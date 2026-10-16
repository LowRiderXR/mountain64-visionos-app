//
//  Renderer.swift
//  AvpCeleste64
//
//  Renderschleife für P0a auf eigenem Thread, nach Apples Muster:
//  queryNextFrame → Update → warten bis optimalInputTime → Submission → Drawable holen.
//  Pro Frame und Auge ein Pass auf die eigene Textur: opaker Clear auf Schwarz (Alpha 1),
//  Tiefe auf 0 (Reverse-Z, 0 = fern). Render-Pose über ARKit an das Drawable melden,
//  encodePresent zuletzt, commit, endSubmission. Jeder angefangene Frame wird abgeschlossen.
//
//  Sonden hinter Schaltern, Standard aus:
//  - C64_STALL_SEQ (Umgebungsvariable, Millisekunden mit Komma): 10 s nach Start der
//    Schleife blockiert der Render-Thread einmal für die erste Dauer, 10 s danach für die
//    nächste, und so weiter. Der Block sitzt VOR queryNextFrame, also ohne angefangenen Frame.
//  Immer an (billig): einmal pro Sekunde eine Zeile [c64-frame].
//

import ARKit
import CompositorServices
import Foundation
import Metal
import os
import QuartzCore

extension LayerRenderer.Clock.Instant {
    /// Sekunden seit der Epoche der Compositor-Uhr (Mach-Zeitbasis), wie sie
    /// WorldTrackingProvider.queryDeviceAnchor(atTimestamp:) erwartet.
    nonisolated var timeInterval: TimeInterval {
        let components = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }
}

nonisolated final class Renderer: @unchecked Sendable {

    // MARK: Aufbau

    private let layerRenderer: LayerRenderer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let appModel: AppModel
    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    // Stall-Probe
    private let stallPlan: [TimeInterval]
    private var stallIndex = 0
    private var nextStallAt: CFAbsoluteTime = 0
    private static let stallSpacing: TimeInterval = 10

    // Frame-Statistik (nur vom Render-Thread berührt)
    private var statWindowStart: CFAbsoluteTime = 0
    private var statFrames = 0
    private var statFramesWithoutAnchor = 0
    private var statIntervalMin = Double.greatestFiniteMagnitude
    private var statIntervalMax = 0.0
    private var statIntervalSum = 0.0
    private var statIntervalCount = 0
    private var statGaps: UInt64 = 0
    private var statCancelled = 0          // queryDrawables lieferte eine leere Liste (Frame vom System abgebrochen)
    private var statNoCmdBuf = 0           // makeCommandBuffer lieferte nil
    private var statDrawablesMin = Int.max // Drawables pro Frame im Fenster
    private var statDrawablesMax = 0
    private var lastNoCmdBufLog: CFAbsoluteTime = 0
    private var lastTargets: [UInt32]?     // Zielmenge des letzten Frames, für [c64-targets]
    private var lastPresentationTime: TimeInterval?
    private var lastFrameIndex: UInt64?
    private var totalFrames: UInt64 = 0

    private init(layerRenderer: LayerRenderer, appModel: AppModel) {
        self.layerRenderer = layerRenderer
        self.appModel = appModel
        self.device = layerRenderer.device
        guard let queue = device.makeCommandQueue() else {
            fatalError("MTLCommandQueue konnte nicht erzeugt werden")
        }
        queue.label = "c64-render-queue"
        self.commandQueue = queue
        self.stallPlan = StallPlan.fromEnvironment()
    }

    /// Einstieg aus dem CompositorLayer-Closure (Hauptthread). Startet ARKit und dann die
    /// Renderschleife auf einem eigenen Thread.
    @MainActor
    static func start(layerRenderer: LayerRenderer, appModel: AppModel) {
        let renderer = Renderer(layerRenderer: layerRenderer, appModel: appModel)
        renderer.logContext()
        Task {
            await renderer.startARSession()
            renderer.startThread()
        }
    }

    private func startARSession() async {
        do {
            try await arSession.run([worldTracking])
            c64Log.notice("[c64-arkit] WorldTrackingProvider läuft")
        } catch {
            // Ohne Pose wird trotzdem präsentiert (Schwarz ohne Anker); das Log zeigt es.
            c64Record("[c64-arkit] ARKitSession.run fehlgeschlagen: \(error)")
        }
    }

    private func startThread() {
        let thread = Thread { [self] in
            renderLoop()
        }
        thread.name = "c64-render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: Startzeile

    /// [c64-ctx]: der gelesene Zustand des Prozesses, nicht der angenommene.
    private func logContext() {
        let config = layerRenderer.configuration
        let layout = ProbeLayerConfiguration.name(config.layout)
        let line = "[c64-ctx] build=\(ProbeContext.buildConfiguration)"
            + " MTL_DEBUG_LAYER=\(ProbeContext.environment("MTL_DEBUG_LAYER"))"
            + " METAL_DEVICE_WRAPPER_TYPE=\(ProbeContext.environment("METAL_DEVICE_WRAPPER_TYPE"))"
            + " hw.machine=\(ProbeContext.hardwareMachine)"
            + " os=\(ProbeContext.osVersion)"
            + " gpu=\(device.name)"
            + " layout=\(layout)"
            + " color=\(ProbeContext.name(config.colorFormat))"
            + " depth=\(ProbeContext.name(config.depthFormat))"
            + " foveation=\(config.isFoveationEnabled)"
            + " views=\(layerRenderer.properties.viewCount)"
            + " stallSeq=\(stallPlan.isEmpty ? "-" : stallPlan.map { String(Int($0 * 1000)) }.joined(separator: ","))"
        c64Record(line)
    }

    // MARK: Schleife

    private func renderLoop() {
        let start = CFAbsoluteTimeGetCurrent()
        statWindowStart = start
        nextStallAt = start + Self.stallSpacing
        c64Record("[c64-loop] Renderschleife gestartet, thread=\(Thread.current.name ?? "?")")

        while true {
            switch layerRenderer.state {
            case .invalidated:
                c64Record("[c64-loop] Layer invalidiert, Schleife endet nach \(totalFrames) Frames")
                Task { @MainActor [appModel] in
                    appModel.immersiveState = .closed
                    appModel.statusLine = "ImmersiveSpace geschlossen."
                }
                return
            case .paused:
                c64Log.notice("[c64-loop] Layer pausiert, warte")
                layerRenderer.waitUntilRunning()
                c64Log.notice("[c64-loop] Layer läuft wieder")
                lastPresentationTime = nil
                continue
            default:
                break
            }

            // Stall-Probe: VOR queryNextFrame, also ohne angefangenen Frame.
            stallIfDue()

            autoreleasepool {
                renderFrame()
            }
        }
    }

    private func stallIfDue() {
        guard stallIndex < stallPlan.count else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now >= nextStallAt else { return }

        let soll = stallPlan[stallIndex]
        let nummer = stallIndex + 1
        let sollMs = Int((soll * 1000).rounded())
        c64Record("[c64-stall] vor Block \(nummer)/\(stallPlan.count) soll=\(sollMs) ms frames=\(totalFrames)")
        let t0 = CFAbsoluteTimeGetCurrent()
        Thread.sleep(forTimeInterval: soll)
        let ist = CFAbsoluteTimeGetCurrent() - t0
        c64Record(String(format: "[c64-stall] nach Block %d/%d soll=%d ms ist=%.1f ms layerState=%@",
                         nummer, stallPlan.count, sollMs, ist * 1000, Self.name(layerRenderer.state)))

        stallIndex += 1
        nextStallAt = CFAbsoluteTimeGetCurrent() + Self.stallSpacing
        lastPresentationTime = nil   // das Intervall über den Block hinweg nicht in die Statistik nehmen
        if stallIndex == stallPlan.count {
            c64Record("[c64-stall] Sequenz beendet, alle \(stallPlan.count) Blöcke überstanden")
        }
    }

    // MARK: Frame

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else {
            // Kein Frame verfügbar (pausiert, invalidiert oder zu viele in Arbeit): kurz warten.
            Thread.sleep(forTimeInterval: 0.001)
            return
        }

        // Update-Phase: hier läuft später Celestes Update (ein Schritt pro Frame).
        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else {
            // Leere Liste: der Frame ist vom System abgebrochen und darf nicht mehr angefasst
            // werden, auch nicht mit endSubmission. frame.h:109-110 zu cp_frame_query_drawables:
            // "If array count is 0, the frame has been cancelled as there are no drawables to
            // draw to and the frame should be discarded and is invalid to access."
            statCancelled += 1
            return
        }
        // Ab dem ersten erhaltenen Drawable ist der Frame in Arbeit und wird in jedem Fall
        // abgeschlossen (encodePresent, commit, endSubmission).

        logTargetsIfChanged(drawables)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            // Ohne Command Buffer lässt sich nichts präsentieren; Submission trotzdem beenden,
            // damit der angefangene Frame nicht offen bleibt. Zeile höchstens einmal pro Sekunde.
            statNoCmdBuf += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastNoCmdBufLog >= 1.0 {
                lastNoCmdBufLog = now
                c64Log.error("[c64-loop] makeCommandBuffer lieferte nil, Frame \(frame.frameIndex) ohne Present beendet (bisher \(self.statNoCmdBuf) im Fenster)")
            }
            frame.endSubmission()
            return
        }
        commandBuffer.label = "c64-frame \(frame.frameIndex)"

        // Pose und Timing aus dem Drawable für das eingebaute Display (target builtIn,
        // drawable.h:36-44, Vorrang laut drawable.h:428-429), Rückfall auf das erste.
        // Fehlt die Pose (ARKit noch nicht bereit), wird trotzdem Schwarz präsentiert, nur
        // ohne Anker. Der Anker wird auf alle Drawables gesetzt.
        let primary = drawables.first(where: { $0.target == .builtIn }) ?? drawables[0]
        let presentationTime = primary.frameTiming.presentationTime.timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: presentationTime)

        for drawable in drawables {
            if let anchor = deviceAnchor {
                drawable.deviceAnchor = anchor
            }
            encodeClearPasses(drawable: drawable, commandBuffer: commandBuffer)
        }

        // encodePresent zuletzt, nach allen Inhalts-Pässen.
        for drawable in drawables {
            drawable.encodePresent(commandBuffer: commandBuffer)
        }
        commandBuffer.commit()
        frame.endSubmission()

        recordStats(frameIndex: frame.frameIndex,
                    presentationTime: presentationTime,
                    hasAnchor: deviceAnchor != nil,
                    drawableCount: drawables.count)
    }

    /// [c64-targets]: das Ziel jedes Drawables, beim ersten Frame und bei jeder Änderung der
    /// Zielmenge (etwa Start und Ende einer Bildschirmaufnahme). Auch in die Fortschrittsdatei.
    private func logTargetsIfChanged(_ drawables: [LayerRenderer.Drawable]) {
        let targets = drawables.map { $0.target.rawValue }
        guard targets != lastTargets else { return }
        lastTargets = targets
        let names = drawables.enumerated().map { index, drawable in
            "\(index):\(Self.name(drawable.target))(\(drawable.colorTextures.count)tex,\(drawable.views.count)views)"
        }.joined(separator: " ")
        c64Record("[c64-targets] drawables=\(drawables.count) \(names) frames=\(totalFrames)")
    }

    /// Pro Auge ein Pass auf die eigene Textur (Layout .dedicated): Farbe Schwarz, Alpha 1,
    /// Tiefe 0 (Reverse-Z, 0 = fern). Keine Draws; der Clear ist der Inhalt.
    private func encodeClearPasses(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer) {
        for (viewIndex, view) in drawable.views.enumerated() {
            let map = view.textureMap
            let descriptor = MTLRenderPassDescriptor()

            let color = descriptor.colorAttachments[0]!
            color.texture = drawable.colorTextures[map.textureIndex]
            color.slice = map.sliceIndex
            color.loadAction = .clear
            color.storeAction = .store
            color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            let depth = descriptor.depthAttachment!
            depth.texture = drawable.depthTextures[map.textureIndex]
            depth.slice = map.sliceIndex
            depth.loadAction = .clear
            depth.storeAction = .store
            depth.clearDepth = 0.0

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                c64Log.error("[c64-frame] makeRenderCommandEncoder lieferte nil (view \(viewIndex))")
                continue
            }
            encoder.label = "c64-clear view\(viewIndex)"
            encoder.endEncoding()
        }
    }

    // MARK: Statistik

    private func recordStats(frameIndex: UInt64, presentationTime: TimeInterval, hasAnchor: Bool, drawableCount: Int) {
        totalFrames += 1
        statFrames += 1
        if !hasAnchor { statFramesWithoutAnchor += 1 }
        statDrawablesMin = min(statDrawablesMin, drawableCount)
        statDrawablesMax = max(statDrawablesMax, drawableCount)

        if let last = lastPresentationTime {
            let interval = presentationTime - last
            if interval > 0 {
                statIntervalMin = min(statIntervalMin, interval)
                statIntervalMax = max(statIntervalMax, interval)
                statIntervalSum += interval
                statIntervalCount += 1
            }
        }
        lastPresentationTime = presentationTime

        if let last = lastFrameIndex, frameIndex > last + 1 {
            statGaps += frameIndex - last - 1
        }
        lastFrameIndex = frameIndex

        let now = CFAbsoluteTimeGetCurrent()
        if now - statWindowStart >= 1.0 {
            let mean = statIntervalCount > 0 ? statIntervalSum / Double(statIntervalCount) : 0
            let hz = mean > 0 ? 1.0 / mean : 0
            let minMs = statIntervalCount > 0 ? statIntervalMin * 1000 : 0
            let drawablesMin = statFrames > 0 ? statDrawablesMin : 0
            let line = String(format: "[c64-frame] frames=%d interval(ms) min=%.2f mean=%.2f max=%.2f rate=%.1f Hz gaps=%llu drawables min=%d/max=%d cancelled=%d noCmdBuf=%d noAnchor=%d thermal=%@ total=%llu",
                              statFrames, minMs, mean * 1000, statIntervalMax * 1000, hz,
                              statGaps, drawablesMin, statDrawablesMax, statCancelled, statNoCmdBuf,
                              statFramesWithoutAnchor, ProbeContext.thermalState, totalFrames)
            c64Log.notice("\(line, privacy: .public)")
            Task { @MainActor [appModel] in
                appModel.frameLine = line
            }
            statWindowStart = now
            statFrames = 0
            statFramesWithoutAnchor = 0
            statIntervalMin = Double.greatestFiniteMagnitude
            statIntervalMax = 0
            statIntervalSum = 0
            statIntervalCount = 0
            statGaps = 0
            statCancelled = 0
            statNoCmdBuf = 0
            statDrawablesMin = Int.max
            statDrawablesMax = 0
        }
    }

    private static func name(_ target: LayerRenderer.Drawable.Target) -> String {
        switch target {
        case .builtIn: return "builtIn"
        case .capture: return "capture"
        @unknown default: return "target\(target.rawValue)"
        }
    }

    private static func name(_ state: LayerRenderer.State) -> String {
        switch state {
        case .paused: return "paused"
        case .running: return "running"
        case .invalidated: return "invalidated"
        @unknown default: return "unknown"
        }
    }
}

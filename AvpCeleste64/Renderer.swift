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

    // Wanduhr-Intervall zwischen aufeinanderfolgenden Rückkehren von queryNextFrame.
    // Zeigt den Block, weil es am Render-Thread misst, nicht am Frame-Zähler des Compositors.
    private var lastQueryReturn: CFAbsoluteTime?
    private var statWallMin = Double.greatestFiniteMagnitude
    private var statWallMax = 0.0
    private var statWallSum = 0.0
    private var statWallCount = 0

    // Verspätung pro Frame: presentationTime minus Compositor-Uhr unmittelbar vor encodePresent,
    // gleiche Zeitbasis (Mach-Zeit, frame_timing.h:67-68). Negativ = die Präsentationszeit ist
    // beim Encodieren schon vorbei.
    private var statLateMin = Double.greatestFiniteMagnitude
    private var statLateMax = -Double.greatestFiniteMagnitude
    private var statLateFrames = 0

    // Die ersten drei Frames nach einem Stall-Block: frameIndex, presentationTime relativ zur
    // Compositor-Uhr beim Erhalt der Drawables, Verspätung vor encodePresent.
    private var postStallWanted = 0
    private var postStallBlock = 0
    private var postStallSamples: [(index: UInt64, relative: Double, late: Double)] = []

    // Foveation-Sonde (P0b): Beschreibung der Drawables und Rate Maps, Fingerabdruck pro Sekunde.
    private var lastFovSignature: String?
    private var lastFovLog: CFAbsoluteTime = 0
    private var lastFovPrint: String?
    private var lastFovPrintTime: CFAbsoluteTime = 0
    private var renderQualityApplied = false

    // Testszene (P0b-2, Schalter C64_TESTSCENE=1): lazy erzeugt auf dem Render-Thread.
    private let testSceneRequested = TestScene.isRequested
    private var testScene: TestScene?
    private var testSceneFailed = false

    // Fehlerstatus der Command Buffer. Der Completed-Handler läuft auf einem Metal-Thread,
    // deshalb hinter einem Lock; der Render-Thread liest und nullt den Zähler pro Sekunde.
    private let cmdErrLock = NSLock()
    private var cmdErrCount = 0
    private var lastCmdErrLog: CFAbsoluteTime = 0

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
            + " maxRenderQuality=\(config.maxRenderQuality.rawValue)"
            + " renderQuality=\(layerRenderer.renderQuality.rawValue)"
            + " C64_RENDERQUALITY=\(ProbeContext.environment("C64_RENDERQUALITY"))"
            + " C64_LAYOUT=\(ProbeContext.environment("C64_LAYOUT"))"
            + " C64_TESTSCENE=\(ProbeContext.environment(TestScene.environmentKey))"
            + " C64_KIT=\(ProbeContext.environment(KitProbe.environmentKey))"
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

        // Kit-Stufe K1a (C64_KIT=inject): einmal vor dem ersten Frame, mit dem Device des
        // Layer-Renderers und der Queue dieses Gerüsts. SDL_Init lief im Hauptthread (ContentView).
        if KitProbe.mode == .inject {
            runKitInjectProbe()
        }

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

    /// K1a: SDL_GPU-Device auf dem geteilten Device und der geteilten Queue, dann Clear-Pass mit
    /// Rücklesen, SDL_DestroyGPUDevice und ein leerer Command Buffer auf der Host-Queue. Danach
    /// läuft die Schleife normal weiter; die ersten [c64-frame]-Zeilen zeigen, ob cmdErr=0 bleibt.
    private func runKitInjectProbe() {
        let result = KitProbe.runInject(device: device, queue: commandQueue)
        Task { @MainActor [appModel] in
            appModel.statusLine = result == 0
                ? "Inject-Test (P1, geteiltes Device und Queue) bestanden. Renderschleife läuft, siehe [c64-kit] und [c64-frame]."
                : "Inject-Test fehlgeschlagen in Schritt \(result). Siehe Log [c64-kit]."
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
        // Das Intervall über den Block hinweg bleibt in der Statistik: lastPresentationTime und
        // lastQueryReturn werden nicht zurückgesetzt, damit die [c64-frame]-Zeile der
        // Block-Sekunde den Sprung zeigt (max ≈ Block + ein Takt).
        postStallWanted = 3
        postStallBlock = nummer
        postStallSamples.removeAll()
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

        // Wanduhr-Intervall seit der letzten Rückkehr von queryNextFrame.
        let queryReturn = CFAbsoluteTimeGetCurrent()
        if let last = lastQueryReturn {
            let wall = queryReturn - last
            statWallMin = min(statWallMin, wall)
            statWallMax = max(statWallMax, wall)
            statWallSum += wall
            statWallCount += 1
        }
        lastQueryReturn = queryReturn

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
        applyRenderQualityIfRequested()
        logFoveationIfChanged(drawables)
        logFoveationFingerprint(drawables)

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
        let frameIndexForHandler = frame.frameIndex
        commandBuffer.addCompletedHandler { [weak self] buffer in
            self?.noteCommandBufferCompletion(buffer, frameIndex: frameIndexForHandler)
        }

        // Pose und Timing aus dem Drawable für das eingebaute Display (target builtIn,
        // drawable.h:36-44, Vorrang laut drawable.h:428-429), Rückfall auf das erste.
        // Fehlt die Pose (ARKit noch nicht bereit), wird trotzdem Schwarz präsentiert, nur
        // ohne Anker. Der Anker wird auf alle Drawables gesetzt.
        let primary = drawables.first(where: { $0.target == .builtIn }) ?? drawables[0]
        let presentationTime = primary.frameTiming.presentationTime.timeInterval
        // presentationTime relativ zur Compositor-Uhr beim Erhalt der Drawables (gleiche Zeitbasis).
        let relativeToNow = presentationTime - LayerRenderer.Clock().now.timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: presentationTime)

        for drawable in drawables {
            if let anchor = deviceAnchor {
                drawable.deviceAnchor = anchor
            }
            encodeClearPasses(drawable: drawable, commandBuffer: commandBuffer, deviceAnchor: deviceAnchor)
        }

        // Verspätung unmittelbar vor encodePresent: Präsentationszeit minus jetzt, gleiche
        // Zeitbasis. Negativ heisst, der Frame wird nach seiner Präsentationszeit abgeschickt.
        let lateness = presentationTime - LayerRenderer.Clock().now.timeInterval

        // encodePresent zuletzt, nach allen Inhalts-Pässen.
        for drawable in drawables {
            drawable.encodePresent(commandBuffer: commandBuffer)
        }
        commandBuffer.commit()
        frame.endSubmission()

        if postStallWanted > 0 {
            postStallSamples.append((frame.frameIndex, relativeToNow, lateness))
            postStallWanted -= 1
            if postStallWanted == 0 {
                let text = postStallSamples.map {
                    String(format: "idx=%llu rel=%+.1f ms late=%+.1f ms", $0.index, $0.relative * 1000, $0.late * 1000)
                }.joined(separator: " | ")
                c64Record("[c64-stall] Block \(postStallBlock)/\(stallPlan.count) erste Frames: \(text)")
            }
        }

        recordStats(frameIndex: frame.frameIndex,
                    presentationTime: presentationTime,
                    lateness: lateness,
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

    /// Clear-Pässe: Farbe Schwarz, Alpha 1, Tiefe 0 (Reverse-Z, 0 = fern). Keine Draws; der
    /// Clear ist der Inhalt.
    ///
    /// Layout .layered (Standard): **ein** Pass über alle Schichten mit
    /// `renderTargetArrayLength = Anzahl Views` (MTLRenderPass.h:321-324, „number of active
    /// layers“), Slice = kleinster sliceIndex der Views. Das ist der Pass, den Celeste später
    /// mit Vertex Amplification fährt; Clear und Rate Map laufen damit genau dort, wo sie im
    /// Port laufen werden. Rate Map: `rasterizationRateMaps[0]`, eine Map mit `layerCount ==
    /// Schichten` (Metal-Doku MTLRasterizationRateMap: „one layer map for each layer“; Vice City
    /// misst für .layered eine Map mit layerCount 2, angle-stereo-multiview.md Abschnitt 2).
    ///
    /// Layout .dedicated oder .shared: ein Pass pro View auf dessen Textur. Rate Map: die Map
    /// mit dem Index der View-Textur, falls so viele Maps vorhanden sind, sonst die erste.
    /// Dass bei .dedicated eine Map pro Textur kommt, ist nicht dokumentiert; [c64-fov] loggt
    /// die tatsächliche Anzahl.
    private func encodeClearPasses(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer, deviceAnchor: DeviceAnchor?) {
        let scene = currentTestScene()
        let maps = layerRenderer.configuration.isFoveationEnabled ? drawable.rasterizationRateMaps : []
        let views = drawable.views
        guard let firstView = views.first else { return }
        let isArray = drawable.colorTextures[firstView.textureMap.textureIndex].textureType == .type2DArray

        if isArray, views.count > 1 {
            let baseSlice = views.map { $0.textureMap.sliceIndex }.min() ?? 0
            let descriptor = Self.clearDescriptor(color: drawable.colorTextures[firstView.textureMap.textureIndex],
                                                  depth: drawable.depthTextures[firstView.textureMap.textureIndex],
                                                  slice: baseSlice)
            descriptor.renderTargetArrayLength = views.count
            if let map = maps.first {
                descriptor.rasterizationRateMap = map
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                c64Log.error("[c64-frame] makeRenderCommandEncoder lieferte nil (layered, \(views.count) Schichten)")
                return
            }
            encoder.label = "c64-clear layered x\(views.count)"
            // Testszene: beide Schichten in einem Draw, Amplification 2, Map bleibt am Pass.
            scene?.encode(encoder: encoder, drawable: drawable, views: Array(views.prefix(2)),
                          viewIndices: Array(0..<min(views.count, 2)), deviceAnchor: deviceAnchor)
            encoder.endEncoding()
            return
        }

        for (viewIndex, view) in views.enumerated() {
            let textureMap = view.textureMap
            let descriptor = Self.clearDescriptor(color: drawable.colorTextures[textureMap.textureIndex],
                                                  depth: drawable.depthTextures[textureMap.textureIndex],
                                                  slice: textureMap.sliceIndex)
            if !maps.isEmpty {
                descriptor.rasterizationRateMap = textureMap.textureIndex < maps.count ? maps[textureMap.textureIndex] : maps[0]
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                c64Log.error("[c64-frame] makeRenderCommandEncoder lieferte nil (view \(viewIndex))")
                continue
            }
            encoder.label = "c64-clear view\(viewIndex)"
            // Testszene bei .dedicated/.shared: pro View ein Draw ohne Amplification.
            scene?.encode(encoder: encoder, drawable: drawable, views: [view],
                          viewIndices: [viewIndex], deviceAnchor: deviceAnchor)
            encoder.endEncoding()
        }
    }

    /// Testszene beim ersten Bedarf erzeugen (Render-Thread); scheitert sie, bleibt sie aus.
    private func currentTestScene() -> TestScene? {
        guard testSceneRequested, !testSceneFailed else { return nil }
        if let testScene { return testScene }
        let config = layerRenderer.configuration
        guard let mode = TestScene.requestedMode else { return nil }
        let scene = TestScene(mode: mode,
                              device: device,
                              colorFormat: config.colorFormat,
                              depthFormat: config.depthFormat,
                              viewCount: layerRenderer.properties.viewCount)
        if scene == nil { testSceneFailed = true }
        testScene = scene
        return scene
    }

    private static func clearDescriptor(color colorTexture: MTLTexture, depth depthTexture: MTLTexture, slice: Int) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        let color = descriptor.colorAttachments[0]!
        color.texture = colorTexture
        color.slice = slice
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let depth = descriptor.depthAttachment!
        depth.texture = depthTexture
        depth.slice = slice
        depth.loadAction = .clear
        depth.storeAction = .store
        depth.clearDepth = 0.0
        return descriptor
    }

    // MARK: Foveation-Sonde (P0b)

    /// Render Quality zur Laufzeit setzen, einmal nach dem ersten Drawable. Nur mit Foveation
    /// und gesetzter Obergrenze; der Wert wird auf maxRenderQuality geklemmt, weil ein höherer
    /// Wert CompositorServices abbrechen lässt (Plattformwissen, Vice City [vc-rq]).
    private func applyRenderQualityIfRequested() {
        guard !renderQualityApplied else { return }
        renderQualityApplied = true
        guard let wanted = ProcessInfo.processInfo.environment["C64_RENDERQUALITY"].flatMap({ Float($0) }) else { return }
        let config = layerRenderer.configuration
        guard config.isFoveationEnabled else {
            c64Record("[c64-rq] C64_RENDERQUALITY=\(wanted) ignoriert: Foveation aus")
            return
        }
        let before = layerRenderer.renderQuality.rawValue
        let clamped = max(0.0, min(config.maxRenderQuality.rawValue, wanted))
        layerRenderer.renderQuality = LayerRenderer.RenderQuality(clamped)
        c64Record(String(format: "[c64-rq] renderQuality %.3f -> %.3f (gewünscht %.3f, max %.3f); Übergang dauert laut Header einige Frames",
                         before, layerRenderer.renderQuality.rawValue, wanted, config.maxRenderQuality.rawValue))
    }

    /// [c64-fov]: Rate Maps (Anzahl, layerCount, screenSize, physicalSize pro Layer,
    /// Granularität) und pro View die Farb- und Tiefentextur (Typ, Grösse, arrayLength,
    /// Format), Viewport, Slice- und Texturindex. Beim ersten Frame und bei jeder Änderung,
    /// höchstens einmal pro Sekunde (während eines Render-Quality-Übergangs ändert sich die
    /// physicalSize über mehrere Frames).
    private func logFoveationIfChanged(_ drawables: [LayerRenderer.Drawable]) {
        guard let drawable = drawables.first(where: { $0.target == .builtIn }) ?? drawables.first else { return }
        let maps = drawable.rasterizationRateMaps
        var parts: [String] = []
        for (index, map) in maps.enumerated() {
            let layers = (0..<map.layerCount).map { layer -> String in
                let p = map.physicalSize(layer: layer)
                return "L\(layer)=\(p.width)x\(p.height)"
            }.joined(separator: ",")
            let g = map.physicalGranularity
            parts.append("map\(index){layers=\(map.layerCount) screen=\(map.screenSize.width)x\(map.screenSize.height) physical[\(layers)] granularity=\(g.width)x\(g.height)}")
        }
        for (index, view) in drawable.views.enumerated() {
            let tm = view.textureMap
            let c = drawable.colorTextures[tm.textureIndex]
            let d = drawable.depthTextures[tm.textureIndex]
            let vp = tm.viewport
            parts.append("view\(index){tex=\(tm.textureIndex) slice=\(tm.sliceIndex) viewport=\(Int(vp.originX)),\(Int(vp.originY)) \(Int(vp.width))x\(Int(vp.height)) color=\(Self.name(c.textureType)) \(c.width)x\(c.height) arr=\(c.arrayLength) \(ProbeContext.name(c.pixelFormat)) depth=\(Self.name(d.textureType)) \(d.width)x\(d.height) arr=\(d.arrayLength) \(ProbeContext.name(d.pixelFormat))}")
        }
        let signature = parts.joined(separator: " ")
        guard signature != lastFovSignature else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastFovSignature == nil || now - lastFovLog >= 1.0 else { return }
        lastFovSignature = signature
        lastFovLog = now
        c64Record(String(format: "[c64-fov] maps=%d renderQuality=%.3f frames=%llu %@",
                         maps.count, layerRenderer.renderQuality.rawValue, totalFrames, signature))
    }

    /// [c64-fovprint] einmal pro Sekunde: physische Koordinaten zu fünf festen Bildschirmpunkten
    /// (Mitte, 25 % links, rechts, oben, unten) pro Map und Layer, gerundet. Ändert sich der
    /// Abdruck gegenüber der Vorsekunde, zusätzlich [c64-fovchange]. Konstanter Abdruck bei
    /// bewegtem Blick = feste Foveation; wandernder Abdruck = blickabhängig.
    private func logFoveationFingerprint(_ drawables: [LayerRenderer.Drawable]) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFovPrintTime >= 1.0 else { return }
        lastFovPrintTime = now
        guard layerRenderer.configuration.isFoveationEnabled,
              let drawable = drawables.first(where: { $0.target == .builtIn }) ?? drawables.first else { return }
        let maps = drawable.rasterizationRateMaps
        guard !maps.isEmpty else { return }

        var parts: [String] = []
        for (index, map) in maps.enumerated() {
            let w = Float(map.screenSize.width), h = Float(map.screenSize.height)
            let points: [(String, Float, Float)] = [
                ("c", w * 0.5, h * 0.5), ("l", w * 0.25, h * 0.5), ("r", w * 0.75, h * 0.5),
                ("u", w * 0.5, h * 0.25), ("d", w * 0.5, h * 0.75),
            ]
            for layer in 0..<map.layerCount {
                let coords = points.map { name, x, y -> String in
                    let p = map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: x, y: y), layer: layer)
                    return "\(name)=\(Int(p.x.rounded())),\(Int(p.y.rounded()))"
                }.joined(separator: " ")
                parts.append("map\(index)L\(layer)[\(coords)]")
            }
        }
        let print = parts.joined(separator: " ")
        c64Log.notice("[c64-fovprint] \(print, privacy: .public)")
        if let last = lastFovPrint, last != print {
            c64Record("[c64-fovchange] frames=\(totalFrames) neu: \(print)")
        }
        lastFovPrint = print
    }

    // MARK: Command-Buffer-Fehler

    /// Completed-Handler (Metal-Thread): Status ungleich .completed oder gesetzter Fehler zählt
    /// als Fehler; Zeile [c64-cmderr] höchstens einmal pro Sekunde, auch in die Datei.
    private func noteCommandBufferCompletion(_ buffer: MTLCommandBuffer, frameIndex: UInt64) {
        let status = buffer.status
        let error = buffer.error
        guard status != .completed || error != nil else { return }

        cmdErrLock.lock()
        cmdErrCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let shouldLog = now - lastCmdErrLog >= 1.0
        if shouldLog { lastCmdErrLog = now }
        cmdErrLock.unlock()

        guard shouldLog else { return }
        let errorText: String
        if let error = error as NSError? {
            errorText = "\(error.domain) code=\(error.code) \(error.localizedDescription)"
        } else {
            errorText = "-"
        }
        c64Record("[c64-cmderr] frame=\(frameIndex) status=\(Self.name(status)) error=\(errorText)")
    }

    /// Zähler lesen und nullen (Render-Thread, einmal pro Sekunde).
    private func takeCommandBufferErrors() -> Int {
        cmdErrLock.lock()
        defer { cmdErrLock.unlock() }
        let count = cmdErrCount
        cmdErrCount = 0
        return count
    }

    private static func name(_ status: MTLCommandBufferStatus) -> String {
        switch status {
        case .notEnqueued: return "notEnqueued"
        case .enqueued: return "enqueued"
        case .committed: return "committed"
        case .scheduled: return "scheduled"
        case .completed: return "completed"
        case .error: return "error"
        @unknown default: return "status\(status.rawValue)"
        }
    }

    private static func name(_ type: MTLTextureType) -> String {
        switch type {
        case .type2D: return "type2D"
        case .type2DArray: return "type2DArray"
        case .type2DMultisample: return "type2DMultisample"
        case .type2DMultisampleArray: return "type2DMultisampleArray"
        default: return "textureType\(type.rawValue)"
        }
    }

    // MARK: Statistik

    private func recordStats(frameIndex: UInt64, presentationTime: TimeInterval, lateness: TimeInterval, hasAnchor: Bool, drawableCount: Int) {
        totalFrames += 1
        statFrames += 1
        if !hasAnchor { statFramesWithoutAnchor += 1 }
        statDrawablesMin = min(statDrawablesMin, drawableCount)
        statDrawablesMax = max(statDrawablesMax, drawableCount)
        statLateMin = min(statLateMin, lateness)
        statLateMax = max(statLateMax, lateness)
        if lateness < 0 { statLateFrames += 1 }

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
            let wallMean = statWallCount > 0 ? statWallSum / Double(statWallCount) : 0
            let wallMin = statWallCount > 0 ? statWallMin : 0
            let lateMin = statFrames > 0 ? statLateMin : 0
            let lateMax = statFrames > 0 ? statLateMax : 0
            let cmdErr = takeCommandBufferErrors()
            let line = String(format: "[c64-frame] frames=%d interval(ms) min=%.2f mean=%.2f max=%.2f rate=%.1f Hz wall(ms) min=%.2f mean=%.2f max=%.1f late(ms) min=%+.1f max=%+.1f lateFrames=%d gaps=%llu drawables min=%d/max=%d cancelled=%d noCmdBuf=%d cmdErr=%d noAnchor=%d thermal=%@ total=%llu",
                              statFrames, minMs, mean * 1000, statIntervalMax * 1000, hz,
                              wallMin * 1000, wallMean * 1000, statWallMax * 1000,
                              lateMin * 1000, lateMax * 1000, statLateFrames,
                              statGaps, drawablesMin, statDrawablesMax, statCancelled, statNoCmdBuf, cmdErr,
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
            statWallMin = Double.greatestFiniteMagnitude
            statWallMax = 0
            statWallSum = 0
            statWallCount = 0
            statLateMin = Double.greatestFiniteMagnitude
            statLateMax = -Double.greatestFiniteMagnitude
            statLateFrames = 0
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

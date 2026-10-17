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
    private var cmdErrTotal = 0
    private var lastCmdErrLog: CFAbsoluteTime = 0

    // Kit-Stufe K1b (C64_KIT=import): SDL_GPU-Device auf Device und Queue dieses Gerüsts, das in
    // jedem Frame die Drawable-Texturen importiert und löscht. Nur vom Render-Thread berührt.
    private var kitImportSession: OpaquePointer?
    private var kitImportFailed = false       // Sitzung liess sich nicht anlegen: Gerüst löscht selbst
    // Kit-Stufe K2 (C64_KIT=multiview): SDL_GPU-Device mit Pipeline view_count 2; pro Frame Import
    // und ein Pass mit Clear und Schachbrett für beide Augen. Nur vom Render-Thread berührt.
    private var kitMultiviewSession: OpaquePointer?
    private var kitQuad = KitQuadPlacement()
    private var statSdlFail = 0               // Frames im Fenster, in denen SDL scheiterte
    private var sdlFailTotal = 0
    private var footprintStartMB = 0.0        // phys_footprint beim Start der Schleife, in jedem Modus
    // K1b-Diagnose (C64_KIT_VERIFY): SDLs Rücklesewert dieses Frames und die Drawable-Textur,
    // aus der das Gerüst unmittelbar vor encodePresent dieselbe Stelle nochmals liest.
    private var pendingVerify: (afterSDL: [UInt8], color: MTLTexture)?
    private var cancelledTotal = 0
    private static let importClearColor: (Float, Float, Float, Float) = (0.0, 0.1, 0.3, 1.0)
    // K1b: Tiefenwert des SDL-Clears. Der Compositor zeigt nur Pixel mit Alpha > 0 und Tiefe > 0
    // (WWDC24, Session 10092 «Render Metal with passthrough in visionOS»; Messung K1b am
    // 2026-10-17: Tiefe 0 schwarz, Tiefe 0.001 blau, bei identischem Texturinhalt). Reverse-Z mit
    // unendlicher Far-Ebene: Abstand = near / Tiefe; 0.001 bei near 0,1 m sind 100 m, also ein
    // «vorhandener» leerer Hintergrund. C64_KIT_DEPTH=0 bleibt als Gegenprobe möglich.
    private static let importClearDepthDefault: Float = 0.001
    private let importClearDepth: Float = Float(ProcessInfo.processInfo.environment["C64_KIT_DEPTH"] ?? "") ?? Renderer.importClearDepthDefault
    private var importDepthLogged = false

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
            + " C64_KIT_DEPTH=\(ProbeContext.environment("C64_KIT_DEPTH"))"
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
        // Speicher am Anfang der Schleife, in jedem Modus (Vergleichswert für die Zusammenfassung).
        footprintStartMB = ProbeContext.physFootprintMB
        c64Record("[c64-loop] footprintStartMB=\(String(format: "%.1f", footprintStartMB)) C64_KIT=\(ProbeContext.environment(KitProbe.environmentKey))")
        // Kit-Stufe K1b (C64_KIT=import): Sitzung für die ganze Schleife.
        if KitProbe.mode == .import {
            kitImportSession = KitProbe.beginImport(device: device, queue: commandQueue)
            kitImportFailed = (kitImportSession == nil)
            c64Record("[c64-kit] import session=\(kitImportSession == nil ? "FEHLT, Gerüst löscht selbst" : "ok")")
        }
        // Kit-Stufe K2 (C64_KIT=multiview): Sitzung mit Pipeline view_count 2 für die ganze Schleife.
        if KitProbe.mode == .multiview {
            kitMultiviewSession = KitProbe.beginMultiview(device: device, queue: commandQueue)
            kitImportFailed = (kitMultiviewSession == nil)
            c64Record("[c64-kit] multiview session=\(kitMultiviewSession == nil ? "FEHLT, Gerüst löscht selbst" : "ok")")
        }

        while true {
            switch layerRenderer.state {
            case .invalidated:
                c64Record("[c64-loop] Layer invalidiert, Schleife endet nach \(totalFrames) Frames")
                logLoopSummary()
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

    /// K1b: SDL importiert Farb- und Tiefentextur des Drawables und löscht alle Schichten
    /// (dunkelblau, Tiefe 0). SDL committet seinen Command Buffer dabei synchron auf der geteilten
    /// Queue; der Gerüst-Buffer mit encodePresent wird danach committet und läuft deshalb danach
    /// (MTLCommandQueue ist seriell, Ausführung in Commit-Reihenfolge). false: das Gerüst löscht
    /// selbst und präsentiert trotzdem.
    private func kitImportClear(drawable: LayerRenderer.Drawable) -> Bool {
        guard let session = kitImportSession else { return false }
        // Bei .layered nutzen alle Views dieselbe Array-Textur; bei .dedicated eine pro View.
        var textureIndices: [Int] = []
        for view in drawable.views where !textureIndices.contains(view.textureMap.textureIndex) {
            textureIndices.append(view.textureMap.textureIndex)
        }
        if !importDepthLogged {
            importDepthLogged = true
            // depthRange: x = far, y = near, in Metern (drawable.h:317-320).
            let range = drawable.depthRange
            let distance = importClearDepth > 0 ? String(format: "%.1f m", range.y / importClearDepth) : "unendlich (kein Inhalt für den Compositor)"
            c64Record(String(format: "[c64-kit] step=import-depth clear=%.4f depthRange far=%.3f near=%.3f entspricht Abstand %@",
                             importClearDepth, range.x, range.y, distance))
        }
        for index in textureIndices {
            let ok = KitProbe.importClear(session: session,
                                          color: drawable.colorTextures[index],
                                          depth: drawable.depthTextures[index],
                                          rgba: Self.importClearColor,
                                          depthValue: importClearDepth)
            if !ok { return false }
        }
        return true
    }

    /// K2: Farb- und Tiefentextur importieren, ein Pass mit view_count 2: Clear (dunkelblau, Tiefe
    /// aus importClearDepth) und das Schachbrett für beide Augen, Matrizen wie TestScene
    /// (Projektion · inverse(deviceAnchor · view.transform)). Ohne Pose nur der Clear.
    private func kitMultiviewFrame(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) -> Bool {
        guard let session = kitMultiviewSession, let firstView = drawable.views.first else { return false }
        let index = firstView.textureMap.textureIndex
        var quad: (center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>)?
        var matrices = [matrix_identity_float4x4, matrix_identity_float4x4]
        if let deviceAnchor {
            let anchorTransform = deviceAnchor.originFromAnchorTransform
            kitQuad.update(anchor: anchorTransform)
            quad = kitQuad.quad
            for (slot, view) in drawable.views.prefix(2).enumerated() {
                matrices[slot] = drawable.computeProjection(viewIndex: slot) * (anchorTransform * view.transform).inverse
            }
        }
        return KitProbe.multiviewFrame(session: session,
                                       color: drawable.colorTextures[index],
                                       depth: drawable.depthTextures[index],
                                       rgba: Self.importClearColor,
                                       depthClear: importClearDepth,
                                       quad: quad,
                                       viewProjection: matrices)
    }

    /// Zusammenfassung am Ende der Schleife, in jedem Modus: Frames, cmdErr, Speicher am Anfang und
    /// Ende. Im Modus import zusätzlich sdlFail, Wrapper und Rotation; im Modus multiview Pässe und
    /// Draws pro Frame und die CPU-Zeit des SDL-Teils; die Sitzung wird geschlossen.
    private func logLoopSummary() {
        var kitPart = ""
        if let session = kitImportSession {
            let stats = KitProbe.takeImportStats(session: session)
            kitPart = String(format: " sdlFail=%d wrappers created=%lu released=%lu distinctColor=%u distinctDepth=%u",
                             sdlFailTotal, stats.wrappers_created, stats.wrappers_released,
                             stats.distinct_color, stats.distinct_depth)
            KitProbe.endImport(session: session)
            kitImportSession = nil
        } else if let session = kitMultiviewSession {
            let stats = KitProbe.takeMultiviewStats(session: session)
            let frames = max(stats.frames_total, 1)
            let meanMs = stats.total_sum_ms / Double(frames)
            kitPart = String(format: " sdlFail=%d passesPerFrame=%.2f drawsPerFrame=%.2f sdl(ms) mean=%.3f max=%.3f wrappers created=%lu released=%lu",
                             sdlFailTotal, Double(stats.passes_total) / Double(frames), Double(stats.draws_total) / Double(frames),
                             meanMs, stats.total_max_ms, stats.wrappers_created, stats.wrappers_released)
            KitProbe.endMultiview(session: session)
            kitMultiviewSession = nil
        } else if kitImportFailed {
            kitPart = " sdlFail=\(sdlFailTotal) session=none"
        }
        let footprintEnd = ProbeContext.physFootprintMB
        cmdErrLock.lock()
        let cmdErr = cmdErrTotal
        cmdErrLock.unlock()
        let mode = KitProbe.mode?.rawValue ?? "-"
        c64Record(String(format: "[c64-loop] summary C64_KIT=%@ frames=%llu cancelled=%d cmdErr=%d footprintMB start=%.1f end=%.1f delta=%+.1f%@",
                         mode, totalFrames, cancelledTotal, cmdErr,
                         footprintStartMB, footprintEnd, footprintEnd - footprintStartMB, kitPart))
    }

    /// K1b-Diagnose: dieselbe Stelle, die SDL nach seinem Clear zurückgelesen hat, im Gerüst-Buffer
    /// unmittelbar vor encodePresent nochmals lesen (Blit des Mittelpixels von Schicht 0 und 1 in
    /// einen geteilten Puffer); geloggt im Completed-Handler mit beiden Werten.
    private func encodeVerifyBeforePresent(commandBuffer: MTLCommandBuffer, frameIndex: UInt64) {
        guard let pending = pendingVerify else { return }
        pendingVerify = nil
        let texture = pending.color
        guard let buffer = device.makeBuffer(length: 64, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            c64Record("[c64-kit] step=present-verify frame=\(frameIndex) blit nicht möglich")
            return
        }
        blit.label = "c64-verify-before-present"
        let origin = MTLOrigin(x: texture.width / 2, y: texture.height / 2, z: 0)
        let size = MTLSize(width: 1, height: 1, depth: 1)
        let slices = min(texture.arrayLength, 2)
        for slice in 0..<slices {
            blit.copy(from: texture, sourceSlice: slice, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
                      to: buffer, destinationOffset: slice * 16, destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        }
        blit.endEncoding()
        let afterSDL = pending.afterSDL
        let textureID = ObjectIdentifier(texture)
        commandBuffer.addCompletedHandler { buffer_ in
            let p = buffer.contents().assumingMemoryBound(to: UInt8.self)
            let layer0 = "\(p[0]),\(p[1]),\(p[2]),\(p[3])"
            let layer1 = slices > 1 ? "\(p[16]),\(p[17]),\(p[18]),\(p[19])" : "-"
            let sdl = "\(afterSDL[0]),\(afterSDL[1]),\(afterSDL[2]),\(afterSDL[3])"
            c64Record("[c64-kit] step=present-verify frame=\(frameIndex) afterSDL(layer0)=\(sdl) beforePresent layer0=\(layer0) layer1=\(layer1) (b,g,r,a) status=\(Self.name(buffer_.status)) texture=\(textureID)")
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
            cancelledTotal += 1
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
            // K1b: zuerst SDL (importiert und löscht, committet auf der geteilten Queue), dann
            // der Gerüst-Buffer mit nur encodePresent. Scheitert SDL, zählt das Gerüst sdlFail und
            // löscht selbst: Schwarz mit Tiefe 0, also bewusst «leer» für den Compositor (Alpha > 0
            // und Tiefe > 0 wären Inhalt); der Frame wird trotzdem präsentiert.
            if kitMultiviewSession != nil {
                if kitMultiviewFrame(drawable: drawable, deviceAnchor: deviceAnchor) {
                    continue
                }
                statSdlFail += 1
                sdlFailTotal += 1
            } else if kitImportSession != nil || kitImportFailed {
                if kitImportClear(drawable: drawable) {
                    // Diagnose: hat SDL in diesem Frame zurückgelesen, liest das Gerüst vor dem
                    // Present dieselbe Stelle (erste Textur des Drawables).
                    if let session = kitImportSession, let afterSDL = KitProbe.lastVerify(session: session),
                       let firstView = drawable.views.first {
                        pendingVerify = (afterSDL, drawable.colorTextures[firstView.textureMap.textureIndex])
                    }
                    continue
                }
                statSdlFail += 1
                sdlFailTotal += 1
            }
            encodeClearPasses(drawable: drawable, commandBuffer: commandBuffer, deviceAnchor: deviceAnchor)
        }

        // Verspätung unmittelbar vor encodePresent: Präsentationszeit minus jetzt, gleiche
        // Zeitbasis. Negativ heisst, der Frame wird nach seiner Präsentationszeit abgeschickt.
        let lateness = presentationTime - LayerRenderer.Clock().now.timeInterval

        // K1b-Diagnose: Rücklesen im Gerüst-Buffer, als letzter Inhalt vor encodePresent.
        encodeVerifyBeforePresent(commandBuffer: commandBuffer, frameIndex: frame.frameIndex)

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

    /// Clear-Pässe: Farbe Schwarz, Alpha 1, Tiefe 0 (Reverse-Z, 0 = fern). Keine Draws. Für den
    /// Compositor ist das bewusst «leer»: Er zeigt nur Pixel mit Alpha > 0 und Tiefe > 0 (WWDC24,
    /// Session 10092; Messung K1b), Tiefe 0 heisst unendlich fern. Das Gerüst präsentiert damit
    /// einen gültigen Frame ohne Inhalt; das ist auch der Rückfall, wenn SDL im Modus import scheitert.
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
        cmdErrTotal += 1
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
            var line = String(format: "[c64-frame] frames=%d interval(ms) min=%.2f mean=%.2f max=%.2f rate=%.1f Hz wall(ms) min=%.2f mean=%.2f max=%.1f late(ms) min=%+.1f max=%+.1f lateFrames=%d gaps=%llu drawables min=%d/max=%d cancelled=%d noCmdBuf=%d cmdErr=%d noAnchor=%d thermal=%@ total=%llu",
                              statFrames, minMs, mean * 1000, statIntervalMax * 1000, hz,
                              wallMin * 1000, wallMean * 1000, statWallMax * 1000,
                              lateMin * 1000, lateMax * 1000, statLateFrames,
                              statGaps, drawablesMin, statDrawablesMax, statCancelled, statNoCmdBuf, cmdErr,
                              statFramesWithoutAnchor, ProbeContext.thermalState, totalFrames)
            // K1b: CPU-Zeit des SDL-Teils (Wrapper, Pässe, Submit, Release) im Fenster.
            if let session = kitImportSession {
                let stats = KitProbe.takeImportStats(session: session)
                let meanMs = stats.frames > 0 ? stats.sum_ms / Double(stats.frames) : 0
                line += String(format: " sdl(ms) mean=%.3f max=%.3f sdlFrames=%u sdlFail=%d", meanMs, stats.max_ms, stats.frames, statSdlFail)
            } else if let session = kitMultiviewSession {
                let stats = KitProbe.takeMultiviewStats(session: session)
                let meanMs = stats.frames > 0 ? stats.sum_ms / Double(stats.frames) : 0
                line += String(format: " sdl(ms) mean=%.3f max=%.3f sdlFrames=%u sdlFail=%d passes=%lu draws=%lu", meanMs, stats.max_ms, stats.frames, statSdlFail, stats.passes_total, stats.draws_total)
            } else if kitImportFailed {
                line += " sdl=none sdlFail=\(statSdlFail)"
            }
            statSdlFail = 0
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

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
    // ARKit: Session und Provider leben so lange wie der Renderer (Apple: «ARKit stops sessions
    // when they're deinitialized»). Der Provider kann nach einem Fehler ersetzt werden (ein
    // gestoppter Provider darf nicht erneut an run gehen), deshalb hinter einem Lock; der
    // Render-Thread liest ihn pro Frame.
    private let arSession = ARKitSession()
    private let arLock = NSLock()
    private var worldTrackingStorage = WorldTrackingProvider()
    private var worldTracking: WorldTrackingProvider {
        arLock.withLock { worldTrackingStorage }
    }
    private var arRunAttempts = 0
    private static let arMaxRunAttempts = 3
    private var lastLoggedProviderState: DataProviderState?
    // Zustand des Providers einmal pro Sekunde in den ersten zehn Sekunden (M4a.5b-6: bleibt
    // ARKit nach dem Schliessen des Startfensters running?).
    private var arkitPeriodicRemaining = 10
    private var arkitPeriodicNextAt: CFAbsoluteTime = 0
    // M4a.5c-4: Frame-Abschluss nach dem Muster von Vice City. Die Pause wird nur am Schleifen-
    // anfang entschieden; ein Frame nach queryNextFrame läuft immer bis encodePresent, commit,
    // endSubmission (Ausstiege nur bei predictTiming nil und leerer Drawable-Liste). Ein Frame,
    // der mittendrin verlassen wurde, blieb entweder in Arbeit (BUG IN CLIENT «more than 3 frames
    // in flight» beim nächsten queryNextFrame, Absturz M5 2026-10-25) oder liess ein bezogenes
    // Drawable ohne Present zurück (GPU-Timeout des nächsten Host-Buffers, rund 5 s).
    // Diese Notiz hält fest, wo das Hintergrund-Flag im Frame zuerst gesehen wurde.
    private struct PauseFrameNote {
        var frameIndex: UInt64
        var flagSeen: String      // before-update | after-update | after-render
        var tickSkipped: Bool     // kein celeste_update in diesem Frame
        var renderSkipped: Bool   // Update lief, celeste_render_frame entfiel (M4b.1)
        var committed: Bool
        var presented: Bool
    }
    private var pauseFrameNote: PauseFrameNote?
    // Nach dem Fortsetzen: die ersten drei Frames mit dem Status ihres Command Buffers.
    private var resumeFramesToLog = 0
    // Frame, dessen Host-Buffer bei gesetztem Flag committet wurde (hinter cmdErrLock); dessen
    // BackgroundExecutionNotPermitted ist erwartet und zählt nicht als Fehler.
    private var backgroundCommitFrame: UInt64?
    private var cmdErrExpectedTotal = 0
    // M4a.5c-2: Ton-Zustand, nur vom Render-Thread (FMOD: Suspend und Resume paarweise auf
    // demselben Thread, kein zweites Suspend ohne Resume).
    private var audioSuspended = false {
        didSet { CelesteProbe.pauseState.setMixerSuspended(audioSuspended) }
    }
    private var audioResumePending = false
    private var nextAudioRetryAt: CFAbsoluteTime = 0
    private var audioFallbackTried = false
    private var cmdSkippedTotal = 0
    // Ticks bleiben aus, solange der Mixer angehalten ist (Celestes Tick ruft FMOD: Audio.Update,
    // Events; FMOD: kein Aufruf zwischen mixerSuspend und mixerResume). Die Schleife präsentiert
    // weiter die Leinwand mit dem letzten Bild.
    private var ticksHeldForAudio = false
    private var ticksSkippedForAudio = 0

    /// Pause gewünscht: Layer nicht running oder App im Hintergrund (Flag vom Hauptthread). Der
    /// Layer meldet .paused erst 150 bis 200 ms nach willResignActive; bis dahin würden Ticks und
    /// Commits im Hintergrund laufen (IOGPUMetalError in der Konsole).
    private var shouldPause: Bool {
        layerRenderer.state != .running || CelesteProbe.pauseState.isBackground
    }

    private var pauseReasonText: String {
        "layer=\(Self.name(layerRenderer.state)) background=\(CelesteProbe.pauseState.isBackground ? 1 : 0)"
    }

    /// Eine Zeile je Pause: wo das Hintergrund-Flag zuerst gesehen wurde (vor dem Frame, im
    /// Frame vor dem Tick, im Frame nach dem Tick), Tick ausgelassen, committet, präsentiert.
    private func logPauseFrameNote() {
        if let note = pauseFrameNote {
            c64Record("[c64-pause-frame] tMs=\(LaunchClock.tMs) frame=\(note.frameIndex) flagSeen=\(note.flagSeen) tickSkipped=\(note.tickSkipped ? 1 : 0) renderSkipped=\(note.renderSkipped ? 1 : 0) committed=\(note.committed ? 1 : 0) presented=\(note.presented ? 1 : 0)")
        } else {
            c64Record("[c64-pause-frame] tMs=\(LaunchClock.tMs) frame=\(lastFrameIndex.map { "\($0)" } ?? "-") flagSeen=before-frame tickSkipped=0 renderSkipped=0 committed=0 presented=0 (kein Frame in Arbeit, letzter abgeschlossener Frame)")
        }
        pauseFrameNote = nil
    }

    // MARK: Pause (M4a.5c-2)

    /// Pausenzweig der Schleife. Vor dem ersten Frame (Layer startet .paused) nur warten, ohne
    /// Suspend und ohne Pausenanfrage. Sonst: Ticks stehen, Mixer einmal suspendieren, warten,
    /// bis der Layer running ist und die App im Vordergrund (didBecomeActive gesehen, App active,
    /// Szene foregroundActive); dann Session aktivieren, nur bei Erfolg mixerResume, Pausenanfrage,
    /// Ticks weiter. Kehrt bei .invalidated zurück, der Schleifenkopf beendet dann.
    private func pauseBranch() {
        let initial = totalFrames == 0 && !CelesteProbe.pauseState.isBackground
        c64Record("[c64-loop] tMs=\(LaunchClock.tMs) Layer pausiert, warte; \(pauseReasonText) provider=\(Self.name(worldTracking.state)) frames=\(totalFrames) initial=\(initial ? 1 : 0)")
        if initial {
            layerRenderer.waitUntilRunning()
            c64Record("[c64-loop] tMs=\(LaunchClock.tMs) Layer läuft (Start); provider=\(Self.name(worldTracking.state))")
            lastPresentationTime = nil
            lastQueryReturn = nil
            return
        }
        logPauseFrameNote()

        let game = CelesteProbe.ticksGame && CelesteProbe.tickState.isActive
        if CelesteProbe.ticksGame {
            CelesteProbe.tickState.pause(reason: "pause \(pauseReasonText)")
        }
        if game, !audioSuspended, !audioResumePending {
            // Genau ein Suspend je Pause; ein offener Resume-Versuch (Session war nicht aktiv)
            // lässt FMOD suspendiert, dann kein zweites Suspend.
            if CelesteProbe.suspendAudio(true) {
                audioSuspended = true
            }
        } else if game, audioSuspended {
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) mixer bleibt suspendiert (kein zweites Suspend)")
        }

        // Warten, bis beides erfüllt ist. waitUntilRunning kehrt bei running oder invalidated
        // zurück; das Hintergrund-Flag wird alle 20 ms geprüft.
        var loggedRunningInBackground = false
        while true {
            let state = layerRenderer.state
            if state == .invalidated {
                c64Record("[c64-loop] tMs=\(LaunchClock.tMs) Layer invalidiert während der Pause")
                return
            }
            if state == .paused {
                layerRenderer.waitUntilRunning()
                continue
            }
            if CelesteProbe.pauseState.isBackground {
                if !loggedRunningInBackground {
                    loggedRunningInBackground = true
                    c64Record("[c64-loop] tMs=\(LaunchClock.tMs) Layer läuft wieder, App im Hintergrund, warte")
                }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            break
        }
        c64Record("[c64-loop] tMs=\(LaunchClock.tMs) Fortsetzen; \(pauseReasonText) provider=\(Self.name(worldTracking.state))")
        CelesteProbe.AliveProbe.shared.end(resumeMs: LaunchClock.elapsedMs)

        if game {
            resumeAudioIfPossible(trigger: "resume")
        }
        ticksHeldForAudio = true
        resumeTicksIfAudioRunning(reason: "resume")
        resumeFramesToLog = 3
        lastPresentationTime = nil
        lastQueryReturn = nil
    }

    /// Ticks wieder zulassen, sobald der Mixer läuft: Pausenanfrage ans Spiel, dann
    /// tickState.resume. Bei angehaltenem Mixer bleibt es bei einer Logzeile; der nächste
    /// erfolgreiche Resume-Versuch (serviceAudioRetry) ruft erneut.
    private func resumeTicksIfAudioRunning(reason: String) {
        guard ticksHeldForAudio else { return }
        if audioSuspended {
            c64Record("[c64-celeste] tMs=\(LaunchClock.tMs) Ticks bleiben aus, Mixer angehalten (reason=\(reason))")
            return
        }
        ticksHeldForAudio = false
        if ticksSkippedForAudio > 0 {
            c64Record("[c64-celeste] tMs=\(LaunchClock.tMs) Ticks setzen wieder ein nach \(ticksSkippedForAudio) Frames ohne Tick (reason=\(reason))")
            ticksSkippedForAudio = 0
        }
        if CelesteProbe.ticksGame, CelesteProbe.tickState.isActive {
            CelesteProbe.requestPause()
        }
        if CelesteProbe.ticksGame {
            CelesteProbe.tickState.resume(reason: reason)
        }
        lastQueryReturn = nil
    }

    /// Ton nach einer Pause: Session aktivieren, nur bei Erfolg mixerResume (FMOD-Beispiel
    /// common_platform.mm:211-236). Scheitert die Session, bleibt der Mixer suspendiert, die
    /// Ticks laufen ohne Ton, und der Versuch wiederholt sich bei einem Signal (Session
    /// didBecomeActive, resumptionRecommendation) oder spätestens nach einer Sekunde. Scheitert
    /// mixerResume trotz aktiver Session, folgt einmal FMODs Rückfall für eine gestörte Ausgabe
    /// (Media Services Reset, common_platform.mm:195-196): Suspend und Resume als Paar.
    private func resumeAudioIfPossible(trigger: String, mediaServicesReset: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if mediaServicesReset, !audioSuspended {
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) media services reset im Vordergrund: Suspend und Resume als Paar (FMOD-Beispiel)")
            if CelesteProbe.suspendAudio(true, context: "reset pair") {
                audioSuspended = true
            }
        }
        guard audioSuspended else { return }
        guard CelesteProbe.reactivateAudioSession() else {
            audioResumePending = true
            nextAudioRetryAt = now + 1
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) resume pending: session nicht aktiv, Mixer bleibt suspendiert, Ticks ohne Ton (trigger=\(trigger))")
            return
        }
        if CelesteProbe.suspendAudio(false, context: trigger) {
            audioSuspended = false
            audioResumePending = false
            audioFallbackTried = false
            return
        }
        if !audioFallbackTried {
            audioFallbackTried = true
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) fallback pair: Suspend und Resume nochmals (FMOD-Beispiel für gestörte Ausgabe)")
            CelesteProbe.suspendAudio(true, context: "fallback pair")
            if CelesteProbe.suspendAudio(false, context: "fallback pair") {
                audioSuspended = false
                audioResumePending = false
                audioFallbackTried = false
                return
            }
        }
        // Annahme: nach einem gescheiterten Resume ist FMOD weiterhin suspendiert.
        audioResumePending = true
        nextAudioRetryAt = now + 1
        c64Record("[c64-audio] tMs=\(LaunchClock.tMs) resume pending: mixerResume gescheitert, nächster Versuch in 1 s (trigger=\(trigger))")
    }

    /// Schleifenkopf bei laufendem Spiel: offene Ton-Versuche und Bitten des Hauptthreads.
    private func serviceAudioRetry() {
        guard CelesteProbe.ticksGame else { return }
        if let request = CelesteProbe.pauseState.takeAudioRetry() {
            if audioSuspended || request.mediaServicesReset {
                c64Record("[c64-audio] tMs=\(LaunchClock.tMs) audio retry trigger=\(request.trigger)")
                resumeAudioIfPossible(trigger: request.trigger, mediaServicesReset: request.mediaServicesReset)
                resumeTicksIfAudioRunning(reason: "audio retry \(request.trigger)")
            }
            return
        }
        if audioResumePending, CFAbsoluteTimeGetCurrent() >= nextAudioRetryAt {
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) audio retry trigger=periodic")
            resumeAudioIfPossible(trigger: "periodic")
            resumeTicksIfAudioRunning(reason: "audio retry periodic")
        }
    }

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
    // M4b.2: Near-Ebene des Layers einmal an Celeste gemeldet (vor dem ersten Update auf dem Render-Thread).
    private var depthNearSent = false
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

    // Leinwand (M4a.2, C64_CELESTE=canvas): Textur vom Host, Szene lazy auf dem Render-Thread.
    // Mit Leinwand cleart der Grund-Pass die Tiefe auf 0,0001 (1000 m, hinter der Leinwand in
    // 500 m) statt 0 («kein Inhalt»), damit der Rand eigenes Schwarz ist und nicht Durchsicht.
    private let canvasRequested: Bool
    private let canvasTexture: MTLTexture?
    private var canvasScene: CanvasScene?
    private var canvasFailed = false
    private static let canvasClearDepth = 0.0001

    // GPU-Zeit der Gerüst-Command-Buffer (gpuEndTime − gpuStartTime) aus dem Completed-Handler,
    // hinter cmdErrLock; der Render-Thread liest und nullt pro Sekunde.
    private var gpuTimeSum = 0.0
    private var gpuTimeMax = 0.0
    private var gpuTimeCount = 0

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
    // K3 (C64_KIT=multiview mit C64_FOVEATION=1): Messbild gegen die Compositor-Map einmal pro
    // Sekunde; maximale Abweichung in physischen Pixeln über den Lauf.
    private var fovMeasureLast: CFAbsoluteTime = 0
    private var fovMeasureCount = 0
    private var fovMaxDevPx: Float = 0
    private var fovMeanDevSum: Double = 0
    private var fovMeasureMsSum: Double = 0
    // Bildrate über den ganzen Lauf (Intervalle aus presentationTime), für die Zusammenfassung.
    private var intervalTotalSum = 0.0
    private var intervalTotalCount = 0
    private var statSdlFail = 0               // Frames im Fenster, in denen SDL scheiterte
    private var sdlFailTotal = 0
    private var footprintStartMB = 0.0        // phys_footprint beim Start der Schleife, in jedem Modus
    private var availableStartMB = 0.0        // os_proc_available_memory beim Start der Schleife
    // Letzter Stand von Drawable und Map für die Zusammenfassung (Render Quality 1,0: Texturen für
    // maxRenderQuality, Map wächst während des Übergangs).
    private var lastDrawableSize: (width: Int, height: Int) = (0, 0)
    private var lastMapSizes: (screenW: Int, screenH: Int, physW: Int, physH: Int) = (0, 0, 0, 0)
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
    // K4a (C64_KIT_MSAA=<Samples>, Standard aus): Kantenglättung im Kit-Pass; die Sitzung rendert in
    // MSAA-Texturen in Drawable-Grösse und löst Farbe und Tiefe in die Drawable-Schichten auf.
    private let kitMsaaSamples: Int = Int(ProcessInfo.processInfo.environment["C64_KIT_MSAA"] ?? "") ?? 0
    // K4b (C64_KIT_MEMORYLESS=1, Standard aus): MSAA-Ziele memoryless (nur Tile-Speicher).
    private let kitMemoryless: Bool = ProcessInfo.processInfo.environment["C64_KIT_MEMORYLESS"] == "1"
    // K4c (C64_KIT_DEPTH_STORE=store|dontcare, Standard nicht gesetzt): store_op der privaten
    // MSAA-Tiefe im Kit-Pass und Tiefenprobe (zweiter Pass in eigene 1x-Zweischichttexturen,
    // Rücklesen beider Schichten, step=depth-probe). Verlangt C64_KIT_MSAA und, bei store,
    // C64_KIT_MEMORYLESS aus; unbekannte Werte werden geloggt und ignoriert.
    private let kitDepthStore: String? = ProcessInfo.processInfo.environment["C64_KIT_DEPTH_STORE"]

    @MainActor
    private init(layerRenderer: LayerRenderer, appModel: AppModel) {
        self.layerRenderer = layerRenderer
        self.appModel = appModel
        self.device = layerRenderer.device
        // M4a: hat der Host schon Device und Queue (Celeste-Modi init, tick, canvas), nimmt der
        // Renderer dieselbe Queue; dann laufen SDLs Command Buffer (Celestes Bild) und die
        // Gerüst-Buffer in Commit-Reihenfolge, und der Leinwand-Pass liest das fertige Bild.
        if let shared = CelesteProbe.commandQueue {
            let hostDevice = CelesteProbe.device
            let same = hostDevice.map { $0 === layerRenderer.device } ?? false
            self.commandQueue = shared
            c64Record("[c64-canvas] queue shared=1 label=\"\(shared.label ?? "")\" layerDevice=\(Unmanaged.passUnretained(layerRenderer.device).toOpaque()) hostDevice=\(hostDevice.map { "\(Unmanaged.passUnretained($0).toOpaque())" } ?? "nil") same=\(same ? 1 : 0)")
            if !same {
                c64Record("[c64-canvas] WARNUNG: LayerRenderer-Device und Host-Device sind verschieden; Texturen des einen sind auf dem anderen ungültig")
            }
        } else {
            guard let queue = device.makeCommandQueue() else {
                fatalError("MTLCommandQueue konnte nicht erzeugt werden")
            }
            queue.label = "c64-render-queue"
            self.commandQueue = queue
        }
        self.canvasRequested = CelesteProbe.canvasWanted
        self.canvasTexture = CelesteProbe.canvasTexture
        self.stallPlan = StallPlan.fromEnvironment()
    }

    /// Render Quality des Produkts (M4a.5b): 1,0 mit Foveation; C64_RENDERQUALITY überschreibt.
    static let defaultRenderQuality: Float = 1.0

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

    /// Startet die Session mit dem WorldTrackingProvider und beobachtet ihre Ereignisse
    /// (M4a.5b-2: beim Start direkt in den Raum blieb der Provider ohne sichtbaren Grund nicht
    /// im Zustand running, der Device Anchor kam nie). Jede Zustandsänderung geht in die
    /// Probe-Datei; endet der Provider mit Fehler, folgt ein neuer Versuch mit einem neuen
    /// Provider (höchstens arMaxRunAttempts, 1 s Abstand).
    private func startARSession() async {
        Task { [self] in
            for await event in arSession.events {
                switch event {
                case .dataProviderStateChanged(_, let newState, let error):
                    let lifecycle = await MainActor.run { CelesteProbe.lifecycleLine }
                    c64Record("[c64-arkit] tMs=\(LaunchClock.tMs) provider state=\(Self.name(newState))\(error.map { " error=\"\($0)\"" } ?? "") \(lifecycle)")
                    CelesteProbe.AliveProbe.shared.setProviderState(Self.name(newState))
                    if newState == .stopped, error != nil {
                        try? await Task.sleep(for: .seconds(1))
                        await runARSession(reason: "provider stopped with error")
                    }
                case .authorizationChanged(let type, let status):
                    c64Record("[c64-arkit] authorization \(type) -> \(status)")
                default:
                    c64Record("[c64-arkit] event \(event)")
                }
            }
        }
        await runARSession(reason: "start")
    }

    private func runARSession(reason: String) async {
        let (attempt, provider) = arLock.withLock { () -> (Int, WorldTrackingProvider) in
            arRunAttempts += 1
            if arRunAttempts > 1 {
                worldTrackingStorage = WorldTrackingProvider()
            }
            return (arRunAttempts, worldTrackingStorage)
        }
        guard attempt <= Self.arMaxRunAttempts else {
            c64Record("[c64-arkit] run attempt \(attempt) skipped (\(reason)): limit \(Self.arMaxRunAttempts) reached, no pose")
            return
        }
        do {
            let before = await MainActor.run { CelesteProbe.lifecycleLine }
            c64Record("[c64-arkit] tMs=\(LaunchClock.tMs) run attempt \(attempt) (\(reason)) layer=\(Self.name(layerRenderer.state)) \(before)")
            try await arSession.run([provider])
            c64Record("[c64-arkit] run attempt \(attempt) returned (\(reason)) state=\(Self.name(provider.state)) supported=\(WorldTrackingProvider.isSupported)")
            CelesteProbe.AliveProbe.shared.setProviderState(Self.name(provider.state))
        } catch {
            // Ohne Pose wird trotzdem präsentiert (Schwarz ohne Anker); das Log zeigt es.
            c64Record("[c64-arkit] run attempt \(attempt) failed (\(reason)): \(error)")
        }
    }

    private static func name(_ state: DataProviderState) -> String {
        switch state {
        case .initialized: return "initialized"
        case .running: return "running"
        case .paused: return "paused"
        case .stopped: return "stopped"
        @unknown default: return "state\(state)"
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
            + " debugger=\(ProbeContext.debuggerAttached ? 1 : 0)"
            + " truncated=\(ProgressFile.truncateOnStart ? 1 : 0)"
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
            + " C64_KIT_MSAA=\(ProbeContext.environment("C64_KIT_MSAA"))"
            + " C64_KIT_MEMORYLESS=\(ProbeContext.environment("C64_KIT_MEMORYLESS"))"
            + " C64_KIT_DEPTH_STORE=\(ProbeContext.environment("C64_KIT_DEPTH_STORE"))"
            + " C64_CELESTE=\(ProbeContext.environment(CelesteProbe.environmentKey))"
            + " C64_RES=\(ProbeContext.environment("C64_RES"))"
            + " C64_LINE=\(ProbeContext.environment("C64_LINE"))"
            + " views=\(layerRenderer.properties.viewCount)"
            + " stallSeq=\(stallPlan.isEmpty ? "-" : stallPlan.map { String(Int($0 * 1000)) }.joined(separator: ","))"
        c64Record(line)
    }

    // MARK: Schleife

    private func renderLoop() {
        let start = CFAbsoluteTimeGetCurrent()
        statWindowStart = start
        nextStallAt = start + Self.stallSpacing
        c64Record("[c64-loop] tMs=\(LaunchClock.tMs) Renderschleife gestartet, thread=\(Thread.current.name ?? "?")")
        // M4a.5c-6: Layer-Zustand für die Lebenszeichen-Sonde (cp_layer_renderer_get_state, ohne Lock).
        CelesteProbe.AliveProbe.shared.setLayerStateReader { [layerRenderer] in Self.name(layerRenderer.state) }
        if CelesteProbe.ticksGame {
            CelesteProbe.tickState.resume(reason: "render loop started")
        }

        // Kit-Stufe K1a (C64_KIT=inject): einmal vor dem ersten Frame, mit dem Device des
        // Layer-Renderers und der Queue dieses Gerüsts. SDL_Init lief im Hauptthread (GameStartup).
        if KitProbe.mode == .inject {
            runKitInjectProbe()
        }
        // Speicher am Anfang der Schleife, in jedem Modus (Vergleichswert für die Zusammenfassung).
        footprintStartMB = ProbeContext.physFootprintMB
        availableStartMB = ProbeContext.availableMemoryMB
        c64Record("[c64-loop] footprintStartMB=\(String(format: "%.1f", footprintStartMB)) availableMB=\(String(format: "%.1f", availableStartMB)) C64_KIT=\(ProbeContext.environment(KitProbe.environmentKey))")
        // Kit-Stufe K1b (C64_KIT=import): Sitzung für die ganze Schleife.
        if KitProbe.mode == .import {
            kitImportSession = KitProbe.beginImport(device: device, queue: commandQueue)
            kitImportFailed = (kitImportSession == nil)
            c64Record("[c64-kit] import session=\(kitImportSession == nil ? "FEHLT, Gerüst löscht selbst" : "ok")")
        }
        // Kit-Stufe K2 (C64_KIT=multiview): Sitzung mit Pipeline view_count 2 für die ganze Schleife.
        if KitProbe.mode == .multiview {
            kitMultiviewSession = KitProbe.beginMultiview(device: device, queue: commandQueue, msaaSamples: kitMsaaSamples, memoryless: kitMemoryless,
                                                          depthStore: kitDepthStore)
            kitImportFailed = (kitMultiviewSession == nil)
            c64Record("[c64-kit] multiview session=\(kitMultiviewSession == nil ? "FEHLT, Gerüst löscht selbst" : "ok")")
        }

        while true {
            switch layerRenderer.state {
            case .invalidated:
                c64Record("[c64-loop] Layer invalidiert, Schleife endet nach \(totalFrames) Frames")
                logLoopSummary()
                if CelesteProbe.ticksGame {
                    // M4a.5a: der geschlossene Raum (Digital Crown) beendet die App sauber:
                    // Ticks stoppen, celeste_end auf dem Hauptthread, exit(0). Ohne Fensterszene
                    // gäbe es sonst keinen sauberen Neustart, solange Celeste im Prozess lebt.
                    CelesteProbe.requestExit(reason: "layer invalidated")
                }
                Task { @MainActor [appModel] in
                    appModel.immersiveState = .closed
                    appModel.statusLine = "ImmersiveSpace geschlossen."
                }
                return
            default:
                break
            }
            // M4a.5c-2: Pause, wenn der Layer nicht läuft oder die App im Hintergrund ist.
            if shouldPause {
                pauseBranch()
                continue
            }
            // Flag war im letzten Frame kurz gesetzt, aber am Schleifenanfang schon wieder weg:
            // Notiz verwerfen, sonst würde sie der nächsten Pause zugeschrieben.
            pauseFrameNote = nil
            serviceAudioRetry()

            // Stall-Probe: VOR queryNextFrame, also ohne angefangenen Frame.
            stallIfDue()
            if arkitPeriodicRemaining > 0 {
                let now = CFAbsoluteTimeGetCurrent()
                if now >= arkitPeriodicNextAt {
                    arkitPeriodicNextAt = (arkitPeriodicNextAt == 0 ? now : arkitPeriodicNextAt) + 1
                    arkitPeriodicRemaining -= 1
                    c64Record("[c64-arkit] tMs=\(LaunchClock.tMs) periodic provider state=\(Self.name(worldTracking.state)) layer=\(Self.name(layerRenderer.state)) frames=\(totalFrames)")
                }
            }

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
        // K3: Map des Compositors an den SDL-Pass, wenn Foveation an ist (sonst wie K2).
        let rateMap = layerRenderer.configuration.isFoveationEnabled ? drawable.rasterizationRateMaps.first : nil
        let ok = KitProbe.multiviewFrame(session: session,
                                         color: drawable.colorTextures[index],
                                         depth: drawable.depthTextures[index],
                                         rgba: Self.importClearColor,
                                         depthClear: importClearDepth,
                                         quad: quad,
                                         viewProjection: matrices,
                                         rateMap: rateMap)
        if ok, let rateMap {
            measureFoveationIfDue(session: session, rateMap: rateMap)
        }
        return ok
    }

    /// K3: einmal pro Sekunde das Messbild gegen die Compositor-Map (eigene Textur, kostet einen
    /// Pass plus Rücklesen mit Warten); erste Messung ausführlich mit allen Stichproben.
    private func measureFoveationIfDue(session: OpaquePointer, rateMap: MTLRasterizationRateMap) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - fovMeasureLast >= 1.0 else { return }
        fovMeasureLast = now
        let verbose = fovMeasureCount == 0
        guard let m = KitProbe.multiviewMeasure(session: session, rateMap: rateMap, verbose: verbose) else {
            c64Record("[c64-kit] step=fov-measure FAIL (Messbild nicht gerendert oder nicht gelesen)")
            return
        }
        fovMeasureCount += 1
        fovMeanDevSum += Double(m.mean_dev_px)
        fovMeasureMsSum += m.ms
        let newMax = m.max_dev_px > fovMaxDevPx
        fovMaxDevPx = max(fovMaxDevPx, m.max_dev_px)
        if verbose || newMax {
            c64Record(String(format: "[c64-kit] step=fov-measure n=%d samples=%u maxDevPx=%.3f meanDevPx=%.3f screen=%ux%u physical=%ux%u layers=%u ms=%.2f runMax=%.3f",
                             fovMeasureCount, m.samples, m.max_dev_px, m.mean_dev_px, m.screen_width, m.screen_height,
                             m.physical_width, m.physical_height, m.layers, m.ms, fovMaxDevPx))
        }
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
            // K4a: GPU-Zeit der SDL-Command-Buffer (Completed-Rückruf, ohne die ersten 90 Frames:
            // Mittel, p95, Maximum) und MSAA-Stand.
            var gpuCount: UInt32 = 0
            var gpuMean = 0.0, gpuP95 = 0.0, gpuMax = 0.0
            kit_multiview_gpu_percentiles(session, &gpuCount, &gpuMean, &gpuP95, &gpuMax)
            let filterNames = ["sample0", "min", "max"]
            let filter = Int(stats.depth_filter) < filterNames.count ? filterNames[Int(stats.depth_filter)] : "?"
            kitPart += String(format: " gpu(ms, ab Frame 91) n=%u mean=%.3f p95=%.3f max=%.3f untagged=%lu gpuErr=%lu msaa=%u memoryless=%u msaaTextures=%ux%ux%u msaaNominalMB=%.1f msaaAllocatedMB=%@ measureMsaaNominalMB=%.1f depthResolveFilter=%@ depthStore=%@ depthProbes=%lu",
                              gpuCount, gpuMean, gpuP95, gpuMax,
                              stats.gpu_untagged, stats.gpu_errors, stats.msaa_samples, stats.memoryless, stats.msaa_width, stats.msaa_height, stats.msaa_layers,
                              Double(stats.msaa_nominal_bytes) / (1024 * 1024),
                              stats.memoryless == 1 ? "-" : String(format: "%.1f", Double(stats.msaa_bytes) / (1024 * 1024)),
                              Double(stats.measure_msaa_nominal_bytes) / (1024 * 1024),
                              stats.msaa_samples > 1 ? filter : "-",
                              stats.msaa_samples > 1 ? (stats.depth_store == 1 ? "store" : "dontcare") : "-",
                              stats.probes_total)
            if stats.msaa_samples > 1 {
                kit_multiview_log_containers(session)
            }
            KitProbe.endMultiview(session: session)
            kitMultiviewSession = nil
        } else if kitImportFailed {
            kitPart = " sdlFail=\(sdlFailTotal) session=none"
        }
        let footprintEnd = ProbeContext.physFootprintMB
        cmdErrLock.lock()
        let cmdErr = cmdErrTotal
        let cmdSkipped = cmdSkippedTotal
        let cmdErrExpected = cmdErrExpectedTotal
        cmdErrLock.unlock()
        let mode = KitProbe.mode?.rawValue ?? "-"
        // Bildrate über den Lauf: mittleres Intervall aus presentationTime und daraus Hz.
        let meanInterval = intervalTotalCount > 0 ? intervalTotalSum / Double(intervalTotalCount) : 0
        let hz = meanInterval > 0 ? 1.0 / meanInterval : 0
        var fovPart = ""
        if fovMeasureCount > 0 {
            fovPart = String(format: " fov{measurements=%d maxDevPx=%.3f meanDevPx=%.3f measureMs=%.2f}",
                             fovMeasureCount, fovMaxDevPx, fovMeanDevSum / Double(fovMeasureCount), fovMeasureMsSum / Double(fovMeasureCount))
        }
        // Render Quality: angefordert (Schalter), Obergrenze der Konfiguration, tatsächlich am Ende;
        // dazu Drawable- und Map-Grösse des letzten Frames und der verfügbare Speicher.
        let requestedQuality = ProcessInfo.processInfo.environment["C64_RENDERQUALITY"] ?? "-"
        let qualityPart = String(format: " renderQuality{requested=%@ max=%.3f end=%.3f} drawable=%dx%d map{screen=%dx%d physical=%dx%d}",
                                 requestedQuality, layerRenderer.configuration.maxRenderQuality.rawValue, layerRenderer.renderQuality.rawValue,
                                 lastDrawableSize.width, lastDrawableSize.height,
                                 lastMapSizes.screenW, lastMapSizes.screenH, lastMapSizes.physW, lastMapSizes.physH)
        let availableEnd = ProbeContext.availableMemoryMB
        c64Record(String(format: "[c64-loop] summary C64_KIT=%@ foveation=%d%@ frames=%llu interval(ms) mean=%.3f rate=%.1f Hz cancelled=%d cmdErr=%d cmdErrExpectedInBackground=%d cmdSkipped=%d footprintMB start=%.1f end=%.1f delta=%+.1f availableMB start=%.1f end=%.1f%@%@",
                         mode, layerRenderer.configuration.isFoveationEnabled ? 1 : 0, qualityPart, totalFrames, meanInterval * 1000, hz,
                         cancelledTotal, cmdErr, cmdErrExpected, cmdSkipped, footprintStartMB, footprintEnd, footprintEnd - footprintStartMB,
                         availableStartMB, availableEnd, kitPart, fovPart))
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

    // MARK: Stereo-Weltpass (M4b.3a)

    /// Frame-Daten für celeste_render_frame_vr aus dem Drawable: Farb- und Tiefentextur (eine
    /// 2D-Array-Textur für beide Views, Layout .layered), die Rate Map des Compositors mit
    /// logischer und physischer Grösse, die Projektion je View aus computeProjection (16 Floats,
    /// Spaltenreihenfolge wie simd; Celeste setzt ihre Near-Ebene in Einheiten selbst), die
    /// View-Transformationen (für M4b.4) und die Near-Ebene des Layers. false, wenn das Drawable
    /// nicht die Form hat (weniger als zwei Views oder keine Array-Textur).
    private static func fillVRFrame(_ frame: inout celeste_vr_frame, drawable: LayerRenderer.Drawable,
                                    deviceAnchor: DeviceAnchor?, configuration: LayerRenderer.Configuration) -> Bool {
        let views = drawable.views
        guard views.count >= 2 else { return false }
        let index = views[0].textureMap.textureIndex
        guard views[1].textureMap.textureIndex == index else { return false }
        let color = drawable.colorTextures[index]
        let depth = drawable.depthTextures[index]
        guard color.textureType == .type2DArray, color.arrayLength >= 2 else { return false }
        frame.size = Int32(MemoryLayout<celeste_vr_frame>.size)
        frame.view_count = 2
        frame.color_texture = Unmanaged.passUnretained(color).toOpaque()
        frame.depth_texture = Unmanaged.passUnretained(depth).toOpaque()
        frame.width = Int32(color.width)
        frame.height = Int32(color.height)
        frame.color_srgb = (color.pixelFormat == .bgra8Unorm_srgb || color.pixelFormat == .rgba8Unorm_srgb) ? 1 : 0
        if configuration.isFoveationEnabled, let map = drawable.rasterizationRateMaps.first {
            frame.rasterization_rate_map = Unmanaged.passUnretained(map).toOpaque()
            frame.logical_width = Int32(map.screenSize.width)
            frame.logical_height = Int32(map.screenSize.height)
            let physical = map.physicalSize(layer: 0)
            frame.physical_width = Int32(physical.width)
            frame.physical_height = Int32(physical.height)
        } else {
            frame.rasterization_rate_map = nil
            frame.logical_width = frame.width
            frame.logical_height = frame.height
            frame.physical_width = frame.width
            frame.physical_height = frame.height
        }
        let anchorTransform = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        for slot in 0..<2 {
            var projection = drawable.computeProjection(viewIndex: slot)
            var viewTransform = anchorTransform * views[slot].transform
            withUnsafeMutableBytes(of: &frame.projection) { dst in
                withUnsafeBytes(of: &projection) { src in
                    dst.baseAddress!.advanced(by: slot * 64).copyMemory(from: src.baseAddress!, byteCount: 64)
                }
            }
            withUnsafeMutableBytes(of: &frame.view_transform) { dst in
                withUnsafeBytes(of: &viewTransform) { src in
                    dst.baseAddress!.advanced(by: slot * 64).copyMemory(from: src.baseAddress!, byteCount: 64)
                }
            }
        }
        frame.near_meters = Double(configuration.defaultDepthRange.y)
        return true
    }

    private var lastStereoRc: Int32 = -3
    private var stereoWorldFrames = 0

    /// [c64-stereo]: der erste Welt-Frame und jeder Wechsel zwischen Welt (1) und Leinwand (0).
    private func noteStereoFrame(rc: Int32, frame: celeste_vr_frame, frameIndex: UInt64) {
        if rc == 1 { stereoWorldFrames += 1 }
        guard rc != lastStereoRc else { return }
        lastStereoRc = rc
        c64Record("[c64-stereo] tMs=\(LaunchClock.tMs) frame=\(frameIndex) rc=\(rc) (\(rc == 1 ? "Welt im Drawable" : rc == 0 ? "Leinwand" : "kein Render")) drewWorld=\(frame.drew_world) flushes=\(frame.flushes) texture=\(frame.width)x\(frame.height) logical=\(frame.logical_width)x\(frame.logical_height) physical=\(frame.physical_width)x\(frame.physical_height) srgb=\(frame.color_srgb) map=\(frame.rasterization_rate_map != nil ? 1 : 0) near=\(String(format: "%.3f", frame.near_meters)) worldFrames=\(stereoWorldFrames)")
    }

    /// M4b.2: Near-Ebene der Layer-Konfiguration (defaultDepthRange: x = far, y = near, Meter,
    /// layer_renderer_configuration.h:386-414, nur Reverse-Z) an Celeste. Nur wenn der Reverse-Z-Pfad
    /// an ist (C64_REVERSE_Z); sonst eine Logzeile mit dem gelesenen Wert.
    private func sendDepthNear() {
        let range = layerRenderer.configuration.defaultDepthRange
        guard CelesteProbe.reverseZ else {
            c64Record("[c64-depth] tMs=\(LaunchClock.tMs) reverseZ=0 (Referenzpfad), layer defaultDepthRange " + String(format: "far=%.3f near=%.3f", range.x, range.y))
            return
        }
        let rc = celeste_set_depth_near(Double(range.y))
        let error = rc == 0 ? "" : (celeste_last_error().map { " error=\"\(String(cString: $0))\"" } ?? "")
        c64Record("[c64-depth] tMs=\(LaunchClock.tMs) layer defaultDepthRange " + String(format: "far=%.3f near=%.3f m", range.x, range.y) + " -> celeste_set_depth_near rc=\(rc)\(error)")
    }

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else {
            // Kein Frame verfügbar (pausiert, invalidiert oder zu viele in Arbeit): kurz warten.
            Thread.sleep(forTimeInterval: 0.001)
            return
        }

        // Wanduhr-Intervall seit der letzten Rückkehr von queryNextFrame.
        let queryReturn = CFAbsoluteTimeGetCurrent()
        var frameInterval: TimeInterval?
        if let last = lastQueryReturn {
            let wall = queryReturn - last
            frameInterval = wall
            statWallMin = min(statWallMin, wall)
            statWallMax = max(statWallMax, wall)
            statWallSum += wall
            statWallCount += 1
        }
        lastQueryReturn = queryReturn

        // Update-Phase: Celestes Tick (M1a.5, C64_CELESTE=tick), ein Update und ein Render in
        // Celestes eigene Ziele pro Frame, present 0; Delta ist der Frame-Takt. Noch kein Bild in
        // die Drawables, die kommen erst nach startSubmission (M4a verschiebt den Render-Teil
        // dorthin oder reicht die Drawable-Texturen vorher als Ausgabeziele).
        frame.startUpdate()
        // M4b.1: nur die Update-Hälfte (celeste_update); die Render-Hälfte folgt nach dem Device
        // Anchor (renderCelesteThisFrame). M4a.5c-4: Ist die App beim Erreichen des Updates schon
        // im Hintergrund, entfällt der Tick dieses Frames (SDL würde zwei Command Buffer im
        // Hintergrund committen); der Frame wird trotzdem mit der Leinwand des letzten Bildes
        // fertig präsentiert, die Pause folgt am Schleifenanfang.
        var renderCelesteThisFrame = false
        let backgroundAtTick = CelesteProbe.pauseState.isBackground
        if backgroundAtTick {
            pauseFrameNote = PauseFrameNote(frameIndex: frame.frameIndex, flagSeen: "before-update", tickSkipped: true, renderSkipped: true, committed: false, presented: false)
        } else if audioSuspended {
            // M4a.5c-2: kein celeste_tick bei angehaltenem Mixer; der Frame wird trotzdem
            // präsentiert (Leinwand mit dem letzten Bild).
            ticksSkippedForAudio += 1
            if ticksSkippedForAudio == 1 {
                c64Record("[c64-celeste] tMs=\(LaunchClock.tMs) Tick ausgelassen, Mixer angehalten; Schleife präsentiert weiter")
            }
        } else if CelesteProbe.ticksGame {
            // M4b.2: vor dem ersten Update auf diesem Thread die Near-Ebene des Layers an Celeste
            // (celeste_set_depth_near, Meter); Celeste rechnet sie an einer Stelle in Einheiten um.
            if !depthNearSent {
                depthNearSent = true
                sendDepthNear()
            }
            renderCelesteThisFrame = CelesteProbe.tickState.update(frameInterval: frameInterval)
        }
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
        rememberSizes(drawables)

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
        // M4a.5c-4: nach dem Fortsetzen die ersten drei Frames mit Buffer-Status loggen.
        let logResume = resumeFramesToLog > 0
        if logResume { resumeFramesToLog -= 1 }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            self?.noteCommandBufferCompletion(buffer, frameIndex: frameIndexForHandler, logResume: logResume)
        }

        // Pose und Timing aus dem Drawable für das eingebaute Display (target builtIn,
        // drawable.h:36-44, Vorrang laut drawable.h:428-429), Rückfall auf das erste.
        // Fehlt die Pose (ARKit noch nicht bereit), wird trotzdem Schwarz präsentiert, nur
        // ohne Anker. Der Anker wird auf alle Drawables gesetzt.
        let primary = drawables.first(where: { $0.target == .builtIn }) ?? drawables[0]
        let presentationTime = primary.frameTiming.presentationTime.timeInterval
        // presentationTime relativ zur Compositor-Uhr beim Erhalt der Drawables (gleiche Zeitbasis).
        let relativeToNow = presentationTime - LayerRenderer.Clock().now.timeInterval
        // Nur ein laufender Provider liefert Anker; sonst ohne Abfrage (keine Konsolenfehler),
        // der Frame zählt als noAnchor, und eine Zeile je Zustandswechsel zeigt den Grund.
        let provider = worldTracking
        let providerState = provider.state
        if providerState != lastLoggedProviderState {
            lastLoggedProviderState = providerState
            c64Record("[c64-arkit] render thread sees provider state=\(Self.name(providerState)) frame=\(totalFrames)")
        }
        let deviceAnchor = providerState == .running ? provider.queryDeviceAnchor(atTimestamp: presentationTime) : nil
        if let deviceAnchor {
            // M4b.1b: letzte Kopfpose für die [c64-recenter]-Zeile (Diagnose, Vorbereitung M4b.4).
            CelesteProbe.headPose.set(anchor: deviceAnchor.originFromAnchorTransform)
        }

        // M4b.1: Celestes Render-Hälfte nach dem Device Anchor, unmittelbar vor dem Encodieren;
        // SDL committet seine Buffer auf der gemeinsamen Queue vor dem Host-Buffer. Kein Render
        // ohne Update in diesem Frame (Pause, Mixer angehalten, Flag gesetzt).
        // M4b.3a: mit Stereo-Weltpass bekommt Celeste das Drawable (Texturen, Map, Projektionen
        // je Auge); Rückgabe 1 heisst, die Welt steht im Drawable, das Gerüst löscht und zeichnet
        // dort nichts mehr. Rückgabe 0: Leinwand wie bisher.
        var celesteRenderedThisFrame = false
        var worldDrawnThisFrame = false
        if renderCelesteThisFrame {
            if CelesteProbe.pauseState.isBackground {
                // Flag kam zwischen Update und Render: Celestes Render entfällt (keine
                // SDL-Buffer im Hintergrund), die Leinwand zeigt das letzte Bild, der Frame
                // wird fertig präsentiert.
                pauseFrameNote = PauseFrameNote(frameIndex: frame.frameIndex, flagSeen: "after-update", tickSkipped: false, renderSkipped: true, committed: false, presented: false)
            } else {
                celesteRenderedThisFrame = true
                var worldFrame = celeste_vr_frame()
                if CelesteProbe.stereoWorld,
                   Self.fillVRFrame(&worldFrame, drawable: primary, deviceAnchor: deviceAnchor, configuration: layerRenderer.configuration) {
                    let rc = CelesteProbe.tickState.renderVR(&worldFrame)
                    worldDrawnThisFrame = rc == 1
                    noteStereoFrame(rc: rc, frame: worldFrame, frameIndex: frame.frameIndex)
                } else {
                    CelesteProbe.tickState.render()
                }
            }
        }
        // Frame ohne Celeste-Render auf dem Stereo-Pfad (Laden, Pause, Flag): Drawable opak
        // schwarz nach der Frame-Regel, nie alter Inhalt und keine Leinwand mit altem Bild.
        let blackOnly = CelesteProbe.stereoWorld && CelesteProbe.ticksGame && !celesteRenderedThisFrame
        let primaryColor = primary.colorTextures.first

        for drawable in drawables {
            if let anchor = deviceAnchor {
                drawable.deviceAnchor = anchor
            }
            if worldDrawnThisFrame, let primaryColor, drawable.colorTextures.first === primaryColor {
                // Celeste hat dieses Drawable geschrieben (beide Schichten, Tiefe kopiert)
                continue
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
            encodeClearPasses(drawable: drawable, commandBuffer: commandBuffer, deviceAnchor: deviceAnchor, blackOnly: blackOnly)
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
        // M4a.5c-4: immer committen und präsentieren, auch im Hintergrund (Vice City). Ein
        // Present ohne Commit liess das Drawable hängen, der nächste Host-Buffer lief in den
        // GPU-Timeout. Der eine Host-Buffer im Hintergrund darf vom System abgelehnt werden
        // (BackgroundExecutionNotPermitted), das zählt als erwartet.
        if CelesteProbe.pauseState.isBackground {
            if pauseFrameNote == nil {
                pauseFrameNote = PauseFrameNote(frameIndex: frame.frameIndex, flagSeen: "after-render", tickSkipped: false, renderSkipped: false, committed: false, presented: false)
            }
            cmdErrLock.lock()
            backgroundCommitFrame = frame.frameIndex
            cmdErrLock.unlock()
        }
        commandBuffer.commit()
        frame.endSubmission()
        if pauseFrameNote?.frameIndex == frame.frameIndex {
            pauseFrameNote?.committed = true
            pauseFrameNote?.presented = true
        }

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
    private func encodeClearPasses(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer, deviceAnchor: DeviceAnchor?, blackOnly: Bool = false) {
        // M4b.3a, blackOnly: nur der opake schwarze Clear (Tiefe 1000 m, eigener Inhalt), keine
        // Leinwand und keine Testszene (Frame ohne Celeste-Render auf dem Stereo-Pfad)
        let scene = blackOnly ? nil : currentTestScene()
        let canvas = blackOnly ? nil : currentCanvasScene()
        let maps = layerRenderer.configuration.isFoveationEnabled ? drawable.rasterizationRateMaps : []
        let views = drawable.views
        guard let firstView = views.first else { return }
        let isArray = drawable.colorTextures[firstView.textureMap.textureIndex].textureType == .type2DArray
        let clearDepth = canvasRequested || blackOnly ? Self.canvasClearDepth : 0.0
        canvas?.logEyesOnce(drawable: drawable, views: views, maps: maps)

        if isArray, views.count > 1 {
            let baseSlice = views.map { $0.textureMap.sliceIndex }.min() ?? 0
            let descriptor = Self.clearDescriptor(color: drawable.colorTextures[firstView.textureMap.textureIndex],
                                                  depth: drawable.depthTextures[firstView.textureMap.textureIndex],
                                                  slice: baseSlice, clearDepth: clearDepth)
            descriptor.renderTargetArrayLength = views.count
            if let map = maps.first {
                descriptor.rasterizationRateMap = map
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                c64Log.error("[c64-frame] makeRenderCommandEncoder lieferte nil (layered, \(views.count) Schichten)")
                return
            }
            encoder.label = "c64-clear layered x\(views.count)"
            // Testszene und Leinwand: beide Schichten in einem Draw, Amplification 2, Map bleibt am Pass.
            scene?.encode(encoder: encoder, drawable: drawable, views: Array(views.prefix(2)),
                          viewIndices: Array(0..<min(views.count, 2)), deviceAnchor: deviceAnchor)
            canvas?.encode(encoder: encoder, drawable: drawable, views: Array(views.prefix(2)),
                           viewIndices: Array(0..<min(views.count, 2)), deviceAnchor: deviceAnchor)
            encoder.endEncoding()
            return
        }

        for (viewIndex, view) in views.enumerated() {
            let textureMap = view.textureMap
            let descriptor = Self.clearDescriptor(color: drawable.colorTextures[textureMap.textureIndex],
                                                  depth: drawable.depthTextures[textureMap.textureIndex],
                                                  slice: textureMap.sliceIndex, clearDepth: clearDepth)
            if !maps.isEmpty {
                descriptor.rasterizationRateMap = textureMap.textureIndex < maps.count ? maps[textureMap.textureIndex] : maps[0]
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                c64Log.error("[c64-frame] makeRenderCommandEncoder lieferte nil (view \(viewIndex))")
                continue
            }
            encoder.label = "c64-clear view\(viewIndex)"
            // Testszene und Leinwand bei .dedicated/.shared: pro View ein Draw ohne Amplification.
            scene?.encode(encoder: encoder, drawable: drawable, views: [view],
                          viewIndices: [viewIndex], deviceAnchor: deviceAnchor)
            canvas?.encode(encoder: encoder, drawable: drawable, views: [view],
                           viewIndices: [viewIndex], deviceAnchor: deviceAnchor)
            encoder.endEncoding()
        }
    }

    /// Leinwand beim ersten Bedarf erzeugen (Render-Thread); scheitert sie, bleibt sie aus.
    private func currentCanvasScene() -> CanvasScene? {
        guard canvasRequested, !canvasFailed else { return nil }
        if let canvasScene { return canvasScene }
        guard let texture = canvasTexture else {
            canvasFailed = true
            c64Record("[c64-canvas] keine Leinwandtextur vom Host (prepareCanvas lief nicht), Leinwand bleibt aus")
            return nil
        }
        let config = layerRenderer.configuration
        let scene = CanvasScene(device: device,
                                colorFormat: config.colorFormat,
                                depthFormat: config.depthFormat,
                                viewCount: layerRenderer.properties.viewCount,
                                texture: texture,
                                fovDegrees: CelesteProbe.canvasFovDegrees,
                                nearest: CelesteProbe.canvasNearest)
        if scene == nil { canvasFailed = true }
        canvasScene = scene
        return scene
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

    private static func clearDescriptor(color colorTexture: MTLTexture, depth depthTexture: MTLTexture, slice: Int, clearDepth: Double = 0.0) -> MTLRenderPassDescriptor {
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
        depth.clearDepth = clearDepth   // 0 = «kein Inhalt» (Leerframe), mit Leinwand 0,0001 = 1000 m eigenes Schwarz
        return descriptor
    }

    // MARK: Foveation-Sonde (P0b)

    /// Render Quality zur Laufzeit setzen, einmal nach dem ersten Drawable. Nur mit Foveation
    /// und gesetzter Obergrenze; der Wert wird auf maxRenderQuality geklemmt, weil ein höherer
    /// Wert CompositorServices abbrechen lässt (Plattformwissen, Vice City [vc-rq]).
    private func applyRenderQualityIfRequested() {
        guard !renderQualityApplied else { return }
        renderQualityApplied = true
        // Standard 1,0 (M4a.5b), Schalter C64_RENDERQUALITY überschreibt.
        let wanted = ProcessInfo.processInfo.environment["C64_RENDERQUALITY"].flatMap({ Float($0) }) ?? Self.defaultRenderQuality
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

    /// Drawable- und Map-Grösse des Frames merken (für die Zusammenfassung; mit Render Quality
    /// ändert sich die Map in den ersten Frames, die Texturen bleiben bei maxRenderQuality).
    private func rememberSizes(_ drawables: [LayerRenderer.Drawable]) {
        guard let drawable = drawables.first(where: { $0.target == .builtIn }) ?? drawables.first,
              let texture = drawable.colorTextures.first else { return }
        lastDrawableSize = (texture.width, texture.height)
        if let map = drawable.rasterizationRateMaps.first {
            let p = map.physicalSize(layer: 0)
            lastMapSizes = (map.screenSize.width, map.screenSize.height, p.width, p.height)
        } else {
            lastMapSizes = (0, 0, 0, 0)
        }
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
    private func noteCommandBufferCompletion(_ buffer: MTLCommandBuffer, frameIndex: UInt64, logResume: Bool = false) {
        let status = buffer.status
        let error = buffer.error
        if status == .completed {
            let gpuSeconds = buffer.gpuEndTime - buffer.gpuStartTime
            if gpuSeconds > 0 {
                cmdErrLock.lock()
                gpuTimeSum += gpuSeconds
                gpuTimeMax = max(gpuTimeMax, gpuSeconds)
                gpuTimeCount += 1
                cmdErrLock.unlock()
            }
        }
        if logResume {
            // M4a.5c-4: die ersten drei Frames nach dem Fortsetzen, Status und GPU-Zeit.
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            let errorText = (error as NSError?).map { "\($0.domain) code=\($0.code) \($0.localizedDescription)" } ?? "-"
            c64Record("[c64-resume-frame] tMs=\(LaunchClock.tMs) frame=\(frameIndex) status=\(Self.name(status)) gpuMs=\(String(format: "%.2f", gpuMs)) error=\(errorText)")
        }
        guard status != .completed || error != nil else { return }
        // M4a.5c-4: der eine Host-Buffer, der bei gesetztem Hintergrund-Flag committet wurde,
        // darf vom System abgelehnt werden (MTLCommandBufferError.notPermitted, «Insufficient
        // Permission (to submit GPU work from background)»). Erwartet, eigener Zähler, immer eine
        // Zeile; Timeout und andere Fehler wie bisher.
        if let nsError = error as NSError?, nsError.domain == MTLCommandBufferErrorDomain,
           nsError.code == MTLCommandBufferError.notPermitted.rawValue {
            cmdErrLock.lock()
            let expected = backgroundCommitFrame == frameIndex
            if expected { cmdErrExpectedTotal += 1 }
            cmdErrLock.unlock()
            if expected {
                c64Record("[c64-cmderr] tMs=\(LaunchClock.tMs) frame=\(frameIndex) status=\(Self.name(status)) expectedInBackground=1 error=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
                return
            }
        }
        // M4a.5c-2: ein absichtlich nicht committeter Buffer (Pause vor dem Commit) meldet
        // notEnqueued ohne Fehler; das ist kein GPU-Fehler.
        if status == .notEnqueued, error == nil {
            cmdErrLock.lock()
            cmdSkippedTotal += 1
            cmdErrLock.unlock()
            return
        }

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
        // GPU-Timeouts um eine Pause (Host-Buffer, der beim Wechsel in den Hintergrund in der
        // GPU lag) werden hier nur notiert: Frame, Zeit, Status.
        c64Record("[c64-cmderr] tMs=\(LaunchClock.tMs) frame=\(frameIndex) status=\(Self.name(status)) error=\(errorText)")
    }

    /// GPU-Zeit der Gerüst-Buffer im Fenster lesen und nullen (Render-Thread, einmal pro Sekunde).
    private func takeGpuTime() -> (mean: Double, max: Double, count: Int) {
        cmdErrLock.lock()
        defer { cmdErrLock.unlock() }
        let result = (gpuTimeCount > 0 ? gpuTimeSum / Double(gpuTimeCount) : 0, gpuTimeMax, gpuTimeCount)
        gpuTimeSum = 0
        gpuTimeMax = 0
        gpuTimeCount = 0
        return result
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
                intervalTotalSum += interval
                intervalTotalCount += 1
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
            // GPU-Zeit der Gerüst-Buffer (Clear, Testszene, Leinwand; nicht SDLs eigene Buffer).
            let gpu = takeGpuTime()
            line += String(format: " hostGpu(ms) mean=%.3f max=%.3f n=%d", gpu.mean * 1000, gpu.max * 1000, gpu.count)
            // K1b: CPU-Zeit des SDL-Teils (Wrapper, Pässe, Submit, Release) im Fenster.
            if let session = kitImportSession {
                let stats = KitProbe.takeImportStats(session: session)
                let meanMs = stats.frames > 0 ? stats.sum_ms / Double(stats.frames) : 0
                line += String(format: " sdl(ms) mean=%.3f max=%.3f sdlFrames=%u sdlFail=%d", meanMs, stats.max_ms, stats.frames, statSdlFail)
            } else if let session = kitMultiviewSession {
                let stats = KitProbe.takeMultiviewStats(session: session)
                let meanMs = stats.frames > 0 ? stats.sum_ms / Double(stats.frames) : 0
                line += String(format: " sdl(ms) mean=%.3f max=%.3f sdlFrames=%u sdlFail=%d passes=%lu draws=%lu", meanMs, stats.max_ms, stats.frames, statSdlFail, stats.passes_total, stats.draws_total)
                // K4a: GPU-Zeit der SDL-Command-Buffer im Fenster (Completed-Rückruf).
                let gpuMean = stats.gpu_frames > 0 ? stats.gpu_sum_ms / Double(stats.gpu_frames) : 0
                line += String(format: " gpu(ms) mean=%.3f max=%.3f gpuFrames=%u msaa=%u", gpuMean, stats.gpu_max_ms, stats.gpu_frames, stats.msaa_samples)
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

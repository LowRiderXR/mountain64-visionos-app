//
//  Renderer.swift
//  AvpCeleste64
//
//  Render loop of the host on its own thread, after Apple's pattern: queryNextFrame, update,
//  wait until optimalInputTime (minus C64_EARLY_MS), queryDrawables, startSubmission, render,
//  encodePresent last, commit, endSubmission. Every frame that was started is completed.
//  Celeste runs in two halves per frame: celeste_update before the wait, the render half after
//  the device anchor. A level writes its stereo world straight into the drawable
//  (celeste_render_frame_vr); otherwise the host draws the canvas with the game's 2D image in
//  its own pass (opaque black clear, depth 0.0001 = 1000 m). Pauses (layer not running, app in
//  the background) are decided only at the top of the loop.
//
//  Always (cheap): one line [c64-frame] per second into the probe. Only in Debug builds:
//  C64_STALL_SEQ (milliseconds, comma separated): 10 s after the loop started the render
//  thread blocks once for the first duration, 10 s later for the next, and so on; the block
//  sits BEFORE queryNextFrame, so without a started frame. Also the kit test scenes (C64_KIT)
//  and the test scene (C64_TESTSCENE).
//

import ARKit
import CompositorServices
import Foundation
import Metal
import os
import QuartzCore

extension LayerRenderer.Clock.Instant {
    /// Seconds since the epoch of the compositor clock (Mach time base), as
    /// WorldTrackingProvider.queryDeviceAnchor(atTimestamp:) expects them.
    nonisolated var timeInterval: TimeInterval {
        let components = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }
}

nonisolated final class Renderer: @unchecked Sendable {

    // MARK: Setup

    private let layerRenderer: LayerRenderer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let appModel: AppModel
    // ARKit: session and provider live as long as the renderer (Apple: "ARKit stops sessions
    // when they're deinitialized"). The provider can be replaced after an error (a stopped
    // provider must not be run again), hence behind a lock; the render thread reads it per frame.
    private let arSession = ARKitSession()
    private let arLock = NSLock()
    private var worldTrackingStorage = WorldTrackingProvider()
    private var worldTracking: WorldTrackingProvider {
        arLock.withLock { worldTrackingStorage }
    }
    private var arRunAttempts = 0
    private static let arMaxRunAttempts = 3
    private var lastLoggedProviderState: DataProviderState?
    // Provider state once per second during the first ten seconds (does ARKit stay running
    // after the start window closes?).
    private var arkitPeriodicRemaining = 10
    private var arkitPeriodicNextAt: CFAbsoluteTime = 0
    // Frame completion: the pause is decided only at the top of the loop; a frame after
    // queryNextFrame always runs through to encodePresent, commit, endSubmission (exits only
    // with predictTiming nil and an empty drawable list). A frame that was left halfway either
    // stayed in flight (BUG IN CLIENT "more than 3 frames in flight" at the next queryNextFrame,
    // crash on the M5 on 2026-10-25) or left an acquired drawable without a present (GPU timeout
    // of the next host buffer, about 5 s). This note records where the background flag was
    // first seen in the frame.
    private struct PauseFrameNote {
        var frameIndex: UInt64
        var flagSeen: String      // before-update | after-update | after-render
        var tickSkipped: Bool     // no celeste_update in this frame
        var renderSkipped: Bool   // the update ran, celeste_render_frame was skipped
        var committed: Bool
        var presented: Bool
    }
    private var pauseFrameNote: PauseFrameNote?
    // After resuming: the first three frames with the status of their command buffer.
    private var resumeFramesToLog = 0
    // Frame whose host buffer was committed with the flag set (behind cmdErrLock); its
    // BackgroundExecutionNotPermitted is expected and does not count as an error.
    private var backgroundCommitFrame: UInt64?
    private var cmdErrExpectedTotal = 0
    // Audio state, render thread only (FMOD: suspend and resume in pairs on the same thread,
    // no second suspend without a resume).
    private var audioSuspended = false {
        didSet { CelesteProbe.pauseState.setMixerSuspended(audioSuspended) }
    }
    private var audioResumePending = false
    private var nextAudioRetryAt: CFAbsoluteTime = 0
    private var audioFallbackTried = false
    private var cmdSkippedTotal = 0
    // Ticks stay off while the mixer is suspended (Celeste's tick calls FMOD: Audio.Update,
    // events; FMOD: no call between mixerSuspend and mixerResume). The loop keeps presenting
    // the canvas with the last image.
    private var ticksHeldForAudio = false
    private var ticksSkippedForAudio = 0

    /// Pause wanted: layer not running or app in the background (flag from the main thread). The
    /// layer reports .paused only 150 to 200 ms after willResignActive; until then ticks and
    /// commits would run in the background (IOGPUMetalError in the console).
    private var shouldPause: Bool {
        layerRenderer.state != .running || CelesteProbe.pauseState.isBackground
    }

    private var pauseReasonText: String {
        "layer=\(Self.name(layerRenderer.state)) background=\(CelesteProbe.pauseState.isBackground ? 1 : 0)"
    }

    /// One line per pause: where the background flag was first seen (before the frame, in the
    /// frame before the tick, in the frame after the tick), tick skipped, committed, presented.
    private func logPauseFrameNote() {
        if let note = pauseFrameNote {
            c64Record("[c64-pause-frame] tMs=\(LaunchClock.tMs) frame=\(note.frameIndex) flagSeen=\(note.flagSeen) tickSkipped=\(note.tickSkipped ? 1 : 0) renderSkipped=\(note.renderSkipped ? 1 : 0) committed=\(note.committed ? 1 : 0) presented=\(note.presented ? 1 : 0)")
        } else {
            c64Record("[c64-pause-frame] tMs=\(LaunchClock.tMs) frame=\(lastFrameIndex.map { "\($0)" } ?? "-") flagSeen=before-frame tickSkipped=0 renderSkipped=0 committed=0 presented=0 (no frame in progress, last completed frame)")
        }
        pauseFrameNote = nil
    }

    // MARK: Pause

    /// Pause branch of the loop. Before the first frame (the layer starts .paused) only wait,
    /// without suspend and without a pause request. Otherwise: ticks stop, suspend the mixer
    /// once, wait until the layer is running and the app in the foreground (didBecomeActive
    /// seen, app active, scene foregroundActive); then activate the session, mixerResume only on
    /// success, pause request, ticks go on. Returns on .invalidated, the loop head then ends.
    private func pauseBranch() {
        let initial = totalFrames == 0 && !CelesteProbe.pauseState.isBackground
        c64Record("[c64-loop] tMs=\(LaunchClock.tMs) layer paused, waiting; \(pauseReasonText) provider=\(Self.name(worldTracking.state)) frames=\(totalFrames) initial=\(initial ? 1 : 0)")
        if initial {
            layerRenderer.waitUntilRunning()
            c64Record("[c64-loop] tMs=\(LaunchClock.tMs) layer running (start); provider=\(Self.name(worldTracking.state))")
            lastPresentationTime = nil
            lastQueryReturn = nil
        lastPredictedPresentation = nil
            return
        }
        logPauseFrameNote()

        let game = CelesteProbe.gameEnabled && CelesteProbe.tickState.isActive
        if CelesteProbe.gameEnabled {
            CelesteProbe.tickState.pause(reason: "pause \(pauseReasonText)")
        }
        if game, !audioSuspended, !audioResumePending {
            // Exactly one suspend per pause; an open resume attempt (session was not active)
            // leaves FMOD suspended, then no second suspend.
            if CelesteProbe.suspendAudio(true) {
                audioSuspended = true
            }
        } else if game, audioSuspended {
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) mixer stays suspended (no second suspend)")
        }

        // Wait until both hold. waitUntilRunning returns on running or invalidated; the
        // background flag is checked every 20 ms.
        var loggedRunningInBackground = false
        while true {
            let state = layerRenderer.state
            if state == .invalidated {
                c64Record("[c64-loop] tMs=\(LaunchClock.tMs) layer invalidated during the pause")
                return
            }
            if state == .paused {
                layerRenderer.waitUntilRunning()
                continue
            }
            if CelesteProbe.pauseState.isBackground {
                if !loggedRunningInBackground {
                    loggedRunningInBackground = true
                    c64Record("[c64-loop] tMs=\(LaunchClock.tMs) layer running again, app in background, waiting")
                }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            break
        }
        c64Record("[c64-loop] tMs=\(LaunchClock.tMs) resuming; \(pauseReasonText) provider=\(Self.name(worldTracking.state))")
        CelesteProbe.AliveProbe.shared.end(resumeMs: LaunchClock.elapsedMs)
        // reference O anew after resuming, as soon as the pose is still
        CelesteProbe.StereoOrigin.shared.requestSettle("resume")

        if game {
            resumeAudioIfPossible(trigger: "resume")
        }
        ticksHeldForAudio = true
        resumeTicksIfAudioRunning(reason: "resume")
        resumeFramesToLog = 3
        lastPresentationTime = nil
        lastQueryReturn = nil
        lastPredictedPresentation = nil
    }

    /// Allow ticks again once the mixer runs: pause request to the game, then tickState.resume.
    /// With the mixer suspended it stays at one log line; the next successful resume attempt
    /// (serviceAudioRetry) calls again.
    private func resumeTicksIfAudioRunning(reason: String) {
        guard ticksHeldForAudio else { return }
        if audioSuspended {
            c64Record("[c64-celeste] tMs=\(LaunchClock.tMs) ticks stay off, mixer suspended (reason=\(reason))")
            return
        }
        ticksHeldForAudio = false
        if ticksSkippedForAudio > 0 {
            c64Record("[c64-celeste] tMs=\(LaunchClock.tMs) ticks resume after \(ticksSkippedForAudio) frames without a tick (reason=\(reason))")
            ticksSkippedForAudio = 0
        }
        if CelesteProbe.gameEnabled, CelesteProbe.tickState.isActive {
            CelesteProbe.requestPause()
        }
        if CelesteProbe.gameEnabled {
            CelesteProbe.tickState.resume(reason: reason)
        }
        lastQueryReturn = nil
        lastPredictedPresentation = nil
    }

    /// Audio after a pause: activate the session, mixerResume only on success (FMOD example
    /// common_platform.mm:211-236). If the session fails, the mixer stays suspended, the ticks
    /// run without sound, and the attempt repeats on a signal (session didBecomeActive,
    /// resumptionRecommendation) or after one second at the latest. If mixerResume fails despite
    /// an active session, FMOD's fallback for a broken output follows once (media services
    /// reset, common_platform.mm:195-196): suspend and resume as a pair.
    private func resumeAudioIfPossible(trigger: String, mediaServicesReset: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if mediaServicesReset, !audioSuspended {
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) media services reset in the foreground: suspend and resume as a pair (FMOD example)")
            if CelesteProbe.suspendAudio(true, context: "reset pair") {
                audioSuspended = true
            }
        }
        guard audioSuspended else { return }
        guard CelesteProbe.reactivateAudioSession() else {
            audioResumePending = true
            nextAudioRetryAt = now + 1
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) resume pending: session not active, mixer stays suspended, ticks without sound (trigger=\(trigger))")
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
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) fallback pair: suspend and resume once more (FMOD example for a broken output)")
            CelesteProbe.suspendAudio(true, context: "fallback pair")
            if CelesteProbe.suspendAudio(false, context: "fallback pair") {
                audioSuspended = false
                audioResumePending = false
                audioFallbackTried = false
                return
            }
        }
        // Assumption: after a failed resume FMOD is still suspended.
        audioResumePending = true
        nextAudioRetryAt = now + 1
        c64Record("[c64-audio] tMs=\(LaunchClock.tMs) resume pending: mixerResume failed, next attempt in 1 s (trigger=\(trigger))")
    }

    /// Loop head with the game running: open audio attempts and requests from the main thread.
    private func serviceAudioRetry() {
        guard CelesteProbe.gameEnabled else { return }
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

    #if DEBUG
    // Stall probe (C64_STALL_SEQ)
    private let stallPlan: [TimeInterval]
    private var stallIndex = 0
    private var nextStallAt: CFAbsoluteTime = 0
    private static let stallSpacing: TimeInterval = 10
    #endif

    // Frame statistics (touched by the render thread only)
    private var statWindowStart: CFAbsoluteTime = 0
    private var statFrames = 0
    private var statFramesWithoutAnchor = 0
    private var statIntervalMin = Double.greatestFiniteMagnitude
    private var statIntervalMax = 0.0
    private var statIntervalSum = 0.0
    private var statIntervalCount = 0
    private var statGaps: UInt64 = 0
    private var statCancelled = 0          // queryDrawables returned an empty list (frame cancelled by the system)
    private var statNoCmdBuf = 0           // makeCommandBuffer returned nil
    private var statDrawablesMin = Int.max // drawables per frame in the window
    private var statDrawablesMax = 0
    private var lastNoCmdBufLog: CFAbsoluteTime = 0
    private var lastTargets: [UInt32]?     // target set of the last frame, for [c64-targets]
    private var lastPresentationTime: TimeInterval?
    private var lastFrameIndex: UInt64?
    private var totalFrames: UInt64 = 0
    // Grid interval for presentGaps (mean of the last window) and the one-off line on the time
    // base of gpuEndTime against the compositor clock.
    private var presentRasterInterval: TimeInterval = 1.0 / 90.0
    private var timebaseLogged = false
    // last [c64-mem] line (every 10 s)
    private var lastMemLog: CFAbsoluteTime = 0
    // Lead of the submission before optimalInputTime (C64_EARLY_MS, default 5 ms), logged once;
    // last pose for holding when the anchor is refused
    private static let earlySubmitSeconds: TimeInterval = {
        let ms = HostEnvironment.string("C64_EARLY_MS").flatMap { Double($0) } ?? 5
        return max(0, min(ms, 20)) / 1000
    }()
    private var earlyLogged = false
    private var lastDeviceAnchor: DeviceAnchor?

    // Wall clock interval between consecutive returns of queryNextFrame. Shows the block,
    // because it measures at the render thread, not at the compositor's frame counter.
    private var lastQueryReturn: CFAbsoluteTime?
    // predicted presentation time of the previous frame; the game delta is the difference of
    // the presentation times (fixed grid of the compositor), not the wall clock
    private var lastPredictedPresentation: TimeInterval?
    private var predictedPresentation: TimeInterval?
    // Near plane of the layer reported to Celeste once (before the first update on the render thread).
    private var depthNearSent = false
    private var statWallMin = Double.greatestFiniteMagnitude
    private var statWallMax = 0.0
    private var statWallSum = 0.0
    private var statWallCount = 0

    // Lateness per frame: presentationTime minus the compositor clock right before encodePresent,
    // same time base (Mach time, frame_timing.h:67-68). Negative = the presentation time has
    // already passed when encoding.
    private var statLateMin = Double.greatestFiniteMagnitude
    private var statLateMax = -Double.greatestFiniteMagnitude
    private var statLateFrames = 0

    #if DEBUG
    // The first three frames after a stall block: frameIndex, presentationTime relative to the
    // compositor clock when the drawables were received, lateness before encodePresent.
    private var postStallWanted = 0
    private var postStallBlock = 0
    private var postStallSamples: [(index: UInt64, relative: Double, late: Double)] = []
    #endif

    // Foveation probe: shape of the drawables and rate maps as numbers; the line [c64-fov] only
    // on a change (the text is built only then, not per frame).
    private struct FovSignature: Equatable {
        var maps: Int
        var screenWidth: Int, screenHeight: Int
        var physicalWidth: Int, physicalHeight: Int
        var views: Int
        var textureWidth: Int, textureHeight: Int, arrayLength: Int
    }
    private var lastFovSignature: FovSignature?
    private var lastFovLog: CFAbsoluteTime = 0
    private var renderQualityApplied = false

    #if DEBUG
    // Test scene (switch C64_TESTSCENE=1): created lazily on the render thread.
    private let testSceneRequested = TestScene.isRequested
    private var testScene: TestScene?
    private var testSceneFailed = false
    #endif

    // Canvas: texture from the host, scene lazily on the render thread. The base pass clears the
    // depth to 0.0001 (1000 m, behind the canvas at 500 m) instead of 0 ("no content"), so the
    // border is the app's own black and not passthrough.
    private let canvasTexture: MTLTexture?
    private var canvasScene: CanvasScene?
    private var canvasFailed = false
    private static let canvasClearDepth = 0.0001

    // GPU time of the host command buffers (gpuEndTime − gpuStartTime) from the completed
    // handler, behind cmdErrLock; the render thread reads and resets it once per second.
    private var gpuTimeSum = 0.0
    private var gpuTimeMax = 0.0
    private var gpuTimeCount = 0

    // Error state of the command buffers. The completed handler runs on a Metal thread, hence
    // behind a lock; the render thread reads and resets the counter once per second.
    private let cmdErrLock = NSLock()
    private var cmdErrCount = 0
    private var cmdErrTotal = 0
    private var lastCmdErrLog: CFAbsoluteTime = 0

    // Frame rate over the whole run (intervals from presentationTime), for the summary.
    private var intervalTotalSum = 0.0
    private var intervalTotalCount = 0
    private var footprintStartMB = 0.0        // phys_footprint at the start of the loop
    private var availableStartMB = 0.0        // os_proc_available_memory at the start of the loop
    // Last state of drawable and map for the summary (render quality 1.0: textures for
    // maxRenderQuality, the map grows during the transition).
    private var lastDrawableSize: (width: Int, height: Int) = (0, 0)
    private var lastMapSizes: (screenW: Int, screenH: Int, physW: Int, physH: Int) = (0, 0, 0, 0)
    private var cancelledTotal = 0

    #if DEBUG
    // Kit stage import (C64_KIT=import): SDL_GPU device on the device and queue of this host,
    // importing and clearing the drawable textures in every frame. Render thread only.
    private var kitImportSession: OpaquePointer?
    private var kitImportFailed = false       // session could not be created: the host clears itself
    // Kit stage multiview (C64_KIT=multiview): SDL_GPU device with a pipeline of view_count 2;
    // per frame an import and one pass with clear and checkerboard for both eyes. Render thread only.
    private var kitMultiviewSession: OpaquePointer?
    private var kitQuad = KitQuadPlacement()
    // Foveation measurement (C64_KIT=multiview with C64_FOVEATION=1): measurement image against
    // the compositor map once per second; maximum deviation in physical pixels over the run.
    private var fovMeasureLast: CFAbsoluteTime = 0
    private var fovMeasureCount = 0
    private var fovMaxDevPx: Float = 0
    private var fovMeanDevSum: Double = 0
    private var fovMeasureMsSum: Double = 0
    private var statSdlFail = 0               // frames in the window in which SDL failed
    private var sdlFailTotal = 0
    // Import diagnostics (C64_KIT_VERIFY): SDL's read-back value of this frame and the drawable
    // texture from which the host reads the same spot again right before encodePresent.
    private var pendingVerify: (afterSDL: [UInt8], color: MTLTexture)?
    private static let importClearColor: (Float, Float, Float, Float) = (0.0, 0.1, 0.3, 1.0)
    // Depth value of the SDL clear. The compositor shows only pixels with alpha > 0 and depth > 0
    // (WWDC24, session 10092 "Render Metal with passthrough in visionOS"; measured on the device
    // on 2026-10-17: depth 0 black, depth 0.001 blue, with identical texture content). Reverse-Z
    // with an infinite far plane: distance = near / depth; 0.001 at near 0.1 m is 100 m, so a
    // "present" empty background. C64_KIT_DEPTH=0 remains possible as the counter-check.
    private static let importClearDepthDefault: Float = 0.001
    private let importClearDepth: Float = Float(HostEnvironment.string("C64_KIT_DEPTH") ?? "") ?? Renderer.importClearDepthDefault
    private var importDepthLogged = false
    // C64_KIT_MSAA=<samples> (default off): anti-aliasing in the kit pass; the session renders into
    // MSAA textures of drawable size and resolves colour and depth into the drawable layers.
    private let kitMsaaSamples: Int = Int(HostEnvironment.string("C64_KIT_MSAA") ?? "") ?? 0
    // C64_KIT_MEMORYLESS=1 (default off): MSAA targets memoryless (tile memory only).
    private let kitMemoryless: Bool = HostEnvironment.string("C64_KIT_MEMORYLESS") == "1"
    // C64_KIT_DEPTH_STORE=store|dontcare (default unset): store_op of the private MSAA depth in
    // the kit pass and depth probe (second pass into its own 1x two-layer textures, read-back
    // of both layers, step=depth-probe). Requires C64_KIT_MSAA and, with store, C64_KIT_MEMORYLESS
    // off; unknown values are logged and ignored.
    private let kitDepthStore: String? = HostEnvironment.string("C64_KIT_DEPTH_STORE")
    #endif

    @MainActor
    private init(layerRenderer: LayerRenderer, appModel: AppModel) {
        self.layerRenderer = layerRenderer
        self.appModel = appModel
        self.device = layerRenderer.device
        // If the host already has device and queue (game started), the renderer takes the same
        // queue; SDL's command buffers (Celeste's image) and the host buffers then run in commit
        // order, and the canvas pass reads the finished image.
        if let shared = CelesteProbe.commandQueue {
            let hostDevice = CelesteProbe.device
            let same = hostDevice.map { $0 === layerRenderer.device } ?? false
            self.commandQueue = shared
            c64Record("[c64-canvas] queue shared=1 label=\"\(shared.label ?? "")\" layerDevice=\(Unmanaged.passUnretained(layerRenderer.device).toOpaque()) hostDevice=\(hostDevice.map { "\(Unmanaged.passUnretained($0).toOpaque())" } ?? "nil") same=\(same ? 1 : 0)")
            if !same {
                c64Record("[c64-canvas] WARNING: LayerRenderer device and host device differ; textures of one are invalid on the other")
            }
        } else {
            guard let queue = device.makeCommandQueue() else {
                fatalError("MTLCommandQueue could not be created")
            }
            queue.label = "c64-render-queue"
            self.commandQueue = queue
        }
        self.canvasTexture = CelesteProbe.canvasTexture
        #if DEBUG
        self.stallPlan = StallPlan.fromEnvironment()
        #endif
    }

    /// Render quality of the product: 1.0 with foveation; C64_RENDERQUALITY overrides.
    static let defaultRenderQuality: Float = 1.0

    /// Entry from the CompositorLayer closure (main thread). Starts ARKit and then the render
    /// loop on its own thread.
    @MainActor
    static func start(layerRenderer: LayerRenderer, appModel: AppModel) {
        let renderer = Renderer(layerRenderer: layerRenderer, appModel: appModel)
        renderer.logContext()
        Task {
            await renderer.startARSession()
            renderer.startThread()
        }
    }

    /// Starts the session with the WorldTrackingProvider and watches its events (when launching
    /// straight into the space the provider once did not stay running for no visible reason,
    /// the device anchor never came). Every state change goes into the probe file; if the
    /// provider ends with an error, a new attempt with a new provider follows (at most
    /// arMaxRunAttempts, 1 s apart).
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
            c64Error("[c64-arkit] run attempt \(attempt) skipped (\(reason)): limit \(Self.arMaxRunAttempts) reached, no pose")
            return
        }
        do {
            let before = await MainActor.run { CelesteProbe.lifecycleLine }
            c64Record("[c64-arkit] tMs=\(LaunchClock.tMs) run attempt \(attempt) (\(reason)) layer=\(Self.name(layerRenderer.state)) \(before)")
            try await arSession.run([provider])
            c64Record("[c64-arkit] run attempt \(attempt) returned (\(reason)) state=\(Self.name(provider.state)) supported=\(WorldTrackingProvider.isSupported)")
            CelesteProbe.AliveProbe.shared.setProviderState(Self.name(provider.state))
        } catch {
            // Without a pose the loop still presents (black without an anchor); the log shows it.
            c64Error("[c64-arkit] run attempt \(attempt) failed (\(reason)): \(error)")
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

    // MARK: Start line

    /// [c64-ctx]: the process state as read, not as assumed; plus the host's switches (Debug
    /// builds append their test switches).
    private func logContext() {
        let config = layerRenderer.configuration
        let layout = ProbeLayerConfiguration.name(config.layout)
        var line = "[c64-ctx] build=\(ProbeContext.buildConfiguration)"
            + " probe=\(ProgressFile.enabled ? "on" : "off")"
            + " C64_PROBE=\(ProbeContext.environment("C64_PROBE"))"
            + " debugger=\(ProbeContext.debuggerAttached ? 1 : 0)"
            + " rotated=\(ProgressFile.enabled ? ProgressFile.shared.rotatedRuns : 0)"
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
            + " views=\(layerRenderer.properties.viewCount)"
            + " C64_RENDERQUALITY=\(ProbeContext.environment("C64_RENDERQUALITY"))"
            + " C64_FOVEATION=\(ProbeContext.environment("C64_FOVEATION"))"
            + " C64_LAYOUT=\(ProbeContext.environment("C64_LAYOUT"))"
            + " C64_EARLY_MS=\(ProbeContext.environment("C64_EARLY_MS"))"
            + " C64_RES=\(ProbeContext.environment("C64_RES"))"
            + " C64_LINE=\(ProbeContext.environment("C64_LINE"))"
            + " C64_CANVAS_FOV=\(ProbeContext.environment("C64_CANVAS_FOV"))"
            + " C64_CANVAS_FILTER=\(ProbeContext.environment("C64_CANVAS_FILTER"))"
        #if DEBUG
        line += " C64_KIT=\(ProbeContext.environment(KitProbe.environmentKey))"
            + " C64_KIT_DEPTH=\(ProbeContext.environment("C64_KIT_DEPTH"))"
            + " C64_KIT_MSAA=\(ProbeContext.environment("C64_KIT_MSAA"))"
            + " C64_KIT_MEMORYLESS=\(ProbeContext.environment("C64_KIT_MEMORYLESS"))"
            + " C64_KIT_DEPTH_STORE=\(ProbeContext.environment("C64_KIT_DEPTH_STORE"))"
            + " C64_TESTSCENE=\(ProbeContext.environment(TestScene.environmentKey))"
            + " C64_SNAPSHOT=\(ProbeContext.environment("C64_SNAPSHOT"))"
            + " stallSeq=\(stallPlan.isEmpty ? "-" : stallPlan.map { String(Int($0 * 1000)) }.joined(separator: ","))"
        #endif
        c64Record(line)
    }

    // MARK: Loop

    private func renderLoop() {
        let start = CFAbsoluteTimeGetCurrent()
        statWindowStart = start
        c64Record("[c64-loop] tMs=\(LaunchClock.tMs) render loop started, thread=\(Thread.current.name ?? "?")")
        // Layer state for the alive probe (cp_layer_renderer_get_state, no lock).
        CelesteProbe.AliveProbe.shared.setLayerStateReader { [layerRenderer] in Self.name(layerRenderer.state) }
        if CelesteProbe.gameEnabled {
            CelesteProbe.tickState.resume(reason: "render loop started")
        }

        #if DEBUG
        nextStallAt = start + Self.stallSpacing
        // Kit stage inject (C64_KIT=inject): once before the first frame, with the layer renderer's
        // device and the queue of this host. SDL_Init ran on the main thread (GameStartup).
        if KitProbe.mode == .inject {
            runKitInjectProbe()
        }
        #endif
        // Memory at the start of the loop (reference value for the summary).
        footprintStartMB = ProbeContext.physFootprintMB
        availableStartMB = ProbeContext.availableMemoryMB
        c64Record("[c64-loop] footprintStartMB=\(String(format: "%.1f", footprintStartMB)) availableMB=\(String(format: "%.1f", availableStartMB))")
        #if DEBUG
        // Kit stage import (C64_KIT=import): session for the whole loop.
        if KitProbe.mode == .import {
            kitImportSession = KitProbe.beginImport(device: device, queue: commandQueue)
            kitImportFailed = (kitImportSession == nil)
            c64Record("[c64-kit] import session=\(kitImportSession == nil ? "MISSING, scaffold clears itself" : "ok")")
        }
        // Kit stage multiview (C64_KIT=multiview): session with a pipeline of view_count 2 for the whole loop.
        if KitProbe.mode == .multiview {
            kitMultiviewSession = KitProbe.beginMultiview(device: device, queue: commandQueue, msaaSamples: kitMsaaSamples, memoryless: kitMemoryless,
                                                          depthStore: kitDepthStore)
            kitImportFailed = (kitMultiviewSession == nil)
            c64Record("[c64-kit] multiview session=\(kitMultiviewSession == nil ? "MISSING, scaffold clears itself" : "ok")")
        }
        #endif

        while true {
            switch layerRenderer.state {
            case .invalidated:
                c64Record("[c64-loop] layer invalidated, loop ends after \(totalFrames) frames")
                logLoopSummary()
                if CelesteProbe.gameEnabled {
                    // The closed space (Digital Crown) ends the app cleanly: stop the ticks,
                    // celeste_end on the main thread, exit(0). Without a window scene there would
                    // be no clean restart otherwise while Celeste lives in the process.
                    CelesteProbe.requestExit(reason: "layer invalidated")
                }
                Task { @MainActor [appModel] in
                    appModel.immersiveState = .closed
                }
                return
            default:
                break
            }
            // Pause when the layer is not running or the app is in the background.
            if shouldPause {
                pauseBranch()
                continue
            }
            // The flag was set briefly in the last frame but gone again at the top of the loop:
            // drop the note, otherwise it would be attributed to the next pause.
            pauseFrameNote = nil
            serviceAudioRetry()

            #if DEBUG
            // Stall probe: BEFORE queryNextFrame, so without a started frame.
            stallIfDue()
            #endif
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

    #if DEBUG
    /// Inject: SDL_GPU device on the shared device and the shared queue, then a clear pass with
    /// read-back, SDL_DestroyGPUDevice and an empty command buffer on the host queue. The loop
    /// then continues normally; the first [c64-frame] lines show whether cmdErr stays 0.
    private func runKitInjectProbe() {
        let result = KitProbe.runInject(device: device, queue: commandQueue)
        c64Record("[c64-kit] inject \(result == 0 ? "passed (shared device and queue)" : "failed at step \(result)")")
    }

    /// Import: SDL imports colour and depth texture of the drawable and clears all layers (dark
    /// blue, depth from importClearDepth). SDL commits its command buffer synchronously on the
    /// shared queue; the host buffer with encodePresent is committed afterwards and therefore
    /// runs afterwards (MTLCommandQueue is serial, execution in commit order). false: the host
    /// clears itself and presents anyway.
    private func kitImportClear(drawable: LayerRenderer.Drawable) -> Bool {
        guard let session = kitImportSession else { return false }
        // With .layered all views share one array texture; with .dedicated one per view.
        var textureIndices: [Int] = []
        for view in drawable.views where !textureIndices.contains(view.textureMap.textureIndex) {
            textureIndices.append(view.textureMap.textureIndex)
        }
        if !importDepthLogged {
            importDepthLogged = true
            // depthRange: x = far, y = near, in metres (drawable.h:317-320).
            let range = drawable.depthRange
            let distance = importClearDepth > 0 ? String(format: "%.1f m", range.y / importClearDepth) : "infinite (no content for the compositor)"
            c64Record(String(format: "[c64-kit] step=import-depth clear=%.4f depthRange far=%.3f near=%.3f corresponds to distance %@",
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

    /// Multiview: import colour and depth texture, one pass with view_count 2: clear (dark blue,
    /// depth from importClearDepth) and the checkerboard for both eyes, matrices like TestScene
    /// (projection · inverse(deviceAnchor · view.transform)). Without a pose only the clear.
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
        // the compositor's map to the SDL pass when foveation is on (otherwise the plain multiview pass).
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

    /// Once per second the measurement image against the compositor map (own texture, costs one
    /// pass plus a read-back with waiting); the first measurement verbose with all samples.
    private func measureFoveationIfDue(session: OpaquePointer, rateMap: MTLRasterizationRateMap) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - fovMeasureLast >= 1.0 else { return }
        fovMeasureLast = now
        let verbose = fovMeasureCount == 0
        guard let m = KitProbe.multiviewMeasure(session: session, rateMap: rateMap, verbose: verbose) else {
            c64Record("[c64-kit] step=fov-measure FAIL (measurement image not rendered or not read)")
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
    #endif

    /// Summary at the end of the loop, in every mode: frames, cmdErr, memory at start and end. In
    /// mode import also sdlFail, wrappers and rotation; in mode multiview passes and draws per
    /// frame and the CPU time of the SDL part; the session is closed.
    private func logLoopSummary() {
        var kitPart = ""
        var mode = "-"
        #if DEBUG
        mode = KitProbe.mode?.rawValue ?? "-"
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
            // GPU time of the SDL command buffers (completion callback, without the first 90
            // frames: mean, p95, maximum) and MSAA state.
            var gpuCount: UInt32 = 0
            var gpuMean = 0.0, gpuP95 = 0.0, gpuMax = 0.0
            kit_multiview_gpu_percentiles(session, &gpuCount, &gpuMean, &gpuP95, &gpuMax)
            let filterNames = ["sample0", "min", "max"]
            let filter = Int(stats.depth_filter) < filterNames.count ? filterNames[Int(stats.depth_filter)] : "?"
            kitPart += String(format: " gpu(ms, from frame 91) n=%u mean=%.3f p95=%.3f max=%.3f untagged=%lu gpuErr=%lu msaa=%u memoryless=%u msaaTextures=%ux%ux%u msaaNominalMB=%.1f msaaAllocatedMB=%@ measureMsaaNominalMB=%.1f depthResolveFilter=%@ depthStore=%@ depthProbes=%lu",
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
        if fovMeasureCount > 0 {
            kitPart += String(format: " fov{measurements=%d maxDevPx=%.3f meanDevPx=%.3f measureMs=%.2f}",
                              fovMeasureCount, fovMaxDevPx, fovMeanDevSum / Double(fovMeasureCount), fovMeasureMsSum / Double(fovMeasureCount))
        }
        #endif
        let footprintEnd = ProbeContext.physFootprintMB
        cmdErrLock.lock()
        let cmdErr = cmdErrTotal
        let cmdSkipped = cmdSkippedTotal
        let cmdErrExpected = cmdErrExpectedTotal
        cmdErrLock.unlock()
        // Frame rate over the run: mean interval from presentationTime and Hz from it.
        let meanInterval = intervalTotalCount > 0 ? intervalTotalSum / Double(intervalTotalCount) : 0
        let hz = meanInterval > 0 ? 1.0 / meanInterval : 0
        // Render quality: requested (switch), upper limit of the configuration, actual at the end;
        // plus drawable and map size of the last frame and the available memory.
        let requestedQuality = HostEnvironment.text("C64_RENDERQUALITY")
        let qualityPart = String(format: " renderQuality{requested=%@ max=%.3f end=%.3f} drawable=%dx%d map{screen=%dx%d physical=%dx%d}",
                                 requestedQuality, layerRenderer.configuration.maxRenderQuality.rawValue, layerRenderer.renderQuality.rawValue,
                                 lastDrawableSize.width, lastDrawableSize.height,
                                 lastMapSizes.screenW, lastMapSizes.screenH, lastMapSizes.physW, lastMapSizes.physH)
        let availableEnd = ProbeContext.availableMemoryMB
        c64Record(String(format: "[c64-loop] summary C64_KIT=%@ foveation=%d%@ frames=%llu interval(ms) mean=%.3f rate=%.1f Hz cancelled=%d cmdErr=%d cmdErrExpectedInBackground=%d cmdSkipped=%d footprintMB start=%.1f end=%.1f delta=%+.1f availableMB start=%.1f end=%.1f%@",
                         mode, layerRenderer.configuration.isFoveationEnabled ? 1 : 0, qualityPart, totalFrames, meanInterval * 1000, hz,
                         cancelledTotal, cmdErr, cmdErrExpected, cmdSkipped, footprintStartMB, footprintEnd, footprintEnd - footprintStartMB,
                         availableStartMB, availableEnd, kitPart))
    }

    #if DEBUG
    /// Import diagnostics: read the same spot SDL read back after its clear once more in the host
    /// buffer right before encodePresent (blit of the centre pixel of layers 0 and 1 into a
    /// shared buffer); logged in the completed handler with both values.
    private func encodeVerifyBeforePresent(commandBuffer: MTLCommandBuffer, frameIndex: UInt64) {
        guard let pending = pendingVerify else { return }
        pendingVerify = nil
        let texture = pending.color
        guard let buffer = device.makeBuffer(length: 64, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            c64Record("[c64-kit] step=present-verify frame=\(frameIndex) blit not possible")
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

        let target = stallPlan[stallIndex]
        let number = stallIndex + 1
        let targetMs = Int((target * 1000).rounded())
        c64Record("[c64-stall] before block \(number)/\(stallPlan.count) target=\(targetMs) ms frames=\(totalFrames)")
        let t0 = CFAbsoluteTimeGetCurrent()
        Thread.sleep(forTimeInterval: target)
        let actual = CFAbsoluteTimeGetCurrent() - t0
        c64Record(String(format: "[c64-stall] after block %d/%d target=%d ms actual=%.1f ms layerState=%@",
                         number, stallPlan.count, targetMs, actual * 1000, Self.name(layerRenderer.state)))

        stallIndex += 1
        nextStallAt = CFAbsoluteTimeGetCurrent() + Self.stallSpacing
        // The interval across the block stays in the statistics: lastPresentationTime and
        // lastQueryReturn are not reset, so the [c64-frame] line of the block's second shows
        // the jump (max ≈ block + one tick).
        postStallWanted = 3
        postStallBlock = number
        postStallSamples.removeAll()
        if stallIndex == stallPlan.count {
            c64Record("[c64-stall] sequence finished, all \(stallPlan.count) blocks survived")
        }
    }
    #endif

    // MARK: Frame

    // MARK: Stereo world pass

    /// Frame data for celeste_render_frame_vr from the drawable: colour and depth texture (one 2D
    /// array texture for both views, layout .layered), the compositor's rate map with logical and
    /// physical size, the projection per view from computeProjection (16 floats, column order
    /// like simd; Celeste sets its near plane in units itself), the view transforms (for the
    /// head pose) and the near plane of the layer. false when the drawable does not have the
    /// shape (fewer than two views or no array texture).
    private static func fillVRFrame(_ frame: inout celeste_vr_frame, drawable: LayerRenderer.Drawable, layerFrame: LayerRenderer.Frame,
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
        // Head and eyes relative to the reference O (StereoOrigin); identity without a pose
        // (Celeste then takes the game camera for both eyes). The compositor's culling matrix
        // for both eyes with wider tangents, depth range wider than when rendering.
        var relativeHead = matrix_identity_float4x4
        var originReset = false
        if let deviceAnchor {
            let result = CelesteProbe.StereoOrigin.shared.update(anchor: deviceAnchor.originFromAnchorTransform, frameIndex: layerFrame.frameIndex)
            relativeHead = result.relative
            originReset = result.reset
        }
        var culling = layerFrame.binocularFrustumMatrixForDrawableTarget(drawableTarget: drawable.target,
                                                                           increaseTangents: SIMD4<Float>(repeating: 0.15),
                                                                           depthRange: SIMD2<Float>(Float.infinity, 0.05))
        func copy(_ m: inout simd_float4x4, into dst: UnsafeMutableRawBufferPointer, offset: Int) {
            withUnsafeBytes(of: &m) { src in
                dst.baseAddress!.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: 64)
            }
        }
        for slot in 0..<2 {
            var projection = drawable.computeProjection(viewIndex: slot)
            var viewTransform = relativeHead * views[slot].transform
            withUnsafeMutableBytes(of: &frame.projection) { dst in copy(&projection, into: dst, offset: slot * 64) }
            withUnsafeMutableBytes(of: &frame.view_transform) { dst in copy(&viewTransform, into: dst, offset: slot * 64) }
        }
        withUnsafeMutableBytes(of: &frame.head_transform) { dst in copy(&relativeHead, into: dst, offset: 0) }
        withUnsafeMutableBytes(of: &frame.culling_projection) { dst in copy(&culling, into: dst, offset: 0) }
        frame.origin_reset = originReset ? 1 : 0
        frame.near_meters = Double(configuration.defaultDepthRange.y)
        return true
    }

    private var lastHeadLog: CFAbsoluteTime = 0

    /// [c64-head] once per second: offset and yaw relative to O.
    private func logHeadIfDue() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastHeadLog >= 1.0 else { return }
        lastHeadLog = now
        c64Record("[c64-head] tMs=\(LaunchClock.tMs) \(CelesteProbe.StereoOrigin.shared.line)")
    }

    private var lastStereoRc: Int32 = -3
    private var stereoWorldFrames = 0

    /// [c64-stereo]: the first world frame and every switch between world (1) and canvas (0).
    private func noteStereoFrame(rc: Int32, frame: celeste_vr_frame, frameIndex: UInt64) {
        if rc == 1 { stereoWorldFrames += 1 }
        guard rc != lastStereoRc else { return }
        lastStereoRc = rc
        c64Record("[c64-stereo] tMs=\(LaunchClock.tMs) frame=\(frameIndex) rc=\(rc) (\(rc == 1 ? "world in drawable" : rc == 0 ? "canvas" : "no render")) drewWorld=\(frame.drew_world) flushes=\(frame.flushes) texture=\(frame.width)x\(frame.height) logical=\(frame.logical_width)x\(frame.logical_height) physical=\(frame.physical_width)x\(frame.physical_height) srgb=\(frame.color_srgb) map=\(frame.rasterization_rate_map != nil ? 1 : 0) near=\(String(format: "%.3f", frame.near_meters)) worldFrames=\(stereoWorldFrames)")
    }

    /// Near plane of the layer configuration (defaultDepthRange: x = far, y = near, metres,
    /// layer_renderer_configuration.h:386-414, reverse-Z) to Celeste.
    private func sendDepthNear() {
        let range = layerRenderer.configuration.defaultDepthRange
        let rc = celeste_set_depth_near(Double(range.y))
        let error = rc == 0 ? "" : (celeste_last_error().map { " error=\"\(String(cString: $0))\"" } ?? "")
        c64Record("[c64-depth] tMs=\(LaunchClock.tMs) layer defaultDepthRange " + String(format: "far=%.3f near=%.3f m", range.x, range.y) + " -> celeste_set_depth_near rc=\(rc)\(error)")
    }

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else {
            // No frame available (paused, invalidated or too many in flight): wait briefly.
            Thread.sleep(forTimeInterval: 0.001)
            return
        }

        // Wall clock interval since the last return of queryNextFrame.
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

        // Update phase: Celeste's update, the render half follows after the device anchor. The
        // delta is the difference of the predicted presentation times: this frame's presentation
        // time before the update (predictTiming may be called any time before queryDrawables,
        // frame.h:57-69) minus the previous frame's; lost frames give 22.2 ms, the tick caps it at
        // 1/30 s. After start and resume (no reference) the tick takes 1/90 s as before.
        var presentationDelta: TimeInterval?
        predictedPresentation = nil
        if let predicted = frame.predictTiming() {
            let presentation = predicted.presentationTime.timeInterval
            predictedPresentation = presentation
            if let last = lastPredictedPresentation, presentation > last {
                presentationDelta = presentation - last
            }
            lastPredictedPresentation = presentation
        }

        frame.startUpdate()
        // Only the update half (celeste_update); the render half follows after the device anchor
        // (renderCelesteThisFrame). If the app is already in the background when the update is
        // reached, this frame's tick is skipped (SDL would commit two command buffers in the
        // background); the frame is still presented with the canvas of the last image, the pause
        // follows at the top of the loop.
        var renderCelesteThisFrame = false
        let backgroundAtTick = CelesteProbe.pauseState.isBackground
        if backgroundAtTick {
            pauseFrameNote = PauseFrameNote(frameIndex: frame.frameIndex, flagSeen: "before-update", tickSkipped: true, renderSkipped: true, committed: false, presented: false)
        } else if audioSuspended {
            // no celeste_tick with the mixer suspended; the frame is still presented (canvas
            // with the last image).
            ticksSkippedForAudio += 1
            if ticksSkippedForAudio == 1 {
                c64Record("[c64-celeste] tMs=\(LaunchClock.tMs) tick skipped, mixer suspended; loop keeps presenting")
            }
        } else if CelesteProbe.gameEnabled {
            // before the first update on this thread the layer's near plane to Celeste
            // (celeste_set_depth_near, metres); Celeste converts it to units at one place.
            if !depthNearSent {
                depthNearSent = true
                sendDepthNear()
            }
            renderCelesteThisFrame = CelesteProbe.tickState.update(frameInterval: presentationDelta, wallInterval: frameInterval)
        }
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        // wait time until optimalInputTime (negative when the update finished later already)
        let optimalInput = timing.optimalInputTime.timeInterval
        let waitOpt = optimalInput - LayerRenderer.Clock().now.timeInterval
        // Submit earlier. Compositor Services derives optimalInputTime from our CPU time between
        // startSubmission and endSubmission (3 ms) and knows nothing about the 5–9 ms of GPU work
        // after it; measurements showed 6–7 ms of waiting per frame and deadlines the GPU missed
        // by 1–2 ms. We start C64_EARLY_MS (default 5) before optimalInputTime: the GPU start
        // moves forward by that time, the pose for the same presentation time is predicted
        // correspondingly earlier (the compositor corrects rotation when displaying).
        let early = Self.earlySubmitSeconds
        if !earlyLogged {
            earlyLogged = true
            c64Record(String(format: "[c64-early] submission %.1f ms before optimalInputTime (C64_EARLY_MS, 0 = wait until optimalInputTime)", early * 1000))
        }
        if early > 0 {
            LayerRenderer.Clock().wait(until: timing.optimalInputTime.advanced(by: .seconds(-early)))
        } else {
            LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        }

        // First the drawables, then startSubmission, as in Apple's template. An empty list means
        // the frame was cancelled by the system and must not be touched any more (frame.h:109-110
        // on cp_frame_query_drawables: "If array count is 0, the frame has been cancelled ... and
        // is invalid to access"); earlier startSubmission came first, and this exit left a begun
        // submission without endSubmission, which Compositor Services can answer as a client error
        // (__BUG_IN_CLIENT__) with an abort. The duration of queryDrawables is measured: if it
        // blocked until optimalInputTime, the lead would be ineffective and visible here.
        let queryStart = LayerRenderer.Clock().now.timeInterval
        let drawables = frame.queryDrawables()
        let queryDrawablesSeconds = LayerRenderer.Clock().now.timeInterval - queryStart
        guard !drawables.isEmpty else {
            statCancelled += 1
            cancelledTotal += 1
            return
        }
        // The command buffer too comes before startSubmission (as in Apple's template). If it is
        // missing, the frame is left without a begun submission; an endSubmission without a
        // presented drawable counts as a client error for Compositor Services (__BUG_IN_CLIENT__).
        // Line at most once per second.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            statNoCmdBuf += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastNoCmdBufLog >= 1.0 {
                lastNoCmdBufLog = now
                c64Log.error("[c64-loop] makeCommandBuffer returned nil, frame \(frame.frameIndex) left without a submission (\(self.statNoCmdBuf) so far in this window)")
            }
            return
        }
        commandBuffer.label = "c64-frame \(frame.frameIndex)"
        // From here on the frame is in flight and is completed in every case (encodePresent,
        // commit, endSubmission).
        frame.startSubmission()

        logTargetsIfChanged(drawables)
        applyRenderQualityIfRequested()
        logFoveationIfChanged(drawables)
        rememberSizes(drawables)

        // Pose and timing from the drawable for the built-in display (target builtIn,
        // drawable.h:36-44, precedence per drawable.h:428-429), fallback to the first one.
        // Without a pose (ARKit not ready yet) black is still presented, only without an
        // anchor. The anchor is set on all drawables.
        let primary = drawables.first(where: { $0.target == .builtIn }) ?? drawables[0]
        let presentationTime = primary.frameTiming.presentationTime.timeInterval

        // Deadline of the frame (frame_timing.h:45-56, "finish all CPU and GPU work by the
        // returned time") to the completed handler of the host buffer, which as the last buffer
        // of the frame on the serial queue marks the GPU end. Establish the time base once:
        // gpuEndTime is in the base of CACurrentMediaTime (host time, Mach), the compositor
        // clock counts Mach ticks since its epoch (cp_types.h:27-33); the offset is measured
        // and subtracted in the comparison, the line shows whether it is practically 0.
        let renderingDeadline = primary.frameTiming.renderingDeadline.timeInterval
        if !timebaseLogged {
            timebaseLogged = true
            let compositorNow = LayerRenderer.Clock().now.timeInterval
            let mediaNow = CACurrentMediaTime()
            if let offset = CelesteProbe.frameTiming.calibrate(compositorNow: compositorNow, mediaTime: mediaNow) {
                c64Record(String(format: "[c64-deadline] timebase CACurrentMediaTime−compositorClock=%+.3f ms (compositor=%.3f s media=%.3f s); margin = renderingDeadline − (gpuEndTime − offset)", offset * 1000, compositorNow, mediaNow))
            }
        }
        let frameIndexForHandler = frame.frameIndex
        // Frame number of the pass statistics, before Celeste's render (prepare/settle carry it)
        // and for the host buffer that closes this frame's labels.
        let gpuFrame = CelesteProbe.celesteGpuPasses.beginFrame()
        // after resuming log the first three frames with the buffer status.
        let logResume = resumeFramesToLog > 0
        if logResume { resumeFramesToLog -= 1 }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            self?.noteCommandBufferCompletion(buffer, frameIndex: frameIndexForHandler, renderingDeadline: renderingDeadline, gpuFrame: gpuFrame, logResume: logResume)
        }
        // prediction against the drawable's presentation time (statistics)
        if let predictedPresentation {
            CelesteProbe.tickState.notePresentation(predicted: predictedPresentation, actual: presentationTime)
        }
        // presentationTime relative to the compositor clock when the drawables were received (same time base).
        let relativeToNow = presentationTime - LayerRenderer.Clock().now.timeInterval
        // Only a running provider delivers anchors; otherwise no query (no console errors), the
        // frame counts as noAnchor, and one line per state change shows the reason.
        let provider = worldTracking
        let providerState = provider.state
        if providerState != lastLoggedProviderState {
            lastLoggedProviderState = providerState
            c64Record("[c64-arkit] render thread sees provider state=\(Self.name(providerState)) frame=\(totalFrames)")
        }
        var deviceAnchor = providerState == .running ? provider.queryDeviceAnchor(atTimestamp: presentationTime) : nil
        // queryDeviceAnchor refuses times it does not predict for (a stall that pushes the
        // presentation time out is enough). Then hold the last pose instead of presenting
        // without an anchor: the identity would glue the world to the face. Counted as anchorHeld.
        var anchorHeld = false
        if deviceAnchor == nil, providerState == .running, let held = lastDeviceAnchor {
            deviceAnchor = held
            anchorHeld = true
        } else if let fresh = deviceAnchor {
            lastDeviceAnchor = fresh
        }
        if let deviceAnchor {
            // last head pose for the [c64-recenter] line (diagnostics).
            CelesteProbe.headPose.set(anchor: deviceAnchor.originFromAnchorTransform)
        }

        // Celeste's render half after the device anchor, right before encoding; SDL commits its
        // buffers on the shared queue before the host buffer. No render without an update in
        // this frame (pause, mixer suspended, flag set).
        // With the stereo world pass Celeste gets the drawable (textures, map, projections per
        // eye); return 1 means the world is in the drawable, the host clears and draws nothing
        // there any more. Return 0: canvas as before.
        var celesteRenderedThisFrame = false
        var worldDrawnThisFrame = false
        var toFirstCommit: TimeInterval?
        if renderCelesteThisFrame {
            if CelesteProbe.pauseState.isBackground {
                // The flag came between update and render: Celeste's render is skipped (no SDL
                // buffers in the background), the canvas shows the last image, the frame is
                // presented to completion.
                pauseFrameNote = PauseFrameNote(frameIndex: frame.frameIndex, flagSeen: "after-update", tickSkipped: false, renderSkipped: true, committed: false, presented: false)
            } else {
                celesteRenderedThisFrame = true
                var worldFrame = celeste_vr_frame()
                if Self.fillVRFrame(&worldFrame, drawable: primary, layerFrame: frame, deviceAnchor: deviceAnchor, configuration: layerRenderer.configuration) {
                    let renderCall = LayerRenderer.Clock().now.timeInterval
                    let rc = CelesteProbe.tickState.renderVR(&worldFrame)
                    worldDrawnThisFrame = rc == 1
                    // optimalInputTime to the commit of the world buffer (Celeste reports the
                    // microseconds from the call to the commit in reserved2)
                    if rc == 1, worldFrame.reserved2 > 0 {
                        toFirstCommit = (renderCall - optimalInput) + Double(worldFrame.reserved2) / 1_000_000
                    }
                    noteStereoFrame(rc: rc, frame: worldFrame, frameIndex: frame.frameIndex)
                    if rc == 1 { logHeadIfDue() }
                } else {
                    // drawable without the expected shape (two views, array texture): canvas for everything
                    CelesteProbe.tickState.render()
                }
            }
        }
        // Frame without a Celeste render (loading, pause, flag): drawable opaque black per the
        // frame rule, never old content and no canvas with an old image.
        let blackOnly = CelesteProbe.gameEnabled && !celesteRenderedThisFrame
        let primaryColor = primary.colorTextures.first

        for drawable in drawables {
            if let anchor = deviceAnchor {
                drawable.deviceAnchor = anchor
            }
            if worldDrawnThisFrame, let primaryColor, drawable.colorTextures.first === primaryColor {
                // Celeste wrote this drawable (both layers, depth copied)
                continue
            }
            #if DEBUG
            // Kit import: first SDL (imports and clears, commits on the shared queue), then the
            // host buffer with only encodePresent. If SDL fails, the host counts sdlFail and
            // clears itself (encodeClearPasses); the frame is presented anyway.
            if kitMultiviewSession != nil {
                if kitMultiviewFrame(drawable: drawable, deviceAnchor: deviceAnchor) {
                    continue
                }
                statSdlFail += 1
                sdlFailTotal += 1
            } else if kitImportSession != nil || kitImportFailed {
                if kitImportClear(drawable: drawable) {
                    // Diagnostics: if SDL read back in this frame, the host reads the same spot
                    // before the present (first texture of the drawable).
                    if let session = kitImportSession, let afterSDL = KitProbe.lastVerify(session: session),
                       let firstView = drawable.views.first {
                        pendingVerify = (afterSDL, drawable.colorTextures[firstView.textureMap.textureIndex])
                    }
                    continue
                }
                statSdlFail += 1
                sdlFailTotal += 1
            }
            #endif
            encodeClearPasses(drawable: drawable, commandBuffer: commandBuffer, deviceAnchor: deviceAnchor, blackOnly: blackOnly)
        }

        // Lateness right before encodePresent: presentation time minus now, same time base.
        // Negative means the frame is submitted after its presentation time.
        let lateness = presentationTime - LayerRenderer.Clock().now.timeInterval

        #if DEBUG
        // Import diagnostics: read-back in the host buffer, as the last content before encodePresent.
        encodeVerifyBeforePresent(commandBuffer: commandBuffer, frameIndex: frame.frameIndex)
        #endif

        // encodePresent last, after all content passes.
        for drawable in drawables {
            drawable.encodePresent(commandBuffer: commandBuffer)
        }
        // Always commit and present, even in the background. A present without a commit left the
        // drawable hanging, the next host buffer ran into the GPU timeout. The one host buffer in
        // the background may be rejected by the system (BackgroundExecutionNotPermitted), that
        // counts as expected.
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
        // Apple's deadline applies to the CPU: command buffer committed and endSubmission before
        // renderingDeadline. cpuMargin = deadline minus now; plus the wait time and the way to
        // the first commit of this frame. Timestamps only, no synchronisation.
        CelesteProbe.frameTiming.noteCpu(waitOpt: waitOpt, toFirstCommit: toFirstCommit,
                                         cpuMargin: renderingDeadline - LayerRenderer.Clock().now.timeInterval,
                                         queryDrawables: queryDrawablesSeconds, anchorHeld: anchorHeld)
        if pauseFrameNote?.frameIndex == frame.frameIndex {
            pauseFrameNote?.committed = true
            pauseFrameNote?.presented = true
        }

        #if DEBUG
        if postStallWanted > 0 {
            postStallSamples.append((frame.frameIndex, relativeToNow, lateness))
            postStallWanted -= 1
            if postStallWanted == 0 {
                let text = postStallSamples.map {
                    String(format: "idx=%llu rel=%+.1f ms late=%+.1f ms", $0.index, $0.relative * 1000, $0.late * 1000)
                }.joined(separator: " | ")
                c64Record("[c64-stall] block \(postStallBlock)/\(stallPlan.count) first frames: \(text)")
            }
        }
        #endif

        recordStats(frameIndex: frame.frameIndex,
                    presentationTime: presentationTime,
                    lateness: lateness,
                    hasAnchor: deviceAnchor != nil,
                    drawableCount: drawables.count)
    }

    /// [c64-targets]: the target of every drawable, at the first frame and at every change of the
    /// target set (such as start and end of a screen recording). Also into the progress file.
    private func logTargetsIfChanged(_ drawables: [LayerRenderer.Drawable]) {
        let targets = drawables.map { $0.target.rawValue }
        guard targets != lastTargets else { return }
        lastTargets = targets
        let names = drawables.enumerated().map { index, drawable in
            "\(index):\(Self.name(drawable.target))(\(drawable.colorTextures.count)tex,\(drawable.views.count)views)"
        }.joined(separator: " ")
        c64Record("[c64-targets] drawables=\(drawables.count) \(names) frames=\(totalFrames)")
    }

    /// Base pass of the host for a drawable Celeste did not write: colour black, alpha 1, depth
    /// canvasClearDepth (0.0001 = 1000 m on the reverse-Z path), then the canvas with the game's
    /// 2D image and, in Debug builds, the test scene; with blackOnly just the clear. The
    /// compositor shows only pixels with alpha > 0 and depth > 0 (WWDC24, session 10092; measured
    /// on the device), so the clear is the app's own black and not passthrough. This is also the
    /// fallback when SDL fails in the kit modes.
    ///
    /// Layout .layered (default): **one** pass over all layers with
    /// `renderTargetArrayLength = number of views` (MTLRenderPass.h:321-324, "number of active
    /// layers"), slice = smallest sliceIndex of the views; canvas and test scene draw both layers
    /// with vertex amplification 2. Rate map: `rasterizationRateMaps[0]`, one map with
    /// `layerCount == layers` (Metal documentation MTLRasterizationRateMap: "one layer map for
    /// each layer"; .layered delivers one map with layerCount 2).
    ///
    /// Layout .dedicated or .shared: one pass per view on its texture. Rate map: the map with the
    /// index of the view texture if that many maps exist, otherwise the first. That .dedicated
    /// delivers one map per texture is not documented; [c64-fov] logs the actual number.
    private func encodeClearPasses(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer, deviceAnchor: DeviceAnchor?, blackOnly: Bool = false) {
        // blackOnly: only the opaque black clear (depth 1000 m, own content), no canvas and no
        // test scene (frame without a Celeste render on the stereo path)
        #if DEBUG
        let scene = blackOnly ? nil : currentTestScene()
        #endif
        let canvas = blackOnly ? nil : currentCanvasScene()
        let maps = layerRenderer.configuration.isFoveationEnabled ? drawable.rasterizationRateMaps : []
        let views = drawable.views
        guard let firstView = views.first else { return }
        let isArray = drawable.colorTextures[firstView.textureMap.textureIndex].textureType == .type2DArray
        let clearDepth = Self.canvasClearDepth
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
                c64Log.error("[c64-frame] makeRenderCommandEncoder returned nil (layered, \(views.count) layers)")
                return
            }
            encoder.label = "c64-clear layered x\(views.count)"
            // Test scene and canvas: both layers in one draw, amplification 2, the map stays on the pass.
            #if DEBUG
            scene?.encode(encoder: encoder, drawable: drawable, views: Array(views.prefix(2)),
                          viewIndices: Array(0..<min(views.count, 2)), deviceAnchor: deviceAnchor)
            #endif
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
                c64Log.error("[c64-frame] makeRenderCommandEncoder returned nil (view \(viewIndex))")
                continue
            }
            encoder.label = "c64-clear view\(viewIndex)"
            // Test scene and canvas with .dedicated/.shared: one draw per view without amplification.
            #if DEBUG
            scene?.encode(encoder: encoder, drawable: drawable, views: [view],
                          viewIndices: [viewIndex], deviceAnchor: deviceAnchor)
            #endif
            canvas?.encode(encoder: encoder, drawable: drawable, views: [view],
                           viewIndices: [viewIndex], deviceAnchor: deviceAnchor)
            encoder.endEncoding()
        }
    }

    /// Create the canvas on first use (render thread); if it fails, it stays off.
    private func currentCanvasScene() -> CanvasScene? {
        guard !canvasFailed else { return nil }
        if let canvasScene { return canvasScene }
        guard let texture = canvasTexture else {
            canvasFailed = true
            c64Record("[c64-canvas] no canvas texture from the host (prepareCanvas did not run), canvas stays off")
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

    #if DEBUG
    /// Create the test scene on first use (render thread); if it fails, it stays off.
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
    #endif

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
        depth.clearDepth = clearDepth   // the caller passes canvasClearDepth (0.0001 = 1000 m, own black); 0 would be "no content"
        return descriptor
    }

    // MARK: Foveation probe

    /// Set the render quality at run time, once after the first drawable. Only with foveation and
    /// a set upper limit; the value is clamped to maxRenderQuality, because a higher value makes
    /// CompositorServices abort.
    private func applyRenderQualityIfRequested() {
        guard !renderQualityApplied else { return }
        renderQualityApplied = true
        // default 1.0, the switch C64_RENDERQUALITY overrides.
        let wanted = HostEnvironment.string("C64_RENDERQUALITY").flatMap({ Float($0) }) ?? Self.defaultRenderQuality
        let config = layerRenderer.configuration
        guard config.isFoveationEnabled else {
            c64Record("[c64-rq] C64_RENDERQUALITY=\(wanted) ignored: foveation off")
            return
        }
        let before = layerRenderer.renderQuality.rawValue
        let clamped = max(0.0, min(config.maxRenderQuality.rawValue, wanted))
        layerRenderer.renderQuality = LayerRenderer.RenderQuality(clamped)
        c64Record(String(format: "[c64-rq] renderQuality %.3f -> %.3f (wanted %.3f, max %.3f); the transition takes a few frames per the header",
                         before, layerRenderer.renderQuality.rawValue, wanted, config.maxRenderQuality.rawValue))
    }

    /// Remember the drawable and map size of the frame (for the summary; with render quality the
    /// map changes during the first frames, the textures stay at maxRenderQuality).
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

    /// [c64-fov]: rate maps (count, layerCount, screenSize, physicalSize per layer, granularity)
    /// and per view the colour and depth texture (type, size, arrayLength, format), viewport,
    /// slice and texture index. At the first frame and at every change, at most once per second
    /// (during a render quality transition the physicalSize changes over several frames). Per
    /// frame only the numeric comparison; the text is built on a change.
    private func logFoveationIfChanged(_ drawables: [LayerRenderer.Drawable]) {
        guard let drawable = drawables.first(where: { $0.target == .builtIn }) ?? drawables.first,
              let firstView = drawable.views.first else { return }
        let maps = drawable.rasterizationRateMaps
        let texture = drawable.colorTextures[firstView.textureMap.textureIndex]
        var signature = FovSignature(maps: maps.count, screenWidth: 0, screenHeight: 0, physicalWidth: 0, physicalHeight: 0,
                                     views: drawable.views.count, textureWidth: texture.width, textureHeight: texture.height, arrayLength: texture.arrayLength)
        if let map = maps.first {
            let physical = map.physicalSize(layer: 0)
            signature.screenWidth = map.screenSize.width
            signature.screenHeight = map.screenSize.height
            signature.physicalWidth = physical.width
            signature.physicalHeight = physical.height
        }
        guard signature != lastFovSignature else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastFovSignature == nil || now - lastFovLog >= 1.0 else { return }
        lastFovSignature = signature
        lastFovLog = now

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
        c64Record(String(format: "[c64-fov] maps=%d renderQuality=%.3f frames=%llu %@",
                         maps.count, layerRenderer.renderQuality.rawValue, totalFrames, parts.joined(separator: " ")))
    }

    // MARK: Command buffer errors

    /// Completed handler (Metal thread): a status other than .completed or a set error counts as
    /// an error; line [c64-cmderr] at most once per second, also into the file.
    private func noteCommandBufferCompletion(_ buffer: MTLCommandBuffer, frameIndex: UInt64, renderingDeadline: TimeInterval, gpuFrame: UInt64, logResume: Bool = false) {
        let status = buffer.status
        let error = buffer.error
        if status == .completed {
            let gpuStart = buffer.gpuStartTime
            let gpuEnd = buffer.gpuEndTime
            let gpuSeconds = gpuEnd - gpuStart
            if gpuSeconds > 0 {
                cmdErrLock.lock()
                gpuTimeSum += gpuSeconds
                gpuTimeMax = max(gpuTimeMax, gpuSeconds)
                gpuTimeCount += 1
                cmdErrLock.unlock()
            }
            // exclusive time of the host buffer (closes the frame) and the deadline margin;
            // numbers only, no allocation.
            CelesteProbe.celesteGpuPasses.recordHost(start: gpuStart, end: gpuEnd, frame: gpuFrame)
            CelesteProbe.frameTiming.noteHostBuffer(gpuEnd: gpuEnd, deadline: renderingDeadline)
        }
        if logResume {
            // the first three frames after resuming, status and GPU time.
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            let errorText = (error as NSError?).map { "\($0.domain) code=\($0.code) \($0.localizedDescription)" } ?? "-"
            c64Record("[c64-resume-frame] tMs=\(LaunchClock.tMs) frame=\(frameIndex) status=\(Self.name(status)) gpuMs=\(String(format: "%.2f", gpuMs)) error=\(errorText)")
        }
        guard status != .completed || error != nil else { return }
        // The one host buffer that was committed with the background flag set may be rejected
        // by the system (MTLCommandBufferError.notPermitted, "Insufficient Permission (to submit
        // GPU work from background)"). Expected, own counter, always one line; timeout and other
        // errors as before.
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
        // A deliberately uncommitted buffer (pause before the commit) reports notEnqueued
        // without an error; that is no GPU error.
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
        // GPU timeouts around a pause (host buffer that was in the GPU during the switch to the
        // background) are only noted here: frame, time, status.
        c64Record("[c64-cmderr] tMs=\(LaunchClock.tMs) frame=\(frameIndex) status=\(Self.name(status)) error=\(errorText)")
    }

    /// Read and reset the GPU time of the host buffers in the window (render thread, once per second).
    private func takeGpuTime() -> (mean: Double, max: Double, count: Int) {
        cmdErrLock.lock()
        defer { cmdErrLock.unlock() }
        let result = (gpuTimeCount > 0 ? gpuTimeSum / Double(gpuTimeCount) : 0, gpuTimeMax, gpuTimeCount)
        gpuTimeSum = 0
        gpuTimeMax = 0
        gpuTimeCount = 0
        return result
    }

    /// Read and reset the counter (render thread, once per second).
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

    // MARK: Statistics

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
                // jump of the presentationTime over 1.5 grid intervals; the grid is the mean
                // interval of the last window (start 1/90 s).
                if interval > 1.5 * presentRasterInterval {
                    CelesteProbe.frameTiming.noteGap()
                }
            }
        }
        lastPresentationTime = presentationTime

        if let last = lastFrameIndex, frameIndex > last + 1 {
            statGaps += frameIndex - last - 1
        }
        lastFrameIndex = frameIndex

        let now = CFAbsoluteTimeGetCurrent()
        // memory every 10 s (plateau of the SDL copies of A after the first level start).
        if now - lastMemLog >= 10.0 {
            lastMemLog = now
            c64Record("[c64-mem] tMs=\(LaunchClock.tMs) " + String(format: "footprintMB=%.1f availableMB=%.1f", ProbeContext.physFootprintMB, ProbeContext.availableMemoryMB))
        }
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
            // GPU time of the host buffers (clear, test scene, canvas; not SDL's own buffers).
            let gpu = takeGpuTime()
            line += String(format: " hostGpu(ms) mean=%.3f max=%.3f n=%d", gpu.mean * 1000, gpu.max * 1000, gpu.count)
            #if DEBUG
            // Kit import: CPU time of the SDL part (wrappers, passes, submit, release) in the window.
            if let session = kitImportSession {
                let stats = KitProbe.takeImportStats(session: session)
                let meanMs = stats.frames > 0 ? stats.sum_ms / Double(stats.frames) : 0
                line += String(format: " sdl(ms) mean=%.3f max=%.3f sdlFrames=%u sdlFail=%d", meanMs, stats.max_ms, stats.frames, statSdlFail)
            } else if let session = kitMultiviewSession {
                let stats = KitProbe.takeMultiviewStats(session: session)
                let meanMs = stats.frames > 0 ? stats.sum_ms / Double(stats.frames) : 0
                line += String(format: " sdl(ms) mean=%.3f max=%.3f sdlFrames=%u sdlFail=%d passes=%lu draws=%lu", meanMs, stats.max_ms, stats.frames, statSdlFail, stats.passes_total, stats.draws_total)
                // GPU time of the SDL command buffers in the window (completion callback).
                let gpuMean = stats.gpu_frames > 0 ? stats.gpu_sum_ms / Double(stats.gpu_frames) : 0
                line += String(format: " gpu(ms) mean=%.3f max=%.3f gpuFrames=%u msaa=%u", gpuMean, stats.gpu_max_ms, stats.gpu_frames, stats.msaa_samples)
            } else if kitImportFailed {
                line += " sdl=none sdlFail=\(statSdlFail)"
            }
            statSdlFail = 0
            #endif
            c64Record(line)
            // grid for presentGaps from the window; jumps move the mean only a little (one
            // 22 ms jump among 90 frames: +0.12 ms).
            if mean > 0 { presentRasterInterval = mean }
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

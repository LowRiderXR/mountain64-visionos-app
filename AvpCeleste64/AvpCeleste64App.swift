//
//  AvpCeleste64App.swift
//  AvpCeleste64
//
//  Start window and ImmersiveSpace (full immersion) with CompositorLayer. The app starts like
//  Xcode's templates with a window (Info.plist: preferred role
//  UIWindowSceneSessionRoleApplication, initial style Full under the UI role). The window is
//  invisible (.plain, Color.clear, small) and opens the space at once in its .task; on .opened it
//  closes itself (dismissWindow). Launching straight into a CP scene left the space on the M5 in
//  the mixed style (passthrough) and the world tracking paused.
//  Order: in the start window first canvas, queue, audio session, celeste_init with the loading
//  ticks and celeste_set_canvas, while only the window scene is connected (SDL's hidden UIWindow
//  attaches to it); then openImmersiveSpace, renderer and ARKit in the layer closure,
//  dismissWindow on .opened. Starting Celeste only after the window closed (SDL window on the
//  CPImmersiveScene) let the WorldTrackingProvider on the M5 fall to paused. Layer
//  configuration: layout .layered, foveation on, render quality 1.0, colour and depth format from
//  the capabilities (depth depth32Float if offered).
//

import CompositorServices
import os
import SwiftUI

/// Clock since process start for the start lines (tMs), readable from any thread.
nonisolated enum LaunchClock {
    static let reference = DispatchTime.now()
    /// Milliseconds since the start (mach time: keeps running while the process is suspended,
    /// stands still while the device sleeps).
    static var elapsedMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds - reference.uptimeNanoseconds) / 1_000_000
    }
    static var tMs: String {
        String(format: "%.1f", elapsedMs)
    }
}

@main
struct AvpCeleste64App: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = LaunchClock.reference
        // Create and rotate the probe file (or, without the probe, only delete the old Documents file).
        _ = ProgressFile.shared
    }

    var body: some Scene {
        WindowGroup(id: GameStartup.launcherWindowID) {
            LauncherView()
                .environment(appModel)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultSize(width: 240, height: 120)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveContent(appModel: appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Log lines only: phase of the scenes as SwiftUI sees it, plus the app state from
            // UIKit, to classify ARKit pauses.
            c64Record("[c64-scene] tMs=\(LaunchClock.tMs) scenePhase=\(phase) \(CelesteProbe.lifecycleLine)")
            // second way to clear the background flag (in case didBecomeActive came before the
            // scene change); clears only when UIKit reports the app as active.
            if phase == .active, CelesteProbe.pauseState.isBackground {
                CelesteProbe.pauseState.clearBackgroundIfForeground(reason: "scenePhase active")
            }
        }
    }
}

/// Invisible start window: no glass (.plain), no content. Its .task starts Celeste (prepareHost
/// and run, while only the window scene is connected), opens the space and closes the window;
/// the measurement lines after closing run in their own task (GameStartup.logAfterLauncherClosed),
/// because .task ends with the window.
struct LauncherView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 240, height: 120)
            .task {
                c64Record("[c64-launch] tMs=\(LaunchClock.tMs) launcher task; \(CelesteProbe.lifecycleLine)")
                guard appModel.immersiveState == .closed else { return }
                GameStartup.prepareHost()
                // Audio session before celeste_init (FMOD starts in there), without blocking the
                // main thread: the task waits, the main thread stays free.
                if CelesteProbe.gameEnabled {
                    await CelesteProbe.configureAudioSession()
                }
                GameStartup.run(appModel: appModel)
                appModel.immersiveState = .opening
                c64Record("[c64-launch] tMs=\(LaunchClock.tMs) openImmersiveSpace")
                let result = await openImmersiveSpace(id: appModel.immersiveSpaceID)
                switch result {
                case .opened:
                    appModel.immersiveState = .open
                    c64Record("[c64-launch] tMs=\(LaunchClock.tMs) opened; \(CelesteProbe.lifecycleLine)")
                    CelesteProbe.windowSnapshot("before-dismiss", since: LaunchClock.reference)
                    if CelesteProbe.gameEnabled {
                        CelesteProbe.sdlWindowInfo("before-dismiss")
                    }
                    GameStartup.logAfterLauncherClosed()
                    c64Record("[c64-launch] tMs=\(LaunchClock.tMs) dismissWindow(launcher)")
                    dismissWindow(id: GameStartup.launcherWindowID)
                case .userCancelled:
                    appModel.immersiveState = .closed
                    c64Record("[c64-launch] tMs=\(LaunchClock.tMs) openImmersiveSpace: userCancelled")
                case .error:
                    appModel.immersiveState = .closed
                    c64Record("[c64-launch] tMs=\(LaunchClock.tMs) openImmersiveSpace: error")
                @unknown default:
                    appModel.immersiveState = .closed
                    c64Record("[c64-launch] tMs=\(LaunchClock.tMs) openImmersiveSpace: unknown result")
                }
            }
    }
}

struct ImmersiveContent: CompositorContent {
    var appModel: AppModel

    var body: some CompositorContent {
        CompositorLayer(configuration: ProbeLayerConfiguration()) { @MainActor layerRenderer in
            // Only the render loop; Celeste is already loaded (start window), it takes over the
            // host's queue and ticks from the first frame; ARKit starts here.
            c64Record("[c64-launch] tMs=\(LaunchClock.tMs) layer closure; \(CelesteProbe.lifecycleLine)")
            Renderer.start(layerRenderer: layerRenderer, appModel: appModel)
        }
        // Log the system recenter (long Crown press) with the last head pose before the event. On
        // ended let the reference O be set anew a few frames later (at ended the pose still shows
        // the old values, probe of 2026-10-27).
        .onWorldRecenter { phase in
            let name: String
            switch phase {
            case .began: name = "began"
            case .ended:
                name = "ended"
                CelesteProbe.StereoOrigin.shared.recenterEnded()
            @unknown default: name = "phase\(phase)"
            }
            c64Record("[c64-recenter] tMs=\(LaunchClock.tMs) phase=\(name) \(CelesteProbe.headPose.line)")
        }
    }
}

/// Start of the game on the main thread in the start window, before the space opens: prepareHost
/// (device, queue, canvas), run (audio session, celeste_init, loading ticks, celeste_set_canvas,
/// release). The status lines go into the probe ([c64-start]). In Debug builds a kit mode
/// (C64_KIT) switches the game off and starts the kit test scene.
@MainActor
enum GameStartup {
    static let launcherWindowID = "c64-launcher"
    private static var startTask: Task<Void, Never>?

    /// Before the space opens: device and queue (the renderer takes them over in the layer closure)
    /// and the canvas texture. No SDL, no Celeste.
    static func prepareHost() {
        c64Record("[c64-start] prepareHost game=\(CelesteProbe.gameEnabled ? 1 : 0)")
        guard CelesteProbe.gameEnabled else { return }
        if !CelesteProbe.prepareCanvas() {
            c64Error("[c64-start] canvas could not be created")
        }
    }

    /// After dismissWindow: wait until no window scene with role windowApplication is connected any
    /// more (at most 3 s, polling every 50 ms), then the measurement lines: scenes, SDL's window
    /// (has it lost its scene?), lifecycle. Own task, so the end of the start window does not
    /// cancel it. Log only, no change in behaviour.
    static func logAfterLauncherClosed() {
        guard startTask == nil else { return }
        startTask = Task { @MainActor in
            let waitStart = DispatchTime.now()
            var polls = 0
            while UIApplication.shared.connectedScenes.contains(where: { $0.session.role == .windowApplication }) {
                polls += 1
                if Double(DispatchTime.now().uptimeNanoseconds - waitStart.uptimeNanoseconds) > 3e9 {
                    c64Record("[c64-launch] tMs=\(LaunchClock.tMs) launcher scene still connected after 3 s; \(CelesteProbe.lifecycleLine)")
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            c64Record("[c64-launch] tMs=\(LaunchClock.tMs) launcher closed after \(polls) polls; \(CelesteProbe.lifecycleLine)")
            CelesteProbe.windowSnapshot("after-dismiss", since: LaunchClock.reference)
            if CelesteProbe.gameEnabled {
                CelesteProbe.sdlWindowInfo("after-dismiss")
            }
        }
    }

    static func run(appModel: AppModel) {
        let start = DispatchTime.now()
        c64Record("[c64-start] tMs=\(LaunchClock.tMs) game=\(CelesteProbe.gameEnabled ? 1 : 0) thread=\(Thread.isMainThread ? "main" : "other")")
        if CelesteProbe.gameEnabled {
            // The audio session is configured and active (LauncherView waits for it before run
            // runs); FMOD starts in celeste_init.
            // Lifecycle and audio signals into the log.
            CelesteProbe.LifecycleMonitor.shared.start()
            // Load Celeste, final image into the canvas (without a running tick), release; the
            // canvas comes from prepareHost.
            if CelesteProbe.canvasTexture == nil {
                c64Error("[c64-start] canvas missing (prepareHost), Celeste not started")
            } else {
                let result = CelesteProbe.runInit(since: start)
                if result.ok, CelesteProbe.attachCanvasToGame() {
                    CelesteProbe.tickState.markReady()
                    #if DEBUG
                    // the canvas snapshot after 600 ticks (blit, waitUntilCompleted, PNG in
                    // Documents, about 100 ms on the render thread) only with C64_SNAPSHOT=1.
                    if HostEnvironment.string("C64_SNAPSHOT") == "1", let queue = CelesteProbe.commandQueue, let texture = CelesteProbe.canvasTexture {
                        CelesteProbe.tickState.enableSnapshot(queue: queue, texture: texture)
                    }
                    #endif
                    c64Record("[c64-start] Celeste loaded (\(result.version)), final image on the canvas; the render thread ticks from the first frame")
                } else {
                    c64Error("[c64-start] Celeste start or canvas failed: \(result.capabilitiesLine)")
                }
            }
        } else {
            c64Record("[c64-start] game off (kit mode)")
        }

        #if DEBUG
        // Kit test scenes behind C64_KIT (default off), on the main thread before the loop:
        //   =1       basic: whole scene here, SDL creates device and queue itself, SDL_Quit at the end.
        //   =inject  only SDL_Init here; the scene runs on the render thread before the first frame.
        //   =import, =multiview: only SDL_Init here; the rest on the render thread.
        if let kitMode = KitProbe.mode {
            switch kitMode {
            case .basic:
                let result = KitProbe.runBasic()
                c64Record("[c64-start] kit test scene \(result == 0 ? "passed" : "failed at step \(result)")")
            case .inject, .import, .multiview:
                let ok = KitProbe.initSDL(for: kitMode)
                c64Record("[c64-start] SDL_Init for kit mode \(kitMode.rawValue): \(ok ? "ok" : "failed")")
            }
        }
        #endif

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        c64Record("[c64-start] tMs=\(LaunchClock.tMs) done ms=\(CelesteProbe.format(ms))")
    }
}

/// Layer configuration. The renderer reads the chosen values back through
/// layerRenderer.configuration and prints them into the start line [c64-ctx].
nonisolated struct ProbeLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let environment = HostEnvironment.values

        // Foveation on (default of the product); C64_FOVEATION=0 turns it off.
        let foveation = environment["C64_FOVEATION"] != "0" && capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveation

        // Layout: default .layered (one 2D array texture, eye = slice; the format the stereo world
        // pass requires, both views in one pass). Switch C64_LAYOUT=dedicated for comparison.
        let layoutOptions: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveation ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: layoutOptions)
        let wantDedicated = environment["C64_LAYOUT"] == "dedicated"
        if wantDedicated, layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else if layouts.contains(.layered) {
            configuration.layout = .layered
        } else if layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else if let first = layouts.first {
            configuration.layout = first
        }

        // Render quality: the upper limit is only meaningful with foveation (Apple documentation on
        // maxRenderQuality; both the limit here and the runtime value must be set). Default 1.0,
        // switch C64_RENDERQUALITY with a value 0..1; the runtime value is set in the renderer
        // (layer_renderer.h:230-232).
        if foveation {
            let wanted = environment["C64_RENDERQUALITY"].flatMap({ Float($0) }) ?? Renderer.defaultRenderQuality
            configuration.maxRenderQuality = LayerRenderer.RenderQuality(max(0.0, min(1.0, wanted)))
        }

        // Colour format: 8-bit sRGB if offered (the port's format), otherwise the default.
        let colorFormats = capabilities.supportedColorFormats(options: [])
        if colorFormats.contains(.bgra8Unorm_srgb) {
            configuration.colorFormat = .bgra8Unorm_srgb
        }

        // Depth format: depth32Float if offered, otherwise the default.
        let depthFormats = capabilities.supportedDepthFormats
        if depthFormats.contains(.depth32Float) {
            configuration.depthFormat = .depth32Float
        }

        let layoutNames = layouts.map { Self.name($0) }.joined(separator: ",")
        let colorNames = colorFormats.map { ProbeContext.name($0) }.joined(separator: ",")
        let depthNames = depthFormats.map { ProbeContext.name($0) }.joined(separator: ",")
        let maxQuality = configuration.maxRenderQuality.rawValue
        let defaultQuality = capabilities.defaultRenderQuality.rawValue
        let layoutMode = foveation ? "foveated" : "plain"
        c64Record("[c64-caps] supportsFoveation=\(capabilities.supportsFoveation) layouts(\(layoutMode))=\(layoutNames) colorFormats=\(colorNames) depthFormats=\(depthNames) defaultRenderQuality=\(defaultQuality) maxRenderQuality=\(maxQuality)")
    }

    static func name(_ layout: LayerRenderer.Layout) -> String {
        switch layout {
        case .dedicated: return "dedicated"
        case .shared: return "shared"
        case .layered: return "layered"
        @unknown default: return "layout\(layout.rawValue)"
        }
    }
}

//
//  AvpCeleste64App.swift
//  AvpCeleste64
//
//  Startfenster und ImmersiveSpace (volle Immersion) mit CompositorLayer, M4a.5b-5: Die App
//  startet wie Xcodes Vorlagen und Vice City mit einem Fenster (Info.plist: bevorzugte Rolle
//  UIWindowSceneSessionRoleApplication, Anfangsstil Full unter der UI-Rolle). Das Fenster ist
//  unsichtbar (.plain, Color.clear, klein) und öffnet in seinem .task sofort den Raum; bei
//  .opened schliesst es sich (dismissWindow). Der direkte Start in eine CP-Szene liess den Raum
//  auf der M5 im gemischten Stil (Passthrough) und das World Tracking in paused.
//  Reihenfolge wie im alten Knopf-Pfad (M4a.5b-6): im Startfenster zuerst Leinwand, Queue,
//  Audio-Session, celeste_init mit den Ladeticks und celeste_set_canvas, solange nur die
//  Fensterszene verbunden ist (SDLs verstecktes UIWindow hängt sich an sie); dann
//  openImmersiveSpace, im Layer-Closure Renderer und ARKit, bei .opened dismissWindow. Der
//  Versuch, Celeste erst nach dem Schliessen zu starten (SDL-Fenster an der CPImmersiveScene),
//  liess den WorldTrackingProvider auf der M5 in paused fallen. Konfiguration des Layers: Layout
//  .layered, Foveation an, Render Quality 1,0, Farb- und Tiefenformat aus den Capabilities
//  (Tiefe depth32Float, falls angeboten).
//

import CompositorServices
import os
import SwiftUI

/// Uhr seit dem Prozessstart für die Startzeilen (tMs), von jedem Thread lesbar.
nonisolated enum LaunchClock {
    static let reference = DispatchTime.now()
    /// Millisekunden seit dem Start (mach-Zeit: läuft während einer Prozess-Suspendierung weiter,
    /// steht im Geräteschlaf).
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
            // Nur Logzeilen: Phase der Szenen aus Sicht von SwiftUI, dazu der App-Zustand aus
            // UIKit, um ARKit-Pausen einzuordnen.
            c64Record("[c64-scene] tMs=\(LaunchClock.tMs) scenePhase=\(phase) \(CelesteProbe.lifecycleLine)")
            // M4a.5c-2: zweiter Weg, das Hintergrund-Flag zu löschen (falls didBecomeActive vor
            // dem Szenenwechsel kam); löscht nur, wenn UIKit die App als active meldet.
            if phase == .active, CelesteProbe.pauseState.isBackground {
                CelesteProbe.pauseState.clearBackgroundIfForeground(reason: "scenePhase active")
            }
        }
    }
}

/// Unsichtbares Startfenster: kein Glas (.plain), kein Inhalt. Sein .task startet Celeste
/// (prepareHost und run, solange nur die Fensterszene verbunden ist), öffnet den Raum und
/// schliesst das Fenster; die Messzeilen nach dem Schliessen laufen in einem eigenen Task
/// (GameStartup.logAfterLauncherClosed), weil .task mit dem Fenster endet.
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
                GameStartup.run(appModel: appModel)
                appModel.immersiveState = .opening
                c64Record("[c64-launch] tMs=\(LaunchClock.tMs) openImmersiveSpace")
                let result = await openImmersiveSpace(id: appModel.immersiveSpaceID)
                switch result {
                case .opened:
                    appModel.immersiveState = .open
                    c64Record("[c64-launch] tMs=\(LaunchClock.tMs) opened; \(CelesteProbe.lifecycleLine)")
                    CelesteProbe.windowSnapshot("before-dismiss", since: LaunchClock.reference)
                    if CelesteProbe.isRequested, CelesteProbe.mode != .probe, CelesteProbe.mode != .window {
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
                    c64Record("[c64-launch] tMs=\(LaunchClock.tMs) openImmersiveSpace: unbekanntes Ergebnis")
                }
            }
    }
}

struct ImmersiveContent: CompositorContent {
    var appModel: AppModel

    var body: some CompositorContent {
        CompositorLayer(configuration: ProbeLayerConfiguration()) { @MainActor layerRenderer in
            // Nur die Renderschleife; Celeste ist schon geladen (Startfenster), sie übernimmt
            // die Queue des Hosts und tickt ab dem ersten Frame; ARKit startet hier wie im
            // Knopf-Pfad.
            c64Record("[c64-launch] tMs=\(LaunchClock.tMs) layer closure; \(CelesteProbe.lifecycleLine)")
            Renderer.start(layerRenderer: layerRenderer, appModel: appModel)
        }
        // M4b.1b: System-Recenter (Crown lang) protokollieren, mit der letzten Kopfpose vor dem
        // Ereignis. M4b.4: bei ended den Bezugspunkt O neu setzen lassen, einige Frames später
        // (bei ended zeigt die Pose noch die alten Werte, Probe 2026-10-27).
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

/// Start des Spiels auf dem Hauptthread im Startfenster (M4a.5b-6), vor dem Öffnen des Raums:
/// prepareHost (Device, Queue, Leinwand), run (Audio-Session, celeste_init, Ladeticks,
/// celeste_set_canvas, Freigabe). Die Statuszeilen gehen ins Log ([c64-start]).
/// Standard ist der Modus play (C64_CELESTE unset); die Testmodi bleiben über C64_CELESTE und
/// die Kit-Modi über C64_KIT erreichbar.
@MainActor
enum GameStartup {
    static let launcherWindowID = "c64-launcher"
    private static var startTask: Task<Void, Never>?

    /// Vor dem Öffnen des Raums: Device und Queue (der Renderer übernimmt sie im Layer-Closure)
    /// und die Leinwandtextur für die Modi canvas und play. Kein SDL, kein Celeste.
    static func prepareHost() {
        let mode = CelesteProbe.mode
        c64Record("[c64-start] prepareHost mode=\(mode.rawValue) C64_CELESTE=\(ProbeContext.environment(CelesteProbe.environmentKey)) C64_KIT=\(ProbeContext.environment(KitProbe.environmentKey))")
        switch mode {
        case .canvas, .play:
            if !CelesteProbe.prepareCanvas() {
                c64Record("[c64-start] Leinwand konnte nicht angelegt werden")
            }
        case .tick, .initialize, .probe:
            _ = CelesteProbe.ensureHostDevice()
        case .off, .window:
            break
        }
    }

    /// Nach dismissWindow: warten, bis keine Fensterszene mit Rolle windowApplication mehr
    /// verbunden ist (höchstens 3 s, Abfrage alle 50 ms), dann die Messzeilen: Szenen, SDLs
    /// Fenster (hat es seine Szene verloren?), Lebenszyklus. Eigener Task, damit das Ende des
    /// Startfensters ihn nicht abbricht. Nur Log, keine Änderung am Verhalten.
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
            if CelesteProbe.isRequested, CelesteProbe.mode != .probe, CelesteProbe.mode != .window {
                CelesteProbe.sdlWindowInfo("after-dismiss")
            }
        }
    }

    static func run(appModel: AppModel) {
        let start = DispatchTime.now()
        let celesteMode = CelesteProbe.mode
        c64Record("[c64-start] tMs=\(LaunchClock.tMs) mode=\(celesteMode.rawValue) thread=\(Thread.isMainThread ? "main" : "other")")
        if celesteMode != .off, celesteMode != .window, celesteMode != .probe {
            // Vor celeste_init: Audio-Session unabhängig von Fensterszenen (Vice City: ohne
            // .playback starb der Ton mit dem 2D-Fenster; FMOD überlässt die Kategorie der App).
            CelesteProbe.configureAudioSession()
            // Lebenszyklus- und Audio-Signale ins Log (M4a.5c).
            CelesteProbe.LifecycleMonitor.shared.start()
        }

        switch celesteMode {
        case .off:
            c64Record("[c64-start] Celeste aus")
        case .probe:
            // M1a.2: celeste_version und celeste_capabilities_get, kein celeste_init.
            let result = CelesteProbe.runProbe()
            c64Record("[c64-start] Celeste-Hülle: \(result.ok ? "\(result.version); \(result.capabilitiesLine)" : "Fähigkeitsprüfung fehlgeschlagen")")
        case .initialize:
            // M1a.4: celeste_init mit verstecktem Fenster und die ersten Ticks; Szenen-Schnappschüsse
            // bei 0,2, 1 und 2 s laufen nebenher.
            let result = CelesteProbe.runInit(since: start)
            c64Record("[c64-start] Celeste gestartet: \(result.ok ? "\(result.version); nach init \(result.capabilitiesLine)" : "fehlgeschlagen, \(result.capabilitiesLine)")")
            Task { await snapshotMarks(since: start) }
        case .window:
            c64Record("[c64-start] Vergleichslauf ohne Celeste: Szenen-Schnappschüsse bei 0, 0,2, 1 und 2 s")
            Task { await snapshotMarks(since: start) }
        case .canvas:
            // M4a.2: Leinwand ohne Celeste (angelegt in prepareHost).
            c64Record("[c64-start] Leinwand \(CelesteProbe.canvasTexture != nil ? "bereit (\(CelesteProbe.canvasWidth)×\(CelesteProbe.canvasHeight), \(CelesteProbe.canvasFovDegrees)°)" : "fehlt")")
        case .play:
            // M4a.3: Celeste laden, Endbild in die Leinwand (ohne laufenden Tick), Freigabe; die
            // Leinwand kommt aus prepareHost.
            guard CelesteProbe.canvasTexture != nil else {
                c64Record("[c64-start] Leinwand fehlt (prepareHost), Celeste nicht gestartet")
                break
            }
            let result = CelesteProbe.runInit(since: start)
            if result.ok, CelesteProbe.attachCanvasToGame() {
                // M4b L6: der Leinwand-Schnappschuss nach 600 Ticks (Blit, waitUntilCompleted, PNG
                // in Documents, rund 100 ms auf dem Render-Thread) nur noch mit C64_SNAPSHOT=1;
                // er war der eine Ausreisser kurz nach dem Levelstart
                let snapshot = ProcessInfo.processInfo.environment["C64_SNAPSHOT"] == "1"
                CelesteProbe.tickState.markReady(snapshotQueue: snapshot ? CelesteProbe.commandQueue : nil,
                                                 snapshotTexture: snapshot ? CelesteProbe.canvasTexture : nil)
                c64Record("[c64-start] Celeste geladen (\(result.version)), Endbild auf der Leinwand; der Render-Thread tickt ab dem ersten Frame\(snapshot ? "" : "; Leinwand-Schnappschuss aus (C64_SNAPSHOT=1)")")
            } else {
                c64Record("[c64-start] Celeste-Start oder Leinwand fehlgeschlagen: \(result.capabilitiesLine)")
            }
        case .tick:
            // M1a.5: init und Laden, dann Freigabe ohne Leinwand.
            let result = CelesteProbe.runInit(since: start)
            if result.ok {
                CelesteProbe.tickState.markReady()
                c64Record("[c64-start] Celeste geladen (\(result.version)); der Render-Thread tickt ab dem ersten Frame")
            } else {
                c64Record("[c64-start] Celeste-Start fehlgeschlagen: \(result.capabilitiesLine)")
            }
        }

        // Kit-Testszenen hinter C64_KIT (Standard aus), auf dem Hauptthread vor der Schleife:
        //   =1       K0: ganze Szene hier, SDL erzeugt Device und Queue selbst, SDL_Quit am Ende.
        //   =inject  K1a: hier nur SDL_Init; die Szene läuft im Render-Thread vor dem ersten Frame.
        //   =import  K1b, =multiview K2: hier nur SDL_Init; der Rest im Render-Thread.
        if let kitMode = KitProbe.mode {
            switch kitMode {
            case .basic:
                let result = KitProbe.runBasic()
                c64Record("[c64-start] Kit-Testszene \(result == 0 ? "bestanden" : "fehlgeschlagen in Schritt \(result)")")
            case .inject, .import, .multiview:
                let ok = KitProbe.initSDL(for: kitMode)
                c64Record("[c64-start] SDL_Init für Kit-Modus \(kitMode.rawValue): \(ok ? "ok" : "fehlgeschlagen")")
            }
        }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        c64Record("[c64-start] tMs=\(LaunchClock.tMs) done ms=\(CelesteProbe.format(ms))")
    }

    /// Szenen-Schnappschüsse bei 0,2 s, 1 s und 2 s nach dem Start (Modi init und window).
    private static func snapshotMarks(since start: DispatchTime) async {
        for mark in [0.2, 1.0, 2.0] {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            if elapsed < mark {
                try? await Task.sleep(for: .seconds(mark - elapsed))
            }
            CelesteProbe.windowSnapshot("t\(mark)s", since: start)
        }
    }
}

/// Layer-Konfiguration. Gewählte Werte liest der Renderer über layerRenderer.configuration
/// zurück und druckt sie in die Startzeile [c64-ctx].
nonisolated struct ProbeLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let environment = ProcessInfo.processInfo.environment

        // Foveation an (Standard des Produkts, M4a.5b); C64_FOVEATION=0 schaltet sie aus.
        let foveation = environment["C64_FOVEATION"] != "0" && capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveation

        // Layout: Standard .layered (eine 2D-Array-Textur, Auge = Slice; Zielformat des Ports,
        // weil Multiview eingeplant ist). Schalter C64_LAYOUT=dedicated für den Vergleich.
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

        // Render Quality: Obergrenze nur mit Foveation sinnvoll (Apple-Doku zu maxRenderQuality,
        // Plattformwissen: beide Regler setzen). Standard 1,0 (M4a.5b), Schalter C64_RENDERQUALITY
        // mit Wert 0..1; der Laufzeitwert wird im Renderer gesetzt (layer_renderer.h:230-232).
        if foveation {
            let wanted = environment["C64_RENDERQUALITY"].flatMap({ Float($0) }) ?? Renderer.defaultRenderQuality
            configuration.maxRenderQuality = LayerRenderer.RenderQuality(max(0.0, min(1.0, wanted)))
        }

        // Farbformat: 8 Bit sRGB, falls angeboten (geplantes Format des Ports), sonst Vorgabe.
        let colorFormats = capabilities.supportedColorFormats(options: [])
        if colorFormats.contains(.bgra8Unorm_srgb) {
            configuration.colorFormat = .bgra8Unorm_srgb
        }

        // Tiefenformat: depth32Float, falls angeboten, sonst Vorgabe.
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
        c64Log.notice("[c64-caps] supportsFoveation=\(capabilities.supportsFoveation, privacy: .public) layouts(\(layoutMode, privacy: .public))=\(layoutNames, privacy: .public) colorFormats=\(colorNames, privacy: .public) depthFormats=\(depthNames, privacy: .public) defaultRenderQuality=\(defaultQuality, privacy: .public) maxRenderQuality=\(maxQuality, privacy: .public)")
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

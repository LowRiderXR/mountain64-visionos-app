//
//  ContentView.swift
//  AvpCeleste64
//
//  Fenster: Statuszeile und ein Knopf, der den ImmersiveSpace öffnet.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        VStack(spacing: 20) {
            Text("Celeste 64 für visionOS")
                .font(.title)
            Text("P0a: Gerüst des Immersive-Pfads mit Stall-Probe")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(appModel.statusLine)
                .font(.body)
                .multilineTextAlignment(.center)

            if !appModel.frameLine.isEmpty {
                Text(appModel.frameLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Button("ImmersiveSpace öffnen") {
                Task { await openSpace() }
            }
            .disabled(appModel.immersiveState != .closed)

            Text("Fortschrittsdatei: Documents/\(ProgressFile.fileName)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(minWidth: 520)
        .task {
            // M1a.2: Hülle ohne Spiel hinter C64_CELESTE=probe (Standard aus): celeste_version und
            // celeste_capabilities_get aus Celeste64.VisionOS.framework, auf dem Hauptthread, vor
            // den Kit-Modi und ohne sie zu berühren. Kein celeste_init in dieser Stufe.
            // M1a.4 hinter C64_CELESTE=init: dazu celeste_init mit verstecktem Fenster und die
            // ersten Ticks auf dem Hauptthread. M1a.4b: Fenster-Schnappschüsse der Szene zu festen
            // Zeitpunkten nach dem Start (0,2 s, 1 s, 2 s), im Modus init wie im Vergleichsmodus
            // window ohne Celeste; so trennt sich SDLs Geometrieanfrage vom SwiftUI-Layout.
            if let celesteMode = CelesteProbe.mode, !celesteProbeRan {
                celesteProbeRan = true
                let probeStart = DispatchTime.now()
                switch celesteMode {
                case .probe:
                    let result = CelesteProbe.runProbe()
                    appModel.statusLine = result.ok
                        ? "Celeste-Hülle: \(result.version); \(result.capabilitiesLine). Siehe Log [c64-celeste]."
                        : "Celeste-Hülle: Fähigkeitsprüfung fehlgeschlagen, siehe Log [c64-celeste]."
                case .initialize:
                    CelesteProbe.windowSnapshot("t0", since: probeStart)
                    let result = CelesteProbe.runInit(since: probeStart)
                    appModel.statusLine = result.ok
                        ? "Celeste gestartet (Hauptthread, Fenster versteckt): \(result.version); nach init \(result.capabilitiesLine). Siehe Log [c64-celeste]."
                        : "Celeste-Start fehlgeschlagen: \(result.capabilitiesLine). Siehe Log [c64-celeste]."
                    await snapshotMarks(since: probeStart)
                case .window:
                    CelesteProbe.windowSnapshot("t0", since: probeStart)
                    appModel.statusLine = "Vergleichslauf Fenster ohne Celeste: Schnappschüsse bei 0, 0,2, 1 und 2 s. Siehe Log [c64-celeste]."
                    await snapshotMarks(since: probeStart)
                case .canvas:
                    // M4a.2: Device, Queue und gefüllte Leinwandtextur anlegen; der Renderer nimmt
                    // dieselbe Queue und zeichnet die Leinwand, sobald der ImmersiveSpace offen ist.
                    let ok = CelesteProbe.prepareCanvas()
                    appModel.statusLine = ok
                        ? "Leinwand bereit (\(CelesteProbe.canvasWidth)×\(CelesteProbe.canvasHeight), \(CelesteProbe.canvasFovDegrees)°, \(CelesteProbe.canvasNearest ? "nearest" : "linear")). ImmersiveSpace öffnen: Farbfläche in 500 m, Markierung oben links gelb. Siehe Log [c64-canvas]."
                        : "Leinwand konnte nicht angelegt werden, siehe Log [c64-canvas]."
                case .play:
                    // M4a.3: Leinwand anlegen, Celeste laden (Hauptthread), Endbild in die Leinwand
                    // leiten (ohne laufenden Tick), dann Freigabe; der Render-Thread tickt und
                    // zeichnet die Leinwand nach dem Verankern. Rücklesen nach 600 Ticks.
                    guard CelesteProbe.prepareCanvas() else {
                        appModel.statusLine = "Leinwand konnte nicht angelegt werden, siehe Log [c64-canvas]."
                        break
                    }
                    let result = CelesteProbe.runInit(since: probeStart)
                    if result.ok, CelesteProbe.attachCanvasToGame() {
                        CelesteProbe.tickState.markReady(snapshotQueue: CelesteProbe.commandQueue, snapshotTexture: CelesteProbe.canvasTexture)
                        appModel.statusLine = "Celeste geladen (\(result.version)), Endbild auf der Leinwand. ImmersiveSpace öffnen: Titelbild in 500 m nach etwa 1 s; Gamepad führt ins Level. Siehe Log [c64-celeste] und [c64-canvas]."
                    } else {
                        appModel.statusLine = "Celeste-Start oder Leinwand fehlgeschlagen: \(result.capabilitiesLine). Siehe Log."
                    }
                case .tick:
                    // M1a.5: init und Laden wie init (acht Ticks hier auf dem Hauptthread), dann
                    // Freigabe; der Render-Thread tickt ab dem ersten Compositor-Frame.
                    let result = CelesteProbe.runInit(since: probeStart)
                    if result.ok {
                        CelesteProbe.tickState.markReady()
                        appModel.statusLine = "Celeste geladen (\(result.version)). ImmersiveSpace öffnen: dann tickt der Render-Thread. Gamepad einschalten und Tasten drücken, siehe Log [c64-celeste]."
                    } else {
                        appModel.statusLine = "Celeste-Start fehlgeschlagen: \(result.capabilitiesLine). Siehe Log [c64-celeste]."
                    }
                }
            }

            // Kit-Testszene hinter C64_KIT (Standard aus), auf dem Hauptthread, sobald das Fenster
            // steht; der ImmersiveSpace ist noch zu.
            //   =1       K0: ganze Szene hier, SDL erzeugt Device und Queue selbst, SDL_Quit am Ende.
            //   =inject  K1a: hier nur SDL_Init; die Szene läuft im Render-Thread vor dem ersten
            //            Frame mit Device und Queue des Gerüsts (Renderer.runKitInjectProbe).
            //   =import  K1b: hier nur SDL_Init; im ImmersiveSpace löscht SDL jedes Frame die
            //            importierten Drawable-Texturen (Renderer, kitImportSession).
            guard let mode = KitProbe.mode, !kitProbeRan else { return }
            kitProbeRan = true
            switch mode {
            case .basic:
                let result = KitProbe.runBasic()
                appModel.statusLine = result == 0
                    ? "Kit-Testszene (SDL_GPU, SDL main) bestanden. Siehe Log [c64-kit]."
                    : "Kit-Testszene fehlgeschlagen in Schritt \(result). Siehe Log [c64-kit]."
            case .inject:
                let ok = KitProbe.initSDL(for: mode)
                appModel.statusLine = ok
                    ? "SDL initialisiert (Hauptthread). Inject-Test läuft beim Öffnen des ImmersiveSpace vor dem ersten Frame."
                    : "SDL_Init fehlgeschlagen, siehe Log [c64-kit]."
            case .import:
                let ok = KitProbe.initSDL(for: mode)
                appModel.statusLine = ok
                    ? "SDL initialisiert (Hauptthread). Import-Test: SDL löscht im ImmersiveSpace jedes Frame dunkelblau."
                    : "SDL_Init fehlgeschlagen, siehe Log [c64-kit]."
            case .multiview:
                let ok = KitProbe.initSDL(for: mode)
                appModel.statusLine = ok
                    ? "SDL initialisiert (Hauptthread). Multiview-Test: SDL zeichnet im ImmersiveSpace das Schachbrett für beide Augen in einem Pass."
                    : "SDL_Init fehlgeschlagen, siehe Log [c64-kit]."
            }
        }
    }

    @State private var kitProbeRan = false
    @State private var celesteProbeRan = false

    /// Fenster-Schnappschüsse bei 0,2 s, 1 s und 2 s nach dem Start der Probe. Ist ein Zeitpunkt
    /// schon vorbei (celeste_init und das Laden dauern im Modus init länger), folgt der
    /// Schnappschuss sofort; die Zeile trägt die tatsächliche Zeit (tMs).
    private func snapshotMarks(since start: DispatchTime) async {
        for mark in [0.2, 1.0, 2.0] {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            if elapsed < mark {
                try? await Task.sleep(for: .seconds(mark - elapsed))
            }
            CelesteProbe.windowSnapshot("t\(mark)s", since: start)
        }
    }

    private func openSpace() async {
        appModel.immersiveState = .opening
        appModel.statusLine = "ImmersiveSpace wird geöffnet …"
        let result = await openImmersiveSpace(id: appModel.immersiveSpaceID)
        switch result {
        case .opened:
            appModel.immersiveState = .open
            appModel.statusLine = "ImmersiveSpace offen. Renderschleife läuft, siehe Log [c64-frame]."
        case .userCancelled:
            appModel.immersiveState = .closed
            appModel.statusLine = "Öffnen abgebrochen."
        case .error:
            appModel.immersiveState = .closed
            appModel.statusLine = "Öffnen fehlgeschlagen."
        @unknown default:
            appModel.immersiveState = .closed
            appModel.statusLine = "Öffnen: unbekanntes Ergebnis."
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}

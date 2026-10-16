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

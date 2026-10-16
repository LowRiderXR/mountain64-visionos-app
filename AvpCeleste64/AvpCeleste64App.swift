//
//  AvpCeleste64App.swift
//  AvpCeleste64
//
//  Fenster plus ImmersiveSpace (volle Immersion) mit CompositorLayer.
//  Konfiguration des Layers: Layout .dedicated, Foveation in dieser Runde aus,
//  Farb- und Tiefenformat aus den Capabilities (Tiefe depth32Float, falls angeboten).
//

import CompositorServices
import os
import SwiftUI

@main
struct AvpCeleste64App: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .windowResizability(.contentSize)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveContent(appModel: appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

struct ImmersiveContent: CompositorContent {
    var appModel: AppModel

    var body: some CompositorContent {
        CompositorLayer(configuration: ProbeLayerConfiguration()) { @MainActor layerRenderer in
            Renderer.start(layerRenderer: layerRenderer, appModel: appModel)
        }
    }
}

/// Layer-Konfiguration für P0a. Gewählte Werte liest der Renderer über
/// layerRenderer.configuration zurück und druckt sie in die Startzeile [c64-ctx].
nonisolated struct ProbeLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        // Foveation in dieser Runde aus (port-analyse.md, Frage 2 und Phasenplan P0/M4b).
        configuration.isFoveationEnabled = false

        // Layout .dedicated: eine 2D-Textur pro Auge, ein Pass pro Textur.
        let layouts = capabilities.supportedLayouts(options: [])
        if layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else if let first = layouts.first {
            configuration.layout = first
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
        c64Log.notice("[c64-caps] supportsFoveation=\(capabilities.supportsFoveation, privacy: .public) layouts=\(layoutNames, privacy: .public) colorFormats=\(colorNames, privacy: .public) depthFormats=\(depthNames, privacy: .public)")
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

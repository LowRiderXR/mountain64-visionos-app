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
        let environment = ProcessInfo.processInfo.environment

        // Foveation nur mit Schalter C64_FOVEATION=1 (P0b), sonst aus.
        let foveation = environment["C64_FOVEATION"] == "1" && capabilities.supportsFoveation
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
        // Plattformwissen: beide Regler setzen). Schalter C64_RENDERQUALITY, Wert 0..1; der
        // Laufzeitwert wird im Renderer gesetzt (layer_renderer.h:230-232).
        if foveation, let wanted = environment["C64_RENDERQUALITY"].flatMap({ Float($0) }) {
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

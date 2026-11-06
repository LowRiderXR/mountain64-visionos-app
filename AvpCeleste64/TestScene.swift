//
//  TestScene.swift
//  AvpCeleste64
//
//  Testszene P0b-2 hinter dem Schalter C64_TESTSCENE=1 (nur Debug-Builds): ein Quad mit feinem
//  Schachbrett, rund 1 m × 1 m, 1,5 m vor der Startposition auf Augenhöhe, in der Welt verankert.
//  Gezeichnet im bestehenden Clear-Pass über beide Schichten, beide Augen in einem Draw per
//  Vertex Amplification (Anzahl 2, View-Mapping auf Schicht 0 und 1), Reverse-Z mit
//  Tiefenschreiben, damit der Compositor gültige Tiefe bekommt. TestUniforms bleibt in jedem
//  Build: die Leinwand (CanvasScene) nutzt denselben Vertex-Shader.
//

import ARKit
import CompositorServices
import Foundation
import Metal
import simd

/// Muss dem Layout von C64TestUniforms in TestScene.metal entsprechen (float4 statt float3,
/// damit Swift und MSL dieselbe Ausrichtung haben).
/// Uniforms des Quad-Vertex-Shaders c64_test_vertex; auch die Leinwand (CanvasScene) nutzt ihn.
struct TestUniforms {
    var viewProjection: (simd_float4x4, simd_float4x4)
    var center: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
}

#if DEBUG
nonisolated final class TestScene: @unchecked Sendable {
    static let environmentKey = "C64_TESTSCENE"

    /// C64_TESTSCENE=1: in der Welt verankert. C64_TESTSCENE=2: kopffest (Gegenprobe ohne
    /// Weltpose: das Quad muss dann immer vor den Augen liegen).
    enum Mode { case world, headLocked }

    static let requestedMode: Mode? = {
        switch HostEnvironment.string(environmentKey) {
        case "1": return .world
        case "2": return .headLocked
        default: return nil
        }
    }()

    static var isRequested: Bool { requestedMode != nil }

    let mode: Mode
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    /// Weltlage des Quads. Wird während der ersten Sekunde (settleFrames) jeden Frame aus der
    /// aktuellen Pose neu gesetzt und dann eingefroren, weil die Pose der ersten Frames nach
    /// dem Öffnen des ImmersiveSpace noch nicht eingeschwungen ist (Lauf vom 16.10.: Kopfhöhe
    /// 0,43 m im ersten Frame).
    private var center: SIMD3<Float>?
    private var right = SIMD3<Float>(0.5, 0, 0)
    private var up = SIMD3<Float>(0, 0.5, 0)
    private var placementFrames = 0
    private var frozen = false
    private static let settleFrames = 90

    private static let distance: Float = 1.5
    private static let halfSize: Float = 0.5

    /// Erzeugt Pipeline und Tiefenzustand; nil mit Logzeile, wenn etwas fehlt.
    init?(mode: Mode, device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, viewCount: Int) {
        self.mode = mode
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "c64_test_vertex"),
              let fragment = library.makeFunction(name: "c64_test_fragment") else {
            c64Record("[c64-testscene] Shader nicht gefunden (default.metallib fehlt oder Funktionen fehlen)")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "c64-testscene"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        // Vertex Amplification: Maximum am Pipeline-Deskriptor (angle-stereo-multiview.md,
        // Abschnitt 2); Gerätetest supportsVertexAmplificationCount.
        let amplification = min(viewCount, 2)
        descriptor.maxVertexAmplificationCount = device.supportsVertexAmplificationCount(amplification) ? amplification : 1

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            c64Record("[c64-testscene] Pipeline fehlgeschlagen: \(error)")
            return nil
        }

        // Reverse-Z: Clear 0 = fern, näher = grösser, also Vergleich greater, Schreiben an.
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            c64Record("[c64-testscene] DepthStencilState fehlgeschlagen")
            return nil
        }
        depthState = state

        c64Record("[c64-testscene] bereit (\(mode == .world ? "Welt" : "kopffest")): maxVertexAmplificationCount=\(descriptor.maxVertexAmplificationCount) color=\(ProbeContext.name(colorFormat)) depth=\(ProbeContext.name(depthFormat))")
    }

    /// Weltmodus: Quad 1,5 m vor der Pose in horizontaler Blickrichtung, Höhe = Pose, senkrecht
    /// zur Blickrichtung. Während der ersten settleFrames jeden Frame neu, danach eingefroren;
    /// die Logzeile kommt beim Einfrieren und nennt auch die Kopfposition.
    private func place(anchor: simd_float4x4) {
        guard !frozen else { return }
        let position = SIMD3<Float>(anchor.columns.3.x, anchor.columns.3.y, anchor.columns.3.z)
        // Metal/visionOS: die Kamera blickt entlang −Z der Pose.
        var forward = -SIMD3<Float>(anchor.columns.2.x, anchor.columns.2.y, anchor.columns.2.z)
        forward.y = 0
        if simd_length(forward) < 1e-3 { forward = SIMD3<Float>(0, 0, -1) }
        forward = simd_normalize(forward)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let rightDir = simd_normalize(simd_cross(forward, worldUp))   // Rechts aus Sicht des Betrachters

        center = position + forward * Self.distance
        right = rightDir * Self.halfSize
        up = worldUp * Self.halfSize

        placementFrames += 1
        if placementFrames >= Self.settleFrames {
            frozen = true
            c64Record(String(format: "[c64-testscene] Quad eingefroren nach %d Frames bei (%.2f, %.2f, %.2f) m, Kopf (%.2f, %.2f, %.2f) m, Blick (%.2f, %.2f, %.2f), Kante %.1f m",
                             placementFrames, center!.x, center!.y, center!.z,
                             position.x, position.y, position.z,
                             forward.x, forward.y, forward.z, Self.halfSize * 2))
        } else if placementFrames == 1 {
            c64Record(String(format: "[c64-testscene] erste Pose: Kopf (%.2f, %.2f, %.2f) m, Blick (%.2f, %.2f, %.2f)",
                             position.x, position.y, position.z, forward.x, forward.y, forward.z))
        }
    }

    /// Zeichnet das Quad in den offenen Encoder. `views` sind die Views des Passes; bei zwei
    /// Views ein Draw mit Amplification 2 auf Schicht 0 und 1, bei einer View ein Draw ohne
    /// Amplification mit der Matrix dieser View in Slot 0.
    func encode(encoder: MTLRenderCommandEncoder,
                drawable: LayerRenderer.Drawable,
                views: [LayerRenderer.Drawable.View],
                viewIndices: [Int],
                deviceAnchor: DeviceAnchor?) {
        var matrices = [matrix_identity_float4x4, matrix_identity_float4x4]
        let quadCenter: SIMD3<Float>
        let quadRight: SIMD3<Float>
        let quadUp: SIMD3<Float>

        switch mode {
        case .world:
            guard let deviceAnchor else { return }   // ohne Pose keine Weltverankerung, nichts zeichnen
            let anchorTransform = deviceAnchor.originFromAnchorTransform
            place(anchor: anchorTransform)
            guard let center else { return }
            quadCenter = center
            quadRight = right
            quadUp = up
            for (slot, viewIndex) in viewIndices.prefix(2).enumerated() {
                // Welt → Auge: inverse(deviceAnchor · view.transform), dann Compositor-Projektion
                // (Reverse-Z, Infinite-Far, asymmetrisch), wie Renderer.swift:1450-1463 bei Vice City.
                let viewMatrix = (anchorTransform * views[slot].transform).inverse
                matrices[slot] = drawable.computeProjection(viewIndex: viewIndex) * viewMatrix
            }
        case .headLocked:
            // Kopffest: Quad im Kopfraum 1,5 m voraus (−Z), View nur über view.transform
            // (ohne deviceAnchor), wie Vice Citys Head-Lock-Zweig (Renderer.swift:1461).
            quadCenter = SIMD3<Float>(0, 0, -Self.distance)
            quadRight = SIMD3<Float>(Self.halfSize, 0, 0)
            quadUp = SIMD3<Float>(0, Self.halfSize, 0)
            for (slot, viewIndex) in viewIndices.prefix(2).enumerated() {
                matrices[slot] = drawable.computeProjection(viewIndex: viewIndex) * views[slot].transform.inverse
            }
        }

        var uniforms = TestUniforms(
            viewProjection: (matrices[0], matrices[1]),
            center: SIMD4<Float>(quadCenter, 1),
            right: SIMD4<Float>(quadRight, 0),
            up: SIMD4<Float>(quadUp, 0)
        )

        encoder.pushDebugGroup("c64-testscene")
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setViewports(views.map { $0.textureMap.viewport })
        if views.count > 1 {
            var mappings = (0..<views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            encoder.setVertexAmplificationCount(views.count, viewMappings: &mappings)
        }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TestUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
    }
}
#endif

//
//  CanvasScene.swift
//  AvpCeleste64
//
//  M4a.2: die Leinwand, auf der später Celestes Bild liegt (M4a.3), hier mit einer vom Host
//  gefüllten Textur. Ein Quad in 500 m (Plattformwissen: weit weg, damit die Ebene keine
//  Stereo-Disparität hinzufügt), Breite nach Winkel (C64_CANVAS_FOV, Standard 50°, 16:9), in der
//  Welt verankert wie die Testszene (Pose der ersten 90 Frames, dann eingefroren), beide Augen
//  in einem Draw per Vertex Amplification mit der Matrix pro View aus computeProjection, Rate
//  Map des Compositors am Pass, Tiefentest greater mit Schreiben (Reverse-Z: die Leinwand
//  schreibt near/D = 0,0002, der Grund-Clear des Renderers liegt mit 0,0001 dahinter).
//
//  Abtastung über eine sRGB-Ansicht der RGBA8Unorm-Textur (PixelFormatView): die Hardware
//  rechnet vor dem Filtern nach linear, das Drawable (bgra8Unorm_srgb) kodiert beim Schreiben
//  zurück; die Bytes der Leinwand kommen so unverändert an. Filter linear, C64_CANVAS_FILTER=nearest
//  für den Pixel-Look. Vertex-Shader und Uniforms sind die der Testszene (gleiches Quad).
//

import CompositorServices
import Foundation
import Metal
import simd

nonisolated final class CanvasScene {
    static let distance: Float = 500
    static let settleFrames = 90

    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private let texture: MTLTexture          // RGBA8Unorm, vom Host gefüllt (M4a.2) oder von Celeste beschrieben (M4a.3)
    private let srgbView: MTLTexture         // Ansicht rgba8Unorm_srgb derselben Textur
    let fovDegrees: Float
    private let halfWidth: Float
    private let halfHeight: Float

    private var center: SIMD3<Float>?
    private var right = SIMD3<Float>(1, 0, 0)
    private var up = SIMD3<Float>(0, 1, 0)
    private var placementFrames = 0
    private var frozen = false
    private var eyesLogged = false

    init?(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, viewCount: Int,
          texture: MTLTexture, fovDegrees: Float, nearest: Bool) {
        self.texture = texture
        self.fovDegrees = fovDegrees
        halfWidth = Self.distance * tan(fovDegrees * .pi / 360)
        halfHeight = halfWidth * 9 / 16

        guard texture.usage.contains(.pixelFormatView), let view = texture.makeTextureView(pixelFormat: .rgba8Unorm_srgb) else {
            c64Record("[c64-canvas] sRGB-Ansicht nicht möglich (Textur ohne PixelFormatView oder Format \(texture.pixelFormat.rawValue))")
            return nil
        }
        srgbView = view

        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "c64_test_vertex"),
              let fragment = library.makeFunction(name: "c64_canvas_fragment") else {
            c64Record("[c64-canvas] Shader nicht gefunden (c64_test_vertex, c64_canvas_fragment)")
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "c64-canvas"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        let amplification = min(viewCount, 2)
        descriptor.maxVertexAmplificationCount = device.supportsVertexAmplificationCount(amplification) ? amplification : 1
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            c64Record("[c64-canvas] Pipeline fehlgeschlagen: \(error)")
            return nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            c64Record("[c64-canvas] DepthStencilState fehlgeschlagen")
            return nil
        }
        depthState = state

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = nearest ? .nearest : .linear
        samplerDescriptor.magFilter = nearest ? .nearest : .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            c64Record("[c64-canvas] SamplerState fehlgeschlagen")
            return nil
        }
        sampler = samplerState

        c64Record(String(format: "[c64-canvas] bereit: texture=%dx%d format=%lu srgbView=%lu fov=%.1f° size=%.1fx%.1f m distance=%.0f m filter=%@ maxVertexAmplificationCount=%d",
                         texture.width, texture.height, texture.pixelFormat.rawValue, srgbView.pixelFormat.rawValue,
                         fovDegrees, halfWidth * 2, halfHeight * 2, Self.distance, nearest ? "nearest" : "linear",
                         descriptor.maxVertexAmplificationCount))
    }

    /// Wie die Testszene: in den ersten settleFrames jeden Frame aus der Pose setzen, dann einfrieren.
    private func place(anchor: simd_float4x4) {
        guard !frozen else { return }
        let position = SIMD3<Float>(anchor.columns.3.x, anchor.columns.3.y, anchor.columns.3.z)
        var forward = -SIMD3<Float>(anchor.columns.2.x, anchor.columns.2.y, anchor.columns.2.z)
        forward.y = 0
        if simd_length(forward) < 1e-3 { forward = SIMD3<Float>(0, 0, -1) }
        forward = simd_normalize(forward)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let rightDir = simd_normalize(simd_cross(forward, worldUp))
        center = position + forward * Self.distance
        right = rightDir * halfWidth
        up = worldUp * halfHeight
        placementFrames += 1
        if placementFrames >= Self.settleFrames {
            frozen = true
            let verticalDegrees = 2 * atan(halfHeight / Self.distance) * 180 / .pi
            c64Record(String(format: "[c64-canvas] eingefroren nach %d Frames: Mitte (%.1f, %.1f, %.1f) m, Kopf (%.2f, %.2f, %.2f) m, Blick (%.2f, %.2f, %.2f), Leinwand %.1fx%.1f m = %.1f°x%.1f° in %.0f m",
                             placementFrames, center!.x, center!.y, center!.z,
                             position.x, position.y, position.z, forward.x, forward.y, forward.z,
                             halfWidth * 2, halfHeight * 2, fovDegrees, verticalDegrees, Self.distance))
        } else if placementFrames == 1 {
            c64Record(String(format: "[c64-canvas] erste Pose: Kopf (%.2f, %.2f, %.2f) m, Blick (%.2f, %.2f, %.2f)",
                             position.x, position.y, position.z, forward.x, forward.y, forward.z))
        }
    }

    /// Einmal: Tangenten beider Augen aus computeProjection (aussermittige Projektion: Spalte 0
    /// und 1 skalieren, Spalte 2 trägt die Aussermittigkeit, Plattformwissen «Augen-Frustum ist
    /// asymmetrisch»; tanR = (1 + m20)/m00, tanL = (1 − m20)/m00, tanT = (1 + m21)/m11,
    /// tanB = (1 − m21)/m11), daraus das Sichtfeld, dazu Drawable- und Map-Grössen und die Pixel,
    /// die auf die Leinwandbreite fallen (Grundlage für «nativ» in M4a.4: logisch in der Mitte
    /// 1:1 unter der Map, physisch als Mittel über die Textur). cp_view_get_tangents ist seit
    /// visionOS 2 veraltet.
    func logEyesOnce(drawable: LayerRenderer.Drawable, views: [LayerRenderer.Drawable.View], maps: [MTLRasterizationRateMap]) {
        guard !eyesLogged, let firstView = views.first else { return }
        eyesLogged = true
        let texture = drawable.colorTextures[firstView.textureMap.textureIndex]
        var parts: [String] = []
        for (index, view) in views.enumerated() {
            let p = drawable.computeProjection(viewIndex: index)
            let m00 = p.columns.0.x, m11 = p.columns.1.y, m20 = p.columns.2.x, m21 = p.columns.2.y
            let t = SIMD4<Float>((1 - m20) / m00, (1 + m20) / m00, (1 + m21) / m11, (1 - m21) / m11)   // l, r, t, b
            let horizontal = (atan(t.x) + atan(t.y)) * 180 / .pi
            let vertical = (atan(t.z) + atan(t.w)) * 180 / .pi
            let viewport = view.textureMap.viewport
            var native = ""
            if let map = maps.first {
                let layer = min(index, map.layerCount - 1)
                let logicalWidth = Float(map.screenSize.width)
                let physicalWidth = Float(map.physicalSize(layer: layer).width)
                native = String(format: " nativeForCanvas{logical=%.0f physical=%.0f}", logicalWidth * fovDegrees / horizontal, physicalWidth * fovDegrees / horizontal)
            } else {
                native = String(format: " nativeForCanvas{texture=%.0f}", Float(viewport.width) * fovDegrees / horizontal)
            }
            parts.append(String(format: "view%d{tangents l=%.3f r=%.3f t=%.3f b=%.3f fov=%.1f°x%.1f° viewport=%.0fx%.0f%@}",
                                index, t.x, t.y, t.z, t.w, horizontal, vertical, viewport.width, viewport.height, native))
        }
        let mapText = maps.enumerated().map { index, map in
            let physical = (0..<map.layerCount).map { "\(map.physicalSize(layer: $0).width)x\(map.physicalSize(layer: $0).height)" }.joined(separator: ",")
            return "map\(index){layers=\(map.layerCount) screen=\(map.screenSize.width)x\(map.screenSize.height) physical=[\(physical)]}"
        }.joined(separator: " ")
        c64Record("[c64-canvas] eyes drawable=\(texture.width)x\(texture.height)x\(texture.arrayLength) canvasFov=\(fovDegrees)° \(parts.joined(separator: " ")) \(mapText.isEmpty ? "map=none" : mapText)")
    }

    /// Zeichnet die Leinwand in den offenen Encoder; wie TestScene.encode (Weltmodus).
    func encode(encoder: MTLRenderCommandEncoder,
                drawable: LayerRenderer.Drawable,
                views: [LayerRenderer.Drawable.View],
                viewIndices: [Int],
                deviceAnchor: DeviceAnchor?) {
        guard let deviceAnchor else { return }
        let anchorTransform = deviceAnchor.originFromAnchorTransform
        place(anchor: anchorTransform)
        guard let center else { return }
        var matrices = [matrix_identity_float4x4, matrix_identity_float4x4]
        for (slot, viewIndex) in viewIndices.prefix(2).enumerated() {
            let viewMatrix = (anchorTransform * views[slot].transform).inverse
            matrices[slot] = drawable.computeProjection(viewIndex: viewIndex) * viewMatrix
        }
        var uniforms = TestUniforms(
            viewProjection: (matrices[0], matrices[1]),
            center: SIMD4<Float>(center, 1),
            right: SIMD4<Float>(right, 0),
            up: SIMD4<Float>(up, 0)
        )
        encoder.pushDebugGroup("c64-canvas")
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
        encoder.setFragmentTexture(srgbView, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
    }
}

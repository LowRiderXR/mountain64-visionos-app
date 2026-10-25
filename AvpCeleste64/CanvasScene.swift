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
    // Erst nach dem Verankern zeigen (in der Verankerungsphase ginge die Fläche mit dem Kopf
    // mit, M4a.2), dann über fadeInFrames einblenden; vorher bleibt nur der Grund-Clear.
    private var fadeFrames = 0
    static let fadeInFrames = 27    // rund 0,3 s bei 90 Hz
    private var fadeLogged = false

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
            c64Record(String(format: "[c64-canvas] tMs=\(LaunchClock.tMs) erste Pose: Kopf (%.2f, %.2f, %.2f) m, Blick (%.2f, %.2f, %.2f)",
                             position.x, position.y, position.z, forward.x, forward.y, forward.z))
        }
    }

    /// Einmal: Tangenten beider Augen aus computeProjection (aussermittige Projektion: Spalte 0
    /// und 1 skalieren, Spalte 2 trägt die Aussermittigkeit, Plattformwissen «Augen-Frustum ist
    /// asymmetrisch»; tanR = (1 + m20)/m00, tanL = (1 − m20)/m00, tanT = (1 + m21)/m11,
    /// tanB = (1 − m21)/m11), daraus das Sichtfeld, dazu Drawable- und Map-Grössen; danach die
    /// Messung «nativ» (logNativeSpan). cp_view_get_tangents ist seit visionOS 2 veraltet.
    func logEyesOnce(drawable: LayerRenderer.Drawable, views: [LayerRenderer.Drawable.View], maps: [MTLRasterizationRateMap]) {
        guard !eyesLogged, let firstView = views.first else { return }
        eyesLogged = true
        let texture = drawable.colorTextures[firstView.textureMap.textureIndex]
        var parts: [String] = []
        var tangents: [SIMD4<Float>] = []
        for (index, view) in views.enumerated() {
            let p = drawable.computeProjection(viewIndex: index)
            let m00 = p.columns.0.x, m11 = p.columns.1.y, m20 = p.columns.2.x, m21 = p.columns.2.y
            let t = SIMD4<Float>((1 - m20) / m00, (1 + m20) / m00, (1 + m21) / m11, (1 - m21) / m11)   // l, r, t, b
            tangents.append(t)
            let horizontal = (atan(t.x) + atan(t.y)) * 180 / .pi
            let vertical = (atan(t.z) + atan(t.w)) * 180 / .pi
            let viewport = view.textureMap.viewport
            parts.append(String(format: "view%d{tangents l=%.3f r=%.3f t=%.3f b=%.3f fov=%.1f°x%.1f° viewport=%.0fx%.0f}",
                                index, t.x, t.y, t.z, t.w, horizontal, vertical, viewport.width, viewport.height))
        }
        let mapText = maps.enumerated().map { index, map in
            let physical = (0..<map.layerCount).map { "\(map.physicalSize(layer: $0).width)x\(map.physicalSize(layer: $0).height)" }.joined(separator: ",")
            return "map\(index){layers=\(map.layerCount) screen=\(map.screenSize.width)x\(map.screenSize.height) physical=[\(physical)]}"
        }.joined(separator: " ")
        c64Record("[c64-canvas] eyes drawable=\(texture.width)x\(texture.height)x\(texture.arrayLength) canvasFov=\(fovDegrees)° \(parts.joined(separator: " ")) \(mapText.isEmpty ? "map=none" : mapText)")
        logNativeSpan(tangents: tangents, maps: maps)
    }

    /// Messung «nativ» (M4a.4): wie viele physische Pixel der Rate Map auf eine geradeaus
    /// zentrierte Leinwand mit fovDegrees fallen, je Auge. Bildschirm-x der Leinwandränder aus
    /// den Tangenten (x = (tanL ∓ tan(fov/2)) / (tanL + tanR) · screen.width, Tangens, nicht
    /// Winkel: die Map ist im Tangens linear), dasselbe vertikal mit der 16:9-Höhe
    /// (y = (tanT ∓ halfV) / (tanT + tanB) · screen.height), dann mapScreenToPhysicalCoordinates
    /// (Swift: physicalCoordinates(screenCoordinates:layer:)) für beide Ränder und die Mitte ±1 px. Dichte = physische Pixel pro logischem Pixel
    /// (Mitte etwa 1, Rand darunter). suggested: physische Spanne, 16:9, Breite auf 16 und Höhe
    /// auf 8 gerundet, begrenzt durch die vertikale Spanne.
    private func logNativeSpan(tangents: [SIMD4<Float>], maps: [MTLRasterizationRateMap]) {
        guard let map = maps.first else {
            c64Record("[c64-native] no rate map (foveation off): no measurement")
            return
        }
        let half = tan(fovDegrees * .pi / 360)
        let halfV = half * 9 / 16
        let screenW = Float(map.screenSize.width), screenH = Float(map.screenSize.height)
        for (index, t) in tangents.enumerated() {
            let layer = min(index, map.layerCount - 1)
            let tanL = t.x, tanR = t.y, tanT = t.z, tanB = t.w
            func screenX(_ u: Float) -> Float { (tanL + u) / (tanL + tanR) * screenW }
            func screenY(_ v: Float) -> Float { (tanT - v) / (tanT + tanB) * screenH }
            let xLeft = screenX(-half), xRight = screenX(half), xCentre = screenX(0)
            let yTop = screenY(halfV), yBottom = screenY(-halfV), yCentre = screenY(0)
            func physical(_ x: Float, _ y: Float) -> MTLCoordinate2D {
                map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: x, y: y), layer: layer)
            }
            let pLeft = physical(xLeft, yCentre), pRight = physical(xRight, yCentre)
            let pTop = physical(xCentre, yTop), pBottom = physical(xCentre, yBottom)
            let physicalSpanX = pRight.x - pLeft.x
            let physicalSpanY = pBottom.y - pTop.y
            // Dichte aus ±1 logischem Pixel
            let centreDensityX = (physical(xCentre + 1, yCentre).x - physical(xCentre - 1, yCentre).x) / 2
            let centreDensityY = (physical(xCentre, yCentre + 1).y - physical(xCentre, yCentre - 1).y) / 2
            let edgeDensityL = (physical(xLeft + 1, yCentre).x - physical(xLeft - 1, yCentre).x) / 2
            let edgeDensityR = (physical(xRight + 1, yCentre).x - physical(xRight - 1, yCentre).x) / 2
            let edgeDensityT = (physical(xCentre, yTop + 1).y - physical(xCentre, yTop - 1).y) / 2
            let edgeDensityB = (physical(xCentre, yBottom + 1).y - physical(xCentre, yBottom - 1).y) / 2
            let suggestedWidthRaw = min(physicalSpanX, physicalSpanY * 16 / 9)
            let suggestedWidth = Int((suggestedWidthRaw / 16).rounded()) * 16
            let suggestedHeight = Int((Float(suggestedWidth) * 9 / 16 / 8).rounded()) * 8
            c64Record(String(format: "[c64-native] eye=%d layer=%d canvasFov=%.1f° screenX=[%.0f..%.0f] screenY=[%.0f..%.0f] logicalSpan=%.0fx%.0f physicalX=[%.0f..%.0f] physicalY=[%.0f..%.0f] physicalSpan=%.0fx%.0f centreDensity=%.3fx%.3f edgeDensity{l=%.3f r=%.3f t=%.3f b=%.3f} suggested=%dx%d",
                             index, layer, fovDegrees, xLeft, xRight, yTop, yBottom, xRight - xLeft, yBottom - yTop,
                             pLeft.x, pRight.x, pTop.y, pBottom.y, physicalSpanX, physicalSpanY,
                             centreDensityX, centreDensityY, edgeDensityL, edgeDensityR, edgeDensityT, edgeDensityB,
                             suggestedWidth, suggestedHeight))
        }
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
        guard let center, frozen else { return }   // vor dem Verankern nichts zeichnen
        var fade = min(1, Float(fadeFrames) / Float(Self.fadeInFrames))
        if fadeFrames <= Self.fadeInFrames { fadeFrames += 1 }
        if !fadeLogged, fade >= 1 {
            fadeLogged = true
            c64Record("[c64-canvas] sichtbar: Einblendung nach \(Self.fadeInFrames) Frames abgeschlossen")
        }
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
        encoder.setFragmentBytes(&fade, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
    }
}

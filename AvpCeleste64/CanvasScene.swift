//
//  CanvasScene.swift
//  AvpCeleste64
//
//  The canvas that carries Celeste's 2D image: a texture the host fills at start (prepareCanvas)
//  and Celeste writes afterwards (celeste_set_canvas). A quad at 500 m (far away, so that the
//  plane adds no stereo disparity), width by angle (C64_CANVAS_FOV, default 50°, 16:9),
//  anchored in the world like the test scene (pose of the first 90 frames, then frozen), both
//  eyes in one draw through vertex amplification with the matrix per view from
//  computeProjection, the compositor's rate map on the pass, depth test greater with writes
//  (reverse-Z: the canvas writes near/D = 0.0002, the renderer's base clear lies behind it at 0.0001).
//
//  Sampling through an sRGB view of the RGBA8Unorm texture (PixelFormatView): the hardware
//  converts to linear before filtering, the drawable (bgra8Unorm_srgb) encodes back when
//  writing; the bytes of the canvas thus arrive unchanged. Filter linear, C64_CANVAS_FILTER=nearest
//  for the pixel look. Vertex shader and uniforms are those of the test scene (same quad).
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
    private let texture: MTLTexture          // RGBA8Unorm, filled by the host at start, then written by Celeste
    private let srgbView: MTLTexture         // view rgba8Unorm_srgb of the same texture
    let fovDegrees: Float
    private let halfWidth: Float
    private let halfHeight: Float

    private var center: SIMD3<Float>?
    private var right = SIMD3<Float>(1, 0, 0)
    private var up = SIMD3<Float>(0, 1, 0)
    private var placementFrames = 0
    private var frozen = false
    private var eyesLogged = false
    // Show only after anchoring (during the anchoring phase the plane would move with the
    // head), then fade in over fadeInFrames; before that only the base clear remains.
    private var fadeFrames = 0
    static let fadeInFrames = 27    // about 0.3 s at 90 Hz
    private var fadeLogged = false

    init?(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, viewCount: Int,
          texture: MTLTexture, fovDegrees: Float, nearest: Bool) {
        self.texture = texture
        self.fovDegrees = fovDegrees
        halfWidth = Self.distance * tan(fovDegrees * .pi / 360)
        halfHeight = halfWidth * 9 / 16

        guard texture.usage.contains(.pixelFormatView), let view = texture.makeTextureView(pixelFormat: .rgba8Unorm_srgb) else {
            c64Record("[c64-canvas] sRGB view not possible (texture without PixelFormatView or format \(texture.pixelFormat.rawValue))")
            return nil
        }
        srgbView = view

        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "c64_test_vertex"),
              let fragment = library.makeFunction(name: "c64_canvas_fragment") else {
            c64Record("[c64-canvas] shaders not found (c64_test_vertex, c64_canvas_fragment)")
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
            c64Record("[c64-canvas] pipeline failed: \(error)")
            return nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            c64Record("[c64-canvas] DepthStencilState failed")
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
            c64Record("[c64-canvas] SamplerState failed")
            return nil
        }
        sampler = samplerState

        c64Record(String(format: "[c64-canvas] ready: texture=%dx%d format=%lu srgbView=%lu fov=%.1f° size=%.1fx%.1f m distance=%.0f m filter=%@ maxVertexAmplificationCount=%d",
                         texture.width, texture.height, texture.pixelFormat.rawValue, srgbView.pixelFormat.rawValue,
                         fovDegrees, halfWidth * 2, halfHeight * 2, Self.distance, nearest ? "nearest" : "linear",
                         descriptor.maxVertexAmplificationCount))
    }

    /// During the first settleFrames set every frame, then freeze; the placement no longer depends
    /// on the gaze direction but on −Z of the origin (yaw 0, x = z = 0), only the height comes from
    /// the head height. The system recenter (long Crown press) puts −Z of the origin onto the gaze
    /// direction, so the canvas stands in front of the player again afterwards. Before, it lay
    /// along the gaze direction of the 90th frame and stayed off to the side by that angle after a recenter.
    private func place(anchor: simd_float4x4) {
        guard !frozen else { return }
        let position = SIMD3<Float>(anchor.columns.3.x, anchor.columns.3.y, anchor.columns.3.z)
        var gaze = -SIMD3<Float>(anchor.columns.2.x, anchor.columns.2.y, anchor.columns.2.z)
        gaze.y = 0
        if simd_length(gaze) < 1e-3 { gaze = SIMD3<Float>(0, 0, -1) }
        gaze = simd_normalize(gaze)
        let forward = SIMD3<Float>(0, 0, -1)
        let worldUp = SIMD3<Float>(0, 1, 0)
        center = SIMD3<Float>(0, position.y, 0) + forward * Self.distance
        right = SIMD3<Float>(1, 0, 0) * halfWidth
        up = worldUp * halfHeight
        placementFrames += 1
        if placementFrames >= Self.settleFrames {
            frozen = true
            let verticalDegrees = 2 * atan(halfHeight / Self.distance) * 180 / .pi
            let gazeYaw = atan2(gaze.x, -gaze.z) * 180 / .pi
            c64Record(String(format: "[c64-canvas] frozen after %d frames on -Z of the origin (yaw 0): centre (%.1f, %.1f, %.1f) m, head (%.2f, %.2f, %.2f) m, gaze (%.2f, %.2f, %.2f) = %.1f°, canvas %.1fx%.1f m = %.1f°x%.1f° at %.0f m",
                             placementFrames, center!.x, center!.y, center!.z,
                             position.x, position.y, position.z, gaze.x, gaze.y, gaze.z, gazeYaw,
                             halfWidth * 2, halfHeight * 2, fovDegrees, verticalDegrees, Self.distance))
        } else if placementFrames == 1 {
            c64Record(String(format: "[c64-canvas] tMs=\(LaunchClock.tMs) first pose: head (%.2f, %.2f, %.2f) m, gaze (%.2f, %.2f, %.2f)",
                             position.x, position.y, position.z, gaze.x, gaze.y, gaze.z))
        }
    }

    /// Once: tangents of both eyes from computeProjection (off-centre projection: columns 0 and 1
    /// scale, column 2 carries the off-centre terms; the eye frustum is asymmetric, so the four
    /// tangents differ; tanR = (1 + m20)/m00, tanL = (1 − m20)/m00, tanT = (1 + m21)/m11,
    /// tanB = (1 − m21)/m11), from that the field of view, plus drawable and map sizes; then the
    /// "native" measurement (logNativeSpan). cp_view_get_tangents is deprecated since visionOS 2.
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

    /// "Native" measurement: how many physical pixels of the rate map fall onto a straight-ahead
    /// centred canvas with fovDegrees, per eye. Screen x of the canvas edges from the tangents
    /// (x = (tanL ∓ tan(fov/2)) / (tanL + tanR) · screen.width, tangent, not angle: the map is
    /// linear in the tangent), the same vertically with the 16:9 height
    /// (y = (tanT ∓ halfV) / (tanT + tanB) · screen.height), then mapScreenToPhysicalCoordinates
    /// (Swift: physicalCoordinates(screenCoordinates:layer:)) for both edges and the centre ±1 px. Density = physical pixels per logical pixel
    /// (centre about 1, edge below). suggested: physical span, 16:9, width rounded to 16 and height
    /// to 8, limited by the vertical span.
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
            // density from ±1 logical pixel
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

    /// Draws the canvas into the open encoder; like TestScene.encode (world mode).
    func encode(encoder: MTLRenderCommandEncoder,
                drawable: LayerRenderer.Drawable,
                views: [LayerRenderer.Drawable.View],
                viewIndices: [Int],
                deviceAnchor: DeviceAnchor?) {
        guard let deviceAnchor else { return }
        let anchorTransform = deviceAnchor.originFromAnchorTransform
        place(anchor: anchorTransform)
        guard let center, frozen else { return }   // draw nothing before anchoring
        var fade = min(1, Float(fadeFrames) / Float(Self.fadeInFrames))
        if fadeFrames <= Self.fadeInFrames { fadeFrames += 1 }
        if !fadeLogged, fade >= 1 {
            fadeLogged = true
            c64Record("[c64-canvas] visible: fade-in finished after \(Self.fadeInFrames) frames")
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

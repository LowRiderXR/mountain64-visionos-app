//
//  TestScene.swift
//  AvpCeleste64
//
//  Test scene behind the switch C64_TESTSCENE=1 (Debug builds only): a quad with a fine
//  checkerboard, about 1 m × 1 m, 1.5 m in front of the start position at eye height, anchored
//  in the world. Drawn in the existing clear pass over both layers, both eyes in one draw through
//  vertex amplification (count 2, view mapping onto layers 0 and 1), reverse-Z with depth writes
//  so the compositor gets valid depth. TestUniforms stays in every build: the canvas
//  (CanvasScene) uses the same vertex shader.
//

import ARKit
import CompositorServices
import Foundation
import Metal
import simd

/// Must match the layout of C64TestUniforms in TestScene.metal (float4 instead of float3, so
/// Swift and MSL have the same alignment).
/// Uniforms of the quad vertex shader c64_test_vertex; the canvas (CanvasScene) uses it too.
struct TestUniforms {
    var viewProjection: (simd_float4x4, simd_float4x4)
    var center: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
}

#if DEBUG
nonisolated final class TestScene: @unchecked Sendable {
    static let environmentKey = "C64_TESTSCENE"

    /// C64_TESTSCENE=1: anchored in the world. C64_TESTSCENE=2: head-locked (counter-check without
    /// a world pose: the quad must then always lie in front of the eyes).
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

    /// World placement of the quad. Set anew from the current pose every frame during the first
    /// second (settleFrames) and then frozen, because the pose of the first frames after opening
    /// the ImmersiveSpace has not settled yet (run of 16 October: head height 0.43 m in the
    /// first frame).
    private var center: SIMD3<Float>?
    private var right = SIMD3<Float>(0.5, 0, 0)
    private var up = SIMD3<Float>(0, 0.5, 0)
    private var placementFrames = 0
    private var frozen = false
    private static let settleFrames = 90

    private static let distance: Float = 1.5
    private static let halfSize: Float = 0.5

    /// Creates pipeline and depth state; nil with a log line when something is missing.
    init?(mode: Mode, device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, viewCount: Int) {
        self.mode = mode
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "c64_test_vertex"),
              let fragment = library.makeFunction(name: "c64_test_fragment") else {
            c64Record("[c64-testscene] shaders not found (default.metallib missing or functions missing)")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "c64-testscene"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        // Vertex amplification: maximum on the pipeline descriptor; device check
        // supportsVertexAmplificationCount.
        let amplification = min(viewCount, 2)
        descriptor.maxVertexAmplificationCount = device.supportsVertexAmplificationCount(amplification) ? amplification : 1

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            c64Record("[c64-testscene] pipeline failed: \(error)")
            return nil
        }

        // Reverse-Z: clear 0 = far, nearer = larger, so compare greater, writes on.
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            c64Record("[c64-testscene] DepthStencilState failed")
            return nil
        }
        depthState = state

        c64Record("[c64-testscene] ready (\(mode == .world ? "world" : "head-locked")): maxVertexAmplificationCount=\(descriptor.maxVertexAmplificationCount) color=\(ProbeContext.name(colorFormat)) depth=\(ProbeContext.name(depthFormat))")
    }

    /// World mode: quad 1.5 m in front of the pose in the horizontal gaze direction, height = pose,
    /// perpendicular to the gaze. Anew every frame during the first settleFrames, then frozen; the
    /// log line comes when freezing and also names the head position.
    private func place(anchor: simd_float4x4) {
        guard !frozen else { return }
        let position = SIMD3<Float>(anchor.columns.3.x, anchor.columns.3.y, anchor.columns.3.z)
        // Metal/visionOS: the camera looks along −Z of the pose.
        var forward = -SIMD3<Float>(anchor.columns.2.x, anchor.columns.2.y, anchor.columns.2.z)
        forward.y = 0
        if simd_length(forward) < 1e-3 { forward = SIMD3<Float>(0, 0, -1) }
        forward = simd_normalize(forward)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let rightDir = simd_normalize(simd_cross(forward, worldUp))   // right from the viewer's point of view

        center = position + forward * Self.distance
        right = rightDir * Self.halfSize
        up = worldUp * Self.halfSize

        placementFrames += 1
        if placementFrames >= Self.settleFrames {
            frozen = true
            c64Record(String(format: "[c64-testscene] quad frozen after %d frames at (%.2f, %.2f, %.2f) m, head (%.2f, %.2f, %.2f) m, gaze (%.2f, %.2f, %.2f), edge %.1f m",
                             placementFrames, center!.x, center!.y, center!.z,
                             position.x, position.y, position.z,
                             forward.x, forward.y, forward.z, Self.halfSize * 2))
        } else if placementFrames == 1 {
            c64Record(String(format: "[c64-testscene] first pose: head (%.2f, %.2f, %.2f) m, gaze (%.2f, %.2f, %.2f)",
                             position.x, position.y, position.z, forward.x, forward.y, forward.z))
        }
    }

    /// Draws the quad into the open encoder. `views` are the views of the pass; with two views one
    /// draw with amplification 2 onto layers 0 and 1, with one view one draw without amplification
    /// with that view's matrix in slot 0.
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
            guard let deviceAnchor else { return }   // without a pose no world anchoring, draw nothing
            let anchorTransform = deviceAnchor.originFromAnchorTransform
            place(anchor: anchorTransform)
            guard let center else { return }
            quadCenter = center
            quadRight = right
            quadUp = up
            for (slot, viewIndex) in viewIndices.prefix(2).enumerated() {
                // world -> eye: inverse(deviceAnchor · view.transform), then the compositor projection
                // (reverse-Z, infinite far, asymmetric).
                let viewMatrix = (anchorTransform * views[slot].transform).inverse
                matrices[slot] = drawable.computeProjection(viewIndex: viewIndex) * viewMatrix
            }
        case .headLocked:
            // head-locked: quad in head space 1.5 m ahead (−Z), view only through view.transform
            // (without deviceAnchor).
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

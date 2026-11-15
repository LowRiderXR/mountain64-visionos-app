//
//  KitProbe.swift
//  AvpCeleste64
//
//  Switch C64_KIT (default off):
//    C64_KIT=1          stage basic: SDL_GPU test scene once at start on the main thread, SDL
//                       creates device and queue itself, SDL_Quit at the end. Reference.
//    C64_KIT=inject     stage inject: SDL_Init on the main thread at the window (without
//                       SDL_Quit), the scene then runs on the render thread of the ImmersiveSpace
//                       with the layer renderer's device and the host's queue, once before the
//                       first frame. The render loop then continues normally; SDL stays
//                       initialised (SDL_Quit from the render thread would not be clean on UIKit).
//    C64_KIT=import     stage import: like inject at the window; in the ImmersiveSpace SDL imports
//                       colour and depth texture of the drawable in every frame and clears both
//                       layers (dark blue, depth 0.001); the host presents.
//    C64_KIT=multiview  stage multiview: like import, but one pass with view_count 2 and one draw
//                       of the checkerboard (1 m, 1.5 m in front of the start pose, world-fixed)
//                       for both eyes through vertex amplification; shaders from the kit toolchain.
//                       With C64_FOVEATION=1 the compositor's map goes to the pass.
//                       C64_KIT_MSAA=<samples> (default off) renders into MSAA textures and
//                       resolves colour and depth into the drawable layers.
//                       C64_KIT_DEPTH_STORE=store|dontcare (default unset) selects the store_op of
//                       the MSAA depth and turns on the depth probe (step=depth-probe).
//
//  Checks the SDL GPU kit inside a foreign process: device ownership, texture import and
//  multiview rendering. Every line of the scene goes into the probe.
//  Compiled in Debug builds only (Release and Diagnostics know no kit mode).
//
//  Thread evidence (SDL main 4cfdb71ee): SDL_Init(VIDEO) runs through UIKit_VideoInit
//  (SDL_uikitvideo.m:153) and belongs on the main thread; SDL_CreateGPUDevice and
//  SDL_DestroyGPUDevice check no thread (SDL_gpu.c, SDL_gpu_metal.m without SDL_IsMainThread).
//

import Foundation
import Metal
import os
import simd

#if DEBUG
nonisolated enum KitProbe {
    static let environmentKey = "C64_KIT"

    enum Mode: String {
        case basic = "1"
        case inject = "inject"
        case `import` = "import"
        case multiview = "multiview"
    }

    static let mode: Mode? = Mode(rawValue: HostEnvironment.string(environmentKey) ?? "")

    static var isRequested: Bool { mode != nil }

    private static let debugRequested: Bool = HostEnvironment.string("C64_KIT_DEBUG") == "1"

    /// C callback without context: writes every line of the scene into the probe.
    static let logLine: kit_log_fn = { line, _ in
        guard let line else { return }
        c64Record(String(cString: line))
    }

    /// Unretained pointer to a Metal object for the C side; the host stays the owner.
    static func pointer(_ object: AnyObject) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(object).toOpaque()
    }

    /// Basic: everything on the main thread, SDL creates device and queue itself.
    @MainActor
    @discardableResult
    static func runBasic() -> Int32 {
        c64Record("[c64-kit] start mode=basic thread=main debug=\(debugRequested)")
        var options = kit_testscene_options()
        options.init_sdl = true
        options.quit_sdl = true
        options.debug_mode = debugRequested
        options.width = 256
        options.height = 256
        let began = CFAbsoluteTimeGetCurrent()
        let result = kit_testscene_run(&options, logLine, nil)
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        c64Record("[c64-kit] end mode=basic result=\(result) totalMs=\(String(format: "%.1f", ms))")
        return result
    }

    /// inject/import/multiview, part 1 (main thread, at the window): only SDL_SetMainReady + SDL_Init(VIDEO).
    @MainActor
    @discardableResult
    static func initSDL(for mode: Mode) -> Bool {
        c64Record("[c64-kit] start mode=\(mode.rawValue) thread=main step=init-only")
        return kit_testscene_init_sdl(logLine, nil)
    }

    /// Inject, part 2 (render thread, before the first frame): scene with the host's device and queue.
    /// The pointers go to C unretained; SDL holds its own reference during the scene and releases
    /// it in SDL_DestroyGPUDevice. The host stays the owner.
    @discardableResult
    static func runInject(device: MTLDevice, queue: MTLCommandQueue) -> Int32 {
        let devicePointer = pointer(device as AnyObject)
        let queuePointer = pointer(queue as AnyObject)
        c64Record("[c64-kit] start mode=inject thread=\(Thread.current.name ?? "?") host.device=\(devicePointer) host.queue=\(queuePointer) device=\"\(device.name)\" queue=\"\(queue.label ?? "-")\" debug=\(debugRequested)")
        var options = kit_testscene_options()
        options.init_sdl = false
        options.quit_sdl = false
        options.debug_mode = debugRequested
        options.width = 256
        options.height = 256
        options.metal_device = devicePointer
        options.metal_queue = queuePointer
        let began = CFAbsoluteTimeGetCurrent()
        let result = kit_testscene_run(&options, logLine, nil)
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        c64Record("[c64-kit] end mode=inject result=\(result) totalMs=\(String(format: "%.1f", ms))")
        return result
    }

    // MARK: Import

    /// Import session on the host's device and queue (the SDL_GPU device lives until `endImport`).
    /// Diagnostic switches: C64_KIT_WAIT=1 (wait for SDL's fence before the host commits),
    /// C64_KIT_VERIFY=1 (every 90 frames read the centre pixel of the imported colour texture back).
    static func beginImport(device: MTLDevice, queue: MTLCommandQueue) -> OpaquePointer? {
        let wait = HostEnvironment.string("C64_KIT_WAIT") == "1"
        let verify = HostEnvironment.string("C64_KIT_VERIFY") == "1"
        c64Record("[c64-kit] start mode=import thread=\(Thread.current.name ?? "?") device=\"\(device.name)\" queue=\"\(queue.label ?? "-")\" C64_KIT_WAIT=\(wait) C64_KIT_VERIFY=\(verify)")
        guard let session = kit_import_begin(pointer(device as AnyObject), pointer(queue as AnyObject), logLine, nil) else {
            return nil
        }
        if wait || verify {
            kit_import_set_diagnostics(session, wait, verify ? 90 : 0)
        }
        return session
    }

    /// Import the colour and depth texture of a frame and clear all layers.
    static func importClear(session: OpaquePointer, color: MTLTexture, depth: MTLTexture,
                            rgba: (Float, Float, Float, Float), depthValue: Float) -> Bool {
        var components: [Float] = [rgba.0, rgba.1, rgba.2, rgba.3]
        return kit_import_clear_frame(session, pointer(color as AnyObject), pointer(depth as AnyObject),
                                      &components, depthValue)
    }

    /// Import diagnostics: pixel SDL read back in this frame after its clear (b,g,r,a).
    static func lastVerify(session: OpaquePointer) -> [UInt8]? {
        var bytes: [UInt8] = [0, 0, 0, 0]
        let present = bytes.withUnsafeMutableBufferPointer { kit_import_last_verify(session, $0.baseAddress) }
        return present ? bytes : nil
    }

    static func takeImportStats(session: OpaquePointer) -> kit_import_stats {
        var stats = kit_import_stats()
        kit_import_take_stats(session, &stats)
        return stats
    }

    static func endImport(session: OpaquePointer) {
        kit_import_end(session)
    }

    // MARK: Multiview

    /// Multiview session with shaders and pipeline (view_count 2) on the host's device and queue.
    /// `msaaSamples` > 1 turns anti-aliasing on (C64_KIT_MSAA); the session then renders into its
    /// own MSAA textures of drawable size and resolves colour and depth (filter max, reverse-Z:
    /// nearest surface) into the drawable layers. 0 = no MSAA.
    /// `memoryless` creates the MSAA targets (and the MSAA texture of the measurement image) without
    /// memory (C64_KIT_MEMORYLESS=1); colour and depth are only resolved, never loaded or stored.
    /// `depthStore` "store" or "dontcare" (C64_KIT_DEPTH_STORE) selects the store_op of the MSAA
    /// depth (STORE: StoreAndMultisampleResolve) and turns on the depth probe; nil keeps the
    /// default (DONT_CARE, no probe). The session rejects the combination without MSAA or store
    /// with memoryless (FAIL step=multiview-options).
    static func beginMultiview(device: MTLDevice, queue: MTLCommandQueue, msaaSamples: Int = 0, memoryless: Bool = false,
                               depthStore: String? = nil) -> OpaquePointer? {
        c64Record("[c64-kit] start mode=multiview thread=\(Thread.current.name ?? "?") device=\"\(device.name)\" queue=\"\(queue.label ?? "-")\" msaa=\(msaaSamples) memoryless=\(memoryless) depthStore=\(depthStore ?? "-")")
        var options = kit_multiview_options()
        kit_multiview_options_default(&options)
        options.msaa_samples = UInt32(max(0, msaaSamples))
        options.memoryless = memoryless
        switch depthStore {
        case nil:
            break
        case "store":
            options.depth_store = true
            options.depth_probe = true
        case "dontcare":
            options.depth_store = false
            options.depth_probe = true
        default:
            c64Record("[c64-kit] step=multiview-options C64_KIT_DEPTH_STORE=\"\(depthStore ?? "")\" unknown (expected store|dontcare), switch ignored")
        }
        return kit_multiview_begin_ex(pointer(device as AnyObject), pointer(queue as AnyObject), &options, logLine, nil)
    }

    /// One frame; `viewProjection` per view (projection · inverse(deviceAnchor · view.transform)),
    /// quad from center/right/up in metres. Without a quad only the clear in the two-view pass.
    /// `rateMap` is the compositor's map (foveation on) or nil.
    static func multiviewFrame(session: OpaquePointer, color: MTLTexture, depth: MTLTexture,
                               rgba: (Float, Float, Float, Float), depthClear: Float,
                               quad: (center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>)?,
                               viewProjection: [simd_float4x4],
                               rateMap: MTLRasterizationRateMap? = nil) -> Bool {
        var clear: [Float] = [rgba.0, rgba.1, rgba.2, rgba.3]
        var matrices = [Float](repeating: 0, count: 32)
        for (index, matrix) in viewProjection.prefix(2).enumerated() {
            for column in 0..<4 {
                for row in 0..<4 {
                    matrices[index * 16 + column * 4 + row] = matrix[column][row]
                }
            }
        }
        var center: [Float] = [0, 0, 0]
        var right: [Float] = [0, 0, 0]
        var up: [Float] = [0, 0, 0]
        if let quad {
            center = [quad.center.x, quad.center.y, quad.center.z]
            right = [quad.right.x, quad.right.y, quad.right.z]
            up = [quad.up.x, quad.up.y, quad.up.z]
        }
        let mapPointer = rateMap.map { pointer($0 as AnyObject) }
        return kit_multiview_frame(session, pointer(color as AnyObject), pointer(depth as AnyObject),
                                   &clear, depthClear, quad != nil, &matrices, &center, &right, &up, mapPointer)
    }

    /// Measurement image against the compositor's map (own float texture of physical size).
    static func multiviewMeasure(session: OpaquePointer, rateMap: MTLRasterizationRateMap, verbose: Bool) -> kit_multiview_measure? {
        var result = kit_multiview_measure()
        guard kit_multiview_measure_map(session, pointer(rateMap as AnyObject), verbose, &result) else { return nil }
        return result
    }

    static func takeMultiviewStats(session: OpaquePointer) -> kit_multiview_stats {
        var stats = kit_multiview_stats()
        kit_multiview_take_stats(session, &stats)
        return stats
    }

    static func endMultiview(session: OpaquePointer) {
        kit_multiview_end(session)
    }
}

/// World placement of the checkerboard for the multiview stage, like TestScene.place: 1.5 m in
/// front of the pose in the horizontal gaze direction, height = pose, edge 1 m; anew from the
/// pose every frame during the first 90 frames, then frozen, because the first poses after
/// opening have not settled (head height 0.43 m in the first frame, run of 16 October).
nonisolated struct KitQuadPlacement {
    private(set) var center: SIMD3<Float>?
    private(set) var right = SIMD3<Float>(0.5, 0, 0)
    private(set) var up = SIMD3<Float>(0, 0.5, 0)
    private var placementFrames = 0
    private var frozen = false
    private static let settleFrames = 90
    private static let distance: Float = 1.5
    private static let halfSize: Float = 0.5

    mutating func update(anchor: simd_float4x4) {
        guard !frozen else { return }
        let position = SIMD3<Float>(anchor.columns.3.x, anchor.columns.3.y, anchor.columns.3.z)
        var forward = -SIMD3<Float>(anchor.columns.2.x, anchor.columns.2.y, anchor.columns.2.z)
        forward.y = 0
        if simd_length(forward) < 1e-3 { forward = SIMD3<Float>(0, 0, -1) }
        forward = simd_normalize(forward)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let rightDir = simd_normalize(simd_cross(forward, worldUp))
        center = position + forward * Self.distance
        right = rightDir * Self.halfSize
        up = worldUp * Self.halfSize
        placementFrames += 1
        if placementFrames >= Self.settleFrames {
            frozen = true
            c64Record(String(format: "[c64-kit] step=multiview-quad frozen after %d frames at (%.2f, %.2f, %.2f) m, head (%.2f, %.2f, %.2f) m, gaze (%.2f, %.2f, %.2f), edge %.1f m",
                             placementFrames, center!.x, center!.y, center!.z,
                             position.x, position.y, position.z, forward.x, forward.y, forward.z, Self.halfSize * 2))
        }
    }

    var quad: (center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>)? {
        guard let center else { return nil }
        return (center, right, up)
    }
}
#endif

//
//  CelesteProbe.swift
//  AvpCeleste64
//
//  Start and operation of the game in the host: celeste_init on the main thread in the start
//  window (hidden SDL window, the host's device and queue, bundle as content root, loading
//  ticks, celeste_set_canvas), then the compositor's render thread ticks (TickState: update in
//  the update phase, render after the device anchor, stereo world pass through
//  celeste_render_frame_vr), pause and audio (PauseState, suspendAudio), clean exit
//  (requestExit), reference O of the head pose (StereoOrigin) and the statistics per second
//  (tick-stats).
//
//  Switches (see GameSettings): C64_RES for the game's internal resolution (default 1920x1080)
//  and C64_LINE for the outline width (default auto); the canvas has the internal resolution,
//  C64_CANVAS_FOV its angular width, C64_CANVAS_FILTER the filter. In Debug builds a kit mode
//  (C64_KIT) switches the game off, and C64_SNAPSHOT=1 reads the canvas back once.
//

import AVFAudio
import CoreGraphics
import Foundation
import ImageIO
import Metal
import os
import simd
import UIKit

nonisolated enum CelesteProbe {
    /// The game runs (default). In Debug builds a kit mode (C64_KIT) switches it off: two SDL_GPU
    /// devices on the same MTLDevice make no sense.
    #if DEBUG
    static let gameEnabled: Bool = KitProbe.mode == nil
    #else
    static let gameEnabled = true
    #endif

    /// GPU time of command buffers (gpuEndTime − gpuStartTime), collected from a completion
    /// callback (Metal thread), read once per second by the render thread.
    nonisolated final class GpuStats: @unchecked Sendable {
        private let lock = NSLock()
        private var sum = 0.0
        private var maxValue = 0.0
        private var count = 0
        func add(_ seconds: Double) {
            guard seconds > 0 else { return }
            lock.withLock { sum += seconds; maxValue = max(maxValue, seconds); count += 1 }
        }
        func take() -> (mean: Double, max: Double, count: Int) {
            lock.withLock {
                let result = (count > 0 ? sum / Double(count) : 0, maxValue, count)
                sum = 0; maxValue = 0; count = 0
                return result
            }
        }
    }

    /// GPU time of Celeste's SDL command buffers (kit callback, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_BUFFER_COMPLETED_CALLBACK_POINTER).
    static let celesteGpu = GpuStats()

    /// C callback of the kit: void (*)(void *userdata, void *mtl_command_buffer); runs on Metal's
    /// completion thread, where the buffer is complete (gpuStartTime and gpuEndTime set).
    static let celesteCommandBufferCompleted: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, raw in
        guard let raw else { return }
        let buffer = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard let commandBuffer = buffer as? MTLCommandBuffer else { return }
        let start = commandBuffer.gpuStartTime
        let end = commandBuffer.gpuEndTime
        CelesteProbe.celesteGpu.add(end - start)
        CelesteProbe.celesteGpuPasses.record(start: start, end: end)
    }

    /// Celeste's final image into the canvas (celeste_set_canvas), on the main thread after
    /// runInit and before the render thread is released, so without a running tick.
    @MainActor static func attachCanvasToGame() -> Bool {
        guard let texture = canvasTexture else {
            c64Record("[c64-canvas] no canvas texture for celeste_set_canvas")
            return false
        }
        let rc = celeste_set_canvas(Unmanaged.passUnretained(texture).toOpaque(), Int32(texture.width), Int32(texture.height))
        if rc != 0 {
            let error = celeste_last_error().map { String(cString: $0) } ?? ""
            c64Record("[c64-canvas] celeste_set_canvas rc=\(rc) error=\"\(error)\"")
            return false
        }
        c64Record("[c64-canvas] celeste_set_canvas rc=0: Celeste's final image goes to the canvas \(texture.width)x\(texture.height)")
        return true
    }

    #if DEBUG
    /// Colour comparison with the Mac (C64_SNAPSHOT=1, Debug builds only): read the canvas back
    /// once (blit on the shared queue, after Celeste's commits), log the mean colour and store it
    /// as PNG and raw RGBA in Documents (c64-canvas-<device>.png/.rgba; scripts/compare-canvas.py
    /// compares with the image from mac-check). Blocks the calling thread until the blit has
    /// finished.
    static func writeCanvasSnapshot(queue: MTLCommandQueue, texture: MTLTexture, label: String) {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        guard let buffer = queue.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            c64Record("[c64-canvas] snapshot \(label): blit not possible")
            return
        }
        let start = DispatchTime.now()
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let data = Data(bytes: buffer.contents(), count: bytesPerRow * height)
        var sum = [UInt64](repeating: 0, count: 3)
        var black = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < p.count {
                sum[0] += UInt64(p[i]); sum[1] += UInt64(p[i + 1]); sum[2] += UInt64(p[i + 2])
                if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 { black += 1 }
                i += 4
            }
        }
        let pixels = Double(width * height)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = "c64-canvas-\(ProbeContext.hardwareMachine)-\(label)"
        let rawURL = documents.appendingPathComponent(base + ".rgba")
        let pngURL = documents.appendingPathComponent(base + ".png")
        var written = "raw=\((try? data.write(to: rawURL)) != nil ? 1 : 0)"
        if let provider = CGDataProvider(data: data as CFData),
           let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
           let destination = CGImageDestinationCreateWithURL(pngURL as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            written += " png=\(CGImageDestinationFinalize(destination) ? 1 : 0)"
        } else {
            written += " png=0"
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        c64Record(String(format: "[c64-canvas] snapshot %@ %dx%d mean(rgb)=%.1f,%.1f,%.1f black=%.1f%% %@ ms=%.1f files=%@",
                         label, width, height, Double(sum[0]) / pixels, Double(sum[1]) / pixels, Double(sum[2]) / pixels,
                         Double(black) / pixels * 100, written, ms, base))
    }
    #endif

    // MARK: Resolution and line width

    /// Internal resolution of the game, outline width and canvas size from C64_RES and C64_LINE.
    ///   C64_RES=640x360|1280x720|1920x1080|2560x1440|native   default 1920x1080.
    ///       native: table per device (hw.machine) from the map measurement ([c64-native]); while
    ///       it is empty, 1920x1080 with a log line.
    ///   C64_LINE=1|2|3|4|auto                                  default auto = round(height/360).
    /// Invalid values: error line in the log, then the default. The canvas has the internal
    /// resolution, except at 640x360 (1280x720 as before); the angular width stays C64_CANVAS_FOV.
    struct GameSettings {
        let internalWidth: Int
        let internalHeight: Int
        let edgeLineWidth: Int
        var canvasWidth: Int { internalWidth == 640 && internalHeight == 360 ? 1280 : internalWidth }
        var canvasHeight: Int { internalWidth == 640 && internalHeight == 360 ? 720 : internalHeight }
    }

    static let resolutions: [String: (Int, Int)] = [
        "640x360": (640, 360), "1280x720": (1280, 720), "1920x1080": (1920, 1080), "2560x1440": (2560, 1440),
    ]
    static let defaultResolution = (1920, 1080)
    /// "native" per device from the measurement [c64-native]; still empty.
    static let nativeResolutions: [String: (Int, Int)] = [:]

    static let settings: GameSettings = {
        let environment = HostEnvironment.values
        let resText = environment["C64_RES"] ?? ""
        var resolution = defaultResolution
        var resNote = resText.isEmpty ? "unset" : resText
        if resText.isEmpty {
            // default
        } else if resText == "native" {
            if let native = nativeResolutions[ProbeContext.hardwareMachine] {
                resolution = native
                resNote = "native(\(ProbeContext.hardwareMachine))"
            } else {
                c64Record("[c64-res] native table empty, using \(defaultResolution.0)x\(defaultResolution.1) (hw.machine \(ProbeContext.hardwareMachine))")
            }
        } else if let known = resolutions[resText] {
            resolution = known
        } else {
            c64Record("[c64-res] error: C64_RES=\"\(resText)\" unknown (640x360, 1280x720, 1920x1080, 2560x1440, native), default \(defaultResolution.0)x\(defaultResolution.1)")
        }
        let lineText = environment["C64_LINE"] ?? ""
        let autoLine = max(1, min(4, Int((Double(resolution.1) / 360).rounded())))
        var line = autoLine
        if lineText.isEmpty || lineText == "auto" {
            // default auto
        } else if let value = Int(lineText), (1...4).contains(value) {
            line = value
        } else {
            c64Record("[c64-res] error: C64_LINE=\"\(lineText)\" invalid (1, 2, 3, 4, auto), default auto=\(autoLine)")
        }
        let result = GameSettings(internalWidth: resolution.0, internalHeight: resolution.1, edgeLineWidth: line)
        c64Record("[c64-res] C64_RES=\(resNote) -> internal=\(result.internalWidth)x\(result.internalHeight) canvas=\(result.canvasWidth)x\(result.canvasHeight) C64_LINE=\(lineText.isEmpty ? "unset" : lineText) -> line=\(line) (auto=\(autoLine))")
        return result
    }()

    // MARK: Canvas

    static var canvasWidth: Int { settings.canvasWidth }
    static var canvasHeight: Int { settings.canvasHeight }

    /// Angular width of the canvas in degrees (C64_CANVAS_FOV, default 50).
    static let canvasFovDegrees: Float = Float(HostEnvironment.string("C64_CANVAS_FOV") ?? "") ?? 50

    /// C64_CANVAS_FILTER=nearest for the pixel look, otherwise linear.
    static let canvasNearest: Bool = HostEnvironment.string("C64_CANVAS_FILTER") == "nearest"

    /// GPU time per pass. Celeste's command buffers arrive at the callback in commit order;
    /// renderVR queues the labels of the expected buffers after every call (two buffers per
    /// submission: upload and render, GraphicsDeviceSDL.cs:464-465), the callback assigns the
    /// time to the front label.
    /// Plus the exclusive time per buffer as in the MacHost, end − max(start, end of the
    /// predecessor) on the shared serial queue (Celeste's buffers and the host buffer, which
    /// comes last in the frame and closes it). Per pass the sum per frame (mean) and the largest
    /// frame (max); the sum of all buffers of a frame likewise. In the callback only numbers in
    /// fixed fields, no allocation (labels as indices).
    /// Labels are queued before the call of celeste_render_frame_vr (shape of the previous frame,
    /// prepare), because the small upload buffer of the world pass can complete before the call
    /// returns; with an empty queue the buffer then took no label and the ones queued afterwards
    /// stayed as an offset (c64-probe.txt: unlabelled=3, pending 8 → 11). After the call settle
    /// replaces the unconsumed rest when the shape differs. Every label carries the renderer's
    /// frame number; the frame's host buffer (serial queue, after all Celeste buffers of the
    /// frame) discards leftover labels up to its frame (stale).
    nonisolated final class GpuPassStats: @unchecked Sendable {
        enum Label: Int { case world = 0, edge, sprites, rest, canvas, host, ui, other }
        static let count = Label.other.rawValue + 1
        static let worldLabels: [Label] = [.world, .world, .edge, .edge, .sprites, .sprites, .rest, .rest]
        // world frame with a UI or wipe layer: the game submits the layers after the world pass as its own pass "ui"
        static let worldLabelsUi: [Label] = [.world, .world, .ui, .ui, .edge, .edge, .sprites, .sprites, .rest, .rest]
        static let canvasLabels: [Label] = [.canvas, .canvas]
        private let lock = NSLock()
        // queue: label and frame number, parallel (no allocation in the callback)
        private var pending: [Int] = []
        private var pendingFrame: [UInt64] = []
        private var frameSerial: UInt64 = 0
        // shape of the previous frame (provisional labels) and how many of them this frame queued
        private var lastLabels: [Label] = GpuPassStats.canvasLabels
        private var provisionalCount = 0
        private var stale = 0
        // inclusive (gpuEnd − gpuStart) per label
        private var sums = [Double](repeating: 0, count: GpuPassStats.count)
        // exclusive per label: sum, running frame value, buffers in the running frame, maximum per frame
        private var exclSums = [Double](repeating: 0, count: GpuPassStats.count)
        private var exclFrame = [Double](repeating: 0, count: GpuPassStats.count)
        private var exclFrameBuffers = [Int](repeating: 0, count: GpuPassStats.count)
        private var exclMax = [Double](repeating: 0, count: GpuPassStats.count)
        // sum of all buffers of a frame (up to and including the host buffer)
        private var frameTotal = 0.0
        private var frameTotalSum = 0.0
        private var frameTotalMax = 0.0
        private var frameTotalCount = 0
        private var previousEnd = 0.0
        private var unlabelled = 0
        // span from the first GPU start to the host end per frame, and frames with a sum above 5.8 ms
        private var frameFirstStart = 0.0
        private var spanSum = 0.0, spanMax = 0.0
        private var slowFrames = 0
        static let slowFrameSeconds = 0.0058

        init() { pending.reserveCapacity(64); pendingFrame.reserveCapacity(64) }

        /// Render thread, once per compositor frame before the host command buffer: new frame number,
        /// carried by this frame's prepare/settle and the host buffer.
        func beginFrame() -> UInt64 {
            lock.withLock { frameSerial += 1; return frameSerial }
        }

        /// Before celeste_render_frame_vr: queue the labels of the previous frame provisionally.
        func prepare() {
            lock.withLock {
                provisionalCount = lastLabels.count
                for label in lastLabels { pending.append(label.rawValue); pendingFrame.append(frameSerial) }
            }
        }

        /// After the call: actual shape. Equal to the provisional one: nothing to do. Otherwise remove
        /// the unconsumed rest of this frame and append the actual labels not consumed yet (consumed
        /// ones keep the provisional label, once).
        func settle(_ actual: [Label]) {
            lock.withLock {
                defer { lastLabels = actual }
                if actual == lastLabels { return }
                var remaining = 0
                while let last = pendingFrame.last, last == frameSerial, remaining < provisionalCount {
                    pending.removeLast(); pendingFrame.removeLast(); remaining += 1
                }
                let consumed = provisionalCount - remaining
                if consumed < actual.count {
                    for label in actual[consumed...] { pending.append(label.rawValue); pendingFrame.append(frameSerial) }
                }
            }
        }

        /// One Celeste buffer (kit callback, Metal completion thread).
        func record(start: Double, end: Double) {
            lock.withLock {
                let index: Int
                if pending.isEmpty {
                    unlabelled += 1
                    index = Label.other.rawValue
                } else {
                    index = pending.removeFirst()
                    pendingFrame.removeFirst()
                }
                add(index: index, start: start, end: end, buffersPerFrame: 2)
            }
        }

        /// The frame's host buffer (completed handler of the renderer), closes the frame: labels up
        /// to its frame that no buffer took are stale.
        func recordHost(start: Double, end: Double, frame: UInt64) {
            lock.withLock {
                add(index: Label.host.rawValue, start: start, end: end, buffersPerFrame: 1)
                frameTotalSum += frameTotal
                frameTotalMax = max(frameTotalMax, frameTotal)
                frameTotalCount += 1
                if frameTotal > GpuPassStats.slowFrameSeconds { slowFrames += 1 }
                frameTotal = 0
                if frameFirstStart > 0 {
                    let span = max(end - frameFirstStart, 0)
                    spanSum += span; spanMax = max(spanMax, span)
                }
                frameFirstStart = 0
                while let first = pendingFrame.first, first <= frame {
                    pending.removeFirst(); pendingFrame.removeFirst(); stale += 1
                }
            }
        }

        private func add(index: Int, start: Double, end: Double, buffersPerFrame: Int) {
            if frameFirstStart == 0 || start < frameFirstStart { frameFirstStart = start }
            let inclusive = max(end - start, 0)
            let exclusive = max(end - max(start, previousEnd), 0)
            previousEnd = max(previousEnd, end)
            sums[index] += inclusive
            exclSums[index] += exclusive
            frameTotal += exclusive
            exclFrame[index] += exclusive
            exclFrameBuffers[index] += 1
            if exclFrameBuffers[index] >= buffersPerFrame {
                exclMax[index] = max(exclMax[index], exclFrame[index])
                exclFrame[index] = 0
                exclFrameBuffers[index] = 0
            }
        }

        struct Window {
            var inclusive: [Double]
            var exclusive: [Double]
            var exclusiveMax: [Double]
            var frameTotalMean: Double
            var frameTotalMax: Double
            var frames: Int
            var unlabelled: Int
            var stale: Int
            var pending: Int
            var spanMean: Double
            var spanMax: Double
            var slowFrames: Int
            func inclusive(_ label: Label) -> Double { inclusive[label.rawValue] }
            func exclusive(_ label: Label) -> Double { exclusive[label.rawValue] }
            func exclusiveMax(_ label: Label) -> Double { exclusiveMax[label.rawValue] }
        }

        func take() -> Window {
            lock.withLock {
                let result = Window(inclusive: sums, exclusive: exclSums, exclusiveMax: exclMax,
                                    frameTotalMean: frameTotalCount > 0 ? frameTotalSum / Double(frameTotalCount) : 0,
                                    frameTotalMax: frameTotalMax, frames: frameTotalCount,
                                    unlabelled: unlabelled, stale: stale, pending: pending.count,
                                    spanMean: frameTotalCount > 0 ? spanSum / Double(frameTotalCount) : 0, spanMax: spanMax, slowFrames: slowFrames)
                for i in 0..<GpuPassStats.count { sums[i] = 0; exclSums[i] = 0; exclMax[i] = 0 }
                frameTotalSum = 0
                frameTotalMax = 0
                frameTotalCount = 0
                unlabelled = 0
                stale = 0
                spanSum = 0; spanMax = 0; slowFrames = 0
                return result
            }
        }
    }
    static let celesteGpuPasses = GpuPassStats()

    /// Deadlines and compositor grid. Per frame margin = renderingDeadline − gpuEndTime of the
    /// host buffer (both in the time base of the compositor clock; gpuEndTime comes in the base of
    /// CACurrentMediaTime, the offset measured once is subtracted). Plus the jumps of the
    /// presentationTime over 1.5 intervals (presentGaps). Numbers only, one lock.
    nonisolated final class FrameTimingStats: @unchecked Sendable {
        private let lock = NSLock()
        private var offsetMediaMinusCompositor = 0.0
        private var calibrated = false
        private var marginSum = 0.0
        private var marginMin = Double.greatestFiniteMagnitude
        private var marginCount = 0
        private var missed = 0
        private var presentGaps = 0
        // CPU time fields per frame (render thread, numbers only)
        private var waitSum = 0.0, waitMax = -Double.greatestFiniteMagnitude; private var waitCount = 0
        private var commitSum = 0.0, commitMax = 0.0; private var commitCount = 0
        private var cpuMarginSum = 0.0, cpuMarginMin = Double.greatestFiniteMagnitude; private var cpuMarginCount = 0
        private var cpuLate = 0
        // duration of queryDrawables and held anchors
        private var querySum = 0.0, queryMax = 0.0
        private var anchorHeld = 0

        /// Render thread after endSubmission: wait time until optimalInputTime, way from
        /// optimalInputTime to the commit of the world buffer (world frames only), the CPU deadline,
        /// the duration of queryDrawables and whether the last pose was held.
        func noteCpu(waitOpt: TimeInterval, toFirstCommit: TimeInterval?, cpuMargin: TimeInterval, queryDrawables: TimeInterval, anchorHeld held: Bool) {
            lock.withLock {
                waitSum += waitOpt; waitMax = max(waitMax, waitOpt); waitCount += 1
                if let toFirstCommit { commitSum += toFirstCommit; commitMax = max(commitMax, toFirstCommit); commitCount += 1 }
                cpuMarginSum += cpuMargin; cpuMarginMin = min(cpuMarginMin, cpuMargin); cpuMarginCount += 1
                if cpuMargin < 0 { cpuLate += 1 }
                querySum += queryDrawables; queryMax = max(queryMax, queryDrawables)
                if held { anchorHeld += 1 }
            }
        }

        struct CpuWindow { var waitMean, waitMax, commitMean, commitMax, cpuMarginMin, cpuMarginMean, queryMean, queryMax: Double; var cpuLate, frames, commitFrames, anchorHeld: Int }

        func takeCpu() -> CpuWindow {
            lock.withLock {
                let result = CpuWindow(waitMean: waitCount > 0 ? waitSum / Double(waitCount) : 0, waitMax: waitCount > 0 ? waitMax : 0,
                                       commitMean: commitCount > 0 ? commitSum / Double(commitCount) : 0, commitMax: commitMax,
                                       cpuMarginMin: cpuMarginCount > 0 ? cpuMarginMin : 0,
                                       cpuMarginMean: cpuMarginCount > 0 ? cpuMarginSum / Double(cpuMarginCount) : 0,
                                       queryMean: cpuMarginCount > 0 ? querySum / Double(cpuMarginCount) : 0, queryMax: queryMax,
                                       cpuLate: cpuLate, frames: cpuMarginCount, commitFrames: commitCount, anchorHeld: anchorHeld)
                waitSum = 0; waitMax = -Double.greatestFiniteMagnitude; waitCount = 0
                commitSum = 0; commitMax = 0; commitCount = 0
                cpuMarginSum = 0; cpuMarginMin = Double.greatestFiniteMagnitude; cpuMarginCount = 0
                cpuLate = 0
                querySum = 0; queryMax = 0; anchorHeld = 0
                return result
            }
        }

        /// One-off establishment of the time base: both clocks read right after each other.
        /// Returns the offset in seconds, nil when already calibrated.
        func calibrate(compositorNow: TimeInterval, mediaTime: TimeInterval) -> TimeInterval? {
            lock.withLock {
                guard !calibrated else { return nil }
                calibrated = true
                offsetMediaMinusCompositor = mediaTime - compositorNow
                return offsetMediaMinusCompositor
            }
        }

        /// Host buffer complete (completed handler): gpuEnd in the base of CACurrentMediaTime.
        func noteHostBuffer(gpuEnd: Double, deadline: TimeInterval) {
            lock.withLock {
                let margin = deadline - (gpuEnd - offsetMediaMinusCompositor)
                marginSum += margin
                marginMin = min(marginMin, margin)
                marginCount += 1
                if margin < 0 { missed += 1 }
            }
        }

        func noteGap() { lock.withLock { presentGaps += 1 } }

        func take() -> (missed: Int, frames: Int, marginMin: Double, marginMean: Double, presentGaps: Int) {
            lock.withLock {
                let result = (missed, marginCount, marginCount > 0 ? marginMin : 0,
                              marginCount > 0 ? marginSum / Double(marginCount) : 0, presentGaps)
                marginSum = 0
                marginMin = Double.greatestFiniteMagnitude
                marginCount = 0
                missed = 0
                presentGaps = 0
                return result
            }
        }
    }
    static let frameTiming = FrameTimingStats()

    /// The host's canvas texture; the renderer takes it over when the ImmersiveSpace starts.
    @MainActor static var canvasTexture: MTLTexture?

    /// The host's device and queue, created once: celeste_init gets the same queue (SDL commits on
    /// it) as the renderer (host buffers), so command buffers run in commit order and Celeste's
    /// image is finished before the canvas pass reads it.
    @MainActor static func ensureHostDevice() -> Bool {
        if device != nil, commandQueue != nil { return true }
        guard let mtlDevice = MTLCreateSystemDefaultDevice(), let queue = mtlDevice.makeCommandQueue() else {
            c64Record("[c64-celeste] no MTLDevice or no queue")
            return false
        }
        queue.label = "c64-celeste-queue"
        device = mtlDevice
        commandQueue = queue
        c64Record("[c64-celeste] host device=\(Unmanaged.passUnretained(mtlDevice).toOpaque()) name=\"\(mtlDevice.name)\" queue=\"c64-celeste-queue\"")
        return true
    }

    /// Create the canvas texture (private, RenderTarget | ShaderRead | PixelFormatView, as Celeste
    /// writes it) and fill it once through a staging buffer on the shared queue. Pattern: gradient
    /// (red to the right, green downwards, blue 64), white grid every 128 pixels, yellow mark
    /// 160×90 at the top left, blue 80×45 at the bottom right, black border of 4 pixels. Size from
    /// the settings (internal resolution of the game).
    @MainActor static func prepareCanvas() -> Bool {
        guard ensureHostDevice(), let device, let queue = commandQueue else { return false }
        if canvasTexture != nil { return true }
        let width = canvasWidth, height = canvasHeight
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            c64Record("[c64-canvas] canvas texture could not be created")
            return false
        }
        texture.label = "c64-canvas"

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r = UInt8(x * 255 / (width - 1))
                var g = UInt8(y * 255 / (height - 1))
                var b: UInt8 = 64
                if x % 128 == 0 || y % 128 == 0 || x % 128 == 1 || y % 128 == 1 { r = 255; g = 255; b = 255 }
                if x < 160, y < 90 { r = 255; g = 220; b = 0 }                           // mark at the top left
                if x >= width - 80, y >= height - 45 { r = 40; g = 90; b = 255 }         // mark at the bottom right
                if x < 4 || y < 4 || x >= width - 4 || y >= height - 4 { r = 0; g = 0; b = 0 }
                let i = (y * width + x) * 4
                pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
            }
        }
        guard let staging = device.makeBuffer(bytes: pixels, length: pixels.count, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            c64Record("[c64-canvas] staging or blit not possible")
            return false
        }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: width * 4, sourceBytesPerImage: pixels.count,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        canvasTexture = texture
        c64Record("[c64-canvas] canvas texture \(width)x\(height) rgba8Unorm usage=0x\(String(texture.usage.rawValue, radix: 16)) hazard=\(texture.hazardTrackingMode.rawValue) filled (status=\(commandBuffer.status.rawValue)) fov=\(canvasFovDegrees)° filter=\(canvasNearest ? "nearest" : "linear")")
        return true
    }

    /// State of the ticking on the render thread. The main thread releases after init and loading
    /// (markReady), the render thread ticks. All fields behind a lock, and the same lock encloses
    /// every Celeste tick, so two ticks never run at the same time (the main thread ticks
    /// synchronously in runInit before the release, the render thread only comes into being with
    /// the ImmersiveSpace; the lock is the safeguard, not the plan).
    nonisolated final class TickState: @unchecked Sendable {
        private let lock = NSLock()
        private var ready = false
        private var stopped = false
        private var firstLogged = false
        private var totalTicks = 0
        private var totalFrames = 0
        // window of one second
        private var windowStart: CFAbsoluteTime = 0
        private var windowFrames = 0
        private var windowTicks = 0
        private var deltaSum = 0.0
        private var deltaMax = 0.0
        // wall clock interval and deviation from the delta used, prediction against the drawable
        private var wallSum = 0.0
        private var wallMax = 0.0
        private var devSum = 0.0
        private var devMax = 0.0
        private var wallCount = 0
        private var predSum = 0.0
        private var predMax = 0.0
        private var predCount = 0
        // update and render measured separately (CPU, render thread).
        private var updateMsSum = 0.0
        private var updateMsMax = 0.0
        private var renderMsSum = 0.0
        private var renderMsMax = 0.0
        private var windowRenders = 0
        // frames in which Celeste wrote the world into the drawable (rc 1)
        private var windowWorldFrames = 0
        private var updatePending = false
        #if DEBUG
        // C64_SNAPSHOT=1: canvas and queue for the one-off read-back after snapshotAtTicks ticks.
        private var snapshotQueue: MTLCommandQueue?
        private var snapshotTexture: MTLTexture?
        private var snapshotDone = false
        static let snapshotAtTicks = 600

        func enableSnapshot(queue: MTLCommandQueue, texture: MTLTexture) {
            lock.withLock {
                snapshotQueue = queue
                snapshotTexture = texture
            }
            c64Record("[c64-celeste] canvas readback after \(Self.snapshotAtTicks) ticks (C64_SNAPSHOT=1)")
        }

        /// After a render: read the canvas back once if requested (under the lock).
        private func snapshotIfDue() {
            if !snapshotDone, totalTicks >= Self.snapshotAtTicks, let queue = snapshotQueue, let texture = snapshotTexture {
                snapshotDone = true
                CelesteProbe.writeCanvasSnapshot(queue: queue, texture: texture, label: "tick\(totalTicks)")
            }
        }
        #else
        private func snapshotIfDue() {}
        #endif

        var isActive: Bool { lock.withLock { ready && !stopped } }

        func markReady() {
            lock.withLock { ready = true }
            c64Record("[c64-celeste] tick ready: ticks run on the render thread once the immersive space is open")
        }

        /// One tick per compositor frame. frameInterval: difference of the predicted presentation
        /// times of consecutive frames (the compositor's grid), nil on the first frame after start
        /// or pause; then 1/90 s. wallInterval: the wall clock interval between the returns of
        /// queryNextFrame, statistics only. If the tick reports rc=1 ("Exit" in the game),
        /// requestExit runs only after leaving the lock: it calls stop, which takes the same
        /// (non-recursive) NSLock; inside tick that would deadlock the render thread (measured on
        /// the M5: no line after "requested", the system terminated the app after the blocked
        /// render thread).
        /// The update half (celeste_update) in the update phase of the frame; returns true when
        /// the update ran (then render() follows in the same frame).
        @discardableResult
        func update(frameInterval: TimeInterval?, wallInterval: TimeInterval? = nil) -> Bool {
            let (ran, reason) = updateLocked(frameInterval: frameInterval, wallInterval: wallInterval)
            if let reason {
                CelesteProbe.requestExit(reason: reason)
            }
            return ran
        }

        /// The update under the lock; returns whether it ran and the reason for an exit.
        private func updateLocked(frameInterval: TimeInterval?, wallInterval: TimeInterval?) -> (Bool, String?) {
            lock.lock()
            defer { lock.unlock() }
            guard ready, !stopped else { return (false, nil) }
            // frameInterval is the difference of the presentation times (grid), the wall clock
            // only serves the statistics
            let delta = min(max(frameInterval ?? CelesteProbe.tickDelta, 0.001), 1.0 / 30.0)
            if let wallInterval {
                wallSum += wallInterval
                wallMax = max(wallMax, wallInterval)
                let dev = abs(wallInterval - delta)
                devSum += dev
                devMax = max(devMax, dev)
                wallCount += 1
            }
            let now = CFAbsoluteTimeGetCurrent()
            if !firstLogged {
                firstLogged = true
                windowStart = now
                c64Record("[c64-celeste] tMs=\(LaunchClock.tMs) tick first-render-thread thread=\(Thread.current.name ?? "?") isMainThread=\(Thread.isMainThread) qos=\(Thread.current.qualityOfService.rawValue) delta=\(CelesteProbe.format(delta * 1000))ms")
            }
            totalFrames += 1
            windowFrames += 1
            let start = DispatchTime.now()
            let rc = celeste_update(delta)
            let updateMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            if rc == -1 {
                let error = celeste_last_error().map { String(cString: $0) } ?? ""
                c64Error("[c64-celeste] update rc=-1 after \(totalTicks) ticks, ticking stopped: \"\(error)\"")
                stopped = true
                return (false, nil)
            }
            totalTicks += 1
            windowTicks += 1
            if rc == 1 {
                // "Exit" in the title: the same clean exit as with the Digital Crown; stopped
                // here under the lock, requestExit afterwards outside (see update).
                c64Record("[c64-celeste] update rc=1: game asked to exit after \(totalTicks) ticks, ticking stopped")
                stopped = true
                return (false, "game asked to exit (tick rc=1)")
            }
            deltaSum += delta
            deltaMax = max(deltaMax, delta)
            updateMsSum += updateMs
            updateMsMax = max(updateMsMax, updateMs)
            updatePending = true
            logStatsIfDue(now: now)
            return (true, nil)
        }

        /// The render half (celeste_render_frame, present 0) after the device anchor, right before
        /// encoding the host buffer; Celeste's SDL buffers thus commit before the host buffer on
        /// the same queue. Only after an update in the same frame.
        func render() {
            lock.lock()
            defer { lock.unlock() }
            guard ready, !stopped, updatePending else { return }
            updatePending = false
            // labels before the call (one submission at the frame end: two buffers)
            CelesteProbe.celesteGpuPasses.prepare()
            let start = DispatchTime.now()
            let rc = celeste_render_frame(0)
            let renderMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            if rc == -1 {
                let error = celeste_last_error().map { String(cString: $0) } ?? ""
                c64Error("[c64-celeste] render rc=-1 after \(totalTicks) ticks, ticking stopped: \"\(error)\"")
                stopped = true
                CelesteProbe.celesteGpuPasses.settle([])
                return
            }
            windowRenders += 1
            renderMsSum += renderMs
            renderMsMax = max(renderMsMax, renderMs)
            CelesteProbe.celesteGpuPasses.settle(GpuPassStats.canvasLabels)
            snapshotIfDue()
        }

        /// The render half with the stereo world pass (celeste_render_frame_vr). Returns 1: world
        /// in the drawable, 0: canvas (title, overworld, wipe), -1: error (ticks stopped), -2: no
        /// render in this frame (not ready or no update).
        func renderVR(_ frame: UnsafeMutablePointer<celeste_vr_frame>) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            guard ready, !stopped, updatePending else { return -2 }
            updatePending = false
            // queue the labels before the call (shape of the previous frame), set the actual
            // shape after the call
            CelesteProbe.celesteGpuPasses.prepare()
            let start = DispatchTime.now()
            let rc = celeste_render_frame_vr(frame)
            let renderMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            if rc == -1 {
                let error = celeste_last_error().map { String(cString: $0) } ?? ""
                c64Error("[c64-celeste] render_vr rc=-1 after \(totalTicks) ticks, ticking stopped: \"\(error)\"")
                stopped = true
                CelesteProbe.celesteGpuPasses.settle([])
                return rc
            }
            windowRenders += 1
            renderMsSum += renderMs
            renderMsMax = max(renderMsMax, renderMs)
            // labels of this frame's buffers: per FlushPass (world, [UI layer], edge, sprites) and
            // the submission at the frame end two buffers; canvas frames only the frame end
            let flushes = Int(frame.pointee.flushes)
            var labels: [GpuPassStats.Label] = []
            if rc == 1 {
                windowWorldFrames += 1
                if flushes == 3 {
                    labels = GpuPassStats.worldLabels
                } else if flushes == 4 {
                    labels = GpuPassStats.worldLabelsUi
                }
            } else if rc == 0, flushes == 0 {
                labels = GpuPassStats.canvasLabels
            }
            if labels.isEmpty {
                for _ in 0...flushes { labels += [.other, .other] }
            }
            CelesteProbe.celesteGpuPasses.settle(labels)
            snapshotIfDue()
            return rc
        }

        /// Deviation of the predicted from the drawable's presentation time.
        func notePresentation(predicted: TimeInterval, actual: TimeInterval) {
            lock.withLock {
                let dev = abs(actual - predicted)
                predSum += dev
                predMax = max(predMax, dev)
                predCount += 1
            }
        }

        /// Statistics once per second (under the lock): frames, updates, renders, delta, update
        /// and render CPU time, GPU time of Celeste's buffers.
        private func logStatsIfDue(now: CFAbsoluteTime) {
            let elapsed = now - windowStart
            guard elapsed >= 1.0, windowFrames > 0 else { return }
            let updatesPerFrame = Double(windowTicks) / Double(windowFrames)
            let gpu = CelesteProbe.celesteGpu.take()
            let renders = max(windowRenders, 1)
            // GPU time per pass per world frame (world, edge, sprites, rest) and per canvas frame
            let passes = CelesteProbe.celesteGpuPasses.take()
            let worldFrames = Double(max(windowWorldFrames, 1))
            let canvasFrames = Double(max(windowRenders - windowWorldFrames, 1))
            let hostFrames = Double(max(passes.frames, 1))
            func perWorld(_ label: GpuPassStats.Label) -> Double { passes.inclusive(label) / worldFrames * 1000 }
            // exclusive time per pass (mean per world frame, max of one frame), host buffer per
            // frame, and the sum of all buffers of a frame; the inclusive values stay.
            func excl(_ label: GpuPassStats.Label, per frames: Double) -> String {
                String(format: "%.3f/%.3f", passes.exclusive(label) / frames * 1000, passes.exclusiveMax(label) * 1000)
            }
            let passText = String(format: " worldFrames=%d gpuPass(ms/frame) world=%.3f ui=%.3f edge=%.3f sprites=%.3f rest=%.3f canvas=%.3f unlabelled=%d stale=%d pending=%d",
                                  windowWorldFrames, perWorld(.world), perWorld(.ui), perWorld(.edge), perWorld(.sprites), perWorld(.rest),
                                  passes.inclusive(.canvas) / canvasFrames * 1000, passes.unlabelled, passes.stale, passes.pending)
                + " gpuExcl(ms/frame mean/max) world=\(excl(.world, per: worldFrames)) ui=\(excl(.ui, per: worldFrames)) edge=\(excl(.edge, per: worldFrames)) sprites=\(excl(.sprites, per: worldFrames)) rest=\(excl(.rest, per: worldFrames)) host=\(excl(.host, per: hostFrames))"
                + String(format: " sum=%.3f/%.3f", passes.frameTotalMean * 1000, passes.frameTotalMax * 1000)
            let timing = CelesteProbe.frameTiming.take()
            let cpu = CelesteProbe.frameTiming.takeCpu()
            // deadlineMissed is an approximation (GPU end against the CPU deadline), cpuLate
            // Apple's deadline (endSubmission after renderingDeadline), slowFrames frames with a
            // sum above 5.8 ms
            let timingText = String(format: " deadlineMissed=%d/%d deadlineMargin(ms) min=%+.2f mean=%+.2f presentGaps=%d waitOpt(ms) mean=%.2f max=%.2f toFirstCommit(ms) mean=%.2f max=%.2f n=%d frameSpan(ms) mean=%.2f max=%.2f cpuMargin(ms) min=%+.2f mean=%+.2f cpuLate=%d slowFrames=%d queryDrawables(ms) mean=%.3f max=%.3f anchorHeld=%d",
                                    timing.missed, timing.frames, timing.marginMin * 1000, timing.marginMean * 1000, timing.presentGaps,
                                    cpu.waitMean * 1000, cpu.waitMax * 1000, cpu.commitMean * 1000, cpu.commitMax * 1000, cpu.commitFrames,
                                    passes.spanMean * 1000, passes.spanMax * 1000, cpu.cpuMarginMin * 1000, cpu.cpuMarginMean * 1000, cpu.cpuLate, passes.slowFrames,
                                    cpu.queryMean * 1000, cpu.queryMax * 1000, cpu.anchorHeld)
            let wallText = wallCount > 0
                ? String(format: " wall(ms) mean=%.2f max=%.2f dev(ms) mean=%.3f max=%.3f", wallSum / Double(wallCount) * 1000, wallMax * 1000, devSum / Double(wallCount) * 1000, devMax * 1000)
                : ""
            let predText = predCount > 0
                ? String(format: " predVsActual(ms) mean=%.3f max=%.3f", predSum / Double(predCount) * 1000, predMax * 1000)
                : ""
            c64Record(String(format: "[c64-celeste] tick-stats frames=%d ticks=%d renders=%d updatesPerFrame=%.2f compositor=%.1f Hz delta(ms) mean=%.2f max=%.2f update(ms) mean=%.2f max=%.2f render(ms) mean=%.2f max=%.2f celesteGpu(ms) mean=%.3f max=%.3f n=%d total=%d",
                             windowFrames, windowTicks, windowRenders, updatesPerFrame, Double(windowFrames) / elapsed,
                             deltaSum / Double(windowTicks) * 1000, deltaMax * 1000,
                             updateMsSum / Double(windowTicks), updateMsMax,
                             renderMsSum / Double(renders), renderMsMax,
                             gpu.mean * 1000, gpu.max * 1000, gpu.count, totalTicks) + wallText + predText + timingText + passText)
            windowStart = now
            windowFrames = 0
            windowTicks = 0
            windowRenders = 0
            windowWorldFrames = 0
            deltaSum = 0
            deltaMax = 0
            wallSum = 0
            wallMax = 0
            devSum = 0
            devMax = 0
            wallCount = 0
            predSum = 0
            predMax = 0
            predCount = 0
            updateMsSum = 0
            updateMsMax = 0
            renderMsSum = 0
            renderMsMax = 0
        }

        /// Pause or end of the render loop: the ticks stop, the game stays (no celeste_end); after
        /// reopening the statistics window starts anew.
        func pause(reason: String) {
            lock.lock()
            defer { lock.unlock() }
            guard ready else { return }
            c64Record("[c64-celeste] tMs=\(LaunchClock.tMs) tick paused reason=\"\(reason)\" totalTicks=\(totalTicks) totalFrames=\(totalFrames)")
            windowStart = 0
            windowFrames = 0
            windowTicks = 0
            windowRenders = 0
            deltaSum = 0
            deltaMax = 0
            updateMsSum = 0
            updateMsMax = 0
            renderMsSum = 0
            renderMsMax = 0
            updatePending = false
        }

        func resume(reason: String) {
            lock.lock()
            defer { lock.unlock() }
            guard ready else { return }
            windowStart = CFAbsoluteTimeGetCurrent()
            c64Record("[c64-celeste] tMs=\(LaunchClock.tMs) tick resumed reason=\"\(reason)\" thread=\(Thread.current.name ?? "?") totalTicks=\(totalTicks)")
        }

        /// Final end of the ticks: no more ticks, not even after a resume; the next step is
        /// celeste_end on the main thread. Waits if a tick is running right now (same lock), so
        /// celeste_end never runs next to a tick.
        func stop(reason: String) {
            lock.lock()
            defer { lock.unlock() }
            let already = stopped
            stopped = true
            c64Record("[c64-celeste] tick stopped reason=\"\(reason)\" alreadyStopped=\(already ? 1 : 0) totalTicks=\(totalTicks) totalFrames=\(totalFrames)")
        }
    }

    static let tickState = TickState()

    // MARK: Clean exit

    private static let exitLock = NSLock()
    private static var exitRequested = false
    private static var exitCalled = false

    /// Ends the app cleanly: stop the ticks for good, celeste_end on the main thread (SDL's main
    /// thread, the thread of celeste_init; Foster End → Celeste's Shutdown → FMOD release;
    /// Dispose → SDL_Quit), then exit(0). Every log line goes to the kernel with an unbuffered
    /// write() before the next step (ProbeLog, no fsync) and so survives the exit(0).
    /// Watchdog: if the shutdown takes longer than one second, a second thread exits anyway,
    /// with a log line; it starts as the first step, before anything that can block (stop takes
    /// the tick lock, celeste_end runs on the main thread). Callable from any thread, but not
    /// under the tick lock; the first call wins. Triggers: layer invalidated (Digital Crown,
    /// space closed) and a tick with rc=1 ("Exit" in the title).
    nonisolated static func requestExit(reason: String) {
        let first = exitLock.withLock { () -> Bool in
            if exitRequested { return false }
            exitRequested = true
            return true
        }
        guard first else { return }
        let requestedAt = DispatchTime.now()

        // Watchdog first: after one second without an end, exit anyway.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
            exitOnce(line: "[c64-exit] shutdown exceeds 1 s, exiting anyway")
        }

        c64Record("[c64-exit] requested reason=\"\(reason)\" thread=\(Thread.current.name ?? "?") isMainThread=\(Thread.isMainThread)")
        tickState.stop(reason: reason)

        // With the mixer suspended (Crown in the background) no celeste_end. Game.End calls
        // Audio.Shutdown (system.release) and World.Disposed (SetPaused, buses), both FMOD; FMOD
        // forbids every call after mixerSuspend except mixerResume, "even if you intend to
        // shutdown FMOD as you may cause a deadlock" (platforms-android.html; iOS page: no FMOD
        // APIs between suspend and resume). mixerResume does not work in the background (the
        // session cannot be activated). The process ends anyway; saving happens only on
        // Save & Quit, nothing is lost.
        if pauseState.isMixerSuspended {
            exitOnce(line: "[c64-exit] mixer suspended: celeste_end skipped (no FMOD call after mixerSuspend), exit(0)")
            return
        }

        DispatchQueue.main.async {
            let start = DispatchTime.now()
            let rc = celeste_end()
            let endMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            let totalMs = Double(DispatchTime.now().uptimeNanoseconds - requestedAt.uptimeNanoseconds) / 1_000_000
            let error = rc == 0 ? "" : " error=\"\(celeste_last_error().map { String(cString: $0) } ?? "")\""
            c64Record("[c64-exit] celeste_end rc=\(rc) ms=\(format(endMs)) totalMs=\(format(totalMs)) exiting=\(celeste_exiting())\(error)")
            exitOnce(line: "[c64-exit] exit(0)")
        }
    }

    /// exit(0) exactly once; the last log line is with the kernel before the call (write(), no fsync).
    private nonisolated static func exitOnce(line: String) {
        let first = exitLock.withLock { () -> Bool in
            if exitCalled { return false }
            exitCalled = true
            return true
        }
        guard first else { return }
        c64Record(line)
        exit(0)
    }

    /// Number of ticks on the main thread: Celeste loads in the fifth update (loadDelay 5), three
    /// more show that the transition to the title begins without errors.
    static let initTicks = 8
    static let tickDelta = 1.0 / 90.0

    /// Bundle ID of the wrapper framework (scripts/build-game.sh, GAME_BUNDLE_ID).
    static let celesteFrameworkIdentifier = "com.lowriderxr.Celeste64.VisionOS"

    /// Result of the start (version, capabilities line, ok) for the [c64-start] lines.
    struct Result {
        var version: String
        var capabilitiesLine: String
        var ok: Bool
    }

    /// The host's device and queue for celeste_init; the host stays the owner, the pointers go to
    /// the wrapper unretained (SDL_GPU kit).
    @MainActor static var device: MTLDevice?
    @MainActor static var commandQueue: MTLCommandQueue?

    /// Log lines of the game (Foster, Celeste, SDL through Foster) into the probe.
    static let logLine: celeste_log_fn = { level, utf8, _ in
        guard let utf8 else { return }
        let kind = level == 2 ? "error" : (level == 1 ? "warn" : "info")
        c64Record("[c64-celeste] game(\(kind)) \(String(cString: utf8))")
    }

    /// Version and capabilities before celeste_init. Every line goes into the probe
    /// ([c64-celeste]).
    static func runProbe() -> Result {
        let start = DispatchTime.now()

        let version: String
        if let cString = celeste_version() {
            version = String(cString: cString)
        } else {
            version = "(celeste_version returned NULL)"
        }
        let versionMs = elapsedMs(since: start)
        c64Record("[c64-celeste] step=version thread=\(Thread.isMainThread ? "main" : "other") version=\"\(version)\" ms=\(format(versionMs))")

        let (rc, line) = capabilities(label: "before-init")
        c64Record("[c64-celeste] step=done totalMs=\(format(elapsedMs(since: start)))")

        return Result(version: version, capabilitiesLine: line, ok: rc == 0)
    }

    /// Probe, then celeste_init with a hidden window and the necessary ticks on the main thread.
    /// Returns the capabilities after init in the capabilities line.
    @MainActor static func runInit(since probeStart: DispatchTime) -> Result {
        var result = runProbe()
        let start = DispatchTime.now()

        // Content root: the embedded Celeste64.VisionOS.framework; scripts/build-game.sh puts the
        // Content folder inside (a folder in the framework keeps its structure, a synchronized
        // Xcode folder would lay the files flat into the bundle).
        let frameworkBundle = Bundle(identifier: celesteFrameworkIdentifier)
            ?? Bundle.main.privateFrameworksPath.flatMap { Bundle(path: ($0 as NSString).appendingPathComponent("Celeste64.VisionOS.framework")) }
        guard let contentRoot = frameworkBundle?.bundlePath else {
            c64Error("[c64-celeste] step=init skipped: Celeste64.VisionOS.framework not found (bundle ID \(celesteFrameworkIdentifier), privateFrameworksPath \(Bundle.main.privateFrameworksPath ?? "nil"))")
            result.ok = false
            result.capabilitiesLine = "framework not found"
            return result
        }
        let contentDir = (contentRoot as NSString).appendingPathComponent("Content")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: contentDir, isDirectory: &isDirectory), isDirectory.boolValue else {
            c64Error("[c64-celeste] step=init skipped: no Content folder in \(contentRoot); run scripts/build-game.sh again (it copies Source/Celeste64/Content into the framework)")
            result.ok = false
            result.capabilitiesLine = "Content missing in the framework"
            return result
        }
        let contentFiles = (FileManager.default.enumerator(atPath: contentDir)?.allObjects.count) ?? 0
        c64Record("[c64-celeste] step=content root=\"\(contentRoot)\" entries=\(contentFiles)")

        // The host's device and queue; the renderer takes over the same queue.
        guard ensureHostDevice(), let mtlDevice = device, let queue = commandQueue else {
            c64Record("[c64-celeste] step=init skipped: no MTLDevice or no queue")
            result.ok = false
            return result
        }

        // Log lines of the game from now on through the callback (Foster then no longer writes to stdout).
        let logRc = celeste_set_log_callback(logLine, nil)
        c64Record("[c64-celeste] step=log-callback rc=\(logRc)")

        windowSnapshot("before-init", since: probeStart)
        let availableBefore = ProbeContext.availableMemoryMB
        let footprintBefore = ProbeContext.physFootprintMB
        c64Record("[c64-celeste] memory before-init availableMB=\(format(availableBefore)) footprintMB=\(format(footprintBefore))")

        var options = celeste_init_options()
        options.size = Int32(MemoryLayout<celeste_init_options>.size)
        options.hidden_window = 1
        options.depth_clip = 0      // Foster turns depth clip on by itself on visionOS
        options.metal_device = Unmanaged.passUnretained(mtlDevice).toOpaque()
        options.metal_command_queue = Unmanaged.passUnretained(queue).toOpaque()
        // GPU time of Celeste's command buffers through the kit callback.
        options.completed_callback = unsafeBitCast(celesteCommandBufferCompleted, to: UnsafeMutableRawPointer.self)
        options.completed_userdata = nil
        // Internal resolution and outline width (C64_RES and C64_LINE; the host resolves auto).
        options.internal_width = Int32(settings.internalWidth)
        options.internal_height = Int32(settings.internalHeight)
        options.edge_line_width = Int32(settings.edgeLineWidth)
        // Depth convention of the VR path: reverse-Z with an infinite far plane; the near plane
        // follows in the renderer from the layer configuration (celeste_set_depth_near).
        options.reverse_z = 1

        let initStart = DispatchTime.now()
        let initRc: Int32 = contentRoot.withCString { cRoot in
            options.content_root = cRoot
            return celeste_init(&options)
        }
        let initMs = elapsedMs(since: initStart)
        if initRc == 0 {
            c64Record("[c64-celeste] tMs=\(LaunchClock.tMs) step=init rc=0 thread=\(Thread.isMainThread ? "main" : "other") contentRoot=\"\(contentRoot)\" internal=\(settings.internalWidth)x\(settings.internalHeight) line=\(settings.edgeLineWidth) reverseZ=\(options.reverse_z) optionsSize=\(options.size) ms=\(format(initMs))")
        } else {
            let error = celeste_last_error().map { String(cString: $0) } ?? ""
            c64Error("[c64-celeste] step=init rc=\(initRc) error=\"\(error)\" ms=\(format(initMs))")
            result.ok = false
            result.capabilitiesLine = "celeste_init rc=\(initRc)"
            return result
        }
        windowSnapshot("after-init", since: probeStart)
        sdlWindowInfo("after-init")

        // Ticks on the main thread: Startup counts five updates, then Assets.Load.
        var ticksOk = 0
        for index in 0..<initTicks {
            let tickStart = DispatchTime.now()
            let rc = celeste_tick(tickDelta, 0)
            let ms = elapsedMs(since: tickStart)
            if rc == -1 {
                let error = celeste_last_error().map { String(cString: $0) } ?? ""
                c64Record("[c64-celeste] step=tick index=\(index) rc=-1 error=\"\(error)\" ms=\(format(ms))")
                result.ok = false
                break
            }
            ticksOk += 1
            c64Record("[c64-celeste] step=tick index=\(index) rc=\(rc) ms=\(format(ms))")
        }
        c64Record("[c64-celeste] step=ticks ok=\(ticksOk) of=\(initTicks) exiting=\(celeste_exiting())")

        let (rc, line) = capabilities(label: "after-init")
        if rc == 0 {
            result.capabilitiesLine = line
        } else {
            result.ok = false
        }
        windowSnapshot("after-ticks", since: probeStart)
        sdlWindowInfo("after-ticks")
        let availableAfter = ProbeContext.availableMemoryMB
        let footprintAfter = ProbeContext.physFootprintMB
        c64Record("[c64-celeste] memory after-ticks availableMB=\(format(availableAfter)) footprintMB=\(format(footprintAfter)) deltaFootprintMB=\(format(footprintAfter - footprintBefore))")
        c64Record("[c64-celeste] step=done totalMs=\(format(elapsedMs(since: start)))")
        return result
    }

    /// Window check: all UIKit window scenes of the app with state, size and windows. SDL creates
    /// its (hidden) UIWindow in the active scene and requests its logical size there
    /// (SDL_uikitwindow.m, requestGeometryUpdate). `since` adds the time since the start of the
    /// probe in milliseconds, so the lines of the different labels are comparable.
    @MainActor static func windowSnapshot(_ label: String, since start: DispatchTime? = nil) {
        let timing = start.map { " tMs=\(format(elapsedMs(since: $0)))" } ?? ""
        // All connected scenes with class and role (without a window there is only the immersive
        // scene, which is no UIWindowScene); windows only for UIWindowScene.
        let all = Array(UIApplication.shared.connectedScenes)
        let windowScenes = all.compactMap { $0 as? UIWindowScene }
        c64Record("[c64-celeste] scenes \(label)\(timing) count=\(all.count) windowScenes=\(windowScenes.count) [\(all.map { "\(String(describing: type(of: $0))) role=\($0.session.role.rawValue) state=\($0.activationState.rawValue)" }.joined(separator: " | "))]")
        for (index, scene) in windowScenes.enumerated() {
            let bounds = scene.effectiveGeometry.coordinateSpace.bounds.size
            let windows = scene.windows.map { window -> String in
                let root = window.rootViewController.map { String(describing: type(of: $0)) } ?? "-"
                return "\(String(describing: type(of: window))) \(Int(window.frame.width))x\(Int(window.frame.height)) hidden=\(window.isHidden) key=\(window.isKeyWindow) root=\(root)"
            }.joined(separator: " | ")
            c64Record("[c64-celeste] window \(label)\(timing) scene=\(index) role=\(scene.session.role.rawValue) state=\(scene.activationState.rawValue) bounds=\(Int(bounds.width))x\(Int(bounds.height)) windows=\(scene.windows.count) [\(windows)]")
        }
    }

    /// Number of UIWindowScenes; 0 means SDL's UIWindow has no scene (fallback initWithFrame).
    @MainActor static var windowSceneCount: Int {
        UIApplication.shared.connectedScenes.filter { $0 is UIWindowScene }.count
    }

    /// The app's audio session before celeste_init: category .playback, active. FMOD leaves the
    /// session to the app (FMOD documentation iOS); .playback is tied to no window scene, which
    /// the sound needs to survive the closing of the 2D window. setActive blocks (audio server),
    /// so the call runs on its own task; the start waits for it (await) before celeste_init
    /// initialises FMOD (System::init opens the output and needs the finished session). Only the
    /// order is fixed, not the thread.
    static func configureAudioSession() async {
        let start = DispatchTime.now()
        await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
                let route = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
                c64Record("[c64-audio] session category=\(session.category.rawValue) active route=[\(route)] sampleRate=\(session.sampleRate) thread=\(Thread.current.name ?? "detached") isMainThread=\(Thread.isMainThread)")
            } catch {
                c64Error("[c64-audio] session setCategory/setActive failed: \(error)")
            }
        }.value
        c64Record("[c64-audio] tMs=\(LaunchClock.tMs) session ready after \(format(elapsedMs(since: start))) ms, main thread free meanwhile")
    }

    // MARK: Pause when the device is taken off

    /// App state for the render thread: the main thread sets the background flag at
    /// willResignActive and didEnterBackground and clears it at didBecomeActive, once UIKit reports
    /// the app as active and a scene as foregroundActive. The layer reports .paused only 150 to
    /// 200 ms after willResignActive and .running long before the foreground (on the M2: 8 s
    /// before); the flag closes both gaps. Plus the request for a new audio attempt (audio
    /// session active again, resumption recommendation, media services reset).
    nonisolated final class PauseState: @unchecked Sendable {
        private let lock = NSLock()
        private var background = false
        private var audioRetry = false
        private var audioRetryTrigger = ""
        private var mediaReset = false
        private var mixerSuspended = false

        var isBackground: Bool { lock.withLock { background } }

        /// Mixer state for the exit: the render thread sets it after every successful mixerSuspend
        /// and mixerResume; requestExit reads it (no FMOD call with the mixer suspended, not even
        /// to exit).
        var isMixerSuspended: Bool { lock.withLock { mixerSuspended } }
        func setMixerSuspended(_ value: Bool) { lock.withLock { mixerSuspended = value } }

        func setBackground(reason: String) {
            let changed = lock.withLock { () -> Bool in
                let was = background
                background = true
                return !was
            }
            c64Record("[c64-pause] tMs=\(LaunchClock.tMs) background=1 reason=\(reason)\(changed ? "" : " (already set)")")
            if changed {
                CelesteProbe.AliveProbe.shared.begin()
            }
        }

        /// Clears the flag only when the app really is in the foreground (UIKit); otherwise a log line.
        @MainActor func clearBackgroundIfForeground(reason: String) {
            let app = UIApplication.shared.applicationState
            let foregroundScene = UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            guard app == .active, foregroundScene else {
                c64Record("[c64-pause] tMs=\(LaunchClock.tMs) background stays 1 reason=\(reason) app=\(app == .active ? "active" : (app == .inactive ? "inactive" : "background")) foregroundScene=\(foregroundScene ? 1 : 0)")
                return
            }
            let changed = lock.withLock { () -> Bool in
                let was = background
                background = false
                return was
            }
            if changed {
                c64Record("[c64-pause] tMs=\(LaunchClock.tMs) background=0 reason=\(reason) app=active scene=foregroundActive")
            }
        }

        func requestAudioRetry(trigger: String, mediaServicesReset: Bool = false) {
            lock.withLock {
                audioRetry = true
                audioRetryTrigger = trigger
                if mediaServicesReset { mediaReset = true }
            }
        }

        /// Render thread: collect the request for an audio attempt (once), plus whether media
        /// services were reset (FMOD example: then suspend and resume as a pair).
        func takeAudioRetry() -> (trigger: String, mediaServicesReset: Bool)? {
            lock.withLock {
                guard audioRetry || mediaReset else { return nil }
                let result = (audioRetry ? audioRetryTrigger : "mediaServicesReset", mediaReset)
                audioRetry = false
                audioRetryTrigger = ""
                mediaReset = false
                return result
            }
        }
    }

    static let pauseState = PauseState()

    /// Last head pose from the device anchor (render thread writes per frame, main thread reads
    /// at onWorldRecenter): position in metres, yaw in degrees (positive to the right, 0 = −Z).
    nonisolated final class HeadPose: @unchecked Sendable {
        private let lock = NSLock()
        private var position = SIMD3<Float>(0, 0, 0)
        private var yawDegrees: Float = 0
        private var ageMs: Double = -1
        private var frames = 0

        func set(anchor: simd_float4x4) {
            let p = SIMD3<Float>(anchor.columns.3.x, anchor.columns.3.y, anchor.columns.3.z)
            let forward = -SIMD3<Float>(anchor.columns.2.x, anchor.columns.2.y, anchor.columns.2.z)
            let yaw = atan2(forward.x, -forward.z) * 180 / .pi
            lock.withLock {
                position = p
                yawDegrees = yaw
                ageMs = LaunchClock.elapsedMs
                frames += 1
            }
        }

        var line: String {
            lock.withLock {
                guard ageMs >= 0 else { return "head=- yaw=- (no pose yet)" }
                return String(format: "head=(%.2f, %.2f, %.2f) yaw=%.1f° poseTMs=%.1f frames=%d", position.x, position.y, position.z, yawDegrees, ageMs, frames)
            }
        }
    }

    static let headPose = HeadPose()

    /// Reference O for the head pose: position and yaw of the device anchor at a reference time.
    /// Set after `settleFrames` frames from start or resume (the pose should be still),
    /// `recenterFrames` frames after onWorldRecenter ended (at ended the pose still shows the old
    /// values, probe of 2026-10-27) and at once on a jump (over 0.5 m or 10° in one frame).
    /// Returns per frame the pose relative to O (inverse(O) · anchor). The render thread writes,
    /// the main thread reports the recenter.
    nonisolated final class StereoOrigin: @unchecked Sendable {
        static let shared = StereoOrigin()
        static let settleFrames = 90
        static let recenterFrames = 20
        private let lock = NSLock()
        private var reference: simd_float4x4?
        private var referenceInverse = matrix_identity_float4x4
        private var settleRemaining = StereoOrigin.settleFrames
        private var settleReason = "Start"
        private var recenterRemaining = -1
        private var firstPoseAfterRecenter: String?
        private var lastAnchor: simd_float4x4?
        private var resets = 0
        private var lastRelative = matrix_identity_float4x4

        /// Rotation about Y (yaw) plus position of the anchor; pitch and roll drop out.
        static func yawOnly(_ anchor: simd_float4x4) -> simd_float4x4 {
            let backFlat = SIMD3<Float>(anchor.columns.2.x, 0, anchor.columns.2.z)
            let length = simd_length(backFlat)
            let back = length > 1e-4 ? backFlat / length : SIMD3<Float>(0, 0, 1)
            let up = SIMD3<Float>(0, 1, 0)
            let right = simd_cross(up, back)
            return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), anchor.columns.3))
        }

        /// Yaw in degrees, 0 = −Z, positive to the right (like HeadPose).
        static func yawDegrees(_ m: simd_float4x4) -> Float {
            let forward = -SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            return atan2(forward.x, -forward.z) * 180 / .pi
        }

        static func position(_ m: simd_float4x4) -> SIMD3<Float> {
            SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }

        func recenterEnded() {
            lock.withLock {
                recenterRemaining = Self.recenterFrames
                firstPoseAfterRecenter = nil
            }
        }

        func requestSettle(_ reason: String) {
            lock.withLock {
                settleRemaining = Self.settleFrames
                settleReason = reason
            }
        }

        /// Pose of this frame relative to O; reset = O was set in this frame.
        func update(anchor: simd_float4x4, frameIndex: UInt64) -> (relative: simd_float4x4, reset: Bool) {
            lock.lock()
            defer { lock.unlock() }
            var reset = false
            var reason = ""
            // jump against the previous frame
            if let last = lastAnchor {
                let jump = simd_length(Self.position(anchor) - Self.position(last))
                var dYaw = abs(Self.yawDegrees(anchor) - Self.yawDegrees(last))
                if dYaw > 180 { dYaw = 360 - dYaw }
                if jump > 0.5 || dYaw > 10 {
                    reset = true
                    reason = String(format: "jump %.2f m, %.1f°", jump, dYaw)
                }
            }
            lastAnchor = anchor
            // settling phase after start or resume
            if settleRemaining > 0 {
                settleRemaining -= 1
                if settleRemaining == 0 {
                    reset = true
                    reason = "\(settleReason), \(Self.settleFrames) Frames"
                }
            }
            // recenter: only a few frames after ended
            if recenterRemaining >= 0 {
                if recenterRemaining == Self.recenterFrames - 1 || firstPoseAfterRecenter == nil {
                    firstPoseAfterRecenter = String(format: "(%.2f, %.2f, %.2f) yaw=%.1f°", Self.position(anchor).x, Self.position(anchor).y, Self.position(anchor).z, Self.yawDegrees(anchor))
                }
                recenterRemaining -= 1
                if recenterRemaining < 0 {
                    reset = true
                    reason = "recenter, \(Self.recenterFrames) frames after ended, first pose afterwards \(firstPoseAfterRecenter ?? "-")"
                }
            }
            if reset || reference == nil {
                let o = Self.yawOnly(anchor)
                if reset {
                    reference = o
                    referenceInverse = o.inverse
                    resets += 1
                    c64Record(String(format: "[c64-recenter] tMs=%@ frame=%llu O set anew (%@): O=(%.2f, %.2f, %.2f) yaw=%.1f° resets=%d",
                                     LaunchClock.tMs, frameIndex, reason, Self.position(o).x, Self.position(o).y, Self.position(o).z, Self.yawDegrees(o), resets))
                } else {
                    // no O yet: provisionally the own pose as reference (head-locked until the settling phase)
                    lastRelative = o.inverse * anchor
                    return (lastRelative, false)
                }
            }
            lastRelative = referenceInverse * anchor
            return (lastRelative, reset)
        }

        /// [c64-head]: offset to O in metres and yaw relative to O.
        var line: String {
            lock.withLock {
                guard let reference else { return "O=- (not set yet, settle=\(settleRemaining))" }
                let p = Self.position(lastRelative)
                return String(format: "offset=(%.2f, %.2f, %.2f) m yawRel=%.1f° O=(%.2f, %.2f, %.2f) yawO=%.1f° resets=%d",
                              p.x, p.y, p.z, Self.yawDegrees(lastRelative), Self.position(reference).x, Self.position(reference).y, Self.position(reference).z, Self.yawDegrees(reference), resets)
            }
        }
    }

    /// Alive probe: its own thread "c64-alive", woken by the background flag, writes one line per
    /// second into the probe, at most 600 per pause; on resuming one line with the gap since the
    /// last sign of life. A process suspended by the system shows a large gap on waking, an awake
    /// one (debugger attached) gapless seconds. Calls neither FMOD nor Metal nor
    /// CompositorServices; takes only its own lock. Layer and provider state come as texts from
    /// outside (the renderer sets them), so the probe needs no foreign lock.
    nonisolated final class AliveProbe: @unchecked Sendable {
        static let shared = AliveProbe()
        static let maxBeatsPerPause = 600

        private let condition = NSCondition()
        private var started = false
        private var active = false
        private var beats = 0
        private var lastBeatMs: Double?
        private var layerStateText = "-"
        private var providerStateText = "-"
        private var readLayerState: (() -> String)?

        func start() {
            condition.lock()
            let first = !started
            started = true
            condition.unlock()
            guard first else { return }
            let thread = Thread { [self] in loop() }
            thread.name = "c64-alive"
            thread.qualityOfService = .utility
            thread.start()
        }

        /// Renderer: reader for the layer state (cp_layer_renderer_get_state, no lock).
        func setLayerStateReader(_ reader: @escaping () -> String) {
            condition.lock(); readLayerState = reader; condition.unlock()
        }

        /// Renderer, at every state change of the WorldTrackingProvider.
        func setProviderState(_ text: String) {
            condition.lock(); providerStateText = text; condition.unlock()
        }

        /// Main thread, when the background flag is set.
        func begin() {
            condition.lock()
            if !active {
                active = true
                beats = 0
                lastBeatMs = nil
            }
            condition.signal()
            condition.unlock()
        }

        /// Render thread, on resuming: gap since the last sign of life.
        func end(resumeMs: Double) {
            condition.lock()
            let wasActive = active
            active = false
            let last = lastBeatMs
            let count = beats
            condition.signal()
            condition.unlock()
            guard wasActive else { return }
            if let last {
                c64Record(String(format: "[c64-alive] tMs=%.1f gap=%.0f ms beats=%d", resumeMs, resumeMs - last, count))
            } else {
                c64Record(String(format: "[c64-alive] tMs=%.1f gap=- beats=0 (no sign of life during this pause)", resumeMs))
            }
        }

        private func loop() {
            while true {
                condition.lock()
                while !active { condition.wait() }
                let reader = readLayerState
                let provider = providerStateText
                let count = beats
                condition.unlock()
                if count >= Self.maxBeatsPerPause {
                    // limit reached: sleep until the end of the pause (no further sign).
                    condition.lock()
                    while active { condition.wait() }
                    condition.unlock()
                    continue
                }
                let now = LaunchClock.elapsedMs
                let layer = reader?() ?? "-"
                c64Record(String(format: "[c64-alive] tMs=%.1f n=%d background=%d layer=%@ provider=%@", now, count + 1,
                                 CelesteProbe.pauseState.isBackground ? 1 : 0, layer, provider))
                condition.lock()
                beats += 1
                lastBeatMs = now
                if active {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 1.0))
                }
                condition.unlock()
            }
        }
    }

    /// Suspend the FMOD mixer or let it run again (celeste_audio_suspend); from the render thread,
    /// both calls on the same thread without a tick in between (FMOD documentation iOS). Only with
    /// the game. Returns true on FMOD_OK.
    @discardableResult
    nonisolated static func suspendAudio(_ suspend: Bool, context: String = "") -> Bool {
        guard tickState.isActive || suspend == false else { return false }
        let start = DispatchTime.now()
        let rc = celeste_audio_suspend(suspend ? 1 : 0)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let error = rc == 0 ? "" : " error=\"\(celeste_last_error().map { String(cString: $0) } ?? "")\""
        c64Record("[c64-audio] tMs=\(LaunchClock.tMs) mixer \(suspend ? "suspend" : "resume") rc=\(rc) ms=\(format(ms)) thread=\(Thread.current.name ?? "?")\(context.isEmpty ? "" : " context=\(context)")\(error)")
        return rc == 0
    }

    /// Reactivate the audio session after a pause before FMOD's mixer runs again (the system
    /// deactivates the session when it suspends the process). Returns true on success; FMOD's
    /// example (common_platform.mm:211-227) does not call mixerResume on an error but waits for
    /// the next signal.
    @discardableResult
    nonisolated static func reactivateAudioSession() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) session setActive(true) ok")
            return true
        } catch {
            c64Record("[c64-audio] tMs=\(LaunchClock.tMs) session setActive(true) failed: \(error)")
            return false
        }
    }

    /// Pause request to the game (celeste_request_pause); Game.Update opens the pause menu of a
    /// running level and logs [c64-pause] applied=.
    nonisolated static func requestPause() {
        guard tickState.isActive else { return }
        let rc = celeste_request_pause()
        c64Record("[c64-audio] tMs=\(LaunchClock.tMs) pause requested rc=\(rc)")
    }

    /// Observer for lifecycle and audio signals: UIKit notifications (they set and clear the
    /// background flag), AVAudioSession didBecomeInactive with source and interruption reason,
    /// resumptionRecommendation, didBecomeActive, media services reset and route changes. The
    /// audio signals request a new audio attempt from the render thread; everything is logged.
    nonisolated final class LifecycleMonitor: @unchecked Sendable {
        static let shared = LifecycleMonitor()
        private var started = false
        private var tokens: [NSObjectProtocol] = []

        @MainActor func start() {
            guard !started else { return }
            started = true
            let center = NotificationCenter.default
            let app: [(Notification.Name, String)] = [
                (UIApplication.willResignActiveNotification, "willResignActive"),
                (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
                (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
                (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
            ]
            for (name, label) in app {
                tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        c64Record("[c64-life] tMs=\(LaunchClock.tMs) \(label); \(CelesteProbe.lifecycleLine)")
                        // background flag for the render thread.
                        switch name {
                        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification:
                            CelesteProbe.pauseState.setBackground(reason: label)
                        case UIApplication.didBecomeActiveNotification:
                            CelesteProbe.pauseState.clearBackgroundIfForeground(reason: label)
                        default:
                            break
                        }
                    }
                })
            }
            // visionOS 27 replaces interruptionNotification with didBecomeInactive (with
            // DeactivationContext: source, interruption reason) and resumptionRecommendation
            // (shouldResume or shouldNotResume); didBecomeActive reports the activation.
            tokens.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { note in
                let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                let source = context.map { "\($0.source.rawValue)" } ?? "-"
                let reason = context?.interruptionContext.map { Self.name($0.reason) } ?? "-"
                c64Record("[c64-life] tMs=\(LaunchClock.tMs) AVAudioSession didBecomeInactive source=\(source) interruptionReason=\(reason)")
            })
            tokens.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                let shouldResume = context.map { $0.recommendation == .shouldResume ? "1" : "0" } ?? "-"
                c64Record("[c64-life] tMs=\(LaunchClock.tMs) AVAudioSession resumptionRecommendation shouldResume=\(shouldResume)")
                if shouldResume == "1" {
                    // The render thread tries setActive and mixerResume (same thread as the
                    // suspend) as soon as it runs.
                    CelesteProbe.pauseState.requestAudioRetry(trigger: "resumptionRecommendation")
                }
            })
            tokens.append(center.addObserver(forName: AVAudioSession.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                c64Record("[c64-life] tMs=\(LaunchClock.tMs) AVAudioSession didBecomeActive")
                CelesteProbe.pauseState.requestAudioRetry(trigger: "session didBecomeActive")
            })
            tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
                // FMOD example common_platform.mm:184-197: in the foreground suspend and resume as
                // a pair, in the background at the next resume; here the render thread takes over.
                c64Record("[c64-life] tMs=\(LaunchClock.tMs) AVAudioSession mediaServicesWereReset")
                CelesteProbe.pauseState.requestAudioRetry(trigger: "mediaServicesReset", mediaServicesReset: true)
            })
            tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map { "\($0)" } ?? "-"
                let route = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
                c64Record("[c64-life] tMs=\(LaunchClock.tMs) AVAudioSession routeChange reason=\(reason) route=[\(route)]")
            })
            c64Record("[c64-life] tMs=\(LaunchClock.tMs) monitor started")
            CelesteProbe.AliveProbe.shared.start()
        }

        private static func name(_ reason: AVAudioSession.InterruptionReason) -> String {
            switch reason {
            case .default: return "default"
            case .appWasSuspended: return "appWasSuspended"
            case .sceneWasBackgrounded: return "sceneWasBackgrounded"
            case .routeDisconnected: return "routeDisconnected"
            case .builtInMicMuted: return "builtInMicMuted"
            default: return "reason\(reason.rawValue)"
            }
        }
    }

    /// Lifecycle in one line (log only): app state from UIKit and state of every connected scene
    /// with role. The immersion style of a CompositorServices scene cannot be read (no public API
    /// on UIScene, onImmersionChange only on views).
    @MainActor static var lifecycleLine: String {
        let app: String
        switch UIApplication.shared.applicationState {
        case .active: app = "active"
        case .inactive: app = "inactive"
        case .background: app = "background"
        @unknown default: app = "unknown"
        }
        let scenes = UIApplication.shared.connectedScenes.map { scene -> String in
            let state: String
            switch scene.activationState {
            case .unattached: state = "unattached"
            case .foregroundActive: state = "foregroundActive"
            case .foregroundInactive: state = "foregroundInactive"
            case .background: state = "background"
            @unknown default: state = "unknown"
            }
            return "\(String(describing: type(of: scene))) role=\(scene.session.role.rawValue) state=\(state)"
        }
        return "applicationState=\(app) scenes=[\(scenes.joined(separator: " | "))]"
    }

    /// Foster's window as SDL sees it: the logical size is the size SDL sends to the scene as a
    /// geometry request when creating (points); pixels and density show what Foster and Celeste
    /// see as the backbuffer.
    @MainActor static func sdlWindowInfo(_ label: String) {
        var info = celeste_window_info()
        info.size = Int32(MemoryLayout<celeste_window_info>.size)
        let rc = celeste_window_info_get(&info)
        if rc == 0 {
            // scene: 1 when a UIWindowScene exists (SDL attaches its window to it), otherwise 0
            // (SDL_uikitwindow.m: fallback initWithFrame without a scene).
            let windowScenes = windowSceneCount
            c64Record("[c64-celeste] sdl-window \(label) requested=\(info.width)x\(info.height) pixels=\(info.pixel_width)x\(info.pixel_height) density=\(Double(info.pixel_density_x1000) / 1000) hidden=\(info.hidden) fullscreen=\(info.fullscreen) windowScenes=\(windowScenes) scene=\(windowScenes > 0 ? 1 : 0)")
        } else {
            let error = celeste_last_error().map { String(cString: $0) } ?? ""
            c64Record("[c64-celeste] sdl-window \(label) rc=\(rc) error=\"\(error)\"")
        }
    }

    private static func capabilities(label: String) -> (Int32, String) {
        var caps = celeste_capabilities()
        caps.size = Int32(MemoryLayout<celeste_capabilities>.size)
        let start = DispatchTime.now()
        let rc = celeste_capabilities_get(&caps)
        let ms = elapsedMs(since: start)
        let line = "kitSdlLoaded=\(caps.kit_sdl_loaded) kitExports=\(caps.kit_exports) multiView=\(caps.multi_view) passProperties=\(caps.pass_properties) externalTextures=\(caps.external_textures) memoryless=\(caps.memoryless) depthResolve=\(caps.depth_resolve)"
        if rc == 0 {
            c64Record("[c64-celeste] step=capabilities rc=0 \(label) \(line) ms=\(format(ms))")
        } else {
            let error = celeste_last_error().map { String(cString: $0) } ?? ""
            c64Record("[c64-celeste] step=capabilities rc=\(rc) \(label) error=\"\(error)\" ms=\(format(ms))")
        }
        return (rc, line)
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

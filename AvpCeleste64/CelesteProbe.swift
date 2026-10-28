//
//  CelesteProbe.swift
//  AvpCeleste64
//
//  Schalter C64_CELESTE (Standard aus):
//    C64_CELESTE=probe  Stufe M1a.2: beim Start im Hauptthread celeste_version und
//                       celeste_capabilities_get aus Celeste64.VisionOS.framework aufrufen und
//                       loggen. Kein celeste_init, kein SDL, kein Spiel; die Hülle beweist nur,
//                       dass die Native-AOT-Bibliothek geladen ist und die Fähigkeitsprüfung
//                       vor dem Spiel läuft (Docs port-analyse.md, «Analyse M1a», Wege a und c).
//    C64_CELESTE=init   Stufe M1a.4 (Variante B, Teil 1): wie probe, dann celeste_init auf dem
//                       Hauptthread vor dem ImmersiveSpace mit verstecktem Fenster, Device und
//                       Queue des Hosts und dem Bundle als Content-Root; danach acht Ticks mit
//                       present 0 auf dem Hauptthread, bis Celeste seine Inhalte geladen hat
//                       (Startup.cs: Laden im fünften Update), und die Fähigkeiten nach init.
//                       Fensterprüfung: UIKit-Fenster der Szene vor, direkt nach und eine
//                       Sekunde nach init. celeste_end wird nicht gerufen (SDL_Quit beendet
//                       SDL im ganzen Prozess). Kein Tick auf dem Render-Thread (M1a.5).
//
//  Unabhängig von C64_KIT; init und ein Kit-Modus zusammen sind nicht sinnvoll (zwei SDL_GPU-
//  Devices auf demselben MTLDevice), die Kit-Modi laufen aber unverändert danach.
//
//  Weitere Schalter (M4a.4, siehe GameSettings): C64_RES für die interne Auflösung des Spiels
//  (Standard 1920x1080) und C64_LINE für die Umrissbreite (Standard auto); die Leinwand hat die
//  interne Auflösung, C64_CANVAS_FOV ihre Winkelbreite, C64_CANVAS_FILTER den Filter.
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
    static let environmentKey = "C64_CELESTE"

    enum Mode: String {
        /// Celeste aus (Kit-Modi oder reines Gerüst).
        case off
        case probe
        case initialize = "init"
        /// M1a.4b: Vergleichslauf ohne Celeste, nur die Fenster-Schnappschüsse der Szene zu
        /// denselben Zeitpunkten (Start, 0,2 s, 1 s, 2 s). Zeigt, was SwiftUI allein mit dem
        /// Fenster macht (Standardgrösse 1280×720, dann Layout auf die Inhaltsgrösse).
        case window
        /// M1a.5 (Variante B, Teil 2): wie init, danach übernimmt der Render-Thread des
        /// Compositors das Ticken, ein celeste_tick pro Frame in der Update-Phase
        /// (Renderer.renderFrame, zwischen startUpdate und endUpdate), present 0, Delta aus dem
        /// Frame-Takt begrenzt auf 1/30 s. Kein Bild in die Drawables (M4a). Beim Pausieren des
        /// Layers pausieren die Ticks; das Schliessen des ImmersiveSpace (Digital Crown) und
        /// «Exit» im Spiel beenden die App sauber über requestExit (M4a.5a: celeste_end, exit(0)).
        case tick
        /// M4a.2: Leinwand ohne Celeste. Der Host legt Device, Queue und eine 1280×720-Textur
        /// (RGBA8Unorm, PixelFormatView) an, füllt sie einmal (Verlauf, Gitter, Markierung oben
        /// links) und der Renderer zeichnet sie als Quad in 500 m in beide Augen (CanvasScene).
        /// Prüft Pass, Tiefe, Grund-Clear, Verankerung, Foveation und die gemeinsame Queue, bevor
        /// Celestes Bild kommt (M4a.3). Kein celeste_init.
        case canvas
        /// M4a.3: Celestes Bild auf der Leinwand. Init und Laden wie tick, dann celeste_set_canvas
        /// mit der Leinwandtextur (vor dem ersten Tick im Render-Thread, Vertrag aus M4a.1),
        /// Ticks im Render-Thread, Leinwand-Pass danach mit sRGB-Ansicht; die Leinwand erscheint
        /// erst nach dem Verankern (0,3 s Einblendung). Completion-Rückruf des Kits misst die
        /// GPU-Zeit von Celestes Command Buffern; nach rund 7 s ein Rücklesen der Leinwand als PNG
        /// und RGBA-Rohdaten in Documents für den Farbvergleich mit dem Mac.
        case play
    }

    /// Modi, in denen der Render-Thread Celeste tickt.
    static var ticksGame: Bool { mode == .tick || mode == .play }
    /// Modi, in denen der Renderer die Leinwand zeichnet.
    static var canvasWanted: Bool { mode == .canvas || mode == .play }

    /// GPU-Zeit von Command Buffern (gpuEndTime − gpuStartTime), gesammelt aus einem
    /// Completed-Rückruf (Metal-Thread), gelesen pro Sekunde vom Render-Thread.
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

    /// GPU-Zeit von Celestes SDL-Command-Buffern (Kit-Rückruf, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_BUFFER_COMPLETED_CALLBACK_POINTER).
    static let celesteGpu = GpuStats()

    /// C-Rückruf des Kits: void (*)(void *userdata, void *mtl_command_buffer); läuft auf Metals
    /// Completion-Thread, der Buffer ist dort vollständig (gpuStartTime und gpuEndTime gesetzt).
    static let celesteCommandBufferCompleted: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, raw in
        guard let raw else { return }
        let buffer = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard let commandBuffer = buffer as? MTLCommandBuffer else { return }
        CelesteProbe.celesteGpu.add(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
    }

    /// M4a.3: Celestes Endbild in die Leinwand (celeste_set_canvas), auf dem Hauptthread nach
    /// runInit und vor der Freigabe des Render-Threads, also ohne laufenden Tick.
    @MainActor static func attachCanvasToGame() -> Bool {
        guard let texture = canvasTexture else {
            c64Record("[c64-canvas] keine Leinwandtextur für celeste_set_canvas")
            return false
        }
        let rc = celeste_set_canvas(Unmanaged.passUnretained(texture).toOpaque(), Int32(texture.width), Int32(texture.height))
        if rc != 0 {
            let error = celeste_last_error().map { String(cString: $0) } ?? ""
            c64Record("[c64-canvas] celeste_set_canvas rc=\(rc) error=\"\(error)\"")
            return false
        }
        c64Record("[c64-canvas] celeste_set_canvas rc=0: Celestes Endbild geht in die Leinwand \(texture.width)x\(texture.height)")
        return true
    }

    /// Farbvergleich mit dem Mac: die Leinwand einmal zurücklesen (Blit auf der gemeinsamen
    /// Queue, nach Celestes Commits), mittlere Farbe loggen und als PNG und RGBA-Rohdaten in
    /// Documents ablegen (c64-canvas-<Gerät>.png/.rgba; scripts/compare-canvas.py vergleicht
    /// mit dem Bild aus mac-check). Blockiert den rufenden Thread bis zum Ende des Blits.
    static func writeCanvasSnapshot(queue: MTLCommandQueue, texture: MTLTexture, label: String) {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        guard let buffer = queue.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            c64Record("[c64-canvas] snapshot \(label): Blit nicht möglich")
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

    // MARK: Auflösung und Linienbreite (M4a.4)

    /// Interne Auflösung des Spiels, Umrissbreite und Leinwandgrösse aus C64_RES und C64_LINE.
    ///   C64_RES=640x360|1280x720|1920x1080|2560x1440|native   Standard 1920x1080 (vorläufig).
    ///       native: Tabelle je Gerät (hw.machine) aus der Map-Messung ([c64-native]); solange
    ///       sie leer ist, 1920x1080 mit Logzeile.
    ///   C64_LINE=1|2|3|4|auto                                  Standard auto = round(Höhe/360).
    /// Ungültige Werte: Fehlerzeile im Log, dann der Standard. Die Leinwand hat die interne
    /// Auflösung, ausser bei 640x360 (1280x720 wie bisher); die Winkelbreite bleibt C64_CANVAS_FOV.
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
    /// «nativ» je Gerät aus der Messung [c64-native]; wird in M4a.4c gefüllt.
    static let nativeResolutions: [String: (Int, Int)] = [:]

    static let settings: GameSettings = {
        let environment = ProcessInfo.processInfo.environment
        let resText = environment["C64_RES"] ?? ""
        var resolution = defaultResolution
        var resNote = resText.isEmpty ? "unset" : resText
        if resText.isEmpty {
            // Standard
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
            c64Record("[c64-res] error: C64_RES=\"\(resText)\" unbekannt (640x360, 1280x720, 1920x1080, 2560x1440, native), Standard \(defaultResolution.0)x\(defaultResolution.1)")
        }
        let lineText = environment["C64_LINE"] ?? ""
        let autoLine = max(1, min(4, Int((Double(resolution.1) / 360).rounded())))
        var line = autoLine
        if lineText.isEmpty || lineText == "auto" {
            // Standard auto
        } else if let value = Int(lineText), (1...4).contains(value) {
            line = value
        } else {
            c64Record("[c64-res] error: C64_LINE=\"\(lineText)\" ungültig (1, 2, 3, 4, auto), Standard auto=\(autoLine)")
        }
        let result = GameSettings(internalWidth: resolution.0, internalHeight: resolution.1, edgeLineWidth: line)
        c64Record("[c64-res] C64_RES=\(resNote) -> internal=\(result.internalWidth)x\(result.internalHeight) canvas=\(result.canvasWidth)x\(result.canvasHeight) C64_LINE=\(lineText.isEmpty ? "unset" : lineText) -> line=\(line) (auto=\(autoLine))")
        return result
    }()

    // MARK: Leinwand (M4a)

    static var canvasWidth: Int { settings.canvasWidth }
    static var canvasHeight: Int { settings.canvasHeight }

    /// Winkelbreite der Leinwand in Grad (C64_CANVAS_FOV, Standard 50).
    static var canvasFovDegrees: Float {
        Float(ProcessInfo.processInfo.environment["C64_CANVAS_FOV"] ?? "") ?? 50
    }

    /// C64_CANVAS_FILTER=nearest für den Pixel-Look, sonst linear.
    static var canvasNearest: Bool {
        ProcessInfo.processInfo.environment["C64_CANVAS_FILTER"] == "nearest"
    }

    /// M4b.2: Tiefenkonvention des VR-Pfads (Reverse-Z, unendliche Far-Ebene, Shader ohne
    /// SV_Depth) in Celeste; Standard an, C64_REVERSE_Z=0 schaltet auf Celestes eigene
    /// Konvention (Referenzpfad). Die Near-Ebene liefert der Renderer aus der Layer-Konfiguration
    /// (celeste_set_depth_near), bevor der erste Tick auf dem Render-Thread läuft.
    static var reverseZ: Bool {
        ProcessInfo.processInfo.environment["C64_REVERSE_Z"] != "0"
    }

    /// Die Leinwandtextur des Hosts; der Renderer übernimmt sie beim Start des ImmersiveSpace.
    @MainActor static var canvasTexture: MTLTexture?

    /// Device und Queue des Hosts, einmal angelegt: dieselbe Queue bekommt celeste_init (SDL
    /// committet darauf) und der Renderer (Gerüst-Buffer), damit Command Buffer in
    /// Commit-Reihenfolge laufen und Celestes Bild fertig ist, bevor der Leinwand-Pass es liest.
    @MainActor static func ensureHostDevice() -> Bool {
        if device != nil, commandQueue != nil { return true }
        guard let mtlDevice = MTLCreateSystemDefaultDevice(), let queue = mtlDevice.makeCommandQueue() else {
            c64Record("[c64-celeste] kein MTLDevice oder keine Queue")
            return false
        }
        queue.label = "c64-celeste-queue"
        device = mtlDevice
        commandQueue = queue
        c64Record("[c64-celeste] host device=\(Unmanaged.passUnretained(mtlDevice).toOpaque()) name=\"\(mtlDevice.name)\" queue=\"c64-celeste-queue\"")
        return true
    }

    /// M4a.2: Leinwandtextur anlegen (privat, RenderTarget | ShaderRead | PixelFormatView, wie
    /// sie Celeste in M4a.3 beschreibt) und einmal über einen Staging-Puffer auf der gemeinsamen
    /// Queue füllen. Muster: Verlauf (rot nach rechts, grün nach unten, blau 64), weisses Gitter
    /// alle 128 Pixel, gelbe Markierung 160×90 oben links, blaue 80×45 unten rechts, schwarzer
    /// Rand von 4 Pixeln. Grösse aus den Einstellungen (M4a.4: interne Auflösung des Spiels).
    @MainActor static func prepareCanvas() -> Bool {
        guard ensureHostDevice(), let device, let queue = commandQueue else { return false }
        if canvasTexture != nil { return true }
        let width = canvasWidth, height = canvasHeight
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            c64Record("[c64-canvas] Leinwandtextur konnte nicht angelegt werden")
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
                if x < 160, y < 90 { r = 255; g = 220; b = 0 }                           // Markierung oben links
                if x >= width - 80, y >= height - 45 { r = 40; g = 90; b = 255 }         // Markierung unten rechts
                if x < 4 || y < 4 || x >= width - 4 || y >= height - 4 { r = 0; g = 0; b = 0 }
                let i = (y * width + x) * 4
                pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
            }
        }
        guard let staging = device.makeBuffer(bytes: pixels, length: pixels.count, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            c64Record("[c64-canvas] Staging oder Blit nicht möglich")
            return false
        }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: width * 4, sourceBytesPerImage: pixels.count,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        canvasTexture = texture
        c64Record("[c64-canvas] Leinwandtextur \(width)x\(height) rgba8Unorm usage=0x\(String(texture.usage.rawValue, radix: 16)) hazard=\(texture.hazardTrackingMode.rawValue) gefüllt (status=\(commandBuffer.status.rawValue)) fov=\(canvasFovDegrees)° filter=\(canvasNearest ? "nearest" : "linear")")
        return true
    }

    /// M1a.5: Zustand des Tickens auf dem Render-Thread. Der Hauptthread gibt nach init und Laden
    /// frei (markReady), der Render-Thread tickt. Alle Felder hinter einem Lock, und dasselbe Lock
    /// umschliesst jeden celeste_tick, damit nie zwei Ticks gleichzeitig laufen (der Hauptthread
    /// tickt in runInit synchron vor der Freigabe, der Render-Thread entsteht erst mit dem
    /// ImmersiveSpace; das Lock ist die Absicherung, nicht der Plan).
    nonisolated final class TickState: @unchecked Sendable {
        private let lock = NSLock()
        private var ready = false
        private var stopped = false
        private var firstLogged = false
        private var totalTicks = 0
        private var totalFrames = 0
        // Fenster von einer Sekunde
        private var windowStart: CFAbsoluteTime = 0
        private var windowFrames = 0
        private var windowTicks = 0
        private var deltaSum = 0.0
        private var deltaMax = 0.0
        // M4b.1: Update und Render getrennt gemessen (CPU, Render-Thread).
        private var updateMsSum = 0.0
        private var updateMsMax = 0.0
        private var renderMsSum = 0.0
        private var renderMsMax = 0.0
        private var windowRenders = 0
        private var updatePending = false
        // M4a.3: Leinwand und Queue für das einmalige Rücklesen nach snapshotAtTicks Ticks.
        private var snapshotQueue: MTLCommandQueue?
        private var snapshotTexture: MTLTexture?
        private var snapshotDone = false
        static let snapshotAtTicks = 600

        var isActive: Bool { lock.withLock { ready && !stopped } }

        func markReady(snapshotQueue: MTLCommandQueue? = nil, snapshotTexture: MTLTexture? = nil) {
            lock.withLock {
                ready = true
                self.snapshotQueue = snapshotQueue
                self.snapshotTexture = snapshotTexture
            }
            c64Record("[c64-celeste] tick ready: Ticks laufen im Render-Thread, sobald der ImmersiveSpace offen ist\(snapshotTexture != nil ? "; Leinwand-Rücklesen nach \(Self.snapshotAtTicks) Ticks" : "")")
        }

        /// Ein Tick pro Compositor-Frame. frameInterval: Wanduhr-Intervall zwischen den Rückkehren
        /// von queryNextFrame (Takt des Compositors, am Render-Thread gemessen), nil beim ersten
        /// Frame nach Start oder Pause; dann 1/90 s. Meldet der Tick rc=1 («Exit» im Spiel),
        /// läuft requestExit erst nach dem Verlassen des Locks: es ruft stop, das denselben
        /// (nicht rekursiven) NSLock nimmt; innerhalb von tick wäre das ein Deadlock des
        /// Render-Threads (gemessen M4a.5a auf der M5: keine Zeile nach «requested», das
        /// System beendete die App nach dem blockierten Render-Thread).
        /// M4b.1: die Update-Hälfte (celeste_update) in der Update-Phase des Frames; liefert
        /// true, wenn das Update lief (dann folgt render() im selben Frame).
        @discardableResult
        func update(frameInterval: TimeInterval?) -> Bool {
            let (ran, reason) = updateLocked(frameInterval: frameInterval)
            if let reason {
                CelesteProbe.requestExit(reason: reason)
            }
            return ran
        }

        /// Das Update unter dem Lock; gibt zurück, ob es lief, und den Grund für ein Ende.
        private func updateLocked(frameInterval: TimeInterval?) -> (Bool, String?) {
            lock.lock()
            defer { lock.unlock() }
            guard ready, !stopped else { return (false, nil) }
            let delta = min(max(frameInterval ?? CelesteProbe.tickDelta, 0.001), 1.0 / 30.0)
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
                c64Record("[c64-celeste] update rc=-1 after \(totalTicks) ticks, ticking stopped: \"\(error)\"")
                stopped = true
                return (false, nil)
            }
            totalTicks += 1
            windowTicks += 1
            if rc == 1 {
                // «Exit» im Titel: dasselbe saubere Ende wie bei der Digital Crown (M4a.5a);
                // stopped hier unter dem Lock, requestExit danach ausserhalb (siehe update).
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

        /// M4b.1: die Render-Hälfte (celeste_render_frame, present 0) nach dem Device Anchor,
        /// unmittelbar vor dem Encodieren des Host-Buffers; Celestes SDL-Buffer committen so
        /// vor dem Host-Buffer auf derselben Queue. Nur nach einem Update im selben Frame.
        func render() {
            lock.lock()
            defer { lock.unlock() }
            guard ready, !stopped, updatePending else { return }
            updatePending = false
            let start = DispatchTime.now()
            let rc = celeste_render_frame(0)
            let renderMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            if rc == -1 {
                let error = celeste_last_error().map { String(cString: $0) } ?? ""
                c64Record("[c64-celeste] render rc=-1 after \(totalTicks) ticks, ticking stopped: \"\(error)\"")
                stopped = true
                return
            }
            windowRenders += 1
            renderMsSum += renderMs
            renderMsMax = max(renderMsMax, renderMs)
            if !snapshotDone, totalTicks >= Self.snapshotAtTicks, let queue = snapshotQueue, let texture = snapshotTexture {
                snapshotDone = true
                CelesteProbe.writeCanvasSnapshot(queue: queue, texture: texture, label: "tick\(totalTicks)")
            }
        }

        /// Statistik einmal pro Sekunde (unter dem Lock): Frames, Updates, Renders, Delta,
        /// Update- und Render-CPU-Zeit, GPU-Zeit von Celestes Buffern.
        private func logStatsIfDue(now: CFAbsoluteTime) {
            let elapsed = now - windowStart
            guard elapsed >= 1.0, windowFrames > 0 else { return }
            let updatesPerFrame = Double(windowTicks) / Double(windowFrames)
            let gpu = CelesteProbe.celesteGpu.take()
            let renders = max(windowRenders, 1)
            c64Record(String(format: "[c64-celeste] tick-stats frames=%d ticks=%d renders=%d updatesPerFrame=%.2f compositor=%.1f Hz delta(ms) mean=%.2f max=%.2f update(ms) mean=%.2f max=%.2f render(ms) mean=%.2f max=%.2f celesteGpu(ms) mean=%.3f max=%.3f n=%d total=%d",
                             windowFrames, windowTicks, windowRenders, updatesPerFrame, Double(windowFrames) / elapsed,
                             deltaSum / Double(windowTicks) * 1000, deltaMax * 1000,
                             updateMsSum / Double(windowTicks), updateMsMax,
                             renderMsSum / Double(renders), renderMsMax,
                             gpu.mean * 1000, gpu.max * 1000, gpu.count, totalTicks))
            windowStart = now
            windowFrames = 0
            windowTicks = 0
            windowRenders = 0
            deltaSum = 0
            deltaMax = 0
            updateMsSum = 0
            updateMsMax = 0
            renderMsSum = 0
            renderMsMax = 0
        }

        /// Pause oder Ende der Renderschleife: die Ticks setzen aus, das Spiel bleibt (kein
        /// celeste_end); nach dem Wiederöffnen beginnt das Fenster der Statistik neu.
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

        /// Endgültiges Ende der Ticks (M4a.5a): kein Tick mehr, auch nicht nach einem Resume; der
        /// nächste Schritt ist celeste_end auf dem Hauptthread. Wartet, falls gerade ein Tick
        /// läuft (dasselbe Lock), damit celeste_end nie neben celeste_tick läuft.
        func stop(reason: String) {
            lock.lock()
            defer { lock.unlock() }
            let already = stopped
            stopped = true
            c64Record("[c64-celeste] tick stopped reason=\"\(reason)\" alreadyStopped=\(already ? 1 : 0) totalTicks=\(totalTicks) totalFrames=\(totalFrames)")
        }
    }

    static let tickState = TickState()

    // MARK: Sauberes Ende (M4a.5a)

    private static let exitLock = NSLock()
    private static var exitRequested = false
    private static var exitCalled = false

    /// Beendet die App sauber: Ticks endgültig stoppen, auf dem Hauptthread (SDLs Hauptthread,
    /// der Thread von celeste_init) celeste_end (Foster End → Celestes Shutdown → FMOD release;
    /// Dispose → SDL_Quit), dann exit(0). Jede Logzeile ist mit fsync geschrieben, bevor der
    /// nächste Schritt läuft (ProbeLog). Wächter: dauert das Ende länger als eine Sekunde,
    /// beendet ein zweiter Thread trotzdem, mit Logzeile; er startet als erster Schritt, vor
    /// allem, was blockieren kann (stop nimmt das Tick-Lock, celeste_end läuft auf dem
    /// Hauptthread). Aufrufbar von jedem Thread, aber nicht unter dem Tick-Lock; der erste
    /// Aufruf gewinnt. Auslöser: Layer invalidiert (Digital Crown, Raum geschlossen) und ein Tick
    /// mit rc=1 («Exit» im Titel).
    nonisolated static func requestExit(reason: String) {
        let first = exitLock.withLock { () -> Bool in
            if exitRequested { return false }
            exitRequested = true
            return true
        }
        guard first else { return }
        let requestedAt = DispatchTime.now()

        // Wächter zuerst: nach einer Sekunde ohne Ende trotzdem beenden.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
            exitOnce(line: "[c64-exit] shutdown exceeds 1 s, exiting anyway")
        }

        c64Record("[c64-exit] requested reason=\"\(reason)\" thread=\(Thread.current.name ?? "?") isMainThread=\(Thread.isMainThread)")
        tickState.stop(reason: reason)

        // M4a.5c-2: Bei angehaltenem Mixer (Crown im Hintergrund) kein celeste_end. Game.End
        // ruft Audio.Shutdown (system.release) und World.Disposed (SetPaused, Busse), beides
        // FMOD; FMOD verbietet jeden Aufruf nach mixerSuspend ausser mixerResume, «even if you
        // intend to shutdown FMOD as you may cause a deadlock» (platforms-android.html; iOS-Seite:
        // keine FMOD-APIs zwischen Suspend und Resume). mixerResume geht im Hintergrund nicht
        // (Session nicht aktivierbar). Der Prozess endet ohnehin; gespeichert wird nur bei
        // Save & Quit, nichts geht verloren.
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

    /// exit(0) genau einmal; die letzte Logzeile ist vor dem Aufruf mit fsync geschrieben.
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

    /// Modus aus C64_CELESTE; ohne Schalter der Standard des Produkts, play (M4a.5b). Mit einem
    /// Kit-Modus (C64_KIT) und ohne C64_CELESTE bleibt Celeste aus, zwei SDL_GPU-Devices auf
    /// demselben MTLDevice sind nicht sinnvoll. Ein unbekannter Wert gibt eine Fehlerzeile und play.
    static var mode: Mode {
        let text = ProcessInfo.processInfo.environment[environmentKey] ?? ""
        if text.isEmpty {
            return KitProbe.mode == nil ? .play : .off
        }
        if let mode = Mode(rawValue: text) { return mode }
        c64Record("[c64-celeste] error: C64_CELESTE=\"\(text)\" unbekannt (off, probe, init, window, tick, canvas, play), Standard play")
        return .play
    }

    static var isRequested: Bool { mode != .off }

    /// Anzahl Ticks auf dem Hauptthread in M1a.4: Celeste lädt im fünften Update (loadDelay 5),
    /// drei weitere zeigen, dass der Übergang zum Titel ohne Fehler beginnt.
    static let initTicks = 8
    static let tickDelta = 1.0 / 90.0

    /// Bundle-ID des Wrapper-Frameworks (scripts/build-game.sh, GAME_BUNDLE_ID).
    static let celesteFrameworkIdentifier = "com.lowriderxr.Celeste64.VisionOS"

    /// Ergebnis für die Statuszeile des Fensters.
    struct Result {
        var version: String
        var capabilitiesLine: String
        var ok: Bool
    }

    /// Device und Queue des Hosts für celeste_init; der Host bleibt Besitzer, die Zeiger gehen
    /// unretained an den Wrapper (SDL_GPU-Kit, P1).
    @MainActor static var device: MTLDevice?
    @MainActor static var commandQueue: MTLCommandQueue?

    /// Logzeilen des Spiels (Foster, Celeste, SDL über Foster) ins Unified Log und in die Datei.
    static let logLine: celeste_log_fn = { level, utf8, _ in
        guard let utf8 else { return }
        let kind = level == 2 ? "error" : (level == 1 ? "warn" : "info")
        c64Record("[c64-celeste] game(\(kind)) \(String(cString: utf8))")
    }

    /// M1a.2: Version und Fähigkeiten vor celeste_init. Jede Zeile geht ins Unified Log und in
    /// die Fortschrittsdatei ([c64-celeste]).
    static func runProbe() -> Result {
        let start = DispatchTime.now()

        let version: String
        if let cString = celeste_version() {
            version = String(cString: cString)
        } else {
            version = "(celeste_version lieferte NULL)"
        }
        let versionMs = elapsedMs(since: start)
        c64Record("[c64-celeste] step=version thread=\(Thread.isMainThread ? "main" : "other") version=\"\(version)\" ms=\(format(versionMs))")

        let (rc, line) = capabilities(label: "before-init")
        c64Record("[c64-celeste] step=done totalMs=\(format(elapsedMs(since: start)))")

        return Result(version: version, capabilitiesLine: line, ok: rc == 0)
    }

    /// M1a.4: Probe, dann celeste_init mit verstecktem Fenster und den nötigen Ticks auf dem
    /// Hauptthread. Liefert die Fähigkeiten nach init in der Statuszeile.
    @MainActor static func runInit(since probeStart: DispatchTime) -> Result {
        var result = runProbe()
        let start = DispatchTime.now()

        // Content-Root: das eingebettete Celeste64.VisionOS.framework; scripts/build-game.sh legt
        // den Ordner Content hinein (Weg 3 der M1a.4-Analyse: ein Ordner im Framework behält seine
        // Struktur, ein synchronisierter Xcode-Ordner würde die Dateien flach ins Bundle legen).
        let frameworkBundle = Bundle(identifier: celesteFrameworkIdentifier)
            ?? Bundle.main.privateFrameworksPath.flatMap { Bundle(path: ($0 as NSString).appendingPathComponent("Celeste64.VisionOS.framework")) }
        guard let contentRoot = frameworkBundle?.bundlePath else {
            c64Record("[c64-celeste] step=init skipped: Celeste64.VisionOS.framework nicht gefunden (Bundle-ID \(celesteFrameworkIdentifier), privateFrameworksPath \(Bundle.main.privateFrameworksPath ?? "nil"))")
            result.ok = false
            result.capabilitiesLine = "Framework nicht gefunden"
            return result
        }
        let contentDir = (contentRoot as NSString).appendingPathComponent("Content")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: contentDir, isDirectory: &isDirectory), isDirectory.boolValue else {
            c64Record("[c64-celeste] step=init skipped: kein Ordner Content in \(contentRoot); scripts/build-game.sh neu laufen lassen (es kopiert Source/Celeste64/Content ins Framework)")
            result.ok = false
            result.capabilitiesLine = "Content fehlt im Framework"
            return result
        }
        let contentFiles = (FileManager.default.enumerator(atPath: contentDir)?.allObjects.count) ?? 0
        c64Record("[c64-celeste] step=content root=\"\(contentRoot)\" entries=\(contentFiles)")

        // Device und Queue des Hosts; der Renderer übernimmt dieselbe Queue (M4a.2).
        guard ensureHostDevice(), let mtlDevice = device, let queue = commandQueue else {
            c64Record("[c64-celeste] step=init skipped: kein MTLDevice oder keine Queue")
            result.ok = false
            return result
        }

        // Logzeilen des Spiels ab jetzt über den Rückruf (Foster schreibt dann nicht mehr auf stdout).
        let logRc = celeste_set_log_callback(logLine, nil)
        c64Record("[c64-celeste] step=log-callback rc=\(logRc)")

        windowSnapshot("before-init", since: probeStart)
        let availableBefore = ProbeContext.availableMemoryMB
        let footprintBefore = ProbeContext.physFootprintMB
        c64Record("[c64-celeste] memory before-init availableMB=\(format(availableBefore)) footprintMB=\(format(footprintBefore))")

        var options = celeste_init_options()
        options.size = Int32(MemoryLayout<celeste_init_options>.size)
        options.hidden_window = 1
        options.depth_clip = 0      // Foster schaltet Depth Clip auf visionOS selbst ein
        options.metal_device = Unmanaged.passUnretained(mtlDevice).toOpaque()
        options.metal_command_queue = Unmanaged.passUnretained(queue).toOpaque()
        // GPU-Zeit von Celestes Command Buffern über den Kit-Rückruf (M4a.3).
        options.completed_callback = unsafeBitCast(celesteCommandBufferCompleted, to: UnsafeMutableRawPointer.self)
        options.completed_userdata = nil
        // Interne Auflösung und Umrissbreite (M4a.4, C64_RES und C64_LINE; der Host löst auto auf).
        options.internal_width = Int32(settings.internalWidth)
        options.internal_height = Int32(settings.internalHeight)
        options.edge_line_width = Int32(settings.edgeLineWidth)
        // Tiefenkonvention des VR-Pfads (M4b.2, C64_REVERSE_Z); Near folgt im Renderer aus dem Layer.
        options.reverse_z = reverseZ ? 1 : 0

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
            c64Record("[c64-celeste] step=init rc=\(initRc) error=\"\(error)\" ms=\(format(initMs))")
            result.ok = false
            result.capabilitiesLine = "celeste_init rc=\(initRc)"
            return result
        }
        windowSnapshot("after-init", since: probeStart)
        sdlWindowInfo("after-init")

        // Ticks auf dem Hauptthread: Startup zählt fünf Updates, dann Assets.Load.
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

    /// Fensterprüfung: alle UIKit-Fensterszenen der App mit Zustand, Grösse und Fenstern. SDL
    /// legt sein (verstecktes) UIWindow in der aktiven Szene an und fragt dort seine logische
    /// Grösse an (SDL_uikitwindow.m, requestGeometryUpdate). `since` ergänzt die Zeit seit dem
    /// Start der Probe in Millisekunden, damit die Modi init und window vergleichbar sind.
    @MainActor static func windowSnapshot(_ label: String, since start: DispatchTime? = nil) {
        let timing = start.map { " tMs=\(format(elapsedMs(since: $0)))" } ?? ""
        // Alle verbundenen Szenen mit Klasse und Rolle (M4a.5b: ohne Fenster gibt es nur die
        // immersive Szene, die keine UIWindowScene ist); Fenster nur bei UIWindowScene.
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

    /// Zahl der UIWindowScenes; 0 heisst, SDLs UIWindow hat keine Szene (Rückfall initWithFrame).
    @MainActor static var windowSceneCount: Int {
        UIApplication.shared.connectedScenes.filter { $0 is UIWindowScene }.count
    }

    /// Audio-Session der App vor celeste_init (M4a.5b-5): Kategorie .playback, aktiv. FMOD
    /// überlässt die Session der App (FMOD-Doku iOS); .playback hängt an keiner Fensterszene,
    /// Vice City brauchte genau das, damit der Ton das Schliessen des 2D-Fensters überlebt.
    @MainActor static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback)
            try session.setActive(true)
            let route = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
            c64Record("[c64-audio] session category=\(session.category.rawValue) active route=[\(route)] sampleRate=\(session.sampleRate)")
        } catch {
            c64Record("[c64-audio] session setCategory/setActive failed: \(error)")
        }
    }

    // MARK: Pause beim Abnehmen (M4a.5c)

    /// App-Zustand für den Render-Thread (M4a.5c-2): der Hauptthread setzt das Hintergrund-Flag
    /// bei willResignActive und didEnterBackground und löscht es bei didBecomeActive, sobald UIKit
    /// die App als active und eine Szene als foregroundActive meldet. Der Layer meldet .paused
    /// erst 150 bis 200 ms nach willResignActive und .running schon lange vor dem Vordergrund
    /// (M2: 8 s vorher); das Flag schliesst beide Lücken. Dazu die Bitte um einen neuen
    /// Ton-Versuch (Audio-Session wieder aktiv, Empfehlung zum Fortsetzen, Media Services Reset).
    nonisolated final class PauseState: @unchecked Sendable {
        private let lock = NSLock()
        private var background = false
        private var audioRetry = false
        private var audioRetryTrigger = ""
        private var mediaReset = false
        private var mixerSuspended = false

        var isBackground: Bool { lock.withLock { background } }

        /// Mixer-Zustand für das Beenden: der Render-Thread setzt ihn nach jedem erfolgreichen
        /// mixerSuspend und mixerResume; requestExit liest ihn (kein FMOD-Aufruf bei angehaltenem
        /// Mixer, auch nicht zum Beenden).
        var isMixerSuspended: Bool { lock.withLock { mixerSuspended } }
        func setMixerSuspended(_ value: Bool) { lock.withLock { mixerSuspended = value } }

        func setBackground(reason: String) {
            let changed = lock.withLock { () -> Bool in
                let was = background
                background = true
                return !was
            }
            c64Record("[c64-pause] tMs=\(LaunchClock.tMs) background=1 reason=\(reason)\(changed ? "" : " (schon gesetzt)")")
            if changed {
                CelesteProbe.AliveProbe.shared.begin()
            }
        }

        /// Löscht das Flag nur, wenn die App wirklich im Vordergrund ist (UIKit); sonst Logzeile.
        @MainActor func clearBackgroundIfForeground(reason: String) {
            let app = UIApplication.shared.applicationState
            let foregroundScene = UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            guard app == .active, foregroundScene else {
                c64Record("[c64-pause] tMs=\(LaunchClock.tMs) background bleibt 1 reason=\(reason) app=\(app == .active ? "active" : (app == .inactive ? "inactive" : "background")) foregroundScene=\(foregroundScene ? 1 : 0)")
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

        /// Render-Thread: Bitte um einen Ton-Versuch abholen (einmalig), dazu ob Media Services
        /// zurückgesetzt wurden (FMOD-Beispiel: dann Suspend und Resume als Paar).
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

    /// Letzte Kopfpose aus dem Device Anchor (Render-Thread schreibt je Frame, Hauptthread liest
    /// bei onWorldRecenter): Position in Metern, Gieren in Grad (positiv nach rechts, 0 = −Z).
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
                guard ageMs >= 0 else { return "head=- yaw=- (noch keine Pose)" }
                return String(format: "head=(%.2f, %.2f, %.2f) yaw=%.1f° poseTMs=%.1f frames=%d", position.x, position.y, position.z, yawDegrees, ageMs, frames)
            }
        }
    }

    static let headPose = HeadPose()

    /// Lebenszeichen-Sonde (M4a.5c-6): ein eigener Thread «c64-alive», geweckt vom Hintergrund-
    /// Flag, schreibt einmal pro Sekunde eine Zeile in die Probe, höchstens 600 je Pause; beim
    /// Fortsetzen eine Zeile mit der Lücke seit dem letzten Lebenszeichen. Ein vom System
    /// suspendierter Prozess zeigt beim Aufwachen eine grosse Lücke, ein wacher (Debugger
    /// angehängt) lückenlose Sekunden. Ruft weder FMOD noch Metal noch CompositorServices;
    /// nimmt nur den eigenen Lock. Layer- und Provider-Zustand kommen als Texte von aussen
    /// (Renderer setzt sie), damit die Sonde keinen fremden Lock braucht.
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

        /// Renderer: Lesefunktion für den Layer-Zustand (cp_layer_renderer_get_state, ohne Lock).
        func setLayerStateReader(_ reader: @escaping () -> String) {
            condition.lock(); readLayerState = reader; condition.unlock()
        }

        /// Renderer, bei jeder Zustandsänderung des WorldTrackingProviders.
        func setProviderState(_ text: String) {
            condition.lock(); providerStateText = text; condition.unlock()
        }

        /// Hauptthread, beim Setzen des Hintergrund-Flags.
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

        /// Render-Thread, bei «Fortsetzen»: Lücke seit dem letzten Lebenszeichen.
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
                c64Record(String(format: "[c64-alive] tMs=%.1f gap=- beats=0 (kein Lebenszeichen in dieser Pause)", resumeMs))
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
                    // Grenze erreicht: bis zum Ende der Pause schlafen (kein weiteres Zeichen).
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

    /// FMOD-Mixer anhalten oder weiterlaufen lassen (celeste_audio_suspend); vom Render-Thread,
    /// beide Aufrufe auf demselben Thread ohne Tick dazwischen (FMOD-Doku iOS). Nur mit Spiel.
    /// Liefert true bei FMOD_OK.
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

    /// Audio-Session nach einer Pause wieder aktivieren, bevor FMODs Mixer weiterläuft (das
    /// System deaktiviert die Session, wenn es den Prozess suspendiert). Liefert true bei Erfolg;
    /// FMODs Beispiel (common_platform.mm:211-227) ruft bei einem Fehler nicht mixerResume,
    /// sondern wartet auf das nächste Signal.
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

    /// Pause-Anfrage ans Spiel (celeste_request_pause); Game.Update öffnet das Pausenmenü eines
    /// laufenden Levels und loggt [c64-pause] applied=.
    nonisolated static func requestPause() {
        guard tickState.isActive else { return }
        let rc = celeste_request_pause()
        c64Record("[c64-audio] tMs=\(LaunchClock.tMs) pause requested rc=\(rc)")
    }

    /// Beobachter für Lebenszyklus- und Audio-Signale (nur Log): UIKit-Benachrichtigungen,
    /// AVAudioSession-Unterbrechungen mit Typ, Grund, wasSuspended und shouldResume, Media
    /// Services Reset. Bei .ended wird die Session wieder aktiviert (geloggt).
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
                        // M4a.5c-2: Hintergrund-Flag für den Render-Thread.
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
            // visionOS 27 ersetzt interruptionNotification durch didBecomeInactive (mit
            // DeactivationContext: Quelle, Unterbrechungsgrund) und resumptionRecommendation
            // (shouldResume oder shouldNotResume); didBecomeActive meldet die Aktivierung.
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
                    // Der Render-Thread versucht setActive und mixerResume (gleicher Thread wie
                    // das Suspend), sobald er läuft.
                    CelesteProbe.pauseState.requestAudioRetry(trigger: "resumptionRecommendation")
                }
            })
            tokens.append(center.addObserver(forName: AVAudioSession.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                c64Record("[c64-life] tMs=\(LaunchClock.tMs) AVAudioSession didBecomeActive")
                CelesteProbe.pauseState.requestAudioRetry(trigger: "session didBecomeActive")
            })
            tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
                // FMOD-Beispiel common_platform.mm:184-197: im Vordergrund Suspend und Resume als
                // Paar, im Hintergrund beim nächsten Fortsetzen; hier übernimmt der Render-Thread.
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

    /// Lebenszyklus in einer Zeile (nur Log, M4a.5b-4): App-Zustand aus UIKit und Zustand jeder
    /// verbundenen Szene mit Rolle. Der Stil der Immersion ist für eine CompositorServices-Szene
    /// nicht auslesbar (kein öffentliches API an UIScene, onImmersionChange nur an Views).
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

    /// Fosters Fenster aus SDLs Sicht: die logische Grösse ist die Grösse, die SDL beim Anlegen
    /// per Geometrieanfrage an die Szene schickt (Punkte); Pixel und Dichte zeigen, was Foster
    /// und Celeste als Backbuffer sehen.
    @MainActor static func sdlWindowInfo(_ label: String) {
        var info = celeste_window_info()
        info.size = Int32(MemoryLayout<celeste_window_info>.size)
        let rc = celeste_window_info_get(&info)
        if rc == 0 {
            // scene: 1, wenn eine UIWindowScene existiert (SDL hängt sein Fenster daran), sonst 0
            // (SDL_uikitwindow.m: Rückfall initWithFrame ohne Szene).
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

//
//  KitProbe.swift
//  AvpCeleste64
//
//  Schalter C64_KIT (Standard aus):
//    C64_KIT=1          Stufe K0: SDL_GPU-Testszene einmal beim Start im Hauptthread, SDL erzeugt
//                       Device und Queue selbst, am Ende SDL_Quit. Referenz.
//    C64_KIT=inject     Stufe K1a (Baustein P1): SDL_Init im Hauptthread beim Fenster (ohne
//                       SDL_Quit), die Szene läuft dann im Render-Thread des ImmersiveSpace mit dem
//                       Device des Layer-Renderers und der Queue des Gerüsts, einmal vor dem ersten
//                       Frame. Danach läuft die Renderschleife normal weiter; SDL bleibt
//                       initialisiert (SDL_Quit vom Render-Thread wäre auf UIKit nicht sauber).
//    C64_KIT=import     Stufe K1b (Baustein P3): wie inject beim Fenster; im ImmersiveSpace
//                       importiert SDL in jedem Frame Farb- und Tiefentextur des Drawables und
//                       löscht beide Schichten (dunkelblau, Tiefe 0.001); das Gerüst präsentiert.
//    C64_KIT=multiview  Stufe K2 (Baustein P6): wie import, aber ein Pass mit view_count 2 und
//                       ein Draw des Schachbretts (1 m, 1,5 m vor der Startpose, weltfest) für
//                       beide Augen per Vertex Amplification; Shader aus der Kit-Werkzeugkette.
//                       K3: mit C64_FOVEATION=1 geht die Map des Compositors an den Pass (P4).
//                       K4a: C64_KIT_MSAA=<Samples> (Standard aus) rendert in MSAA-Texturen und
//                       löst Farbe und Tiefe in die Drawable-Schichten auf.
//
//  Prüft Risiko R1 (K0), die Besitzregeln von P1 (K1a), den Texturimport P3 (K1b) und Multiview
//  P6 (K2) aus Docs/celeste64/sdl-gpu-kit-analyse.md. Jede Zeile der Szene geht ins Unified Log
//  und in die Fortschrittsdatei.
//
//  Thread-Belege (SDL main 4cfdb71ee): SDL_Init(VIDEO) läuft über UIKit_VideoInit
//  (SDL_uikitvideo.m:153) und gehört auf den Hauptthread; SDL_CreateGPUDevice und
//  SDL_DestroyGPUDevice prüfen keinen Thread (SDL_gpu.c, SDL_gpu_metal.m ohne SDL_IsMainThread).
//

import Foundation
import Metal
import os
import simd

nonisolated enum KitProbe {
    static let environmentKey = "C64_KIT"

    enum Mode: String {
        case basic = "1"
        case inject = "inject"
        case `import` = "import"
        case multiview = "multiview"
    }

    static var mode: Mode? {
        Mode(rawValue: ProcessInfo.processInfo.environment[environmentKey] ?? "")
    }

    static var isRequested: Bool { mode != nil }

    private static var debugRequested: Bool {
        ProcessInfo.processInfo.environment["C64_KIT_DEBUG"] == "1"
    }

    /// C-Callback ohne Kontext: schreibt jede Zeile der Szene ins Log und in die Datei.
    static let logLine: kit_log_fn = { line, _ in
        guard let line else { return }
        c64Record(String(cString: line))
    }

    /// Unretained Zeiger auf ein Metal-Objekt für die C-Seite; der Host bleibt Besitzer.
    static func pointer(_ object: AnyObject) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(object).toOpaque()
    }

    /// K0: alles im Hauptthread, SDL erzeugt Device und Queue selbst.
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

    /// K1a/K1b/K2, Teil 1 (Hauptthread, beim Fenster): nur SDL_SetMainReady + SDL_Init(VIDEO).
    @MainActor
    @discardableResult
    static func initSDL(for mode: Mode) -> Bool {
        c64Record("[c64-kit] start mode=\(mode.rawValue) thread=main step=init-only")
        return kit_testscene_init_sdl(logLine, nil)
    }

    /// K1a, Teil 2 (Render-Thread, vor dem ersten Frame): Szene mit Device und Queue des Hosts.
    /// Die Zeiger gehen unretained an C; SDL hält während der Szene eine eigene Referenz und gibt
    /// sie in SDL_DestroyGPUDevice ab. Der Host bleibt Besitzer.
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

    // MARK: K1b Import

    /// K1b: Import-Sitzung auf Device und Queue des Hosts (SDL_GPU-Device lebt bis `endImport`).
    /// Diagnose-Schalter: C64_KIT_WAIT=1 (auf SDLs Fence warten, bevor das Gerüst committet),
    /// C64_KIT_VERIFY=1 (alle 90 Frames den Mittelpixel der importierten Farbtextur zurücklesen).
    static func beginImport(device: MTLDevice, queue: MTLCommandQueue) -> OpaquePointer? {
        let environment = ProcessInfo.processInfo.environment
        let wait = environment["C64_KIT_WAIT"] == "1"
        let verify = environment["C64_KIT_VERIFY"] == "1"
        c64Record("[c64-kit] start mode=import thread=\(Thread.current.name ?? "?") device=\"\(device.name)\" queue=\"\(queue.label ?? "-")\" C64_KIT_WAIT=\(wait) C64_KIT_VERIFY=\(verify)")
        guard let session = kit_import_begin(pointer(device as AnyObject), pointer(queue as AnyObject), logLine, nil) else {
            return nil
        }
        if wait || verify {
            kit_import_set_diagnostics(session, wait, verify ? 90 : 0)
        }
        return session
    }

    /// K1b: Farb- und Tiefentextur eines Frames importieren und alle Schichten löschen.
    static func importClear(session: OpaquePointer, color: MTLTexture, depth: MTLTexture,
                            rgba: (Float, Float, Float, Float), depthValue: Float) -> Bool {
        var components: [Float] = [rgba.0, rgba.1, rgba.2, rgba.3]
        return kit_import_clear_frame(session, pointer(color as AnyObject), pointer(depth as AnyObject),
                                      &components, depthValue)
    }

    /// K1b-Diagnose: Pixel, den SDL in diesem Frame nach seinem Clear zurückgelesen hat (b,g,r,a).
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

    // MARK: K2 Multiview

    /// K2: Sitzung mit Shadern und Pipeline (view_count 2) auf Device und Queue des Hosts.
    /// K4a: `msaaSamples` > 1 schaltet Kantenglättung ein (C64_KIT_MSAA); die Sitzung rendert dann
    /// in eigene MSAA-Texturen in Drawable-Grösse und löst Farbe und Tiefe (Filter max, Reverse-Z:
    /// nächste Fläche) in die Drawable-Schichten auf. 0 = Stand K3.
    /// K4b: `memoryless` legt die MSAA-Ziele (und die MSAA-Textur des Messbilds) ohne Speicher an
    /// (C64_KIT_MEMORYLESS=1); Farbe und Tiefe werden nur aufgelöst, nie geladen oder gespeichert.
    static func beginMultiview(device: MTLDevice, queue: MTLCommandQueue, msaaSamples: Int = 0, memoryless: Bool = false) -> OpaquePointer? {
        c64Record("[c64-kit] start mode=multiview thread=\(Thread.current.name ?? "?") device=\"\(device.name)\" queue=\"\(queue.label ?? "-")\" msaa=\(msaaSamples) memoryless=\(memoryless)")
        var options = kit_multiview_options()
        kit_multiview_options_default(&options)
        options.msaa_samples = UInt32(max(0, msaaSamples))
        options.memoryless = memoryless
        return kit_multiview_begin_ex(pointer(device as AnyObject), pointer(queue as AnyObject), &options, logLine, nil)
    }

    /// K2: ein Frame; `viewProjection` pro View (Projektion · inverse(deviceAnchor · view.transform)),
    /// Quad aus center/right/up in Metern. Ohne Quad nur der Clear im Zwei-View-Pass.
    /// K3: `rateMap` ist die Map des Compositors (Foveation an) oder nil.
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

    /// K3: Messbild gegen die Map des Compositors (eigene Float-Textur in physischer Grösse).
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

/// Weltlage des Schachbretts für K2, wie TestScene.place (P0b-2): 1,5 m vor der Pose in
/// horizontaler Blickrichtung, Höhe = Pose, Kante 1 m; während der ersten 90 Frames jeden Frame
/// neu aus der Pose, dann eingefroren, weil die ersten Posen nach dem Öffnen nicht eingeschwungen
/// sind (Kopfhöhe 0,43 m im ersten Frame, Lauf vom 16.10.).
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
            c64Record(String(format: "[c64-kit] step=multiview-quad eingefroren nach %d Frames bei (%.2f, %.2f, %.2f) m, Kopf (%.2f, %.2f, %.2f) m, Blick (%.2f, %.2f, %.2f), Kante %.1f m",
                             placementFrames, center!.x, center!.y, center!.z,
                             position.x, position.y, position.z, forward.x, forward.y, forward.z, Self.halfSize * 2))
        }
    }

    var quad: (center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>)? {
        guard let center else { return nil }
        return (center, right, up)
    }
}

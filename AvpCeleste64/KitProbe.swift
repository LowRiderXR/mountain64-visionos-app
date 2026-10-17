//
//  KitProbe.swift
//  AvpCeleste64
//
//  Schalter C64_KIT (Standard aus):
//    C64_KIT=1       Stufe K0: SDL_GPU-Testszene einmal beim Start im Hauptthread, SDL erzeugt
//                    Device und Queue selbst, am Ende SDL_Quit. Referenz.
//    C64_KIT=inject  Stufe K1a (Baustein P1): SDL_Init im Hauptthread beim Fenster (ohne
//                    SDL_Quit), die Szene läuft dann im Render-Thread des ImmersiveSpace mit dem
//                    Device des Layer-Renderers und der Queue des Gerüsts, einmal vor dem ersten
//                    Frame. Danach läuft die Renderschleife normal weiter; SDL bleibt
//                    initialisiert (SDL_Quit vom Render-Thread wäre auf UIKit nicht sauber).
//
//  Prüft Risiko R1 (K0) und die Besitzregeln von P1 (K1a) aus
//  Docs/celeste64/sdl-gpu-kit-analyse.md. Jede Zeile der Szene geht ins Unified Log und in die
//  Fortschrittsdatei.
//
//  Thread-Belege (SDL main 4cfdb71ee): SDL_Init(VIDEO) läuft über UIKit_VideoInit
//  (SDL_uikitvideo.m:153) und gehört auf den Hauptthread; SDL_CreateGPUDevice und
//  SDL_DestroyGPUDevice prüfen keinen Thread (SDL_gpu.c, SDL_gpu_metal.m ohne SDL_IsMainThread).
//

import Foundation
import Metal
import os

nonisolated enum KitProbe {
    static let environmentKey = "C64_KIT"

    enum Mode: String {
        case basic = "1"
        case inject = "inject"
    }

    static var mode: Mode? {
        Mode(rawValue: ProcessInfo.processInfo.environment[environmentKey] ?? "")
    }

    static var isRequested: Bool { mode != nil }

    private static var debugRequested: Bool {
        ProcessInfo.processInfo.environment["C64_KIT_DEBUG"] == "1"
    }

    /// C-Callback ohne Kontext: schreibt jede Zeile der Szene ins Log und in die Datei.
    private static let logLine: kit_log_fn = { line, _ in
        guard let line else { return }
        c64Record(String(cString: line))
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

    /// K1a, Teil 1 (Hauptthread, beim Fenster): nur SDL_SetMainReady + SDL_Init(VIDEO).
    @MainActor
    @discardableResult
    static func initSDLForInject() -> Bool {
        c64Record("[c64-kit] start mode=inject thread=main step=init-only")
        return kit_testscene_init_sdl(logLine, nil)
    }

    /// K1a, Teil 2 (Render-Thread, vor dem ersten Frame): Szene mit Device und Queue des Hosts.
    /// Die Zeiger gehen unretained an C; SDL hält während der Szene eine eigene Referenz und gibt
    /// sie in SDL_DestroyGPUDevice ab. Der Host bleibt Besitzer.
    @discardableResult
    static func runInject(device: MTLDevice, queue: MTLCommandQueue) -> Int32 {
        let devicePointer = Unmanaged.passUnretained(device as AnyObject).toOpaque()
        let queuePointer = Unmanaged.passUnretained(queue as AnyObject).toOpaque()
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
}

//
//  KitProbe.swift
//  AvpCeleste64
//
//  Kit-Stufe K0, Schalter C64_KIT=1 (Standard aus): führt die SDL_GPU-Testszene aus
//  Kit/sdl-gpu-kit einmal beim Start aus, bevor der ImmersiveSpace geöffnet wird.
//  Prüft Risiko R1 aus Docs/celeste64/port-analyse.md: SDL_Init(VIDEO) und ein
//  SDL_GPU-Device in einer SwiftUI-App auf visionOS, ohne SDL_main.
//
//  Thread: Hauptthread. SDL_Init(SDL_INIT_VIDEO) läuft auf UIKit-Plattformen über
//  UIKit_VideoInit (SDL_uikitvideo.m:153) und legt auf visionOS ein Display ohne UIScreen an
//  (SDL_uikitmodes.m:346-347); die Szene selbst ruft SDL_SetMainReady (SDL.c:345).
//  Jede Zeile der Szene geht ins Unified Log und in die Fortschrittsdatei.
//

import Foundation
import os

nonisolated enum KitProbe {
    static let environmentKey = "C64_KIT"

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    /// Einmal pro Prozess ausführen; Rückgabe ist der gescheiterte Schritt (0 = bestanden).
    @MainActor
    @discardableResult
    static func runOnce() -> Int32 {
        c64Record("[c64-kit] start C64_KIT=1 thread=main debug=\(ProcessInfo.processInfo.environment["C64_KIT_DEBUG"] == "1")")
        var options = kit_testscene_options()
        options.init_sdl = true
        options.debug_mode = ProcessInfo.processInfo.environment["C64_KIT_DEBUG"] == "1"
        options.width = 256
        options.height = 256
        let began = CFAbsoluteTimeGetCurrent()
        let result = kit_testscene_run(&options, { line, _ in
            guard let line else { return }
            c64Record(String(cString: line))
        }, nil)
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        c64Record("[c64-kit] end result=\(result) totalMs=\(String(format: "%.1f", ms))")
        return result
    }
}

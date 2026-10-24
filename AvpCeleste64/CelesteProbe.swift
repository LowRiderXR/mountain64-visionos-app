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

import Foundation
import Metal
import os
import UIKit

nonisolated enum CelesteProbe {
    static let environmentKey = "C64_CELESTE"

    enum Mode: String {
        case probe
        case initialize = "init"
        /// M1a.4b: Vergleichslauf ohne Celeste, nur die Fenster-Schnappschüsse der Szene zu
        /// denselben Zeitpunkten (Start, 0,2 s, 1 s, 2 s). Zeigt, was SwiftUI allein mit dem
        /// Fenster macht (Standardgrösse 1280×720, dann Layout auf die Inhaltsgrösse).
        case window
    }

    static var mode: Mode? {
        Mode(rawValue: ProcessInfo.processInfo.environment[environmentKey] ?? "")
    }

    static var isRequested: Bool { mode != nil }

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

        // Device und Queue des Hosts, wie später der LayerRenderer sie nutzt (Vergleich in M4a).
        guard let mtlDevice = MTLCreateSystemDefaultDevice(), let queue = mtlDevice.makeCommandQueue() else {
            c64Record("[c64-celeste] step=init skipped: kein MTLDevice oder keine Queue")
            result.ok = false
            return result
        }
        queue.label = "c64-celeste-queue"
        device = mtlDevice
        commandQueue = queue

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
        options.completed_callback = nil
        options.completed_userdata = nil

        let initStart = DispatchTime.now()
        let initRc: Int32 = contentRoot.withCString { cRoot in
            options.content_root = cRoot
            return celeste_init(&options)
        }
        let initMs = elapsedMs(since: initStart)
        if initRc == 0 {
            c64Record("[c64-celeste] step=init rc=0 thread=\(Thread.isMainThread ? "main" : "other") contentRoot=\"\(contentRoot)\" ms=\(format(initMs))")
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
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if scenes.isEmpty {
            c64Record("[c64-celeste] window \(label)\(timing) scenes=0")
        }
        for (index, scene) in scenes.enumerated() {
            let bounds = scene.effectiveGeometry.coordinateSpace.bounds.size
            let windows = scene.windows.map { window -> String in
                let root = window.rootViewController.map { String(describing: type(of: $0)) } ?? "-"
                return "\(String(describing: type(of: window))) \(Int(window.frame.width))x\(Int(window.frame.height)) hidden=\(window.isHidden) key=\(window.isKeyWindow) root=\(root)"
            }.joined(separator: " | ")
            c64Record("[c64-celeste] window \(label)\(timing) scene=\(index) role=\(scene.session.role.rawValue) state=\(scene.activationState.rawValue) bounds=\(Int(bounds.width))x\(Int(bounds.height)) windows=\(scene.windows.count) [\(windows)]")
        }
    }

    /// Fosters Fenster aus SDLs Sicht: die logische Grösse ist die Grösse, die SDL beim Anlegen
    /// per Geometrieanfrage an die Szene schickt (Punkte); Pixel und Dichte zeigen, was Foster
    /// und Celeste als Backbuffer sehen.
    static func sdlWindowInfo(_ label: String) {
        var info = celeste_window_info()
        info.size = Int32(MemoryLayout<celeste_window_info>.size)
        let rc = celeste_window_info_get(&info)
        if rc == 0 {
            c64Record("[c64-celeste] sdl-window \(label) requested=\(info.width)x\(info.height) pixels=\(info.pixel_width)x\(info.pixel_height) density=\(Double(info.pixel_density_x1000) / 1000) hidden=\(info.hidden) fullscreen=\(info.fullscreen)")
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

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

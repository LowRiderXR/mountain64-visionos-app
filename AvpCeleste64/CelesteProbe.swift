//
//  CelesteProbe.swift
//  AvpCeleste64
//
//  Schalter C64_CELESTE (Standard aus):
//    C64_CELESTE=probe  Stufe M1a.2: beim Start im Hauptthread celeste_version und
//                       celeste_capabilities_get aus Celeste64.VisionOS.framework aufrufen und
//                       loggen. Kein celeste_init, kein SDL, kein Spiel; die Hülle beweist nur,
//                       dass die Native-AOT-Bibliothek geladen ist und die Fähigkeitsprüfung
//                       vor dem Spiel läuft (Frage: findet NativeLibrary.TryLoad("SDL3") das
//                       eingebettete SDL3.framework, Docs port-analyse.md, «Analyse M1a», Weg a).
//
//  Unabhängig von C64_KIT: beide Schalter dürfen zusammen gesetzt sein, die Kit-Modi laufen
//  unverändert danach.
//

import Foundation
import os

nonisolated enum CelesteProbe {
    static let environmentKey = "C64_CELESTE"

    enum Mode: String {
        case probe
    }

    static var mode: Mode? {
        Mode(rawValue: ProcessInfo.processInfo.environment[environmentKey] ?? "")
    }

    static var isRequested: Bool { mode != nil }

    /// Ergebnis für die Statuszeile des Fensters.
    struct Result {
        var version: String
        var capabilitiesLine: String
        var ok: Bool
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
        c64Record("[c64-celeste] step=version thread=\(Thread.isMainThread ? "main" : "other") version=\"\(version)\" ms=\(String(format: "%.1f", versionMs))")

        var caps = celeste_capabilities()
        caps.size = Int32(MemoryLayout<celeste_capabilities>.size)
        let capsStart = DispatchTime.now()
        let rc = celeste_capabilities_get(&caps)
        let capsMs = elapsedMs(since: capsStart)
        let line = "kitSdlLoaded=\(caps.kit_sdl_loaded) kitExports=\(caps.kit_exports) multiView=\(caps.multi_view) passProperties=\(caps.pass_properties) externalTextures=\(caps.external_textures) memoryless=\(caps.memoryless) depthResolve=\(caps.depth_resolve)"
        if rc == 0 {
            c64Record("[c64-celeste] step=capabilities rc=0 before-init \(line) ms=\(String(format: "%.1f", capsMs))")
        } else {
            let error = celeste_last_error().map { String(cString: $0) } ?? ""
            c64Record("[c64-celeste] step=capabilities rc=\(rc) error=\"\(error)\" ms=\(String(format: "%.1f", capsMs))")
        }
        c64Record("[c64-celeste] step=done totalMs=\(String(format: "%.1f", elapsedMs(since: start)))")

        return Result(version: version, capabilitiesLine: line, ok: rc == 0)
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}

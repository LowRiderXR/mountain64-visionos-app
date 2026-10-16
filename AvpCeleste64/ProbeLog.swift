//
//  ProbeLog.swift
//  AvpCeleste64
//
//  Logger, Startzeile [c64-ctx] und Fortschrittsdatei Documents/c64-probe.txt.
//  Die Datei wird nach jeder Zeile synchronisiert (fsync), damit nach einem Abbruch
//  durch das System sichtbar bleibt, welche Zeile zuletzt geschrieben wurde.
//

import Darwin
import Foundation
import Metal
import os

/// Unified Log, Subsystem der App. In Console.app nach "c64-" filtern.
nonisolated let c64Log = Logger(subsystem: "com.lowriderxr.Mountain64", category: "probe")

/// Fortschrittsdatei im Documents-Ordner der App. Anhängend; jeder Start beginnt mit einer
/// Trennzeile, damit mehrere Läufe nachvollziehbar bleiben.
nonisolated final class ProgressFile: @unchecked Sendable {
    static let shared = ProgressFile()

    static let fileName = "c64-probe.txt"

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    private let lock = NSLock()
    private var fd: Int32 = -1

    private init() {
        let path = Self.url.path
        fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd < 0 {
            c64Log.error("[c64-file] Fortschrittsdatei nicht geöffnet: \(path, privacy: .public) errno=\(errno)")
        }
        write("---- Start \(ISO8601DateFormatter().string(from: Date())) pid=\(getpid())")
    }

    /// Schreibt eine Zeile und synchronisiert sie sofort auf den Datenträger.
    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        let data = Array((line + "\n").utf8)
        data.withUnsafeBufferPointer { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
        fsync(fd)
    }
}

/// Schreibt eine Zeile ins Unified Log und in die Fortschrittsdatei.
nonisolated func c64Record(_ line: String) {
    c64Log.notice("\(line, privacy: .public)")
    ProgressFile.shared.write(line)
}

/// Kontext des Prozesses für die Startzeile: der Zustand wird gelesen, nicht angenommen
/// (Arbeitsweise, Fehlerklasse 2b).
nonisolated enum ProbeContext {
    static var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    static func environment(_ key: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? "-"
    }

    /// Gerätemodell über sysctl hw.machine (etwa "RealityDevice14,1").
    static var hardwareMachine: String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static func name(_ format: MTLPixelFormat) -> String {
        switch format {
        case .bgra8Unorm: return "bgra8Unorm"
        case .bgra8Unorm_srgb: return "bgra8Unorm_srgb"
        case .rgba8Unorm: return "rgba8Unorm"
        case .rgba8Unorm_srgb: return "rgba8Unorm_srgb"
        case .rgba16Float: return "rgba16Float"
        case .depth32Float: return "depth32Float"
        case .depth16Unorm: return "depth16Unorm"
        case .depth32Float_stencil8: return "depth32Float_stencil8"
        case .invalid: return "invalid"
        default: return "raw\(format.rawValue)"
        }
    }

    static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Stall-Sequenz aus der Umgebungsvariablen C64_STALL_SEQ, Millisekunden mit Komma getrennt,
/// Beispiel "500,1000,2000,5000". Nicht gesetzt oder leer: keine Stall-Probe.
nonisolated enum StallPlan {
    static let environmentKey = "C64_STALL_SEQ"

    /// Dauern in Sekunden.
    static func fromEnvironment() -> [TimeInterval] {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey], !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { part in
            guard let ms = Double(part.trimmingCharacters(in: .whitespaces)), ms > 0 else { return nil }
            return ms / 1000.0
        }
    }
}

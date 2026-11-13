//
//  ProbeLog.swift
//  AvpCeleste64
//
//  Probe-Datei und die wenigen Fehlerzeilen für das Unified Log.
//
//  Schalten: Mit der Konfiguration Diagnostics (DIAGNOSTICS) ist die Probe an, sonst aus;
//  C64_PROBE=on|off übersteuert beides. Mit Probe geht jede c64Record-Zeile in die Datei
//  Library/Application Support/c64-probe.txt (der aktuelle Lauf); bei jedem Start rücken die
//  vorigen Läufe zu c64-probe-1.txt bis c64-probe-4.txt, ältere werden gelöscht. Ohne Probe wird
//  keine Datei angelegt und c64Record tut nichts. c64Error geht immer ins Unified Log (und mit
//  Probe in die Datei); sonst schreibt nichts mehr ins Unified Log (In Console.app nach "c64-"
//  filtern zeigt nur Fehler).
//
//  Jede Zeile geht mit einem ungepufferten write() direkt an den Kernel; damit überlebt sie
//  einen SIGKILL (die Daten liegen im Seitencache und werden vom Kernel geschrieben), ohne dass
//  der schreibende Thread auf den Datenträger wartet. M4b L4: das frühere fsync je Zeile lief
//  auf dem Render-Thread und konnte dort Millisekunden kosten; ein verlorener Rest bliebe nur
//  bei einem Kernel-Absturz oder Stromausfall, nicht beim Beenden durch das System.
//

import Darwin
import Foundation
import Metal
import os

/// Umgebung des Prozesses, einmal gelesen: ProcessInfo.environment kopiert bei jedem Zugriff das
/// ganze Wörterbuch; die Schalter des Hosts lesen deshalb alle aus dieser Kopie.
nonisolated enum HostEnvironment {
    static let values: [String: String] = ProcessInfo.processInfo.environment

    static func string(_ key: String) -> String? {
        values[key]
    }

    /// Für die Startzeile: der Wert oder "-".
    static func text(_ key: String) -> String {
        values[key] ?? "-"
    }
}

/// Unified Log, Subsystem der App; nur noch Fehler (c64Error und c64Log.error).
nonisolated let c64Log = Logger(subsystem: "com.lowriderxr.Mountain64", category: "probe")

/// Probe-Datei unter Library/Application Support (nicht in der Files-App sichtbar).
nonisolated final class ProgressFile: @unchecked Sendable {
    static let shared = ProgressFile()

    static let fileName = "c64-probe.txt"
    /// Vorige Läufe, die beim Start behalten werden (c64-probe-1.txt bis c64-probe-4.txt).
    static let keptRuns = 4

    /// Probe an: C64_PROBE=on|off entscheidet; ohne den Schalter die Konfiguration Diagnostics.
    static let enabled: Bool = {
        switch HostEnvironment.string("C64_PROBE") {
        case "on": return true
        case "off": return false
        default:
            #if DIAGNOSTICS
            return true
            #else
            return false
            #endif
        }
    }()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var url: URL {
        directory.appendingPathComponent(fileName)
    }

    private static func rotatedURL(_ index: Int) -> URL {
        directory.appendingPathComponent("c64-probe-\(index).txt")
    }

    private let lock = NSLock()
    private var fd: Int32 = -1
    /// Dateien, die beim Start um eine Stelle gerückt sind (0 beim ersten Lauf).
    private(set) var rotatedRuns = 0

    private init() {
        let fileManager = FileManager.default
        // Alter Ablageort (Documents, in der Files-App sichtbar): beim Start löschen.
        let legacy = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(Self.fileName)
        if fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.removeItem(at: legacy)
        }
        guard Self.enabled else { return }

        try? fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        // Rotation: 4 löschen, 3 -> 4, 2 -> 3, 1 -> 2, aktuell -> 1.
        let oldest = Self.rotatedURL(Self.keptRuns)
        if fileManager.fileExists(atPath: oldest.path) {
            try? fileManager.removeItem(at: oldest)
        }
        for index in stride(from: Self.keptRuns - 1, through: 1, by: -1) {
            let from = Self.rotatedURL(index)
            if fileManager.fileExists(atPath: from.path) {
                try? fileManager.moveItem(at: from, to: Self.rotatedURL(index + 1))
                rotatedRuns += 1
            }
        }
        if fileManager.fileExists(atPath: Self.url.path) {
            try? fileManager.moveItem(at: Self.url, to: Self.rotatedURL(1))
            rotatedRuns += 1
        }

        let path = Self.url.path
        fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd < 0 {
            c64Log.error("[c64-file] probe file not opened: \(path, privacy: .public) errno=\(errno)")
        }
        // debugger= zeigt, ob der Lauf aus Xcode kam (der Debugger hält den Prozess im Hintergrund
        // wach, Quinn, Apple DTS, Forum 796528).
        write("---- Start \(ISO8601DateFormatter().string(from: Date())) pid=\(getpid()) debugger=\(ProbeContext.debuggerAttached ? 1 : 0) rotated=\(rotatedRuns)")
    }

    /// Schreibt eine Zeile ungepuffert an den Kernel (kein fsync, siehe Kopf der Datei).
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
    }
}

/// Eine Zeile in die Probe-Datei; ohne Probe nichts.
nonisolated func c64Record(_ line: String) {
    guard ProgressFile.enabled else { return }
    ProgressFile.shared.write(line)
}

/// Ein Fehler: immer ins Unified Log, mit Probe auch in die Datei.
nonisolated func c64Error(_ line: String) {
    c64Log.error("\(line, privacy: .public)")
    c64Record(line)
}

/// Kontext des Prozesses für die Startzeile: der Zustand wird gelesen, nicht angenommen
/// (Arbeitsweise, Fehlerklasse 2b).
nonisolated enum ProbeContext {
    static var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #elseif DIAGNOSTICS
        return "Diagnostics"
        #else
        return "Release"
        #endif
    }

    static func environment(_ key: String) -> String {
        HostEnvironment.text(key)
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

    /// Hängt ein Debugger am Prozess? sysctl kern.proc.pid, Flag P_TRACED (Apple TN QA1361).
    /// Gelesen, nicht angenommen: beim M2-Lauf von M4a.5c-4 war nicht erkennbar, ob er aus Xcode
    /// oder vom Home-Bildschirm kam.
    static var debuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &info, &size, nil, 0)
        }
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    static func name(_ format: MTLPixelFormat) -> String {
        switch format {
        case .bgra8Unorm: return "bgra8Unorm"
        case .bgra8Unorm_srgb: return "bgra8Unorm_srgb"
        case .rgba8Unorm: return "rgba8Unorm"
        case .rgba8Unorm_srgb: return "rgba8Unorm_srgb"
        case .rgba16Float: return "rgba16Float"
        case .bgr10a2Unorm: return "bgr10a2Unorm"       // Rohwert 94 (MTLPixelFormat.h:114)
        case .rgba16Unorm: return "rgba16Unorm"         // Rohwert 110 (MTLPixelFormat.h:172)
        case .depth32Float: return "depth32Float"
        case .depth16Unorm: return "depth16Unorm"
        case .depth32Float_stencil8: return "depth32Float_stencil8"
        case .invalid: return "invalid"
        default: return "raw\(format.rawValue)"
        }
    }

    /// Noch verfügbarer Speicher des Prozesses in MB (os_proc_available_memory: Abstand zur
    /// Jetsam-Grenze der App). Referenz: Vice City stürzte auf der M5 bei 5,4 GB phys_footprint ab,
    /// das Entwicklerforum nennt 5 GB pro App.
    static var availableMemoryMB: Double {
        Double(os_proc_available_memory()) / (1024 * 1024)
    }

    /// Physischer Speicherbedarf des Prozesses in MB (task_info TASK_VM_INFO, phys_footprint),
    /// dieselbe Grösse wie in Xcodes Speicheranzeige. 0 bei Fehler.
    static var physFootprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
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

#if DEBUG
/// Stall-Sequenz aus der Umgebungsvariablen C64_STALL_SEQ, Millisekunden mit Komma getrennt,
/// Beispiel "500,1000,2000,5000". Nicht gesetzt oder leer: keine Stall-Probe. Nur in Debug-Builds.
nonisolated enum StallPlan {
    static let environmentKey = "C64_STALL_SEQ"

    /// Dauern in Sekunden.
    static func fromEnvironment() -> [TimeInterval] {
        guard let raw = HostEnvironment.string(environmentKey), !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { part in
            guard let ms = Double(part.trimmingCharacters(in: .whitespaces)), ms > 0 else { return nil }
            return ms / 1000.0
        }
    }
}
#endif

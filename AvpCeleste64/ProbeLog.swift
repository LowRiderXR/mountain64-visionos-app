//
//  ProbeLog.swift
//  AvpCeleste64
//
//  Probe file and the few error lines for the unified log.
//
//  Switching: with the configuration Diagnostics (DIAGNOSTICS) the probe is on, otherwise off;
//  C64_PROBE=on|off overrides both. With the probe every c64Record line goes into the file
//  Library/Application Support/c64-probe.txt (the current run); at every start the previous runs
//  move to c64-probe-1.txt through c64-probe-4.txt, older ones are deleted. Without the probe no
//  file is created and c64Record does nothing. c64Error always goes into the unified log (and
//  with the probe into the file); nothing else writes to the unified log any more (filtering for
//  "c64-" in Console.app shows only errors).
//
//  Every line goes straight to the kernel with an unbuffered write(); that way it survives a
//  SIGKILL (the data sits in the page cache and is written by the kernel) without the writing
//  thread waiting for the disk. The earlier fsync per line ran on the render thread and could
//  cost milliseconds there; a lost remainder would only occur on a kernel panic or power loss,
//  not when the system terminates the app.
//

import Darwin
import Foundation
import Metal
import os

/// Environment of the process, read once: ProcessInfo.environment copies the whole dictionary on
/// every access; the host's switches therefore all read from this copy.
nonisolated enum HostEnvironment {
    static let values: [String: String] = ProcessInfo.processInfo.environment

    static func string(_ key: String) -> String? {
        values[key]
    }

    /// For the start line: the value or "-".
    static func text(_ key: String) -> String {
        values[key] ?? "-"
    }
}

/// Unified log, subsystem of the app; errors only (c64Error and c64Log.error).
nonisolated let c64Log = Logger(subsystem: "com.lowriderxr.Mountain64", category: "probe")

/// Probe file under Library/Application Support (not visible in the Files app).
nonisolated final class ProgressFile: @unchecked Sendable {
    static let shared = ProgressFile()

    static let fileName = "c64-probe.txt"
    /// Previous runs kept at start (c64-probe-1.txt through c64-probe-4.txt).
    static let keptRuns = 4

    /// Probe on: C64_PROBE=on|off decides; without the switch the configuration Diagnostics.
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
    /// Files that moved up one place at start (0 on the first run).
    private(set) var rotatedRuns = 0

    private init() {
        let fileManager = FileManager.default
        // Old location (Documents, visible in the Files app): delete at start.
        let legacy = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(Self.fileName)
        if fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.removeItem(at: legacy)
        }
        guard Self.enabled else { return }

        try? fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        // Rotation: delete 4, 3 -> 4, 2 -> 3, 1 -> 2, current -> 1.
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
        // debugger= shows whether the run came from Xcode (the debugger keeps the process awake in
        // the background, Quinn, Apple DTS, forum 796528).
        write("---- Start \(ISO8601DateFormatter().string(from: Date())) pid=\(getpid()) debugger=\(ProbeContext.debuggerAttached ? 1 : 0) rotated=\(rotatedRuns)")
    }

    /// Writes one line unbuffered to the kernel (no fsync, see the file header).
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

/// One line into the probe file; nothing without the probe.
nonisolated func c64Record(_ line: String) {
    guard ProgressFile.enabled else { return }
    ProgressFile.shared.write(line)
}

/// An error: always into the unified log, with the probe also into the file.
nonisolated func c64Error(_ line: String) {
    c64Log.error("\(line, privacy: .public)")
    c64Record(line)
}

/// Context of the process for the start line: the state is read, not assumed.
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

    /// Device model via sysctl hw.machine (such as "RealityDevice14,1").
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

    /// Is a debugger attached to the process? sysctl kern.proc.pid, flag P_TRACED (Apple TN QA1361).
    /// Read, not assumed: in one run on the M2 it was not clear whether it came from Xcode or from
    /// the home screen.
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
        case .bgr10a2Unorm: return "bgr10a2Unorm"       // raw value 94 (MTLPixelFormat.h:114)
        case .rgba16Unorm: return "rgba16Unorm"         // raw value 110 (MTLPixelFormat.h:172)
        case .depth32Float: return "depth32Float"
        case .depth16Unorm: return "depth16Unorm"
        case .depth32Float_stencil8: return "depth32Float_stencil8"
        case .invalid: return "invalid"
        default: return "raw\(format.rawValue)"
        }
    }

    /// Memory still available to the process in MB (os_proc_available_memory: distance to the app's
    /// jetsam limit). Reference: a comparable app crashed on the M5 at a phys_footprint of 5.4 GB,
    /// the developer forum names 5 GB per app.
    static var availableMemoryMB: Double {
        Double(os_proc_available_memory()) / (1024 * 1024)
    }

    /// Physical memory footprint of the process in MB (task_info TASK_VM_INFO, phys_footprint), the
    /// same quantity as Xcode's memory gauge. 0 on error.
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
/// Stall sequence from the environment variable C64_STALL_SEQ, milliseconds separated by commas,
/// example "500,1000,2000,5000". Unset or empty: no stall probe. Debug builds only.
nonisolated enum StallPlan {
    static let environmentKey = "C64_STALL_SEQ"

    /// Durations in seconds.
    static func fromEnvironment() -> [TimeInterval] {
        guard let raw = HostEnvironment.string(environmentKey), !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { part in
            guard let ms = Double(part.trimmingCharacters(in: .whitespaces)), ms > 0 else { return nil }
            return ms / 1000.0
        }
    }
}
#endif

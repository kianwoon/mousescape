// baseline-guard:allow new file for ClickAssistAgent target (no prior baseline)
//
//  AgentLog.swift
//  ClickAssistAgent
//
//  Persistent, bounded logging shim so the shared ClickAssistEngine/Resolver/Tap
//  sources (and the agent) leave decision-level evidence. launchd discards stderr,
//  so lines go to ~/Library/Logs/Mousecape/ClickAssistAgent.log. The app target
//  supplies its own DebugLogger implementation and is unaffected.
//

import Foundation
import Synchronization

/// Bounded per-user log file with numbered multi-step rotation.
private enum ClickAssistLogFile {
    /// Directory under the user's Library; created lazily on first append.
    static let directoryComponents = ["Library", "Logs", "Mousecape"]
    static let fileName = "ClickAssistAgent.log"
    /// Rotate when the live file exceeds this size. `backupCount` numbered
    /// backups are kept (`.1` newest … `.3` oldest), so total disk use is
    /// bounded at (backupCount + 1) × maxBytes = 8 MB.
    static let maxBytes = 2 * 1024 * 1024
    /// Number of rotated backups retained beyond the live file.
    static let backupCount = 3

    static var url: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let dir = directoryComponents.dropFirst().reduce(base) { $0.appendingPathComponent($1) }
        return dir.appendingPathComponent(fileName)
    }

    /// Called only on `ClickAssistLogQueue`. All I/O failures are swallowed: a
    /// read-only/absent directory must never take down the agent.
    static func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        let fileURL = url
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            if size > maxBytes {
                // Shift oldest→newest so ordering survives: drop .N, then
                // .(N-1) → .N … .1 → .2, and finally live → .1. Every step is
                // `try?` so a partial failure never crashes the agent.
                let base = fileURL.deletingPathExtension()
                func backup(_ i: Int) -> URL { base.appendingPathExtension("\(i).log") }
                try? fm.removeItem(at: backup(backupCount))
                var i = backupCount - 1
                while i >= 1 {
                    try? fm.moveItem(at: backup(i), to: backup(i + 1))
                    i -= 1
                }
                try? fm.moveItem(at: fileURL, to: backup(1))
            }
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: fileURL.path) else { return }
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Intentionally silent: logging is best-effort diagnostics.
        }
    }
}

/// Serial, utility-QoS queue so append I/O never runs on the tap thread.
private let ClickAssistLogQueue = DispatchQueue(label: "com.sdmj76.ClickAssistAgent.log",
                                                qos: .utility)

/// Queued-line count used for the drop-when-backlogged policy. Atomic so the
/// tap callback can check/update it without a lock or file I/O.
private let ClickAssistLogPending = Atomic<Int>(0)
/// Beyond this many queued lines, new lines are dropped rather than growing the
/// backlog (a wedged/slow disk must not balloon memory or latency).
private let ClickAssistLogMaxPending = 64

private func clickAssistTimestamp() -> String {
    var now = time(nil)
    var tmValue = tm()
    localtime_r(&now, &tmValue)
    var buffer = [CChar](repeating: 0, count: 32)
    strftime(&buffer, buffer.count, "%Y-%m-%d %H:%M:%S", &tmValue)
    return String(cString: buffer)
}

func debugLog(_ message: String) {
    let line = "\(clickAssistTimestamp()) \(message)"

    // Mirror to stderr only when attached to a terminal; launchd discards it.
    if isatty(STDERR_FILENO) != 0 {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    let previous = ClickAssistLogPending.add(1, ordering: .relaxed).oldValue
    guard previous < ClickAssistLogMaxPending else {
        ClickAssistLogPending.subtract(1, ordering: .relaxed)
        return
    }
    ClickAssistLogQueue.async {
        defer { ClickAssistLogPending.subtract(1, ordering: .relaxed) }
        ClickAssistLogFile.append(line)
    }
}

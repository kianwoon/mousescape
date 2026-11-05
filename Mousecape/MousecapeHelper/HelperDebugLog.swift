//
//  HelperDebugLog.swift
//  MousecapeHelper
//
//  Logging shim for MousecapeHelper and the shared Click Assist sources it hosts.
//  - "[ClickAssist]" lines always (Release too) go to a bounded per-user file,
//    the same file the ClickAssistResolver XPC service writes, so engine and
//    resolver decisions stay diagnosable and Tools/ClickAssistCorpus can read
//    them. launchd discards stderr, so a file is the only durable sink.
//  - Everything else goes to the MCLogger file in DEBUG builds only.
//

import Foundation
import os
import Synchronization

/// Bounded Click Assist log file with numbered multi-step rotation. The file
/// name is shared with ClickAssistXPC/main.swift and Tools/ClickAssistCorpus.
private enum ClickAssistLogFile {
    static let directoryComponents = ["Logs", "Mousecape"]
    static let fileName = "ClickAssistAgent.log"
    /// Rotate when the live file exceeds this size; `backupCount` numbered
    /// backups are kept, so total disk use is bounded at (backupCount + 1) × maxBytes.
    static let maxBytes = 2 * 1024 * 1024
    static let backupCount = 3

    static var url: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let dir = directoryComponents.reduce(base) { $0.appendingPathComponent($1) }
        return dir.appendingPathComponent(fileName)
    }

    /// Called only on `ClickAssistLogQueue`. All I/O failures are swallowed:
    /// logging is best-effort and must never take down the Helper.
    static func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        let fileURL = url
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let size = ((try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
            if size > maxBytes {
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
            // O_APPEND: the resolver XPC service appends to this same file from
            // another process; seekToEnd + write let each overwrite the other.
            let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT,
                          S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            guard fd >= 0 else { return }
            defer { close(fd) }
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        } catch {
            // Intentionally silent: logging is best-effort diagnostics.
        }
    }
}

/// Serial, utility-QoS queue so file I/O never runs on the tap thread.
private let ClickAssistLogQueue = DispatchQueue(
    label: (Bundle.main.bundleIdentifier ?? "MousecapeHelper") + ".click-assist-log",
    qos: .utility)

/// Queued-line count for the drop-when-backlogged policy (atomic: callable from
/// the tap callback without a lock).
private let ClickAssistLogPending = Atomic<Int>(0)
private let ClickAssistLogMaxPending = 64

private let ClickAssistMarker = "[ClickAssist]"

/// Unified-log channel for Helper lifecycle facts (visible in Release, public).
let helperOSLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MousecapeHelper",
                         category: "ClickAssist")

private func clickAssistTimestamp() -> String {
    var now = time(nil)
    var tmValue = tm()
    localtime_r(&now, &tmValue)
    var buffer = [CChar](repeating: 0, count: 32)
    strftime(&buffer, buffer.count, "%Y-%m-%d %H:%M:%S", &tmValue)
    return String(cString: buffer)
}

/// Append one line to the Click Assist log file (Release and Debug).
func clickAssistFileLog(_ message: String) {
    let line = "\(clickAssistTimestamp()) \(message)"
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

/// Helper lifecycle line for Click Assist: unified log (public) + Click Assist file.
func clickAssistLifecycleLog(_ message: String) {
    helperOSLog.notice("\(message, privacy: .public)")
    clickAssistFileLog("\(ClickAssistMarker) \(message)")
}

/// Debug logging used by Helper code and the shared Click Assist sources.
func debugLog(_ message: String) {
    if message.contains(ClickAssistMarker) {
        clickAssistFileLog(message)
    }
    #if DEBUG
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    HelperLog("[\(timestamp)] [MousecapeHelper] \(message)")
    #endif
}

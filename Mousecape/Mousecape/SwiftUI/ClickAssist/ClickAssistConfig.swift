// baseline-guard:allow new file for app-hosted Click Assist integration (no prior baseline)
//
//  ClickAssistConfig.swift
//  Mousecape
//
//  Click Assist preference contract, validated model and runtime status text.
//

import Foundation
import CoreGraphics

// MARK: - Contract table (exact names / defaults / validation)
//
// Key                                  Type    Default   Validation
// MCClickAssistEnabled                 Bool    false     bool (missing => false)
// MCClickAssistTolerancePoints         Number  12        finite, clamped 8...32
// MCClickAssistIndicatorEnabled        Bool    true      bool (missing => true)
//
// Scope is deliberately one store: currentUser + anyHost, inside Mousecape's own
// preference domain. No host-specific shadow, no mirrored second domain.
struct ClickAssistConfig: Equatable, Sendable {
    var enabled: Bool
    var tolerancePoints: CGFloat
    var indicatorEnabled: Bool

    static let defaultTolerance = ClickAssistTolerance.defaultValue
    static let toleranceRange = ClickAssistTolerance.range

    static func validated(enabled: Bool, tolerancePoints raw: CGFloat,
                          indicatorEnabled: Bool) -> ClickAssistConfig {
        return ClickAssistConfig(enabled: enabled,
                                 tolerancePoints: ClickAssistTolerance.validated(raw),
                                 indicatorEnabled: indicatorEnabled)
    }
}

final class ClickAssistPreferences: @unchecked Sendable {
    /// Mousecape's own app preference domain (same domain the Settings/AppState
    /// prefs already use), always read/written with currentUser + anyHost.
    static let domain = "com.sdmj76.Mousecape"
    static let changedNotification = domain + ".click-assist-prefs-changed"
    static let enabledKey = "MCClickAssistEnabled"
    static let toleranceKey = "MCClickAssistTolerancePoints"
    static let indicatorKey = "MCClickAssistIndicatorEnabled"

    // Explicit scoped accessors: currentUser + anyHost only.
    private func read(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyValue(key as CFString, Self.domain as CFString,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func write(_ key: String, _ value: CFPropertyList) {
        CFPreferencesSetValue(key as CFString, value, Self.domain as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(Self.domain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        // Post AFTER set + synchronize so another process can re-sync and re-read.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(rawValue: Self.changedNotification as CFString),
                                             nil, nil, true)
    }

    func readConfig() -> ClickAssistConfig {
        ClickAssistConfig.validated(
            enabled: bool(Self.enabledKey, default: false),
            tolerancePoints: number(Self.toleranceKey, default: ClickAssistConfig.defaultTolerance),
            indicatorEnabled: bool(Self.indicatorKey, default: true))
    }

    func writeEnabled(_ value: Bool) {
        write(Self.enabledKey, NSNumber(value: value))
    }

    func writeTolerancePoints(_ value: CGFloat) {
        let clamped = ClickAssistConfig.validated(enabled: true, tolerancePoints: value,
                                                  indicatorEnabled: true).tolerancePoints
        write(Self.toleranceKey, NSNumber(value: Double(clamped)))
    }

    func writeIndicatorEnabled(_ value: Bool) {
        write(Self.indicatorKey, NSNumber(value: value))
    }

    private func bool(_ key: String, default def: Bool) -> Bool {
        guard let raw = read(key) else { return def }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((raw as! CFBoolean))
        }
        if let n = raw as? NSNumber { return n.boolValue }
        return def
    }

    private func number(_ key: String, default def: CGFloat) -> CGFloat {
        guard let raw = read(key), let n = raw as? NSNumber else { return def }
        let d = n.doubleValue
        return d.isFinite ? CGFloat(d) : def
    }
}

enum ClickAssistRuntimeStatus: Equatable, Sendable {
    case active
    case pausedDisabled
    case pausedAccessibility
    case tapFailed
    case resolverUnavailable

    var text: String {
        switch self {
        case .active: return "Active — assist tap and resolver running"
        case .pausedDisabled: return "Paused — disabled in Settings"
        case .pausedAccessibility: return "Paused — Accessibility access required"
        case .tapFailed: return "Paused — event tap could not start"
        case .resolverUnavailable: return "Paused — Accessibility resolver unavailable"
        }
    }

    /// Wire value persisted in the runtime status record. Deliberately distinct
    /// from the preference layer: this describes what the agent is actually doing.
    var reportedState: ClickAssistStatusState {
        switch self {
        case .active: return .active
        case .pausedDisabled: return .pausedDisabled
        case .pausedAccessibility: return .pausedPermission
        case .tapFailed: return .tapFailed
        case .resolverUnavailable: return .resolverUnavailable
        }
    }
}

// MARK: - Runtime status record (agent -> app)
//
// This is runtime truth, not configuration. It is written only by the agent to a
// deterministic per-user file and read by the app. Prefs remain the user's intent.

enum ClickAssistStatusState: String, Codable, Equatable, Sendable {
    case active
    case pausedPermission = "paused-permission"
    case pausedDisabled = "paused-disabled"
    case tapFailed = "tap-failed"
    case resolverUnavailable = "resolver-unavailable"
}

struct ClickAssistStatusRecord: Codable, Equatable, Sendable {
    var state: ClickAssistStatusState
    /// Wall-clock heartbeat, refreshed by the agent while it runs. A stale value
    /// means the agent is gone (or wedged) even if the file still exists.
    var heartbeat: Date
    /// The tolerance the agent is actually using, NOT the requested pref value.
    var tolerancePoints: Double

    /// User-facing status text rendered by the app Settings view.
    func displayText() -> String {
        switch state {
        case .active:
            let tol = tolerancePoints.rounded() == tolerancePoints
                ? String(format: "%.0f", tolerancePoints)
                : String(format: "%.1f", tolerancePoints)
            return "Active — assist running at \(tol) pt"
        case .pausedPermission: return "Paused — Accessibility access required"
        case .pausedDisabled: return "Paused — disabled in Settings"
        case .tapFailed: return "Paused — event tap could not start"
        case .resolverUnavailable: return "Paused — Accessibility resolver unavailable"
        }
    }
}

/// Single deterministic per-user location for the runtime record, plus the
/// namespaced Darwin hint posted after every change. The file is the record;
/// the notification only tells listeners to re-read it.
enum ClickAssistStatusStore {
    static let changedNotification = ClickAssistPreferences.domain + ".click-assist-status-changed"
    static let directoryName = "Mousecape/ClickAssistAgent"
    static let fileName = "status.json"

    /// A record whose heartbeat is older than this is treated as dead. The agent
    /// heartbeats every 2 s, so this tolerates ~2 missed beats before the app
    /// stops claiming assist is running.
    static let staleThreshold: TimeInterval = 6

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(directoryName, isDirectory: true)
                   .appendingPathComponent(fileName, isDirectory: false)
    }

    static func write(_ record: ClickAssistStatusRecord) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            // Atomic write: readers never observe a partially written record.
            try data.write(to: url, options: .atomic)
            postChanged()
        } catch {
            debugLog("[ClickAssist] STATUS_WRITE_FAILED error=\(error)")
        }
    }

    static func read() -> ClickAssistStatusRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ClickAssistStatusRecord.self, from: data)
    }

    /// Clean shutdown: remove the record so the app never shows a false "Active".
    static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
        postChanged()
    }

    static func postChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: changedNotification as CFString),
            nil, nil, true)
    }
}

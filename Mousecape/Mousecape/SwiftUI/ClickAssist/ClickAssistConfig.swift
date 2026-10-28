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
// MCClickAssistTolerancePoints         Number  12        finite, clamped 8...16
// MCClickAssistIndicatorEnabled        Bool    true      bool (missing => true)
//
// Scope is deliberately one store: currentUser + anyHost, inside Mousecape's own
// preference domain. No host-specific shadow, no mirrored second domain.
struct ClickAssistConfig: Equatable, Sendable {
    var enabled: Bool
    var tolerancePoints: CGFloat
    var indicatorEnabled: Bool

    static let defaultTolerance: CGFloat = 12
    static let toleranceRange: ClosedRange<CGFloat> = 8...16

    static func validated(enabled: Bool, tolerancePoints raw: CGFloat,
                          indicatorEnabled: Bool) -> ClickAssistConfig {
        let finite = raw.isFinite ? raw : defaultTolerance
        return ClickAssistConfig(enabled: enabled,
                                 tolerancePoints: min(max(finite, toleranceRange.lowerBound),
                                                      toleranceRange.upperBound),
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
}

// baseline-guard:allow new file for app-hosted Click Assist integration (no prior baseline)
//
//  ClickAssistEngine.swift
//  Mousecape
//
//  App-hosted runtime for Click Assist. Owns the AX resolver, the event tap and the
//  targeting overlay for the Mousecape app target. It never touches the cursor-apply,
//  wake or helper machinery.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Observation

/// Owns the runtime engine and is the only place that applies a validated config
/// snapshot. Prefs are the source of truth; the UI reads `config`/`runtimeStatus`
/// directly from the engine (no shadow copy).
@Observable
@MainActor
final class ClickAssistEngine {
    static let shared = ClickAssistEngine()

    let cache = CacheStore()
    /// One legitimacy policy shared by the tap (click decisions) and the overlay
    /// (ring decisions): the renderer's hit-test is the single source of truth.
    let legitimacy = LegitimacyPolicy()
    let prefs = ClickAssistPreferences()

    private(set) var config: ClickAssistConfig
    private(set) var tap: AssistTap?
    private(set) var resolver: AccessibilityResolver?
    private(set) var overlay: TargetingOverlay?

    /// When false the engine never auto-prompts for Accessibility; permission must
    /// be requested by an explicit user action (the persistent agent uses this).
    /// Default preserves the existing app-hosted behavior.
    var promptsForAccessibility = true

    private var trustPromptRequested = false
    private var prefObserverRegistered = false
    private var cacheObserverInstalled = false

    private init() {
        self.config = prefs.readConfig()
    }

    // MARK: - lifecycle

    /// Called once from AppState at launch. Registers pref invalidation even when
    /// the pref is off, but only starts the engine when enabled.
    func startFromAppIfNeeded() {
        registerForPrefChanges()
        guard config.enabled else { return }
        apply(config)
    }

    /// Re-sync the explicit domain and re-read/validate ALL keys, then apply.
    func refreshFromPreferences() {
        CFPreferencesSynchronize(ClickAssistPreferences.domain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        registerForPrefChanges()
        reloadFromPreferences()
    }

    func reloadFromPreferences() {
        apply(prefs.readConfig())
    }

    func shutdown() {
        unregisterForPrefChanges()
        stopEngine()
    }

    // MARK: - pref change observation (external edits)

    /// Idempotent registration: a second call is a no-op, so handlers never stack.
    private func registerForPrefChanges() {
        guard !prefObserverRegistered else { return }
        prefObserverRegistered = true
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        Self.prefChangedCallback,
                                        ClickAssistPreferences.changedNotification as CFString,
                                        nil, .deliverImmediately)
    }

    private func unregisterForPrefChanges() {
        guard prefObserverRegistered else { return }
        prefObserverRegistered = false
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(rawValue: ClickAssistPreferences.changedNotification as CFString),
                                           nil)
    }

    private static let prefChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let engine = Unmanaged<ClickAssistEngine>.fromOpaque(observer).takeUnretainedValue()
        engine.preferencesChangedFromDarwin()
    }

    /// Darwin notifications arrive on an arbitrary thread; hop to main, never block.
    private func preferencesChangedFromDarwin() {
        Task { @MainActor [weak self] in
            self?.handleExternalPreferencesChanged()
        }
    }

    private func handleExternalPreferencesChanged() {
        CFPreferencesSynchronize(ClickAssistPreferences.domain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        reloadFromPreferences()
    }

    // MARK: - requests (writes prefs, then re-reads the validated snapshot)

    func requestEnabled(_ value: Bool) {
        guard value != config.enabled else { return }
        prefs.writeEnabled(value)
        reloadFromPreferences()
    }

    func requestTolerancePoints(_ value: CGFloat) {
        let clamped = ClickAssistConfig.validated(enabled: config.enabled,
                                                  tolerancePoints: value,
                                                  indicatorEnabled: config.indicatorEnabled).tolerancePoints
        guard clamped != config.tolerancePoints else { return }
        prefs.writeTolerancePoints(clamped)
        reloadFromPreferences()
    }

    func requestIndicatorEnabled(_ value: Bool) {
        guard value != config.indicatorEnabled else { return }
        prefs.writeIndicatorEnabled(value)
        reloadFromPreferences()
    }

    // MARK: - status

    var requestedSummary: String {
        "Requested: \(config.enabled ? "Enabled" : "Disabled") · " +
        String(format: "%.1f pt", config.tolerancePoints) +
        " · Indicator \(config.indicatorEnabled ? "On" : "Off")"
    }

    var runtimeStatus: ClickAssistRuntimeStatus {
        if !config.enabled { return .pausedDisabled }
        if !AXIsProcessTrusted() { return .pausedAccessibility }
        if tap == nil { return .tapFailed }
        if resolver == nil { return .resolverUnavailable }
        return .active
    }

    var runtimeSummary: String { runtimeStatus.text }

    // MARK: - apply

    private func apply(_ raw: ClickAssistConfig) {
        let old = config
        config = ClickAssistConfig.validated(enabled: raw.enabled,
                                             tolerancePoints: raw.tolerancePoints,
                                             indicatorEnabled: raw.indicatorEnabled)
        if !config.enabled {
            stopEngine()
            return
        }
        if old.enabled, tap != nil {
            if old.tolerancePoints != config.tolerancePoints { applyToleranceChange(from: old.tolerancePoints) }
            if old.indicatorEnabled != config.indicatorEnabled {
                config.indicatorEnabled ? startOverlay() : stopOverlay()
            }
        } else {
            startEngine()
        }
    }

    private func startEngine() {
        stopEngine()
        guard config.enabled else { return }
        guard AXIsProcessTrusted() else {
            if !trustPromptRequested, promptsForAccessibility {
                trustPromptRequested = true
                let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(prompt)
            }
            debugLog("[ClickAssist] ENGINE_PAUSED reason=accessibility-untrusted status=\"\(runtimeStatus.text)\"")
            return
        }
        // Tap creation is cheap and must happen on the main run loop; the AX walk
        // never runs here (the resolver's first refresh is queued off-main).
        let t = AssistTap(tolerance: config.tolerancePoints) { line in
            debugLog("[ClickAssist] \(line)")
        }
        t.targetSource = .cache(cache)
        guard t.start(point: .cghidEventTap) else {
            debugLog("[ClickAssist] ENGINE_PAUSED reason=tap-create-failed")
            return
        }
        tap = t
        let r = AccessibilityResolver(cache: cache, legitimacy: legitimacy) { line in
            debugLog("[ClickAssist] \(line)")
        }
        resolver = r
        r.start()
        if config.indicatorEnabled { startOverlay() }
    }

    private func stopEngine() {
        resolver?.stop()
        resolver = nil
        tap?.stop()
        tap = nil
        stopOverlay()
    }

    private func applyToleranceChange(from old: CGFloat) {
        tap?.setTolerance(config.tolerancePoints)
        overlay?.setTolerance(config.tolerancePoints)
        // No queue.sync here: invalidate only publishes an invalid snapshot and
        // schedules the refresh on the resolver queue.
        resolver?.invalidate(reason: "tolerance-change", prefixStale: false)
        debugLog(String(format: "[ClickAssist] TOLERANCE_APPLY from=%.1f to=%.1f",
                        old, config.tolerancePoints))
    }

    private func startOverlay() {
        guard overlay == nil else { return }
        let o = TargetingOverlay(tolerance: config.tolerancePoints) { line in
            debugLog("[ClickAssist] \(line)")
        }
        o.legitimacy = legitimacy
        overlay = o
        // One permanent forwarder: overlay identity changes, observer count stays 1.
        if !cacheObserverInstalled {
            cache.addObserver { [weak self] snap in
                // Called on the resolver queue: hop to main, never block the publisher.
                Task { @MainActor in self?.overlay?.observe(snap) }
            }
            cacheObserverInstalled = true
        }
    }

    private func stopOverlay() {
        guard let o = overlay else { return }
        o.kill()
        overlay = nil
    }
}

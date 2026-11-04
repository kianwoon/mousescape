//
//  HelperClickAssist.swift
//  MousecapeHelper
//
//  Hosts the shared Click Assist engine inside MousecapeHelper (agent → Helper
//  consolidation, phase 1). Threading:
//    - event tap source + callback: ClickAssistTapThread (dedicated CFRunLoop),
//      so the Helper's wake/apply work on main can never delay input delivery
//      or trip tapDisabledByTimeout;
//    - XPC client + snapshot decoding: the service client's own utility queue;
//    - AX element work: the ClickAssistResolver XPC service (out of process);
//    - engine state, overlay and this controller: main actor (cheap UI only).
//  The Helper is the single resident app: at launch it terminates any leftover
//  legacy ClickAssistAgent (single system-wide tap), then hosts unconditionally.
//

import AppKit
import ApplicationServices
import Combine

/// Dedicated thread whose run loop hosts the Click Assist event tap.
final class ClickAssistTapThread: Thread, @unchecked Sendable {
    static let shared = ClickAssistTapThread()

    private let ready = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop?
    private var cachedLoop: CFRunLoop?

    private override init() {
        super.init()
        name = (Bundle.main.bundleIdentifier ?? "MousecapeHelper") + ".click-assist-tap"
        qualityOfService = .userInteractive
    }

    override func main() {
        loop = CFRunLoopGetCurrent()
        // Keep-alive source: a run loop with no sources returns immediately.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while !isCancelled {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    /// The tap run loop. First call starts the thread and waits only for it to
    /// publish its run loop (one-time, sub-millisecond). Call from main only.
    /// nil only if the thread failed to publish (engine then falls back to main).
    var runLoop: CFRunLoop? {
        if let cachedLoop { return cachedLoop }
        start()
        ready.wait()
        cachedLoop = loop
        return loop
    }
}

@MainActor
final class HelperClickAssistController: ObservableObject {
    static let shared = HelperClickAssistController()

    @Published private(set) var enabled = false
    @Published private(set) var statusText = ""

    private let engine = ClickAssistEngine.shared
    private var started = false
    private var lastTrusted = false
    private var refreshTimer: Timer?

    /// Status / accessibility-trust refresh cadence and status-record heartbeat.
    private static let refreshInterval: TimeInterval = 1
    private static let heartbeatInterval: TimeInterval = 2

    private var lastPublishedState: ClickAssistStatusState?
    private var lastPublishedTolerance: CGFloat?
    private var lastHeartbeat = Date.distantPast

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        // Onboarding is explicit: only "Grant Accessibility…" prompts.
        engine.promptsForAccessibility = false
        engine.tapHostRunLoop = ClickAssistTapThread.shared.runLoop
        lastTrusted = AXIsProcessTrusted()

        // Retire a leftover legacy agent first: only one system-wide tap may exist.
        if ClickAssistHost.terminateLegacyAgentIfRunning() {
            NSLog("[MousecapeHelper] ClickAssist terminated legacy agent")
        }
        NSLog("[MousecapeHelper] ClickAssist host engine=starting")
        // Re-sync + re-read prefs and apply: starts the tap only when the shared
        // pref is enabled.
        engine.refreshFromPreferences()
        publishStatus()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor in HelperClickAssistController.shared.tick() }
        }
    }

    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        engine.shutdown()
        ClickAssistStatusStore.remove()
    }

    // MARK: - menu actions

    func setEnabled(_ value: Bool) {
        engine.requestEnabled(value)
        refresh()
    }

    func grantAccessibility() {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    /// Called when the menu opens: re-sync prefs written by other processes.
    func refreshFromMenu() {
        refresh()
    }

    // MARK: - hosting

    private func tick() {
        retryAfterTrustGranted()
        refresh()
    }

    /// The engine pauses (no tap) while untrusted; once the user grants access,
    /// re-apply exactly once on the false → true transition.
    private func retryAfterTrustGranted() {
        let trusted = AXIsProcessTrusted()
        defer { lastTrusted = trusted }
        guard trusted, !lastTrusted, engine.config.enabled, engine.tap == nil else { return }
        NSLog("[MousecapeHelper] ClickAssist accessibility granted, restarting engine")
        engine.reloadFromPreferences()
    }

    private func refresh() {
        enabled = engine.config.enabled
        statusText = engine.runtimeSummary
        publishStatus()
    }

    /// Runtime status record for the main app for the main app.
    private func publishStatus() {
        let state = engine.runtimeStatus.reportedState
        let tolerance = engine.config.tolerancePoints
        let now = Date()
        let changed = state != lastPublishedState || tolerance != lastPublishedTolerance
        guard changed || now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval else { return }
        lastPublishedState = state
        lastPublishedTolerance = tolerance
        lastHeartbeat = now
        ClickAssistStatusStore.write(ClickAssistStatusRecord(state: state,
                                                             heartbeat: now,
                                                             tolerancePoints: Double(tolerance)))
    }
}

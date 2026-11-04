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
//  While the legacy ClickAssistAgent is running the Helper never starts its
//  engine (single system-wide tap); it yields and resumes as the agent comes
//  and goes.
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
    /// True while this Helper owns the engine (legacy agent not running).
    private var hosting = false
    private var started = false
    private var lastTrusted = false
    private var skipLogged = false
    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Same cadences as the legacy agent's AgentStatusController.
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

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == ClickAssistHost.legacyAgentBundleIdentifier else { return }
                Task { @MainActor in HelperClickAssistController.shared.tick() }
            }
            workspaceObservers.append(token)
        }
        updateHosting()
        // Notifications are the fast path; the timer also re-checks the legacy
        // agent (covers missed notifications) and heartbeats the status record.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor in HelperClickAssistController.shared.tick() }
        }
    }

    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if hosting {
            engine.shutdown()
            hosting = false
            ClickAssistStatusStore.remove()
        }
    }

    // MARK: - menu actions

    func setEnabled(_ value: Bool) {
        if hosting {
            engine.requestEnabled(value)
        } else {
            // Yielding: write intent only; the legacy agent observes the pref.
            engine.prefs.writeEnabled(value)
        }
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
        if !hosting {
            CFPreferencesSynchronize(ClickAssistPreferences.domain as CFString,
                                     kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        refresh()
    }

    // MARK: - hosting

    private func tick() {
        updateHosting()
        retryAfterTrustGranted()
        refresh()
    }

    private func legacyAgentRunning() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: ClickAssistHost.legacyAgentBundleIdentifier).isEmpty
    }

    private func updateHosting() {
        let agentRunning = legacyAgentRunning()
        if agentRunning, hosting {
            // The agent writes its own status record; we just stop ours.
            engine.shutdown()
            hosting = false
            NSLog("[MousecapeHelper] ClickAssist yield reason=legacy-agent-running")
        } else if agentRunning, !skipLogged {
            skipLogged = true
            NSLog("[MousecapeHelper] ClickAssist skip reason=legacy-agent-running")
        } else if !agentRunning, !hosting {
            hosting = true
            NSLog("[MousecapeHelper] ClickAssist host engine=starting")
            // Re-sync + re-read prefs (engine.config is stale after a yield, during
            // which the toggle only wrote the pref), re-register the observer and
            // apply: starts the tap only when the shared pref is enabled.
            engine.refreshFromPreferences()
            publishStatus()
        }
    }

    /// The engine pauses (no tap) while untrusted; once the user grants access,
    /// re-apply exactly once on the false → true transition.
    private func retryAfterTrustGranted() {
        let trusted = AXIsProcessTrusted()
        defer { lastTrusted = trusted }
        guard hosting, trusted, !lastTrusted, engine.config.enabled, engine.tap == nil else { return }
        NSLog("[MousecapeHelper] ClickAssist accessibility granted, restarting engine")
        engine.reloadFromPreferences()
    }

    private func refresh() {
        let config = hosting ? engine.config : engine.prefs.readConfig()
        enabled = config.enabled
        if !hosting {
            statusText = String(localized: "Handled by Click Assist agent")
        } else {
            statusText = engine.runtimeSummary
            publishStatus()
        }
    }

    /// Runtime status record for the main app (mirrors AgentStatusController).
    private func publishStatus() {
        guard hosting else { return }
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

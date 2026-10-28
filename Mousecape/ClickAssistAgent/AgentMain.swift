// baseline-guard:allow new file for ClickAssistAgent target (no prior baseline)
//
//  AgentMain.swift
//  ClickAssistAgent
//
//  LSUIElement accessory agent that hosts the shared click-assist engine so assist
//  keeps running after the Mousecape app quits. No Dock icon, no windows, menu-bar
//  status item only.
//

import AppKit
import ApplicationServices
import ServiceManagement

// MARK: - App delegate

@MainActor
final class AgentAppDelegate: NSObject, NSApplicationDelegate {
    private let engine = ClickAssistEngine.shared
    private var statusController: AgentStatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController = AgentStatusController(engine: engine)
        // Onboarding is explicit: only the "Grant Accessibility…" menu action prompts.
        engine.promptsForAccessibility = false
        // Starts only when the shared pref is enabled; no AX work on the launch path.
        engine.startFromAppIfNeeded()
        // Publish immediately after the engine's first transition so the app never
        // reads the pre-start (tap-not-yet-created) snapshot for a full poll cycle.
        statusController?.publishStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
        // Clean quit: drop the runtime record so the app cannot show a stale
        // "Active". Hard kills are covered by the app's heartbeat staleness check.
        ClickAssistStatusStore.remove()
    }
}

// MARK: - Menu-bar status item

@MainActor
final class AgentStatusController: NSObject, NSMenuDelegate {
    private let engine: ClickAssistEngine
    private let statusItem: NSStatusItem
    private let assistItem: NSMenuItem
    private var refreshTimer: Timer?

    /// Heartbeat cadence for the runtime status record. The app treats a record
    /// older than `ClickAssistStatusStore.staleThreshold` as "agent unavailable".
    private static let heartbeatInterval: TimeInterval = 2

    private var lastPublishedState: ClickAssistStatusState?
    private var lastPublishedTolerance: CGFloat?
    private var lastHeartbeat = Date.distantPast

    init(engine: ClickAssistEngine) {
        self.engine = engine
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.assistItem = NSMenuItem(title: "Pause Assist",
                                     action: #selector(toggleAssist),
                                     keyEquivalent: "")
        super.init()
        buildMenu()
        refresh()
        // Status can change without a menu interaction (permission granted, pref
        // edited by the app). Poll cheaply on the main thread.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func buildMenu() {
        statusItem.button?.toolTip = "Click Assist"
        let menu = NSMenu()
        menu.delegate = self

        assistItem.target = self
        menu.addItem(assistItem)

        let openItem = NSMenuItem(title: "Open Mousecape Settings",
                                  action: #selector(openMousecapeSettings),
                                  keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)

        let grantItem = NSMenuItem(title: "Grant Accessibility…",
                                   action: #selector(grantAccessibility),
                                   keyEquivalent: "")
        grantItem.target = self
        menu.addItem(grantItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Click Assist",
                                  action: #selector(quitAgent),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func refresh() {
        let state: String
        if !engine.config.enabled {
            state = "Off"
        } else if engine.runtimeStatus == .active {
            state = "On"
        } else {
            state = "Paused"
        }
        statusItem.button?.title = "CA \(state)"
        statusItem.button?.toolTip = "Click Assist — \(engine.runtimeSummary)"
        assistItem.title = engine.config.enabled ? "Pause Assist" : "Resume Assist"
        assistItem.state = engine.config.enabled ? .on : .off
        publishStatus()
    }

    // MARK: - Runtime status record (file is truth; notification is a hint)

    /// Writes on every state/tolerance transition and heartbeats while running.
    func publishStatus() {
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

    // MARK: - Actions (all go through the shared preference bridge)

    @objc private func toggleAssist() {
        engine.requestEnabled(!engine.config.enabled)
        refresh()
    }

    @objc private func openMousecapeSettings() {
        let appURL = URL(fileURLWithPath: "/Applications/Mousecape.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(at: appURL,
                                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.sdmj76.Mousecape").first {
            running.activate()
        }
    }

    @objc private func grantAccessibility() {
        // Permission is requested only on this explicit user action.
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    @objc private func quitAgent() {
        engine.shutdown()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

@main
@MainActor
struct ClickAssistAgentMain {
    static func main() {
        let agent = NSApplication.shared
        let delegate = AgentAppDelegate()
        agent.delegate = delegate
        agent.setActivationPolicy(.accessory)
        agent.run()
    }
}

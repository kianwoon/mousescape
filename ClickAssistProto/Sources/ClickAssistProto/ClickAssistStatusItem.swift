// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit

/// Persistent menu-bar control surface. It exists independently of every window,
/// so closing the settings or target window can never make the app unreachable.
final class StatusItemController: NSObject {
    private let engine: EngineRuntime
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private var assistItem: NSMenuItem!

    init(engine: EngineRuntime, openSettings: @escaping () -> Void) {
        self.engine = engine
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        engine.onRuntimeChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func buildMenu() {
        statusItem.button?.toolTip = "ClickAssist"
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(showSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        assistItem = NSMenuItem(title: "Assist: Off",
                                action: #selector(toggleAssist),
                                keyEquivalent: "")
        assistItem.target = self
        menu.addItem(assistItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit ClickAssistProto",
                                  action: #selector(quitApp),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
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
        statusItem.button?.toolTip = "ClickAssist — \(engine.runtimeSummary)"
        assistItem?.title = "Assist: \(engine.config.enabled ? "On" : "Off")"
        assistItem?.state = engine.config.enabled ? .on : .off
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func toggleAssist() {
        // Same pref domain and existing bridge used by the Settings UI.
        engine.requestEnabled(!engine.config.enabled)
        refresh()
    }

    @objc private func quitApp() {
        // Explicit clean shutdown: tap, resolver, overlay helper.
        engine.shutdown()
        NSApp.terminate(nil)
    }
}

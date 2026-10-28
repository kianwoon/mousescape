// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit
import ApplicationServices
import CoreGraphics

setlinebuf(stdout)

struct Options {
    var selftest = false
    var dangerous = false
    var simulateUntrusted = false
    var tolerance: CGFloat = 12
    var toleranceExplicit = false
    var tapLocation: CGEventTapLocation = .cghidEventTap

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        o.selftest = args.contains("--selftest")
        o.dangerous = args.contains("--dangerous")
            || ProcessInfo.processInfo.environment["CLICKASSIST_ALLOW_DANGEROUS"] == "1"
        o.simulateUntrusted = args.contains("--simulate-untrusted")
        if let i = args.firstIndex(of: "--tolerance"), i + 1 < args.count, let v = Double(args[i + 1]) {
            o.tolerance = CGFloat(v)
            o.toleranceExplicit = true
        }
        if let i = args.firstIndex(of: "--tap-point"), i + 1 < args.count {
            o.tapLocation = args[i + 1] == "session" ? .cgSessionEventTap : .cghidEventTap
        }
        return o
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    let sink = LogSink()
    var engine: EngineRuntime?
    var window: TestWindow?
    var settings: SettingsWindowController?
    var statusItem: StatusItemController?
    var selfTest: SelfTest?

    init(options: Options) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        let w = TestWindow()
        window = w
        w.makeKeyAndOrderFront(nil)
        let target = w.buttonTarget()
        print("[ASSIST] window content=(640x360) at cocoa-origin=\(w.frame.origin)")
        print("[ASSIST] static target \(target.name) CG-rect=\(target.rect) inset=\(target.inset) tolerance=\(options.tolerance)")

        let trusted = AXIsProcessTrusted()
        print("[ASSIST] pid=\(getpid()) trusted=\(trusted)")

        let e = EngineRuntime(options: options, sink: sink, target: target)
        engine = e

        if options.selftest {
            // Defer engine start to the next runloop turn, after the target window is
            // on screen, so AX notifications cannot overlap launch-time window setup.
            DispatchQueue.main.async {
                e.start()
                let st = SelfTest(window: w, tap: e.tap, sink: self.sink,
                                  cache: e.resolver == nil ? nil : e.cache,
                                  resolver: e.resolver,
                                  overlay: e.overlay,
                                  allowDangerous: self.options.dangerous,
                                  mode: e.tap == nil ? .failOpen : .trustedTap)
                self.selfTest = st
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { st.start() }
            }
        } else {
            installMenu()
            let s = SettingsWindowController(engine: e)
            settings = s
            s.show()
            statusItem = StatusItemController(engine: e) { [weak self] in
                self?.settings?.show()
            }
            print("[ASSIST] interactive mode: settings=runtime-linked prefs=currentUser+anyHost status=\"\(e.runtimeSummary)\"")
            // UI is key/visible before any resolver walk or AX observer registration.
            DispatchQueue.main.async { e.start() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !options.selftest, let settings {
            settings.show()
            return true
        }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !options.selftest, let settings else { return }
        let settingsVisible = settings.window?.isVisible == true
        // No reliance on the isolated-target window: activation restores Settings.
        if !settingsVisible { settings.show() }
    }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit ClickAssistProto",
                                  action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc private func openSettings() {
        settings?.show()
    }
}

let options = Options.parse(CommandLine.arguments)
// Gate 7: overlay helper mode — a separate process, never the tap's process.
if let i = CommandLine.arguments.firstIndex(of: "--overlay-helper"),
   i + 1 < CommandLine.arguments.count {
    runOverlayHelper(socketPath: CommandLine.arguments[i + 1])
}
if CommandLine.arguments.contains("--help") {
    print("usage: ClickAssistProto [--selftest] [--dangerous] [--tolerance pt] [--tap-point hid|session] [--simulate-untrusted]")
    print("  --dangerous (or CLICKASSIST_ALLOW_DANGEROUS=1): enable Space-switch, browser, Electron and synthetic-keyboard cases. Plain --selftest never posts keyboard events, switches Spaces or touches external apps.")
    print("  Config precedence: normal launch loads prefs (currentUser+anyHost). --selftest forces enabled + deterministic test radius (never persisted). An explicit --tolerance seeds the session only; a later Settings write persists and wins.")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()

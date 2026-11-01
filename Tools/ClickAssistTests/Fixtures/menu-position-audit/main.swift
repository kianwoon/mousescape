import AppKit

// A safe, local custom menu. Accessibility exposes each strip as one menu
// item; its six native segments still perform different actions by position.
final class StripView: NSView {
    override func accessibilityChildren() -> [Any]? { [] }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { enclosingMenuItem }
}
final class Audit: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var result: NSTextField!
    var menu: NSMenu!
    var actionCount = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 450, y: 450, width: 640, height: 260),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Click Assist — emoji position audit"
        window.isReleasedWhenClosed = false
        let body = window.contentView!
        let help = NSTextField(wrappingLabelWithString:
            "Local test only. Open the menu and click the second row’s fifth emoji. Expected: Row 2, column 5 — 😱. No message or reaction is sent.")
        help.frame = NSRect(x: 25, y: 160, width: 585, height: 70)
        body.addSubview(help)
        let open = NSButton(title: "Open emoji test menu", target: self, action: #selector(openMenu))
        open.bezelStyle = .rounded
        open.frame = NSRect(x: 25, y: 105, width: 300, height: 40)
        body.addSubview(open)
        result = NSTextField(labelWithString: "No selection — actions: 0")
        result.frame = NSRect(x: 25, y: 35, width: 590, height: 45)
        result.font = .systemFont(ofSize: 22)
        body.addSubview(result)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func openMenu() {
        menu = NSMenu(title: "Safe emoji menu")
        menu.autoenablesItems = false
        for (row, symbols) in [["❤️", "👍", "👎", "😆", "‼️", "❓"],
                               ["💪", "🤣", "💀", "😂", "😱", "🙂"]].enumerated() {
            let item = NSMenuItem(title: "Emoji row \(row + 1)", action: nil, keyEquivalent: "")
            let view = StripView(frame: NSRect(x: 0, y: 0, width: 288, height: 42))
            let segments = NSSegmentedControl(labels: symbols, trackingMode: .momentary,
                                               target: self, action: #selector(picked(_:)))
            segments.tag = row
            segments.frame = NSRect(x: 0, y: 3, width: 288, height: 36)
            for index in symbols.indices { segments.setWidth(46, forSegment: index) }
            view.addSubview(segments)
            item.view = view
            item.isEnabled = true
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 30, y: 102), in: window.contentView)
    }
    @objc func picked(_ sender: NSSegmentedControl) {
        let row = sender.tag + 1, column = sender.selectedSegment + 1
        let symbols = row == 1 ? ["❤️", "👍", "👎", "😆", "‼️", "❓"] : ["💪", "🤣", "💀", "😂", "😱", "🙂"]
        actionCount += 1
        let emoji = symbols.indices.contains(column - 1) ? symbols[column - 1] : "unknown"
        result.stringValue = "Row \(row), column \(column) — \(emoji) — actions: \(actionCount)"
        try? result.stringValue.write(toFile: "/tmp/mousecape-menu-position-result.txt", atomically: true, encoding: .utf8)
        menu.cancelTracking()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let audit = Audit()
app.delegate = audit
app.setActivationPolicy(.regular)
app.run()

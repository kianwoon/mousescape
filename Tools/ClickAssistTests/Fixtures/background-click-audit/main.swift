import AppKit

// Disposable local audit. The button deliberately refuses native first-mouse
// activation so its background behavior reproduces the reported two-click case.
final class AuditButton: NSButton {
    var onDown: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func mouseDown(with event: NSEvent) {
        onDown?(event)
        super.mouseDown(with: event)
    }
}
final class Audit: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var counter: NSTextField!
    var button: AuditButton!
    var count = 0
    let logURL = URL(fileURLWithPath: "/tmp/mousecape-background-click-audit.log")
    func record(_ message: String) {
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("\(ProcessInfo.processInfo.systemUptime) \(message)\n".utf8))
        try? handle.close()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.record("EVENT type=\(event.type.rawValue) marked=\(event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0) active=\(NSApp.isActive) key=\(self?.window?.isKeyWindow ?? false)")
            return event
        }
        window = NSWindow(contentRect: NSRect(x: 500, y: 500, width: 620, height: 300),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Click Assist — background click audit"
        window.isReleasedWhenClosed = false
        let body = window.contentView!
        let help = NSTextField(wrappingLabelWithString:
            "Safe local counter. Focus another app, hover the button until its green ring appears, then click once. Count should increase by exactly one.")
        help.frame = NSRect(x: 30, y: 200, width: 560, height: 70)
        body.addSubview(help)
        button = AuditButton(title: "Count one click", target: self, action: #selector(clicked))
        button.frame = NSRect(x: 30, y: 115, width: 250, height: 60)
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("Background click audit button")
        button.onDown = { [weak self] event in
            self?.record("DOWN marked=\(event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0) active=\(NSApp.isActive) key=\(self?.window.isKeyWindow ?? false)")
        }
        body.addSubview(button)
        counter = NSTextField(labelWithString: "Actions: 0")
        counter.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        counter.frame = NSRect(x: 320, y: 125, width: 250, height: 40)
        body.addSubview(counter)
        let box = NSButton(checkboxWithTitle: "Toggle once", target: nil, action: nil)
        box.frame = NSRect(x: 30, y: 55, width: 220, height: 30)
        body.addSubview(box)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func clicked() {
        count += 1; counter.stringValue = "Actions: \(count)"
        record("ACTION count=\(count)")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let audit = Audit()
app.delegate = audit
app.setActivationPolicy(.regular)
app.run()

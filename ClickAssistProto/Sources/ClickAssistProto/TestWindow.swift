// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit

/// Coordinate conversions: Cocoa screen space (origin bottom-left of main display,
/// y up) <-> CGEvent/AX global display space (origin top-left of main display, y down).
/// Both spaces are global and unified, so secondary displays (negative/offset origins)
/// use the same single-offset conversion.
enum ScreenSpace {
    static var mainHeight: CGFloat { NSScreen.screens[0].frame.height }

    static func cgPoint(fromCocoaScreen p: NSPoint) -> CGPoint {
        cgPoint(fromCocoaScreen: p, mainHeight: mainHeight)
    }

    static func cgRect(fromCocoaScreen r: NSRect) -> CGRect {
        cgRect(fromCocoaScreen: r, mainHeight: mainHeight)
    }

    /// Pure mapping with an injected main-display height. Used by the simulated
    /// multi-display gate: the conversion has no per-display branch, only this
    /// single vertical flip around the main display's top edge.
    static func cgPoint(fromCocoaScreen p: NSPoint, mainHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: mainHeight - p.y)
    }

    static func cgRect(fromCocoaScreen r: NSRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    /// AX/CG global points -> backing pixels at the host display scale.
    static func pixelRect(fromGlobalRect r: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: r.minX * scale, y: r.minY * scale,
               width: r.width * scale, height: r.height * scale)
    }

    /// Backing pixels -> AX/CG global points. Exact inverse of pixelRect.
    static func globalRect(fromPixelRect r: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: r.minX / scale, y: r.minY / scale,
               width: r.width / scale, height: r.height / scale)
    }

    static func fmt(_ p: CGPoint) -> String { String(format: "(%.1f,%.1f)", p.x, p.y) }
    static func fmt(_ v: CGVector) -> String { String(format: "(%.1f,%.1f)", v.dx, v.dy) }
}

/// Records every event that actually reaches a control, in content-view coordinates.
final class EventLog {
    var buttonDown: [NSPoint] = []
    var buttonUp: [NSPoint] = []
    var buttonDragged: [NSPoint] = []
    var buttonRightDown: [NSPoint] = []
    var backgroundDown: [NSPoint] = []
    var backgroundUp: [NSPoint] = []
    /// Any click that reaches an auxiliary AX target (decoy / ambiguity twins).
    var auxDown: [NSPoint] = []
    /// P3: system-computed click state (1 = single, 2 = double-click) and delivered flags.
    var buttonClickCounts: [Int] = []
    var buttonDownFlags: [UInt64] = []
    var buttonDragFlags: [UInt64] = []

    func reset() {
        buttonDown.removeAll(); buttonUp.removeAll(); buttonDragged.removeAll()
        buttonRightDown.removeAll(); backgroundDown.removeAll(); backgroundUp.removeAll()
        auxDown.removeAll()
        buttonClickCounts.removeAll(); buttonDownFlags.removeAll(); buttonDragFlags.removeAll()
    }
}

final class AssistButton: NSButton {
    var log: EventLog?
    var isAux = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func contentPoint(_ event: NSEvent) -> NSPoint {
        superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
    }

    // Deliberately no super call: this prototype needs a deterministic handler, not a
    // tracking loop. Every call below is the control's own action handler.
    override func mouseDown(with event: NSEvent) {
        let p = contentPoint(event)
        if isAux {
            log?.auxDown.append(p)
            print("[AUX] \(title) down at content=(\(Int(p.x)),\(Int(p.y)))")
        } else {
            log?.buttonDown.append(p)
            log?.buttonClickCounts.append(event.clickCount)
            log?.buttonDownFlags.append(UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
            print("[BUTTON] down at content=(\(Int(p.x)),\(Int(p.y))) clickState=\(event.clickCount) flags=0x\(String(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue, radix: 16))")
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isAux else { return }
        let p = contentPoint(event)
        log?.buttonUp.append(p)
        print("[BUTTON] up at content=(\(Int(p.x)),\(Int(p.y)))")
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isAux else { return }
        let p = contentPoint(event)
        log?.buttonDragged.append(p)
        log?.buttonDragFlags.append(UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
        print("[BUTTON] dragged at content=(\(Int(p.x)),\(Int(p.y)))")
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isAux else { return }
        let p = contentPoint(event)
        log?.buttonRightDown.append(p)
        print("[BUTTON] right-down at content=(\(Int(p.x)),\(Int(p.y)))")
    }

    override func rightMouseUp(with event: NSEvent) {}
}

final class BackgroundView: NSView {
    var log: EventLog?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func contentPoint(_ event: NSEvent) -> NSPoint {
        superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
    }

    override func mouseDown(with event: NSEvent) {
        let p = contentPoint(event)
        log?.backgroundDown.append(p)
        print("[BG] down at content=(\(Int(p.x)),\(Int(p.y)))")
    }

    override func mouseUp(with event: NSEvent) {
        let p = contentPoint(event)
        log?.backgroundUp.append(p)
        print("[BG] up at content=(\(Int(p.x)),\(Int(p.y)))")
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
}

final class TestWindow: NSWindow {
    static let contentSize = NSSize(width: 640, height: 360)
    static let defaultOrigin = NSPoint(x: 320, y: 520)

    let eventLog = EventLog()
    let button = AssistButton()
    let background = BackgroundView()
    /// Auxiliary AX-actionable controls used by the P1 cases.
    let decoy = AssistButton()
    let ambL = AssistButton()
    let ambR = AssistButton()
    /// P3 gesture surfaces and their event logs.
    let sliderLog = EventLog()
    let scrollLog = EventLog()
    let textLog = EventLog()
    var p3Slider: P3Slider?
    var p3Scrollbar: P3Slider?
    var p3Text: P3TextView?

    init(origin: NSPoint = TestWindow.defaultOrigin) {
        super.init(contentRect: NSRect(origin: origin, size: TestWindow.contentSize),
                   styleMask: [.titled, .closable],
                   backing: .buffered,
                   defer: false)
        title = "ClickAssistProto — isolated target"
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        level = .floating

        let content = NSView(frame: NSRect(origin: .zero, size: TestWindow.contentSize))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView = content

        background.frame = content.bounds
        background.autoresizingMask = [.width, .height]
        background.log = eventLog
        content.addSubview(background)

        // The P0 target: near-miss probes at +9 pt on the right edge.
        button.frame = NSRect(x: 240, y: 140, width: 120, height: 60)
        button.title = "Assist Target"
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("assistButton")
        button.log = eventLog
        content.addSubview(button)

        // Gate 4: an actionable neighbour whose boundary is 2 pt from the direct-hit
        // probe, while the probe itself is inside `button`.
        decoy.frame = NSRect(x: 300, y: 196, width: 50, height: 30)
        decoy.title = "Decoy"
        decoy.bezelStyle = .rounded
        decoy.setAccessibilityIdentifier("decoyButton")
        decoy.isAux = true
        decoy.log = eventLog
        content.addSubview(decoy)

        // Gate 5: two equal-score candidates 20 pt apart (probe sits in the middle).
        ambL.frame = NSRect(x: 150, y: 60, width: 55, height: 40)
        ambL.title = "Ambig L"
        ambL.bezelStyle = .rounded
        ambL.setAccessibilityIdentifier("ambigLeft")
        ambL.isAux = true
        ambL.log = eventLog

        ambR.frame = NSRect(x: 213, y: 60, width: 55, height: 40)
        ambR.title = "Ambig R"
        ambR.bezelStyle = .rounded
        ambR.setAccessibilityIdentifier("ambigRight")
        ambR.isAux = true
        ambR.log = eventLog
        content.addSubview(ambL)
        content.addSubview(ambR)

        // P3 gesture surfaces: analog + text controls (right column, clear of all probe points).
    let p3Slider = P3Slider(frame: NSRect(x: 400, y: 280, width: 200, height: 24))
    p3Slider.minValue = 0
    p3Slider.maxValue = 100
    p3Slider.doubleValue = 30
    p3Slider.isContinuous = true
    p3Slider.setAccessibilityIdentifier("assistSlider")
    p3Slider.sliderLog = sliderLog
    content.addSubview(p3Slider)
    self.p3Slider = p3Slider

    // Scrollbar analog: a VERTICAL slider (NSScroller redirected presses clamp to its
    // 2 px bevel — a dead hit zone — so the track/knob drag semantics are proven here).
    let p3Scrollbar = P3Slider(frame: NSRect(x: 420, y: 80, width: 16, height: 120))
    p3Scrollbar.minValue = 0
    p3Scrollbar.maxValue = 1
    p3Scrollbar.doubleValue = 0.5
    p3Scrollbar.isContinuous = true
    p3Scrollbar.setAccessibilityIdentifier("assistScrollbar")
    p3Scrollbar.sliderLog = scrollLog
    content.addSubview(p3Scrollbar)
    self.p3Scrollbar = p3Scrollbar

    let p3Text = P3TextView(frame: NSRect(x: 400, y: 230, width: 200, height: 40))
    p3Text.string = "ClickAssist drag-selection surface text"
    p3Text.isEditable = false
    p3Text.isSelectable = true
    p3Text.drawsBackground = false
    p3Text.setAccessibilityIdentifier("assistTextField")
    p3Text.textLog = textLog
    content.addSubview(p3Text)
    self.p3Text = p3Text

    let hint = NSTextField(labelWithString: "button=(240,140,120,60)  decoy=(300,196,50,30)  ambig=(150|213,60,55,40)  tol=12")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 10, width: 600, height: 14)
        content.addSubview(hint)
    }

    /// Button rect in CGEvent global display coordinates (what the tap operates on).
    func buttonTarget(name: String = "assistButton", inset: CGFloat = 4) -> AssistTarget {
        let r = cgRect(forContentRect: button.frame)
        return AssistTarget(name: name, rect: r, inset: inset)
    }

    /// Content-view point -> Cocoa screen point -> CGEvent point.
    func cgPoint(forContentPoint p: NSPoint) -> CGPoint {
        let inWindow = contentView!.convert(p, to: nil)
        let onScreen = convertPoint(toScreen: inWindow)
        return ScreenSpace.cgPoint(fromCocoaScreen: onScreen)
    }

    /// Content-view rect -> global display rect (same convention as AXPosition).
    func cgRect(forContentRect r: NSRect) -> CGRect {
        let a = cgPoint(forContentPoint: NSPoint(x: r.minX, y: r.minY))
        let b = cgPoint(forContentPoint: NSPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

extension TestWindow {
    /// Global display point -> content-view point (inverse of cgPoint(forContentPoint:)).
    func contentPoint(forCGPoint p: CGPoint) -> NSPoint {
        let cocoaScreen = NSPoint(x: p.x, y: ScreenSpace.mainHeight - p.y)
        let inWindow = convertPoint(fromScreen: cocoaScreen)
        return contentView!.convert(inWindow, from: nil)
    }
}


// MARK: - P3 gesture-surface controls (log delivered events, then run NATIVE tracking)
// NOTE: super.mouseDown enters AppKit tracking loops that block the main thread until
// mouse-up; the selftest posts these gesture sequences from a background queue.

final class P3Slider: NSSlider {
    var sliderLog: EventLog?
    private func cp(_ e: NSEvent) -> NSPoint {
        superview?.convert(e.locationInWindow, from: nil) ?? .zero
    }
    override func mouseDown(with e: NSEvent) {
        sliderLog?.buttonDown.append(cp(e))
        sliderLog?.buttonDownFlags.append(UInt64(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
        super.mouseDown(with: e)
    }
    override func mouseDragged(with e: NSEvent) {
        sliderLog?.buttonDragged.append(cp(e))
        sliderLog?.buttonDragFlags.append(UInt64(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
        super.mouseDragged(with: e)
    }
    override func mouseUp(with e: NSEvent) {
        sliderLog?.buttonUp.append(cp(e))
        super.mouseUp(with: e)
    }
}

final class P3TextView: NSTextView {
    var textLog: EventLog?
    private func cp(_ e: NSEvent) -> NSPoint {
        superview?.convert(e.locationInWindow, from: nil) ?? .zero
    }
    override func mouseDown(with e: NSEvent) {
        textLog?.buttonDown.append(cp(e))
        super.mouseDown(with: e)
    }
    override func mouseDragged(with e: NSEvent) {
        textLog?.buttonDragged.append(cp(e))
        super.mouseDragged(with: e)
    }
    override func mouseUp(with e: NSEvent) {
        textLog?.buttonUp.append(cp(e))
        super.mouseUp(with: e)
    }
}

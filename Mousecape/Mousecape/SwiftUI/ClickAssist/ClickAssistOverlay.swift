// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit
import CoreGraphics

/// Borderless transparent panel that can NEVER become key/main and NEVER receives
/// mouse events (window-server level `ignoresMouseEvents`). Pure drawing surface.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws, in global display coordinates: the AX frame (solid), the effective
/// tolerance ring OUTSIDE the AX frame (dashed), and the real-cursor marker.
final class OverlayView: NSView {
    var cgFrame = CGRect.zero            // AX frame, global display coords
    var cgPanelTopLeft = CGPoint.zero    // panel's top-left in global display coords
    var cgPointer = CGPoint.zero         // real cursor position
    var tolerance: CGFloat = 12
    var mode = "redirect"
    var isBlank = true

    override var isFlipped: Bool { true }

    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - cgPanelTopLeft.x, y: p.y - cgPanelTopLeft.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Effective tolerance region: dashed ring outside the AX frame.
        let ring = cgFrame.insetBy(dx: -tolerance, dy: -tolerance)
        let ringRect = CGRect(x: local(ring.origin).x, y: local(ring.origin).y,
                              width: ring.width, height: ring.height)
        let ringPath = NSBezierPath(roundedRect: ringRect, xRadius: tolerance, yRadius: tolerance)
        ringPath.lineWidth = 1.5
        NSColor.systemOrange.setStroke()
        ringPath.setLineDash([6, 4], count: 2, phase: 0)
        ringPath.stroke()
        // AX frame: solid.
        let f = CGRect(origin: local(cgFrame.origin), size: cgFrame.size)
        let framePath = NSBezierPath(rect: f)
        framePath.lineWidth = 2
        (mode == "direct-hit" ? NSColor.systemGreen : NSColor.systemBlue).setStroke()
        framePath.stroke()
        // Pointer marker at the REAL cursor position (never moved by us).
        let p = local(cgPointer)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: p.x - 9, y: p.y)); cross.line(to: CGPoint(x: p.x + 9, y: p.y))
        cross.move(to: CGPoint(x: p.x, y: p.y - 9)); cross.line(to: CGPoint(x: p.x, y: p.y + 9))
        NSColor.systemRed.setStroke()
        cross.lineWidth = 1
        cross.stroke()
    }
}

/// P2a debugging instrument: a pure observer of published decision snapshots.
/// Zero targeting math of its own — every render is DecisionCore.route() applied to
/// the exact immutable CacheSnapshot the tap router also reads. Invalid, ambiguous
/// or stale states render NO highlight. Death of this object cannot reach the tap:
/// the tap only ever reads CacheStore.current().
@MainActor
final class TargetingOverlay {
    private var tolerance: CGFloat
    private let log: (String) -> Void
    private var panel: OverlayPanel?
    private var view: OverlayView?
    private var dead = false
    private var lastSig = ""

    init(tolerance: CGFloat, log: @escaping (String) -> Void) {
        self.tolerance = tolerance
        self.log = log
    }

    func setTolerance(_ v: CGFloat) {
        tolerance = AssistTap.clampTolerance(v)
    }

    /// Called by CacheStore after each publish, on the resolver thread, with the SAME
    /// immutable snapshot struct the router consumes. Hops to main; never blocks.
    nonisolated func observe(_ s: CacheSnapshot) {
        Task { @MainActor [weak self] in self?.render(s) }
    }

    /// Gate 5: kill the instrument. The tap pipeline holds no reference to this path.
    func kill() {
        dead = true
        if let panel { panel.orderOut(nil); panel.contentView = nil }
        panel = nil
        view = nil
        log("OVERLAY_DEAD action=observer-dead taps-unaffected=true")
    }

    /// Gate 6 evidence: non-interactivity flags of the live panel (main thread only).
    func nonInteractiveFlags() -> String? {
        guard !dead, let p = panel, p.isVisible else { return nil }
        return "ignoresMouseEvents=\(p.ignoresMouseEvents) canBecomeKey=\(p.canBecomeKey) " +
               "canBecomeMain=\(p.canBecomeMain) level=\(p.level.rawValue)"
    }

    // MARK: - render (main thread)

    private func render(_ s: CacheSnapshot) {
        guard !dead else { return }
        let ageMs = (CACurrentMediaTime() - s.stamp) * 1000
        let fresh = s.valid && ageMs <= DecisionCore.cacheMaxAge * 1000
        let pointer = CGEvent(source: nil)?.location ?? .zero
        var action = "none"
        var reason = s.valid ? String(format: "stale:age(%.0fms)", ageMs) : s.reason
        var targetKey: String?
        var frame: CGRect?
        var mode = "redirect"
        if fresh {
            let cands = s.targets.map { DecisionCore.Candidate(key: $0.key, rect: $0.rect, inset: $0.inset) }
            switch DecisionCore.route(point: pointer, candidates: cands, tolerance: tolerance) {
            case .redirect(let c, _, _):
                action = "show"; targetKey = c.key; frame = c.rect; reason = "redirect"
            case .directHit(let c, _):
                action = "show"; targetKey = c.key; frame = c.rect; reason = "direct-hit"; mode = "direct-hit"
            case .ambiguous:
                reason = "ambiguous"
            case .noCandidate:
                reason = "no-candidate-in-radius"
            }
        }
        let sig = "\(s.generation)|\(action)|\(targetKey ?? "-")|\(reason)"
        if sig != lastSig {
            lastSig = sig
            if action == "show", let targetKey, let frame {
                log(String(format: "OVERLAY_STATE gen=%llu action=show target=%@ frame=(%.1f,%.1f,%.1f,%.1f) tol=%.1f pointer=(%.1f,%.1f) reason=%@ mode=%@",
                           s.generation, targetKey as NSString, frame.origin.x, frame.origin.y, frame.width, frame.height,
                           tolerance, pointer.x, pointer.y, reason as NSString, mode as NSString))
            } else {
                log(String(format: "OVERLAY_STATE gen=%llu action=none pointer=(%.1f,%.1f) reason=%@",
                           s.generation, pointer.x, pointer.y, reason as NSString))
            }
        }
        draw(action: action, frame: frame, pointer: pointer, mode: mode)
    }

    private func draw(action: String, frame: CGRect?, pointer: CGPoint, mode: String) {
        guard action == "show", let frame else {
            // NO target highlight: keep the (click-through) panel but draw nothing.
            // Ordering it out would fire AX uielementdestroyed events and invalidate
            // the very snapshot stream this instrument observes.
            view?.isBlank = true
            view?.needsDisplay = true
            return
        }
        let margin = tolerance + 14
        let cgPanel = frame.insetBy(dx: -margin, dy: -margin)
        let cocoa = NSRect(x: cgPanel.minX, y: ScreenSpace.mainHeight - cgPanel.maxY,
                           width: cgPanel.width, height: cgPanel.height)
        if panel == nil {
            let p = OverlayPanel(contentRect: cocoa, styleMask: .borderless, backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true       // window-server level: never receives mouse events
            p.acceptsMouseMovedEvents = false
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            let v = OverlayView(frame: NSRect(origin: .zero, size: cocoa.size))
            v.wantsLayer = true
            p.contentView = v
            panel = p
            view = v
        }
        guard let panel, let view else { return }
        if panel.frame != cocoa { panel.setFrame(cocoa, display: false) }   // AX-churn guard
        view.cgFrame = frame
        view.cgPanelTopLeft = CGPoint(x: cgPanel.minX, y: cgPanel.minY)
        view.cgPointer = pointer
        view.tolerance = tolerance
        view.mode = mode
        view.isBlank = false
        view.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }   // never activates, never keys
    }
}

// MARK: - Screen space conversion (shared by resolver / tap / overlay)

/// Coordinate conversions: Cocoa screen space (origin bottom-left of main display,
/// y up) <-> CGEvent/AX global display space (origin top-left of main display, y down).
enum ScreenSpace {
    static var mainHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func cgPoint(fromCocoaScreen p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: mainHeight - p.y)
    }

    static func cgRect(fromCocoaScreen r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    static func fmt(_ p: CGPoint) -> String { String(format: "(%.1f,%.1f)", p.x, p.y) }
    static func fmt(_ v: CGVector) -> String { String(format: "(%.1f,%.1f)", v.dx, v.dy) }
}

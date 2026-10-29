// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit
import ApplicationServices
import CoreGraphics

/// Borderless transparent panel that can NEVER become key/main and NEVER receives
/// mouse events (window-server level `ignoresMouseEvents`). Pure drawing surface.
final class OverlayPanel: NSPanel {
    /// The targeting ring must be the topmost non-interactive layer: above NSMenu
    /// windows (`.popUpMenu` = 101), above `.screenSaver` (1000), and above custom
    /// high-level panels that apps like BetterDisplay draw their dropdown in (raw
    /// 2000 chosen for that headroom). Visibility only — click-through comes from
    /// `ignoresMouseEvents`, which the window server honours at every level.
    static let targetWindowLevel = NSWindow.Level(rawValue: 2000)
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
        // Blank means PIXELS blank, not just state blank. The clear path sets
        // isBlank=true + needsDisplay, and this guard erases the previously
        // drawn ring/frame/pointer with a copy-mode clear instead of re-stroking
        // the stale stored geometry.
        guard !isBlank else {
            NSColor.clear.setFill()
            dirtyRect.fill(using: .copy)
            return
        }
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

    /// Latest immutable snapshot the tap router also reads. Kept only to re-run
    /// the same pure route against the LIVE pointer between snapshot publishes.
    private var latestSnapshot: CacheSnapshot?
    /// Pointer sampling cadence (~30 Hz): visually attached to the real cursor,
    /// but each tick is just one pure DecisionCore.route() plus a few rect draws.
    private static let repaintInterval: TimeInterval = 0.033
    private var repaintTimer: Timer?

    private var lastDrawnAction = ""
    private var lastDrawnFrame: CGRect?
    private var lastDrawnPointer = CGPoint(x: CGFloat.greatestFiniteMagnitude,
                                           y: CGFloat.greatestFiniteMagnitude)
    private var lastDrawnMode = ""
    private var lastDrawnTolerance: CGFloat = -1
    /// Ghost-ring suppression: per-target visibility verdict from the app's own
    /// AX hit-test, cached briefly so the 30 Hz repaint does not issue an AX call
    /// every tick (≈ one hit-test per 0.5 s per target key).
    private enum GhostVerdict {
        case visible
        case ghost
    }
    private struct VisibilityVerdict {
        let verdict: GhostVerdict
        let stamp: CFTimeInterval
    }
    private var visibilityCache: [String: VisibilityVerdict] = [:]
    private var lastGhostLog: [String: CFTimeInterval] = [:]
    private static let visibilityTTL: CFTimeInterval = 0.5
    private static let ghostLogInterval: CFTimeInterval = 5

    init(tolerance: CGFloat, log: @escaping (String) -> Void) {
        self.tolerance = tolerance
        self.log = log
        // The overlay's state is a pure function of (latest snapshot, live pointer).
        // Snapshot publishes are sparse; this timer samples the pointer so the ring
        // tracks it and clears promptly when no candidate applies.
        repaintTimer = Timer.scheduledTimer(withTimeInterval: Self.repaintInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.repaintFromLivePointer() }
        }
    }

    func setTolerance(_ v: CGFloat) {
        tolerance = AssistTap.clampTolerance(v)
    }

    /// Called by CacheStore after each publish, on the resolver thread, with the SAME
    /// immutable snapshot struct the router consumes. Hops to main; never blocks.
    nonisolated func observe(_ s: CacheSnapshot) {
        Task { @MainActor [weak self] in
            self?.latestSnapshot = s
            self?.render(s)
        }
    }

    /// Re-evaluate the LATEST snapshot against the current pointer. No AX calls,
    /// no snapshot copy, no event-tap work — display-only.
    private func repaintFromLivePointer() {
        guard !dead, let snapshot = latestSnapshot else { return }
        render(snapshot)
    }

    /// Gate 5: kill the instrument. The tap pipeline holds no reference to this path.
    func kill() {
        dead = true
        repaintTimer?.invalidate()
        repaintTimer = nil
        latestSnapshot = nil
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
            let cands = s.targets.map { DecisionCore.Candidate(key: $0.key, rect: $0.rect,
                                                               inset: $0.inset, tier: $0.tier,
                                                               role: $0.role) }
            switch DecisionCore.route(point: pointer, candidates: cands, tolerance: tolerance) {
            case .redirect(let c, _, _, _, _):
                action = "show"; targetKey = c.key; frame = c.rect; reason = "redirect"
            case .directHit(let c, _):
                if c.tier == .secondClass {
                    // A second-class container under the pointer is NOT a
                    // guaranteed target: render no highlight (neutral preview
                    // only; the router may still rescue a first-class near-miss).
                    reason = "second-class-direct-hit"
                } else {
                    action = "show"; targetKey = c.key; frame = c.rect; reason = "direct-hit"; mode = "direct-hit"
                }
            case .ambiguous:
                reason = "ambiguous"
            case .noCandidate:
                reason = "no-candidate-in-radius"
            }
        }
        // GHOST-RING GATE (display only — never touches the tap's click path).
        // Chromium exposes faded-out / opacity-0 elements through AX with no
        // visibility flag. Its own AX hit-test only returns VISIBLE elements, so
        // cross-check the target's center: a definitive hit whose frame does not
        // contain that center means the element is invisible. Errors, nil and
        // frameless results PASS (the hit-test is advisory and intermittently
        // flakes). Mutations are unaffected: the click still redirects to the
        // cached element.
        var ghostKey: String?
        if action == "show", let key = targetKey, let rect = frame, fresh,
           !isVisibleNow(pid: s.pid, key: key, rect: rect) {
            ghostKey = key
            action = "none"
            reason = "ghost-suppressed"
            targetKey = nil
            frame = nil
        }
        if let ghostKey {
            // Rate-limited: one ghost line per target key per 5 s.
            let now = CACurrentMediaTime()
            if now - (lastGhostLog[ghostKey] ?? -Double.infinity) >= Self.ghostLogInterval {
                lastGhostLog[ghostKey] = now
                log(String(format: "OVERLAY_STATE gen=%llu action=none target=%@ pointer=(%.1f,%.1f) reason=ghost-suppressed",
                           s.generation, ghostKey as NSString, pointer.x, pointer.y))
            }
            // Force a fresh "show" line when the element becomes visible again.
            lastSig = "\(s.generation)|none|ghost|\(ghostKey)"
            draw(action: action, frame: frame, pointer: pointer, mode: mode)
            return
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

    /// Advisory visibility check via the app's own AX hit-test at the candidate
    /// center. Returns false ONLY on a definitive mismatch. Errors/nil pass.
    /// Called on the main actor; a 0.1 s messaging timeout bounds the cost.
    ///
    /// v2: containment alone is not enough. An INVISIBLE element inside a
    /// visible container (Brave tab slots, hidden close buttons, "search tabs"
    /// anchors) hit-tests to the visible strip, whose frame still contains the
    /// candidate center. The renderer's answer is the ASPECT that matters:
    /// - hit frame strictly INSIDE the candidate frame → a descendant was hit → real, show.
    /// - candidate frame strictly INSIDE the hit frame → only an ancestor (bare
    ///   container) responded → nothing actionable there → ghost, suppress.
    /// - same/equal frames or partial overlap → the candidate itself or an
    ///   unrelated sibling → fall back to v1 containment (show).
    private func isVisibleNow(pid: pid_t, key: String, rect: CGRect) -> Bool {
        let now = CACurrentMediaTime()
        // Cache key includes the verdict type's geometry (center) so a moved
        // candidate never reuses a verdict computed for another rect.
        let cacheKey = "\(key)|\(Int(rect.midX))|\(Int(rect.midY))"
        if let cached = visibilityCache[cacheKey], now - cached.stamp < Self.visibilityTTL {
            return cached.verdict == .visible
        }
        guard pid > 0, pid != getpid(), rect.width > 0, rect.height > 0 else { return true }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var element: AXUIElement?
        // Flaky rule: any error or nil element means "cannot judge" → pass.
        guard AXUIElementCopyElementAtPosition(app, Float(center.x), Float(center.y),
                                               &element) == .success,
              let element else {
            visibilityCache[cacheKey] = VisibilityVerdict(verdict: .visible, stamp: now)
            return true
        }
        guard let hitFrame = axFrame(element) else {
            visibilityCache[cacheKey] = VisibilityVerdict(verdict: .visible, stamp: now)
            return true
        }
        let verdict: GhostVerdict
        if !hitFrame.contains(center) {
            // v1: the renderer placed something whose frame excludes the point.
            verdict = .ghost
        } else if Self.strictlyContains(hitFrame, rect) {
            // Only an ancestor/container answered. That is a ghost ONLY when the
            // container has no ACTIONABLE child at this point either: a tab's
            // close ✕ hit-tests to the tab group (its close button is a child
            // that covers the same point), so a genuinely clickable control must
            // still ring. Empty strip slots / hidden anchors have no actionable
            // descendant at the center and stay suppressed.
            verdict = Self.hasActionableDescendant(hit: element, center: center) ? .visible : .ghost
        } else {
            // Candidate itself, a descendant, or a sibling at the point: show.
            verdict = .visible
        }
        visibilityCache[cacheKey] = VisibilityVerdict(verdict: verdict, stamp: now)
        return verdict == .visible
    }

    /// `outer` fully encloses `inner` with at least `margin` on every side —
    /// distinguishes an ancestor answer from an equal-frame self answer.
    private static func strictlyContains(_ outer: CGRect, _ inner: CGRect,
                                         margin: CGFloat = 0.5) -> Bool {
        outer.minX <= inner.minX - margin && outer.maxX >= inner.maxX + margin &&
        outer.minY <= inner.minY - margin && outer.maxY >= inner.maxY + margin
    }

    /// Roles that accept a click. Mirrors the resolver's first-class set; kept
    /// local so the display path needs no shared state.
    private static let actionableRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXLink", "AXCheckBox", "AXRadioButton",
        "AXMenuItem", "AXMenuBarItem", "AXPopUpButton", "AXComboBox", "AXTab",
        "AXSegmentedControl", "AXSlider", "AXDisclosureTriangle",
        "AXTextField", "AXSearchField", "AXScrollBar", "AXValueIndicator"
    ]

    /// True when `root` or one of its near descendants (≤3 levels) is a control
    /// whose frame contains `center` — i.e. the renderer's container answer still
    /// maps to a real clickable control at that point. Bounded so the 30 Hz path
    /// stays cheap.
    private static func hasActionableDescendant(hit: AXUIElement, center: CGPoint) -> Bool {
        func roleOf(_ el: AXUIElement) -> String {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
            return v as? String ?? ""
        }
        func contains(_ el: AXUIElement) -> Bool {
            var p: CFTypeRef?; var s: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
                  let p, let s else { return false }
            var o = CGPoint.zero; var sz = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &o),
                  AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return false }
            return CGRect(origin: o, size: sz).contains(center)
        }
        if actionableRoles.contains(roleOf(hit)), contains(hit) { return true }
        func search(_ el: AXUIElement, _ depth: Int) -> Bool {
            if depth > 3 { return false }
            var ch: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ch) == .success,
                  let kids = ch as? [AXUIElement] else { return false }
            for k in kids {
                if actionableRoles.contains(roleOf(k)), contains(k) { return true }
                if search(k, depth + 1) { return true }
            }
            return false
        }
        return search(hit, 1)
    }

    /// Frame of an AX element in global top-left coordinates.
    private func axFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func draw(action: String, frame: CGRect?, pointer: CGPoint, mode: String) {
        // Skip redundant redraws: state transitions always paint; pointer moves
        // only matter while a highlight is shown. This keeps the 30 Hz sampling
        // nearly free when the ring is static or blank.
        let stateChanged = action != lastDrawnAction || frame != lastDrawnFrame
            || mode != lastDrawnMode || tolerance != lastDrawnTolerance
        let pointerChanged = pointer != lastDrawnPointer
        guard stateChanged || (action == "show" && pointerChanged) else { return }
        lastDrawnAction = action
        lastDrawnFrame = frame
        lastDrawnMode = mode
        lastDrawnPointer = pointer
        lastDrawnTolerance = tolerance

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
            p.level = OverlayPanel.targetWindowLevel
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

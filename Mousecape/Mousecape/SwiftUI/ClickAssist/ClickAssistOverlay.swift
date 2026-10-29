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
    var cgSecondaryFrame: CGRect?        // second confirmed target, subdued ring
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
        // Secondary target: thinner, dimmed green — never obscures the primary.
        if let sec = cgSecondaryFrame {
            let sf = CGRect(origin: local(sec.origin), size: sec.size)
            let secPath = NSBezierPath(rect: sf)
            secPath.lineWidth = 1
            NSColor.systemGreen.withAlphaComponent(0.45).setStroke()
            secPath.stroke()
        }
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
    private var lastDrawnSecondary: CGRect?
    private var lastDrawnPointer = CGPoint(x: CGFloat.greatestFiniteMagnitude,
                                           y: CGFloat.greatestFiniteMagnitude)
    private var lastDrawnMode = ""
    private var lastDrawnTolerance: CGFloat = -1
    /// The ONE legitimacy policy, shared with the tap. The overlay carries no
    /// visibility heuristics of its own: a ring is drawn only when the renderer
    /// confirms the destination point.
    var legitimacy: LegitimacyPolicy?
    private var lastSuppressLog: [String: CFTimeInterval] = [:]
    private static let suppressLogInterval: CFTimeInterval = 5

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
        var primary: (key: String, rect: CGRect, dest: CGPoint, dist: CGFloat, direct: Bool, tier: Int)?
        var secondary: (key: String, rect: CGRect, tier: Int)?
        var confirmedCount = 0
        var suppressed: (key: String, verdict: LegitimacyPolicy.Verdict)?
        if fresh {
            let cands = s.targets.map { DecisionCore.Candidate(key: $0.key, rect: $0.rect,
                                                               inset: $0.inset, tier: $0.tier,
                                                               role: $0.role) }
            // Up to three nearest in-tolerance first-class candidates, validated
            // at their own destination points (fail-closed). Every confirmed one
            // is indicated; the nearest wins the click.
            let scored = DecisionCore.displayCandidates(point: pointer, candidates: cands,
                                                        tolerance: tolerance, limit: 3)
            var confirmed: [(DecisionCore.ScoredCandidate, CGPoint)] = []
            for choice in scored {
                let snap = DecisionCore.snapMode(for: choice.candidate)
                let dest = snap == .center
                    ? DecisionCore.centerPoint(into: choice.candidate.rect)
                    : DecisionCore.clampPoint(pointer, into: choice.candidate.rect,
                                              inset: choice.candidate.inset)
                let verdict = legitimacy?.validate(
                    pid: s.pid, generation: s.generation, key: choice.candidate.key,
                    candidate: choice.candidate.rect, destination: dest,
                    siblings: cands.filter { $0.key != choice.candidate.key && $0.tier == .firstClass }
                                   .map { $0.rect }) ?? .confirmed
                if verdict == .confirmed {
                    confirmed.append((choice, dest))
                } else if suppressed == nil {
                    suppressed = (choice.candidate.key, verdict)
                }
            }
            confirmedCount = confirmed.count
            if let winner = confirmed.first {
                primary = (winner.0.candidate.key, winner.0.candidate.rect, winner.1,
                           winner.0.dist, winner.0.dist == 0,
                           winner.0.candidate.tier == .firstClass ? 1 : 2)
                action = "show"
                reason = winner.0.dist == 0 ? "direct-hit" : "redirect"
                if confirmed.count > 1 {
                    secondary = (confirmed[1].0.candidate.key, confirmed[1].0.candidate.rect,
                                 confirmed[1].0.candidate.tier == .firstClass ? 1 : 2)
                }
            } else if let suppressed {
                reason = "legitimacy-\(suppressed.verdict.rawValue)"
            } else {
                reason = "no-candidate-in-radius"
            }
        }
        // Fail-closed suppression log (rate-limited, additive format).
        if action == "none", let suppressed {
            let now = CACurrentMediaTime()
            if now - (lastSuppressLog[suppressed.key] ?? -Double.infinity) >= Self.suppressLogInterval {
                lastSuppressLog[suppressed.key] = now
                log(String(format: "OVERLAY_STATE gen=%llu action=none target=%@ pointer=(%.1f,%.1f) reason=%@ legitimacy=%@",
                           s.generation, suppressed.key as NSString, pointer.x, pointer.y,
                           reason as NSString, suppressed.verdict.rawValue as NSString))
            }
            lastSig = "\(s.generation)|none|legitimacy|\(suppressed.key)"
            draw(action: action, frame: nil, secondary: nil, pointer: pointer, mode: "redirect")
            return
        }
        let sig = "\(s.generation)|\(action)|\(primary?.key ?? "-")|\(secondary?.key ?? "-")|\(confirmedCount)|\(reason)"
        if sig != lastSig {
            lastSig = sig
            if action == "show", let primary {
                log(String(format: "OVERLAY_STATE gen=%llu action=show target=%@ frame=(%.1f,%.1f,%.1f,%.1f) tol=%.1f pointer=(%.1f,%.1f) reason=%@ mode=%@ legitimacy=confirmed tier=%d cands=%d winner=1",
                           s.generation, primary.key as NSString, primary.rect.origin.x, primary.rect.origin.y,
                           primary.rect.width, primary.rect.height, tolerance, pointer.x, pointer.y,
                           reason as NSString, (primary.direct ? "direct-hit" : "redirect") as NSString,
                           primary.tier, confirmedCount))
                if let secondary {
                    log(String(format: "OVERLAY_STATE gen=%llu action=show target=%@ frame=(%.1f,%.1f,%.1f,%.1f) tol=%.1f pointer=(%.1f,%.1f) reason=secondary mode=secondary legitimacy=confirmed tier=%d cands=%d winner=2",
                               s.generation, secondary.key as NSString, secondary.rect.origin.x, secondary.rect.origin.y,
                               secondary.rect.width, secondary.rect.height, tolerance, pointer.x, pointer.y,
                               secondary.tier, confirmedCount))
                }
            } else {
                log(String(format: "OVERLAY_STATE gen=%llu action=none pointer=(%.1f,%.1f) reason=%@",
                           s.generation, pointer.x, pointer.y, reason as NSString))
            }
        }
        draw(action: action, frame: primary?.rect, secondary: secondary?.rect,
             pointer: pointer, mode: primary?.direct == true ? "direct-hit" : "redirect")
    }

    private func draw(action: String, frame: CGRect?, secondary: CGRect?, pointer: CGPoint, mode: String) {
        // Skip redundant redraws: state transitions always paint; pointer moves
        // only matter while a highlight is shown. This keeps the 30 Hz sampling
        // nearly free when the ring is static or blank.
        let stateChanged = action != lastDrawnAction || frame != lastDrawnFrame
            || secondary != lastDrawnSecondary || mode != lastDrawnMode || tolerance != lastDrawnTolerance
        let pointerChanged = pointer != lastDrawnPointer
        guard stateChanged || (action == "show" && pointerChanged) else { return }
        lastDrawnAction = action
        lastDrawnFrame = frame
        lastDrawnSecondary = secondary
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
        var cgPanel = frame.insetBy(dx: -margin, dy: -margin)
        if let secondary { cgPanel = cgPanel.union(secondary.insetBy(dx: -margin, dy: -margin)) }
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
        view.cgSecondaryFrame = secondary
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

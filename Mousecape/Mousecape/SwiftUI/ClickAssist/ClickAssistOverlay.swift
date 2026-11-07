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
    var primaryDim = false               // unnamed candidate: visually demoted (weak ghost signal)
    var cgSecondaryFrame: CGRect?        // second confirmed target, subdued ring
    var cgPanelTopLeft = CGPoint.zero    // panel's top-left in global display coords
    var cgPointer = CGPoint.zero         // real cursor position
    var tolerance: CGFloat = 12
    var mode = "redirect"
    var isBlank = true
    /// Until this time the target rect is filled: the click was captured and is
    /// being delivered (activation settle), so the user sees it registered.
    var ackUntil: CFTimeInterval = 0

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
        let localFrame = CGRect(origin: local(cgFrame.origin), size: cgFrame.size)
        let ringPath = NSBezierPath(cgPath: DecisionCore.toleranceOutline(
            rect: localFrame, tolerance: tolerance))
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
        framePath.lineWidth = primaryDim ? 1 : 2
        (mode == "direct-hit" ? NSColor.systemGreen : NSColor.systemBlue).setStroke()
        framePath.stroke()
        if CACurrentMediaTime() < ackUntil {
            NSColor.systemGreen.withAlphaComponent(0.3).setFill()
            framePath.fill()
        }
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
    private var dragPause = RingDragPause()
    private var unknownHold = RingUnknownHold()
    private var heldPrimary: (key: String, rect: CGRect, dest: CGPoint, dist: CGFloat, direct: Bool,
                              tier: Int, named: Bool, weakVerdict: Bool)?
    /// Pointer sampling cadence (~60 Hz): visually attached to the real cursor,
    /// but each tick is just one pure DecisionCore.route() plus a few rect draws.
    private static let repaintInterval: TimeInterval = 0.016
    private var repaintTimer: Timer?
    // Bounded diagnostics for actual main-thread timer delivery and render work.
    // These measure scheduling/CPU work, not display scanout or frame presentation.
    private var redrawSampleStart: CFTimeInterval = 0
    private var redrawPreviousTick: CFTimeInterval = 0
    private var redrawIntervals = 0
    private var redrawIntervalTotal: Double = 0
    private var redrawIntervalMax: Double = 0
    private var redrawWorkTotal: Double = 0
    private var redrawWorkMax: Double = 0

    private var lastDrawnAction = ""
    private var lastDrawnFrame: CGRect?
    private var lastDrawnSecondary: CGRect?
    private var lastDrawnPointer = CGPoint(x: CGFloat.greatestFiniteMagnitude,
                                           y: CGFloat.greatestFiniteMagnitude)
    private var lastDrawnMode = ""
    private var lastDrawnTolerance: CGFloat = -1
    private var lastDrawnDim: Bool = false
    private var lastSuppressLog: [String: CFTimeInterval] = [:]
    private static let suppressLogInterval: CFTimeInterval = 5
    /// Diagnostic RING_CANDS: radius (pt) and max entries of targets listed.
    private static let diagNearRadius: CGFloat = 80
    private static let diagNearMax = 6

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

    /// A background click was captured: fill the ring for the delivery window so
    /// the user can tell the click registered while activation settles.
    func acknowledgeClick() {
        guard let view, !view.isBlank else { return }
        view.ackUntil = CACurrentMediaTime() + BackgroundClickPolicy.clickAckDuration
        view.needsDisplay = true
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
        let started = CACurrentMediaTime()
        render(snapshot)
        let work = CACurrentMediaTime() - started
        if redrawPreviousTick > 0 {
            let interval = started - redrawPreviousTick
            redrawIntervals += 1
            redrawIntervalTotal += interval
            redrawIntervalMax = max(redrawIntervalMax, interval)
            redrawWorkTotal += work
            redrawWorkMax = max(redrawWorkMax, work)
        } else {
            redrawSampleStart = started
        }
        redrawPreviousTick = started
        if started - redrawSampleStart >= 5, redrawIntervals > 0 {
            log(String(format: "OVERLAY_REDRAW_STATS configured_ms=%.1f intervals=%d mean_interval_ms=%.2f max_interval_ms=%.2f mean_work_ms=%.3f max_work_ms=%.3f",
                Self.repaintInterval * 1000, redrawIntervals,
                redrawIntervalTotal * 1000 / Double(redrawIntervals), redrawIntervalMax * 1000,
                redrawWorkTotal * 1000 / Double(redrawIntervals), redrawWorkMax * 1000))
            redrawSampleStart = started
            redrawIntervals = 0
            redrawIntervalTotal = 0
            redrawIntervalMax = 0
            redrawWorkTotal = 0
            redrawWorkMax = 0
        }
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
        publishWindowIDs()
        log("OVERLAY_DEAD action=observer-dead taps-unaffected=true")
    }

    /// Fired on the main actor whenever the set of overlay windows changes
    /// (panel created / torn down). The resolver service excludes exactly these
    /// CGWindowIDs from pointer ownership.
    var onWindowIDsChanged: (([Int]) -> Void)?

    /// CGWindowIDs of every live overlay window (`windowNumber` is the
    /// window-server id; it is > 0 once the window has a device).
    var windowIDs: [Int] {
        [panel].compactMap { $0?.windowNumber }.filter { $0 > 0 }
    }

    private func publishWindowIDs() {
        let ids = windowIDs
        log("OVERLAY_WINDOW_IDS ids=\(ids)")
        onWindowIDsChanged?(ids)
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
        let now = CACurrentMediaTime()
        let ageMs = (now - s.stamp) * 1000
        // Render ONLY from published evidence. Stale/missing evidence (including
        // a snapshot from a replaced service epoch) shows nothing.
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let dragPaused = dragPause.update(leftButtonDown: NSEvent.pressedMouseButtons & 1 != 0,
                                          pointer: pointer, now: now)
        let fresh = s.valid && ageMs <= ClickAssistEvidence.displayMaxAgeMs
            && s.epoch != "" && !dragPaused
        var action = "none"
        var reason = dragPaused ? "paused:drag"
            : (s.valid ? String(format: "stale:age(%.0fms)", ageMs) : s.reason)
        var primary: (key: String, rect: CGRect, dest: CGPoint, dist: CGFloat, direct: Bool, tier: Int, named: Bool, weakVerdict: Bool)?
        var secondary: (key: String, rect: CGRect, tier: Int, named: Bool)?
        var confirmedCount = 0
        var suppressed: (key: String, verdict: ClickAssistVerdict)?
        if fresh {
            let cands = s.targets.map { DecisionCore.Candidate(key: $0.key, rect: $0.rect,
                                                               inset: $0.inset, tier: $0.tier,
                                                               role: $0.role, label: $0.label,
                                                               verdict: $0.verdict,
                                                               chromeEligible: $0.chromeEligible,
                                                               evidenceGeneration: $0.evidenceGeneration,
                                                               collectedAt: $0.collectedAt, windowRect: $0.windowRect) }
            // Indicate only the shared click winner, with fresh confirmation
            // at its delivery point. Never substitute a farther confirmed target.
            let scored = DecisionCore.displayCandidates(point: pointer, candidates: cands,
                                                        tolerance: tolerance, limit: 3)
            var confirmed: [(DecisionCore.ScoredCandidate, CGPoint, ClickAssistVerdict)] = []
            for choice in scored {
                let snap = DecisionCore.snapMode(for: choice.candidate)
                let dest = snap == .center
                    ? DecisionCore.centerPoint(into: choice.candidate.rect)
                    : DecisionCore.clampPoint(pointer, into: choice.candidate.rect,
                                              inset: choice.candidate.inset)
                let evidence = ClickAssistEvidence.displayState(
                    evidenceGeneration: choice.candidate.evidenceGeneration,
                    currentGeneration: s.generation,
                    ageMs: choice.candidate.collectedAt > 0
                        ? (now - choice.candidate.collectedAt) * 1000
                        : ageMs)
                let verdict: ClickAssistVerdict = evidence == .fresh
                    ? choice.candidate.verdict : .unknown
                if verdict == .confirmed {
                    confirmed.append((choice, dest, verdict))
                } else if suppressed == nil {
                    suppressed = (choice.candidate.key, verdict)
                }
            }
            confirmedCount = confirmed.count
            if let winner = confirmed.first {
                let winnerNamed = !winner.0.candidate.label.isEmpty
                let winnerWeak = winner.2 == .confirmedWeak
                primary = (winner.0.candidate.key, winner.0.candidate.rect, winner.1,
                           winner.0.dist, winner.0.dist == 0,
                           winner.0.candidate.tier == .firstClass ? 1 : 2, winnerNamed,
                           winnerWeak)
                action = "show"
                reason = winner.0.dist == 0 ? "direct-hit" : "redirect"
                if confirmed.count > 1 {
                    secondary = (confirmed[1].0.candidate.key, confirmed[1].0.candidate.rect,
                                 confirmed[1].0.candidate.tier == .firstClass ? 1 : 2,
                                 !confirmed[1].0.candidate.label.isEmpty)
                }
            } else if let suppressed {
                reason = "legitimacy-\(suppressed.verdict.rawValue)"
            } else {
                reason = "no-candidate-in-radius"
            }
        }
        // Bridge a brief "unknown" gap on the ring's own target (see RingUnknownHold).
        // Direct hits only, pointer still inside: a held redirect ring would
        // promise a snap the click path may refuse on the same unknown evidence.
        if action == "show", let shown = primary {
            unknownHold.confirmed(key: shown.key, rect: shown.rect, now: now)
            heldPrimary = shown
        } else if let gap = suppressed, gap.verdict == .unknown, let held = heldPrimary,
                  held.direct,
                  unknownHold.holds(unknownKey: gap.key, pointer: pointer,
                                    tolerance: 0, now: now) {
            primary = held
            action = "show"
            reason = RingUnknownHold.reason
            suppressed = nil
        } else {
            unknownHold.reset()
            heldPrimary = nil
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
            // Diagnostics: every snapshot target near the pointer, so a wrong ring
            // can be traced to what the resolver actually published.
            var nearParts: [String] = []
            for t in s.targets {
                let d = DecisionCore.boundaryDistance(pointer, t.rect)
                if d > Self.diagNearRadius || nearParts.count >= Self.diagNearMax { continue }
                let tier = t.tier == .firstClass ? 1 : 2
                let r = t.rect
                let rectText = "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
                nearParts.append("\(t.key)|\(t.role)|t\(tier)|(\(rectText))|\(t.verdict)|d=\(Int(d))")
            }
            let near: [String] = nearParts
            log("RING_CANDS gen=\(s.generation) pointer=(\(Int(pointer.x)),\(Int(pointer.y))) n=\(s.targets.count) near=[\(near.joined(separator: "; "))]")
            if action == "show", let primary {
                log(String(format: "OVERLAY_STATE gen=%llu action=show target=%@ frame=(%.1f,%.1f,%.1f,%.1f) tol=%.1f pointer=(%.1f,%.1f) reason=%@ mode=%@ legitimacy=%@ tier=%d named=%d cands=%d weak=%d winner=1",
                           s.generation, primary.key as NSString, primary.rect.origin.x, primary.rect.origin.y,
                           primary.rect.width, primary.rect.height, tolerance, pointer.x, pointer.y,
                           reason as NSString, (primary.direct ? "direct-hit" : "redirect") as NSString,
                           (reason == RingUnknownHold.reason ? "held" : "confirmed") as NSString,
                           primary.tier, primary.named ? 1 : 0, confirmedCount,
                           primary.weakVerdict ? 1 : 0))
                if let secondary {
                    log(String(format: "OVERLAY_STATE gen=%llu action=show target=%@ frame=(%.1f,%.1f,%.1f,%.1f) tol=%.1f pointer=(%.1f,%.1f) reason=secondary mode=secondary legitimacy=confirmed tier=%d named=%d cands=%d winner=2",
                               s.generation, secondary.key as NSString, secondary.rect.origin.x, secondary.rect.origin.y,
                               secondary.rect.width, secondary.rect.height, tolerance, pointer.x, pointer.y,
                               secondary.tier, secondary.named ? 1 : 0, confirmedCount))
                }
            } else {
                log(String(format: "OVERLAY_STATE gen=%llu action=none pointer=(%.1f,%.1f) reason=%@",
                           s.generation, pointer.x, pointer.y, reason as NSString))
            }
        }
        draw(action: action, frame: primary?.rect, secondary: secondary?.rect,
             pointer: pointer,
             mode: primary?.direct == true ? "direct-hit" : "redirect",
             primaryDim: !(primary?.named ?? true) || (primary?.weakVerdict ?? false))
    }

    private func draw(action: String, frame: CGRect?, secondary: CGRect?, pointer: CGPoint,
                      mode: String, primaryDim: Bool = false) {
        // Skip redundant redraws: state transitions always paint; pointer moves
        // only matter while a highlight is shown. This keeps pointer sampling
        // cheap when the ring is static or blank.
        let stateChanged = action != lastDrawnAction || frame != lastDrawnFrame
            || secondary != lastDrawnSecondary || mode != lastDrawnMode || tolerance != lastDrawnTolerance
            || primaryDim != lastDrawnDim
        let pointerChanged = pointer != lastDrawnPointer
        // Keep the confirmed direct-hit (green) outline actively painted even
        // when the pointer rests at the bullseye. Static-frame coalescing must
        // not make that indicator disappear when the backing surface redraws.
        let keepGreenVisible = action == "show" && mode == "direct-hit"
        guard stateChanged || (action == "show" && pointerChanged) || keepGreenVisible else { return }
        lastDrawnAction = action
        lastDrawnFrame = frame
        lastDrawnSecondary = secondary
        lastDrawnMode = mode
        lastDrawnPointer = pointer
        lastDrawnTolerance = tolerance
        lastDrawnDim = primaryDim

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
            publishWindowIDs()
        }
        guard let panel, let view else { return }
        if panel.frame != cocoa { panel.setFrame(cocoa, display: false) }   // AX-churn guard
        view.cgFrame = frame
        view.cgSecondaryFrame = secondary
        view.cgPanelTopLeft = CGPoint(x: cgPanel.minX, y: cgPanel.minY)
        view.cgPointer = pointer
        view.tolerance = tolerance
        view.mode = mode
        view.primaryDim = primaryDim
        view.isBlank = false
        view.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }   // never activates, never keys
    }
}

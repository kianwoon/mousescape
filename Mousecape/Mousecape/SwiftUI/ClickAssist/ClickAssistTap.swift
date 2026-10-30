// baseline-guard:allow new standalone prototype file, no prior baseline possible
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import QuartzCore

/// A snap target with a fixed rect, retained for the P0 regression harness.
struct AssistTarget: Sendable {
    let name: String
    let rect: CGRect
    let inset: CGFloat

    func correctedPoint(for p: CGPoint) -> CGPoint {
        let r = rect.insetBy(dx: inset, dy: inset)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX),
                       y: min(max(p.y, r.minY), r.maxY))
    }
}

/// Where routing candidates come from. `.cache` is the production path (AX resolver);
/// `.staticTargets` exists only so the P0 self-test stays a regression test.
enum TargetSource: Sendable {
    case staticTargets([AssistTarget])
    case cache(CacheStore)
}

/// Mutable CGEventTap. The callback's ONLY inputs are an in-memory snapshot and a
/// bool; it performs zero Accessibility calls and zero on-demand resolution.
final class AssistTap: @unchecked Sendable {
    private(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var latched: (delta: CGVector, target: String, snap: DecisionCore.Snap,
                          edgeCore: Bool)?
    /// Set when a center-snapped down turned into a drag: the rest of that
    /// gesture is passed through unmutated (no drag-to-snapped-center hijack).
    private var unlatchedForDrag = false
    /// Set while the tap is intentionally disabled (P3 interruption gate): the system
    /// delivers tapDisabledByUserInput for a manual CGEvent.tapEnable(false), which
    /// must NOT auto-re-enable.
    private var manuallyDisabled = false
    /// Latched at a mouse-down that was delivered via AXPress. While non-nil the
    /// rest of that gesture (drag/up) is swallowed, so AXPress can never pair with
    /// a synthetic event. The token also guarantees one AXPress per gesture.
    private var pressGestureToken: UUID?
    /// Set when a gesture's DOWN failed the conservative support gate (non-primary
    /// button, modifier, multi-click, or secure input). Every later event of that
    /// gesture stays a passthrough: a gesture that began unsupported stays
    /// unsupported end-to-end.
    private var gestureUnsupported = false

    var assistEnabled = true
    private(set) var tolerance: CGFloat
    let log: (String) -> Void
    /// The single legitimacy policy (renderer hit-test at the destination).
    var legitimacy: LegitimacyPolicy?

    var targetSource: TargetSource = .staticTargets([])

    private static let downTypes: Set<CGEventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    private static let upTypes: Set<CGEventType> = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
    private static let dragTypes: Set<CGEventType> = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    static let mask: CGEventMask =
        (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.leftMouseUp.rawValue) |
        (1 << CGEventType.leftMouseDragged.rawValue) |
        (1 << CGEventType.rightMouseDown.rawValue) |
        (1 << CGEventType.rightMouseUp.rawValue) |
        (1 << CGEventType.rightMouseDragged.rawValue) |
        (1 << CGEventType.otherMouseDown.rawValue) |
        (1 << CGEventType.otherMouseUp.rawValue) |
        (1 << CGEventType.otherMouseDragged.rawValue)

    init(tolerance: CGFloat, log: @escaping (String) -> Void) {
        self.tolerance = AssistTap.clampTolerance(tolerance)
        self.log = log
    }

    /// P2b: runtime-configurable assist radius. Any value outside 8...16 is CLAMPED
    /// (logged); semantics stay boundary-distance <= tolerance inside DecisionCore.
    static func clampTolerance(_ v: CGFloat) -> CGFloat { min(max(v, 8), 16) }

    @discardableResult
    func setTolerance(_ v: CGFloat) -> CGFloat {
        tolerance = AssistTap.clampTolerance(v)
        return tolerance
    }

    deinit { stop() }

    /// P3 interruption gate: toggle the tap without touching latched state.
    @discardableResult
    func setTapEnabled(_ on: Bool) -> Bool {
        guard let tap else { return false }
        manuallyDisabled = !on
        CGEvent.tapEnable(tap: tap, enable: on)
        log("TAP_\(on ? "ENABLED" : "DISABLED") manual reason=p3-interruption-test")
        return on
    }

    // MARK: - tap lifecycle

    @discardableResult
    func start(point: CGEventTapLocation = .cghidEventTap) -> Bool {
        guard tap == nil else { return true }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: point,
            place: .headInsertEventTap,
            // kCGEventTapOptionDefault == mutable, NOT listen-only.
            options: .defaultTap,
            eventsOfInterest: AssistTap.mask,
            callback: AssistTap.callback,
            userInfo: refcon
        ) else {
            log("TAP_CREATE_FAILED point=\(point == .cghidEventTap ? "hid" : "session")")
            return false
        }
        tap = port
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        log("TAP_ACTIVE mutable=defaultTap point=\(point == .cghidEventTap ? "hid" : "session") tolerance=\(tolerance)")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    // MARK: - callback

    private static let callback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<AssistTap>.fromOpaque(refcon).takeUnretainedValue()
        return me.handle(proxy: proxy, type: type, event: event)
    }

    /// Shared routing math lives in DecisionCore; the callback's in-memory work is
    /// unchanged (same comparisons, same arithmetic, no new I/O or locks).
    private typealias Candidate = DecisionCore.Candidate

    private var cacheStoreForDelivery: CacheStore? {
        if case .cache(let store) = targetSource { return store }
        return nil
    }

    private struct Resolution {
        let candidates: [Candidate]
        let valid: Bool
        let reason: String
        let generation: UInt64
        let ageMs: Double
        let source: String
        let pid: pid_t
    }

    /// Pure in-memory snapshot read. No IPC, no AX, no allocation beyond a retain.
    private func resolution() -> Resolution {
        switch targetSource {
        case .staticTargets(let ts):
            return Resolution(candidates: ts.map { Candidate(key: $0.name, rect: $0.rect, inset: $0.inset,
                                                              tier: .firstClass, label: $0.name) },
                              valid: true, reason: "static", generation: 0, ageMs: 0,
                              source: "static", pid: 0)
        case .cache(let store):
            let s = store.current()
            let ageMs = (CACurrentMediaTime() - s.stamp) * 1000
            let fresh = s.valid && ageMs <= DecisionCore.cacheMaxAge * 1000
            let reason = s.valid ? (fresh ? "fresh" : String(format: "stale:age(%.0fms)", ageMs)) : s.reason
            return Resolution(candidates: s.targets.map { Candidate(key: $0.key, rect: $0.rect,
                                                                     inset: $0.inset, tier: $0.tier,
                                                                     role: $0.role, label: $0.label) },
                              valid: fresh, reason: reason, generation: s.generation,
                              ageMs: ageMs, source: "cache", pid: s.pid)
        }
    }

    /// Single legitimacy check for a routing decision at its destination point.
    /// No policy (static regression harness) keeps the legacy behaviour.
    private func legitimacyVerdict(for candidate: Candidate, destination: CGPoint,
                                   res: Resolution) -> LegitimacyPolicy.Verdict {
        guard let legitimacy else { return .confirmed }
        let siblings = res.candidates
            .filter { $0.tier == .firstClass && $0.key != candidate.key }
            .map { $0.rect }
        return legitimacy.validate(pid: res.pid, generation: res.generation,
                                   key: candidate.key, candidate: candidate.rect,
                                   candidateRole: candidate.role,
                                   destination: destination, siblings: siblings)
    }

    /// What may be done with ONE candidate aimed at ONE destination point.
    private struct DeliveryPlan {
        enum Kind {
            /// Exactly one AXPress on the plan's element, then consume the gesture.
            case axPress(CGPoint)
            /// Legacy synthetic delivery: mutate the event to this point.
            case synthetic(CGPoint)
            /// Nothing may be delivered; the caller takes its passthrough path.
            case rejected
        }
        let kind: Kind
        /// The live element behind the candidate, when the resolver supplied one
        /// (nil: static harness, or the entry was dropped). Needed by the caller
        /// for fresh-frame revalidation even when the plan is synthetic.
        let element: AXUIElement?
        let verdict: LegitimacyPolicy.Verdict
        /// One token for a passthrough line: `unavailable=1` when the evidence was
        /// confirmed but the live element/chrome gate could not be re-proven,
        /// `verdict=<v>` when the evidence itself failed.
        let reasonToken: String
    }

    /// THE single delivery decision. Given a candidate and the point we would aim
    /// at, it looks up the live element, applies the structural AXPress gate
    /// (`axPressEligible`), computes the ONE legitimacy verdict for that
    /// destination, and returns what may be done. Weak evidence
    /// (`.confirmedWeak`) is deliverable ONLY as AXPress — the chrome gate is what
    /// makes it safe; it is never synthesised. A material frame move (> 24 pt)
    /// still cancels inside `performAXPressDelivery`.
    ///
    /// `requiresConfirmation: false` is the direct-hit self path, which is
    /// admitted by the router's own hit and delivers on structural eligibility
    /// alone (no extra renderer hit-test, exactly as before).
    private func resolveDelivery(for candidate: Candidate, destination: CGPoint,
                                 res: Resolution,
                                 requiresConfirmation: Bool = true,
                                 allowsSynthetic: Bool) -> DeliveryPlan {
        // Verdict first, in the same AX order as the pre-refactor branches.
        let verdict: LegitimacyPolicy.Verdict = requiresConfirmation
            ? legitimacyVerdict(for: candidate, destination: destination, res: res)
            : .confirmed
        let element = cacheStoreForDelivery?.element(for: candidate.key, pid: res.pid)
        let axPressReady = element.map { AssistTap.axPressEligible($0, role: candidate.role) } ?? false
        let evidenceOK = !requiresConfirmation
            || verdict == .confirmed || verdict == .confirmedWeak
        if evidenceOK, axPressReady, let el = element {
            return DeliveryPlan(kind: .axPress(destination), element: el, verdict: verdict,
                                reasonToken: "unavailable=0")
        }
        // Strong evidence only: a synthetic click aimed at a weak answer is unsafe.
        if requiresConfirmation, verdict == .confirmed, allowsSynthetic {
            return DeliveryPlan(kind: .synthetic(destination), element: element,
                                verdict: verdict, reasonToken: "unavailable=0")
        }
        return DeliveryPlan(kind: .rejected, element: element, verdict: verdict,
                            reasonToken: evidenceOK ? "unavailable=1"
                                                    : "verdict=\(verdict.rawValue)")
    }

    /// Diagnostics helper for the no-candidate branch only: the nearest
    /// `limit` eligible candidates with boundary distance, sorted ascending.
    /// Pure — reads the existing candidate array, allocates nothing else.
    private static func nearestCandidates(_ candidates: [Candidate], to point: CGPoint,
                                          limit: Int = 3) -> String {
        let listed = candidates
            .map { (key: $0.key, dist: DecisionCore.boundaryDistance(point, $0.rect)) }
            .sorted { $0.dist < $1.dist }
            .prefix(limit)
            .map { "\($0.key):\(String(format: "%.1f", $0.dist))" }
        return listed.isEmpty ? "-" : listed.joined(separator: ",")
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByUserInput, manuallyDisabled {
                log("TAP_STAYSDISABLED reason=manual-p3-interruption")
                return Unmanaged.passUnretained(event)
            }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("TAP_REENABLED reason=\(type == .tapDisabledByTimeout ? "timeout" : "user-input")")
            return Unmanaged.passUnretained(event)
        }

        let isDown = AssistTap.downTypes.contains(type)
        let isUp = AssistTap.upTypes.contains(type)
        let isDrag = AssistTap.dragTypes.contains(type)
        guard isDown || isUp || isDrag else { return Unmanaged.passUnretained(event) }

        let started = CACurrentMediaTime()
        let original = event.location
        let label = AssistTap.name(type)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let clicks = event.getIntegerValueField(.mouseEventClickState)
        let gestureFlags = event.flags.intersection(
            [.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let observed = "btn=\(button) flags=0x\(String(gestureFlags.rawValue, radix: 16)) clicks=\(clicks)"

        // Secure input: a password prompt must never receive a relocated click,
        // and secure input is the system-wide signal for it. Evaluated per event
        // (cheap), never polled.
        if IsSecureEventInputEnabled() {
            if isDown { gestureUnsupported = true }
            if isUp { gestureUnsupported = false; pressGestureToken = nil }
            emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                 reason: "secure-input", res: resolution(), started: started,
                 extra: observed)
            return Unmanaged.passUnretained(event)
        }

        // Conservative gesture gate: assist ONLY a plain primary single click.
        // AXPress and coordinate relocation cannot faithfully reproduce modifier
        // or multi-click semantics, so assisting them risks a wrong activation;
        // they must stay native. A gesture that began unsupported stays
        // unsupported end-to-end (its drags and up pass through too).
        let supported = button == 0 && gestureFlags.isEmpty && clicks <= 1
        let continuedUnsupported = gestureUnsupported && !isDown
        if !supported || continuedUnsupported {
            if isDown { gestureUnsupported = true }
            if isUp { gestureUnsupported = false; pressGestureToken = nil }
            emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                 reason: "gesture-unsupported", res: resolution(), started: started,
                 extra: observed + (continuedUnsupported ? " continuity=1" : ""))
            return Unmanaged.passUnretained(event)
        }
        if isDown { gestureUnsupported = false }

        // AXPress gesture consumption: the down that fired AXPress was swallowed,
        // so its drags and matching up must be swallowed too. Returning nil from
        // the callback consumes the event outright. The token is cleared on the up
        // (or on an unexpected new down), so at most one AXPress per gesture.
        if pressGestureToken != nil {
            if isUp {
                pressGestureToken = nil
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: "axpress-swallow-up", res: resolution(), started: started,
                     extra: "mode=axpress consumed=up")
                return nil
            }
            if isDrag { return nil }
            pressGestureToken = nil
        }

        guard assistEnabled else {
            latched = nil
            emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                 reason: "assist-disabled", res: resolution(), started: started)
            return Unmanaged.passUnretained(event)
        }

        let res = resolution()

        if isDown {
            latched = nil
            unlatchedForDrag = false

            guard res.valid else {
                // A gesture may never span a snapshot invalidation (an app switch
                // mid-AXPress): drop the delayed AXPress token with the snapshot,
                // otherwise it would swallow the next up in the new app.
                pressGestureToken = nil
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: res.reason, res: res, started: started, extra: "validity=invalid")
                return Unmanaged.passUnretained(event)
            }

            switch DecisionCore.route(point: original, candidates: res.candidates, tolerance: tolerance) {
            case .directHit(let hit, let others):
                // Self delivery: when the hit element is ITSELF a chrome-gated
                // AXButton (e.g. the real 16x16 tab-close glyph), a synthetic
                // click is ignored by Chromium. AXPress acts on the element, so
                // deliver it directly. Web surfaces fail the gate (AXWebArea).
                let selfPlan = resolveDelivery(for: hit,
                                               destination: DecisionCore.centerPoint(into: hit.rect),
                                               res: res, requiresConfirmation: false,
                                               allowsSynthetic: false)
                if case .axPress(let dest) = selfPlan.kind, let el = selfPlan.element,
                   performAXPressDelivery(element: el, best: hit,
                                          corrected: dest,
                                          snap: DecisionCore.snapMode(for: hit),
                                          dist: 0, cands: 1, res: res, label: label,
                                          original: original, started: started,
                                          extra: "self=1 ") {
                    return nil
                }
                // Promotion: a near-miss can land INSIDE a container (e.g. a
                // browser tab) whose nested chrome button is still within the
                // assist radius. Only a structurally-eligible chrome button can
                // be promoted, so web content keeps the untouched direct-hit path.
                var promotionFailure: String?
                if let promoted = promotedTarget(res: res, point: original, containedIn: hit.rect) {
                    let plan = resolveDelivery(for: promoted,
                                               destination: DecisionCore.centerPoint(into: promoted.rect),
                                               res: res, allowsSynthetic: false)
                    if case .axPress(let dest) = plan.kind, let el = plan.element {
                        if performAXPressDelivery(element: el, best: promoted,
                                                  corrected: dest,
                                                  snap: DecisionCore.snapMode(for: promoted),
                                                  dist: DecisionCore.boundaryDistance(original, promoted.rect),
                                                  cands: 1, res: res, label: label,
                                                  original: original, started: started,
                                                  extra: "promoted=1 from=\(hit.key) ") {
                            return nil
                        }
                        // Fail closed: the gate re-check at delivery lost the
                        // target, so this click is NOT redirected. Fall through
                        // to the normal direct-hit passthrough (which computes the
                        // hit's own verdict and logs the other= diagnostics).
                        promotionFailure = "promoted=1 from=\(hit.key) target=\(promoted.key) unavailable=1"
                    } else {
                        promotionFailure = "promoted=1 from=\(hit.key) target=\(promoted.key) \(plan.reasonToken)"
                    }
                }
                let hitPlan = resolveDelivery(for: hit, destination: original, res: res,
                                              allowsSynthetic: false)
                var extra = "element=\(hit.key) boundary=0.0 action=passthrough legitimacy=\(hitPlan.verdict.rawValue)"
                if let promotionFailure { extra += " " + promotionFailure }
                if let other = others.first { extra += " other=\(other.key) other_dist=\(String(format: "%.1f", other.dist))" }
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: "direct-hit", res: res, started: started, extra: extra)
                return Unmanaged.passUnretained(event)
            case .noCandidate:
                // Diagnostics only: how far was the CLOSEST eligible control? The
                // candidate set is the already-filtered snapshot, so a short list
                // here means either genuine distance (a) or a filtered-out role (c).
                // Computed strictly inside this branch — no cost on any other path.
                let nearest = AssistTap.nearestCandidates(res.candidates, to: original)
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: "no-candidate-in-radius", res: res, started: started,
                     extra: "tol=\(tolerance) targets=\(res.candidates.count) nearest3=[\(nearest)]")
                return Unmanaged.passUnretained(event)
            case .ambiguous(let scored, let tie):
                // Ambiguity between duplicate surfaces (e.g. an AXTabGroup and its
                // AXRadioButton sharing one frame) is not evidence against a nested
                // chrome button. Promotion is SCOPED TO THE TIED SET: an ambiguous
                // tie may only be resolved by evidence about the tied surfaces
                // themselves — a third party merely in range (a tab strip next to
                // two page sliders) is never a tie-breaker. A tied candidate that
                // passes the structural AXPress gate wins if its own legitimacy
                // confirms. Everything else below is untouched.
                let tiedKeys = Set(scored.map { $0.candidate.key })
                if let promoted = promotedTarget(res: res, point: original, containedIn: nil,
                                                 restrictedTo: tiedKeys) {
                    let plan = resolveDelivery(for: promoted,
                                               destination: DecisionCore.centerPoint(into: promoted.rect),
                                               res: res, allowsSynthetic: false)
                    if case .axPress(let dest) = plan.kind, let el = plan.element,
                       performAXPressDelivery(element: el, best: promoted,
                                              corrected: dest,
                                              snap: DecisionCore.snapMode(for: promoted),
                                              dist: DecisionCore.boundaryDistance(original, promoted.rect),
                                              cands: 1, res: res, label: label,
                                              original: original, started: started,
                                              extra: "promoted=1 from=ambiguous ") {
                        return nil
                    }
                }
                let listed = scored.prefix(3)
                    .map { "\($0.candidate.key):\(String(format: "%.1f", $0.dist))" }
                    .joined(separator: ",")
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: "ambiguous", res: res, started: started,
                     extra: "cands=[\(listed)] tie=\(String(format: "%.1f", tie)) tol=\(tolerance)")
                return Unmanaged.passUnretained(event)
            case .redirect:
                // Multi-target, fail-closed: validate up to three nearest
                // candidates at their own destinations; every confirmed one is a
                // legitimate target, and the nearest wins the click. mismatch and
                // unknown never become the winner and never move the event.
                let scored = DecisionCore.displayCandidates(point: original,
                                                            candidates: res.candidates,
                                                            tolerance: tolerance, limit: 3)
                var confirmed: [(DecisionCore.ScoredCandidate, CGPoint, DecisionCore.Snap, DeliveryPlan)] = []
                var firstFailure: (String, LegitimacyPolicy.Verdict)?
                for choice in scored {
                    let snap = DecisionCore.snapMode(for: choice.candidate)
                    let dest = snap == .center
                        ? DecisionCore.centerPoint(into: choice.candidate.rect)
                        : DecisionCore.clampPoint(original, into: choice.candidate.rect,
                                                  inset: choice.candidate.inset)
                    let plan = resolveDelivery(for: choice.candidate, destination: dest,
                                               res: res, allowsSynthetic: true)
                    switch plan.kind {
                    case .axPress, .synthetic:
                        confirmed.append((choice, dest, snap, plan))
                    case .rejected:
                        if firstFailure == nil {
                            firstFailure = (choice.candidate.key, plan.verdict)
                        }
                    }
                }
                guard let winner = confirmed.first else {
                    let failure = firstFailure ?? ("-", .unknown)
                    emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                         reason: "legitimacy-\(failure.1.rawValue)", res: res, started: started,
                         extra: "legitimacy=\(failure.1.rawValue) target=\(failure.0) cands=0 winner=0")
                    return Unmanaged.passUnretained(event)
                }
                let best = winner.0.candidate
                let snap = winner.2
                let plan = winner.3
                let weakEvidence = plan.verdict == .confirmedWeak
                // Delivery side table: the live element behind this candidate, when
                // the resolver supplied one. nil (static harness, or dropped entry)
                // keeps the exact legacy synthetic path below.
                let element = plan.element

                // Fresh-frame revalidation: never aim at a moved target. Any AX
                // failure falls back to the cached rect; drift beyond the
                // target-relative limit, or loss of half-overlap, cancels the
                // redirect entirely (passthrough).
                var corrected = winner.1
                if let element, let fresh = axFrame(element) {
                    if AssistTap.frameMoved(best.rect, fresh) {
                        emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                             reason: "stale-target", res: res, started: started,
                             extra: "mode=synthetic target=\(best.key) cached=\(best.rect) fresh=\(fresh) moved=\(String(format: "%.1f", AssistTap.frameDelta(best.rect, fresh))) iou=\(String(format: "%.2f", FrameContinuity.overlapFraction(best.rect, fresh)))")
                        return Unmanaged.passUnretained(event)
                    }
                    corrected = snap == .center
                        ? DecisionCore.centerPoint(into: fresh)
                        : DecisionCore.clampPoint(original, into: fresh, inset: best.inset)
                }

                // Chrome-button delivery: structural gate, then EXACTLY ONE
                // AXPress. Synthetic CGEvents are ignored by Chromium chrome.
                if case .axPress = plan.kind, let element,
                   performAXPressDelivery(element: element, best: best, corrected: corrected,
                                          snap: snap, dist: winner.0.dist,
                                          cands: confirmed.count, res: res, label: label,
                                          original: original, started: started,
                                          extra: weakEvidence ? "legitimacy=confirmedWeak " : "") {
                    return nil
                }
                // Weak evidence is AXPress-only: a synthetic click here would be
                // aimed on the very hit-test answer that could not be confirmed.
                if weakEvidence {
                    emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                         reason: "legitimacy-confirmedWeak", res: res, started: started,
                         extra: "legitimacy=confirmedWeak target=\(best.key) cands=0 winner=0")
                    return Unmanaged.passUnretained(event)
                }

                let delta = CGVector(dx: corrected.x - original.x, dy: corrected.y - original.y)
                event.location = corrected
                latched = (delta, best.key, snap, false)
                emit("MUTATE", type: label, original: original, mutated: corrected,
                     reason: "redirect", res: res, started: started,
                     extra: "delta=\(ScreenSpace.fmt(delta)) dist=\(String(format: "%.1f", winner.0.dist)) target=\(best.key) mode=return-modified-event mode=synthetic snap=\(snap.rawValue) tier=\(best.tier == .firstClass ? 1 : 2) legitimacy=confirmed cands=\(confirmed.count) winner=1")
                return Unmanaged.passUnretained(event)
            }
        }

        // Drag guard: a center snap is a CLICK assist. The moment that gesture
        // drags, the user is moving/pressing something at their own coordinates —
        // stop redirecting for the remainder (dragged events and the up stay
        // native). Edge-snapped gestures (sliders) keep the latched translation.
        if (isDrag || isUp), unlatchedForDrag {
            if isUp { unlatchedForDrag = false }
            return Unmanaged.passUnretained(event)
        }
        if isDrag, let l = latched, l.snap == .center {
            latched = nil
            unlatchedForDrag = true
            emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                 reason: "unlatched-on-drag", res: res, started: started,
                 extra: "gesture=unlatched-on-drag target=\(l.target)")
            return Unmanaged.passUnretained(event)
        }

        // Drag / up: one latched translation for the whole gesture.
        if let l = latched {
            let corrected = CGPoint(x: original.x + l.delta.dx, y: original.y + l.delta.dy)
            event.location = corrected
            emit("MUTATE", type: label, original: original, mutated: corrected,
                 reason: "redirect", res: res, started: started,
                 extra: "delta=\(ScreenSpace.fmt(l.delta)) gesture=latched-constant target=\(l.target) mode=return-modified-event snap=\(l.snap.rawValue)\(l.edgeCore ? " edgecore=1" : "")")
            if isUp { latched = nil }
            return Unmanaged.passUnretained(event)
        }

        emit("PASSTHROUGH", type: label, original: original, mutated: nil,
             reason: "no-active-gesture", res: res, started: started)
        return Unmanaged.passUnretained(event)
    }

    // MARK: - AXPress delivery gate (chrome only)

    /// Delivers one gesture via AXPress: exactly one perform, then latch the
    /// per-gesture token so the matching up (and any drag) is swallowed by the
    /// top-of-handle guard. Shared by the redirect and direct-hit promotion paths.
    /// Returns false when the element's fresh frame fails the target-relative
    /// continuity check (drift beyond the size-scaled limit, or < half overlap):
    /// the caller must then take its fail-closed passthrough path.
    @discardableResult
    private func performAXPressDelivery(element: AXUIElement, best: Candidate,
                                        corrected: CGPoint, snap: DecisionCore.Snap,
                                        dist: Double, cands: Int, res: Resolution,
                                        label: String, original: CGPoint,
                                        started: CFTimeInterval, extra: String) -> Bool {
        if let fresh = axFrame(element), AssistTap.frameMoved(best.rect, fresh) {
            return false
        }
        let result = AXUIElementPerformAction(element, "AXPress" as CFString)
        pressGestureToken = UUID()
        latched = nil
        unlatchedForDrag = false
        emit("MUTATE", type: label, original: original, mutated: corrected,
             reason: "redirect", res: res, started: started,
             extra: "target=\(best.key) dist=\(String(format: "%.1f", dist)) snap=\(snap.rawValue) tier=\(best.tier == .firstClass ? 1 : 2) legitimacy=confirmed cands=\(cands) winner=1 \(extra)mode=axpress\(result == .success ? "" : " axpress=failed(\(result.rawValue))")")
        return true
    }

    /// Finds the nearest chrome button contained in a direct-hit candidate and
    /// still inside the assist radius. Margin-tolerant: the hit rect is inflated
    /// by 2 pt. Eligibility is the SAME structural AXPress gate as the redirect
    /// path, so a web container (AXWebArea in ancestry) never promotes.
    /// `restrictedTo` narrows the search to the candidates an ambiguity tie is
    /// actually about; nil means the caller supplies its own anchor (the
    /// direct-hit branch's containment).
    private func promotedTarget(res: Resolution, point: CGPoint,
                                containedIn: CGRect?,
                                restrictedTo: Set<String>? = nil) -> Candidate? {
        let containing = containedIn?.insetBy(dx: -2, dy: -2)
        let store = cacheStoreForDelivery
        var best: (candidate: Candidate, dist: CGFloat)?
        for c in res.candidates {
            if let restrictedTo, !restrictedTo.contains(c.key) { continue }
            let dist = DecisionCore.boundaryDistance(point, c.rect)
            guard dist <= tolerance else { continue }
            if let containing, !containing.contains(c.rect) { continue }
            guard let el = store?.element(for: c.key, pid: res.pid),
                  AssistTap.axPressEligible(el, role: c.role) else { continue }
            if let b = best {
                let area = c.rect.width * c.rect.height
                let bestArea = b.candidate.rect.width * b.candidate.rect.height
                if dist < b.dist || (dist == b.dist && area < bestArea) {
                    best = (c, dist)
                }
            } else {
                best = (c, dist)
            }
        }
        return best?.candidate
    }

    /// Structural eligibility: role must be AXButton, the element must still
    /// advertise AXPress, and its ancestry must reach the window through chrome
    /// (AXTabGroup / AXToolbar) with NO AXWebArea anywhere on the chain. Any AX
    /// read error is ambiguous and therefore not eligible. No app/label literals.
    private static func axPressEligible(_ el: AXUIElement, role: String) -> Bool {
        guard role == "AXButton" else { return false }
        AXUIElementSetMessagingTimeout(el, 0.05)
        // Chromium chrome buttons advertise an EMPTY AXActionNames (measured:
        // the tab ✕ exposes actions=[]) yet honor AXPress when performed —
        // verified: AXPress on the ✕ closes the tab. The action-list check is
        // therefore omitted; eligibility rests on role + structural ancestry +
        // enabled below (AXPress failure is handled fail-closed at delivery).
        if let enabled = axAttribute(el, kAXEnabledAttribute) as? Bool, !enabled { return false }
        return chromeAncestry(el)
    }

    /// Walk element -> window. Eligible only when an AXTabGroup or AXToolbar
    /// ancestor is present and no AXWebArea appears at any point. A nil/odd role
    /// or a failing parent read is treated as ambiguous -> false.
    private static func chromeAncestry(_ el: AXUIElement) -> Bool {
        var node: AXUIElement? = el
        var sawChrome = false
        var depth = 0
        while let current = node, depth < 64 {
            depth += 1
            guard let role = axAttribute(current, kAXRoleAttribute) as? String else { return false }
            if role == "AXWebArea" { return false }
            if role == "AXTabGroup" || role == "AXToolbar" { sawChrome = true }
            if role == "AXWindow" { break }
            guard let parent = axAttribute(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = (parent as! AXUIElement)
        }
        return sawChrome
    }

    private static func axAttribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    /// Fresh global frame (top-left space, same as CGEvent/AXPosition). nil on any
    /// AX failure so callers fall back to the cached rect.
    private func axFrame(_ el: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(el, 0.05)
        // Single validated reader: a non-finite frame must never reach
        // centerPoint → event.location (inf − inf = NaN crashed the overlay).
        return AXGeometry.frame(el)
    }

    /// Largest per-edge movement between two frames (pt).
    private static func frameDelta(_ a: CGRect, _ b: CGRect) -> CGFloat {
        FrameContinuity.delta(a, b)
    }

    /// Target-relative continuity check (see FrameContinuity.moved): drift beyond
    /// min(24, max(6, 0.25 * min(w, h))) OR loss of half-overlap cancels a redirect.
    private static func frameMoved(_ a: CGRect, _ b: CGRect) -> Bool {
        FrameContinuity.moved(a, b)
    }

    private func emit(_ kind: String, type: String, original: CGPoint, mutated: CGPoint?,
                      reason: String, res: Resolution, started: CFTimeInterval, extra: String = "") {
        let latency = (CACurrentMediaTime() - started) * 1_000_000
        var line = "\(kind) type=\(type) "
        if kind == "MUTATE" {
            line += "orig=\(ScreenSpace.fmt(original)) mutated=\(ScreenSpace.fmt(mutated ?? original)) "
        } else {
            line += "loc=\(ScreenSpace.fmt(original)) "
        }
        line += "reason=\(reason) "
        if !extra.isEmpty { line += extra + " " }
        line += String(format: "latency_us=%.2f gen=%llu age_ms=%.1f source=%@",
                       latency, res.generation, res.ageMs, res.source)
        if kind == "PASSTHROUGH" {
            line += " equality=orig==delivered"
        }
        log(line)
    }

    private static func name(_ t: CGEventType) -> String {
        switch t {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .otherMouseDragged: return "otherMouseDragged"
        default: return "type\(t.rawValue)"
        }
    }
}

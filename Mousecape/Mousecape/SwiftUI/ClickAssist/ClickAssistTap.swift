// baseline-guard:allow new standalone prototype file, no prior baseline possible
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
                                                              tier: .firstClass) },
                              valid: true, reason: "static", generation: 0, ageMs: 0,
                              source: "static", pid: 0)
        case .cache(let store):
            let s = store.current()
            let ageMs = (CACurrentMediaTime() - s.stamp) * 1000
            let fresh = s.valid && ageMs <= DecisionCore.cacheMaxAge * 1000
            let reason = s.valid ? (fresh ? "fresh" : String(format: "stale:age(%.0fms)", ageMs)) : s.reason
            return Resolution(candidates: s.targets.map { Candidate(key: $0.key, rect: $0.rect,
                                                                     inset: $0.inset, tier: $0.tier,
                                                                     role: $0.role) },
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
                                   destination: destination, siblings: siblings)
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
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: res.reason, res: res, started: started, extra: "validity=invalid")
                return Unmanaged.passUnretained(event)
            }

            switch DecisionCore.route(point: original, candidates: res.candidates, tolerance: tolerance) {
            case .directHit(let hit, let others):
                let verdict = legitimacyVerdict(for: hit, destination: original, res: res)
                var extra = "element=\(hit.key) boundary=0.0 action=passthrough legitimacy=\(verdict.rawValue)"
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
                var confirmed: [(DecisionCore.ScoredCandidate, CGPoint, DecisionCore.Snap, Bool)] = []
                var firstFailure: (String, LegitimacyPolicy.Verdict)?
                for choice in scored {
                    let snap = DecisionCore.snapMode(for: choice.candidate)
                    let dest = snap == .center
                        ? DecisionCore.centerPoint(into: choice.candidate.rect)
                        : DecisionCore.clampPoint(original, into: choice.candidate.rect,
                                                  inset: choice.candidate.inset)
                    let verdict = legitimacyVerdict(for: choice.candidate,
                                                    destination: dest, res: res)
                    if verdict == .confirmed {
                        confirmed.append((choice, dest, snap, false))
                    } else if firstFailure == nil {
                        firstFailure = (choice.candidate.key, verdict)
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
                let corrected = winner.1
                let snap = winner.2
                let delta = CGVector(dx: corrected.x - original.x, dy: corrected.y - original.y)
                event.location = corrected
                latched = (delta, best.key, snap, false)
                emit("MUTATE", type: label, original: original, mutated: corrected,
                     reason: "redirect", res: res, started: started,
                     extra: "delta=\(ScreenSpace.fmt(delta)) dist=\(String(format: "%.1f", winner.0.dist)) target=\(best.key) mode=return-modified-event snap=\(snap.rawValue) legitimacy=confirmed cands=\(confirmed.count) winner=1")
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

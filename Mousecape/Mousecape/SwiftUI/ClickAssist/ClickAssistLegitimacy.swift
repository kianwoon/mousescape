// baseline-guard:allow service-only AX legitimacy policy (moved out of the agent runtime)
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

final class LegitimacyPolicy: @unchecked Sendable {

    private struct Entry {
        let verdict: ClickAssistVerdict
        let generation: UInt64
        let stamp: CFTimeInterval
    }

    /// CFEqual-identity proxy: the snapshot carries no AXUIElement, so the key is
    /// (pid, candidate key, rounded destination). Scoped to the snapshot
    /// generation: any soft/hard invalidation bumps it and drops the cache.
    private var cache: [String: Entry] = [:]
    private var cachedGeneration: UInt64 = 0
    private static let ttl: CFTimeInterval = 0.5
    private let lock = NSLock()

    /// Roles that ARE an actionable control on their own. Only these may be
    /// confirmed by sitting inside an answered surface (see evaluate step 3).
    private static let directControlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton",
        "AXMenuButton", "AXLink", "AXComboBox", "AXSearchField", "AXIncrementor"
    ]

    /// Approximate frame equality used for "the renderer answered with this exact
    /// control surface" (Brave's tab group vs the tab's AXRadioButton).
    private static func sameFrame(_ a: CGRect, _ b: CGRect, eps: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= eps && abs(a.minY - b.minY) <= eps &&
        abs(a.width - b.width) <= eps && abs(a.height - b.height) <= eps
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return v
    }

    private static func role(of el: AXUIElement) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        return (v as? String) ?? ""
    }

    private static func axFrame(_ el: AXUIElement) -> CGRect? {
        AXGeometry.frame(el)   // single validated reader (ClickAssistGeometry.swift)
    }

    /// Validate `candidate` at `destination` for app `pid`. `siblings` are the
    /// first-class candidate frames in the same snapshot (identity proxy).
    func validate(pid: pid_t, generation: UInt64, key: String,
                  candidate: CGRect, candidateRole: String, destination: CGPoint,
                  siblings: [CGRect]) -> ClickAssistVerdict {
        // Non-finite geometry (AX can answer NaN/±inf frames — observed crash:
        // Int(destination.x) trapping on the main thread) is never testimony.
        // Reject before any arithmetic; fail closed and stay quiet.
        guard destination.x.isFinite, destination.y.isFinite,
              candidate.origin.x.isFinite, candidate.origin.y.isFinite,
              candidate.width.isFinite, candidate.height.isFinite else { return .unknown }
        let now = CACurrentMediaTime()
        let cacheKey = "\(pid)|\(key)|\(Int(destination.x.rounded()))|\(Int(destination.y.rounded()))"
        lock.lock()
        if cachedGeneration != generation {
            cache.removeAll()
            cachedGeneration = generation
        }
        if let hit = cache[cacheKey], now - hit.stamp < Self.ttl, hit.generation == generation {
            lock.unlock()
            return hit.verdict
        }
        lock.unlock()

        let verdict = Self.evaluate(pid: pid, candidate: candidate,
                                    candidateRole: candidateRole,
                                    destination: destination, siblings: siblings)
        lock.lock()
        cache[cacheKey] = Entry(verdict: verdict, generation: generation, stamp: now)
        lock.unlock()
        return verdict
    }

    private static func evaluate(pid: pid_t, candidate: CGRect, candidateRole: String,
                                 destination: CGPoint, siblings: [CGRect]) -> ClickAssistVerdict {
        guard pid > 0, pid != getpid() else { return .unknown }
        let app = AXUIElementCreateApplication(pid)
        // Evidence collection runs in the XPC service, OFF the event tap, so a
        // generous timeout costs nothing user-visible. 0.1 s was too tight for
        // heavy pages: YouTube's seek bar returned nothing at all and the ring was
        // suppressed as `legitimacy-unknown` on every hover (observed live).
        AXUIElementSetMessagingTimeout(app, 0.35)
        var element: AXUIElement?
        var hitResult = AXUIElementCopyElementAtPosition(app, Float(destination.x), Float(destination.y), &element)
        if hitResult != .success || element == nil {
            // One retry: Chromium occasionally fails the first query under load.
            usleep(15_000)
            hitResult = AXUIElementCopyElementAtPosition(app, Float(destination.x), Float(destination.y), &element)
        }
        guard hitResult == .success, let element, let hitFrame = axFrame(element) else {
            // No testimony at all. A first-class control whose OWN rect contains
            // the destination still stands on its geometry — the same rule already
            // applied when the hit-test answers incoherently (below). Anonymous
            // groups get nothing: they have no role evidence.
            if candidate.contains(destination), directControlRoles.contains(candidateRole) {
                return .confirmedWeak
            }
            return .unknown
        }
        // The renderer's answer must cover the destination to mean anything.
        // In macOS fullscreen Chromium answers out of a broken coordinate space
        // (measured: the menu bar for a point at the bottom of the screen, or a
        // different window's element). Such an answer is incoherent — it cannot
        // testify about this point either way — so it is discarded and a real
        // control whose own rect holds the destination stands on its geometry.
        if !hitFrame.contains(destination) {
            if candidate.contains(destination),
               directControlRoles.contains(candidateRole) { return .confirmedWeak }
            return .unknown
        }
        // AXEnabled veto: a DISABLED control is never a legitimate click target.
        // (Cheap; true supplies no visibility evidence — see Codex audit.)
        if let enabled = attr(element, kAXEnabledAttribute) as? Bool, enabled == false {
            return .mismatch
        }
        // Confirmation must prove THE CHOSEN TARGET. Two accepted answers:
        // 1. the renderer's answer sits inside the candidate's own rect, or IS
        //    the candidate's own surface (frame-equal within 1 pt);
        // 2. the renderer answered a REAL first-class control (frame-equal to a
        //    first-class candidate) that CONTAINS this candidate — Chromium
        //    answers a tab's inner ✕ with the tab's own frame. Scoped to that
        //    containment; an unrelated container still fails.
        // Strong evidence requires the answered surface to BE something: a named
        // control, a press-capable control, or a direct-control role. An
        // anonymous group answering for itself may be nothing but a dead div —
        // that self-answer is only WEAK evidence (dim ring, still assisted).
        let hitNamed = !(attr(element, kAXTitleAttribute) as? String ?? "").isEmpty
            || !(attr(element, kAXDescriptionAttribute) as? String ?? "").isEmpty
        let hitPress = (attr(element, "AXActionNames") as? [String])?.contains("AXPress") ?? false
        let hitControl = Self.directControlRoles.contains(candidateRole)
        let strong = hitNamed || hitPress || hitControl
        if candidate.contains(hitFrame) { return strong ? .confirmed : .confirmedWeak }
        if sameFrame(candidate, hitFrame) { return strong ? .confirmed : .confirmedWeak }
        if hitFrame.contains(candidate),
           siblings.contains(where: { sameFrame($0, hitFrame) }) { return .confirmed }
        // 3. The renderer answered a surface that CONTAINS a real control placed
        //    inside it (Chromium answers web video players with the player group
        //    for their seek bar). Only direct-control roles qualify — a generic
        //    container or anonymous group can never be confirmed this way.
        if hitFrame.contains(candidate),
           Self.directControlRoles.contains(candidateRole) { return .confirmedWeak }
        // 4. A CONTAINER answer cannot veto a real control that covers the point.
        //    Web players answer with the video/overlay group at points where the
        //    seek bar is fully clickable (measured in fullscreen: menu bar or a
        //    background window's group). Only an answer that IS a control may
        //    block; a structural answer is treated as uninformative.
        let hitRole = Self.role(of: element)
        if candidate.contains(destination),
           Self.directControlRoles.contains(candidateRole),
           !Self.directControlRoles.contains(hitRole) { return .confirmedWeak }
        return .mismatch
    }

    /// Drop cached verdicts (called on soft/hard invalidation).
    func invalidate() {
        lock.lock()
        cache.removeAll()
        cachedGeneration = 0
        lock.unlock()
    }
}

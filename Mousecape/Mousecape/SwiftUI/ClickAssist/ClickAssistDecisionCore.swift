// baseline-guard:allow new standalone prototype file, no prior baseline possible
import CoreGraphics
import Foundation
import ApplicationServices
import QuartzCore

/// The single source of routing math. The CGEventTap router calls `route()` in its
/// callback; the P2a targeting overlay calls the SAME `route()` on the SAME published
/// snapshot. The overlay therefore renders the router's decision by construction and
/// carries zero targeting math of its own.
enum DecisionCore {
    /// Two candidates closer than this in boundary distance are treated as ambiguous.
    static let tieEpsilon: CGFloat = 2.0
    /// A cache snapshot older than this is treated as stale even if still marked valid.
    static let cacheMaxAge: CFTimeInterval = 1.0
    /// Fraction of each half-dimension treated as a control's "live core". A
    /// DIRECT hit inside this core is left untouched; outside it (but still
    /// inside the AX rect) a position-agnostic control is re-aimed at the
    /// bullseye. 0.4 = the inner 40% of each half-axis — Chromium's tab close X
    /// exposes 28×28 but only registers near the glyph, so a click 13 pt off
    /// center inside the rect is a dead zone and must be redirected.
    static let coreRadiusFraction: CGFloat = 0.4

    /// Admission tier. FIRST-CLASS is a genuine control role; SECOND-CLASS is a
    /// container admitted only by the tile/row size envelope (AXImage/AXGroup
    /// tiles, oversized-but-row-admitted elements). Only first-class candidates
    /// own direct-hit priority — a container never blocks a nearby control.
    enum Tier: Sendable {
        case firstClass
        case secondClass
    }

    /// How a redirected point is derived from the target rect.
    /// - `center`: the bullseye for position-AGNOSTIC controls — the click
    ///   ACTIVATES the control wherever it lands, so the safest interior point
    ///   is the rect center (a corner landing can miss the hit area entirely;
    ///   observed: Brave tab close X, 28×28 AXButton, click landed 2.8 pt in).
    /// - `edge`: the minimal-delta clamp for position-SENSITIVE controls whose
    ///   click POINT is the intent (slider thumbs, scrollbars, value
    ///   indicators) and for second-class rows/tiles (a row may be a text
    ///   field or list row where the clicked offset matters). Centering those
    ///   would silently jump the value/selection, so keep the smallest move
    ///   that lands inside the rect.
    enum Snap: String, Sendable {
        case center
        case edge
    }

    /// Roles whose click POINT carries meaning. These are first-class controls
    /// that must NOT be center-snapped. Editable text keeps the caret at the
    /// clicked offset, combo boxes open/settle at the clicked row. Scrollbar-ish
    /// roles are listed here even though the resolver's role filter currently
    /// excludes some as containers — the semantics belong with the routing
    /// math, not the filter.
    static let positionSensitiveRoles: Set<String> = [
        "AXSlider", "AXScrollBar", "AXValueIndicator",
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        // Tabs and radio buttons carry position/drag semantics: a near-miss must
        // edge-clamp to the clicked offset, never bullseye. Chromium exposes tabs
        // as AXRadioButton (AxTab/AXTabGroup where a distinct role exists).
        "AXRadioButton", "AXTab", "AXTabGroup"
    ]

    struct Candidate {
        let key: String
        let rect: CGRect
        let inset: CGFloat
        let tier: Tier
        /// AX role, needed for the snap-mode decision. Empty for the P0 static
        /// harness, which keeps first-class center snapping.
        let role: String
        /// True for a tab synthesized from a ✕-anchored strip.
        let synth: Bool
        /// Strip container for a synthesized tab (legitimacy scoping).
        let strip: CGRect?

        init(key: String, rect: CGRect, inset: CGFloat, tier: Tier, role: String = "",
             synth: Bool = false, strip: CGRect? = nil) {
            self.key = key
            self.rect = rect
            self.inset = inset
            self.tier = tier
            self.role = role
            self.synth = synth
            self.strip = strip
        }
    }

    enum Decision {
        case directHit(candidate: Candidate, others: [(key: String, dist: CGFloat)])
        case noCandidate
        case ambiguous(scored: [(candidate: Candidate, dist: CGFloat)], tie: CGFloat)
        case redirect(candidate: Candidate, corrected: CGPoint, boundaryDist: CGFloat,
                      snap: Snap, edgeCore: Bool)
    }

    static func route(point: CGPoint, candidates: [Candidate], tolerance: CGFloat,
                      tieEpsilon: CGFloat = DecisionCore.tieEpsilon) -> Decision {
        // Direct-hit priority belongs to actionable controls only. A first-class
        // hit is native behaviour, exactly as before.
        if let hit = candidates.first(where: { $0.rect.contains(point) && $0.tier == .firstClass }) {
            return directHit(hit, point: point, candidates: candidates)
        }
        // Direct hit on ONLY a second-class container: do not passthrough yet.
        // A first-class control within tolerance is rescued from the container's
        // direct-hit shadow (the YouTube seek-bar band). Otherwise the container
        // keeps today's passthrough behaviour.
        if let container = candidates.first(where: { $0.rect.contains(point) }) {
            if let near = preferredNearMiss(point: point, candidates: candidates,
                                            tolerance: tolerance, tieEpsilon: tieEpsilon,
                                            firstClassOnly: true) {
                return near
            }
            return directHit(container, point: point, candidates: candidates)
        }
        // Near-miss: prefer first-class, fall back to second-class only when no
        // first-class candidate is in tolerance. The ambiguity guard applies
        // WITHIN the chosen tier (it never compares a tile against a control).
        return preferredNearMiss(point: point, candidates: candidates,
                                 tolerance: tolerance, tieEpsilon: tieEpsilon) ?? .noCandidate
    }

    private static func directHit(_ hit: Candidate, point: CGPoint,
                                  candidates: [Candidate]) -> Decision {
        // A position-agnostic first-class control whose AX rect is larger than
        // its real hit region: direct hits outside the live core are re-aimed
        // at the bullseye. Inside the core, and for every position-sensitive
        // role / second-class container, native passthrough is unchanged.
        if snapMode(for: hit) == .center, !isWithinCenterCore(point, rect: hit.rect) {
            return .redirect(candidate: hit, corrected: centerPoint(into: hit.rect),
                             boundaryDist: 0, snap: .center, edgeCore: true)
        }
        let others = candidates
            .filter { $0.key != hit.key }
            .map { (key: $0.key, dist: boundaryDistance(point, $0.rect)) }
            .sorted { $0.dist < $1.dist }
        return .directHit(candidate: hit, others: others)
    }

    /// Nearest in-tolerance candidate, tier-aware. Returns nil when nothing is
    /// within tolerance. Boundary-distance semantics (d > 0, d <= tolerance) and
    /// the tie maths are unchanged.
    private static func preferredNearMiss(point: CGPoint, candidates: [Candidate],
                                          tolerance: CGFloat,
                                          tieEpsilon: CGFloat,
                                          firstClassOnly: Bool = false) -> Decision? {
        var firstClass: [(Candidate, CGFloat)] = []
        var secondClass: [(Candidate, CGFloat)] = []
        for c in candidates {
            let d = boundaryDistance(point, c.rect)
            guard d > 0, d <= tolerance else { continue }
            if c.tier == .firstClass { firstClass.append((c, d)) }
            else { secondClass.append((c, d)) }
        }
        let scored = (firstClass.isEmpty && !firstClassOnly ? secondClass : firstClass)
            .sorted { $0.1 < $1.1 }
        guard let best = scored.first else { return nil }
        if scored.count >= 2, scored[1].1 - best.1 <= tieEpsilon {
            return .ambiguous(scored: scored, tie: scored[1].1 - best.1)
        }
        let snap = snapMode(for: best.0)
        let corrected = snap == .center
            ? centerPoint(into: best.0.rect)
            : clampPoint(point, into: best.0.rect, inset: best.0.inset)
        return .redirect(candidate: best.0, corrected: corrected,
                         boundaryDist: best.1, snap: snap, edgeCore: false)
    }

    /// Center-snap only first-class, position-agnostic controls. Second-class
    /// rows/tiles and the position-sensitive roles keep the edge clamp.
    static func snapMode(for candidate: Candidate) -> Snap {
        guard candidate.tier == .firstClass,
              !positionSensitiveRoles.contains(candidate.role) else { return .edge }
        return .center
    }

    /// Bullseye of a rect, inset by max(2 pt, 10% of the smaller side) so a
    /// sub-10 pt control still lands safely interior rather than on an edge.
    /// (A symmetric inset does not move the midpoint; it documents the safety
    /// margin the redirect guarantees.)
    static func centerPoint(into rect: CGRect) -> CGPoint {
        let inset = max(2, min(rect.width, rect.height) * 0.1)
        let r = rect.insetBy(dx: inset, dy: inset)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// True when `point` is within `coreRadiusFraction` of the rect's
    /// half-dimension on BOTH axes — the control's known-live inner region.
    static func isWithinCenterCore(_ point: CGPoint, rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return true }
        let dx = abs(point.x - rect.midX)
        let dy = abs(point.y - rect.midY)
        return dx <= rect.width * 0.5 * coreRadiusFraction
            && dy <= rect.height * 0.5 * coreRadiusFraction
    }

    static func clampPoint(_ p: CGPoint, into rect: CGRect, inset: CGFloat) -> CGPoint {
        let r = rect.insetBy(dx: inset, dy: inset)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX),
                       y: min(max(p.y, r.minY), r.maxY))
    }

    /// A candidate plus its boundary distance, for multi-target indication.
    struct ScoredCandidate: Sendable {
        let candidate: Candidate
        let dist: CGFloat
    }

    /// All in-tolerance candidates for indication, nearest first, tie-break
    /// smaller area. First-class only when any first-class is in range (a
    /// container never competes with a control); `limit` bounds validation work.
    /// The winner of a click is always element 0.
    static func displayCandidates(point: CGPoint, candidates: [Candidate],
                                  tolerance: CGFloat, limit: Int = 3) -> [ScoredCandidate] {
        var firstClass: [ScoredCandidate] = []
        var secondClass: [ScoredCandidate] = []
        for c in candidates {
            let d = boundaryDistance(point, c.rect)
            guard d <= tolerance else { continue }
            let scored = ScoredCandidate(candidate: c, dist: d)
            if c.tier == .firstClass { firstClass.append(scored) }
            else { secondClass.append(scored) }
        }
        // INVARIANT: winner/primary is the NEAREST confirmed candidate by boundary
        // distance, regardless of tier (ties -> smaller area). Tier no longer
        // grants priority — it only decides snap mode and the direct-hit rule.
        // ONE carve-out: a second-tier DIRECT hit (dist == 0) is never a target —
        // a list row must not swallow its embedded first-class control (and with
        // no first-class nearby it is excluded too: direct hits stay native).
        let pool = firstClass + secondClass.filter { $0.dist > 0 }
        // A container masquerading as a control (Brave exposes the whole tab
        // strip as an AXTab-sized element, and a strip-sized AXGroup as a tile)
        // encloses several real controls. It is never a target on its own: drop
        // any candidate that encloses 2+ others, comparing against BOTH tiers.
        let allScored = firstClass + secondClass
        let filtered = pool.filter { candidate in
            allScored.filter { other in
                other.candidate.key != candidate.candidate.key
                    && candidate.candidate.rect.contains(other.candidate.rect)
            }.count < 2
        }
        let ordered = filtered.sorted { a, b in
            if a.dist != b.dist { return a.dist < b.dist }
            let areaA = a.candidate.rect.width * a.candidate.rect.height
            let areaB = b.candidate.rect.width * b.candidate.rect.height
            if areaA != areaB { return areaA < areaB }
            return a.candidate.key < b.candidate.key
        }
        return Array(ordered.prefix(limit))
    }

    static func boundaryDistance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        if r.contains(p) { return 0 }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return sqrt(dx * dx + dy * dy)
    }
}

// MARK: - Single legitimacy policy (renderer hit-test at the DESTINATION)

/// The ONLY source of legitimacy for a ring or a redirect. The renderer's own
/// hit-test at the exact destination point decides:
/// - `confirmed`: the hit answer covers the destination and corresponds to the
///   candidate (candidate contains the hit, or a real control occupies the same
///   frame — e.g. a tab's close ✕ under the tab group's frame).
/// - `mismatch`: the renderer answered with something that is not the candidate.
/// - `unknown`: the hit-test errored / returned nothing.
///
/// Fail-closed: only `confirmed` allows a ring or a redirect. `mismatch` and
/// `unknown` both pass the original click through untouched.
final class LegitimacyPolicy: @unchecked Sendable {
    enum Verdict: String, Sendable {
        case confirmed
        case mismatch
        case unknown
    }

    private struct Entry {
        let verdict: Verdict
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

    /// Approximate frame equality used for "the renderer answered with this exact
    /// control surface" (Brave's tab group vs the tab's AXRadioButton).
    private static func sameFrame(_ a: CGRect, _ b: CGRect, eps: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= eps && abs(a.minY - b.minY) <= eps &&
        abs(a.width - b.width) <= eps && abs(a.height - b.height) <= eps
    }

    private static func axFrame(_ el: AXUIElement) -> CGRect? {
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

    /// Validate `candidate` at `destination` for app `pid`. `siblings` are the
    /// first-class candidate frames in the same snapshot (identity proxy).
    func validate(pid: pid_t, generation: UInt64, key: String,
                  candidate: CGRect, destination: CGPoint,
                  siblings: [CGRect], strip: CGRect? = nil) -> Verdict {
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
                                    destination: destination, siblings: siblings,
                                    strip: strip)
        lock.lock()
        cache[cacheKey] = Entry(verdict: verdict, generation: generation, stamp: now)
        lock.unlock()
        return verdict
    }

    private static func evaluate(pid: pid_t, candidate: CGRect,
                                 destination: CGPoint, siblings: [CGRect],
                                 strip: CGRect?) -> Verdict {
        guard pid > 0, pid != getpid() else { return .unknown }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(destination.x), Float(destination.y),
                                               &element) == .success,
              let element, let hitFrame = axFrame(element) else { return .unknown }
        // Synthesized tab: the strip is the authority. The renderer answered with
        // real content INSIDE the strip (the tab div / strip group) -> confirmed;
        // anything outside the strip -> mismatch. Errors stay unknown (fail-closed).
        if let strip {
            return strip.contains(hitFrame) ? .confirmed : .mismatch
        }
        // The renderer's answer must cover the destination at all.
        guard hitFrame.contains(destination) else { return .mismatch }
        // Candidate itself or a descendant/equal surface answered.
        if candidate.contains(hitFrame) { return .confirmed }
        // An equal-frame real control answered (Brave: tab group frame == tab).
        if siblings.contains(where: { sameFrame($0, hitFrame) }) { return .confirmed }
        // Or the renderer answered with a control row/strip that HOLDS a real
        // control at this point (Brave's tab strip group covering the tabs).
        if siblings.contains(where: { hitFrame.contains($0) }) { return .confirmed }
        // Candidate is inside the hit but the hit is an unrelated container.
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

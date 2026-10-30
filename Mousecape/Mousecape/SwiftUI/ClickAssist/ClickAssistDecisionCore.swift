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
        /// Accessible name evidence (title/description). Unnamed candidates are
        /// legitimate but are demoted visually — a weak ghost signal, never a veto.
        let label: String

        init(key: String, rect: CGRect, inset: CGFloat, tier: Tier, role: String = "",
             label: String = "") {
            self.key = key
            self.rect = rect
            self.inset = inset
            self.tier = tier
            self.role = role
            self.label = label
        }
    }

    enum Decision {
        case directHit(candidate: Candidate, others: [(key: String, dist: CGFloat)])
        case noCandidate
        case ambiguous(scored: [(candidate: Candidate, dist: CGFloat)], tie: CGFloat)
        case redirect(candidate: Candidate, corrected: CGPoint, boundaryDist: CGFloat,
                      snap: Snap, edgeCore: Bool)
    }

    /// The target a shared resolution picked, with everything needed both to
    /// draw it and to execute it.
    struct Target: Sendable {
        let candidate: Candidate
        let dist: CGFloat
        let destination: CGPoint
        let snap: Snap
    }

    /// THE single decision. Rendering and execution both consume this — they may
    /// never disagree about what was chosen.
    enum Resolution: Sendable {
        case winner(Target, alternates: [Target])
        case ambiguous(scored: [(candidate: Candidate, dist: CGFloat)], tie: CGFloat)
        case none
    }

    /// One selection rule, used by BOTH the indicator and the click:
    /// 1. in-tolerance, minus elements that enclose two or more others;
    /// 2. the element the pointer is INSIDE wins (first-class preferred, then the
    ///    smallest) — a row is indicated and clicked on itself;
    /// 3. otherwise the nearest in-tolerance candidate, first-class preferred,
    ///    with a tie guard that is the same on both paths.
    static func resolve(point: CGPoint, candidates: [Candidate], tolerance: CGFloat,
                        tieEpsilon: CGFloat = DecisionCore.tieEpsilon) -> Resolution {
        var scored: [(Candidate, CGFloat)] = []
        for c in candidates {
            let d = boundaryDistance(point, c.rect)
            guard d <= tolerance else { continue }
            scored.append((c, d))
        }
        guard !scored.isEmpty else { return .none }
        let all = scored
        let filtered = scored.filter { cand, _ in
            all.filter { other in
                other.0.key != cand.key
                    && DecisionCore.isNested(cand.rect, other.0.rect, margin: 0)
            }.count < 2
        }
        guard !filtered.isEmpty else { return .none }

        let area = { (c: Candidate) in c.rect.width * c.rect.height }
        let containing = filtered.filter { $0.1 == 0 }
        let pool: [(Candidate, CGFloat)]
        if !containing.isEmpty {
            let fc = containing.filter { $0.0.tier == .firstClass }.sorted { area($0.0) < area($1.0) }
            if !fc.isEmpty {
                pool = fc
            } else {
                // The pointer sits inside a second-tier element. TWO kinds:
                // - GROUPING WRAPPER: encloses other candidates (a chip-bar DIV
                //   wrapping chips, a player bar wrapping the seek slider). It has
                //   no click semantics of its own — never self-indicate; only the
                //   embedded controls (when within tolerance) are targets.
                // - ACTIONABLE LEAF: encloses nothing (MyHome's AXCell sidebar
                //   rows). Clicking it means something — self-indicate.
                let container = containing.sorted { area($0.0) < area($1.0) }.first!.0
                // INTERSECT-based grouping: a container visually holding controls
                // (player bar over its slider/mute) often has a slightly offset
                // frame, so strict containment misses them. Intersection matches
                // what the user sees.
                let inside = filtered
                    .filter { $0.0.tier == .firstClass && container.rect.intersects($0.0.rect) }
                    .sorted { $0.1 < $1.1 }
                let enclosesAny = candidates.contains {
                    $0.key != container.key && container.rect.intersects($0.rect)
                }
                if !inside.isEmpty {
                    pool = inside
                } else if enclosesAny {
                    pool = []   // dead zone inside a wrapper: fail-closed silence
                } else {
                    pool = [(container, 0)]
                }
            }
        } else {
            let fc = filtered.filter { $0.0.tier == .firstClass }.sorted { $0.1 < $1.1 }
            if fc.isEmpty {
                let sc = filtered.filter { $0.0.tier != .firstClass }.sorted { $0.1 < $1.1 }
                guard let best = sc.first else { return .none }
                if sc.count >= 2, sc[1].1 - best.1 <= tieEpsilon {
                    return .ambiguous(scored: sc.prefix(3).map { ($0.0, $0.1) },
                                      tie: sc[1].1 - best.1)
                }
                pool = [best]
            } else {
                if fc.count >= 2, fc[1].1 - fc[0].1 <= tieEpsilon {
                    return .ambiguous(scored: fc.prefix(3).map { ($0.0, $0.1) },
                                      tie: fc[1].1 - fc[0].1)
                }
                pool = fc
            }
        }

        // Ordered candidates: the primary pool first (position decided by the
        // rules above), then every remaining in-tolerance candidate by distance.
        // They are FALLBACKS only: if the primary fails renderer validation (the
        // elapsed-time label under the pointer), the next legitimate candidate —
        // the seek slider right beside it — is what gets indicated and clicked.
        var seen = Set<String>()
        var ordered: [(Candidate, CGFloat)] = []
        for entry in pool.sorted(by: { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if area(a.0) != area(b.0) { return area(a.0) < area(b.0) }
            return a.0.key < b.0.key
        }) where seen.insert(entry.0.key).inserted {
            ordered.append(entry)
        }
        for entry in filtered.sorted(by: { $0.1 < $1.1 }) where seen.insert(entry.0.key).inserted {
            ordered.append(entry)
        }

        let targets = ordered
            .map { cand, d -> Target in
                let snap = snapMode(for: cand)
                let dest = snap == .center
                    ? centerPoint(into: cand.rect)
                    : clampPoint(point, into: cand.rect, inset: cand.inset)
                return Target(candidate: cand, dist: d, destination: dest, snap: snap)
            }
        guard let winner = targets.first else { return .none }
        return .winner(winner, alternates: Array(targets.dropFirst().prefix(4)))
    }

    /// Click semantics layered on the shared resolution. Passthrough decisions
    /// (direct hits) are reported as such so the caller leaves the event alone.
    static func route(point: CGPoint, candidates: [Candidate], tolerance: CGFloat,
                      tieEpsilon: CGFloat = DecisionCore.tieEpsilon) -> Decision {
        switch resolve(point: point, candidates: candidates,
                       tolerance: tolerance, tieEpsilon: tieEpsilon) {
        case .none:
            return .noCandidate
        case .ambiguous(let scored, let tie):
            return .ambiguous(scored: scored, tie: tie)
        case .winner(let target, _):
            guard target.dist == 0 else {
                return .redirect(candidate: target.candidate, corrected: target.destination,
                                 boundaryDist: target.dist, snap: target.snap, edgeCore: false)
            }
            // Inside the element: native, except a first-class button clicked
            // outside its live core — that one is re-aimed at its bullseye.
            if target.snap == .center, !isWithinCenterCore(point, rect: target.candidate.rect) {
                return .redirect(candidate: target.candidate,
                                 corrected: centerPoint(into: target.candidate.rect),
                                 boundaryDist: 0, snap: .center, edgeCore: true)
            }
            let others = candidates
                .filter { $0.key != target.candidate.key }
                .map { (key: $0.key, dist: boundaryDistance(point, $0.rect)) }
                .sorted { $0.dist < $1.dist }
            return .directHit(candidate: target.candidate, others: others)
        }
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

    /// Margin (pt) that makes a nesting test tolerant of Chromium frames that
    /// are offset by 1-2 pt (a menu container vs the button it wraps). ONE
    /// constant: the ring filter and the resolver's enclosure test share it.
    static let nestMargin: CGFloat = 8

    /// The ONE containment predicate. `outer` must contain `inner` expanded by
    /// `margin` points; the default margin is the ring's tolerance. `margin: 0`
    /// is the strict containment used by the resolver's wrapper filter, so both
    /// places express containment the same way.
    static func isNested(_ outer: CGRect, _ inner: CGRect,
                         margin: CGFloat = nestMargin) -> Bool {
        outer.insetBy(dx: -margin, dy: -margin).contains(inner)
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
    /// Thin view over `resolve()` so the ring and the click can never pick
    /// different winners. Order is the resolution order; the first is the winner.
    ///
    /// USER RULE (final arbiter): no shown ring may contain or be contained by
    /// another shown ring — outer grouping wrappers (rect contains another
    /// cached candidate) are dropped, AND inner secondaries (non-winner rects
    /// inside the winner) are suppressed, with the winner always kept.
    static func displayCandidates(point: CGPoint, candidates: [Candidate],
                                  tolerance: CGFloat, limit: Int = 3) -> [ScoredCandidate] {
        switch resolve(point: point, candidates: candidates, tolerance: tolerance) {
        case .winner(let winner, let alternates):
            let scored = ([winner] + alternates).prefix(limit).map {
                ScoredCandidate(candidate: $0.candidate, dist: $0.dist)
            }
            // The shown set is an ANTICHAIN drawn from the scored set ONLY:
            // element 0 (the winner) is never dropped, and an alternate is
            // dropped when it nests — either way round — with the winner or with
            // anything already kept. The wrapper test deliberately ignores the
            // full `candidates` list: a cached ✕ inside the winning tab frame
            // must not evict the tab the click actually hits.
            guard let winnerEntry = scored.first else { return [] }
            var kept: [ScoredCandidate] = [winnerEntry]
            for cand in scored.dropFirst() {
                let w = winnerEntry.candidate.rect
                if isNested(w, cand.candidate.rect) || isNested(cand.candidate.rect, w) {
                    continue
                }
                let nestsWithKept = kept.contains { entry in
                    let r = entry.candidate.rect
                    return isNested(r, cand.candidate.rect) || isNested(cand.candidate.rect, r)
                }
                if nestsWithKept { continue }
                kept.append(cand)
            }
            // Safety: the winner is unconditional, so this can only fire if the
            // scored set were empty — kept empty is impossible, fallback stays.
            return kept.isEmpty ? Array(scored.prefix(1)) : Array(kept.prefix(limit))
        case .ambiguous, .none:
            return []
        }
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
        /// Strong evidence: the renderer's hit-test answered WITH this candidate
        /// (frame inside it, or exactly its own surface).
        case confirmed
        /// Weak evidence: geometry-only (container answers, fullscreen incoherent
        /// answers). Legitimate enough to assist, but the ring is demoted.
        case confirmedWeak
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
                  siblings: [CGRect]) -> Verdict {
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
                                 destination: CGPoint, siblings: [CGRect]) -> Verdict {
        guard pid > 0, pid != getpid() else { return .unknown }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(destination.x), Float(destination.y),
                                               &element) == .success,
              let element, let hitFrame = axFrame(element) else { return .unknown }
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

/// Identity continuity for a control seen twice (cached rect vs a fresh AX rect).
/// Pure geometry, shared by the live tap and the headless suite.
enum FrameContinuity {
    /// Largest per-edge movement between two frames (pt).
    static func delta(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(max(abs(a.minX - b.minX), abs(a.maxX - b.maxX)),
            max(abs(a.minY - b.minY), abs(a.maxY - b.maxY)))
    }

    /// Intersection area as a fraction of the SMALLER rect's area (IoU-style
    /// lower bound). 0 when the frames are disjoint; 1 when one contains the other.
    static func overlapFraction(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let smaller = min(a.width * a.height, b.width * b.height)
        guard smaller > 0 else { return 0 }
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        return (inter.width * inter.height) / smaller
    }

    /// Target-relative drift tolerance: a small control tolerates little movement
    /// (down to 6 pt) and a large one more (up to 24 pt). A redirect is cancelled
    /// at or beyond `limit`, OR when the fresh frame lost identity continuity
    /// (overlap below half of the smaller area): a moved-but-overlapping frame is
    /// the same control, a disjoint one is a different control.
    static func moved(_ a: CGRect, _ b: CGRect) -> Bool {
        let limit = min(24, max(6, 0.25 * min(a.width, a.height)))
        return delta(a, b) >= limit || overlapFraction(a, b) < 0.5
    }
}

/// One gesture's translation, latched exactly once at the DOWN. `let` fields make
/// mid-gesture recomputation impossible: drags and the up apply this value
/// verbatim regardless of snapshot, target or resolver changes.
struct GestureLatch: Sendable {
    let delta: CGVector
    let target: String
    let snap: DecisionCore.Snap
    let edgeCore: Bool
}

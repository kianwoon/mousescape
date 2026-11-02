// baseline-guard:allow new standalone prototype file, no prior baseline possible
import CoreGraphics
import Foundation
import QuartzCore

/// Shared range for settings, resolver evidence, rings and click delivery.
enum ClickAssistTolerance {
    static let range: ClosedRange<CGFloat> = 8...32
    static let defaultValue: CGFloat = 12

    static func validated(_ value: CGFloat) -> CGFloat {
        let finite = value.isFinite ? value : defaultValue
        return min(max(finite, range.lowerBound), range.upperBound)
    }
}

/// The single source of routing math. The CGEventTap router calls `route()` in its
/// callback; the P2a targeting overlay calls the SAME `route()` on the SAME published
/// snapshot. The overlay therefore renders the router's decision by construction and
/// carries zero targeting math of its own.
/// Evidence verdict published by the resolver and consumed by the agent.
/// Defined here (agent-safe, AX-free) so the tap, overlay and cache can use it
/// without compiling the AX-backed `LegitimacyPolicy` implementation.
enum ClickAssistVerdict: String, Sendable {
    case confirmed
    case confirmedWeak
    case mismatch
    case unknown
}

enum DecisionCore {
    /// Only an exact distance tie is ambiguous; a uniquely nearer target wins.
    static let tieEpsilon: CGFloat = 0
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
        // Custom menu items can contain a horizontal strip of actions (e.g.
        // reactions). Their item frame is not one position-agnostic button.
        "AXMenuItem", "AXMenuBarItem",
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
        /// Evidence published by the resolver for the targets NEAREST the pointer.
        /// The tap reads these; it never computes them (no AX on the callback).
        let verdict: ClickAssistVerdict
        let chromeEligible: Bool
        let evidenceGeneration: UInt64
        /// Collection time of the evidence (0 = none). Age is measured from here,
        /// never from snapshot publish time.
        let collectedAt: CFTimeInterval

        init(key: String, rect: CGRect, inset: CGFloat, tier: Tier, role: String = "",
             label: String = "", verdict: ClickAssistVerdict = .unknown,
             chromeEligible: Bool = false, evidenceGeneration: UInt64 = 0,
             collectedAt: CFTimeInterval = 0) {
            self.key = key
            self.rect = rect
            self.inset = inset
            self.tier = tier
            self.role = role
            self.label = label
            self.verdict = verdict
            self.chromeEligible = chromeEligible
            self.evidenceGeneration = evidenceGeneration
            self.collectedAt = collectedAt
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
    /// 3. otherwise the nearest in-tolerance candidate, regardless of category,
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
            // Distance wins across control categories. A nearer selectable row
            // must not lose to a farther first-class control.
            let nearest = filtered.sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0.key < $1.0.key
            }
            guard let best = nearest.first else { return .none }
            if nearest.count >= 2, nearest[1].1 - best.1 <= tieEpsilon {
                return .ambiguous(scored: nearest.prefix(3).map { ($0.0, $0.1) },
                                  tie: nearest[1].1 - best.1)
            }
            pool = [best]
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

    /// Fresh pointer-area targets can be published without waiting for global
    /// discovery. Ambiguous/empty results still need the rotating tree walk.
    /// Call only with candidates collected in THIS cycle, never the cached union.
    static func needsGlobalDiscovery(point: CGPoint, freshCandidates: [Candidate],
                                      tolerance: CGFloat, consecutiveLocalSkips: Int = 0) -> Bool {
        // Bound deferral so an incompletely discovered parent cannot hide an
        // undiscovered child forever (e.g. a tab whose close button was missed).
        if consecutiveLocalSkips >= 4 { return true }
        if case .winner = resolve(point: point, candidates: freshCandidates,
                                  tolerance: tolerance) { return false }
        return true
    }

    /// A current-cycle, strongly validated direct control can reach publication
    /// before redundant window discovery. Never use union/cache entries here.
    static func canDeferPointerWalk(point: CGPoint, freshCandidates: [Candidate],
                                    tolerance: CGFloat, consecutiveLocalSkips: Int) -> Bool {
        guard consecutiveLocalSkips < 4,
              !freshCandidates.contains(where: { GeometryPolicy.usesNativeRowAction($0.role) }),
              case .winner(let winner, _) = resolve(point: point,
                candidates: freshCandidates, tolerance: tolerance) else { return false }
        return winner.dist == 0 && winner.candidate.tier == .firstClass
            && winner.candidate.verdict == .confirmed
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
        // A symmetric inset cannot change the center, but can make a thin
        // rectangle null. Read the original midpoint directly.
        return CGPoint(x: rect.midX, y: rect.midY)
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
        // A track can be thinner than twice the requested inset. CGRect's
        // insetBy then becomes null/infinite; clamp each axis toward its center
        // instead, without ever constructing an empty rectangle.
        let dx = min(max(inset, 0), rect.width / 2)
        let dy = min(max(inset, 0), rect.height / 2)
        return CGPoint(x: min(max(p.x, rect.minX + dx), rect.maxX - dx),
                       y: min(max(p.y, rect.minY + dy), rect.maxY - dy))
    }

    /// A candidate plus its boundary distance, for multi-target indication.
    struct ScoredCandidate: Sendable {
        let candidate: Candidate
        let dist: CGFloat
    }

    /// All in-tolerance candidates for indication, nearest first, tie-break
    /// smaller area. First-class only when any first-class is in range (a
    /// container never competes with a control); `limit` bounds validation work.
    /// One indicated target: exactly the shared resolution winner. Never show
    /// an alternate that delivery might not select, or silently fall back to it.
    static func displayCandidates(point: CGPoint, candidates: [Candidate],
                                  tolerance: CGFloat, limit: Int = 3) -> [ScoredCandidate] {
        guard limit > 0 else { return [] }
        if case .winner(let winner, _) = resolve(point: point, candidates: candidates,
                                                 tolerance: tolerance) {
            return [ScoredCandidate(candidate: winner.candidate, dist: winner.dist)]
        }
        return []
    }

    /// Offset of the target by the same Euclidean radius used for routing.
    static func toleranceOutline(rect: CGRect, tolerance: CGFloat) -> CGPath {
        CGPath(roundedRect: rect.insetBy(dx: -tolerance, dy: -tolerance),
               cornerWidth: tolerance, cornerHeight: tolerance, transform: nil)
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

/// Identity continuity for a control seen twice (cached rect vs a fresh AX rect).
/// Pure geometry, shared by the live tap and the headless suite.
enum FrameContinuity {
    /// A cached target must be recollected when its live AX geometry changes.
    /// This is stricter than delivery drift tolerance: stale geometry must not
    /// win selection ahead of the control at its new position.
    static func needsGeometryRefresh(cached: CGRect, live: CGRect?) -> Bool {
        guard let live, GeometryPolicy.isValidFrame(live) else { return true }
        return delta(cached, live) > 1
    }

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

/// Published-evidence freshness. Display and activation have DIFFERENT windows:
/// the ring may keep showing evidence across a slow cycle, but a redirect must
/// act only on evidence that is still current enough to be safe.
enum ClickAssistEvidence {
    /// Shared with resolver pointer generations: sub-2pt motion is sensor drift,
    /// not a new aim or a native sidebar drag.
    static let pointerMoveEpsilon: CGFloat = 2
    /// Ring/overlay may display evidence collected within this window.
    /// A shown ring must expire with the evidence required for its click.
    static let activationMaxAgeMs: Double = 400
    static let displayMaxAgeMs: Double = activationMaxAgeMs

    /// Bound AX work per cycle while allowing proven mismatches to be removed
    /// before confirming the nearest remaining target. Unknown results stop early.
    static let maxEvidenceCandidatesPerCycle = 3

    enum State: String, Sendable {
        case fresh
        case missing
        case stale
        case wrongGeneration = "wrong-generation"
    }

    static func state(evidenceGeneration: UInt64, currentGeneration: UInt64,
                      ageMs: Double, maxAgeMs: Double) -> State {
        if evidenceGeneration == 0 { return currentGeneration == 0 ? .fresh : .missing }
        if evidenceGeneration != currentGeneration { return .wrongGeneration }
        if ageMs > maxAgeMs { return .stale }
        return .fresh
    }

    /// Ring display staleness (single site: overlay/render).
    static func displayState(evidenceGeneration: UInt64, currentGeneration: UInt64,
                             ageMs: Double) -> State {
        state(evidenceGeneration: evidenceGeneration, currentGeneration: currentGeneration,
              ageMs: ageMs, maxAgeMs: displayMaxAgeMs)
    }

    /// Redirect/AXPress staleness (single site: tap delivery gate).
    static func activationState(evidenceGeneration: UInt64, currentGeneration: UInt64,
                                ageMs: Double) -> State {
        state(evidenceGeneration: evidenceGeneration, currentGeneration: currentGeneration,
              ageMs: ageMs, maxAgeMs: activationMaxAgeMs)
    }

    /// Evidence age is COLLECTION time: a cycle that did not complete evidence for
    /// a target must publish that target's previous timestamp untouched.
    static func renewedCollectedAt(existing: CFTimeInterval,
                                   validatedAt: CFTimeInterval?) -> CFTimeInterval {
        validatedAt ?? existing
    }
}

/// One off-callback AXPress activation request. Pure value, testable. The
/// deadline is ABSOLUTE at issue time and never renewed on receipt.
/// A completed green-ring click, not a request to click an arbitrary point.
struct BackgroundClickWire: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var rect: CGRect
    var point: CGPoint { CGPoint(x: x, y: y) }
}

enum BackgroundClickPolicy {
    static let eventMarker: Int64 = 0x4D434243
    static func eligible(targetPID: Int32, foregroundPID: Int32?, candidate: DecisionCore.Candidate,
                         generation: UInt64, point: CGPoint, now: Double,
                         nativeTolerance: CGFloat = 0,
                         targetWindowFocused: Bool = true) -> Bool {
        // An open menu already owns native mouse tracking, even when its
        // application's PID differs from the foreground PID. It may have no
        // AXWindow at all; consuming it for window activation loses the click.
        guard candidate.role != "AXMenuItem", candidate.role != "AXMenuBarItem",
              let foregroundPID, foregroundPID > 0, targetPID > 0,
              // A frontmost app's unfocused standard window behaves like a
              // background app: native routing spends the click on focus.
              (foregroundPID != targetPID || !targetWindowFocused
                || GeometryPolicy.usesNativeRowAction(candidate.role)),
              candidate.verdict == .confirmed,
              (candidate.rect.contains(point)
                || (GeometryPolicy.usesNativeRowAction(candidate.role)
                    && DecisionCore.boundaryDistance(point, candidate.rect) <= nativeTolerance)),
              candidate.collectedAt > 0 else { return false }
        return ClickAssistEvidence.activationState(evidenceGeneration: candidate.evidenceGeneration,
            currentGeneration: generation, ageMs: (now - candidate.collectedAt) * 1000) == .fresh
    }
    /// Hand tremor during a click emits sub-point leftMouseDragged events.
    /// Releasing the captured down for that noise hands the gesture back to
    /// native routing, which only activates the background window (the user
    /// must click again). Track controls keep every drag: movement is intent.
    static func isClickPointerNoise(role: String, down: CGPoint, current: CGPoint) -> Bool {
        !GeometryPolicy.trackRoles.contains(role)
            && hypot(current.x - down.x, current.y - down.y) <= ClickAssistEvidence.pointerMoveEpsilon
    }
    static func matches(_ click: BackgroundClickWire, rect: CGRect) -> Bool {
        click.x.isFinite && click.y.isFinite && GeometryPolicy.isValidFrame(click.rect)
            && click.rect.width > 0 && click.rect.height > 0 && rect.contains(click.point)
            && FrameContinuity.delta(click.rect, rect) <= 1
    }
}

struct AXPressRequest: Sendable {
    var backgroundClick: BackgroundClickWire? = nil
    let requestID: UUID
    let targetKey: String
    let pid: pid_t
    let generation: UInt64
    let issuedAt: CFTimeInterval
    let expiryMs: Double
    let deadline: CFTimeInterval

    init(requestID: UUID = UUID(), targetKey: String, pid: pid_t, generation: UInt64,
         issuedAt: CFTimeInterval, expiryMs: Double = AXPressGate.defaultExpiryMs) {
        self.requestID = requestID
        self.targetKey = targetKey
        self.pid = pid
        self.generation = generation
        self.issuedAt = issuedAt
        self.expiryMs = expiryMs
        self.deadline = issuedAt + expiryMs / 1000
    }
}

/// The worker's pre-activation gate. Never retries via synthetic.
enum AXPressGate {
    static let defaultExpiryMs: Double = 150

    enum Rejection: String, Sendable {
        case expired
        case expiredAtExecution = "expired-at-execution"
        case staleGeneration = "stale-generation"
        case identityMismatch = "identity-mismatch"
        case duplicate
        case queueFull = "queue-full"
    }

    static func rejection(request: AXPressRequest, currentGeneration: UInt64,
                          identityMatches: Bool, now: CFTimeInterval) -> Rejection? {
        if now >= request.deadline { return .expired }
        if request.generation != currentGeneration { return .staleGeneration }
        if !identityMatches { return .identityMismatch }
        return nil
    }

    /// Evaluated immediately before the service performs the AX press: a request that aged
    /// while queued is rejected there, even if it passed the earlier gate.
    static func executionExpired(_ request: AXPressRequest, now: CFTimeInterval) -> Bool {
        now >= request.deadline
    }
}

/// Bounded-queue + deduplication admission. Pure so the callback accounting is
/// testable: at most `maxPendingPresses` in flight, and one activation per target
/// inside the dedupe window.
enum AXPressAdmission {
    static let maxPendingPresses = 4
    static let dedupeWindowMs: Double = 250

    struct Decision: Equatable, Sendable {
        let rejection: AXPressGate.Rejection
        let dtMs: Double
    }

    static func evaluate(targetKey: String, now: CFTimeInterval,
                         lastTarget: String?, lastIssuedAt: CFTimeInterval?,
                         pending: Int) -> Decision? {
        if pending >= maxPendingPresses {
            return Decision(rejection: .queueFull, dtMs: 0)
        }
        if lastTarget == targetKey, let lastIssuedAt {
            let dtMs = (now - lastIssuedAt) * 1000
            if dtMs < dedupeWindowMs {
                return Decision(rejection: .duplicate, dtMs: dtMs)
            }
        }
        return nil
    }
}

/// Gesture ownership is independent of activation outcome: once an AXPress token
/// is taken the tap consumes the rest of the gesture (drags and the matching up).
enum GestureOwnership {
    static func consumes(tokenActive: Bool, isDown: Bool, isDrag: Bool, isUp: Bool) -> Bool {
        guard tokenActive else { return false }
        return isDrag || isUp
    }
}

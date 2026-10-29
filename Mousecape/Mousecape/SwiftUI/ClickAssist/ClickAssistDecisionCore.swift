// baseline-guard:allow new standalone prototype file, no prior baseline possible
import CoreGraphics
import Foundation

/// The single source of routing math. The CGEventTap router calls `route()` in its
/// callback; the P2a targeting overlay calls the SAME `route()` on the SAME published
/// snapshot. The overlay therefore renders the router's decision by construction and
/// carries zero targeting math of its own.
enum DecisionCore {
    /// Two candidates closer than this in boundary distance are treated as ambiguous.
    static let tieEpsilon: CGFloat = 2.0
    /// A cache snapshot older than this is treated as stale even if still marked valid.
    static let cacheMaxAge: CFTimeInterval = 1.0

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
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"
    ]

    struct Candidate {
        let key: String
        let rect: CGRect
        let inset: CGFloat
        let tier: Tier
        /// AX role, needed for the snap-mode decision. Empty for the P0 static
        /// harness, which keeps first-class center snapping.
        let role: String

        init(key: String, rect: CGRect, inset: CGFloat, tier: Tier, role: String = "") {
            self.key = key
            self.rect = rect
            self.inset = inset
            self.tier = tier
            self.role = role
        }
    }

    enum Decision {
        case directHit(candidate: Candidate, others: [(key: String, dist: CGFloat)])
        case noCandidate
        case ambiguous(scored: [(candidate: Candidate, dist: CGFloat)], tie: CGFloat)
        case redirect(candidate: Candidate, corrected: CGPoint, boundaryDist: CGFloat,
                      snap: Snap)
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
                         boundaryDist: best.1, snap: snap)
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

    static func clampPoint(_ p: CGPoint, into rect: CGRect, inset: CGFloat) -> CGPoint {
        let r = rect.insetBy(dx: inset, dy: inset)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX),
                       y: min(max(p.y, r.minY), r.maxY))
    }

    static func boundaryDistance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        if r.contains(p) { return 0 }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return sqrt(dx * dx + dy * dy)
    }
}

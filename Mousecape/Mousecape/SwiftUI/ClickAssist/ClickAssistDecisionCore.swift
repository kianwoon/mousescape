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

    struct Candidate {
        let key: String
        let rect: CGRect
        let inset: CGFloat
        let tier: Tier
    }

    enum Decision {
        case directHit(candidate: Candidate, others: [(key: String, dist: CGFloat)])
        case noCandidate
        case ambiguous(scored: [(candidate: Candidate, dist: CGFloat)], tie: CGFloat)
        case redirect(candidate: Candidate, corrected: CGPoint, boundaryDist: CGFloat)
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
        return .redirect(candidate: best.0,
                         corrected: clampPoint(point, into: best.0.rect, inset: best.0.inset),
                         boundaryDist: best.1)
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

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

    struct Candidate {
        let key: String
        let rect: CGRect
        let inset: CGFloat
    }

    enum Decision {
        case directHit(candidate: Candidate, others: [(key: String, dist: CGFloat)])
        case noCandidate
        case ambiguous(scored: [(candidate: Candidate, dist: CGFloat)], tie: CGFloat)
        case redirect(candidate: Candidate, corrected: CGPoint, boundaryDist: CGFloat)
    }

    static func route(point: CGPoint, candidates: [Candidate], tolerance: CGFloat,
                      tieEpsilon: CGFloat = DecisionCore.tieEpsilon) -> Decision {
        // Direct-hit priority: inside a cached actionable rect -> untouched.
        if let hit = candidates.first(where: { $0.rect.contains(point) }) {
            let others = candidates
                .filter { $0.key != hit.key }
                .map { (key: $0.key, dist: boundaryDistance(point, $0.rect)) }
                .sorted { $0.dist < $1.dist }
            return .directHit(candidate: hit, others: others)
        }
        // Boundary distance to the nearest point inside each rect; outside only.
        var scored: [(Candidate, CGFloat)] = []
        for c in candidates {
            let d = boundaryDistance(point, c.rect)
            if d > 0, d <= tolerance { scored.append((c, d)) }
        }
        scored.sort { $0.1 < $1.1 }
        guard let best = scored.first else { return .noCandidate }
        // Ambiguity guard.
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

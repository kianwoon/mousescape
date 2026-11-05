import CoreGraphics
import Foundation

/// Overlap ownership by SIBLING Z-ORDER. AX children are ordered back-to-front,
/// so a LATER sibling (same AX parent) that overlaps a candidate is painted on
/// top of it and owns that area. The candidate's ring/click rect is cut back
/// to the largest region no later sibling covers.
///
/// MyHome: the childless Settings button (175x93) is followed by the status
/// image, status text, sparkle image and input field it spills over, so it
/// keeps only its top row. YouTube card: the menu button comes AFTER the title
/// link, so the link loses the corner and the button keeps its full frame.
/// Pure geometry plus an injected sibling source (unit-testable); the resolver
/// supplies the AX reads, the tap never calls this.
enum OverlapOwnership {

    /// Frame tolerance (pt) for enclosure tests (same as legitimacy's identity).
    static let frameEpsilon: CGFloat = 1

    /// At most this many candidates near the pointer are examined per publish.
    static let maxCandidatesPerCycle = 4

    /// At most this many later siblings are read per candidate.
    static let maxLaterSiblings = 16

    /// A parent with more children than this is not inspected (huge lists).
    static let maxParentChildren = 200

    /// A sibling frame with a side longer than this (pt) is not evidence.
    static let maxSiblingExtent: CGFloat = 16384

    /// Sibling answers are reused for this long (s) per (pid, key, frame).
    static let siblingCacheTTL: TimeInterval = 0.5

    /// Cache entries above which expired answers are pruned.
    static let siblingCacheMaxEntries = 64

    /// The later siblings that actually cover part of `rect`, clipped to it.
    /// nil = fail closed (a later sibling encloses the whole candidate: an
    /// overlay/wrapper, not content on top of part of it).
    static func coveringSiblings(of rect: CGRect, laterSiblings: [CGRect]) -> [CGRect]? {
        var out: [CGRect] = []
        for s in laterSiblings {
            guard s.origin.x.isFinite, s.origin.y.isFinite, s.width.isFinite, s.height.isFinite,
                  s.width > 0, s.height > 0,
                  s.width <= maxSiblingExtent, s.height <= maxSiblingExtent else { continue }
            if s.insetBy(dx: -frameEpsilon, dy: -frameEpsilon).contains(rect) { return nil }
            let clip = rect.intersection(s)
            guard !clip.isNull, clip.width > 0, clip.height > 0 else { continue }
            out.append(clip)
        }
        return out
    }

    /// Largest axis-aligned rectangle inside `rect` that no obstacle covers.
    /// Its left/right edges lie on `rect`'s or an obstacle's x-edges; for each
    /// such band the tallest free vertical gap is the best height. nil = no
    /// free area. Raw extents throughout, so no negative-size rect is built.
    static func largestFreeRect(in rect: CGRect, avoiding obstacles: [CGRect]) -> CGRect? {
        let xs = Array(Set([rect.minX, rect.maxX] + obstacles.flatMap { [$0.minX, $0.maxX] }))
            .filter { $0 >= rect.minX && $0 <= rect.maxX }.sorted()
        var best: CGRect?
        var bestArea: CGFloat = 0
        for (i, left) in xs.enumerated() {
            for right in xs[(i + 1)...] {
                let width = right - left
                guard width > 0 else { continue }
                let blocking = obstacles.filter { $0.minX < right && $0.maxX > left }
                    .sorted { $0.minY < $1.minY }
                var top = rect.minY
                var gaps: [(y: CGFloat, h: CGFloat)] = []
                for o in blocking {
                    if o.minY > top { gaps.append((top, o.minY - top)) }
                    top = max(top, o.maxY)
                }
                if rect.maxY > top { gaps.append((top, rect.maxY - top)) }
                for g in gaps where width * g.h > bestArea {
                    bestArea = width * g.h
                    best = CGRect(x: left, y: g.y, width: width, height: g.h)
                }
            }
        }
        return best
    }

    /// `rect` minus everything its later siblings cover, or nil when it stays
    /// as it is (no covering sibling, an enclosing overlay, or nothing left).
    static func trimmed(_ rect: CGRect, laterSiblings: [CGRect]) -> (rect: CGRect, cutBy: [CGRect])? {
        guard let covering = coveringSiblings(of: rect, laterSiblings: laterSiblings),
              !covering.isEmpty,
              let free = largestFreeRect(in: rect, avoiding: covering),
              free != rect else { return nil }
        return (free, covering)
    }

    /// Trimmed rects keyed by candidate key (unchanged candidates are absent).
    /// `siblingsAbove(key)` answers the frames of the candidate's later AX
    /// siblings (nil = unknown: untouched). `items` should already be bounded
    /// to the candidates near the pointer.
    static func trimmedRects(_ items: [(key: String, rect: CGRect)],
                             siblingsAbove: (String) -> [CGRect]?)
        -> [String: (rect: CGRect, cutBy: [CGRect])] {
        var out: [String: (rect: CGRect, cutBy: [CGRect])] = [:]
        for item in items.prefix(maxCandidatesPerCycle) {
            guard let later = siblingsAbove(item.key),
                  let cut = trimmed(item.rect, laterSiblings: later) else { continue }
            out[item.key] = cut
        }
        return out
    }
}

/// Short-lived memo of later-sibling frames so the 25 Hz refresh does not
/// re-query AX for a stable layout. Confined to the resolver's queue.
final class LaterSiblingCache {
    private var entries: [String: (frames: [CGRect]?, stamp: TimeInterval)] = [:]

    func frames(pid: Int32, key: String, rect: CGRect, now: TimeInterval,
                read: () -> [CGRect]?) -> [CGRect]? {
        let cacheKey = "\(pid)|\(key)|\(rect)"
        if let e = entries[cacheKey], now - e.stamp < OverlapOwnership.siblingCacheTTL { return e.frames }
        if entries.count >= OverlapOwnership.siblingCacheMaxEntries {
            entries = entries.filter { now - $0.value.stamp < OverlapOwnership.siblingCacheTTL }
        }
        let answer = read()
        entries[cacheKey] = (answer, now)
        return answer
    }
}

// baseline-guard:allow service-only AX frame reader (moved out of the agent runtime)
import ApplicationServices
import CoreGraphics

/// The one frame reader. Every AX geometry read in Click Assist goes through
/// here, so a non-finite frame (±infinity / NaN) can never reach centerPoint →
/// event.location (inf − inf = NaN traps the overlay's main-thread render).
/// Callers own their messaging-timeout policy; this reader sets none.
enum AXGeometry {
    static func frame(_ el: AXUIElement) -> CGRect? {
        readFrame(batch: {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el,
                [kAXPositionAttribute, kAXSizeAttribute] as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success else { return nil }
            return values
        }, separate: {
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size else { return nil }
            return [position, size] as CFArray
        })
    }

    /// Frames of every AXScrollArea at or above `start` (nearest first), up to
    /// the window. A scroll area's frame is its visible viewport; the list or
    /// outline inside it reports the full scrolled content extent instead.
    static func scrollViewports(from start: AXUIElement, maxDepth: Int) -> [CGRect] {
        func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success else { return nil }
            return value
        }
        var viewports: [CGRect] = []
        var node: AXUIElement? = start
        for _ in 0..<maxDepth {
            guard let current = node else { break }
            let role = attr(current, kAXRoleAttribute) as? String ?? ""
            if role == (kAXWindowRole as String) { break }
            if role == (kAXScrollAreaRole as String), let viewport = frame(current) {
                viewports.append(viewport)
            }
            guard let parent = attr(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = (parent as! AXUIElement)
        }
        return viewports
    }

    /// Thumb-sized slider → its track. Walks up to `maxDepth` parents (nearest
    /// first, each read under `timeout`), stopping at the web document/window,
    /// and asks GeometryPolicy for the first track-shaped ancestor; falls back
    /// to the thumb's same-row siblings. `trail` lists role+frame per step for
    /// the SLIDER_THUMB_PROMOTE diagnostic. Callers gate on `isThumbLike`.
    static func promotedTrack(for el: AXUIElement, thumb: CGRect, maxDepth: Int,
                              siblingLimit: Int, timeout: Float) -> (track: CGRect?, trail: [String]) {
        func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success else { return nil }
            return value
        }
        func parent(of e: AXUIElement) -> AXUIElement? {
            guard let raw = attr(e, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            let p = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(p, timeout)
            return p
        }
        var trail: [String] = []
        var ancestors: [CGRect] = []
        var node = parent(of: el)
        let directParent = node
        for _ in 0..<maxDepth {
            guard let current = node else { break }
            let role = attr(current, kAXRoleAttribute) as? String ?? "-"
            if role == "AXWebArea" || role == (kAXWindowRole as String) { break }
            let f = frame(current)
            trail.append("\(role)\(f.map { "\($0)" } ?? "nil")")
            if let f { ancestors.append(f) }
            node = parent(of: current)
        }
        if let track = GeometryPolicy.promotedTrackRect(thumb: thumb, ancestors: ancestors) {
            return (track, trail)
        }
        guard let directParent,
              let kids = attr(directParent, kAXChildrenAttribute) as? [AXUIElement] else { return (nil, trail) }
        let siblings = kids.prefix(siblingLimit).filter { !CFEqual($0, el) }.compactMap { frame($0) }
        trail.append("siblings=\(siblings.count)")
        return (GeometryPolicy.promotedTrackRect(thumb: thumb, rowSiblings: siblings), trail)
    }

    /// Frames of the siblings AFTER `el` in its parent's children (AX children
    /// are back-to-front, so these are painted on top of it), at most
    /// `maxSiblings`. nil = unknown (no parent, `el` not among the children, or
    /// more than `maxChildren` children). Each read runs under `timeout`.
    static func laterSiblingFrames(of el: AXUIElement, maxChildren: Int,
                                   maxSiblings: Int, timeout: Float) -> [CGRect]? {
        func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success else { return nil }
            return value
        }
        guard let raw = attr(el, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let parent = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(parent, timeout)
        guard let kids = attr(parent, kAXChildrenAttribute) as? [AXUIElement], kids.count <= maxChildren,
              let index = kids.firstIndex(where: { CFEqual($0, el) }) else { return nil }
        return kids[(index + 1)...].prefix(maxSiblings).compactMap { kid in
            AXUIElementSetMessagingTimeout(kid, timeout)
            return frame(kid)
        }
    }

    /// One live round trip on supporting apps. A partial/unsupported batch uses
    /// the original reader, preserving apps with incomplete batch support.
    /// Nothing is cached, and both paths use the same finite-frame validation.
    static func readFrame(batch: () -> CFArray?, separate: () -> CFArray?) -> CGRect? {
        decode(batch()) ?? decode(separate())
    }

    private static func decode(_ values: CFArray?) -> CGRect? {
        guard let values, CFArrayGetCount(values) == 2 else { return nil }
        let array = values as [CFTypeRef]
        let posRef = array[0], sizeRef = array[1]
        guard
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: origin, size: size)
        guard GeometryPolicy.isValidFrame(rect) else { return nil }
        return rect
    }
}


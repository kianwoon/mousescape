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


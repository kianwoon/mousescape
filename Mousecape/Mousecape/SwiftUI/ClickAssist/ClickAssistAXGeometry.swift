// baseline-guard:allow service-only AX frame reader (moved out of the agent runtime)
import ApplicationServices
import CoreGraphics

/// The one frame reader. Every AX geometry read in Click Assist goes through
/// here, so a non-finite frame (±infinity / NaN) can never reach centerPoint →
/// event.location (inf − inf = NaN traps the overlay's main-thread render).
/// Callers own their messaging-timeout policy; this reader sets none.
enum AXGeometry {
    static func frame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
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


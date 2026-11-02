// baseline-guard:allow service-only AX legitimacy policy (moved out of the agent runtime)
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

final class LegitimacyPolicy: @unchecked Sendable {

    private struct Entry {
        let verdict: ClickAssistVerdict
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
                  siblings: [CGRect], candidateElement: AXUIElement,
                  diagnostic: (String) -> Void) -> ClickAssistVerdict {
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
                                    destination: destination, siblings: siblings,
                                    candidateElement: candidateElement, diagnostic: diagnostic)
        lock.lock()
        cache[cacheKey] = Entry(verdict: verdict, generation: generation, stamp: now)
        lock.unlock()
        return verdict
    }

    private static func evaluate(pid: pid_t, candidate: CGRect, candidateRole: String,
                                 destination: CGPoint, siblings: [CGRect], candidateElement: AXUIElement,
                  diagnostic: (String) -> Void) -> ClickAssistVerdict {
        guard pid > 0, pid != getpid(),
              GeometryPolicy.isActionable(role: candidateRole, hasPressAction: false)
        else { return .unknown }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var element: AXUIElement?
        // One bounded query. A failed or incoherent answer is not confirmation;
        // the next resolver beat can try again without delaying this publish.
        let hitResult = AXUIElementCopyElementAtPosition(app, Float(destination.x),
                                                         Float(destination.y), &element)
        let answeredFrame = element.flatMap { axFrame($0) }
        if candidateRole == "AXSlider" {
            diagnostic("SLIDER_HIT result=\(hitResult.rawValue) destination=\(destination) candidate=\(candidate) live=\(String(describing: axFrame(candidateElement))) hit=\(String(describing: answeredFrame)) role=\(element.map { role(of: $0) } ?? "-")")
        }
        guard hitResult == .success, let element, let hitFrame = answeredFrame else {
            diagnostic("VERDICT_REJECT unknown reason=hit-failed result=\(hitResult.rawValue) destination=\(destination) candidate=\(candidate)")
            return .unknown
        }
        // A successful hit on a surface that does not cover the requested point
        // is positive geometry disagreement, not a transport/timeout uncertainty.
        guard hitFrame.contains(destination) else {
            diagnostic("VERDICT_REJECT mismatch reason=hit-misses-destination hitRole=\(role(of: element)) hit=\(hitFrame) destination=\(destination) candidate=\(candidate)")
            return .mismatch
        }
        if let enabled = attr(element, kAXEnabledAttribute) as? Bool, !enabled {
            diagnostic("VERDICT_REJECT mismatch reason=hit-disabled hitRole=\(role(of: element)) hit=\(hitFrame) candidate=\(candidate)")
            return .mismatch
        }
        if candidateRole == "AXButton" || candidateRole == "AXSlider" {
            diagnostic("LEGITIMACY_HIT candidateRole=\(candidateRole) liveFrame=\(String(describing: axFrame(candidateElement))) candidate=\(candidate) hitRole=\(role(of: element)) hit=\(hitFrame) title=\(attr(element, kAXTitleAttribute) ?? "-" as CFString)")
        }
        // An actionable candidate must be the answered surface, or contain the
        // answered child (e.g. a button's text). A surrounding page/video group
        // cannot confirm a hidden control simply because its rectangle fits.
        if sameFrame(candidate, hitFrame) || candidate.contains(hitFrame) {
            return .confirmed
        }
        // OpenCode's clipped tab label extends beyond the link's AX bounds.
        // Prove direct ownership by AX identity, rather than broadening geometry
        // acceptance to unrelated text, enclosing groups, or covered controls.
        if candidateRole == "AXLink", role(of: element) == "AXStaticText",
           let parent = attr(element, kAXParentAttribute),
           let liveFrame = axFrame(candidateElement),
           GeometryPolicy.confirmsLinkTextHit(candidateRole: candidateRole,
               hitRole: role(of: element),
               enabled: (attr(candidateElement, kAXEnabledAttribute) as? Bool) != false
                   && (attr(candidateElement, "AXHidden") as? Bool) != true,
               frameMatches: sameFrame(candidate, liveFrame),
               hitParentIsCandidate: CFEqual(parent, candidateElement),
               destinationInsideCandidate: liveFrame.contains(destination)) {
            return .confirmed
        }
        // Browser chrome can answer an inner close button with its parent tab.
        // Require that parent to itself be an actionable sibling control.
        var actions: CFArray?
        let hasPress = AXUIElementCopyActionNames(element, &actions) == .success
            && (actions as? [String])?.contains("AXPress") == true
        if hitFrame.contains(candidate),
           GeometryPolicy.isActionable(role: role(of: element), hasPressAction: hasPress),
           siblings.contains(where: { sameFrame($0, hitFrame) }) {
            return .confirmed
        }
        // Video players can answer for their live seek slider. Require both
        // actual slider capability and an exact live ancestor, never containment
        // alone (which would also admit unrelated overlays and page furniture).
        if candidateRole == "AXSlider",
           GeometryPolicy.sliderHitCoversDestination(candidate: candidate, hit: hitFrame,
                                                      destination: destination) {
            var sliderActions: CFArray?
            _ = AXUIElementCopyActionNames(candidateElement, &sliderActions)
            let actions = sliderActions as? [String] ?? []
            var valueSettable = DarwinBoolean(false)
            let canSetValue = AXUIElementIsAttributeSettable(candidateElement,
                kAXValueAttribute as CFString, &valueSettable) == .success && valueSettable.boolValue
            let adjustable = canSetValue || (actions.contains("AXIncrement") && actions.contains("AXDecrement"))
            var node: AXUIElement? = candidateElement
            var hitIsAncestor = false
            var playerAncestors: [AXUIElement] = []
            for _ in 0..<24 {
                guard let current = node else { break }
                let currentRole = role(of: current)
                // Stop at the web document: a whole page/window cannot vouch
                // for a slider that a different surface covers.
                if currentRole == "AXWebArea" || currentRole == "AXWindow" { break }
                let currentFrame = currentRole == "AXGroup" ? axFrame(current) : nil
                if currentRole == "AXGroup",
                   (attr(current, "AXDOMClassList") as? [String] ?? []).contains("html5-video-player") {
                    playerAncestors.append(current)
                }
                if CFEqual(current, element) || (currentRole == "AXGroup"
                    && role(of: element) == "AXGroup"
                    && currentFrame.map { sameFrame($0, hitFrame) } == true) {
                    hitIsAncestor = true
                    break
                }
                guard let parent = attr(current, kAXParentAttribute),
                      CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                node = (parent as! AXUIElement)
            }
            // A player's video surface is often a SIBLING of its controls.
            // Trace the actual hit's ancestry too, rather than guessing that
            // its own rectangle must equal the slider's outer player wrapper.
            if !hitIsAncestor, role(of: element) == "AXGroup" {
                let surfaceClasses = attr(element, "AXDOMClassList") as? [String] ?? []
                let isVideoSurface = surfaceClasses.contains("html5-main-video")
                    || surfaceClasses.contains("html5-video-container")
                var hitNode: AXUIElement? = element
                for _ in 0..<24 {
                    guard let current = hitNode else { break }
                    let hitRole = role(of: current)
                    if hitRole == "AXWebArea" || hitRole == "AXWindow" || hitRole == "AXScrollArea" { break }
                    let samePlayer = playerAncestors.contains { CFEqual($0, current) }
                    if GeometryPolicy.confirmsSharedVideoPlayer(isVideoSurface: isVideoSurface,
                        sameLivePlayer: samePlayer) {
                        hitIsAncestor = true
                        diagnostic("SLIDER_SHARED_PLAYER identity=true videoSurface=true")
                        break
                    }
                    guard let parent = attr(current, kAXParentAttribute),
                          CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    hitNode = (parent as! AXUIElement)
                }
            }
            let liveFrameMatches = axFrame(candidateElement).map { sameFrame($0, candidate) } == true
            let enabled = (attr(candidateElement, kAXEnabledAttribute) as? Bool) != false
                && (attr(candidateElement, "AXHidden") as? Bool) != true
            diagnostic("SLIDER_CONTAINER adjustable=\(adjustable) frameMatches=\(liveFrameMatches) enabled=\(enabled) ancestor=\(hitIsAncestor)")
            if GeometryPolicy.confirmsSliderContainer(candidateRole: candidateRole,
                enabled: enabled, adjustable: adjustable, frameMatches: liveFrameMatches,
                hitIsAncestor: hitIsAncestor) { return .confirmed }
        }
        // Confirm the actual tab control's live relationship to the tab hit,
        // even when the tab group itself has no control role or press action.
        if ["AXButton", "AXRadioButton", "AXTab"].contains(candidateRole),
           hitFrame.contains(candidate),
           let liveFrame = axFrame(candidateElement), sameFrame(candidate, liveFrame) {
            var candidateActions: CFArray?
            let candidatePress = AXUIElementCopyActionNames(candidateElement, &candidateActions) == .success
                && (candidateActions as? [String])?.contains("AXPress") == true
            var node: AXUIElement? = candidateElement
            var hitIsAncestor = false
            var hasChrome = false
            var hasWebArea = false
            for _ in 0..<32 {
                guard let current = node else { break }
                let currentRole = role(of: current)
                hasWebArea = hasWebArea || currentRole == "AXWebArea"
                hasChrome = hasChrome || currentRole == "AXTabGroup" || currentRole == "AXToolbar"
                // Chromium returns a separate AXGroup proxy for the tab's
                // AXRadioButton. Match only that live tab ancestor's frame;
                // generic groups and unrelated enclosing surfaces do not qualify.
                let tabProxy = axFrame(current).map {
                    GeometryPolicy.isTabHitProxy(ancestorRole: currentRole,
                        hitRole: role(of: element), ancestorFrame: $0, hitFrame: hitFrame)
                } == true
                // Multi-tab Brave windows answer with a sibling AXGroup proxy
                // of the live AXTabGroup, rather than an individual tab proxy.
                // Require both identical strip bounds and the same actual parent.
                let stripProxy: Bool
                if currentRole == "AXTabGroup", let frame = axFrame(current),
                   let parent = attr(current, kAXParentAttribute),
                   let hitParent = attr(element, kAXParentAttribute) {
                    stripProxy = GeometryPolicy.isTabStripHitProxy(
                        ancestorRole: currentRole, hitRole: role(of: element),
                        ancestorFrame: frame, hitFrame: hitFrame,
                        sharesLiveParent: CFEqual(parent, hitParent))
                } else {
                    stripProxy = false
                }
                hitIsAncestor = hitIsAncestor || CFEqual(current, element) || tabProxy || stripProxy
                if currentRole == "AXWindow" || hasWebArea { break }
                guard let parent = attr(current, kAXParentAttribute),
                      CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                node = (parent as! AXUIElement)
            }
            diagnostic("LEGITIMACY_CHROME press=\(candidatePress) ancestor=\(hitIsAncestor) chrome=\(hasChrome) web=\(hasWebArea)")
            if GeometryPolicy.confirmsChromeDescendant(
                candidateRole: candidateRole,
                enabled: (attr(candidateElement, kAXEnabledAttribute) as? Bool) != false,
                hasPress: candidatePress, hitIsAncestor: hitIsAncestor,
                hasChrome: hasChrome, hasWebArea: hasWebArea) {
                return .confirmed
            }
        }
        if confirmsByInteriorProbe(app: app, candidate: candidate, centreHit: hitFrame,
                                   centreHitActionable: GeometryPolicy.isActionable(
                                       role: role(of: element), hasPressAction: hasPress),
                                   // Only an enclosing answer needs the (bounded) walk.
                                   centreHitIsAncestor: hitFrame.contains(candidate)
                                       && isAncestor(element, of: candidateElement),
                                   diagnostic: diagnostic) {
            return .confirmed
        }
        diagnostic("VERDICT_REJECT mismatch reason=no-rule centreRole=\(role(of: element)) centreHit=\(hitFrame) destination=\(destination) candidate=\(candidate) liveCandidate=\(String(describing: axFrame(candidateElement))) candidateElementRole=\(role(of: candidateElement))")
        return .mismatch
    }

    private static func isAncestor(_ ancestor: AXUIElement, of element: AXUIElement) -> Bool {
        var node: AXUIElement? = element
        for _ in 0..<GeometryPolicy.occlusionAncestorDepth {
            guard let current = node,
                  let parent = attr(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            let p = parent as! AXUIElement
            if CFEqual(p, ancestor) { return true }
            node = p
        }
        return false
    }

    /// Floating controls (position:fixed pills) can make the renderer's AX
    /// hit-test fall through to the content underneath at some interior
    /// points. When the centre answer is a partial-overlap surface (never a
    /// full cover), re-probe a few interior points: the control answering
    /// for ITSELF (or a child inside it) at any of them proves it is the top
    /// surface there. Same evidence rule as the primary probe — no frame-only
    /// confirmation.
    private static func confirmsByInteriorProbe(app: AXUIElement, candidate: CGRect,
                                                centreHit: CGRect, centreHitActionable: Bool,
                                                centreHitIsAncestor: Bool,
                                                diagnostic: (String) -> Void) -> Bool {
        guard GeometryPolicy.admitsOcclusionProbe(candidate: candidate, centreHit: centreHit,
                                                  centreHitActionable: centreHitActionable,
                                                  centreHitIsAncestor: centreHitIsAncestor)
        else {
            diagnostic("VERDICT_REJECT probe=not-admitted actionable=\(centreHitActionable) ancestor=\(centreHitIsAncestor)")
            return false
        }
        let start = CACurrentMediaTime()
        for point in GeometryPolicy.occlusionProbePoints(in: candidate) {
            guard CACurrentMediaTime() - start < GeometryPolicy.occlusionProbeBudget else { break }
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y),
                                                   &element) == .success,
                  let element, let hit = axFrame(element), hit.contains(point),
                  (attr(element, kAXEnabledAttribute) as? Bool) != false,
                  sameFrame(candidate, hit) || candidate.contains(hit) else {
                var miss: AXUIElement?
                _ = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &miss)
                diagnostic("VERDICT_REJECT probe=miss at=\(point) role=\(miss.map { role(of: $0) } ?? "nil") frame=\(String(describing: miss.flatMap { axFrame($0) })) t=\(Int((CACurrentMediaTime() - start) * 1000))ms")
                continue
            }
            diagnostic("LEGITIMACY_INTERIOR_PROBE confirmed at=\(point) hitRole=\(role(of: element)) centreHit=\(centreHit)")
            return true
        }
        diagnostic("VERDICT_REJECT probe=exhausted t=\(Int((CACurrentMediaTime() - start) * 1000))ms")
        return false
    }

    /// Drop cached verdicts (called on soft/hard invalidation).
    func invalidate() {
        lock.lock()
        cache.removeAll()
        cachedGeneration = 0
        lock.unlock()
    }
}

/// Direct native list actions. These capabilities are never inferred from a
/// title or rectangle, and web ancestry can never authorize a native action.
enum NativeListActionDelivery {
    enum Action { case select, press }
    static func action(for element: AXUIElement, role: String) -> Action? {
        func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success else { return nil }
            return value
        }
        guard (attr(element, kAXEnabledAttribute) as? Bool) != false,
              (attr(element, "AXHidden") as? Bool) != true else { return nil }
        let actualRole = attr(element, kAXRoleAttribute) as? String ?? ""
        let action: Action
        if role == "AXSelectableRow", GeometryPolicy.rowRoles.contains(actualRole) {
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXSelectedAttribute as CFString, &settable) == .success,
                  settable.boolValue else { return nil }
            action = .select
        } else if (role == "AXButton" || role == "AXNativeRowButton"), actualRole == "AXButton" {
            var actions: CFArray?
            guard AXUIElementCopyActionNames(element, &actions) == .success,
                  (actions as? [String])?.contains("AXPress") == true else { return nil }
            action = .press
        } else { return nil }
        var current: AXUIElement? = element
        var selectableRow = false
        var nativeList = false
        for _ in 0..<64 {
            guard let node = current else { return nil }
            let nodeRole = attr(node, kAXRoleAttribute) as? String ?? ""
            if nodeRole == "AXWebArea" { return nil }
            if GeometryPolicy.rowRoles.contains(nodeRole) {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(node, kAXSelectedAttribute as CFString, &settable) == .success,
                   settable.boolValue { selectableRow = true }
            }
            nativeList = nativeList || nodeRole == "AXList" || nodeRole == "AXOutline"
            if nodeRole == "AXWindow" { return selectableRow && nativeList ? action : nil }
            guard let parent = attr(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = (parent as! AXUIElement)
        }
        return nil
    }
    static func perform(_ action: Action, on element: AXUIElement) -> AXError {
        switch action {
        case .select:
            // AppKit outlines expose selection on the owning container even
            // when a row advertises AXSelected but rejects writes to it.
            var node = element
            for _ in 0..<64 {
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                node = parent as! AXUIElement
                var role: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
                let name = role as? String ?? ""
                if name == "AXWebArea" || name == "AXWindow" { break }
                if name == "AXList" || name == "AXOutline" {
                    var settable = DarwinBoolean(false)
                    var rows: CFTypeRef?
                    if AXUIElementIsAttributeSettable(node, kAXSelectedRowsAttribute as CFString, &settable) == .success,
                       settable.boolValue,
                       AXUIElementCopyAttributeValue(node, kAXRowsAttribute as CFString, &rows) == .success,
                       let members = rows as? [AXUIElement], members.contains(where: { CFEqual($0, element) }) {
                        return AXUIElementSetAttributeValue(node, kAXSelectedRowsAttribute as CFString,
                                                            [element] as CFArray)
                    }
                    break
                }
            }
            return AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        case .press: return AXUIElementPerformAction(element, "AXPress" as CFString)
        }
    }
}

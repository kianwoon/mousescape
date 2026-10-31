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
        guard hitResult == .success, let element, let hitFrame = answeredFrame,
              hitFrame.contains(destination) else { return .unknown }
        if let enabled = attr(element, kAXEnabledAttribute) as? Bool, !enabled {
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
            var groupAncestors: [CGRect] = []
            for _ in 0..<24 {
                guard let current = node else { break }
                let currentRole = role(of: current)
                // Stop at the web document: a whole page/window cannot vouch
                // for a slider that a different surface covers.
                if currentRole == "AXWebArea" || currentRole == "AXWindow" { break }
                let currentFrame = currentRole == "AXGroup" ? axFrame(current) : nil
                if let currentFrame { groupAncestors.append(currentFrame) }
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
                var hitNode: AXUIElement? = element
                for _ in 0..<24 {
                    guard let current = hitNode else { break }
                    let hitRole = role(of: current)
                    if hitRole == "AXWebArea" || hitRole == "AXWindow" || hitRole == "AXScrollArea" { break }
                    if hitRole == "AXGroup", let hitAncestorFrame = axFrame(current),
                       groupAncestors.contains(where: {
                           GeometryPolicy.isSliderSharedContainer(candidateAncestor: $0,
                               hitAncestor: hitAncestorFrame, hitSurface: hitFrame,
                               destination: destination)
                       }) {
                        hitIsAncestor = true
                        diagnostic("SLIDER_SHARED_PLAYER frame=\(hitAncestorFrame)")
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

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

        var verdict = Self.evaluate(pid: pid, candidate: candidate,
                                    candidateRole: candidateRole,
                                    destination: destination, siblings: siblings,
                                    candidateElement: candidateElement, diagnostic: diagnostic)
        // Visible = a real click there reaches this app. The app-rooted hit-test
        // above answers for a window buried under other apps (observed: a held
        // Claude window ringed whole-app while the pointer was over Brave).
        // The same app's own stacked windows cover each other too (8 Brave
        // windows observed), so the hit must land in the candidate's window.
        if verdict == .confirmed || verdict == .confirmedWeak {
            if let top = Self.systemWideHit(at: destination) {
                let candidateWindow = Self.attr(candidateElement, kAXWindowAttribute)
                let hitWindow = Self.attr(top.element, kAXWindowAttribute)
                if top.owner != pid {
                    diagnostic("VERDICT_REJECT mismatch reason=covered-by-other-app owner=\(top.owner) pid=\(pid) destination=\(destination)")
                    verdict = .mismatch
                } else if let candidateWindow, let hitWindow, !CFEqual(candidateWindow, hitWindow) {
                    diagnostic("VERDICT_REJECT mismatch reason=covered-by-other-window pid=\(pid) destination=\(destination)")
                    verdict = .mismatch
                }
            } else {
                diagnostic("VERDICT_REJECT unknown reason=system-hit-failed pid=\(pid) destination=\(destination)")
                verdict = .unknown
            }
        }
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
        AXUIElementSetMessagingTimeout(app, GeometryPolicy.legitimacyHitTimeout)
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
        // AppKit Open/Save panels are remote views hosted by
        // openAndSavePanelService: an APP-rooted hit-test stops at the AXSheet
        // (measured 20/20) while the SYSTEM-WIDE hit — the routing a real click
        // takes — reaches Cancel/Open/the cell (20/20). Only an enclosing
        // answer is re-asked; the system answer must come from the same app and
        // be the candidate or lie inside it, so a foreign cover never confirms.
        if hitFrame.contains(candidate),
           let system = systemWideAnswer(at: destination, pid: pid),
           sameFrame(candidate, system.frame) || candidate.contains(system.frame) {
            diagnostic("LEGITIMACY_SYSTEM_HIT confirmed role=\(role(of: system.element)) appHitRole=\(role(of: element))")
            return .confirmed
        }
        // OpenCode's tab label / disclosure-button text extends beyond the AX bounds.
        // Prove direct ownership by AX identity, rather than broadening geometry
        // acceptance to unrelated text, enclosing groups, or covered controls.
        if candidateRole == "AXLink" || candidateRole == "AXButton", role(of: element) == "AXStaticText",
           let parent = attr(element, kAXParentAttribute),
           let liveFrame = axFrame(candidateElement),
           // Chromium may hand back a fresh proxy for the same parent per query,
           // so identity alone is brittle: also accept a parent of the candidate's
           // role whose live frame is the candidate's own.
           GeometryPolicy.confirmsLinkTextHit(candidateRole: candidateRole,
               hitRole: role(of: element),
               enabled: (attr(candidateElement, kAXEnabledAttribute) as? Bool) != false
                   && (attr(candidateElement, "AXHidden") as? Bool) != true,
               frameMatches: sameFrame(candidate, liveFrame),
               hitParentIsCandidate: CFEqual(parent, candidateElement)
                   || (role(of: parent as! AXUIElement) == candidateRole
                       && axFrame(parent as! AXUIElement).map { sameFrame($0, liveFrame) } == true),
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
                // for a slider that a different surface covers. The exception is
                // the page itself answering the hit-test (x.com's player exposes no
                // finer element at its seek bar): nothing else covers the slider,
                // so the slider's own live web document is the proof.
                if currentRole == "AXWebArea", CFEqual(current, element) {
                    hitIsAncestor = true
                    diagnostic("SLIDER_PAGE_ANSWER adjustable=\(adjustable)")
                }
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
            // A thumb-sized slider was promoted to its track: its live frame is
            // the moving knob, which must lie inside the candidate track.
            let liveFrameMatches = axFrame(candidateElement).map {
                sameFrame($0, candidate)
                    || GeometryPolicy.thumbWithinPromotedTrack(thumb: $0, track: candidate)
            } == true
            let enabled = (attr(candidateElement, kAXEnabledAttribute) as? Bool) != false
                && (attr(candidateElement, "AXHidden") as? Bool) != true
            diagnostic("SLIDER_CONTAINER adjustable=\(adjustable) frameMatches=\(liveFrameMatches) enabled=\(enabled) ancestor=\(hitIsAncestor)")
            if GeometryPolicy.confirmsSliderContainer(candidateRole: candidateRole,
                enabled: enabled, adjustable: adjustable, frameMatches: liveFrameMatches,
                hitIsAncestor: hitIsAncestor) { return .confirmed }
        }
        // Div-built video players: the seek bar is a bar-shaped AXPress group and
        // Chromium answers the hit-test with a coarser ANCESTOR of it (the frame's
        // web document or the player container). Accept only when the answer is
        // an exact live ancestor up to the AXWindow, THROUGH web-area/iframe
        // boundaries (the answer can be the outer page's wrapper group); a foreign
        // cover is never an ancestor.
        if candidateRole == "AXPressGroup" {
            var node: AXUIElement? = candidateElement
            var ownsHit = false
            for _ in 0..<48 {
                guard let current = node else { break }
                if CFEqual(current, element) { ownsHit = true; break }
                if role(of: current) == "AXWindow" { break }
                guard let parent = attr(current, kAXParentAttribute),
                      CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                node = (parent as! AXUIElement)
            }
            let liveFrameMatches = axFrame(candidateElement).map { sameFrame($0, candidate) } == true
            let enabled = (attr(candidateElement, kAXEnabledAttribute) as? Bool) != false
                && (attr(candidateElement, "AXHidden") as? Bool) != true
            if GeometryPolicy.confirmsBarPageAnswer(candidateRole: candidateRole, candidate: candidate,
                destination: destination, hitIsOwnWebArea: ownsHit,
                liveFrameMatches: liveFrameMatches, enabled: enabled) {
                diagnostic("BAR_ANCESTOR_ANSWER confirmed candidate=\(candidate)")
                return .confirmed
            }
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
                                   centreHitElement: element, candidateElement: candidateElement,
                                   candidateRole: candidateRole,
                                   diagnostic: diagnostic) {
            return .confirmed
        }
        diagnostic("VERDICT_REJECT mismatch reason=no-rule centreRole=\(role(of: element)) centreHit=\(hitFrame) destination=\(destination) candidate=\(candidate) liveCandidate=\(String(describing: axFrame(candidateElement))) candidateElementRole=\(role(of: candidateElement))")
        return .mismatch
    }

    /// What a real click at `point` reaches (top-most window under it).
    /// nil when the system-wide hit-test fails (not proven: fail closed).
    private static func systemWideHit(at point: CGPoint) -> (element: AXUIElement, owner: pid_t)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, GeometryPolicy.legitimacyHitTimeout)
        var element: AXUIElement?
        var owner: pid_t = 0
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y),
                                               &element) == .success,
              let element, AXUIElementGetPid(element, &owner) == .success else { return nil }
        AXUIElementSetMessagingTimeout(element, GeometryPolicy.legitimacyHitTimeout)
        return (element, owner)
    }

    /// One system-wide hit-test at `point`, accepted only when the answering
    /// element belongs to `pid` and its frame covers the point.
    private static func systemWideAnswer(at point: CGPoint,
                                         pid: pid_t) -> (element: AXUIElement, frame: CGRect)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, GeometryPolicy.legitimacyHitTimeout)
        var element: AXUIElement?
        var owner: pid_t = 0
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y),
                                               &element) == .success,
              let element, AXUIElementGetPid(element, &owner) == .success, owner == pid,
              let frame = axFrame(element), frame.contains(point) else { return nil }
        return (element, frame)
    }

    /// Bounded parent walk. Running out of time is "not proven" (fail closed).
    private static func isAncestor(_ ancestor: AXUIElement, of element: AXUIElement,
                                   deadline: CFTimeInterval) -> Bool {
        var node: AXUIElement? = element
        for _ in 0..<GeometryPolicy.occlusionAncestorDepth {
            guard CACurrentMediaTime() < deadline, let current = node,
                  let parent = attr(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            let p = parent as! AXUIElement
            if CFEqual(p, ancestor) { return true }
            node = p
        }
        return false
    }

    /// True when `hit` IS the candidate's element or lies beneath it. Chromium
    /// can hand back a fresh proxy per query, so a node of the candidate's
    /// role whose live frame equals the candidate's live frame also counts
    /// (same rule as the link-text proof). Running out of time = not owned.
    private static func isOwned(_ hit: AXUIElement, by candidateElement: AXUIElement,
                                candidateRole: String, deadline: CFTimeInterval) -> Bool {
        guard let liveFrame = axFrame(candidateElement) else { return false }
        var node: AXUIElement? = hit
        for _ in 0..<GeometryPolicy.occlusionAncestorDepth {
            guard CACurrentMediaTime() < deadline, let current = node else { return false }
            if CFEqual(current, candidateElement) { return true }
            let currentRole = role(of: current)
            if currentRole == candidateRole,
               axFrame(current).map({ sameFrame($0, liveFrame) }) == true { return true }
            if currentRole == "AXWebArea" || currentRole == "AXWindow" { return false }
            guard let parent = attr(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = (parent as! AXUIElement)
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
                                                centreHitElement: AXUIElement,
                                                candidateElement: AXUIElement,
                                                candidateRole: String,
                                                diagnostic: (String) -> Void) -> Bool {
        // One deadline covers the probes AND the ancestry proof.
        let start = CACurrentMediaTime()
        let deadline = start + GeometryPolicy.occlusionProbeBudget
        // A partial-overlap inert answer is admitted on geometry alone; an
        // enclosing answer needs ancestry, proven lazily (only after a probe
        // has confirmed) so the walk is never paid on the common miss path.
        let inertLeaf = GeometryPolicy.inertLeafRoles.contains(role(of: centreHitElement))
        // An enclosing inert leaf (tweet text under a floating pill) needs no
        // ancestry proof: text is never a cover layer.
        let viaInertLeaf = centreHit.contains(candidate) && inertLeaf && !centreHitActionable
        let enclosing = centreHit.contains(candidate) && !viaInertLeaf
        guard enclosing || GeometryPolicy.admitsOcclusionProbe(candidate: candidate,
                  centreHit: centreHit, centreHitActionable: centreHitActionable,
                  centreHitIsInertLeaf: inertLeaf)
        else {
            diagnostic("VERDICT_REJECT probe=not-admitted actionable=\(centreHitActionable)")
            return false
        }
        /// nil = this point missed; true/false = final verdict.
        func probe(_ point: CGPoint, deadline: CFTimeInterval) -> Bool? {
            var probed: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y),
                                                   &probed) == .success,
                  let element = probed, let hit = axFrame(element), hit.contains(point),
                  (attr(element, kAXEnabledAttribute) as? Bool) != false,
                  sameFrame(candidate, hit) || candidate.contains(hit) else {
                // Reuse the answer already in hand: a second hit-test per miss
                // spent the 15 ms budget before the ownership walk could run.
                let miss = probed
                diagnostic("VERDICT_REJECT probe=miss at=\(point) role=\(miss.map { role(of: $0) } ?? "nil") frame=\(String(describing: miss.flatMap { axFrame($0) })) t=\(Int((CACurrentMediaTime() - start) * 1000))ms")
                return nil
            }
            // Admitted only because the enclosing answer is inert text: the
            // probe must reach the candidate ITSELF (or its own child). Any
            // element merely inside its rect could be a small control of a
            // text-bodied cover sitting over a hidden candidate.
            if viaInertLeaf, !sameFrame(candidate, hit), !CFEqual(element, candidateElement),
               !isAncestor(candidateElement, of: element, deadline: deadline) {
                diagnostic("VERDICT_REJECT probe=inert-leaf-not-own at=\(point) role=\(role(of: element)) t=\(Int((CACurrentMediaTime() - start) * 1000))ms")
                continue
            }
            if enclosing {
                // Ownership first: the probe hit is the candidate or a few hops
                // below it, while a failing ancestor walk can spend the whole
                // budget (measured: timedOut=true at 15 ms on x.com's pill).
                let owned = isOwned(element, by: candidateElement,
                                    candidateRole: candidateRole, deadline: deadline)
                let ancestor = !owned && isAncestor(centreHitElement, of: candidateElement,
                                                    deadline: deadline)
                guard GeometryPolicy.admitsOcclusionProbe(candidate: candidate, centreHit: centreHit,
                          centreHitActionable: centreHitActionable, centreHitIsAncestor: ancestor,
                          probeHitOwnedByCandidate: owned)
                else {
                    let timedOut = CACurrentMediaTime() >= deadline
                    diagnostic("VERDICT_REJECT probe=enclosing-not-ancestor owned=false actionable=\(centreHitActionable) timedOut=\(timedOut) probeRole=\(role(of: element)) t=\(Int((CACurrentMediaTime() - start) * 1000))ms")
                    return false
                }
                if owned {
                    diagnostic("LEGITIMACY_INTERIOR_PROBE confirmed owner=candidate at=\(point) hitRole=\(role(of: element)) centreHit=\(centreHit) actionable=\(centreHitActionable)")
                    return true
                }
            }
            diagnostic("LEGITIMACY_INTERIOR_PROBE confirmed at=\(point) hitRole=\(role(of: element)) centreHit=\(centreHit)")
            return true
        }
        for point in GeometryPolicy.occlusionProbePoints(in: candidate) {
            guard CACurrentMediaTime() < deadline else { break }
            if let verdict = probe(point, deadline: deadline) { return verdict }
        }
        // Chromium answers from its LAST hover hit-test while the point lies
        // in that result's bounds, and fires an async renderer hit-test per
        // query. The probes above have just fired those requests, so the
        // centre re-asked now (and once more after a frame) reaches the real
        // top element. Measured on x.com's pill (diagnostic build, 19/19):
        // every probe answered the covered card, the centre re-ask answered
        // the pill's own avatar. Same identity rule; nothing frame-only.
        let centre = CGPoint(x: candidate.midX, y: candidate.midY)
        let settleDeadline = CACurrentMediaTime() + GeometryPolicy.hitCacheSettleBudget
        for attempt in 0..<GeometryPolicy.hitCacheSettleAttempts {
            if attempt > 0 {
                // Never sleep into an already-spent budget.
                guard CACurrentMediaTime() + GeometryPolicy.hitCacheSettleWait < settleDeadline else { break }
                usleep(useconds_t(GeometryPolicy.hitCacheSettleWait * 1_000_000))
            }
            guard CACurrentMediaTime() < settleDeadline else { break }
            if let verdict = probe(centre, deadline: settleDeadline) {
                if verdict { diagnostic("VERDICT_REJECT_OVERRIDDEN settle=confirmed attempt=\(attempt)") }
                return verdict
            }
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
            nativeList = nativeList || GeometryPolicy.nativeListRoles.contains(nodeRole)
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
                if GeometryPolicy.nativeListRoles.contains(name) {
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

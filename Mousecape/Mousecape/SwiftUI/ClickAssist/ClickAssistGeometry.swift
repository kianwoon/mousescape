// baseline-guard:allow new standalone prototype file, no prior baseline possible
import CoreGraphics
import Foundation

/// What a admitted element IS (drives tier and delivery).
enum CandidateClass: String {
    case direct, track, pressGroup, wideThin, row, tile
}

/// Why an inspected element was NOT admitted (one bucket per policy row).
enum RejectionReason: String {
    case role, secure, nonFinite, degenerate
    /// Does not fit inside its displays, or fills its own window (the page itself).
    case oversized
    /// An AXSlider that is not track-shaped (e.g. a player container).
    case notTrackShaped
    case thinGroupMismatch
    /// A press group with clickable controls inside is a container (a video
    /// player, a page wrapper): ring the controls, never the box.
    case containsControls
    case tileTooSmall, tileTooWide
    /// Rect intersects no known display: nothing can be clicked there.
    case offscreen
    /// Row scrolled (mostly) out of its enclosing scroll area's viewport.
    case scrolledOut
}

struct GeometryVerdict {
    let candidateClass: CandidateClass?
    let rejection: RejectionReason?
    var accepted: Bool { candidateClass != nil }
}

/// The SINGLE admission policy. Every constant that decides whether an AX
/// element can be a click target lives here, and `classify` is the only place
/// they are combined. `collect()` reads one verdict per element.
///
/// Table (first matching row wins; row 9 is the fallthrough). There is no
/// fixed point-size cap: a ring marks what is clickable and visible. After a
/// class row matches, every class passes the same FIT GATE: the rect must lie
/// inside `allowed` (union of the displays it intersects, inflated 1.05× per
/// axis + 2 pt) and must cover < `windowFillLimit` of its reference frame
/// (smallest app window containing its centre, else its displays); otherwise
/// `.oversized`. A rect that intersects no display is `.offscreen`.
/// 1. any non-finite component                         -> .nonFinite
/// 2. width < 4, or height < (width >= 300 ? 2 : 4)    -> .degenerate
/// 3. direct roles                                     -> .direct
/// 4. AXSlider: minSide ≤ 60 OR aspect ≥ 8             -> .track / .notTrackShaped
/// 5. AXGroup + AXPress                                -> .pressGroup
/// 6. AXGroup, width ≥ 300, 2 ≤ height ≤ 6             -> .wideThin
///    (AXGroup thinner than a tile and not wide-thin)   -> .thinGroupMismatch
/// 7. row roles                                        -> .row
/// 8. tile roles: sides ≥ 30, aspect ≤ 3               -> .tile / .tileTooSmall
///                                                              / .tileTooWide
/// 9. otherwise                                        -> .role
///
/// Viewport gate (row roles only, applied by `isVisibleInViewport` after
/// `classify`): a row's AX frame keeps its scrolled-out extent, so a row
/// beneath an Open panel's button bar is still "on screen". The row must show
/// ≥ `rowMinVisibleHeight` pt and ≥ `rowMinVisibleHeightFraction` of its
/// height inside the intersection of its enclosing AXScrollArea frames,
/// otherwise -> .scrolledOut. The published rect stays the full AX frame:
/// legitimacy confirms by exact frame identity with the hit element.
enum GeometryPolicy {
    /// Names and rectangles do not prove that page furniture can be clicked.
    static func isActionable(role: String, hasPressAction: Bool) -> Bool {
        directRoles.contains(role) || admittedTrackRoles.contains(role)
            || role == "AXPressGroup" || role == "AXSelectableRow" || role == "AXNativeRowButton" || hasPressAction
    }

    static func usesNativeRowAction(_ role: String) -> Bool {
        role == "AXSelectableRow" || role == "AXNativeRowButton"
    }

    /// Selection is an explicit action for native sidebar rows even when they
    /// expose no AXPress. Never infer this capability from a row's name/size.
    static func isNativeSelectableRow(role: String, selectionSettable: Bool,
                                       inNativeList: Bool, inWebContent: Bool) -> Bool {
        rowRoles.contains(role) && selectionSettable && inNativeList && !inWebContent
    }

    /// Full-screen sliders may extend across letterboxing beyond their player's
    /// reported AX frame. Confirmation concerns the intended click point.
    static func sliderHitCoversDestination(candidate: CGRect, hit: CGRect,
                                           destination: CGPoint) -> Bool {
        candidate.contains(destination) && hit.contains(destination)
    }

    /// Chromium answers a frame-nested player's hit-test with the frame's own
    /// AXWebArea, never the finer element at its seek bar. Div-built players
    /// (no slider role) expose that bar as a bar-shaped AXPress group, so the
    /// page answering is the only possible answer, not a cover. Accept it only
    /// for a live, enabled, bar-shaped press group whose OWN nearest web
    /// document is the answered surface and that contains the click point.
    static func confirmsBarPageAnswer(candidateRole: String, candidate: CGRect,
                                      destination: CGPoint, hitIsOwnWebArea: Bool,
                                      liveFrameMatches: Bool, enabled: Bool) -> Bool {
        guard candidateRole == "AXPressGroup", hitIsOwnWebArea, liveFrameMatches,
              enabled, candidate.contains(destination) else { return false }
        let minSide = min(candidate.width, candidate.height)
        let aspect = max(candidate.width, candidate.height) / max(minSide, 1)
        return minSide <= trackShortMinSide && aspect >= trackMinAspect
    }

    /// A renderer's inner video surface and a real slider can be siblings.
    /// Require an exact common-container frame in BOTH live ancestry chains,
    /// and keep that container local to the hit surface (not the whole page).
    static func hitWindowIsCoherent(expectedPID: pid_t, hitPID: pid_t,
                                    hitFrame: CGRect, windowFrame: CGRect,
                                    pointer: CGPoint) -> Bool {
        expectedPID > 0 && expectedPID == hitPID && isValidFrame(hitFrame)
            && isValidFrame(windowFrame) && hitFrame.contains(pointer)
            && windowFrame.contains(pointer)
    }

    /// A target tagged with a window other than the live hit window is occluded
    /// by it. 0 pointerWindow (no coherent hit window) or untagged targets
    /// (menus, menu bar, system surfaces) are never dropped.
    static func isOtherWindowTarget(targetWindow: Int?, pointerWindow: Int) -> Bool {
        guard pointerWindow != 0, let targetWindow, targetWindow != 0 else { return false }
        return targetWindow != pointerWindow
    }

    /// Whether the pointer window is the app's focused window. Only a live
    /// hit-window (frame containment cannot tell stacked same-app windows
    /// apart) that is a STANDARD window (panels/HUDs may never become key) and
    /// whose app reports a different focused window is unfocused. Any unread
    /// fact (`focusedMatches == nil`) keeps the conservative answer: focused.
    static func pointerWindowFocused(mode: String, isStandardWindow: Bool,
                                     focusedMatches: Bool?) -> Bool {
        !(mode == "hit-window" && isStandardWindow && focusedMatches == false)
    }

    /// Video pixels and controls must belong to the same actual player.
    /// Dimensions, aspect ratio and equal-looking ancestor bounds are not evidence.
    static func confirmsSharedVideoPlayer(isVideoSurface: Bool, sameLivePlayer: Bool) -> Bool {
        isVideoSurface && sameLivePlayer
    }

    static func confirmsSliderContainer(candidateRole: String, enabled: Bool,
                                         adjustable: Bool, frameMatches: Bool,
                                         hitIsAncestor: Bool) -> Bool {
        candidateRole == "AXSlider" && enabled && adjustable && frameMatches && hitIsAncestor
    }

    static func isTabHitProxy(ancestorRole: String, hitRole: String,
                              ancestorFrame: CGRect, hitFrame: CGRect) -> Bool {
        (ancestorRole == "AXRadioButton" || ancestorRole == "AXTab")
            && hitRole == "AXGroup" && FrameContinuity.delta(ancestorFrame, hitFrame) <= 1
    }

    /// A link's or button's label can report bounds wider than its clickable area
    /// (OpenCode tab links, "Effective permissions" disclosure button).
    /// Only the actual text child can vouch for that live control, at an inside point.
    static func confirmsLinkTextHit(candidateRole: String, hitRole: String,
                                     enabled: Bool, frameMatches: Bool,
                                     hitParentIsCandidate: Bool,
                                     destinationInsideCandidate: Bool) -> Bool {
        (candidateRole == "AXLink" || candidateRole == "AXButton") && hitRole == "AXStaticText" && enabled
            && frameMatches && hitParentIsCandidate && destinationInsideCandidate
    }

    /// Brave can return a separate group representing the entire tab strip.
    /// Equal bounds alone cannot distinguish that proxy from a covering surface.
    static func isTabStripHitProxy(ancestorRole: String, hitRole: String,
                                    ancestorFrame: CGRect, hitFrame: CGRect,
                                    sharesLiveParent: Bool) -> Bool {
        ancestorRole == "AXTabGroup" && hitRole == "AXGroup" && sharesLiveParent
            && isValidFrame(ancestorFrame) && isValidFrame(hitFrame)
            && FrameContinuity.delta(ancestorFrame, hitFrame) <= 1
    }

    /// Chromium may hit-test a tab's group instead of its close button. This
    /// exception requires live ancestry and press capability, never frame alone.
    static func confirmsChromeDescendant(candidateRole: String, enabled: Bool,
                                          hasPress: Bool, hitIsAncestor: Bool,
                                          hasChrome: Bool, hasWebArea: Bool) -> Bool {
        ["AXButton", "AXRadioButton", "AXTab"].contains(candidateRole)
            && enabled && hasPress && hitIsAncestor
            && hasChrome && !hasWebArea
    }

    /// Interior fractions re-probed when the centre hit-test answers with
    /// content BENEATH a floating control. Observed: x.com's "new posts" pill in
    /// Brave — AX hit-testing returns the tweet text under the pill's right half
    /// (and intermittently at its centre), while the left half answers the
    /// AXButton. The centre itself is the primary probe, so it is not repeated.
    static let occlusionProbeFractions: [CGPoint] = [
        CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5),
        CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.5, y: 0.75)
    ]
    /// Wall-clock cap on the extra probes (AX hit-tests are ~1 ms; a hung
    /// renderer must not eat the 60 ms evidence deadline).
    static let occlusionProbeBudget: CFTimeInterval = 0.015
    /// AX messaging timeout for every legitimacy hit-test (app- and system-rooted).
    static let legitimacyHitTimeout: Float = 0.05
    /// Parent hops checked when proving an enclosing centre answer is the
    /// candidate's own ancestor (measured: x.com's pill sits 15 hops below
    /// Brave's AXWebArea; headroom for deeper SPA trees).
    static let occlusionAncestorDepth = 40
    /// Centre re-asks after the interior probes miss (Chromium answers from
    /// its last hover hit-test; the probes' async replies land meanwhile).
    /// Measured on x.com's pill: the immediate re-ask hit 18/19, after one
    /// 30 ms wait 19/19.
    static let hitCacheSettleAttempts = 2
    /// Wait (s) between centre re-asks: about one display frame.
    static let hitCacheSettleWait: TimeInterval = 0.016
    /// Wall-clock cap (s) on the re-asks plus the ownership walk.
    static let hitCacheSettleBudget: CFTimeInterval = 0.03

    static func occlusionProbePoints(in rect: CGRect) -> [CGPoint] {
        occlusionProbeFractions.map {
            CGPoint(x: rect.minX + rect.width * $0.x, y: rect.minY + rect.height * $0.y)
        }
    }

    /// The re-probe is only admitted when the centre answer could NOT be a
    /// cover: a surface that fully encloses the candidate (a modal, sheet or
    /// page layer over it) is a genuine occluder and keeps the mismatch. An
    /// ACTIONABLE centre answer (a popup/menu item covering the centre) is a
    /// real partial occluder too: the centre-aimed redirect would land in it,
    /// so that case stays fail-closed. Only inert content (text, plain groups)
    /// — the renderer falling through a floating control — is re-probed.
    /// An AX ANCESTOR of the candidate can never occlude it: when Brave answers
    /// the whole AXWebArea for x.com's pill, the renderer simply failed to
    /// descend, so enclosing frames are admitted when they are ancestors.
    /// An inert LEAF (a text run, a picture) is content, never a cover layer:
    /// modals, sheets and page layers answer as groups/dialogs/web areas. When
    /// Brave answers x.com's pill centre with the tweet text that runs
    /// underneath it (474x150, enclosing the 180x38 pill), that text is noise,
    /// so an enclosing inert leaf is admitted like a partial-overlap answer.
    /// The re-probe must still land on the candidate itself to confirm.
    static let inertLeafRoles: Set<String> = ["AXStaticText", "AXImage"]

    /// A probe that answers the candidate's OWN element (or a descendant of
    /// it) is identity proof the candidate is the top surface there: a real
    /// cover answers itself, never the control it covers. Brave on x.com
    /// answers the tweet card's AXGroup (encloses, not an ancestor, may carry
    /// AXPress) at the "posted" pill's centre while an interior probe returns
    /// the pill itself — that proof outranks the centre answer's shape/role.
    static func admitsOcclusionProbe(candidate: CGRect, centreHit: CGRect,
                                     centreHitActionable: Bool,
                                     centreHitIsAncestor: Bool = false,
                                     centreHitIsInertLeaf: Bool = false,
                                     probeHitOwnedByCandidate: Bool = false) -> Bool {
        if centreHitIsAncestor || probeHitOwnedByCandidate { return true }
        if centreHitIsInertLeaf && !centreHitActionable { return true }
        return !centreHitActionable && !centreHit.contains(candidate)
    }

    // Row 3 — direct control roles (track roles are excluded: row 4 owns them).
    static let eligibleRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXLink",
        "AXCheckBox", "AXRadioButton",
        "AXMenuItem", "AXMenuBarItem",
        "AXPopUpButton", "AXComboBox", "AXTab", "AXSegmentedControl",
        "AXSlider", "AXDisclosureTriangle",
        "AXTextField", "AXSearchField"
    ]
    // Row 4 — value-control tracks. Legitimately screen-wide and thin.
    static let trackRoles: Set<String> = ["AXSlider", "AXScrollBar", "AXValueIndicator"]
    /// Admission is limited to AXSlider. A page's AXScrollBar / AXValueIndicator
    /// is furniture, never an assist target — the old role filter excluded them
    /// and they must stay excluded (admitting them would ring every page scrollbar).
    static let admittedTrackRoles: Set<String> = ["AXSlider"]
    static var directRoles: Set<String> { eligibleRoles.subtracting(trackRoles) }
    /// A slider must be track-shaped: sliver-thin or ≥ 8:1 (page zoom scales
    /// the control, so a zoomed 3195 × 76 seek bar stays admitted). A
    /// 2289 × 963 "slider" is a player container, not a track.
    static let trackShortMinSide: CGFloat = 60
    static let trackMinAspect: CGFloat = 8
    // Thumb-sized sliders (x.com's video "Seek slider" reports its 30 × 30
    // knob as the AXSlider frame, not the bar). Promote to the enclosing
    // track so the whole bar is a candidate. Never applies to a slider whose
    // own frame is already bar-shaped (isThumbLike gates every path).
    static let thumbMaxSide: CGFloat = 48
    static let thumbMaxAspect: CGFloat = 1.6
    static let promotedTrackMinWidthRatio: CGFloat = 4
    static let promotedTrackMaxHeightFloor: CGFloat = 60
    static let promotedTrackMaxHeightRatio: CGFloat = 3
    static let thumbContainmentSlack: CGFloat = 1
    static let thumbPromoteAncestorDepth = 6
    static let thumbPromoteSiblingLimit = 16
    static let thumbPromoteTimeout: Float = 0.05

    /// A knob-sized, roughly square frame — not a track.
    static func isThumbLike(_ r: CGRect) -> Bool {
        guard isValidFrame(r), r.width > 0, r.height > 0 else { return false }
        let minSide = min(r.width, r.height)
        let aspect = max(r.width, r.height) / minSide
        return r.width <= thumbMaxSide && r.height <= thumbMaxSide && aspect <= thumbMaxAspect
    }

    /// Shape a track promoted from `thumb` must have: wide, and not much taller.
    private static func isPromotableTrack(_ track: CGRect, thumb: CGRect) -> Bool {
        isValidFrame(track)
            && track.width >= promotedTrackMinWidthRatio * thumb.width
            && track.height <= max(promotedTrackMaxHeightFloor, promotedTrackMaxHeightRatio * thumb.height)
    }

    /// The bar a knob rides on: the knob's centre lies within the bar's
    /// x-span (± half a knob, so a knob parked at either end still counts) and
    /// the bar's y-span holds the knob's centre line. A knob is usually TALLER
    /// than its bar (x.com: 30 pt knob on a 3 pt bar), so plain containment
    /// never holds; mere overlap would admit a control row beside the knob.
    private static func knobRides(_ thumb: CGRect, on bar: CGRect) -> Bool {
        let halfKnob = thumb.width / 2, slack = thumbContainmentSlack
        return thumb.midX >= bar.minX - halfKnob && thumb.midX <= bar.maxX + halfKnob
            && thumb.midY >= bar.minY - slack && thumb.midY <= bar.maxY + slack
    }

    /// Promoted track: x-span from the BAR (never the knob, so the published
    /// origin/key stays put while the knob moves or sits past an end), y-span
    /// = bar ∪ knob so the live knob always lies inside the track.
    private static func track(bar: CGRect, thumb: CGRect) -> CGRect {
        let minY = min(bar.minY, thumb.minY), maxY = max(bar.maxY, thumb.maxY)
        return CGRect(x: bar.minX, y: minY, width: bar.width, height: maxY - minY)
    }

    /// Nearest-first ancestor frames: the first track-shaped ancestor the knob
    /// rides on becomes the promoted track; nil when none is.
    static func promotedTrackRect(thumb: CGRect, ancestors: [CGRect]) -> CGRect? {
        guard isThumbLike(thumb) else { return nil }
        for a in ancestors where isValidFrame(a) && knobRides(thumb, on: a) {
            let t = track(bar: a, thumb: thumb)
            if isPromotableTrack(t, thumb: thumb) { return t }
        }
        return nil
    }

    /// Fallback when no ancestor is the track: the siblings that sit on the
    /// knob's row (vertically overlap its centre, same height bound) are the
    /// bar segments; their x-span is the bar.
    static func promotedTrackRect(thumb: CGRect, rowSiblings: [CGRect]) -> CGRect? {
        guard isThumbLike(thumb) else { return nil }
        let maxHeight = max(promotedTrackMaxHeightFloor, promotedTrackMaxHeightRatio * thumb.height)
        let row = rowSiblings.filter { s in isValidFrame(s) && s.height <= maxHeight
            && s.minY <= thumb.midY && s.maxY >= thumb.midY }
        guard let first = row.first else { return nil }
        let bar = row.dropFirst().reduce(first) { $0.union($1) }
        guard knobRides(thumb, on: bar) else { return nil }
        let t = track(bar: bar, thumb: thumb)
        return isPromotableTrack(t, thumb: thumb) ? t : nil
    }

    /// Bound on the resolver's per-element promotion memo.
    static let thumbPromoteMemoLimit = 64

    enum ThumbPromotionSource: String { case promoted, remembered, thumb }

    /// Which rect a thumb-sized slider publishes this cycle: a fresh promotion
    /// wins; on a miss the last promoted track is reused while the knob still
    /// rides on it; otherwise the knob itself.
    static func thumbPromotionDecision(thumb: CGRect, fresh: CGRect?,
                                       remembered: CGRect?) -> (rect: CGRect, source: ThumbPromotionSource) {
        if let fresh { return (fresh, .promoted) }
        if let remembered, thumbWithinPromotedTrack(thumb: thumb, track: remembered) {
            return (remembered, .remembered)
        }
        return (thumb, .thumb)
    }

    /// The live slider frame is the moving thumb while the cached target is
    /// its promoted track: identity still holds while the knob rides on it
    /// (horizontally up to half a knob past either end — x.com parks the knob
    /// there at 0 % / 100 %).
    static func thumbWithinPromotedTrack(thumb: CGRect, track: CGRect) -> Bool {
        guard isThumbLike(thumb) else { return false }
        let slack = thumbContainmentSlack
        return track.insetBy(dx: -thumb.width / 2, dy: -slack).contains(thumb)
            && isPromotableTrack(track, thumb: thumb)
    }
    // Row 6 — wide-thin group (zoomed web seek bar collapsed to 2 pt tall).
    static let wideThinMinWidth: CGFloat = 300
    static let wideThinMinHeight: CGFloat = 2
    static let wideThinMaxHeight: CGFloat = 6
    // Row 7 — row-like containers.
    static let rowRoles: Set<String> = ["AXCell", "AXRow", "AXListItem"]
    static let rowMaxHeight: CGFloat = 200
    static let rowMaxArea: CGFloat = 120_000
    // Viewport gate — rows scrolled under a scroll area's edge. Scrolling clips
    // one edge, so a ≥ 0.5 HEIGHT fraction keeps the row's centre (the
    // legitimacy probe point) inside the viewport.
    static let rowMinVisibleHeightFraction: CGFloat = 0.5
    /// A sliver of a row (a few points peeking above a bar) is not a target.
    static let rowMinVisibleHeight: CGFloat = 8
    /// Parent hops searched for enclosing AXScrollArea viewports.
    static let rowViewportAncestorDepth = 24
    /// Diagnostics only: a scrolled-out drop is logged when the pointer is
    /// within this many points of the row (keeps the log to the hovered area).
    static let rowViewportLogRadius: CGFloat = 80

    /// Pure viewport gate. `viewports` are the frames of every enclosing
    /// AXScrollArea (nearest first); none -> nothing clips the row.
    static func isVisibleInViewport(_ rect: CGRect, viewports: [CGRect]) -> Bool {
        guard let first = viewports.first else { return true }
        let viewport = viewports.dropFirst().reduce(first) { $0.intersection($1) }
        let visible = rect.intersection(viewport)
        guard !visible.isNull, rect.height > 0 else { return false }
        // A fully visible row shorter than the sliver floor is still whole.
        return visible.height >= min(rowMinVisibleHeight, rect.height)
            && visible.height >= rect.height * rowMinVisibleHeightFraction
    }
    // Row 8 — tiles / thumbnails (no press action of their own). The aspect
    // bound is a SHAPE rule: long wrapper strips (1258 × 47) are furniture.
    static let tileRoles: Set<String> = ["AXImage", "AXGroup"]
    static let tileMinDimension: CGFloat = 30
    static let tileMaxAspect: CGFloat = 3
    // FIT GATE — an element covering this fraction of its reference frame is
    // the page/panel itself, not a control.
    static let windowFillLimit: CGFloat = 0.9
    /// Descendants inspected when deciding whether a press group contains
    /// controls. A work bound, not a size cap; only a found control is cached.
    static let containerProbeNodeBudget = 48
    /// Bound on remembered containers per app before the memo resets.
    static let containerCacheLimit = 768
    // Row 2.5 — DISPLAY GATE. `allowed` = union of the displays this rect
    // intersects, inflated 1.05× on each dimension plus 2 pt of rounding slack.
    // All values are AX/CG points, so there is no Retina/pixel scaling here.
    static let displaySlackScale: CGFloat = 1.05
    static let displaySlackPoints: CGFloat = 2

    /// Union of the displays `rect` intersects. nil when it intersects none.
    static func displayUnion(for rect: CGRect, displayBounds: [CGRect]) -> CGRect? {
        let hits = displayBounds.filter { $0.intersects(rect) }
        guard var union = hits.first else { return nil }
        for d in hits.dropFirst() { union = union.union(d) }
        return union
    }

    /// The display-derived admission envelope for `rect`: union of the displays
    /// it intersects, inflated. nil when it intersects no known display.
    static func allowedBounds(for rect: CGRect, displayBounds: [CGRect]) -> CGRect? {
        guard let allowed = displayUnion(for: rect, displayBounds: displayBounds) else { return nil }
        // Centred so a control touching a display edge (or a 1 pt rounding
        // overhang) is not rejected: 1.05× total per axis, 2 pt total slack.
        let dx = (allowed.width * (displaySlackScale - 1) + displaySlackPoints) / 2
        let dy = (allowed.height * (displaySlackScale - 1) + displaySlackPoints) / 2
        return allowed.insetBy(dx: -dx, dy: -dy)
    }

    /// A clickable box with another clickable target lying on it (YouTube's
    /// progress bar over the video) is a container even when the page tree
    /// puts that target in a sibling branch. Same-box duplicates do not count.
    static func isVisualContainer(_ rect: CGRect, among others: [CGRect]) -> Bool {
        others.contains { $0 != rect && rect.contains($0) && FrameContinuity.delta($0, rect) > 1 }
    }

    /// The window an element lives in: the smallest window containing its centre.
    /// Prefers the smallest window that holds the WHOLE rect: with several
    /// overlapping windows of one app (8 stacked Brave windows observed), a
    /// smaller window that merely contains the centre is a different window.
    static func referenceFrame(for rect: CGRect, windows: [CGRect]) -> CGRect? {
        let valid = windows.filter { isValidFrame($0) && $0.width > 0 && $0.height > 0 }
        let slack = displaySlackPoints
        let holding = valid.filter { $0.insetBy(dx: -slack, dy: -slack).contains(rect) }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let pool = holding.isEmpty ? valid.filter { $0.contains(centre) } : holding
        return pool.min { $0.width * $0.height < $1.width * $1.height }
    }

    /// The single finiteness test. Non-finite geometry is never testimony.
    static func isValidFrame(_ r: CGRect) -> Bool {
        r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite
    }

    /// True when the role belongs to ANY policy family (used before the frame
    /// read so a role reject is still diagnosed when AX has no frame yet).
    static func isCandidateRole(_ role: String) -> Bool {
        directRoles.contains(role) || admittedTrackRoles.contains(role)
            || rowRoles.contains(role) || tileRoles.contains(role)
    }

    /// Classify one element. Pure: no AX calls, no logging, no side effects.
    /// `displayBounds` is the per-cycle display list and `windowBounds` the
    /// target app's on-screen window frames, both in AX/CG points.
    static func classify(role: String, hasPressAction: Bool, rect: CGRect,
                         displayBounds: [CGRect], windowBounds: [CGRect] = []) -> GeometryVerdict {
        func reject(_ r: RejectionReason) -> GeometryVerdict {
            GeometryVerdict(candidateClass: nil, rejection: r)
        }
        // 1. Finiteness.
        guard isValidFrame(rect) else { return reject(.nonFinite) }
        // 2. Frame floor (wide elements still admit a 2 pt sliver — zoomed bars).
        guard rect.width >= 4, rect.height >= (rect.width >= 300 ? 2 : 4) else {
            return reject(.degenerate)
        }
        guard let allowed = allowedBounds(for: rect, displayBounds: displayBounds),
              let displays = displayUnion(for: rect, displayBounds: displayBounds) else {
            return reject(.offscreen)
        }
        let minSide = min(rect.width, rect.height)
        let aspect = max(rect.width, rect.height) / max(minSide, 1)

        // 3-9. What the element is (role + shape, never size).
        let cls: CandidateClass
        if directRoles.contains(role) {
            cls = .direct
        } else if admittedTrackRoles.contains(role) {
            guard minSide <= trackShortMinSide || aspect >= trackMinAspect else {
                return reject(.notTrackShaped)
            }
            cls = .track
        } else if role == "AXGroup", hasPressAction {
            cls = .pressGroup
        } else if role == "AXGroup", rect.width >= wideThinMinWidth,
                  rect.height >= wideThinMinHeight, rect.height <= wideThinMaxHeight {
            cls = .wideThin
        } else if role == "AXGroup", minSide < tileMinDimension {
            // A group too thin to be a tile and not wide-thin is a divider sliver.
            return reject(.thinGroupMismatch)
        } else if rowRoles.contains(role) {
            cls = .row
        } else if tileRoles.contains(role) {
            guard minSide >= tileMinDimension else { return reject(.tileTooSmall) }
            guard aspect <= tileMaxAspect else { return reject(.tileTooWide) }
            cls = .tile
        } else {
            // Everything else is page furniture.
            return reject(.role)
        }

        // FIT GATE: visible on a real display, and not the window itself.
        guard allowed.contains(rect) else { return reject(.oversized) }
        let reference = referenceFrame(for: rect, windows: windowBounds) ?? displays
        let covered = rect.intersection(reference)
        if !covered.isNull,
           covered.width * covered.height >= windowFillLimit * reference.width * reference.height {
            return reject(.oversized)
        }
        return GeometryVerdict(candidateClass: cls, rejection: nil)
    }

    /// Tier mapping (unchanged from the pre-refactor guard chain).
    static func tier(for cls: CandidateClass) -> DecisionCore.Tier {
        switch cls {
        case .direct, .track, .pressGroup: return .firstClass
        case .wideThin, .row, .tile: return .secondClass
        }
    }
}

// MARK: - Screen space conversion (shared by resolver / tap / overlay)

/// Coordinate conversions: Cocoa screen space (origin bottom-left of main display,
/// y up) <-> CGEvent/AX global display space (origin top-left of main display, y down).
enum ScreenSpace {
    static var mainHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func cgPoint(fromCocoaScreen p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: mainHeight - p.y)
    }

    static func cgRect(fromCocoaScreen r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    static func fmt(_ p: CGPoint) -> String { String(format: "(%.1f,%.1f)", p.x, p.y) }
    static func fmt(_ v: CGVector) -> String { String(format: "(%.1f,%.1f)", v.dx, v.dy) }
}

/// Equal-footprint alternates for the pointer-guided descent. When several
/// children of one node contain the pointer (stacked same-size player layers),
/// the descent follows only the smallest; the rest are remembered so the
/// sibling rescue can still reach a control living under a layer that was not
/// chosen. Pure so the ordering/bounding is unit-testable offline.
enum GuidedAlternates {
    struct Entry: Equatable {
        let index: Int      // caller-side identity (position in the remembered list)
        let depth: Int      // depth of the alternate node
        let frame: CGRect
    }

    /// Alternates worth walking: frames intersecting `near`, deepest level first
    /// (closest to where the descent died), then original order; at most `limit`.
    static func ordered(_ entries: [Entry], near: CGRect, limit: Int) -> [Entry] {
        guard limit > 0 else { return [] }
        return Array(entries.filter { $0.frame.intersects(near) }
            .sorted { ($0.depth, $1.index) > ($1.depth, $0.index) }
            .prefix(limit))
    }
}

/// Gate for the pointer hit-test ancestry rescue. Climbing a few levels from
/// the hit element only reaches the hovered control's neighbours when the hit
/// is a LOCAL element (x.com: the 461x20 seek-bar group). When a page answers
/// with itself (the AXWebArea while the player controls are hidden), the climb
/// lands near the window and the bounded walk cannot reach the controls, so the
/// rescue is skipped. Pure so the bound is unit-testable offline.
enum HitAncestryRescue {
    static func isLocal(hitFrame: CGRect, windowFrame: CGRect, maxWindowFraction: CGFloat) -> Bool {
        guard hitFrame.width > 0, hitFrame.height > 0,
              windowFrame.width > 0, windowFrame.height > 0 else { return false }
        let hitArea = hitFrame.width * hitFrame.height
        let windowArea = windowFrame.width * windowFrame.height
        return hitArea < windowArea * maxWindowFraction
    }

    /// Which hit element seeds the rescue. The system-wide hit wins when it is
    /// local; when it is the page (x.com over a playing video: the AXWebArea),
    /// the APP-level hit (`seedAtPointer`'s hit-test through the application
    /// element, which answers the 461x20 seek-bar group there) is used if it is
    /// local and overlaps the pointer window. Otherwise nothing runs.
    enum Source: String { case system, app, none }

    static func source(systemIsLocal: Bool, appHitFrame: CGRect?, windowFrame: CGRect?,
                       maxWindowFraction: CGFloat) -> Source {
        if systemIsLocal { return .system }
        guard let appHitFrame, let windowFrame, appHitFrame.intersects(windowFrame),
              isLocal(hitFrame: appHitFrame, windowFrame: windowFrame,
                      maxWindowFraction: maxWindowFraction) else { return .none }
        return .app
    }
}

/// Pointer ownership from the system-wide AX hit (pure). Exclusion is by
/// WINDOW, never by process: the agent's click-through overlay windows must not
/// claim the pointer, but the agent's other windows (its menu-bar item) are
/// ordinary targets. Only the resolver's OWN process is excluded wholesale —
/// the structural self-RPC guard (AX queries into self deadlock).
enum PointerOwnerPolicy {
    /// - Returns: the owner pid, or nil when the hit is unusable/excluded, in
    ///   which case the caller falls back to the frontmost app. The AX hit test
    ///   yields one element, not a z-ordered list, so there is no "next window
    ///   below" to descend to.
    static func owner(hitPid: Int32?, hitWindowID: Int?, selfPid: Int32,
                      excludedWindowIDs: Set<Int>) -> Int32? {
        guard let hitPid, hitPid > 0, hitPid != selfPid else { return nil }
        if let hitWindowID, excludedWindowIDs.contains(hitWindowID) { return nil }
        return hitPid
    }
}

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

    /// A link's clipped label can report bounds wider than its clickable area.
    /// Only the actual text child can vouch for that live link, at an inside point.
    static func confirmsLinkTextHit(candidateRole: String, hitRole: String,
                                     enabled: Bool, frameMatches: Bool,
                                     hitParentIsCandidate: Bool,
                                     destinationInsideCandidate: Bool) -> Bool {
        candidateRole == "AXLink" && hitRole == "AXStaticText" && enabled
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
    static func admitsOcclusionProbe(candidate: CGRect, centreHit: CGRect,
                                     centreHitActionable: Bool,
                                     centreHitIsAncestor: Bool = false) -> Bool {
        if centreHitIsAncestor { return true }
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
    // Row 6 — wide-thin group (zoomed web seek bar collapsed to 2 pt tall).
    static let wideThinMinWidth: CGFloat = 300
    static let wideThinMinHeight: CGFloat = 2
    static let wideThinMaxHeight: CGFloat = 6
    // Row 7 — row-like containers.
    static let rowRoles: Set<String> = ["AXCell", "AXRow", "AXListItem"]
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
    /// CG_WINDOWLIST diagnostic lines logged per call site per resolver run.
    static let cgWindowListNoteLimit = 5
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

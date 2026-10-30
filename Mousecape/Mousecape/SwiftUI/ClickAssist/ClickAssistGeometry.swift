// baseline-guard:allow new standalone prototype file, no prior baseline possible
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

/// What a admitted element IS (drives tier and delivery).
enum CandidateClass: String {
    case direct, track, pressGroup, wideThin, row, tile
}

/// Why an inspected element was NOT admitted (one bucket per policy row).
enum RejectionReason: String {
    case role, secure, nonFinite, degenerate, oversized
    case pressTooLarge, thinGroupMismatch, rowTooLarge
    case tileTooSmall, tileTooLarge, tileTooWide
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
/// Table (first matching row wins; row 9 is the fallthrough). Row 2.5 is the
/// DISPLAY GATE every class must pass: `allowed` is the union of the displays
/// the rect intersects, inflated 1.05× per axis + 2 pt slack; a rect that
/// intersects no display is `.offscreen`, and a rect outside `allowed` fails
/// its class row's fit test. There is no fixed point cap any more.
/// 1. any non-finite component                         -> .nonFinite
/// 2. width < 4, or height < (width >= 300 ? 2 : 4)    -> .degenerate
/// 3. direct roles: area ≤ 150k, h ≤ 600, inside allowed -> .direct / .oversized
/// 4. track roles: minSide ≤ 200 AND (minSide ≤ 60 OR
///    aspect ≥ 8) AND inside allowed                   -> .track / .oversized
/// 5. AXGroup + AXPress, ≤ 420 × 220                   -> .pressGroup / .pressTooLarge
/// 6. AXGroup, width ≥ 300, 2 ≤ height ≤ 6             -> .wideThin
///    (AXGroup thinner than a tile and not wide-thin)   -> .thinGroupMismatch
/// 7. row roles: h < 200 AND area < 120k               -> .row / .rowTooLarge
/// 8. tile roles: sides ≥ 30, area ≤ 120k, aspect ≤ 3  -> .tile / .tileTooSmall
///                                                              / .tileTooLarge
///                                                              / .tileTooWide
/// 9. otherwise                                        -> .role
enum GeometryPolicy {
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
    /// A track is thin in ABSOLUTE terms (a 2289 × 963 "slider" is a container)
    /// and either sliver-thin or ≥ 8:1 (page zoom scales the control, so a
    /// zoomed 3195 × 76 seek bar must stay admitted).
    static let trackMaxMinSide: CGFloat = 200
    static let trackShortMinSide: CGFloat = 60
    static let trackMinAspect: CGFloat = 8
    // Row 5 — press-capable generic AXGroup (flattened web button) envelope.
    static let pressMaxWidth: CGFloat = 420
    static let pressMaxHeight: CGFloat = 220
    // Row 6 — wide-thin group (zoomed web seek bar collapsed to 2 pt tall).
    static let wideThinMinWidth: CGFloat = 300
    static let wideThinMinHeight: CGFloat = 2
    static let wideThinMaxHeight: CGFloat = 6
    // Row 7 — row-like containers.
    static let rowRoles: Set<String> = ["AXCell", "AXRow", "AXListItem"]
    static let rowMaxHeight: CGFloat = 200
    static let rowMaxArea: CGFloat = 120_000
    // Row 8 — tiles / thumbnails.
    static let tileRoles: Set<String> = ["AXImage", "AXGroup"]
    static let tileMinDimension: CGFloat = 30
    static let tileMaxArea: CGFloat = 120_000
    static let tileMaxAspect: CGFloat = 3
    // Row 3 — bulk bounds for a control that is not track-shaped.
    static let maxControlArea: CGFloat = 150_000
    static let maxControlHeight: CGFloat = 600
    // Row 2.5 — DISPLAY GATE. `allowed` = union of the displays this rect
    // intersects, inflated 1.05× on each dimension plus 2 pt of rounding slack.
    // All values are AX/CG points, so there is no Retina/pixel scaling here.
    static let displaySlackScale: CGFloat = 1.05
    static let displaySlackPoints: CGFloat = 2

    /// The display-derived admission envelope for `rect`: union of the displays
    /// it intersects, inflated. nil when it intersects no known display.
    static func allowedBounds(for rect: CGRect, displayBounds: [CGRect]) -> CGRect? {
        let hits = displayBounds.filter { $0.intersects(rect) }
        guard var allowed = hits.first else { return nil }
        for d in hits.dropFirst() { allowed = allowed.union(d) }
        // Centred so a control touching a display edge (or a 1 pt rounding
        // overhang) is not rejected: 1.05× total per axis, 2 pt total slack.
        let dx = (allowed.width * (displaySlackScale - 1) + displaySlackPoints) / 2
        let dy = (allowed.height * (displaySlackScale - 1) + displaySlackPoints) / 2
        return allowed.insetBy(dx: -dx, dy: -dy)
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
    /// `displayBounds` is the per-cycle display list in AX/CG points.
    static func classify(role: String, hasPressAction: Bool, rect: CGRect,
                         displayBounds: [CGRect]) -> GeometryVerdict {
        // 1. Finiteness.
        guard isValidFrame(rect) else { return GeometryVerdict(candidateClass: nil, rejection: .nonFinite) }
        // 2. Frame floor (wide elements still admit a 2 pt sliver — zoomed bars).
        guard rect.width >= 4, rect.height >= (rect.width >= 300 ? 2 : 4) else {
            return GeometryVerdict(candidateClass: nil, rejection: .degenerate)
        }
        // 2.5 Display gate: the rect must land on a real display, and every
        // class below additionally has to fit inside `allowed`.
        guard let allowed = allowedBounds(for: rect, displayBounds: displayBounds) else {
            return GeometryVerdict(candidateClass: nil, rejection: .offscreen)
        }
        let onScreen = allowed.contains(rect)
        let area = rect.width * rect.height
        let minSide = min(rect.width, rect.height)
        let maxSide = max(rect.width, rect.height)
        let aspect = maxSide / max(minSide, 1)

        // 3. Genuine control roles.
        if directRoles.contains(role) {
            let fits = onScreen && area <= maxControlArea && rect.height <= maxControlHeight
            return GeometryVerdict(candidateClass: fits ? .direct : nil,
                                   rejection: fits ? nil : .oversized)
        }
        // 4. Tracks: thin in absolute terms AND sliver-thin or very wide, and
        // wholly inside their displays. No area exemption: a 20000 × 200
        // "slider" is thin but cannot fit a display, so it is oversized.
        // A track-role control that is NOT track-shaped (e.g. a 400x150 volume
        // slider) is still a real control: it falls to the same bulk bound as a
        // direct role instead of being rejected for lacking a track shape —
        // that is the pre-refactor behaviour and must not silently tighten.
        if admittedTrackRoles.contains(role) {
            let thin = minSide <= trackMaxMinSide
                && (minSide <= trackShortMinSide || aspect >= trackMinAspect)
            if thin, onScreen {
                return GeometryVerdict(candidateClass: .track, rejection: nil)
            }
            let fits = onScreen && area <= maxControlArea && rect.height <= maxControlHeight
            return GeometryVerdict(candidateClass: fits ? .track : nil,
                                   rejection: fits ? nil : .oversized)
        }
        // 5. Press-capable generic group = flattened web button.
        if role == "AXGroup", hasPressAction {
            let fits = onScreen && rect.width <= pressMaxWidth && rect.height <= pressMaxHeight
            return GeometryVerdict(candidateClass: fits ? .pressGroup : nil,
                                   rejection: fits ? nil : .pressTooLarge)
        }
        // 6. Wide-thin group = zoomed seek bar collapsed to 2-6 pt.
        if role == "AXGroup" {
            if onScreen, rect.width >= wideThinMinWidth,
               rect.height >= wideThinMinHeight, rect.height <= wideThinMaxHeight {
                return GeometryVerdict(candidateClass: .wideThin, rejection: nil)
            }
            // A group too thin to be a tile and not wide-thin is a divider sliver.
            if minSide < tileMinDimension {
                return GeometryVerdict(candidateClass: nil, rejection: .thinGroupMismatch)
            }
        }
        // 7. Row-like containers.
        if rowRoles.contains(role) {
            let fits = onScreen && rect.height < rowMaxHeight && area < rowMaxArea
            return GeometryVerdict(candidateClass: fits ? .row : nil,
                                   rejection: fits ? nil : .rowTooLarge)
        }
        // 8. Tiles / thumbnails.
        if tileRoles.contains(role) {
            guard minSide >= tileMinDimension else {
                return GeometryVerdict(candidateClass: nil, rejection: .tileTooSmall)
            }
            guard onScreen, area <= tileMaxArea else {
                return GeometryVerdict(candidateClass: nil, rejection: .tileTooLarge)
            }
            guard aspect <= tileMaxAspect else {
                return GeometryVerdict(candidateClass: nil, rejection: .tileTooWide)
            }
            return GeometryVerdict(candidateClass: .tile, rejection: nil)
        }
        // 9. Everything else is page furniture.
        return GeometryVerdict(candidateClass: nil, rejection: .role)
    }

    /// Tier mapping (unchanged from the pre-refactor guard chain).
    static func tier(for cls: CandidateClass) -> DecisionCore.Tier {
        switch cls {
        case .direct, .track, .pressGroup: return .firstClass
        case .wideThin, .row, .tile: return .secondClass
        }
    }
}

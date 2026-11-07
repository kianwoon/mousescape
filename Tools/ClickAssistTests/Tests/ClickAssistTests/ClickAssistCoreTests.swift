// baseline-guard:allow new headless regression suite; no prior baseline possible
import XCTest
import CoreGraphics
@testable import ClickAssistCore

/// Regression suite for the Click Assist decision core. Every test names the
/// real-world failure it guards, because each one of these shipped as a bug.
final class ClickAssistCoreTests: XCTestCase {

    // MARK: - helpers

    private let mainDisplay = CGRect(x: 0, y: 0, width: 7680, height: 2160)
    private var displays: [CGRect] { [mainDisplay] }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private func classify(_ role: String, _ r: CGRect, press: Bool = false,
                          on displays: [CGRect]? = nil,
                          windows: [CGRect] = []) -> GeometryVerdict {
        GeometryPolicy.classify(role: role, hasPressAction: press, rect: r,
                                displayBounds: displays ?? self.displays,
                                windowBounds: windows)
    }

    private func cand(_ key: String, _ r: CGRect, tier: DecisionCore.Tier = .firstClass,
                      role: String = "AXButton") -> DecisionCore.Candidate {
        DecisionCore.Candidate(key: key, rect: r, inset: 2, tier: tier, role: role)
    }

    func testPageFurnitureNeedsAnExplicitPressAction() {
        for role in ["AXGroup", "AXImage", "AXCell", "AXRow", "AXStaticText"] {
            XCTAssertFalse(GeometryPolicy.isActionable(role: role, hasPressAction: false))
            XCTAssertTrue(GeometryPolicy.isActionable(role: role, hasPressAction: true))
        }
        for role in ["AXButton", "AXLink", "AXSlider", "AXTextField", "AXPressGroup"] {
            XCTAssertTrue(GeometryPolicy.isActionable(role: role, hasPressAction: false))
        }
    }

    /// x.com "new posts" pill in Brave: the centre hit-test answered the tweet
    /// text beneath the floating pill → mismatch → ring dropped mid-hover.
    func testFloatingPillReprobeIsAdmittedOnlyForPartialOverlapAnswers() {
        let pill = CGRect(x: 5838, y: 554, width: 180, height: 38)
        let tweetText = CGRect(x: 5711, y: 571, width: 349, height: 131)   // logged centre answer
        let modal = CGRect(x: 5600, y: 400, width: 800, height: 600)       // genuine cover
        let popup = CGRect(x: 5900, y: 565, width: 160, height: 120)       // partial, actionable
        XCTAssertTrue(GeometryPolicy.admitsOcclusionProbe(candidate: pill, centreHit: tweetText,
                                                          centreHitActionable: false))
        XCTAssertFalse(GeometryPolicy.admitsOcclusionProbe(candidate: pill, centreHit: modal,
                                                           centreHitActionable: false))
        // A real control covering the centre would receive the centre-aimed
        // redirect: never re-probe past it.
        XCTAssertFalse(GeometryPolicy.admitsOcclusionProbe(candidate: pill, centreHit: popup,
                                                           centreHitActionable: true))
        // 5f1846d live: Brave answered the pill centre with the whole AXWebArea.
        // Enclosing, but the candidate's own ancestor — cannot be an occluder.
        let webArea = pill.insetBy(dx: -600, dy: -300)   // encloses the pill like the live AXWebArea
        XCTAssertTrue(GeometryPolicy.admitsOcclusionProbe(candidate: pill, centreHit: webArea,
                                                          centreHitActionable: false,
                                                          centreHitIsAncestor: true))
        XCTAssertFalse(GeometryPolicy.admitsOcclusionProbe(candidate: pill, centreHit: webArea,
                                                           centreHitActionable: false,
                                                           centreHitIsAncestor: false))
        // 2026-11-07 live: Brave answered the pill centre with the tweet card's
        // AXGroup (5406,378 476x250) — encloses, not an ancestor — while an
        // interior probe returned the pill element itself. Identity proof wins,
        // even when the card is clickable.
        let card = CGRect(x: 5406, y: 378, width: 476, height: 250)
        let livePill = CGRect(x: 5532, y: 419, width: 180, height: 38)
        for actionable in [false, true] {
            XCTAssertTrue(GeometryPolicy.admitsOcclusionProbe(candidate: livePill, centreHit: card,
                centreHitActionable: actionable, probeHitOwnedByCandidate: true))
            XCTAssertFalse(GeometryPolicy.admitsOcclusionProbe(candidate: livePill, centreHit: card,
                centreHitActionable: actionable, probeHitOwnedByCandidate: false))
        }
        // A genuine cover never answers the covered control's own element.
        XCTAssertFalse(GeometryPolicy.admitsOcclusionProbe(candidate: pill, centreHit: modal,
                                                           centreHitActionable: true))

        let points = GeometryPolicy.occlusionProbePoints(in: pill)
        XCTAssertEqual(points.count, GeometryPolicy.occlusionProbeFractions.count)
        let centre = CGPoint(x: pill.midX, y: pill.midY)
        for p in points {
            XCTAssertTrue(pill.contains(p), "probe \(p) must lie inside the control")
            XCTAssertNotEqual(p, centre, "the centre is the primary probe, never repeated")
        }
        // The left-quarter probe is where the pill's AXButton answered live.
        XCTAssertTrue(points.contains(CGPoint(x: 5883, y: 573)))
    }

    func testBraveTabGroupProxyRequiresTheLiveTabFrame() {
        let tab = rect(4937, 164, 248, 40)
        XCTAssertTrue(GeometryPolicy.isTabHitProxy(ancestorRole: "AXRadioButton",
            hitRole: "AXGroup", ancestorFrame: tab, hitFrame: tab))
        XCTAssertFalse(GeometryPolicy.isTabHitProxy(ancestorRole: "AXGroup",
            hitRole: "AXGroup", ancestorFrame: tab, hitFrame: tab))
        XCTAssertFalse(GeometryPolicy.isTabHitProxy(ancestorRole: "AXRadioButton",
            hitRole: "AXGroup", ancestorFrame: tab, hitFrame: tab.offsetBy(dx: 10, dy: 0)))
    }

    func testBraveMultiTabStripProxyRequiresLiveParentAndExactStripBounds() {
        for width: CGFloat in [248, 740, 986] {
            let strip = rect(521, 53, width, 40)
            func proxy(role: String = "AXTabGroup", hit: String = "AXGroup",
                       frame: CGRect? = nil, parent: Bool = true) -> Bool {
                GeometryPolicy.isTabStripHitProxy(ancestorRole: role, hitRole: hit,
                    ancestorFrame: strip, hitFrame: frame ?? strip, sharesLiveParent: parent)
            }
            XCTAssertTrue(proxy())
            XCTAssertFalse(proxy(parent: false), "An unrelated covering group must not confirm")
            XCTAssertFalse(proxy(role: "AXGroup"))
            XCTAssertFalse(proxy(role: "AXWebArea"))
            XCTAssertFalse(proxy(role: "AXWindow"))
            XCTAssertFalse(proxy(hit: "AXWebArea"))
            XCTAssertFalse(proxy(frame: strip.insetBy(dx: -10, dy: 0)))
            XCTAssertFalse(proxy(frame: strip.offsetBy(dx: 2, dy: 0)))
        }
    }

    func testOpenCodeOverflowingTabLabelRequiresItsActualLiveLink() {
        func confirms(role: String = "AXLink", hit: String = "AXStaticText",
                      enabled: Bool = true, frame: Bool = true,
                      parent: Bool = true, inside: Bool = true) -> Bool {
            GeometryPolicy.confirmsLinkTextHit(candidateRole: role, hitRole: hit,
                enabled: enabled, frameMatches: frame, hitParentIsCandidate: parent,
                destinationInsideCandidate: inside)
        }
        XCTAssertTrue(confirms())
        XCTAssertTrue(confirms(role: "AXButton"), "Disclosure button whose label overflows its bounds")
        XCTAssertFalse(confirms(role: "AXButton", parent: false))
        XCTAssertFalse(confirms(role: "AXButton", inside: false))
        XCTAssertFalse(confirms(parent: false), "Overlaid/unrelated text cannot confirm a link")
        XCTAssertFalse(confirms(enabled: false))
        XCTAssertFalse(confirms(frame: false), "Stale link geometry must not acquire evidence")
        XCTAssertFalse(confirms(inside: false), "Label overflow is not a new click area")
        XCTAssertFalse(confirms(hit: "AXGroup"))
        XCTAssertFalse(confirms(hit: "AXWebArea"))
        XCTAssertFalse(confirms(role: "AXSlider"))
        XCTAssertFalse(confirms(role: "AXSelectableRow"))
        XCTAssertFalse(confirms(role: "AXRadioButton"))
    }

    func testTabCloseCanBeConfirmedByItsActualChromeAncestor() {
        func confirms(role: String = "AXButton", enabled: Bool = true,
                      press: Bool = true, ancestor: Bool = true,
                      chrome: Bool = true, web: Bool = false) -> Bool {
            GeometryPolicy.confirmsChromeDescendant(candidateRole: role, enabled: enabled,
                hasPress: press, hitIsAncestor: ancestor, hasChrome: chrome, hasWebArea: web)
        }
        XCTAssertTrue(confirms())
        for role in ["AXRadioButton", "AXTab"] {
            XCTAssertTrue(confirms(role: role))
            XCTAssertFalse(confirms(role: role, enabled: false))
            XCTAssertFalse(confirms(role: role, press: false))
            XCTAssertFalse(confirms(role: role, ancestor: false))
            XCTAssertFalse(confirms(role: role, chrome: false))
            XCTAssertFalse(confirms(role: role, web: true))
        }
        XCTAssertFalse(confirms(role: "AXGroup"))
        XCTAssertFalse(confirms(enabled: false))
        XCTAssertFalse(confirms(press: false))
        XCTAssertFalse(confirms(ancestor: false))
        XCTAssertFalse(confirms(chrome: false))
        XCTAssertFalse(confirms(web: true))
    }

    func testThinTargetsNeverProduceInfiniteClickDestinations() {
        for size in [CGSize(width: 1601, height: 2), CGSize(width: 2, height: 100),
                     CGSize(width: 3486, height: 7), CGSize(width: 1, height: 1)] {
            let frame = CGRect(origin: CGPoint(x: 100, y: 100), size: size)
            let center = DecisionCore.centerPoint(into: frame)
            XCTAssertEqual(center, CGPoint(x: frame.midX, y: frame.midY))
            XCTAssertTrue(center.x.isFinite && center.y.isFinite)
            XCTAssertTrue(frame.contains(center))
            for point in [CGPoint(x: 500, y: 90), CGPoint(x: 90, y: 500)] {
                let destination = DecisionCore.clampPoint(point, into: frame, inset: 2)
                XCTAssertTrue(destination.x.isFinite && destination.y.isFinite)
                XCTAssertTrue(frame.contains(destination))
            }
        }
    }

    func testNearestTargetWinsAcrossTiersEvenWithSmallDistanceDifference() {
        let row = cand("Fans", rect(100, 100, 100, 26), tier: .secondClass, role: "AXSelectableRow")
        let button = cand("button", rect(100, 147, 100, 26))
        let point = CGPoint(x: 150, y: 136)
        for order in [[row, button], [button, row]] {
            let shown = DecisionCore.displayCandidates(point: point, candidates: order, tolerance: 32)
            XCTAssertEqual(shown.map(\.candidate.key), ["Fans"])
            guard case .redirect(let clicked, _, _, _, _) = DecisionCore.route(
                point: point, candidates: order, tolerance: 32) else { return XCTFail("Missing click") }
            XCTAssertEqual(clicked.key, shown.first?.candidate.key)
        }
    }

    func testDotted32PointOutlineMatchesClickDistanceIncludingCorners() {
        let frame = rect(100, 100, 100, 30)
        let path = DecisionCore.toleranceOutline(rect: frame, tolerance: 32)
        let candidate = cand("target", frame)
        for angle in stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 24) {
            let x: CGFloat = cos(angle) >= 0 ? frame.maxX : frame.minX
            let y: CGFloat = sin(angle) >= 0 ? frame.maxY : frame.minY
            for radius: CGFloat in [31.9, 32.1] {
                let point = CGPoint(x: x + cos(angle) * radius, y: y + sin(angle) * radius)
                let inside = DecisionCore.boundaryDistance(point, frame) <= 32
                XCTAssertEqual(path.contains(point), inside)
                XCTAssertEqual(!DecisionCore.displayCandidates(point: point,
                    candidates: [candidate], tolerance: 32).isEmpty, inside)
                if inside {
                    guard case .redirect(let clicked, _, _, _, _) = DecisionCore.route(
                        point: point, candidates: [candidate], tolerance: 32) else {
                        return XCTFail("Inside outline must route")
                    }
                    XCTAssertEqual(clicked.key, "target")
                } else if case .noCandidate = DecisionCore.route(
                    point: point, candidates: [candidate], tolerance: 32) {} else {
                    XCTFail("Outside outline must not route")
                }
            }
        }
    }

    func testSharedToleranceSupports32AndRejectsInvalidValues() {
        XCTAssertEqual(ClickAssistTolerance.range, 8...32)
        for value: CGFloat in [8, 12, 16, 24, 32] {
            XCTAssertEqual(ClickAssistTolerance.validated(value), value)
        }
        XCTAssertEqual(ClickAssistTolerance.validated(40), 32)
        XCTAssertEqual(ClickAssistTolerance.validated(0), 8)
        for value: CGFloat in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(ClickAssistTolerance.validated(value), 12)
        }
    }

    func testToleranceControlsBothRingAndClickBoundary() {
        let target = cand("button", rect(100, 100, 28, 28))
        for tolerance: CGFloat in [8, 12, 16, 24, 32] {
            let edge = CGPoint(x: 128 + tolerance, y: 114)
            let beyond = CGPoint(x: edge.x + 0.01, y: edge.y)
            guard case .redirect = DecisionCore.route(point: edge, candidates: [target],
                                                      tolerance: tolerance) else {
                return XCTFail("Click at tolerance boundary must be assisted: \(tolerance)")
            }
            guard case .noCandidate = DecisionCore.route(point: beyond, candidates: [target],
                                                         tolerance: tolerance) else {
                return XCTFail("Click outside tolerance must pass through: \(tolerance)")
            }
            XCTAssertEqual(DecisionCore.displayCandidates(point: edge, candidates: [target],
                tolerance: tolerance).count, 1)
            XCTAssertTrue(DecisionCore.displayCandidates(point: beyond, candidates: [target],
                tolerance: tolerance).isEmpty)
        }
    }

    func testVideoPlayerCanConfirmOnlyItsLiveAdjustableSlider() {
        func confirms(role: String = "AXSlider", enabled: Bool = true,
                      adjustable: Bool = true, frameMatches: Bool = true,
                      ancestor: Bool = true) -> Bool {
            GeometryPolicy.confirmsSliderContainer(candidateRole: role, enabled: enabled,
                adjustable: adjustable, frameMatches: frameMatches, hitIsAncestor: ancestor)
        }
        XCTAssertTrue(confirms())
        XCTAssertFalse(confirms(role: "AXGroup"))
        XCTAssertFalse(confirms(enabled: false))
        XCTAssertFalse(confirms(adjustable: false))
        XCTAssertFalse(confirms(frameMatches: false))
        XCTAssertFalse(confirms(ancestor: false))
    }

    func testFullscreenSliderCanExtendBeyondLetterboxedPlayer() {
        let slider = rect(21, 2070, 7638, 6)
        let player = rect(1946, 30, 3787, 2130)
        XCTAssertFalse(player.contains(slider))
        XCTAssertTrue(GeometryPolicy.sliderHitCoversDestination(candidate: slider, hit: player,
            destination: CGPoint(x: 2366, y: 2072)))
        XCTAssertFalse(GeometryPolicy.sliderHitCoversDestination(candidate: slider, hit: player,
            destination: CGPoint(x: 100, y: 2072)))
        XCTAssertFalse(GeometryPolicy.sliderHitCoversDestination(candidate: slider, hit: player,
            destination: CGPoint(x: 2366, y: 1900)))
    }

    /// All supported control families must survive the same admission and
    /// selection gates; tightening page-furniture rules must not remove them.
    func testSupportedControlFamiliesKeepTheirRingsAndClickTargets() {
        let centerRoles = ["AXButton", "AXLink", "AXCheckBox", "AXMenuButton",
            "AXPopUpButton", "AXSegmentedControl",
            "AXDisclosureTriangle"]
        let edgeRoles = ["AXRadioButton", "AXTab", "AXComboBox", "AXTextField",
            "AXSearchField", "AXSlider", "AXMenuItem", "AXMenuBarItem"]
        for role in centerRoles + edgeRoles {
            let frame = rect(100, 100, 100, 30)
            XCTAssertTrue(GeometryPolicy.isActionable(role: role, hasPressAction: false), role)
            XCTAssertTrue(classify(role, frame).accepted, role)
            let target = cand(role, frame, role: role)
            let point = CGPoint(x: 226, y: 115)
            let displayed = DecisionCore.displayCandidates(point: point, candidates: [target],
                                                            tolerance: 32)
            XCTAssertEqual(displayed.first?.candidate.key, role)
            guard case .redirect(let clicked, let destination, _, let snap, _) =
                DecisionCore.route(point: point, candidates: [target], tolerance: 32) else {
                XCTFail("Missing assisted click for \(role)")
                continue
            }
            XCTAssertEqual(clicked.key, displayed.first?.candidate.key)
            XCTAssertTrue(frame.contains(destination), role)
            XCTAssertEqual(snap, edgeRoles.contains(role) ? .edge : .center, role)
        }
    }

    func testDecorativeAndDocumentRolesStaySilentWithoutActions() {
        for role in ["AXGroup", "AXImage", "AXRow", "AXCell", "AXListItem",
                     "AXStaticText", "AXWebArea", "AXScrollArea", "AXWindow"] {
            XCTAssertFalse(GeometryPolicy.isActionable(role: role, hasPressAction: false), role)
        }
    }

    func testFreshTabCloseAndVideoSlidersDoNotWaitForGlobalDiscovery() {
        let close = cand("Close", rect(5152, 170, 28, 28))
        let tab = cand("Tab", rect(4937, 164, 248, 40), role: "AXRadioButton")
        XCTAssertFalse(DecisionCore.needsGlobalDiscovery(point: CGPoint(x: 5166, y: 184),
            freshCandidates: [tab, close], tolerance: 16))
        for frame in [rect(4830, 1664, 2510, 7), rect(21, 2070, 7638, 6)] {
            let slider = cand("Seek", frame, role: "AXSlider")
            XCTAssertFalse(DecisionCore.needsGlobalDiscovery(
                point: CGPoint(x: frame.midX, y: frame.minY - 12),
                freshCandidates: [slider], tolerance: 16))
        }
    }

    func testMissingOutOfRangeOrAmbiguousLocalTargetsStillGetDiscovery() {
        let point = CGPoint(x: 100, y: 100)
        XCTAssertTrue(DecisionCore.needsGlobalDiscovery(point: point,
            freshCandidates: [], tolerance: 16))
        XCTAssertTrue(DecisionCore.needsGlobalDiscovery(point: point,
            freshCandidates: [cand("far", rect(200, 100, 20, 20))], tolerance: 16))
        let left = cand("left", rect(70, 90, 20, 20))
        let right = cand("right", rect(110, 90, 20, 20))
        XCTAssertTrue(DecisionCore.needsGlobalDiscovery(point: point,
            freshCandidates: [left, right], tolerance: 16))
    }

    func testGlobalDiscoveryResumesEvenWhenOnlyAParentWasFoundLocally() {
        let tab = cand("Tab", rect(100, 100, 248, 40), role: "AXRadioButton")
        let point = CGPoint(x: 330, y: 120)
        XCTAssertFalse(DecisionCore.needsGlobalDiscovery(point: point,
            freshCandidates: [tab], tolerance: 16, consecutiveLocalSkips: 3))
        XCTAssertTrue(DecisionCore.needsGlobalDiscovery(point: point,
            freshCandidates: [tab], tolerance: 16, consecutiveLocalSkips: 4))
    }

    func testMovedCachedSliderMustNotStealTheNewVideosEvidenceSlot() {
        let oldFrame = rect(4644, 1721, 2510, 7)
        let newFrame = rect(4869, 1738, 2510, 7)
        let point = CGPoint(x: 5464, y: 1723.4)
        let old = cand("old", oldFrame, role: "AXSlider")
        let current = cand("current", newFrame, role: "AXSlider")
        // The stale rectangle wins at distance zero, although it is no longer
        // the actual control. This reproduces the captured live failure.
        if case .winner(let winner, _) = DecisionCore.resolve(point: point,
            candidates: [old, current], tolerance: 16) {
            XCTAssertEqual(winner.candidate.key, "old")
        } else { XCTFail("Missing stale-winner reproduction") }
        XCTAssertTrue(FrameContinuity.needsGeometryRefresh(cached: oldFrame, live: newFrame))
        let refreshed = DecisionCore.displayCandidates(point: point,
            candidates: [current], tolerance: 16)
        XCTAssertEqual(refreshed.first?.candidate.key, "current")
        XCTAssertEqual(refreshed.first!.dist, 14.6, accuracy: 0.01)
    }

    func testUnchangedControlsStayCachedButGoneGeometryDoesNot() {
        for frame in [rect(5152,170,28,28), rect(4830,1664,2510,7), rect(21,2070,7638,6)] {
            XCTAssertFalse(FrameContinuity.needsGeometryRefresh(cached: frame, live: frame))
            XCTAssertTrue(FrameContinuity.needsGeometryRefresh(cached: frame, live: nil))
            XCTAssertTrue(FrameContinuity.needsGeometryRefresh(cached: frame,
                live: frame.offsetBy(dx: 0, dy: 20)))
        }
    }

    func testVideoSurfaceRequiresActualPlayerIdentityNotSizeSimilarity() {
        XCTAssertTrue(GeometryPolicy.confirmsSharedVideoPlayer(
            isVideoSurface: true, sameLivePlayer: true))
        XCTAssertFalse(GeometryPolicy.confirmsSharedVideoPlayer(
            isVideoSurface: true, sameLivePlayer: false), "Another player must not confirm this slider")
        XCTAssertFalse(GeometryPolicy.confirmsSharedVideoPlayer(
            isVideoSurface: false, sameLivePlayer: true), "A covering group inside the player is not the video surface")
        XCTAssertFalse(GeometryPolicy.confirmsSharedVideoPlayer(
            isVideoSurface: false, sameLivePlayer: false))
    }

    func testLiveHitWindowMustMatchOwnerAndCoverThePointer() {
        let hit = rect(3480, 687, 2115, 1190)
        let playerWindow = rect(3461, 638, 2152, 1338)
        let pointer = CGPoint(x: 4062, y: 1820)
        XCTAssertTrue(GeometryPolicy.hitWindowIsCoherent(expectedPID: 1406, hitPID: 1406,
            hitFrame: hit, windowFrame: playerWindow, pointer: pointer))
        XCTAssertFalse(GeometryPolicy.hitWindowIsCoherent(expectedPID: 1406, hitPID: 123,
            hitFrame: hit, windowFrame: playerWindow, pointer: pointer))
        XCTAssertFalse(GeometryPolicy.hitWindowIsCoherent(expectedPID: 1406, hitPID: 1406,
            hitFrame: rect(0, 0, 100, 30), windowFrame: playerWindow, pointer: pointer))
        XCTAssertFalse(GeometryPolicy.hitWindowIsCoherent(expectedPID: 1406, hitPID: 1406,
            hitFrame: hit, windowFrame: rect(0, 0, 100, 100), pointer: pointer))
    }

    func testNativeSidebarSelectionIsAnActionButWebFurnitureIsNot() {
        XCTAssertTrue(GeometryPolicy.isNativeSelectableRow(role: "AXRow",
            selectionSettable: true, inNativeList: true, inWebContent: false))
        XCTAssertFalse(GeometryPolicy.isNativeSelectableRow(role: "AXRow",
            selectionSettable: false, inNativeList: true, inWebContent: false))
        XCTAssertFalse(GeometryPolicy.isNativeSelectableRow(role: "AXRow",
            selectionSettable: true, inNativeList: true, inWebContent: true))
        XCTAssertFalse(GeometryPolicy.isNativeSelectableRow(role: "AXGroup",
            selectionSettable: true, inNativeList: true, inWebContent: false))
        XCTAssertFalse(GeometryPolicy.isNativeSelectableRow(role: "AXRow",
            selectionSettable: true, inNativeList: false, inWebContent: false))
        let row = cand("Fans", rect(100,100,150,26), tier: .secondClass, role: "AXSelectableRow")
        XCTAssertTrue(GeometryPolicy.isActionable(role: row.role, hasPressAction: false))
        XCTAssertEqual(DecisionCore.snapMode(for: row), .edge)
        XCTAssertEqual(DecisionCore.displayCandidates(point: CGPoint(x: 95, y: 110),
            candidates: [row], tolerance: 16).first?.candidate.key, "Fans")
    }

    // MARK: - A. geometry / zoom

    /// Guarded failure: the fullscreen video seek bar (7638x7) was rejected by a
    /// fixed point cap, so the ring never appeared on a full-screen player.
    func testA1_fullscreenSeekBarIsATrack() {
        let v = classify("AXSlider", rect(20, 1000, 7638, 7))
        XCTAssertEqual(v.candidateClass, .track)
        XCTAssertNil(v.rejection)
    }

    /// Guarded failure: at 388% page zoom the iyf scrub bar is 3195x76 — an
    /// absolute 60 pt thinness cap rejected a perfectly clickable control.
    func testA2_zoomedScrubBarIsATrack() {
        let v = classify("AXSlider", rect(100, 300, 3195, 76))
        XCTAssertEqual(v.candidateClass, .track)
    }

    /// Guarded failure: a mis-exposed 2289x963 player CONTAINER exposed as
    /// AXSlider hijacked clicks meant for the real control. A slider must be
    /// track-shaped (a shape rule, not a size cap).
    func testA3_playerContainerIsNotTrackShaped() {
        let v = classify("AXSlider", rect(100, 200, 2289, 963))
        XCTAssertNil(v.candidateClass)
        XCTAssertEqual(v.rejection, .notTrackShaped)
    }

    /// Guarded failure: the old table exempted "thin" tracks from ALL area
    /// limits, so a 20000x200 pseudo-slider was admitted off-screen.
    func testA4_giantTrackHasNoAreaExemption() {
        let v = classify("AXSlider", rect(0, 1000, 20000, 200))
        XCTAssertNil(v.candidateClass)
        XCTAssertEqual(v.rejection, .oversized)
    }

    /// Guarded failure: action-row wrappers (1258x47, 1599x54) were admitted as
    /// tiles, so the ring highlighted page furniture instead of the button.
    func testA5_actionRowWrappersAreTileTooWide() {
        XCTAssertEqual(classify("AXGroup", rect(0, 100, 1258, 47)).rejection, .tileTooWide)
        XCTAssertEqual(classify("AXGroup", rect(0, 200, 1599, 54)).rejection, .tileTooWide)
    }

    /// Guarded failure: a page container (1466x944) passed as a tile while a real
    /// 204x290 thumbnail was rejected — exactly inverted. The container fills
    /// its window, so it is the page, not a control.
    func testA6_pageContainerVsThumbnail() {
        let window = rect(0, 0, 1470, 956)
        XCTAssertEqual(classify("AXGroup", rect(0, 0, 1466, 944), windows: [window]).rejection, .oversized)
        XCTAssertEqual(classify("AXImage", rect(500, 500, 204, 290), windows: [window]).candidateClass, .tile)
    }

    /// Live 2026-11-02 23:29: clicks inside a 475x51 web press group that
    /// wraps a text input were re-aimed 160 pt to its center, so the caret
    /// always jumped to the same place.
    func testClickInsideWebPressGroupIsNeverReaimed() {
        let box = rect(4960, 1362, 475, 51)
        let point = CGPoint(x: 5037.4, y: 1383.7)
        let group = cand("@4960,1362", box, role: "AXPressGroup")
        guard case .directHit(let hit, _) = DecisionCore.route(point: point, candidates: [group],
                                                              tolerance: 18.5) else {
            return XCTFail("a click inside a web press group must stay where it was aimed")
        }
        XCTAssertEqual(hit.key, group.key)
        XCTAssertEqual(DecisionCore.snapMode(for: group), .edge)
    }

    /// Guarded failure: the 16x16 tab-close glyph was filtered out as
    /// "degenerate", so Chromium chrome buttons could never be assisted.
    func testA7_smallButtonIsDirect() {
        XCTAssertEqual(classify("AXButton", rect(10, 10, 16, 16)).candidateClass, .direct)
    }

    /// Guarded failure: a stale window frame below the display (y=3000) was
    /// admitted and the ring pointed at nothing visible.
    func testA8_rectBelowDisplayIsOffscreen() {
        let v = classify("AXButton", rect(0, 3000, 600, 300))
        XCTAssertNil(v.candidateClass)
        XCTAssertEqual(v.rejection, .offscreen)
    }

    /// Guarded failure: on a two-display desk a control straddling the seam was
    /// rejected because only one display was consulted.
    func testA9_straddlingDisplaysUseTheUnion() {
        let two = [rect(0, 0, 1920, 1080), rect(1920, 0, 1920, 1080)]
        let straddling = classify("AXSlider", rect(1800, 500, 600, 7), on: two)
        XCTAssertEqual(straddling.candidateClass, .track, "straddling the seam must use the union")
        let nowhere = classify("AXSlider", rect(5000, 500, 600, 7), on: two)
        XCTAssertEqual(nowhere.rejection, .offscreen)
    }

    // MARK: - B. crash safety (non-finite geometry)

    /// Guarded failure: AX answered an infinite/NaN frame and `Int(...)` on it
    /// traps — the overlay crashed on the main thread (EXC_BREAKPOINT).
    func testB_nonFiniteGeometryNeverTraps() {
        let fields: [(String, CGRect)] = [
            ("origin.x +inf", CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)),
            ("origin.x -inf", CGRect(x: -CGFloat.infinity, y: 0, width: 100, height: 100)),
            ("origin.x nan", CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)),
            ("origin.y +inf", CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100)),
            ("origin.y -inf", CGRect(x: 0, y: -CGFloat.infinity, width: 100, height: 100)),
            ("origin.y nan", CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100)),
            ("width +inf", CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)),
            ("width -inf", CGRect(x: 0, y: 0, width: -CGFloat.infinity, height: 100)),
            ("width nan", CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)),
            ("height +inf", CGRect(x: 0, y: 0, width: 100, height: CGFloat.infinity)),
            ("height -inf", CGRect(x: 0, y: 0, width: 100, height: -CGFloat.infinity)),
            ("height nan", CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan)),
        ]
        for (name, r) in fields {
            XCTAssertFalse(GeometryPolicy.isValidFrame(r), "isValidFrame must reject \(name)")
            let v = classify("AXSlider", r)
            XCTAssertNil(v.candidateClass, "non-finite \(name) must never be admitted")
            XCTAssertEqual(v.rejection, .nonFinite, "non-finite \(name) must be named nonFinite")
        }
    }

    /// Guarded failure: a zero-height or negative-width AX frame was treated as a
    /// real control and produced a NaN destination.
    /// NOTE: CG normalises a negative size at CGRect init (w=-40 becomes a 40 pt
    /// rect at x=-40), so that input is rejected by the display gate instead of
    /// the floor — still rejected, which is the invariant under test.
    func testB_zeroAndNegativeSizesAreRejected() {
        XCTAssertEqual(classify("AXButton", rect(0, 0, 0, 0)).rejection, .degenerate)
        XCTAssertEqual(classify("AXButton", rect(0, 0, 40, 0)).rejection, .degenerate)
        let negative = classify("AXButton", rect(0, 0, -40, 20))
        XCTAssertNil(negative.candidateClass, "a negative-size frame is never a control")
        XCTAssertNotNil(negative.rejection)
    }

    // MARK: - C. antichain / display set

    /// Guarded failure: the winner was dropped when any cached (not displayed!)
    /// candidate sat inside it, so the ring showed what the click does NOT hit.
    func testC1_winnerContainingAlternateIsStillShown() {
        let outer = cand("tab", rect(100, 100, 300, 300))
        let inner = cand("x", rect(250, 250, 50, 50))
        let shown = DecisionCore.displayCandidates(point: CGPoint(x: 120, y: 120),
                                                   candidates: [outer, inner], tolerance: 400)
        XCTAssertEqual(shown.map(\.candidate.key), ["tab"])
    }

    /// Guarded failure: a wrapper alternate that CONTAINS the winner was shown
    /// around the winner's ring, drawing a ring on page furniture.
    func testC2_alternateContainingWinnerIsDropped() {
        let outer = cand("wrapper", rect(100, 100, 400, 400))
        let winner = cand("radio", rect(200, 200, 60, 60))
        let shown = DecisionCore.displayCandidates(point: CGPoint(x: 230, y: 230),
                                                   candidates: [outer, winner], tolerance: 400)
        XCTAssertEqual(shown.map(\.candidate.key), ["radio"])
    }

    /// Guarded failure: over-eager dedupe dropped a genuinely separate neighbour.
    func testC3_onlyTheClickWinnerIsShown() {
        let a = cand("a", rect(100, 100, 100, 100))
        let b = cand("b", rect(400, 100, 100, 100))
        let shown = DecisionCore.displayCandidates(point: CGPoint(x: 150, y: 150),
                                                   candidates: [a, b], tolerance: 400)
        XCTAssertEqual(shown.map(\.candidate.key), ["a"])
    }

    /// Guarded failure: three nested containers produced three concentric rings
    /// with no way to tell which one the click hits.
    func testC4_threeNestedRingsKeepOnlyTheWinner() {
        let outer = cand("outer", rect(100, 100, 400, 400))
        let mid = cand("mid", rect(150, 150, 200, 200))
        let inner = cand("inner", rect(200, 200, 100, 100))
        let shown = DecisionCore.displayCandidates(point: CGPoint(x: 250, y: 250),
                                                   candidates: [outer, mid, inner], tolerance: 400)
        XCTAssertEqual(shown.map(\.candidate.key), ["inner"])
    }

    // MARK: Overlap ownership (later AX siblings are painted on top)

    /// MyHome (live AX dump): the childless Settings button is followed, in its
    /// parent's children, by the status image/text, the sparkle image and the
    /// input field it spills over (plus a non-overlapping scroll area). It keeps
    /// only its top row, full width.
    func testOwnership_settingsLosesAreaOfLaterSiblings() {
        let button = rect(6053, 990, 175, 93)
        let later = [rect(6229, 58, 1163, 966),   // AXScrollArea, abuts only
                     rect(6066, 1035, 11, 11),    // AXImage 'Selected'
                     rect(6086, 1032, 144, 15),   // AXStaticText status
                     rect(6066, 1057, 11, 14),    // AXImage 'Sparkle'
                     rect(6086, 1053, 1262, 22)]  // AXTextField
        let out = OverlapOwnership.trimmedRects([("settings", button)]) { _ in later }
        XCTAssertEqual(out["settings"]?.rect, rect(6053, 990, 175, 42))
        XCTAssertEqual(out["settings"]?.cutBy.count, 4)
    }

    /// YouTube card: the menu button comes AFTER the title link, so the link
    /// loses the corner and the button (no later sibling) keeps its full frame.
    func testOwnership_laterMenuButtonCutsLinkButKeepsItsFrame() {
        let link = rect(2934, 1338, 540, 40)
        let dots = rect(3447, 1333, 36, 36)
        let above: [String: [CGRect]] = ["link": [dots], "dots": []]
        let out = OverlapOwnership.trimmedRects([("dots", dots), ("link", link)]) { above[$0] }
        XCTAssertNil(out["dots"])
        XCTAssertEqual(out["link"]?.rect, rect(2934, 1338, 513, 40))
        let shown = DecisionCore.displayCandidates(
            point: CGPoint(x: 3464, y: 1350),
            candidates: [cand("link", out["link"]!.rect, role: "AXLink"), cand("dots", dots)],
            tolerance: 13)
        XCTAssertEqual(shown.first?.candidate.key, "dots")
        XCTAssertEqual(shown.first?.candidate.rect, dots)
    }

    /// Wide sidebar: the later full-width field is enclosed by the button.
    func testOwnership_enclosedLaterRowIsCutFromButton() {
        let out = OverlapOwnership.trimmedRects([("settings", rect(4624, 1897, 577, 68))]) { _ in
            [rect(4624, 1937, 577, 28)]
        }
        XCTAssertEqual(out["settings"]?.rect, rect(4624, 1897, 577, 40))
    }

    /// A later sibling that ENCLOSES the candidate is an overlay/wrapper, not
    /// content on part of it: fail closed, untouched (even with other cutters).
    func testOwnership_enclosingLaterSiblingLeavesCandidateUntouched() {
        let button = rect(100, 100, 100, 50)
        let out = OverlapOwnership.trimmedRects([("b", button)]) { _ in
            [rect(150, 130, 50, 20), rect(90, 90, 200, 100)]
        }
        XCTAssertTrue(out.isEmpty)
    }

    /// No later siblings, unknown siblings, or later siblings that do not overlap
    /// (or are degenerate/huge) leave the candidate untouched.
    func testOwnership_noOverlappingLaterSiblingIsUntouched() {
        let button = rect(100, 100, 100, 50)
        XCTAssertTrue(OverlapOwnership.trimmedRects([("b", button)]) { _ in [] }.isEmpty)
        XCTAssertTrue(OverlapOwnership.trimmedRects([("b", button)]) { _ in nil }.isEmpty)
        XCTAssertTrue(OverlapOwnership.trimmedRects([("b", button)]) { _ in
            [rect(300, 100, 50, 50), rect(200, 100, 10, 50), rect(120, 110, 0, 10),
             rect(120, 110, OverlapOwnership.maxSiblingExtent + 1, 10)]
        }.isEmpty)
    }

    /// The per-cycle candidate cap bounds the sibling reads.
    func testOwnership_candidateCapBoundsSiblingReads() {
        var reads = 0
        let items = (0..<(OverlapOwnership.maxCandidatesPerCycle + 3)).map {
            (key: "k\($0)", rect: rect(CGFloat($0) * 100, 0, 50, 50))
        }
        _ = OverlapOwnership.trimmedRects(items) { _ in reads += 1; return [] }
        XCTAssertEqual(reads, OverlapOwnership.maxCandidatesPerCycle)
    }

    /// Guarded failure: the shown winner changed with AX walk order, so the ring
    /// and the click disagreed between two consecutive cycles.
    func testC5_permutationKeepsWinnerAtIndexZero() {
        let outer = cand("outer", rect(100, 100, 400, 400))
        let mid = cand("mid", rect(150, 150, 200, 200))
        let inner = cand("inner", rect(200, 200, 100, 100))
        let point = CGPoint(x: 250, y: 250)
        for perm in [[outer, mid, inner], [inner, outer, mid], [mid, inner, outer]] {
            let shown = DecisionCore.displayCandidates(point: point, candidates: perm,
                                                       tolerance: 400)
            XCTAssertEqual(shown.first?.candidate.key, "inner")
            XCTAssertEqual(shown.count, 1, "nested rings must collapse to the winner")
        }
    }

    // MARK: - D. duplicate surfaces

    /// Guarded failure (Brave): a tab and its AXRadioButton share one frame; the
    /// winner depended on walk order, so tabs/close buttons were ringed at random.
    func testD_identicalFramesAreOrderIndependent() {
        let frame = rect(300, 300, 180, 30)
        let group = cand("tabgroup", frame, tier: .secondClass, role: "AXTabGroup")
        let radio = cand("tab-radio", frame, tier: .firstClass, role: "AXRadioButton")
        let point = CGPoint(x: 350, y: 315)
        let forward = DecisionCore.route(point: point, candidates: [group, radio],
                                         tolerance: 300)
        let reverse = DecisionCore.route(point: point, candidates: [radio, group],
                                         tolerance: 300)
        func winnerKey(_ d: DecisionCore.Decision) -> String? {
            switch d {
            case .directHit(let c, _): return c.key
            case .redirect(let c, _, _, _, _): return c.key
            case .ambiguous(let scored, _): return scored.first?.candidate.key
            case .noCandidate: return nil
            }
        }
        XCTAssertEqual(winnerKey(forward), winnerKey(reverse),
                       "duplicate surfaces must resolve identically regardless of AX order")
        XCTAssertEqual(winnerKey(forward), "tab-radio", "the real control must win the tie")
    }

    // MARK: - E. ambiguity abstains

    /// Guarded failure: two equidistant unrelated controls silently picked one and
    /// the assist clicked the wrong page element.
    func testE_equidistantControlsAbstain() {
        let left = cand("left", rect(100, 100, 100, 100))
        let right = cand("right", rect(300, 100, 100, 100))
        let point = CGPoint(x: 250, y: 150)   // 50 pt from each
        func isAmbiguous(_ order: [DecisionCore.Candidate]) -> Bool {
            if case .ambiguous = DecisionCore.route(point: point, candidates: order,
                                                    tolerance: 200) { return true }
            return false
        }
        XCTAssertTrue(isAmbiguous([left, right]))
        XCTAssertTrue(isAmbiguous([right, left]))
    }

    // MARK: - F. randomised antichain invariant

    /// Guarded failure: an antichain violation slipping past the hand-written
    /// cases — a shown ring nested in another shown ring, or a missing winner.
    func testF_randomSetsStayAntichainAndKeepWinner() {
        var rng = SeededGenerator(seed: 0xC11C_A55E_17)
        for iteration in 0..<50 {
            let count = Int.random(in: 2...6, using: &rng)
            var candidates: [DecisionCore.Candidate] = []
            for i in 0..<count {
                let x = CGFloat(Int.random(in: 0...900, using: &rng))
                let y = CGFloat(Int.random(in: 0...700, using: &rng))
                let w = CGFloat(Int.random(in: 20...300, using: &rng))
                let h = CGFloat(Int.random(in: 20...300, using: &rng))
                candidates.append(cand("c\(i)", rect(x, y, w, h),
                                       tier: i % 2 == 0 ? .firstClass : .secondClass))
            }
            let point = CGPoint(x: CGFloat(Int.random(in: 0...1000, using: &rng)),
                                y: CGFloat(Int.random(in: 0...800, using: &rng)))
            let shown = DecisionCore.displayCandidates(point: point, candidates: candidates,
                                                       tolerance: 400)
            guard case .winner(let winner, _) = DecisionCore.resolve(point: point,
                                                                     candidates: candidates,
                                                                     tolerance: 400) else {
                XCTAssertTrue(shown.isEmpty, "no winner => no rings (iteration \(iteration))")
                continue
            }
            XCTAssertEqual(shown.first?.candidate.key, winner.candidate.key,
                           "iteration \(iteration): the click winner must always be shown")
            let rects = shown.map(\.candidate.rect)
            for i in rects.indices {
                for j in rects.indices where i != j {
                    XCTAssertFalse(DecisionCore.isNested(rects[i], rects[j]),
                                   "iteration \(iteration): shown ring \(i) nests ring \(j)")
                }
            }
        }
    }

    // MARK: - G. target-relative movement rule (frameMoved)

    /// Small control: 16x16 tolerates 3 pt of drift, cancels at 6 pt.
    func testG1_smallControlToleratesThreeNotSix() {
        let base = rect(100, 100, 16, 16)
        XCTAssertFalse(FrameContinuity.moved(base, base.offsetBy(dx: 3, dy: 0)))
        XCTAssertTrue(FrameContinuity.moved(base, base.offsetBy(dx: 6, dy: 0)))
    }

    /// Large control: 400x400 tolerates 10 pt, cancels at 30 pt (never more than 24).
    func testG2_largeControlToleratesTenNotThirty() {
        let base = rect(100, 100, 400, 400)
        XCTAssertFalse(FrameContinuity.moved(base, base.offsetBy(dx: 10, dy: 0)))
        XCTAssertTrue(FrameContinuity.moved(base, base.offsetBy(dx: 30, dy: 0)))
    }

    /// An unchanged frame is the same control.
    func testG3_identicalRectAllowed() {
        let base = rect(50, 60, 120, 40)
        XCTAssertFalse(FrameContinuity.moved(base, base))
    }

    /// Identity continuity: overlap below half the smaller area cancels even when
    /// the two frames share an origin (here the control changed shape, overlap 0.25).
    func testG4_lowOverlapCancelsRegardlessOfDistance() {
        let cached = rect(100, 100, 400, 100)
        let fresh = rect(100, 100, 100, 400)
        XCTAssertLessThan(FrameContinuity.overlapFraction(cached, fresh), 0.5)
        XCTAssertTrue(FrameContinuity.moved(cached, fresh), "lost identity must cancel")
    }

    // MARK: - H. published evidence / async AXPress policy

    /// Fresh evidence: same generation, within the activation window.
    func testH1_evidenceFresh() {
        XCTAssertEqual(ClickAssistEvidence.activationState(evidenceGeneration: 7, currentGeneration: 7,
                                                           ageMs: 10), .fresh)
    }

    /// Evidence past activationMaxAgeMs is stale (the tap must not refresh it synchronously).
    func testH2_evidenceStale() {
        XCTAssertEqual(ClickAssistEvidence.activationState(evidenceGeneration: 7, currentGeneration: 7,
                                                           ageMs: ClickAssistEvidence.activationMaxAgeMs + 1), .stale)
    }

    /// Evidence from another publish cycle is unusable even if the clock is fresh.
    func testH3_evidenceWrongGeneration() {
        XCTAssertEqual(ClickAssistEvidence.activationState(evidenceGeneration: 6, currentGeneration: 7,
                                                           ageMs: 1), .wrongGeneration)
        XCTAssertEqual(ClickAssistEvidence.activationState(evidenceGeneration: 0, currentGeneration: 7,
                                                           ageMs: 1), .missing)
    }

    /// The worker accepts a request inside 150 ms and rejects one past it.
    func testH4_requestExpiry() {
        let request = AXPressRequest(targetKey: "tab-close", pid: 42, generation: 9,
                                     issuedAt: 100, expiryMs: 150)
        XCTAssertNil(AXPressGate.rejection(request: request, currentGeneration: 9,
                                           identityMatches: true, now: 100.149))
        XCTAssertEqual(AXPressGate.rejection(request: request, currentGeneration: 9,
                                             identityMatches: true, now: 100.151), .expired)
    }

    /// A stale generation or swapped element is rejected before activation.
    func testH5_generationAndIdentityRejection() {
        let request = AXPressRequest(targetKey: "tab-close", pid: 42, generation: 9,
                                     issuedAt: 100, expiryMs: 150)
        XCTAssertEqual(AXPressGate.rejection(request: request, currentGeneration: 10,
                                             identityMatches: true, now: 100.010),
                       .staleGeneration)
        XCTAssertEqual(AXPressGate.rejection(request: request, currentGeneration: 9,
                                             identityMatches: false, now: 100.010),
                       .identityMismatch)
    }

    /// Ownership is taken at dispatch: the matching up is consumed even when the
    /// worker later rejects the activation (activation outcome is irrelevant).
    func testH6_ownerConsumesUpRegardlessOfRejection() {
        XCTAssertTrue(GestureOwnership.consumes(tokenActive: true, isDown: false,
                                                isDrag: false, isUp: true))
        XCTAssertTrue(GestureOwnership.consumes(tokenActive: true, isDown: false,
                                                isDrag: true, isUp: false))
        XCTAssertFalse(GestureOwnership.consumes(tokenActive: false, isDown: false,
                                                 isDrag: false, isUp: true))
    }

    // MARK: - I. absolute deadline / bounded queue / dedup

    /// The deadline is fixed at issue and re-checked at execution: a request that
    /// aged while queued is rejected, and receipt never renews it.
    func testI1_deadlineAtExecution() {
        let request = AXPressRequest(targetKey: "tab-close", pid: 42, generation: 9,
                                     issuedAt: 100, expiryMs: 150)
        XCTAssertEqual(request.deadline, 100.15, accuracy: 1e-9)
        XCTAssertFalse(AXPressGate.executionExpired(request, now: 100.10))
        XCTAssertTrue(AXPressGate.executionExpired(request, now: 100.20),
                      "a request that aged in the queue must die at execution")
        XCTAssertTrue(AXPressGate.executionExpired(request, now: 100.15))
    }

    /// Two activations for the same target inside 250 ms collapse to one.
    func testI2_duplicateWithinWindow() {
        let dup = AXPressAdmission.evaluate(targetKey: "tab-close", now: 100.10,
                                            lastTarget: "tab-close", lastIssuedAt: 100.00,
                                            pending: 0)
        XCTAssertEqual(dup?.rejection, .duplicate)
        XCTAssertEqual(dup?.dtMs ?? 0, 100, accuracy: 0.001)
        XCTAssertNil(AXPressAdmission.evaluate(targetKey: "tab-close", now: 100.25,
                                               lastTarget: "tab-close", lastIssuedAt: 100.00,
                                               pending: 0), "outside the 250 ms window")
        XCTAssertNil(AXPressAdmission.evaluate(targetKey: "other", now: 100.10,
                                               lastTarget: "tab-close", lastIssuedAt: 100.00,
                                               pending: 0), "different target is not a duplicate")
    }

    /// At the bound the new activation is rejected and never enqueued.
    func testI3_queueFull() {
        XCTAssertEqual(AXPressAdmission.evaluate(targetKey: "t", now: 10,
                                                 lastTarget: nil, lastIssuedAt: nil,
                                                 pending: AXPressAdmission.maxPendingPresses)?.rejection,
                       .queueFull)
        XCTAssertNil(AXPressAdmission.evaluate(targetKey: "t", now: 10,
                                               lastTarget: nil, lastIssuedAt: nil,
                                               pending: AXPressAdmission.maxPendingPresses - 1))
    }

    /// Evidence outlives a press request by design (400 ms vs 150 ms).
    func testI4_expiryRelationship() {
        XCTAssertGreaterThan(ClickAssistEvidence.activationMaxAgeMs, AXPressGate.defaultExpiryMs)
        XCTAssertEqual(ClickAssistEvidence.displayMaxAgeMs, ClickAssistEvidence.activationMaxAgeMs)
        XCTAssertEqual(AXPressGate.defaultExpiryMs, 150)
        XCTAssertEqual(AXPressAdmission.maxPendingPresses, 4)
        XCTAssertEqual(AXPressAdmission.dedupeWindowMs, 250)
    }

    // MARK: - Window-fill rule (no fixed size caps)

    func testLargeClickableBelowWindowFillIsAdmitted() {
        let window = rect(0, 0, 1440, 900)
        // 74 % of the window: a big control, still a control.
        XCTAssertEqual(classify("AXButton", rect(100, 50, 1200, 800), windows: [window]).candidateClass, .direct)
        // Former fixed caps: 600x300 row (area cap 120k), 500x300 press group (420x220 cap),
        // 1000x700 image (area cap 120k).
        XCTAssertEqual(classify("AXRow", rect(0, 0, 600, 300), windows: [window]).candidateClass, .row)
        XCTAssertEqual(classify("AXGroup", rect(0, 0, 500, 300), press: true, windows: [window]).candidateClass, .pressGroup)
        XCTAssertEqual(classify("AXImage", rect(0, 0, 1000, 700), windows: [window]).candidateClass, .tile)
    }

    func testWindowFillingElementIsOversized() {
        let window = rect(0, 0, 1440, 900)
        let v = classify("AXGroup", rect(20, 10, 1400, 880), press: true, windows: [window])
        XCTAssertNil(v.candidateClass)
        XCTAssertEqual(v.rejection, .oversized)
    }

    func testNoContainingWindowFallsBackToDisplay() {
        // mainDisplay is 7680x2160; 7600x2100 covers 96 % of it.
        XCTAssertEqual(classify("AXButton", rect(40, 30, 7600, 2100)).rejection, .oversized)
        XCTAssertEqual(classify("AXButton", rect(40, 30, 3000, 1500)).candidateClass, .direct)
    }

    func testReferenceFrameIsSmallestWindowContainingCentre() {
        let big = rect(0, 0, 2000, 1200)
        let small = rect(100, 100, 400, 300)
        XCTAssertEqual(GeometryPolicy.referenceFrame(for: rect(150, 150, 50, 20), windows: [big, small]), small)
        XCTAssertEqual(GeometryPolicy.referenceFrame(for: rect(1500, 900, 50, 20), windows: [big, small]), big)
        XCTAssertNil(GeometryPolicy.referenceFrame(for: rect(5000, 900, 50, 20), windows: [big, small]))
    }

    /// Live 2026-11-02: a Brave page group (1564x1277) in its own 1564x1358
    /// window was measured against a smaller stacked Brave window that only
    /// contained its centre (78 %), so the whole page ringed.
    func testReferenceFramePrefersWindowHoldingWholeRect() {
        let own = rect(5287, 642, 1564, 1358)
        let stacked = rect(5707, 528, 1188, 1579)
        let page = rect(5287, 723, 1564, 1277)
        XCTAssertEqual(GeometryPolicy.referenceFrame(for: page, windows: [own, stacked]), own)
        XCTAssertEqual(classify("AXGroup", page, press: true, windows: [own, stacked]).rejection, .oversized)
    }

    /// Live 2026-11-02: the YouTube video box ringed although its progress
    /// bar (a sibling in the AX tree) lies on it.
    func testVisualContainerHoldsAnotherTarget() {
        let video = rect(1131, 269, 2027, 1140)
        let seek = rect(1155, 1360, 1979, 10)
        XCTAssertTrue(GeometryPolicy.isVisualContainer(video, among: [video, seek]))
        XCTAssertFalse(GeometryPolicy.isVisualContainer(video, among: [video]))
        XCTAssertFalse(GeometryPolicy.isVisualContainer(video, among: [rect(1131.5, 269, 2027, 1140)]))
        XCTAssertFalse(GeometryPolicy.isVisualContainer(seek, among: [video, seek]))
    }

    func testShapeRulesSurvive() {
        // Chunky non-track slider: accepted trade-off of the shape rule.
        XCTAssertEqual(classify("AXSlider", rect(0, 0, 400, 150)).rejection, .notTrackShaped)
        // Long no-press wrapper strips still never ring (user decision 2026-11-02).
        XCTAssertEqual(classify("AXGroup", rect(0, 100, 1258, 47)).rejection, .tileTooWide)
    }
}

/// Deterministic RNG so a failure is reproducible from the seed alone.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Distance-0 tie (guards the evidence-slot regression)

/// A tab close button (16x16) and a page link (900x28) can both contain the
/// pointer, i.e. both sit at boundary distance 0. The router must pick the
/// smaller control, and the single position-specific evidence slot must follow
/// the same comparator — when it did not, the close button rendered as
/// `legitimacy-unknown` and lost its ring entirely.
final class ClickAssistTieBreakTests: XCTestCase {
    private func cand(_ key: String, _ r: CGRect) -> DecisionCore.Candidate {
        DecisionCore.Candidate(key: key, rect: r, inset: 2, tier: .firstClass, role: "AXButton")
    }

    func testSmallerControlWinsAtEqualDistance() {
        let link = cand("link@0,0", CGRect(x: 0, y: 0, width: 900, height: 28))
        let close = cand("close@14,6", CGRect(x: 14, y: 6, width: 16, height: 16))
        let point = CGPoint(x: 20, y: 12)
        let decision = DecisionCore.route(point: point, candidates: [link, close], tolerance: 12)
        guard case .directHit(let hit, _) = decision else {
            return XCTFail("expected a direct hit, got \(decision)")
        }
        XCTAssertEqual(hit.rect, close.rect, "the smaller control must win an equal-distance tie")
    }
}

// MARK: - Candidate identity collision (guards the tab-✕ regression)

/// Every browser tab ✕ is labelled "Close". Label-only keys collapsed them into
/// one candidate, so the hovered ✕ was replaced by a sibling in another window and
/// the ring vanished. Identity must be per-element.
final class ClickAssistIdentityTests: XCTestCase {
    private func cand(_ key: String, _ r: CGRect) -> DecisionCore.Candidate {
        DecisionCore.Candidate(key: key, rect: r, inset: 2, tier: .firstClass, role: "AXButton")
    }

    func testSameLabelDifferentFramesBothSurviveAndPointerWins() {
        let near = cand("Close@100,100", CGRect(x: 100, y: 100, width: 16, height: 16))
        let far = cand("Close@400,400", CGRect(x: 400, y: 400, width: 16, height: 16))
        let decision = DecisionCore.route(point: CGPoint(x: 108, y: 108),
                                         candidates: [far, near], tolerance: 12)
        guard case .directHit(let hit, _) = decision else {
            return XCTFail("expected a direct hit on the near close button")
        }
        XCTAssertEqual(hit.key, "Close@100,100")
    }
}

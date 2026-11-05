import XCTest
import CoreGraphics
@testable import ClickAssistCore

/// x.com (Brave) video "Seek slider": the AXSlider frame is the 30 × 30 knob,
/// not the bar. It is promoted to its enclosing track; bar-shaped sliders are
/// never touched.
final class ClickAssistThumbSliderTests: XCTestCase {
    let thumb = CGRect(x: 5571, y: 1292, width: 30, height: 30)
    let track = CGRect(x: 5300, y: 1292, width: 600, height: 30)

    func testThumbLike() {
        XCTAssertTrue(GeometryPolicy.isThumbLike(thumb))
        XCTAssertFalse(GeometryPolicy.isThumbLike(CGRect(x: 0, y: 0, width: 2098, height: 6)))
        XCTAssertFalse(GeometryPolicy.isThumbLike(CGRect(x: 0, y: 0, width: 40, height: 10)))
    }

    func testThumbPromotedToWideAncestor() {
        let wrapper = thumb   // a same-size knob wrapper is skipped, not chosen
        XCTAssertEqual(GeometryPolicy.promotedTrackRect(thumb: thumb, ancestors: [wrapper, track]), track)
    }

    func testFullBarUnchanged() {
        let bar = CGRect(x: 100, y: 900, width: 2098, height: 6)
        XCTAssertNil(GeometryPolicy.promotedTrackRect(thumb: bar,
            ancestors: [CGRect(x: 90, y: 880, width: 2200, height: 40)]))
        XCTAssertNil(GeometryPolicy.promotedTrackRect(thumb: bar, rowSiblings: [bar]))
    }

    func testTallAncestorRejected() {
        let player = CGRect(x: 5300, y: 1000, width: 600, height: 400)
        XCTAssertNil(GeometryPolicy.promotedTrackRect(thumb: thumb, ancestors: [player]))
    }

    func testAncestorNotContainingThumbRejected() {
        let elsewhere = CGRect(x: 5300, y: 1400, width: 600, height: 30)
        XCTAssertNil(GeometryPolicy.promotedTrackRect(thumb: thumb, ancestors: [elsewhere]))
    }

    func testRowSiblingsJoined() {
        let played = CGRect(x: 5300, y: 1305, width: 271, height: 4)
        let rest = CGRect(x: 5601, y: 1305, width: 299, height: 4)
        let other = CGRect(x: 5300, y: 1340, width: 40, height: 40)   // play button row below
        XCTAssertEqual(GeometryPolicy.promotedTrackRect(thumb: thumb, rowSiblings: [played, rest, other]),
                       CGRect(x: 5300, y: 1292, width: 600, height: 30))
        XCTAssertNil(GeometryPolicy.promotedTrackRect(thumb: thumb, rowSiblings: [other]))
    }

    func testThumbWithinPromotedTrack() {
        XCTAssertTrue(GeometryPolicy.thumbWithinPromotedTrack(thumb: thumb, track: track))
        let moved = thumb.offsetBy(dx: 200, dy: 0)
        XCTAssertTrue(GeometryPolicy.thumbWithinPromotedTrack(thumb: moved, track: track))
        XCTAssertFalse(GeometryPolicy.thumbWithinPromotedTrack(thumb: thumb.offsetBy(dx: 0, dy: 100), track: track))
        XCTAssertFalse(GeometryPolicy.thumbWithinPromotedTrack(thumb: track, track: track))
        XCTAssertFalse(GeometryPolicy.thumbWithinPromotedTrack(thumb: thumb,
            track: CGRect(x: 5300, y: 1000, width: 600, height: 400)))
    }

    /// Flicker guard: cached track + live thumb inside must NOT trigger the
    /// resolver's geometry refresh (which would drop the confirmed verdict).
    func testCachedTrackLiveThumbSkipsRefresh() {
        XCTAssertTrue(FrameContinuity.needsGeometryRefresh(cached: track, live: thumb))
        XCTAssertTrue(GeometryPolicy.thumbWithinPromotedTrack(thumb: thumb, track: track))
    }

    func testPromotedTrackClassifiesAsTrack() {
        let display = [CGRect(x: 0, y: 0, width: 7000, height: 2000)]
        let v = GeometryPolicy.classify(role: "AXSlider", hasPressAction: false, rect: track,
                                        displayBounds: display, windowBounds: display)
        XCTAssertEqual(v.candidateClass, .track)
    }

    // MARK: - Live x.com (Brave) frames, probed 2026-11-05

    let xKnob = CGRect(x: 5702, y: 873, width: 30, height: 30)
    let xAncestors = [CGRect(x: 5502, y: 886, width: 461, height: 3),
                      CGRect(x: 5502, y: 878, width: 461, height: 20),
                      CGRect(x: 5502, y: 878, width: 461, height: 20),
                      CGRect(x: 5498, y: 878, width: 468, height: 20),
                      CGRect(x: 5498, y: 878, width: 468, height: 58),
                      CGRect(x: 5498, y: 878, width: 468, height: 58)]
    let xSiblings = [CGRect(x: 5502, y: 887, width: 461, height: 2),
                     CGRect(x: 5502, y: 886, width: 215, height: 3)]
    let xTrack = CGRect(x: 5502, y: 873, width: 461, height: 30)

    /// The knob is TALLER than every ancestor: containment never held, so the
    /// ancestor path was dead. Riding on the 3 pt bar promotes it.
    func testXcomKnobPromotedViaAncestors() {
        XCTAssertEqual(GeometryPolicy.promotedTrackRect(thumb: xKnob, ancestors: xAncestors), xTrack)
    }

    func testXcomKnobPromotedViaSiblings() {
        XCTAssertEqual(GeometryPolicy.promotedTrackRect(thumb: xKnob, rowSiblings: xSiblings), xTrack)
    }

    /// Knob parked at 0 % sits 6 pt left of the bar (logged at x=5496): the
    /// track (and so the target key) keeps the bar's origin, and the live knob
    /// still confirms identity against it.
    func testXcomKnobAtBarStartKeepsTrackOrigin() {
        let parked = CGRect(x: 5496, y: 873, width: 30, height: 30)
        XCTAssertEqual(GeometryPolicy.promotedTrackRect(thumb: parked, ancestors: xAncestors), xTrack)
        XCTAssertEqual(GeometryPolicy.promotedTrackRect(thumb: parked, rowSiblings: xSiblings), xTrack)
        XCTAssertTrue(GeometryPolicy.thumbWithinPromotedTrack(thumb: parked, track: xTrack))
        let end = CGRect(x: 5948, y: 873, width: 30, height: 30)
        XCTAssertTrue(GeometryPolicy.thumbWithinPromotedTrack(thumb: end, track: xTrack))
        XCTAssertFalse(GeometryPolicy.thumbWithinPromotedTrack(thumb: end.offsetBy(dx: 40, dy: 0), track: xTrack))
    }

    func testKnobOffTheBarNotPromoted() {
        let below = xKnob.offsetBy(dx: 0, dy: 60)
        XCTAssertNil(GeometryPolicy.promotedTrackRect(thumb: below, ancestors: xAncestors))
        XCTAssertNil(GeometryPolicy.promotedTrackRect(thumb: below, rowSiblings: xSiblings))
    }

    func testPromotionDecisionReusesRememberedTrack() {
        let fresh = GeometryPolicy.thumbPromotionDecision(thumb: xKnob, fresh: xTrack, remembered: nil)
        XCTAssertEqual(fresh.rect, xTrack); XCTAssertEqual(fresh.source, .promoted)
        // Transient AX miss: the last track is published, not the knob.
        let moved = xKnob.offsetBy(dx: -150, dy: 0)
        let miss = GeometryPolicy.thumbPromotionDecision(thumb: moved, fresh: nil, remembered: xTrack)
        XCTAssertEqual(miss.rect, xTrack); XCTAssertEqual(miss.source, .remembered)
        // Layout moved away from the remembered track: fall back to the knob.
        let elsewhere = xKnob.offsetBy(dx: 0, dy: 400)
        let stale = GeometryPolicy.thumbPromotionDecision(thumb: elsewhere, fresh: nil, remembered: xTrack)
        XCTAssertEqual(stale.rect, elsewhere); XCTAssertEqual(stale.source, .thumb)
    }
}

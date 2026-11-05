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
}

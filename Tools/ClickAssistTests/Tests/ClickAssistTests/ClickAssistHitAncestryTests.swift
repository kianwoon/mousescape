import XCTest
import CoreGraphics
@testable import ClickAssistCore

/// x.com (Brave) feed player: frames captured live from the AX tree. The hit
/// element is the seek-bar group while controls are shown, and the page's
/// AXWebArea while they are hidden; only the former is worth climbing from.
final class ClickAssistHitAncestryTests: XCTestCase {
    let window = CGRect(x: 5137, y: 540, width: 1198, height: 1463)
    let fraction: CGFloat = 0.5

    func testControlGroupHitIsLocal() {
        let seekGroup = CGRect(x: 5475, y: 1302, width: 461, height: 20)
        XCTAssertTrue(HitAncestryRescue.isLocal(hitFrame: seekGroup, windowFrame: window,
                                                maxWindowFraction: fraction))
    }

    func testWebAreaHitIsNotLocal() {
        let webArea = CGRect(x: 5137, y: 621, width: 1198, height: 1382)
        XCTAssertFalse(HitAncestryRescue.isLocal(hitFrame: webArea, windowFrame: window,
                                                 maxWindowFraction: fraction))
    }

    func testFractionBoundaryIsExclusive() {
        let half = CGRect(x: 0, y: 0, width: 100, height: 50)
        let whole = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertFalse(HitAncestryRescue.isLocal(hitFrame: half, windowFrame: whole, maxWindowFraction: fraction))
        XCTAssertTrue(HitAncestryRescue.isLocal(hitFrame: CGRect(x: 0, y: 0, width: 100, height: 49),
                                                windowFrame: whole, maxWindowFraction: fraction))
    }

    func testDegenerateFramesAreNotLocal() {
        XCTAssertFalse(HitAncestryRescue.isLocal(hitFrame: .zero, windowFrame: window, maxWindowFraction: fraction))
        XCTAssertFalse(HitAncestryRescue.isLocal(hitFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                 windowFrame: .zero, maxWindowFraction: fraction))
    }
}

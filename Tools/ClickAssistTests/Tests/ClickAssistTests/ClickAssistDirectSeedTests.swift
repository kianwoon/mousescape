import XCTest
import CoreGraphics
@testable import ClickAssistCore

final class ClickAssistDirectSeedTests: XCTestCase {
    let point = CGPoint(x: 120, y: 120)
    func target(_ role: String, verdict: ClickAssistVerdict = .confirmed,
                tier: DecisionCore.Tier = .firstClass) -> DecisionCore.Candidate {
        .init(key: role, rect: CGRect(x: 100, y: 100, width: 80, height: 40),
              inset: 2, tier: tier, role: role, verdict: verdict)
    }
    func testStrongDirectControlsCanDeferRedundantWalkButNotForever() {
        for role in ["AXButton", "AXRadioButton", "AXLink", "AXSlider", "AXMenuItem"] {
            XCTAssertTrue(DecisionCore.canDeferPointerWalk(point: point,
                freshCandidates: [target(role)], tolerance: 32, consecutiveLocalSkips: 0))
            XCTAssertFalse(DecisionCore.canDeferPointerWalk(point: point,
                freshCandidates: [target(role)], tolerance: 32, consecutiveLocalSkips: 4))
        }
    }
    func testNativeListContextsRetainTheirExistingDiscoveryPath() {
        for role in ["AXSelectableRow", "AXNativeRowButton"] {
            XCTAssertFalse(DecisionCore.canDeferPointerWalk(point: point,
                freshCandidates: [target(role)], tolerance: 32, consecutiveLocalSkips: 0))
            XCTAssertFalse(DecisionCore.canDeferPointerWalk(point: point,
                freshCandidates: [target("AXButton"), target(role)], tolerance: 32,
                consecutiveLocalSkips: 0))
        }
    }
    func testUncertainOrNearbySeedsKeepFullDiscovery() {
        for verdict: ClickAssistVerdict in [.unknown, .mismatch, .confirmedWeak] {
            XCTAssertFalse(DecisionCore.canDeferPointerWalk(point: point,
                freshCandidates: [target("AXButton", verdict: verdict)], tolerance: 32,
                consecutiveLocalSkips: 0))
        }
        XCTAssertFalse(DecisionCore.canDeferPointerWalk(point: CGPoint(x: 90, y: 120),
            freshCandidates: [target("AXButton")], tolerance: 32, consecutiveLocalSkips: 0))
        XCTAssertFalse(DecisionCore.canDeferPointerWalk(point: point,
            freshCandidates: [target("AXGroup", tier: .secondClass)], tolerance: 32,
            consecutiveLocalSkips: 0))
        XCTAssertFalse(DecisionCore.canDeferPointerWalk(point: point,
            freshCandidates: [], tolerance: 32, consecutiveLocalSkips: 0))
    }
}

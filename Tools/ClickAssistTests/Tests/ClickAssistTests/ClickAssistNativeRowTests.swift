import XCTest
import CoreGraphics
@testable import ClickAssistCore

final class ClickAssistNativeRowTests: XCTestCase {
    func candidate(_ role: String, verdict: ClickAssistVerdict = .confirmed) -> DecisionCore.Candidate {
        DecisionCore.Candidate(key: "sidebar", rect: CGRect(x: 100, y: 100, width: 175, height: 26),
            inset: 2, tier: role == "AXSelectableRow" ? .secondClass : .firstClass,
            role: role, label: "Room", verdict: verdict, evidenceGeneration: 7, collectedAt: 10)
    }
    func testVerifiedNativeRowActionsOwnForegroundClicksButBrowserControlsStayNative() {
        for role in ["AXSelectableRow", "AXNativeRowButton"] {
            XCTAssertTrue(GeometryPolicy.usesNativeRowAction(role))
            XCTAssertTrue(GeometryPolicy.isActionable(role: role, hasPressAction: false))
            XCTAssertTrue(BackgroundClickPolicy.eligible(targetPID: 42, foregroundPID: 42,
                candidate: candidate(role), generation: 7, point: CGPoint(x: 180, y: 112), now: 10.1))
            XCTAssertFalse(BackgroundClickPolicy.eligible(targetPID: 42, foregroundPID: 42,
                candidate: candidate(role, verdict: .unknown), generation: 7,
                point: CGPoint(x: 180, y: 112), now: 10.1))
            XCTAssertFalse(BackgroundClickPolicy.eligible(targetPID: 42, foregroundPID: 42,
                candidate: candidate(role), generation: 7, point: CGPoint(x: 99, y: 112), now: 10.1))
        }
        for role in ["AXButton", "AXLink", "AXSlider", "AXRadioButton", "AXGroup"] {
            XCTAssertFalse(GeometryPolicy.usesNativeRowAction(role))
            XCTAssertFalse(BackgroundClickPolicy.eligible(targetPID: 42, foregroundPID: 42,
                candidate: candidate(role), generation: 7, point: CGPoint(x: 180, y: 112), now: 10.1))
        }
    }
    func testNativeRowButtonKeepsTheSameRingAndNearestTarget() {
        let point = CGPoint(x: 180, y: 112)
        for role in ["AXButton", "AXNativeRowButton"] {
            let row = DecisionCore.Candidate(key: "row", rect: CGRect(x: 90, y: 96, width: 195, height: 34),
                inset: 2, tier: .secondClass, role: "AXSelectableRow")
            guard case .winner(let target, _) = DecisionCore.resolve(point: point,
                candidates: [row, candidate(role)], tolerance: 32) else { return XCTFail("Missing winner") }
            XCTAssertEqual(target.candidate.key, "sidebar")
            XCTAssertEqual(target.candidate.rect, candidate("AXButton").rect)
            XCTAssertEqual(target.snap, .center)
        }
    }
    func testNativeToleranceDeliveryCoversTheIndicatedRegionWithoutExtendingBrowserClicks() {
        let point = CGPoint(x: 280, y: 112)
        for role in ["AXSelectableRow", "AXNativeRowButton"] {
            XCTAssertTrue(BackgroundClickPolicy.eligible(targetPID: 42, foregroundPID: 42,
                candidate: candidate(role), generation: 7, point: point, now: 10.1, nativeTolerance: 32))
            XCTAssertFalse(BackgroundClickPolicy.eligible(targetPID: 42, foregroundPID: 42,
                candidate: candidate(role), generation: 7, point: CGPoint(x: 308, y: 112),
                now: 10.1, nativeTolerance: 32))
        }
        XCTAssertFalse(BackgroundClickPolicy.eligible(targetPID: 42, foregroundPID: 1,
            candidate: candidate("AXButton"), generation: 7, point: point, now: 10.1, nativeTolerance: 32))
    }
    func testNativeRowClickIgnoresOnlyExistingPointerNoiseAndPreservesRealDrags() {
        XCTAssertTrue(BackgroundClickPolicy.isClickPointerNoise(role: "AXSelectableRow",
            down: .zero, current: CGPoint(x: 0.2, y: 0.3)))
        XCTAssertFalse(BackgroundClickPolicy.isClickPointerNoise(role: "AXNativeRowButton",
            down: .zero, current: CGPoint(x: 3, y: 0)))
        XCTAssertFalse(BackgroundClickPolicy.isClickPointerNoise(role: "AXSlider",
            down: .zero, current: CGPoint(x: 0.2, y: 0.3)))
    }
    func testBackgroundButtonClickIgnoresSubPointTremor() {
        // Live log 2026-11-02: a 0.1 pt leftMouseDragged between down and up
        // released the captured background click, so the app only activated.
        XCTAssertTrue(BackgroundClickPolicy.isClickPointerNoise(role: "AXButton",
            down: CGPoint(x: 6339.2, y: 530.7), current: CGPoint(x: 6339.3, y: 530.6)))
        XCTAssertTrue(BackgroundClickPolicy.isClickPointerNoise(role: "AXLink",
            down: .zero, current: CGPoint(x: 1, y: 1)))
        XCTAssertFalse(BackgroundClickPolicy.isClickPointerNoise(role: "AXButton",
            down: .zero, current: CGPoint(x: 3, y: 0)))
        XCTAssertFalse(BackgroundClickPolicy.isClickPointerNoise(role: "AXScrollBar",
            down: .zero, current: CGPoint(x: 0.5, y: 0)))
    }
}

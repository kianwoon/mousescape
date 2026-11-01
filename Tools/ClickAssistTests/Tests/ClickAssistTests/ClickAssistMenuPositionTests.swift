import XCTest
import CoreGraphics
@testable import ClickAssistCore

final class ClickAssistMenuPositionTests: XCTestCase {
    let strip = CGRect(x: 4884, y: 989, width: 254, height: 38)
    func menu(_ key: String = "reactions") -> DecisionCore.Candidate {
        DecisionCore.Candidate(key: key, rect: strip, inset: 2, tier: .firstClass,
                               role: "AXMenuItem", label: "Reactions")
    }
    func testFifthReactionInsideCompositeMenuKeepsItsExactClickPosition() {
        let pointer = CGPoint(x: 5072.4, y: 1005.7)
        guard case .directHit(let target, _) = DecisionCore.route(point: pointer,
            candidates: [menu()], tolerance: 27) else {
            return XCTFail("An inside menu click must remain native, not re-aim at another emoji")
        }
        XCTAssertEqual(target.key, "reactions")
        XCTAssertEqual(DecisionCore.snapMode(for: target), .edge)
    }
    func testToleranceNearReactionStripPreservesTheHoveredColumn() {
        let pointer = CGPoint(x: 5072.4, y: 984)
        guard case .redirect(_, let corrected, _, let snap, _) = DecisionCore.route(point: pointer,
            candidates: [menu()], tolerance: 27) else { return XCTFail("Expected nearby menu") }
        XCTAssertEqual(snap, .edge)
        XCTAssertEqual(corrected.x, pointer.x)
        XCTAssertEqual(corrected.y, strip.minY + 2)
    }
    func testNativeMenuClicksAreNotRecenteredAtEitherEnd() {
        for point in [CGPoint(x: strip.minX + 1, y: strip.midY),
                      CGPoint(x: strip.maxX - 1, y: strip.midY)] {
            guard case .directHit = DecisionCore.route(point: point,
                candidates: [menu("ordinary-menu")], tolerance: 32) else {
                return XCTFail("Native menu click moved")
            }
        }
        let button = DecisionCore.Candidate(key: "button", rect: strip, inset: 2,
                                            tier: .firstClass, role: "AXButton")
        XCTAssertEqual(DecisionCore.snapMode(for: button), .center)
        XCTAssertEqual(DecisionCore.snapMode(for: DecisionCore.Candidate(key: "tab", rect: strip,
            inset: 2, tier: .firstClass, role: "AXLink")), .center)
    }

    func testOpenMenuNeverEntersBackgroundWindowActivation() {
        let target = DecisionCore.Candidate(key: "menu-command", rect: strip, inset: 2,
            tier: .firstClass, role: "AXMenuItem", verdict: .confirmed,
            evidenceGeneration: 7, collectedAt: 10)
        for foreground: Int32? in [1, 2, nil] {
            XCTAssertFalse(BackgroundClickPolicy.eligible(targetPID: 1, foregroundPID: foreground,
                candidate: target, generation: 7, point: CGPoint(x: strip.midX, y: strip.midY), now: 10.1))
        }
        guard case .directHit = DecisionCore.route(point: CGPoint(x: strip.midX, y: strip.midY),
            candidates: [target], tolerance: 32) else {
            return XCTFail("The menu must retain its native click")
        }
    }
}

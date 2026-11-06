import XCTest
@testable import ClickAssistCore

/// x.com "new posts" pill, 2026-11-06: the ring blinked off for one generation
/// every ~17 because a truncated resolver walk left the pill's verdict "unknown".
final class ClickAssistUnknownHoldTests: XCTestCase {
    let pill = CGRect(x: 5467, y: 620, width: 180, height: 38)
    let key = "New posts are available.@5467,620"
    let inside = CGPoint(x: 5560, y: 640)

    func testUnknownGapOnSameTargetIsBridged() {
        var hold = RingUnknownHold()
        hold.confirmed(key: key, rect: pill, now: 10)
        XCTAssertTrue(hold.holds(unknownKey: key, pointer: inside, tolerance: 0, now: 10.05))
    }

    func testHoldExpiresAndConfirmationRestartsIt() {
        var hold = RingUnknownHold()
        hold.confirmed(key: key, rect: pill, now: 10)
        let late = 10 + RingUnknownHold.holdInterval + 0.01
        XCTAssertFalse(hold.holds(unknownKey: key, pointer: inside, tolerance: 0, now: late))
        XCTAssertNil(hold.key)
        // A run of unknowns cannot extend the window: only a confirmation does.
        hold.confirmed(key: key, rect: pill, now: 20)
        XCTAssertTrue(hold.holds(unknownKey: key, pointer: inside, tolerance: 0, now: 20.1))
        XCTAssertFalse(hold.holds(unknownKey: key, pointer: inside, tolerance: 0,
                                  now: 20 + RingUnknownHold.holdInterval + 0.01))
    }

    func testDifferentTargetOrPointerOutsideDropsHold() {
        var hold = RingUnknownHold()
        hold.confirmed(key: key, rect: pill, now: 10)
        XCTAssertFalse(hold.holds(unknownKey: "Image@5403,557", pointer: inside, tolerance: 0, now: 10.05))
        hold.confirmed(key: key, rect: pill, now: 10)
        XCTAssertFalse(hold.holds(unknownKey: key, pointer: CGPoint(x: 5560, y: 700),
                                  tolerance: 0, now: 10.05))
    }
}

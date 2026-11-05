import XCTest
@testable import ClickAssistCore

final class ClickAssistPointerOwnerTests: XCTestCase {
    let agent: Int32 = 500
    let service: Int32 = 600
    let overlayWindow = 41
    let menuBarWindow = 42

    func owner(_ pid: Int32?, _ window: Int?, excluded: Set<Int>? = nil) -> Int32? {
        PointerOwnerPolicy.owner(hitPid: pid, hitWindowID: window, selfPid: service,
                                 excludedWindowIDs: excluded ?? [overlayWindow])
    }

    func testExcludedOverlayWindowIsSkipped() {
        XCTAssertNil(owner(agent, overlayWindow))
    }

    func testOtherWindowOfSameProcessIsNotExcluded() {
        // The agent's own menu-bar item must resolve to the agent pid.
        XCTAssertEqual(owner(agent, menuBarWindow), agent)
        XCTAssertEqual(owner(agent, nil), agent)
    }

    func testSelfProcessAlwaysExcluded() {
        XCTAssertNil(owner(service, menuBarWindow, excluded: []))
        XCTAssertNil(owner(service, nil, excluded: []))
    }

    func testUnusableHitFallsBack() {
        XCTAssertNil(owner(nil, nil))
        XCTAssertNil(owner(0, menuBarWindow))
    }

    func testWindowIDsAreNotPidScoped() {
        // An unrelated app whose window id is not excluded resolves normally.
        XCTAssertEqual(owner(777, 99), 777)
        XCTAssertEqual(owner(777, 99, excluded: []), 777)
    }
}

// baseline-guard:allow new headless latency tests, no prior baseline possible
import XCTest
@testable import ClickAssistCore

/// Passive-latency ring instrumentation: percentiles, wrap-around, reset, and
/// cumulative tap-disable counters.
final class ClickAssistLatencyTests: XCTestCase {

    func testNearestRankPercentiles() {
        let ring = LatencyRing(capacity: 1000)
        for i in 1...1000 { ring.record(Double(i)) }
        let s = ring.snapshotAndReset()
        XCTAssertEqual(s.count, 1000)
        XCTAssertEqual(s.p50Us, 500)
        XCTAssertEqual(s.p99Us, 990)
        XCTAssertEqual(s.p99_9Us, 999)
        XCTAssertEqual(s.maxUs, 1000)
        XCTAssertEqual(s.dropped, 0)
    }

    func testRingWrapKeepsCapacityAndOverwritesOldest() {
        let ring = LatencyRing(capacity: 8)
        for i in 1...20 { ring.record(Double(i)) }
        let s = ring.snapshotAndReset()
        XCTAssertEqual(ring.capacity, 8)
        XCTAssertEqual(s.count, 8)
        XCTAssertEqual(s.maxUs, 20)
        XCTAssertEqual(s.p50Us, 16)
        XCTAssertEqual(s.p99Us, 20)
    }

    func testSnapshotAndResetEmptiesTimings() {
        let ring = LatencyRing(capacity: 16)
        for i in 1...5 { ring.record(Double(i)) }
        XCTAssertEqual(ring.snapshotAndReset().count, 5)
        let second = ring.snapshotAndReset()
        XCTAssertEqual(second.count, 0)
        XCTAssertEqual(second.maxUs, 0)
        XCTAssertEqual(second.p50Us, 0)
    }

    func testTapDisableCountersSurviveTimingReset() {
        let ring = LatencyRing(capacity: 16)
        ring.noteTapDisable(timeout: true)
        ring.noteTapDisable(timeout: true)
        ring.noteTapDisable(timeout: false)
        ring.record(123)
        let first = ring.snapshotAndReset()
        XCTAssertEqual(first.tapDisableTimeout, 2)
        XCTAssertEqual(first.tapDisableUserInput, 1)
        let second = ring.snapshotAndReset()
        XCTAssertEqual(second.count, 0)
        XCTAssertEqual(second.tapDisableTimeout, 2)
        XCTAssertEqual(second.tapDisableUserInput, 1)
    }
}

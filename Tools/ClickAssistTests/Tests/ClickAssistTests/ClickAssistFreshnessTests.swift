// baseline-guard:allow new headless freshness-split tests, no prior baseline possible
import XCTest
import CoreGraphics
@testable import ClickAssistCore

/// Display vs activation freshness split, collection-time evidence stamps, and
/// partial-cycle non-renewal.
final class ClickAssistFreshnessTests: XCTestCase {

    func testWindowsAreDistinctAndActivationIsStricter() {
        XCTAssertEqual(ClickAssistEvidence.displayMaxAgeMs, 700)
        XCTAssertEqual(ClickAssistEvidence.activationMaxAgeMs, 400)
        XCTAssertLessThan(ClickAssistEvidence.activationMaxAgeMs,
                          ClickAssistEvidence.displayMaxAgeMs)
    }

    /// 500 ms old: still showable by the ring, never actionable by the tap.
    func testFiveHundredMsIsDisplayFreshButActivationStale() {
        let cases: [(ageMs: Double, display: ClickAssistEvidence.State,
                     activation: ClickAssistEvidence.State)] = [
            (399, .fresh, .fresh),
            (401, .fresh, .stale),
            (500, .fresh, .stale),
            (699, .fresh, .stale),
            (701, .stale, .stale),
        ]
        for c in cases {
            XCTAssertEqual(ClickAssistEvidence.displayState(
                evidenceGeneration: 7, currentGeneration: 7, ageMs: c.ageMs),
                c.display, "display at \(c.ageMs) ms")
            XCTAssertEqual(ClickAssistEvidence.activationState(
                evidenceGeneration: 7, currentGeneration: 7, ageMs: c.ageMs),
                c.activation, "activation at \(c.ageMs) ms")
        }
    }

    /// A partial cycle that did not validate a target keeps its old collection
    /// timestamp; only a completed validation renews it.
    func testPartialCycleDoesNotRenewCollectedAt() {
        let existing: CFTimeInterval = 100
        XCTAssertEqual(ClickAssistEvidence.renewedCollectedAt(existing: existing, validatedAt: nil),
                       existing)
        XCTAssertEqual(ClickAssistEvidence.renewedCollectedAt(existing: existing, validatedAt: 250),
                       250)
    }

    /// Encode/send latency must not refresh evidence: per-target collectedAt
    /// survives the wire while publishedAt advances.
    func testWireCarriesCollectionTimeSeparateFromPublishTime() {
        let target = CachedTarget(key: "k", role: "AXButton", label: "k",
                                  rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                  inset: 1, tier: .firstClass, verdict: .confirmed,
                                  chromeEligible: true, evidenceGeneration: 3,
                                  collectedAt: 100)
        let snap = CacheSnapshot(generation: 3, targets: [target], valid: true,
                                 reason: "fresh", stamp: 200, resolverMs: 0,
                                 pointer: .zero, appName: "a", pid: 1)
        let wire = SnapshotWire(snapshot: snap, epoch: "E")
        XCTAssertEqual(wire.publishedAt, 200)
        XCTAssertEqual(wire.targets.first?.collectedAt, 100)
        XCTAssertEqual(wire.cacheSnapshot().targets.first?.collectedAt, 100)
    }

    /// SNAP_GAP uses the same nearest-rank ring: p95 of 1...1000 is 950 ms.
    func testSnapGapPercentiles() {
        let ring = LatencyRing(capacity: 1000)
        for i in 1...1000 { ring.record(Double(i) * 1000) }   // microseconds
        let s = ring.snapshotAndReset()
        XCTAssertEqual(s.count, 1000)
        XCTAssertEqual(s.p50Us / 1000, 500)
        XCTAssertEqual(s.p95Us / 1000, 950)
        XCTAssertEqual(s.maxUs / 1000, 1000)
    }
}

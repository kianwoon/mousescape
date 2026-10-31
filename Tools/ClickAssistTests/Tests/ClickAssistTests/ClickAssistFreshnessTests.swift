// baseline-guard:allow new headless freshness-split tests, no prior baseline possible
import XCTest
import CoreGraphics
@testable import ClickAssistCore

/// Display vs activation freshness split, collection-time evidence stamps, and
/// partial-cycle non-renewal.
final class ClickAssistFreshnessTests: XCTestCase {

    func testDisplayAndActivationUseTheSameWindow() {
        // A visible ring must not outlive the confirmation needed for a click.
        XCTAssertEqual(ClickAssistEvidence.displayMaxAgeMs, 400)
        XCTAssertEqual(ClickAssistEvidence.activationMaxAgeMs, 400)
        XCTAssertEqual(ClickAssistEvidence.activationMaxAgeMs,
                          ClickAssistEvidence.displayMaxAgeMs)
        // AX work is bounded even when nearer mismatches must be rejected.
        XCTAssertEqual(ClickAssistEvidence.maxEvidenceCandidatesPerCycle, 3)
    }

    /// Evidence expires together for indication and activation.
    func testExpiredClickEvidenceAlsoClearsTheRing() {
        let cases: [(ageMs: Double, display: ClickAssistEvidence.State,
                     activation: ClickAssistEvidence.State)] = [
            (399, .fresh, .fresh),
            (401, .stale, .stale),
            (500, .stale, .stale),
            (699, .stale, .stale),
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

    /// Pure formatter: exact wire shape, no I/O. Overshoot is derived from the
    /// pointer-window deadline and is reported independently of the rotation walk.
    func testTraceFormatters() {
        XCTAssertEqual(
            ClickAssistTraceFormatter.resolverCycle(
                gen: 42, walkMs: 160.04, deadlineMs: 100,
                evidenceN: 1, evidenceMs: 12.5),
            "RESOLVER_CYCLE gen=42 walk_ms=160.0 deadline_ms=100 overshoot=1 evidence_n=1 evidence_ms=12.5")
        XCTAssertEqual(
            ClickAssistTraceFormatter.resolverCycle(
                gen: 43, walkMs: 90, deadlineMs: 100,
                evidenceN: 1, evidenceMs: 0),
            "RESOLVER_CYCLE gen=43 walk_ms=90.0 deadline_ms=100 overshoot=0 evidence_n=1 evidence_ms=0.0")
        let sample = ClickAssistTraceSample(
            cycle: 7, ptrGen: 3, walkMs: 95.2, evidenceMs: 4.4,
            encodeMs: 0.8, sendMs: 1.2, recvAgeMs: 2.0, totalMs: 512.5,
            targets: 12, evidenceN: 1, trunc: "deadline")
        XCTAssertEqual(
            ClickAssistTraceFormatter.cbTrace(sample),
            "CB_TRACE cycle=7 ptrGen=3 walk_ms=95.2 evidence_ms=4.4 encode_ms=0.8 send_ms=1.2 recv_age_ms=2.0 total_ms=512.5 targets=12 evidence_n=1 trunc=deadline")
    }
}

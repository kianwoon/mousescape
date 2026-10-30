// baseline-guard:allow new headless migration tests, no prior baseline possible
import XCTest
import CoreGraphics
@testable import ClickAssistCore

/// Pure tests for the AX-out-of-agent migration: snapshot wire validation,
/// the reconnect circuit breaker, and service-side activation admission.
final class ClickAssistMigrationTests: XCTestCase {

    // MARK: - helpers

    private func target(_ key: String, chrome: Bool = true,
                        verdict: ClickAssistVerdict = .confirmed,
                        generation: UInt64 = 7) -> SnapshotWireTarget {
        SnapshotWireTarget(CachedTarget(key: key, role: "AXButton", label: key,
                                        rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                                        inset: 2, tier: .firstClass, verdict: verdict,
                                        chromeEligible: chrome,
                                        evidenceGeneration: generation))
    }

    private func wire(generation: UInt64 = 7, publishedAt: Double,
                      epoch: String = "E1",
                      targets: [SnapshotWireTarget]? = nil) -> SnapshotWire {
        SnapshotWire(epoch: epoch, generation: generation, publishedAt: publishedAt,
                     pid: 42, targets: targets ?? [target("k1")])
    }

    // MARK: - (a) snapshot decode / reject rules

    func testSnapshotAcceptsFreshPayload() {
        let now = 1000.0
        let data = ClickAssistSnapshotCodec.encode(wire(publishedAt: now - 0.1))!
        guard case .success(let decoded) = ClickAssistSnapshotCodec.decode(
            data, expectedEpoch: "E1", currentGeneration: 6, now: now) else {
            return XCTFail("fresh payload must decode")
        }
        XCTAssertEqual(decoded.wire.generation, 7)
        XCTAssertEqual(decoded.ageMs, 100, accuracy: 1)
        XCTAssertEqual(decoded.wire.cacheSnapshot().targets.first?.key, "k1")
    }

    func testSnapshotRejectsStaleEpoch() {
        let data = ClickAssistSnapshotCodec.encode(wire(publishedAt: 1000, epoch: "E2"))!
        XCTAssertEqual(ClickAssistSnapshotCodec.decode(data, expectedEpoch: "E1",
                                                       currentGeneration: nil, now: 1000),
                       .failure(.staleEpoch))
    }

    func testSnapshotRejectsOldOrEqualGeneration() {
        let data = ClickAssistSnapshotCodec.encode(wire(generation: 7, publishedAt: 1000))!
        XCTAssertEqual(ClickAssistSnapshotCodec.decode(data, expectedEpoch: "E1",
                                                       currentGeneration: 7, now: 1000),
                       .failure(.oldGeneration))
    }

    func testSnapshotRejectsExpiredEvidence() {
        let data = ClickAssistSnapshotCodec.encode(wire(publishedAt: 1000))!
        // 401 ms > shared 400 ms max.
        XCTAssertEqual(ClickAssistSnapshotCodec.decode(data, expectedEpoch: "E1",
                                                       currentGeneration: nil, now: 1000.401),
                       .failure(.expired))
    }

    func testSnapshotRejectsOversizeInsteadOfTruncating() {
        let big = Data(count: ClickAssistSnapshotCodec.maxPayloadBytes + 1)
        XCTAssertEqual(ClickAssistSnapshotCodec.decode(big, expectedEpoch: nil,
                                                       currentGeneration: nil, now: 1),
                       .failure(.oversize))
        // Encode refuses rather than emitting a truncated payload.
        let huge = SnapshotWire(epoch: "E1", generation: 1, publishedAt: 1,
                                targets: (0..<4000).map { target("key-\($0)-\(String(repeating: "x", count: 100))") })
        XCTAssertGreaterThan((try! JSONEncoder().encode(huge)).count,
                             ClickAssistSnapshotCodec.maxPayloadBytes)
        XCTAssertNil(ClickAssistSnapshotCodec.encode(huge))
    }

    // MARK: - (b) circuit breaker

    func testCircuitRetriesOnOneTwoFourThenOpens() {
        var breaker = ClickAssistCircuitBreaker()
        XCTAssertEqual(breaker.recordFailure(now: 0), .retry(after: 1))
        XCTAssertEqual(breaker.recordFailure(now: 1), .retry(after: 2))
        XCTAssertEqual(breaker.recordFailure(now: 2), .open)
        XCTAssertEqual(breaker.state, .open)
    }

    func testCircuitIgnoresFailuresOutsideWindow() {
        var breaker = ClickAssistCircuitBreaker()
        XCTAssertEqual(breaker.recordFailure(now: 0), .retry(after: 1))
        XCTAssertEqual(breaker.recordFailure(now: 61), .retry(after: 1),
                       "the first failure is outside the 60 s window")
    }

    func testCircuitResetsAfterSixtySecondsHealthy() {
        var breaker = ClickAssistCircuitBreaker()
        _ = breaker.recordFailure(now: 0)
        _ = breaker.recordFailure(now: 1)
        XCTAssertEqual(breaker.failures.count, 2)
        breaker.recordSuccess(now: 10)
        breaker.recordSuccess(now: 69)   // 59 s healthy: not yet
        XCTAssertEqual(breaker.failures.count, 2)
        breaker.recordSuccess(now: 70.1) // 60.1 s healthy: reset
        XCTAssertTrue(breaker.failures.isEmpty)
        XCTAssertEqual(breaker.state, .closed)
    }

    // MARK: - (c) activation validation

    private func request(_ id: String, key: String = "k1", generation: UInt64 = 7,
                         issuedAt: Double = 0, deadlineMs: Double = 150) -> ActivationRequestWire {
        ActivationRequestWire(requestID: id, targetKey: key, pid: 42,
                              generation: generation, issuedAt: issuedAt,
                              deadlineMs: deadlineMs)
    }

    func testActivationRejectsStaleGenerationAndDeadline() {
        var state = ActivationGate.State()
        XCTAssertEqual(ActivationGate.admit(request("r1", generation: 6), now: 0.05,
                                            currentGeneration: 7, targetExists: true,
                                            chromeEligible: true, state: &state),
                       .staleGeneration)
        XCTAssertEqual(ActivationGate.admit(request("r2", issuedAt: 0, deadlineMs: 100),
                                            now: 0.2, currentGeneration: 7,
                                            targetExists: true, chromeEligible: true,
                                            state: &state), .expired)
    }

    func testActivationRejectsMissingOrNonChromeTarget() {
        var state = ActivationGate.State()
        XCTAssertEqual(ActivationGate.admit(request("r1"), now: 0.05,
                                            currentGeneration: 7, targetExists: false,
                                            chromeEligible: true, state: &state),
                       .unknownTarget)
        XCTAssertEqual(ActivationGate.admit(request("r2"), now: 0.05,
                                            currentGeneration: 7, targetExists: true,
                                            chromeEligible: false, state: &state),
                       .notChromeEligible)
    }

    func testActivationDedupesRequestAndTargetWithin250ms() {
        var state = ActivationGate.State()
        XCTAssertNil(ActivationGate.admit(request("r1", key: "a", issuedAt: 1.0), now: 1.0,
                                          currentGeneration: 7, targetExists: true,
                                          chromeEligible: true, state: &state))
        XCTAssertEqual(ActivationGate.admit(request("r1", key: "a", issuedAt: 1.1), now: 1.1,
                                            currentGeneration: 7, targetExists: true,
                                            chromeEligible: true, state: &state),
                       .duplicateRequest)
        // Same target, new request, inside the 250 ms window.
        XCTAssertEqual(ActivationGate.admit(request("r2", key: "a", issuedAt: 1.2), now: 1.2,
                                            currentGeneration: 7, targetExists: true,
                                            chromeEligible: true, state: &state),
                       .duplicateTarget)
        // After the window the same target is allowed again.
        XCTAssertNil(ActivationGate.admit(request("r3", key: "a", issuedAt: 1.3), now: 1.3,
                                          currentGeneration: 7, targetExists: true,
                                          chromeEligible: true, state: &state))
    }

    func testActivationQueueCapIsFour() {
        var state = ActivationGate.State()
        for i in 0..<ActivationGate.maxQueued {
            XCTAssertNil(ActivationGate.admit(request("r\(i)", key: "k\(i)"), now: Double(i) * 0.001,
                                              currentGeneration: 7, targetExists: true,
                                              chromeEligible: true, state: &state),
                         "request \(i) should fit")
        }
        XCTAssertEqual(state.pending, ActivationGate.maxQueued)
        XCTAssertEqual(ActivationGate.admit(request("overflow", key: "kX"), now: 0.01,
                                            currentGeneration: 7, targetExists: true,
                                            chromeEligible: true, state: &state),
                       .queueFull)
        ActivationGate.finish(&state)
        XCTAssertNil(ActivationGate.admit(request("after", key: "kY"), now: 0.02,
                                          currentGeneration: 7, targetExists: true,
                                          chromeEligible: true, state: &state))
    }
}

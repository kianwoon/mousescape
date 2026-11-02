import XCTest
import CoreGraphics
@testable import ClickAssistCore

final class ClickAssistBackgroundClickTests: XCTestCase {
    let frame = CGRect(x: 100, y: 100, width: 240, height: 30)
    func candidate(verdict: ClickAssistVerdict = .confirmed, stamp: Double = 10,
                   generation: UInt64 = 7) -> DecisionCore.Candidate {
        DecisionCore.Candidate(key: "tab", rect: frame, inset: 2, tier: .firstClass,
            role: "AXLink", label: "Tab", verdict: verdict,
            evidenceGeneration: generation, collectedAt: stamp)
    }
    func testOnlyFreshStrongGreenBackgroundHitCanTakeOwnership() {
        func eligible(_ c: DecisionCore.Candidate, foreground: Int32? = 2,
                      point: CGPoint = CGPoint(x: 200, y: 110)) -> Bool {
            BackgroundClickPolicy.eligible(targetPID: 1, foregroundPID: foreground,
                candidate: c, generation: 7, point: point, now: 10.1)
        }
        XCTAssertTrue(eligible(candidate()))
        XCTAssertFalse(eligible(candidate(), foreground: 1))
        XCTAssertFalse(eligible(candidate(), foreground: nil))
        XCTAssertFalse(eligible(candidate(), point: CGPoint(x: 99, y: 110)))
        for verdict: ClickAssistVerdict in [.unknown, .mismatch, .confirmedWeak] {
            XCTAssertFalse(eligible(candidate(verdict: verdict)))
        }
        XCTAssertFalse(eligible(candidate(stamp: 9)))
        XCTAssertFalse(eligible(candidate(generation: 6)))
    }
    func testFocusChangeCannotMoveTheClickToAnotherFrame() {
        let click = BackgroundClickWire(x: 200, y: 110, rect: frame)
        XCTAssertTrue(BackgroundClickPolicy.matches(click, rect: frame))
        XCTAssertFalse(BackgroundClickPolicy.matches(click, rect: frame.offsetBy(dx: 2, dy: 0)))
        XCTAssertFalse(BackgroundClickPolicy.matches(
            BackgroundClickWire(x: .infinity, y: 110, rect: frame), rect: frame))
        XCTAssertFalse(BackgroundClickPolicy.matches(
            BackgroundClickWire(x: 99, y: 110, rect: frame), rect: frame))
    }
    func testBackgroundRequestsKeepTheSameDeduplicationOwner() {
        var state = ActivationGate.State()
        var request = ActivationRequestWire(requestID: "one-physical-click", targetKey: "tab", pid: 1,
            generation: 7, issuedAt: 10, deadlineMs: 400)
        request.backgroundClick = BackgroundClickWire(x: 200, y: 110, rect: frame)
        XCTAssertNil(ActivationGate.admit(request, now: 10.01, currentGeneration: 7,
            targetExists: true, chromeEligible: false, backgroundEligible: true, state: &state))
        XCTAssertEqual(ActivationGate.admit(request, now: 10.02, currentGeneration: 7,
            targetExists: true, chromeEligible: false, backgroundEligible: true, state: &state), .duplicateRequest)
        ActivationGate.finish(&state)
        request.requestID = "new-id-same-click"
        XCTAssertEqual(ActivationGate.admit(request, now: 10.03, currentGeneration: 7,
            targetExists: true, chromeEligible: false, backgroundEligible: true, state: &state), .duplicateTarget)
    }
    func testExistingChromeRequestWireStillDecodes() throws {
        let data = Data(#"{"requestID":"old","targetKey":"close","pid":1,"generation":7,"issuedAt":10,"deadlineMs":150}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ActivationRequestWire.self, from: data).backgroundClick)
    }
    func testResolverRefreshOnlyAcceptsIndependentlyRevalidatedBackgroundTarget() {
        let request = ActivationRequestWire(requestID: "same-live-target", targetKey: "tab", pid: 1,
            generation: 7, issuedAt: 10, deadlineMs: 400)
        var state = ActivationGate.State()
        XCTAssertEqual(ActivationGate.admit(request, now: 10.01, currentGeneration: 8,
            targetExists: true, chromeEligible: true, state: &state), .staleGeneration)
        XCTAssertNil(ActivationGate.admit(request, now: 10.01, currentGeneration: 8,
            targetExists: true, chromeEligible: false, backgroundEligible: true, state: &state))
        state = .init()
        XCTAssertEqual(ActivationGate.admit(request, now: 10.01, currentGeneration: 6,
            targetExists: true, chromeEligible: false, backgroundEligible: true, state: &state), .staleGeneration)
    }
    func testFrontmostAppUnfocusedWindowTakesOwnershipLikeBackgroundApp() {
        func eligible(foreground: Int32, focused: Bool) -> Bool {
            BackgroundClickPolicy.eligible(targetPID: 1, foregroundPID: foreground,
                candidate: candidate(), generation: 7, point: CGPoint(x: 200, y: 110), now: 10.1,
                targetWindowFocused: focused)
        }
        XCTAssertTrue(eligible(foreground: 1, focused: false))
        XCTAssertFalse(eligible(foreground: 1, focused: true))
        XCTAssertTrue(eligible(foreground: 2, focused: true))
        XCTAssertTrue(eligible(foreground: 2, focused: false))
    }
    func testOnlyLiveStandardHitWindowCanReportUnfocused() {
        XCTAssertFalse(GeometryPolicy.pointerWindowFocused(mode: "hit-window",
            isStandardWindow: true, focusedMatches: false))
        XCTAssertTrue(GeometryPolicy.pointerWindowFocused(mode: "hit-window",
            isStandardWindow: true, focusedMatches: true))
        XCTAssertTrue(GeometryPolicy.pointerWindowFocused(mode: "hit-window",
            isStandardWindow: true, focusedMatches: nil))
        XCTAssertTrue(GeometryPolicy.pointerWindowFocused(mode: "hit-window",
            isStandardWindow: false, focusedMatches: false))
        for mode in ["ax-contain", "confirmed-seed", "none"] {
            XCTAssertTrue(GeometryPolicy.pointerWindowFocused(mode: mode,
                isStandardWindow: true, focusedMatches: false))
        }
    }
    func testSnapshotWireCarriesPointerWindowFocus() throws {
        var snap = CacheSnapshot(generation: 3, targets: [], valid: true, reason: "fresh",
                                 stamp: 10, resolverMs: 0, pointer: .zero, appName: "A", pid: 1)
        snap.pointerWindowFocused = false
        let data = try XCTUnwrap(ClickAssistSnapshotCodec.encode(SnapshotWire(snapshot: snap, epoch: "E")))
        let decoded = try ClickAssistSnapshotCodec.decode(data, expectedEpoch: "E",
            currentGeneration: nil, now: 10.01).get()
        XCTAssertFalse(decoded.wire.cacheSnapshot().pointerWindowFocused)
        let old = Data(#"{"version":1,"epoch":"E","generation":3,"publishedAt":10,"ageMs":400,"pid":1,"valid":true,"reason":"fresh","targets":[]}"#.utf8)
        let legacy = try ClickAssistSnapshotCodec.decode(old, expectedEpoch: "E",
            currentGeneration: nil, now: 10.01).get()
        XCTAssertNil(legacy.wire.pointerWindowFocused)
        XCTAssertTrue(legacy.wire.cacheSnapshot().pointerWindowFocused)
    }
}

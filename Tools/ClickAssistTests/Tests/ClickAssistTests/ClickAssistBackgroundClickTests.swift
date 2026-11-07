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
    func testPostPointCarriesRawEventSpaceAndOlderSendersFallBack() throws {
        // Ring/AX point (200,110); the physical click arrived +62,-18 away in raw event space.
        let click = BackgroundClickWire(x: 200, y: 110, rect: frame, postX: 262, postY: 92)
        XCTAssertEqual(click.point, CGPoint(x: 200, y: 110))
        XCTAssertEqual(click.postPoint, CGPoint(x: 262, y: 92))
        // Geometry still judges the AX point, never the post point.
        XCTAssertTrue(BackgroundClickPolicy.matches(click, rect: frame))
        let old = try JSONDecoder().decode(BackgroundClickWire.self,
            from: Data(#"{"x":200,"y":110,"rect":[[100,100],[240,30]]}"#.utf8))
        XCTAssertEqual(old.postPoint, CGPoint(x: 200, y: 110))
        XCTAssertEqual(BackgroundClickWire(x: 200, y: 110, rect: frame, postX: .nan, postY: 92).postPoint,
                       CGPoint(x: 200, y: 110))
        let roundTrip = try JSONDecoder().decode(BackgroundClickWire.self,
            from: JSONEncoder().encode(click))
        XCTAssertEqual(roundTrip, click)
    }
    func testFrontmostRedirectCapturesButSliderKeepsInPlaceGesture() {
        let fresh = { (role: String, rect: CGRect) in
            DecisionCore.Candidate(key: role, rect: rect, inset: 2, tier: .firstClass,
                role: role, label: role, verdict: .confirmed, evidenceGeneration: 7, collectedAt: 10)
        }
        let link = fresh("AXLink", frame)
        let slider = fresh("AXSlider", CGRect(x: 100, y: 100, width: 600, height: 6))
        func eligible(_ c: DecisionCore.Candidate, _ p: CGPoint, redirected: Bool) -> Bool {
            BackgroundClickPolicy.eligible(targetPID: 1, foregroundPID: 1, candidate: c, generation: 7,
                point: p, now: 10.1, targetWindowFocused: true, redirected: redirected)
        }
        XCTAssertTrue(eligible(link, CGPoint(x: 200, y: 110), redirected: true))
        XCTAssertFalse(eligible(link, CGPoint(x: 200, y: 110), redirected: false))
        XCTAssertFalse(eligible(slider, CGPoint(x: 300, y: 102), redirected: true))
        // A background slider is still captured (unchanged behavior).
        XCTAssertTrue(BackgroundClickPolicy.eligible(targetPID: 1, foregroundPID: 2, candidate: slider,
            generation: 7, point: CGPoint(x: 300, y: 102), now: 10.1, redirected: true))
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
    func testRedirectedClickInFocusedFrontmostAppTakesCapturedDelivery() {
        func eligible(redirected: Bool) -> Bool {
            BackgroundClickPolicy.eligible(targetPID: 1, foregroundPID: 1,
                candidate: candidate(), generation: 7, point: CGPoint(x: 200, y: 110), now: 10.1,
                targetWindowFocused: true, redirected: redirected)
        }
        XCTAssertTrue(eligible(redirected: true))
        XCTAssertFalse(eligible(redirected: false))
        // Redirect never widens containment: the delivered point must be inside.
        XCTAssertFalse(BackgroundClickPolicy.eligible(targetPID: 1, foregroundPID: 1,
            candidate: candidate(), generation: 7, point: CGPoint(x: 99, y: 110), now: 10.1,
            targetWindowFocused: true, redirected: true))
    }
    func testClickAimsAtLivePointerTheRingUsed() {
        // Measured on the user's Brave display under 1.01x zoom.
        let event = CGPoint(x: 6248.2, y: 297.5)
        let live = CGPoint(x: 6186.3, y: 315.9)
        let max = ClickAimPolicy.defaultMaxDivergence
        XCTAssertEqual(ClickAimPolicy.aim(event: event, live: live, maxDivergence: max),
                       .init(point: live, source: .live, reason: nil))
        XCTAssertEqual(ClickAimPolicy.aim(event: event, live: nil, maxDivergence: max).source, .event)
        XCTAssertEqual(ClickAimPolicy.aim(event: event, live: CGPoint(x: CGFloat.nan, y: 1),
                                          maxDivergence: max).point, event)
        let far = ClickAimPolicy.aim(event: event, live: CGPoint(x: event.x + max + 1, y: event.y),
                                     maxDivergence: max)
        XCTAssertEqual(far.point, event)
        XCTAssertEqual(far.reason, "divergence")
        XCTAssertEqual(ClickAimPolicy.maxDivergence(environment: [:]), max)
        XCTAssertEqual(ClickAimPolicy.maxDivergence(environment: [ClickAimPolicy.maxDivergenceEnvKey: "120"]), 120)
        XCTAssertEqual(ClickAimPolicy.maxDivergence(environment: [ClickAimPolicy.maxDivergenceEnvKey: "junk"]), max)
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

    func testOtherWindowTargetFilter() {
        XCTAssertTrue(GeometryPolicy.isOtherWindowTarget(targetWindow: 6, pointerWindow: 1))
        XCTAssertFalse(GeometryPolicy.isOtherWindowTarget(targetWindow: 1, pointerWindow: 1))
        XCTAssertFalse(GeometryPolicy.isOtherWindowTarget(targetWindow: nil, pointerWindow: 1))
        XCTAssertFalse(GeometryPolicy.isOtherWindowTarget(targetWindow: 0, pointerWindow: 1))
        XCTAssertFalse(GeometryPolicy.isOtherWindowTarget(targetWindow: 6, pointerWindow: 0))
    }

    /// Guarded failure (Brave, live log): overlap ownership published the YouTube
    /// tab as its visible share (2207,423,246,40) while the live AX frame stays
    /// (2207,423,248,40). The edge-for-edge check rejected it as
    /// "target-changed" before activation, so all 10 clicks were lost.
    func testLiveGeometryAcceptsVisibleShareOfAXFrame() {
        let published = CGRect(x: 2207, y: 423, width: 246, height: 40)
        let live = CGRect(x: 2207, y: 423, width: 248, height: 40)
        let click = BackgroundClickWire(x: 2386.8, y: 437.5, rect: published)
        XCTAssertFalse(BackgroundClickPolicy.matches(click, rect: live), "regression premise")
        XCTAssertEqual(BackgroundClickPolicy.liveGeometry(click, live: live), .matches)
        // Untrimmed (published == live) is the common path.
        XCTAssertEqual(BackgroundClickPolicy.liveGeometry(
            BackgroundClickWire(x: 2386.8, y: 437.5, rect: live), live: live), .matches)
    }

    func testLiveGeometryStillRejectsRealGeometryChanges() {
        let published = CGRect(x: 2207, y: 423, width: 246, height: 40)
        let click = BackgroundClickWire(x: 2386.8, y: 437.5, rect: published)
        XCTAssertEqual(BackgroundClickPolicy.liveGeometry(click, live: published.offsetBy(dx: 5, dy: 0)),
                       .publishedOutside)
        XCTAssertEqual(BackgroundClickPolicy.liveGeometry(click, live: published.insetBy(dx: -5, dy: -5)),
                       .noSharedEdge)
        XCTAssertEqual(BackgroundClickPolicy.liveGeometry(click,
                       live: CGRect(x: 2000, y: 423, width: 100, height: 40)), .pointOutside)
        XCTAssertEqual(BackgroundClickPolicy.liveGeometry(
            BackgroundClickWire(x: .nan, y: 437.5, rect: published), live: published), .invalidClick)
    }

    /// A consumed click is delivered natively only when nothing else owns it.
    func testRejectedBackgroundClickFallbackOwnership() {
        for reason in ["geometry-published-outside-live", "focus-not-established", "expired",
                       "unknown-target", "invalid-background-evidence", "duplicate-target"] {
            XCTAssertTrue(BackgroundClickPolicy.shouldDeliverOriginalAfterRejection(reason), reason)
        }
        for reason in ["axpress-failed-no-retry", "native-row-action-failed-no-retry",
                       "event-allocation-failed", "duplicate-request"] {
            XCTAssertFalse(BackgroundClickPolicy.shouldDeliverOriginalAfterRejection(reason), reason)
        }
    }
}

// baseline-guard:allow new headless regression suite; no prior baseline possible
import XCTest
import CoreGraphics
@testable import ClickAssistCore

/// Regression suite for the Click Assist decision core. Every test names the
/// real-world failure it guards, because each one of these shipped as a bug.
final class ClickAssistCoreTests: XCTestCase {

    // MARK: - helpers

    private let mainDisplay = CGRect(x: 0, y: 0, width: 7680, height: 2160)
    private var displays: [CGRect] { [mainDisplay] }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private func classify(_ role: String, _ r: CGRect, press: Bool = false,
                          on displays: [CGRect]? = nil) -> GeometryVerdict {
        GeometryPolicy.classify(role: role, hasPressAction: press, rect: r,
                                displayBounds: displays ?? self.displays)
    }

    private func cand(_ key: String, _ r: CGRect, tier: DecisionCore.Tier = .firstClass,
                      role: String = "AXButton") -> DecisionCore.Candidate {
        DecisionCore.Candidate(key: key, rect: r, inset: 2, tier: tier, role: role)
    }

    // MARK: - A. geometry / zoom

    /// Guarded failure: the fullscreen video seek bar (7638x7) was rejected by a
    /// fixed point cap, so the ring never appeared on a full-screen player.
    func testA1_fullscreenSeekBarIsATrack() {
        let v = classify("AXSlider", rect(20, 1000, 7638, 7))
        XCTAssertEqual(v.candidateClass, .track)
        XCTAssertNil(v.rejection)
    }

    /// Guarded failure: at 388% page zoom the iyf scrub bar is 3195x76 — an
    /// absolute 60 pt thinness cap rejected a perfectly clickable control.
    func testA2_zoomedScrubBarIsATrack() {
        let v = classify("AXSlider", rect(100, 300, 3195, 76))
        XCTAssertEqual(v.candidateClass, .track)
    }

    /// Guarded failure: a mis-exposed 2289x963 player CONTAINER exposed as
    /// AXSlider hijacked clicks meant for the real control.
    func testA3_playerContainerIsRejectedOversized() {
        let v = classify("AXSlider", rect(100, 200, 2289, 963))
        XCTAssertNil(v.candidateClass)
        XCTAssertEqual(v.rejection, .oversized)
    }

    /// Guarded failure: the old table exempted "thin" tracks from ALL area
    /// limits, so a 20000x200 pseudo-slider was admitted off-screen.
    func testA4_giantTrackHasNoAreaExemption() {
        let v = classify("AXSlider", rect(0, 1000, 20000, 200))
        XCTAssertNil(v.candidateClass)
        XCTAssertEqual(v.rejection, .oversized)
    }

    /// Guarded failure: action-row wrappers (1258x47, 1599x54) were admitted as
    /// tiles, so the ring highlighted page furniture instead of the button.
    func testA5_actionRowWrappersAreTileTooWide() {
        XCTAssertEqual(classify("AXGroup", rect(0, 100, 1258, 47)).rejection, .tileTooWide)
        XCTAssertEqual(classify("AXGroup", rect(0, 200, 1599, 54)).rejection, .tileTooWide)
    }

    /// Guarded failure: a page container (1466x944) passed as a tile while a real
    /// 204x290 thumbnail was rejected — exactly inverted.
    func testA6_pageContainerVsThumbnail() {
        XCTAssertEqual(classify("AXGroup", rect(0, 0, 1466, 944)).rejection, .tileTooLarge)
        XCTAssertEqual(classify("AXImage", rect(500, 500, 204, 290)).candidateClass, .tile)
    }

    /// Guarded failure: the 16x16 tab-close glyph was filtered out as
    /// "degenerate", so Chromium chrome buttons could never be assisted.
    func testA7_smallButtonIsDirect() {
        XCTAssertEqual(classify("AXButton", rect(10, 10, 16, 16)).candidateClass, .direct)
    }

    /// Guarded failure: a stale window frame below the display (y=3000) was
    /// admitted and the ring pointed at nothing visible.
    func testA8_rectBelowDisplayIsOffscreen() {
        let v = classify("AXButton", rect(0, 3000, 600, 300))
        XCTAssertNil(v.candidateClass)
        XCTAssertEqual(v.rejection, .offscreen)
    }

    /// Guarded failure: on a two-display desk a control straddling the seam was
    /// rejected because only one display was consulted.
    func testA9_straddlingDisplaysUseTheUnion() {
        let two = [rect(0, 0, 1920, 1080), rect(1920, 0, 1920, 1080)]
        let straddling = classify("AXSlider", rect(1800, 500, 600, 7), on: two)
        XCTAssertEqual(straddling.candidateClass, .track, "straddling the seam must use the union")
        let nowhere = classify("AXSlider", rect(5000, 500, 600, 7), on: two)
        XCTAssertEqual(nowhere.rejection, .offscreen)
    }

    // MARK: - B. crash safety (non-finite geometry)

    /// Guarded failure: AX answered an infinite/NaN frame and `Int(...)` on it
    /// traps — the overlay crashed on the main thread (EXC_BREAKPOINT).
    func testB_nonFiniteGeometryNeverTraps() {
        let fields: [(String, CGRect)] = [
            ("origin.x +inf", CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)),
            ("origin.x -inf", CGRect(x: -CGFloat.infinity, y: 0, width: 100, height: 100)),
            ("origin.x nan", CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)),
            ("origin.y +inf", CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100)),
            ("origin.y -inf", CGRect(x: 0, y: -CGFloat.infinity, width: 100, height: 100)),
            ("origin.y nan", CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100)),
            ("width +inf", CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)),
            ("width -inf", CGRect(x: 0, y: 0, width: -CGFloat.infinity, height: 100)),
            ("width nan", CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)),
            ("height +inf", CGRect(x: 0, y: 0, width: 100, height: CGFloat.infinity)),
            ("height -inf", CGRect(x: 0, y: 0, width: 100, height: -CGFloat.infinity)),
            ("height nan", CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan)),
        ]
        for (name, r) in fields {
            XCTAssertFalse(GeometryPolicy.isValidFrame(r), "isValidFrame must reject \(name)")
            let v = classify("AXSlider", r)
            XCTAssertNil(v.candidateClass, "non-finite \(name) must never be admitted")
            XCTAssertEqual(v.rejection, .nonFinite, "non-finite \(name) must be named nonFinite")
        }
    }

    /// Guarded failure: a zero-height or negative-width AX frame was treated as a
    /// real control and produced a NaN destination.
    /// NOTE: CG normalises a negative size at CGRect init (w=-40 becomes a 40 pt
    /// rect at x=-40), so that input is rejected by the display gate instead of
    /// the floor — still rejected, which is the invariant under test.
    func testB_zeroAndNegativeSizesAreRejected() {
        XCTAssertEqual(classify("AXButton", rect(0, 0, 0, 0)).rejection, .degenerate)
        XCTAssertEqual(classify("AXButton", rect(0, 0, 40, 0)).rejection, .degenerate)
        let negative = classify("AXButton", rect(0, 0, -40, 20))
        XCTAssertNil(negative.candidateClass, "a negative-size frame is never a control")
        XCTAssertNotNil(negative.rejection)
    }

    // MARK: - C. antichain / display set

    /// Guarded failure: the winner was dropped when any cached (not displayed!)
    /// candidate sat inside it, so the ring showed what the click does NOT hit.
    func testC1_winnerContainingAlternateIsStillShown() {
        let outer = cand("tab", rect(100, 100, 300, 300))
        let inner = cand("x", rect(250, 250, 50, 50))
        let shown = DecisionCore.displayCandidates(point: CGPoint(x: 120, y: 120),
                                                   candidates: [outer, inner], tolerance: 400)
        XCTAssertEqual(shown.map(\.candidate.key), ["tab"])
    }

    /// Guarded failure: a wrapper alternate that CONTAINS the winner was shown
    /// around the winner's ring, drawing a ring on page furniture.
    func testC2_alternateContainingWinnerIsDropped() {
        let outer = cand("wrapper", rect(100, 100, 400, 400))
        let winner = cand("radio", rect(200, 200, 60, 60))
        let shown = DecisionCore.displayCandidates(point: CGPoint(x: 230, y: 230),
                                                   candidates: [outer, winner], tolerance: 400)
        XCTAssertEqual(shown.map(\.candidate.key), ["radio"])
    }

    /// Guarded failure: over-eager dedupe dropped a genuinely separate neighbour.
    func testC3_disjointCandidatesAreBothShown() {
        let a = cand("a", rect(100, 100, 100, 100))
        let b = cand("b", rect(400, 100, 100, 100))
        let shown = DecisionCore.displayCandidates(point: CGPoint(x: 150, y: 150),
                                                   candidates: [a, b], tolerance: 400)
        XCTAssertEqual(shown.map(\.candidate.key), ["a", "b"])
    }

    /// Guarded failure: three nested containers produced three concentric rings
    /// with no way to tell which one the click hits.
    func testC4_threeNestedRingsKeepOnlyTheWinner() {
        let outer = cand("outer", rect(100, 100, 400, 400))
        let mid = cand("mid", rect(150, 150, 200, 200))
        let inner = cand("inner", rect(200, 200, 100, 100))
        let shown = DecisionCore.displayCandidates(point: CGPoint(x: 250, y: 250),
                                                   candidates: [outer, mid, inner], tolerance: 400)
        XCTAssertEqual(shown.map(\.candidate.key), ["inner"])
    }

    /// Guarded failure: the shown winner changed with AX walk order, so the ring
    /// and the click disagreed between two consecutive cycles.
    func testC5_permutationKeepsWinnerAtIndexZero() {
        let outer = cand("outer", rect(100, 100, 400, 400))
        let mid = cand("mid", rect(150, 150, 200, 200))
        let inner = cand("inner", rect(200, 200, 100, 100))
        let point = CGPoint(x: 250, y: 250)
        for perm in [[outer, mid, inner], [inner, outer, mid], [mid, inner, outer]] {
            let shown = DecisionCore.displayCandidates(point: point, candidates: perm,
                                                       tolerance: 400)
            XCTAssertEqual(shown.first?.candidate.key, "inner")
            XCTAssertEqual(shown.count, 1, "nested rings must collapse to the winner")
        }
    }

    // MARK: - D. duplicate surfaces

    /// Guarded failure (Brave): a tab and its AXRadioButton share one frame; the
    /// winner depended on walk order, so tabs/close buttons were ringed at random.
    func testD_identicalFramesAreOrderIndependent() {
        let frame = rect(300, 300, 180, 30)
        let group = cand("tabgroup", frame, tier: .secondClass, role: "AXTabGroup")
        let radio = cand("tab-radio", frame, tier: .firstClass, role: "AXRadioButton")
        let point = CGPoint(x: 350, y: 315)
        let forward = DecisionCore.route(point: point, candidates: [group, radio],
                                         tolerance: 300)
        let reverse = DecisionCore.route(point: point, candidates: [radio, group],
                                         tolerance: 300)
        func winnerKey(_ d: DecisionCore.Decision) -> String? {
            switch d {
            case .directHit(let c, _): return c.key
            case .redirect(let c, _, _, _, _): return c.key
            case .ambiguous(let scored, _): return scored.first?.candidate.key
            case .noCandidate: return nil
            }
        }
        XCTAssertEqual(winnerKey(forward), winnerKey(reverse),
                       "duplicate surfaces must resolve identically regardless of AX order")
        XCTAssertEqual(winnerKey(forward), "tab-radio", "the real control must win the tie")
    }

    // MARK: - E. ambiguity abstains

    /// Guarded failure: two equidistant unrelated controls silently picked one and
    /// the assist clicked the wrong page element.
    func testE_equidistantControlsAbstain() {
        let left = cand("left", rect(100, 100, 100, 100))
        let right = cand("right", rect(300, 100, 100, 100))
        let point = CGPoint(x: 250, y: 150)   // 50 pt from each
        func isAmbiguous(_ order: [DecisionCore.Candidate]) -> Bool {
            if case .ambiguous = DecisionCore.route(point: point, candidates: order,
                                                    tolerance: 200) { return true }
            return false
        }
        XCTAssertTrue(isAmbiguous([left, right]))
        XCTAssertTrue(isAmbiguous([right, left]))
    }

    // MARK: - F. randomised antichain invariant

    /// Guarded failure: an antichain violation slipping past the hand-written
    /// cases — a shown ring nested in another shown ring, or a missing winner.
    func testF_randomSetsStayAntichainAndKeepWinner() {
        var rng = SeededGenerator(seed: 0xC11C_A55E_17)
        for iteration in 0..<50 {
            let count = Int.random(in: 2...6, using: &rng)
            var candidates: [DecisionCore.Candidate] = []
            for i in 0..<count {
                let x = CGFloat(Int.random(in: 0...900, using: &rng))
                let y = CGFloat(Int.random(in: 0...700, using: &rng))
                let w = CGFloat(Int.random(in: 20...300, using: &rng))
                let h = CGFloat(Int.random(in: 20...300, using: &rng))
                candidates.append(cand("c\(i)", rect(x, y, w, h),
                                       tier: i % 2 == 0 ? .firstClass : .secondClass))
            }
            let point = CGPoint(x: CGFloat(Int.random(in: 0...1000, using: &rng)),
                                y: CGFloat(Int.random(in: 0...800, using: &rng)))
            let shown = DecisionCore.displayCandidates(point: point, candidates: candidates,
                                                       tolerance: 400)
            guard case .winner(let winner, _) = DecisionCore.resolve(point: point,
                                                                     candidates: candidates,
                                                                     tolerance: 400) else {
                XCTAssertTrue(shown.isEmpty, "no winner => no rings (iteration \(iteration))")
                continue
            }
            XCTAssertEqual(shown.first?.candidate.key, winner.candidate.key,
                           "iteration \(iteration): the click winner must always be shown")
            let rects = shown.map(\.candidate.rect)
            for i in rects.indices {
                for j in rects.indices where i != j {
                    XCTAssertFalse(DecisionCore.isNested(rects[i], rects[j]),
                                   "iteration \(iteration): shown ring \(i) nests ring \(j)")
                }
            }
        }
    }

    // MARK: - G. target-relative movement rule (frameMoved)

    /// Small control: 16x16 tolerates 3 pt of drift, cancels at 6 pt.
    func testG1_smallControlToleratesThreeNotSix() {
        let base = rect(100, 100, 16, 16)
        XCTAssertFalse(FrameContinuity.moved(base, base.offsetBy(dx: 3, dy: 0)))
        XCTAssertTrue(FrameContinuity.moved(base, base.offsetBy(dx: 6, dy: 0)))
    }

    /// Large control: 400x400 tolerates 10 pt, cancels at 30 pt (never more than 24).
    func testG2_largeControlToleratesTenNotThirty() {
        let base = rect(100, 100, 400, 400)
        XCTAssertFalse(FrameContinuity.moved(base, base.offsetBy(dx: 10, dy: 0)))
        XCTAssertTrue(FrameContinuity.moved(base, base.offsetBy(dx: 30, dy: 0)))
    }

    /// An unchanged frame is the same control.
    func testG3_identicalRectAllowed() {
        let base = rect(50, 60, 120, 40)
        XCTAssertFalse(FrameContinuity.moved(base, base))
    }

    /// Identity continuity: overlap below half the smaller area cancels even when
    /// the two frames share an origin (here the control changed shape, overlap 0.25).
    func testG4_lowOverlapCancelsRegardlessOfDistance() {
        let cached = rect(100, 100, 400, 100)
        let fresh = rect(100, 100, 100, 400)
        XCTAssertLessThan(FrameContinuity.overlapFraction(cached, fresh), 0.5)
        XCTAssertTrue(FrameContinuity.moved(cached, fresh), "lost identity must cancel")
    }

    // MARK: - H. published evidence / async AXPress policy

    /// Fresh evidence: same generation, within the 400 ms window.
    func testH1_evidenceFresh() {
        XCTAssertEqual(ClickAssistEvidence.state(evidenceGeneration: 7, currentGeneration: 7,
                                                 ageMs: 10), .fresh)
    }

    /// Evidence past maxAgeMs is stale (the tap must not refresh it synchronously).
    func testH2_evidenceStale() {
        XCTAssertEqual(ClickAssistEvidence.state(evidenceGeneration: 7, currentGeneration: 7,
                                                 ageMs: ClickAssistEvidence.maxAgeMs + 1), .stale)
    }

    /// Evidence from another publish cycle is unusable even if the clock is fresh.
    func testH3_evidenceWrongGeneration() {
        XCTAssertEqual(ClickAssistEvidence.state(evidenceGeneration: 6, currentGeneration: 7,
                                                 ageMs: 1), .wrongGeneration)
        XCTAssertEqual(ClickAssistEvidence.state(evidenceGeneration: 0, currentGeneration: 7,
                                                 ageMs: 1), .missing)
    }

    /// The worker accepts a request inside 150 ms and rejects one past it.
    func testH4_requestExpiry() {
        let request = AXPressRequest(targetKey: "tab-close", pid: 42, generation: 9,
                                     issuedAt: 100, expiryMs: 150)
        XCTAssertNil(AXPressGate.rejection(request: request, currentGeneration: 9,
                                           identityMatches: true, now: 100.149))
        XCTAssertEqual(AXPressGate.rejection(request: request, currentGeneration: 9,
                                             identityMatches: true, now: 100.151), .expired)
    }

    /// A stale generation or swapped element is rejected before activation.
    func testH5_generationAndIdentityRejection() {
        let request = AXPressRequest(targetKey: "tab-close", pid: 42, generation: 9,
                                     issuedAt: 100, expiryMs: 150)
        XCTAssertEqual(AXPressGate.rejection(request: request, currentGeneration: 10,
                                             identityMatches: true, now: 100.010),
                       .staleGeneration)
        XCTAssertEqual(AXPressGate.rejection(request: request, currentGeneration: 9,
                                             identityMatches: false, now: 100.010),
                       .identityMismatch)
    }

    /// Ownership is taken at dispatch: the matching up is consumed even when the
    /// worker later rejects the activation (activation outcome is irrelevant).
    func testH6_ownerConsumesUpRegardlessOfRejection() {
        XCTAssertTrue(GestureOwnership.consumes(tokenActive: true, isDown: false,
                                                isDrag: false, isUp: true))
        XCTAssertTrue(GestureOwnership.consumes(tokenActive: true, isDown: false,
                                                isDrag: true, isUp: false))
        XCTAssertFalse(GestureOwnership.consumes(tokenActive: false, isDown: false,
                                                 isDrag: false, isUp: true))
    }

    // MARK: - I. absolute deadline / bounded queue / dedup

    /// The deadline is fixed at issue and re-checked at execution: a request that
    /// aged while queued is rejected, and receipt never renews it.
    func testI1_deadlineAtExecution() {
        let request = AXPressRequest(targetKey: "tab-close", pid: 42, generation: 9,
                                     issuedAt: 100, expiryMs: 150)
        XCTAssertEqual(request.deadline, 100.15, accuracy: 1e-9)
        XCTAssertFalse(AXPressGate.executionExpired(request, now: 100.10))
        XCTAssertTrue(AXPressGate.executionExpired(request, now: 100.20),
                      "a request that aged in the queue must die at execution")
        XCTAssertTrue(AXPressGate.executionExpired(request, now: 100.15))
    }

    /// Two activations for the same target inside 250 ms collapse to one.
    func testI2_duplicateWithinWindow() {
        let dup = AXPressAdmission.evaluate(targetKey: "tab-close", now: 100.10,
                                            lastTarget: "tab-close", lastIssuedAt: 100.00,
                                            pending: 0)
        XCTAssertEqual(dup?.rejection, .duplicate)
        XCTAssertEqual(dup?.dtMs ?? 0, 100, accuracy: 0.001)
        XCTAssertNil(AXPressAdmission.evaluate(targetKey: "tab-close", now: 100.25,
                                               lastTarget: "tab-close", lastIssuedAt: 100.00,
                                               pending: 0), "outside the 250 ms window")
        XCTAssertNil(AXPressAdmission.evaluate(targetKey: "other", now: 100.10,
                                               lastTarget: "tab-close", lastIssuedAt: 100.00,
                                               pending: 0), "different target is not a duplicate")
    }

    /// At the bound the new activation is rejected and never enqueued.
    func testI3_queueFull() {
        XCTAssertEqual(AXPressAdmission.evaluate(targetKey: "t", now: 10,
                                                 lastTarget: nil, lastIssuedAt: nil,
                                                 pending: AXPressAdmission.maxPendingPresses)?.rejection,
                       .queueFull)
        XCTAssertNil(AXPressAdmission.evaluate(targetKey: "t", now: 10,
                                               lastTarget: nil, lastIssuedAt: nil,
                                               pending: AXPressAdmission.maxPendingPresses - 1))
    }

    /// Evidence outlives a press request by design (400 ms vs 150 ms).
    func testI4_expiryRelationship() {
        XCTAssertGreaterThan(ClickAssistEvidence.maxAgeMs, AXPressGate.defaultExpiryMs)
        XCTAssertEqual(AXPressGate.defaultExpiryMs, 150)
        XCTAssertEqual(AXPressAdmission.maxPendingPresses, 4)
        XCTAssertEqual(AXPressAdmission.dedupeWindowMs, 250)
    }
}

/// Deterministic RNG so a failure is reproducible from the seed alone.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

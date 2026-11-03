import XCTest
import CoreGraphics
@testable import ClickAssistCore

/// ArtPlayer-style seek bar: the clickable bar is an AXGroup+AXPress (1288x8)
/// whose non-press children are wide-thin AXGroups of the same footprint.
final class ClickAssistProgressBarGroupTests: XCTestCase {
    let display = [CGRect(x: 0, y: 0, width: 1728, height: 1117)]
    let window = [CGRect(x: 0, y: 0, width: 1728, height: 1117)]
    func classify(_ r: CGRect, press: Bool) -> GeometryVerdict {
        GeometryPolicy.classify(role: "AXGroup", hasPressAction: press, rect: r,
                                displayBounds: display, windowBounds: window)
    }
    func testTreeClassification() {
        let bar = CGRect(x: 100, y: 900, width: 1288, height: 8)
        let inner = CGRect(x: 100, y: 901, width: 1288, height: 5)
        let played = CGRect(x: 100, y: 901, width: 12, height: 5)
        XCTAssertEqual(classify(bar, press: true).candidateClass, .pressGroup)
        XCTAssertEqual(classify(inner, press: false).candidateClass, .wideThin)
        XCTAssertNil(classify(played, press: false).candidateClass)
        XCTAssertEqual(classify(CGRect(x: 100, y: 896, width: 1288, height: 14), press: false).rejection,
                       .thinGroupMismatch)
    }
    func cand(_ key: String, _ r: CGRect, _ tier: DecisionCore.Tier, _ role: String) -> DecisionCore.Candidate {
        .init(key: key, rect: r, inset: 2, tier: tier, role: role)
    }
    func testBarWinsOverThinNonPressTwins() {
        let bar = CGRect(x: 100, y: 900, width: 1288, height: 8)
        let inner = CGRect(x: 100, y: 901, width: 1288, height: 5)
        for p in [CGPoint(x: 600, y: 904), CGPoint(x: 600, y: 900.5), CGPoint(x: 600, y: 880)] {
            let cs = [cand("bar", bar, .firstClass, "AXPressGroup"),
                      cand("inner", inner, .secondClass, "AXGroup")]
            guard case .winner(let w, _) = DecisionCore.resolve(point: p, candidates: cs, tolerance: 32) else {
                return XCTFail("no winner at \(p)")
            }
            XCTAssertEqual(w.candidate.key, "bar", "at \(p)")
            XCTAssertEqual(w.snap, .edge)
        }
    }

    /// Pre-dedupe the resolver can hold several equal-footprint thin twins
    /// (inner / loaded / indicator). The wrapper filter must not drop the bar.
    func testBarSurvivesWrapperFilterWithThreeTwins() {
        let bar = CGRect(x: 100, y: 900, width: 1288, height: 8)
        let inner = CGRect(x: 100, y: 901, width: 1288, height: 5)
        let cs = [cand("bar", bar, .firstClass, "AXPressGroup"),
                  cand("inner", inner, .secondClass, "AXGroup"),
                  cand("loaded", inner, .secondClass, "AXGroup"),
                  cand("indicator", inner, .secondClass, "AXGroup")]
        let r = DecisionCore.resolve(point: CGPoint(x: 600, y: 904), candidates: cs, tolerance: 32)
        guard case .winner(let w, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(w.candidate.key, "bar")
    }

    // Frame-nested players answer the hit-test with the frame's web document.
    func testBarPageAnswerConfirmsOnlyBarShapedPressGroupWithLiveAncestorHit() {
        let bar = CGRect(x: 100, y: 900, width: 1288, height: 8)
        let dest = CGPoint(x: 500, y: 904)
        func ok(role: String = "AXPressGroup", rect: CGRect? = nil, owns: Bool = true,
                live: Bool = true, enabled: Bool = true) -> Bool {
            GeometryPolicy.confirmsBarPageAnswer(candidateRole: role, candidate: rect ?? bar,
                destination: dest, hitIsOwnWebArea: owns, liveFrameMatches: live, enabled: enabled)
        }
        XCTAssertTrue(ok())
        XCTAssertFalse(ok(role: "AXGroup"))
        XCTAssertFalse(ok(owns: false))
        XCTAssertFalse(ok(live: false))
        XCTAssertFalse(ok(enabled: false))
        // A card-sized press group must not be confirmed by the page answering.
        XCTAssertFalse(ok(rect: CGRect(x: 100, y: 800, width: 400, height: 200)))
    }
}

final class GuidedAlternatesTests: XCTestCase {
    func testOrdersDeepestFirstFiltersFarAndBounds() {
        let near = CGRect(x: 90, y: 90, width: 20, height: 20)
        let layer = CGRect(x: 0, y: 0, width: 1312, height: 738)
        let far = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        let e = [GuidedAlternates.Entry(index: 0, depth: 3, frame: layer),
                 GuidedAlternates.Entry(index: 1, depth: 3, frame: layer),
                 GuidedAlternates.Entry(index: 2, depth: 7, frame: far),
                 GuidedAlternates.Entry(index: 3, depth: 9, frame: layer)]
        XCTAssertEqual(GuidedAlternates.ordered(e, near: near, limit: 8).map(\.index), [3, 0, 1])
        XCTAssertEqual(GuidedAlternates.ordered(e, near: near, limit: 2).map(\.index), [3, 0])
        XCTAssertTrue(GuidedAlternates.ordered(e, near: near, limit: 0).isEmpty)
    }
}

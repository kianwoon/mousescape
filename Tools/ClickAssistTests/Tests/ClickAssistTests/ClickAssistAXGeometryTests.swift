import XCTest
import ApplicationServices
@testable import ClickAssistCore

final class ClickAssistAXGeometryTests: XCTestCase {
    private func values(_ rect: CGRect) -> CFArray {
        var p = rect.origin, s = rect.size
        return [AXValueCreate(.cgPoint, &p)!, AXValueCreate(.cgSize, &s)!] as CFArray
    }

    func testLiveBatchPreservesLargeAndNegativeCoordinatesWithoutSecondRead() {
        for rect in [CGRect(x: -7680, y: -2160, width: 7680, height: 4320),
                     CGRect(x: 21, y: 2070, width: 7638, height: 6)] {
            var retried = false
            XCTAssertEqual(AXGeometry.readFrame(batch: { self.values(rect) }, separate: {
                retried = true; return nil
            }), rect)
            XCTAssertFalse(retried)
        }
    }

    func testUnsupportedAndPartialBatchesKeepOriginalReader() {
        let rect = CGRect(x: 400, y: 80, width: 250, height: 30)
        for batch: CFArray? in [nil, [] as CFArray, ["unsupported", "unsupported"] as CFArray,
                               ["partial"] as CFArray] {
            var retried = false
            XCTAssertEqual(AXGeometry.readFrame(batch: { batch }, separate: {
                retried = true; return self.values(rect)
            }), rect)
            XCTAssertTrue(retried)
        }
    }

    func testInvalidOrUnavailableFramesCannotBecomeRingTargets() {
        for rect in [CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20),
                     CGRect(x: 0, y: 0, width: 20, height: CGFloat.nan)] {
            XCTAssertNil(AXGeometry.readFrame(batch: { self.values(rect) }, separate: { nil }))
        }
        XCTAssertNil(AXGeometry.readFrame(batch: { ["not geometry", 1] as CFArray }, separate: { nil }))
        XCTAssertNil(AXGeometry.readFrame(batch: { nil }, separate: { nil }))
        // The geometry reader preserves zero-sized AX nodes; admission rejects
        // them exactly as before, rather than manufacturing a clickable frame.
        let empty = CGRect(x: 0, y: 0, width: 0, height: 20)
        let result = AXGeometry.readFrame(batch: { self.values(empty) }, separate: { nil })
        XCTAssertEqual(result, empty)
        XCTAssertNotNil(GeometryPolicy.classify(role: "AXButton", hasPressAction: true,
            rect: result!, displayBounds: [CGRect(x: 0, y: 0, width: 7680, height: 4320)]).rejection)
    }
}

import CoreGraphics
import XCTest
@testable import ClickAssistCore

/// Viewport gate for row candidates: rows scrolled under an enclosing scroll
/// area's edge (e.g. an Open panel's bottom button bar) must not be targets.
final class ClickAssistRowViewportTests: XCTestCase {
    private let viewport = CGRect(x: 100, y: 1000, width: 600, height: 700) // maxY = 1700
    private let rowHeight: CGFloat = 40

    private func row(minY: CGFloat, height: CGFloat? = nil) -> CGRect {
        CGRect(x: 120, y: minY, width: 500, height: height ?? rowHeight)
    }

    func testNoEnclosingScrollAreaKeepsRow() {
        XCTAssertTrue(GeometryPolicy.isVisibleInViewport(row(minY: 5000), viewports: []))
    }

    func testFullyVisibleRowKept() {
        XCTAssertTrue(GeometryPolicy.isVisibleInViewport(row(minY: 1200), viewports: [viewport]))
    }

    /// Measured live: hidden row at y=1765-1805 beneath the panel's button bar.
    func testRowEntirelyBelowViewportDropped() {
        XCTAssertFalse(GeometryPolicy.isVisibleInViewport(row(minY: viewport.maxY + 65),
                                                          viewports: [viewport]))
    }

    func testRowTouchingViewportEdgeDropped() {
        XCTAssertFalse(GeometryPolicy.isVisibleInViewport(row(minY: viewport.maxY),
                                                          viewports: [viewport]))
    }

    func testVisibleFractionBelowPolicyDropped() {
        let visible = rowHeight * GeometryPolicy.rowMinVisibleHeightFraction - 1
        XCTAssertFalse(GeometryPolicy.isVisibleInViewport(row(minY: viewport.maxY - visible),
                                                          viewports: [viewport]))
    }

    func testVisibleFractionAtPolicyKept() {
        let visible = rowHeight * GeometryPolicy.rowMinVisibleHeightFraction
        XCTAssertTrue(GeometryPolicy.isVisibleInViewport(row(minY: viewport.maxY - visible),
                                                         viewports: [viewport]))
    }

    func testClipAtTopEdgeUsesSameFraction() {
        let visible = rowHeight * GeometryPolicy.rowMinVisibleHeightFraction
        XCTAssertTrue(GeometryPolicy.isVisibleInViewport(row(minY: viewport.minY - (rowHeight - visible)),
                                                         viewports: [viewport]))
        XCTAssertFalse(GeometryPolicy.isVisibleInViewport(row(minY: viewport.minY - (rowHeight - visible) - 1),
                                                          viewports: [viewport]))
    }

    func testTallRowSliverBelowMinimumHeightDropped() {
        // Fraction alone would pass for a tiny row; the sliver floor binds here
        // only when the visible part is below rowMinVisibleHeight.
        let tall = GeometryPolicy.rowMinVisibleHeight * 1.5
        let visible = GeometryPolicy.rowMinVisibleHeight - 1
        XCTAssertGreaterThanOrEqual(visible, tall * GeometryPolicy.rowMinVisibleHeightFraction)
        XCTAssertFalse(GeometryPolicy.isVisibleInViewport(row(minY: viewport.maxY - visible, height: tall),
                                                          viewports: [viewport]))
    }

    func testFullyVisibleRowShorterThanSliverFloorKept() {
        let short = GeometryPolicy.rowMinVisibleHeight - 2
        XCTAssertTrue(GeometryPolicy.isVisibleInViewport(row(minY: 1200, height: short), viewports: [viewport]))
    }

    func testNestedViewportsIntersect() {
        let inner = CGRect(x: 100, y: 1000, width: 600, height: 300) // maxY = 1300
        XCTAssertFalse(GeometryPolicy.isVisibleInViewport(row(minY: 1400), viewports: [inner, viewport]))
        XCTAssertTrue(GeometryPolicy.isVisibleInViewport(row(minY: 1200), viewports: [inner, viewport]))
    }

    func testDisjointNestedViewportsDropRow() {
        let elsewhere = CGRect(x: 2000, y: 0, width: 100, height: 100)
        XCTAssertFalse(GeometryPolicy.isVisibleInViewport(row(minY: 1200), viewports: [viewport, elsewhere]))
    }
}

//
//  HotspotZoomInspectorView.swift
//  Mousecape
//
//  Zoomable single-frame inspector for verifying cursor hotspot placement.
//  Shows frame 0 of the cursor sprite at 1x–64x magnification with a
//  crosshair + red dot pinned to the hotspot's exact position. The mapping
//  (hotSpot pt → view px) mirrors HotspotIndicator in AnimatingCursorView,
//  so what the user sees here is what gets registered.
//
//  Why not zoom AnimatingCursorView directly: the editor preview is a fixed
//  200pt drop zone shared with drag-and-drop import. A separate inspector
//  keeps the drop zone behavior untouched while giving pixel-level precision.
//

import SwiftUI
import AppKit

struct HotspotZoomInspectorView: View {
    let cursor: Cursor
    var refreshTrigger: Int = 0
    /// Called when the user clicks/drags on the zoomed canvas to place the
    /// hotspot. Receives the new hotspot in cursor point coordinates
    /// (already clamped to the cursor's point size). The parent commits it
    /// through the editor's normal undo/sync path.
    var onHotspotChange: ((NSPoint) -> Void)? = nil

    // MARK: - Zoom state

    @State private var zoom: CGFloat = 8
    @State private var zoomAtOpen: CGFloat = 8
    static let zoomRange: ClosedRange<CGFloat> = 1...64

    // MARK: - Frame state (frame 0 only — hotspot is a frame-0 property)

    @State private var frameImage: NSImage?

    /// In-progress hotspot while the user is dragging (pt coordinates).
    /// Shows live feedback without committing until drag ends.
    @State private var pendingHotspot: NSPoint?

    /// The hotspot to display: live drag position wins over committed value.
    private var effectiveHotspot: NSPoint {
        pendingHotspot ?? cursor.hotSpot
    }

    /// Live pointer position in canvas coordinates (top-left origin), or nil
    /// when the pointer is outside the canvas. Drives the custom reticle that
    /// replaces the system cursor (which would otherwise cover the exact
    /// pixels under the pointer while adjusting the hotspot).
    @State private var pointerCanvasPoint: CGPoint? = nil

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let frameSize = frameImage?.size ?? .zero
                let scaled = CGSize(width: frameSize.width * zoom,
                                    height: frameSize.height * zoom)
                // Zoom pivots on the HOTSPOT (bug 2026-09-04: centering the
                // image meant high zoom pushed the dot off-canvas). The dot
                // is pinned to the canvas center at every zoom level; when
                // the frame is smaller than the canvas, center the whole
                // frame instead so low zoom still shows the full cursor.
                // Offsets anchor to the COMMITTED hotspot (not the live-drag
                // value) so the canvas→hotspot inverse transform stays stable
                // under the pointer during a drag. On release the view
                // re-centers on the newly committed hotspot.
                let offsetX = alignOffset(available: geo.size.width,
                                          content: scaled.width,
                                          hotspot: cursor.hotSpot.x * zoom)
                let offsetY = alignOffset(available: geo.size.height,
                                          content: scaled.height,
                                          hotspot: cursor.hotSpot.y * zoom)

                ZStack(alignment: .topLeading) {
                    // Checkerboard so semi-transparent cursor pixels are visible
                    CheckerboardBackground()
                        .frame(width: geo.size.width, height: geo.size.height)

                    if let img = frameImage {
                        // Image pinned to its layout slot — .frame + offset, NOT
                        // .position (position also re-centers the view's center
                        // coordinate, which breaks the hotspot math below).
                        Image(nsImage: img)
                            .interpolation(.none)   // pixel-accurate at high zoom
                            .resizable()
                            .frame(width: scaled.width, height: scaled.height)
                            .offset(x: offsetX, y: offsetY)

                        // Crosshair spanning the full canvas at the hotspot's exact point
                        let hs = hotspotPoint(hotspot: effectiveHotspot,
                                              offset: CGPoint(x: offsetX, y: offsetY))
                        CrosshairShape(at: hs, canvas: geo.size)
                            .stroke(Color.red.opacity(0.7),
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        // Hotspot dot — same formula as HotspotIndicator
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            .position(x: hs.x, y: hs.y)
                    } else {
                        Text("No image")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }

                    // Custom reticle tracking the pointer. The system cursor
                    // is hidden while over the canvas (see CursorHideTracker)
                    // because it covers the exact pixels the user is placing;
                    // this minimal reticle shows the precise point instead.
                    if let pointer = pointerCanvasPoint {
                        PointerReticle(at: pointer)
                            .allowsHitTesting(false)   // never intercept clicks/drags
                    }

                    // Movement/hover tracker: hides the system cursor while
                    // the pointer is over the canvas and reports its position.
                    // Clear NSView, mouseDown-agnostic → coexists with the
                    // DragGesture above (which keeps handling click/drag).
                    CursorHideTracker(point: $pointerCanvasPoint)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }
                .clipped()
                .contentShape(Rectangle())
                // Click or drag on the zoomed canvas to place the hotspot.
                // The crosshair follows the pointer live; release commits.
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pendingHotspot = canvasToHotspot(
                            canvasPoint: value.location,
                            offset: CGPoint(x: offsetX, y: offsetY),
                            canvas: geo.size)
                    }
                    .onEnded { value in
                        let newHS = canvasToHotspot(
                            canvasPoint: value.location,
                            offset: CGPoint(x: offsetX, y: offsetY),
                            canvas: geo.size)
                        pendingHotspot = nil
                        onHotspotChange?(newHS)
                    }
                )
            }
            .frame(height: 260)
            .background(CheckerboardBackground())
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .gesture(MagnificationGesture()
                .onChanged { value in
                    zoom = min(max(HotspotZoomInspectorView.zoomRange.lowerBound, zoomAtOpen * value),
                               HotspotZoomInspectorView.zoomRange.upperBound)
                }
                .onEnded { _ in zoomAtOpen = zoom }
            )

            HStack(spacing: 8) {
                Text("Hotspot: (\(String(format: "%.2f", effectiveHotspot.x)), \(String(format: "%.2f", effectiveHotspot.y))) — click or drag to adjust")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    zoom = max(HotspotZoomInspectorView.zoomRange.lowerBound, zoom / 2)
                    zoomAtOpen = zoom
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(zoom <= HotspotZoomInspectorView.zoomRange.lowerBound)
                .buttonStyle(.borderless)

                Slider(value: $zoom, in: HotspotZoomInspectorView.zoomRange, step: 0.5) { _ in
                    zoomAtOpen = zoom
                }
                .frame(width: 140)

                Button {
                    zoom = min(HotspotZoomInspectorView.zoomRange.upperBound, zoom * 2)
                    zoomAtOpen = zoom
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(zoom >= HotspotZoomInspectorView.zoomRange.upperBound)
                .buttonStyle(.borderless)

                Text("\(Int(zoom))×")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(4)
        .onAppear { loadFrame() }
        .onDisappear {
            // Popover may be dismissed while the cursor is hidden (e.g. click
            // outside to close) — force-restore so the system cursor never
            // stays hidden after the inspector goes away.
            CursorHideTracker.forceRestoreIfNeeded()
        }
        .onChange(of: refreshTrigger) { _, _ in loadFrame() }
        .onChange(of: cursor.id) { _, _ in loadFrame() }
    }

    /// hotspot (pt, top-left origin) → view point, mirroring HotspotIndicator:
    /// offset (centering) + hotspot × zoom.
    private func hotspotPoint(hotspot: NSPoint, offset: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + hotspot.x * zoom,
                y: offset.y + hotspot.y * zoom)
    }

    /// Inverse transform: canvas point → hotspot in cursor pt coordinates,
    /// clamped to the cursor's point-size bounds (matches apply.m's
    /// registration clamp: 0 ≤ hotspot < size, 0.01 margin).
    private func canvasToHotspot(canvasPoint: CGPoint, offset: CGPoint, canvas: CGSize) -> NSPoint {
        let maxX = max(0, cursor.size.width - 0.01)
        let maxY = max(0, cursor.size.height - 0.01)
        let x = (canvasPoint.x - offset.x) / zoom
        let y = (canvasPoint.y - offset.y) / zoom
        return NSPoint(x: min(max(0, x), maxX),
                       y: min(max(0, y), maxY))
    }

    /// Offset that aligns content so the hotspot lands on `available/2`
    /// (canvas center). When the content is smaller than the canvas, fall
    /// back to plain centering so the whole frame stays visible at low zoom.
    private func alignOffset(available: CGFloat, content: CGFloat, hotspot: CGFloat) -> CGFloat {
        if content <= available {
            return (available - content) / 2
        }
        return available / 2 - hotspot
    }

    private func loadFrame() {
        guard let image = cursor.image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            frameImage = nil
            return
        }
        let frameCount = max(1, cursor.frameCount)
        let frameHeight = cgImage.height / frameCount
        let cropRect = CGRect(x: 0, y: 0, width: cgImage.width, height: frameHeight)
        guard let cropped = cgImage.cropping(to: cropRect) else {
            frameImage = nil
            return
        }
        // Logical size = cursor point size (matches AnimatingCursorView frame cache)
        let logical = NSSize(width: image.size.width,
                             height: image.size.height / CGFloat(frameCount))
        frameImage = NSImage(cgImage: cropped, size: logical)
    }
}

// MARK: - Cursor hide tracker + pointer reticle

/// NSViewRepresentable that hides the system cursor while the pointer is over
/// the zoom canvas and reports the pointer's position in canvas coordinates.
///
/// Balancing contract: every `NSCursor.hide()` is paired with exactly one
/// `NSCursor.unhide()`, guarded by `isCursorHidden` so double-hide can never
/// stack. Restoration paths: mouseExited, view removal (removeFromSuperview —
/// SwiftUI tears the representable down with the hierarchy), deinit, and the
/// inspector's `onDisappear` force-restore.
private struct CursorHideTracker: NSViewRepresentable {
    @Binding var point: CGPoint?

    static func forceRestoreIfNeeded() {
        CursorHidingNSView.restoreAnyInstance()
    }

    func makeNSView(context: Context) -> CursorHidingNSView {
        let v = CursorHidingNSView()
        v.onLocationChange = { [weak v] nsPoint in
            guard let v = v else { return }
            // NSView bottom-left origin → SwiftUI top-left origin.
            point = CGPoint(x: nsPoint.x, y: v.bounds.height - nsPoint.y)
        }
        v.onExit = { point = nil }
        return v
    }

    func updateNSView(_ nsView: CursorHidingNSView, context: Context) {}

    /// Clear tracking view: never claims mouseDown (so the SwiftUI DragGesture
    /// keeps handling click/drag-to-set), only observes movement. Hit-testing
    /// is additionally disabled at the SwiftUI layer.
    final class CursorHidingNSView: NSView {
        /// Any live tracker instance that currently hides the cursor. Lets the
        /// inspector's onDisappear force-restore even if the NSView teardown
        /// ordering is unpredictable.
        private static weak var liveInstance: CursorHidingNSView?

        var onLocationChange: ((NSPoint) -> Void)?
        var onExit: (() -> Void)?
        private var isCursorHidden = false
        private var trackingArea: NSTrackingArea?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { restoreAndClearPointer() }
        }

        override func layout() {
            super.layout()
            updateTrackingArea()
        }

        private func updateTrackingArea() {
            if let existing = trackingArea { removeTrackingArea(existing) }
            // Cover the full canvas bounds; rect updates automatically on
            // resize via layout(). movementOptions also fires during drags.
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect
            ]
            let area = NSTrackingArea(rect: bounds, options: options,
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            hideCursor()
        }

        override func mouseExited(with event: NSEvent) {
            restoreCursor()
            onExit?()
        }

        /// .mouseMoved covers plain moves; the `.mouseDragged` modifier on the
        /// event mask (set via movementOptions below) keeps the reticle glued
        /// to the pointer during hotspot drags.
        override func mouseMoved(with event: NSEvent) {
            report(event)
        }

        override func mouseDragged(with event: NSEvent) {
            report(event)
        }

        private func report(_ event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return }
            onLocationChange?(local)
        }

        private func hideCursor() {
            guard !isCursorHidden else { return }   // no double-hide
            isCursorHidden = true
            Self.liveInstance = self
            NSCursor.hide()
        }

        private func restoreCursor() {
            guard isCursorHidden else { return }    // exactly-once unhide
            isCursorHidden = false
            NSCursor.unhide()
        }

        private func restoreAndClearPointer() {
            restoreCursor()
            onExit?()
        }

        static func restoreAnyInstance() {
            liveInstance?.restoreAndClearPointer()
        }

        deinit {
            // Safety net: never leave the system cursor hidden if the view is
            // torn down without a mouseExited (e.g. popover dismissal).
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
        }
    }
}

/// Minimal pointer reticle shown at the reported pointer position while the
/// system cursor is hidden over the canvas: 1px crosshair hairlines (~13pt)
/// plus a 5pt ring, white with a black outline + shadow so it reads clearly
/// on the checkerboard, on light or dark cursor art, at any zoom.
private struct PointerReticle: View {
    let at: CGPoint

    static let armLength: CGFloat = 13
    static let ringDiameter: CGFloat = 5

    var body: some View {
        ZStack {
            // Black "outline" pass — slightly thicker, drawn underneath.
            CrosshairLines(arm: Self.armLength)
                .stroke(Color.black.opacity(0.85),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
            RingShape(diameter: Self.ringDiameter)
                .stroke(Color.black.opacity(0.85), style: StrokeStyle(lineWidth: 2.5))

            // White core pass on top.
            CrosshairLines(arm: Self.armLength)
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: 1, lineCap: .round))
            RingShape(diameter: Self.ringDiameter)
                .stroke(Color.white, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 1, x: 0, y: 1)
        .position(x: at.x, y: at.y)
    }
}

/// h+v hairlines centered on `at`, each `arm` pt long (total span = 2×arm).
private struct CrosshairLines: Shape {
    let arm: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: CGPoint(x: c.x - arm, y: c.y))
        p.addLine(to: CGPoint(x: c.x + arm, y: c.y))
        p.move(to: CGPoint(x: c.x, y: c.y - arm))
        p.addLine(to: CGPoint(x: c.x, y: c.y + arm))
        return p
    }
}

private struct RingShape: Shape {
    let diameter: CGFloat

    func path(in rect: CGRect) -> Path {
        let size = CGSize(width: diameter, height: diameter)
        let origin = CGPoint(x: rect.midX - diameter / 2,
                             y: rect.midY - diameter / 2)
        return Path(ellipseIn: CGRect(origin: origin, size: size))
    }
}

// MARK: - Crosshair

/// Full-canvas horizontal + vertical hairlines intersecting at `at`.
private struct CrosshairShape: Shape {
    let at: CGPoint
    let canvas: CGSize

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: at.y))
        p.addLine(to: CGPoint(x: rect.width, y: at.y))
        p.move(to: CGPoint(x: at.x, y: 0))
        p.addLine(to: CGPoint(x: at.x, y: rect.height))
        return p
    }
}

// MARK: - Checkerboard

/// Light checkerboard (8pt squares) to reveal transparent regions of the cursor.
struct CheckerboardBackground: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            for r in 0..<rows {
                for c in 0..<cols {
                    if (r + c).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: CGFloat(c) * square, y: CGFloat(r) * square,
                                        width: square, height: square)),
                            with: .color(.primary.opacity(0.06))
                        )
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Preview

#Preview("Hotspot Zoom Inspector") {
    HotspotZoomInspectorView(cursor: Cursor(identifier: "com.apple.coregraphics.Arrow"))
        .frame(width: 420)
        .padding()
}

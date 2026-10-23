import CoreGraphics
import Testing
@testable import Snappy

@Suite struct PinGeometryTests {
    // MARK: - Scroll delta → factor

    @Test func positiveDeltaZoomsIn() {
        #expect(PinGeometry.zoomFactor(forScrollDeltaY: 10) > 1)
    }

    @Test func negativeDeltaZoomsOut() {
        #expect(PinGeometry.zoomFactor(forScrollDeltaY: -10) < 1)
    }

    @Test func factorIsClampedPerEvent() {
        #expect(PinGeometry.zoomFactor(forScrollDeltaY: 10_000) == 2)
        #expect(PinGeometry.zoomFactor(forScrollDeltaY: -10_000) == 0.5)
    }

    // MARK: - Zoomed frame

    private let frame = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func zoomKeepsAspectRatio() {
        let zoomed = PinGeometry.zoomedFrame(
            frame, factor: 1.5, anchor: CGPoint(x: 150, y: 150),
            minWidth: 10, maxWidth: 10_000
        )
        #expect(zoomed.width == 300)
        #expect(zoomed.height == 150)
        #expect(zoomed.width / zoomed.height == frame.width / frame.height)
    }

    @Test func anchorPointStaysFixed() {
        // Anchor at the frame's center: the center must not move.
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let zoomed = PinGeometry.zoomedFrame(
            frame, factor: 2, anchor: center,
            minWidth: 10, maxWidth: 10_000
        )
        #expect(zoomed.midX == center.x)
        #expect(zoomed.midY == center.y)

        // Anchor at the bottom-left corner: that corner must not move.
        let corner = frame.origin
        let cornerZoomed = PinGeometry.zoomedFrame(
            frame, factor: 2, anchor: corner,
            minWidth: 10, maxWidth: 10_000
        )
        #expect(cornerZoomed.origin == corner)
    }

    @Test func zoomRespectsMaxWidth() {
        let zoomed = PinGeometry.zoomedFrame(
            frame, factor: 10, anchor: CGPoint(x: 150, y: 150),
            minWidth: 10, maxWidth: 400
        )
        #expect(zoomed.width == 400)
        #expect(zoomed.height == 200) // aspect kept even when clamped
    }

    @Test func zoomRespectsMinWidth() {
        let zoomed = PinGeometry.zoomedFrame(
            frame, factor: 0.01, anchor: CGPoint(x: 150, y: 150),
            minWidth: 80, maxWidth: 10_000
        )
        #expect(zoomed.width == 80)
        #expect(zoomed.height == 40)
    }

    // MARK: - Corner resize

    @Test func cornerResizeKeepsTopLeftAndAspect() {
        // frame: x 100…300, y 100…200 (top-left = (100, 200)), aspect 2.
        let resized = PinGeometry.cornerResizedFrame(
            frame, bottomRight: CGPoint(x: 500, y: 0),
            aspectRatio: 2, minWidth: 10, maxWidth: 10_000
        )
        #expect(resized.width == 400)
        #expect(resized.height == 200)
        #expect(resized.minX == frame.minX)
        #expect(resized.maxY == frame.maxY)
    }

    @Test func cornerResizeClampsWidth() {
        let tooSmall = PinGeometry.cornerResizedFrame(
            frame, bottomRight: CGPoint(x: 101, y: 150),
            aspectRatio: 2, minWidth: 80, maxWidth: 10_000
        )
        #expect(tooSmall.width == 80)

        let tooBig = PinGeometry.cornerResizedFrame(
            frame, bottomRight: CGPoint(x: 99_999, y: 150),
            aspectRatio: 2, minWidth: 80, maxWidth: 600
        )
        #expect(tooBig.width == 600)
    }
}

@Suite struct PinChromeGeometryTests {
    // MARK: - Resize corner

    private let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)

    @Test func bottomRightCornerResizes() {
        #expect(PinGeometry.isInResizeCorner(CGPoint(x: 199, y: 1), bounds: bounds, cornerSize: 16))
        #expect(PinGeometry.isInResizeCorner(CGPoint(x: 184, y: 16), bounds: bounds, cornerSize: 16))
    }

    @Test func doubleClickInTheResizeCornerResizesNotCloses() {
        #expect(PinGeometry.mouseDownAction(clickCount: 2, inResizeCorner: true) == .resize)
        #expect(PinGeometry.mouseDownAction(clickCount: 1, inResizeCorner: true) == .resize)
        #expect(PinGeometry.mouseDownAction(clickCount: 3, inResizeCorner: true) == .resize)
    }

    @Test func doubleClickElsewhereClosesSingleClickDrags() {
        #expect(PinGeometry.mouseDownAction(clickCount: 2, inResizeCorner: false) == .close)
        #expect(PinGeometry.mouseDownAction(clickCount: 1, inResizeCorner: false) == .drag)
        #expect(PinGeometry.mouseDownAction(clickCount: 3, inResizeCorner: false) == .drag)
    }

    @Test func outsideCornerDoesNotResize() {
        #expect(!PinGeometry.isInResizeCorner(CGPoint(x: 183, y: 1), bounds: bounds, cornerSize: 16))
        #expect(!PinGeometry.isInResizeCorner(CGPoint(x: 199, y: 17), bounds: bounds, cornerSize: 16))
        // Top-right is not the corner (non-flipped view: origin bottom-left).
        #expect(!PinGeometry.isInResizeCorner(CGPoint(x: 199, y: 99), bounds: bounds, cornerSize: 16))
    }

    @Test func pointsOutsideThePinAreNeverInTheCorner() {
        #expect(!PinGeometry.isInResizeCorner(CGPoint(x: 250, y: -50), bounds: bounds, cornerSize: 16))
        #expect(!PinGeometry.isInResizeCorner(CGPoint(x: 201, y: 5), bounds: bounds, cornerSize: 16))
        #expect(!PinGeometry.isInResizeCorner(CGPoint(x: 195, y: -1), bounds: bounds, cornerSize: 16))
    }

    @Test func cornerFollowsNonZeroBoundsOrigin() {
        let shifted = CGRect(x: 50, y: 20, width: 200, height: 100)
        #expect(PinGeometry.isInResizeCorner(CGPoint(x: 245, y: 25), bounds: shifted, cornerSize: 16))
        #expect(!PinGeometry.isInResizeCorner(CGPoint(x: 199, y: 1), bounds: shifted, cornerSize: 16))
    }

    // MARK: - Toolbar fit

    private let toolbar = CGSize(width: 100, height: 36)

    @Test func toolbarFitsWithInsetOnEverySide() {
        #expect(PinGeometry.toolbarFits(pinSize: CGSize(width: 116, height: 52), toolbarSize: toolbar, inset: 8))
    }

    @Test func narrowPinHidesToolbar() {
        #expect(!PinGeometry.toolbarFits(pinSize: CGSize(width: 115, height: 400), toolbarSize: toolbar, inset: 8))
    }

    @Test func shortPinHidesToolbarInsteadOfClippingIt() {
        // A one-line text capture: wide but shorter than toolbar + insets.
        #expect(!PinGeometry.toolbarFits(pinSize: CGSize(width: 600, height: 51), toolbarSize: toolbar, inset: 8))
    }
}

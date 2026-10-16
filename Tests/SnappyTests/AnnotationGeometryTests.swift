import CoreGraphics
import Testing
@testable import Snappy

@Suite struct AnnotationGeometryTests {
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

    // MARK: - Canvas fitting & conversion

    @Test func fittedFrameCentersAndPreservesAspect() {
        let frame = AnnotationGeometry.fittedFrame(
            imageSize: CGSize(width: 200, height: 100),
            in: CGRect(x: 0, y: 0, width: 400, height: 400)
        )
        #expect(frame == CGRect(x: 0, y: 100, width: 400, height: 200))
    }

    @Test func fittedFrameRespectsMargin() {
        let frame = AnnotationGeometry.fittedFrame(
            imageSize: CGSize(width: 100, height: 100),
            in: CGRect(x: 0, y: 0, width: 120, height: 120),
            margin: 10
        )
        #expect(frame == CGRect(x: 10, y: 10, width: 100, height: 100))
    }

    // MARK: - Tahoe Glass fit area

    @Test func fitAreaUsesUnobscuredRectMinusStatusBand() {
        // 800×600 canvas; the glass toolbar hides the top 52 pt.
        let area = AnnotationGeometry.fitArea(
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            unobscured: CGRect(x: 0, y: 0, width: 800, height: 548),
            bottomInset: 44
        )
        #expect(area == CGRect(x: 0, y: 44, width: 800, height: 504))
    }

    @Test func fitAreaWithoutWindowIsWholeBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(AnnotationGeometry.fitArea(bounds: bounds, unobscured: nil, bottomInset: 0) == bounds)
    }

    @Test func fitAreaClampsToBoundsAndNeverGoesNegative() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        // Unobscured rect reaching past the view is clipped to it.
        let clipped = AnnotationGeometry.fitArea(
            bounds: bounds, unobscured: CGRect(x: -10, y: -10, width: 500, height: 500), bottomInset: 0
        )
        #expect(clipped == bounds)
        // A band taller than the area leaves an empty (not negative) area.
        let squashed = AnnotationGeometry.fitArea(bounds: bounds, unobscured: nil, bottomInset: 1000)
        #expect(squashed.height == 0)
        // Disjoint rect (window not laid out yet) falls back to the bounds.
        let disjoint = AnnotationGeometry.fitArea(
            bounds: bounds, unobscured: CGRect(x: 900, y: 900, width: 10, height: 10), bottomInset: 0
        )
        #expect(disjoint == bounds)
    }

    @Test func viewImageConversionRoundTrips() {
        // Image 800×400 shown in a 400×200 frame at (50, 100) → scale 0.5.
        let imageSize = CGSize(width: 800, height: 400)
        let fitted = CGRect(x: 50, y: 100, width: 400, height: 200)

        let imagePoint = AnnotationGeometry.imagePoint(
            fromViewPoint: CGPoint(x: 250, y: 200), imageSize: imageSize, fittedFrame: fitted
        )
        #expect(imagePoint == CGPoint(x: 400, y: 200))

        let viewRect = AnnotationGeometry.viewRect(
            fromImageRect: CGRect(x: 400, y: 200, width: 100, height: 100),
            imageSize: imageSize,
            fittedFrame: fitted
        )
        #expect(viewRect == CGRect(x: 250, y: 200, width: 50, height: 50))

        #expect(AnnotationGeometry.imageLength(
            fromViewLength: 5, imageSize: imageSize, fittedFrame: fitted
        ) == 10)
    }

    // MARK: - Canvas-rect (M-F) conversions with negative origin

    @Test func contentRectConversionHandlesNegativeOrigin() {
        // Canvas rect spilling below/left of the image: origin (-100, -50),
        // 800×400, shown 1:1 at view (0, 0).
        let content = CGRect(x: -100, y: -50, width: 800, height: 400)
        let fitted = CGRect(x: 0, y: 0, width: 800, height: 400)

        // Image origin (0, 0) sits 100 pt right and 50 pt up in the view.
        #expect(AnnotationGeometry.viewPoint(
            fromImagePoint: .zero, contentRect: content, fittedFrame: fitted
        ) == CGPoint(x: 100, y: 50))

        // And back.
        #expect(AnnotationGeometry.imagePoint(
            fromViewPoint: CGPoint(x: 100, y: 50), contentRect: content, fittedFrame: fitted
        ) == .zero)

        // A negative-origin annotation rect maps into positive view space.
        #expect(AnnotationGeometry.viewRect(
            fromImageRect: CGRect(x: -100, y: -50, width: 50, height: 25),
            contentRect: content, fittedFrame: fitted
        ) == CGRect(x: 0, y: 0, width: 50, height: 25))
    }

    @Test func contentRectConversionScalesWhenDownfitted() {
        // 800×400 canvas shown in a 400×200 frame at (50, 100) → scale 0.5.
        let content = CGRect(x: -400, y: -200, width: 800, height: 400)
        let fitted = CGRect(x: 50, y: 100, width: 400, height: 200)
        // Canvas center (image point (0, 0)) → frame center (250, 200).
        #expect(AnnotationGeometry.viewPoint(
            fromImagePoint: .zero, contentRect: content, fittedFrame: fitted
        ) == CGPoint(x: 250, y: 200))
        #expect(AnnotationGeometry.imageLength(
            fromViewLength: 5, contentRect: content, fittedFrame: fitted
        ) == 10)
    }

    @Test func imageSizeWrappersMatchZeroOriginContentRect() {
        // The pre-M-F imageSize wrappers must equal a zero-origin content rect.
        let size = CGSize(width: 200, height: 100)
        let fitted = CGRect(x: 10, y: 20, width: 400, height: 200)
        let p = CGPoint(x: 110, y: 70)
        #expect(
            AnnotationGeometry.imagePoint(fromViewPoint: p, imageSize: size, fittedFrame: fitted)
            == AnnotationGeometry.imagePoint(
                fromViewPoint: p, contentRect: CGRect(origin: .zero, size: size), fittedFrame: fitted
            )
        )
    }

    // MARK: - Rectangle hit-testing

    @Test func rectangleInteriorHits() {
        #expect(AnnotationGeometry.shapeHit(
            at: CGPoint(x: 200, y: 150), kind: .rectangle, rect: rect, tolerance: 4
        ) == .inside)
    }

    @Test func rectangleEdgeHitsWithinTolerance() {
        // Exactly on the left edge, and just outside it.
        #expect(AnnotationGeometry.shapeHit(
            at: CGPoint(x: 100, y: 150), kind: .rectangle, rect: rect, tolerance: 4
        ) == .edge)
        #expect(AnnotationGeometry.shapeHit(
            at: CGPoint(x: 97, y: 150), kind: .rectangle, rect: rect, tolerance: 4
        ) == .edge)
    }

    @Test func rectangleOutsideMisses() {
        #expect(AnnotationGeometry.shapeHit(
            at: CGPoint(x: 90, y: 90), kind: .rectangle, rect: rect, tolerance: 4
        ) == nil)
    }

    // MARK: - Oval hit-testing

    @Test func ovalCenterHitsInside() {
        #expect(AnnotationGeometry.shapeHit(
            at: CGPoint(x: 200, y: 150), kind: .oval, rect: rect, tolerance: 4
        ) == .inside)
    }

    @Test func ovalBoundaryHitsEdge() {
        // Leftmost point of the ellipse: (minX, midY).
        #expect(AnnotationGeometry.shapeHit(
            at: CGPoint(x: 100, y: 150), kind: .oval, rect: rect, tolerance: 4
        ) == .edge)
    }

    @Test func ovalBoundingCornerMisses() {
        // Inside the bounding rect but outside the ellipse.
        #expect(AnnotationGeometry.shapeHit(
            at: CGPoint(x: 102, y: 102), kind: .oval, rect: rect, tolerance: 4
        ) == nil)
    }

    // MARK: - Rectangle corner radius

    @Test func rectangleCornerRadiusIsProportionalButClamped() {
        // 2 × strokeWidth for comfortable rects…
        #expect(AnnotationGeometry.rectangleCornerRadius(
            rect: CGRect(x: 0, y: 0, width: 100, height: 100), strokeWidth: 3
        ) == 6)
        // …clamped to a quarter of the smaller side for small ones.
        #expect(AnnotationGeometry.rectangleCornerRadius(
            rect: CGRect(x: 0, y: 0, width: 8, height: 100), strokeWidth: 3
        ) == 2)
    }

    // MARK: - Resize handles

    @Test func handlePointsSitOnTheRect() {
        #expect(AnnotationGeometry.handlePoint(.minXminY, in: rect) == CGPoint(x: 100, y: 100))
        #expect(AnnotationGeometry.handlePoint(.midXminY, in: rect) == CGPoint(x: 200, y: 100))
        #expect(AnnotationGeometry.handlePoint(.maxXmidY, in: rect) == CGPoint(x: 300, y: 150))
        #expect(AnnotationGeometry.handlePoint(.maxXmaxY, in: rect) == CGPoint(x: 300, y: 200))
    }

    @Test func handleHitFindsNearestWithinRadius() {
        #expect(AnnotationGeometry.handleHit(
            at: CGPoint(x: 297, y: 203), rect: rect, radius: 7
        ) == .maxXmaxY)
        // The rect's center is far from every handle.
        #expect(AnnotationGeometry.handleHit(
            at: CGPoint(x: 200, y: 150), rect: rect, radius: 7
        ) == nil)
    }

    @Test func resizeCornerMovesOnlyItsEdges() {
        let resized = AnnotationGeometry.resized(
            rect, dragging: .maxXmaxY, by: CGVector(dx: 10, dy: 20)
        )
        #expect(resized == CGRect(x: 100, y: 100, width: 210, height: 120))
    }

    @Test func resizeEdgeHandleIgnoresOtherAxis() {
        let resized = AnnotationGeometry.resized(
            rect, dragging: .minXmidY, by: CGVector(dx: 10, dy: 55)
        )
        #expect(resized == CGRect(x: 110, y: 100, width: 190, height: 100))
    }

    @Test func resizeAcrossOppositeEdgeFlipsAndNormalizes() {
        // Drag the max-corner past the min-corner: rect flips, stays positive.
        let resized = AnnotationGeometry.resized(
            rect, dragging: .maxXmaxY, by: CGVector(dx: -250, dy: -50)
        )
        #expect(resized == CGRect(x: 50, y: 100, width: 50, height: 50))
    }

    // MARK: - Move clamping

    @Test func movedRectClampsToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let moved = AnnotationGeometry.movedRect(
            rect, by: CGVector(dx: 1000, dy: -1000), within: bounds
        )
        #expect(moved == CGRect(x: 300, y: 0, width: 200, height: 100))

        let unclamped = AnnotationGeometry.movedRect(
            rect, by: CGVector(dx: 50, dy: 50), within: bounds
        )
        #expect(unclamped == CGRect(x: 150, y: 150, width: 200, height: 100))
    }

    /// Review #1: an 18×18 pt selection is all handle at a 10 pt radius;
    /// the body must still win outside the 7 pt core.
    @Test func handleArbitrationKeepsTheBodyOfSmallSelections() {
        let rect = CGRect(x: 0, y: 0, width: 18, height: 18)
        let center = CGPoint(x: 9, y: 9)
        let core = AnnotationGeometry.handleHit(at: center, rect: rect, radius: 7)
        let full = AnnotationGeometry.handleHit(at: center, rect: rect, radius: 10)
        #expect(core == nil)
        #expect(full != nil) // the regression the reviewer measured
        #expect(AnnotationGeometry.arbitrateHandle(core: core, full: full, pointIsOnABody: true) == nil)
        // Off any body, the full 20 pt target applies.
        let outside = CGPoint(x: -8, y: 9) // 8 pt left of the left-edge handle
        #expect(AnnotationGeometry.arbitrateHandle(
            core: AnnotationGeometry.handleHit(at: outside, rect: rect, radius: 7),
            full: AnnotationGeometry.handleHit(at: outside, rect: rect, radius: 10),
            pointIsOnABody: false
        ) == .minXmidY)
        // The core always wins, body or not.
        #expect(AnnotationGeometry.arbitrateHandle(
            core: AnnotationGeometry.ResizeHandle.maxXmaxY, full: .maxXmaxY, pointIsOnABody: true
        ) == .maxXmaxY)
    }
}


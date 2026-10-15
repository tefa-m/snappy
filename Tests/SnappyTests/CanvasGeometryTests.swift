import CoreGraphics
import Testing
@testable import Snappy

@Suite struct CanvasGeometryTests {
    private let image = CGRect(x: 0, y: 0, width: 100, height: 80)

    @Test func noAnnotationsKeepsImageBounds() {
        #expect(CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [], padding: 16) == image)
    }

    @Test func interiorAnnotationDoesNotGrowTheCanvas() {
        let inside = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [inside], padding: 16) == image)
    }

    @Test func overflowRightExtendsOnlyThatSide() {
        // Spills 10 px past maxX (100) → right edge = 110 + padding; every other
        // side stays flush with the image.
        let over = CGRect(x: 90, y: 20, width: 20, height: 20) // maxX = 110
        let rect = CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [over], padding: 8)
        #expect(rect == CGRect(x: 0, y: 0, width: 118, height: 80))
    }

    @Test func overflowLeftGivesNegativeOrigin() {
        // minX = -10 → left edge = -10 - padding; width grows to keep maxX = 100.
        let over = CGRect(x: -10, y: 20, width: 20, height: 20)
        let rect = CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [over], padding: 6)
        #expect(rect == CGRect(x: -16, y: 0, width: 116, height: 80))
    }

    @Test func overflowBelowGivesNegativeOriginY() {
        let over = CGRect(x: 20, y: -20, width: 10, height: 10) // minY = -20
        let rect = CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [over], padding: 5)
        #expect(rect == CGRect(x: 0, y: -25, width: 100, height: 105))
    }

    @Test func cornerOverflowExtendsTwoSides() {
        // Past both maxX and maxY.
        let over = CGRect(x: 95, y: 75, width: 20, height: 20) // maxX 115, maxY 95
        let rect = CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [over], padding: 10)
        #expect(rect == CGRect(x: 0, y: 0, width: 125, height: 105))
    }

    @Test func unionOfMultipleAnnotationsDrivesEachSide() {
        let a = CGRect(x: -5, y: 20, width: 10, height: 10) // minX -5
        let b = CGRect(x: 90, y: 90, width: 30, height: 30) // maxX 120, maxY 120
        let rect = CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [a, b], padding: 4)
        // left = -5-4 = -9; right = 120+4 = 124; top = 120+4 = 124; bottom flush 0.
        #expect(rect == CGRect(x: -9, y: 0, width: 133, height: 124))
    }

    @Test func zeroPaddingHugsTheAnnotation() {
        let over = CGRect(x: 90, y: 20, width: 20, height: 20) // maxX 110
        let rect = CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [over], padding: 0)
        #expect(rect == CGRect(x: 0, y: 0, width: 110, height: 80))
    }

    @Test func nonIntegralOverflowRoundsOutward() {
        let over = CGRect(x: 100.4, y: 20, width: 5, height: 5) // maxX 105.4
        let rect = CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [over], padding: 2.3)
        // maxX = 105.4 + 2.3 = 107.7 → ceil to 108.
        #expect(rect == CGRect(x: 0, y: 0, width: 108, height: 80))
    }

    @Test func growthIsClampedPerSide() {
        // 100×80 image → cap is max(100, 80, 4096) = 4096 px past each edge.
        let far = CGRect(x: 100_000, y: -100_000, width: 10, height: 10)
        let rect = CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [far], padding: 16)
        #expect(rect == CGRect(x: 0, y: -4096, width: 100 + 4096, height: 80 + 4096))
    }

    @Test func clampScalesWithLargeImages() {
        let big = CGRect(x: 0, y: 0, width: 8000, height: 6000)
        let far = CGRect(x: -1_000_000, y: 0, width: 10, height: 10)
        let rect = CanvasGeometry.canvasRect(imageBounds: big, annotationRects: [far], padding: 0)
        #expect(rect.minX == -8000) // longer side
        #expect(rect.maxX == 8000)
    }

    @Test func growthWithinTheCapIsUnchanged() {
        let over = CGRect(x: 90, y: 20, width: 20, height: 20)
        let rect = CanvasGeometry.canvasRect(imageBounds: image, annotationRects: [over], padding: 8)
        #expect(rect == CGRect(x: 0, y: 0, width: 118, height: 80))
    }
}

import CoreGraphics
import Testing
@testable import Snappy

@Suite struct CaptureGeometryTests {
    // MARK: - Selection rect normalization

    @Test func dragInAllFourDirectionsYieldsSameRect() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        let a = CGPoint(x: 10, y: 20)
        let b = CGPoint(x: 40, y: 60)

        #expect(CaptureGeometry.normalizedRect(from: a, to: b) == expected)
        #expect(CaptureGeometry.normalizedRect(from: b, to: a) == expected)
        #expect(CaptureGeometry.normalizedRect(from: CGPoint(x: 40, y: 20), to: CGPoint(x: 10, y: 60)) == expected)
        #expect(CaptureGeometry.normalizedRect(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 40, y: 20)) == expected)
    }

    @Test func zeroDragYieldsEmptyRect() {
        let p = CGPoint(x: 5, y: 5)
        let rect = CaptureGeometry.normalizedRect(from: p, to: p)
        #expect(rect.isEmpty)
    }

    // MARK: - Clamping

    @Test func pointInsideBoundsIsUnchanged() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let p = CGPoint(x: 50, y: 50)
        #expect(CaptureGeometry.clamp(p, to: bounds) == p)
    }

    @Test func pointOutsideBoundsIsClampedToEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(CaptureGeometry.clamp(CGPoint(x: -10, y: 150), to: bounds) == CGPoint(x: 0, y: 100))
        #expect(CaptureGeometry.clamp(CGPoint(x: 120, y: -5), to: bounds) == CGPoint(x: 100, y: 0))
    }

    @Test func rectPartiallyOutsideBoundsIsClamped() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = CGRect(x: 80, y: 80, width: 50, height: 50)
        #expect(CaptureGeometry.clamp(rect, to: bounds) == CGRect(x: 80, y: 80, width: 20, height: 20))
    }

    // MARK: - Points → pixels

    @Test func pixelSizeAt1x() {
        let size = CaptureGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 300, height: 200), scale: 1)
        #expect(size == CGSize(width: 300, height: 200))
    }

    @Test func pixelSizeAt2x() {
        let size = CaptureGeometry.pixelSize(of: CGRect(x: 7, y: 9, width: 300, height: 200), scale: 2)
        #expect(size == CGSize(width: 600, height: 400))
    }

    // MARK: - AppKit global → display-local (sourceRect)

    @Test func displayLocalRectOnPrimaryDisplay() {
        // Primary display 1000×800: AppKit rect 100pt from the left, top edge
        // 100pt below the top → local top-left y = 100.
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 100, y: 500, width: 300, height: 200)
        let local = CaptureGeometry.displayLocalRect(fromAppKitGlobal: selection, screenFrame: screen)
        #expect(local == CGRect(x: 100, y: 100, width: 300, height: 200))
    }

    @Test func displayLocalRectOnSecondaryDisplayToTheLeft() {
        // Secondary display sits left of the primary in AppKit space.
        let screen = CGRect(x: -1200, y: 0, width: 1200, height: 900)
        let selection = CGRect(x: -1100, y: 100, width: 200, height: 300)
        let local = CaptureGeometry.displayLocalRect(fromAppKitGlobal: selection, screenFrame: screen)
        #expect(local == CGRect(x: 100, y: 500, width: 200, height: 300))
    }

    @Test func fullScreenSelectionMapsToDisplayOrigin() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let local = CaptureGeometry.displayLocalRect(fromAppKitGlobal: screen, screenFrame: screen)
        #expect(local == CGRect(x: 0, y: 0, width: 1000, height: 800))
    }

    // MARK: - AppKit ↔ CoreGraphics global flips

    @Test func cgPointFlip() {
        // Primary display height 800: AppKit y=0 (bottom) is CG y=800.
        #expect(CaptureGeometry.cgPoint(fromAppKitGlobal: CGPoint(x: 10, y: 0), primaryDisplayHeight: 800) == CGPoint(x: 10, y: 800))
        #expect(CaptureGeometry.cgPoint(fromAppKitGlobal: CGPoint(x: 10, y: 800), primaryDisplayHeight: 800) == CGPoint(x: 10, y: 0))
    }

    @Test func appKitRectFlipRoundTripsWithCGPoint() {
        let primaryHeight: CGFloat = 800
        // A CG-global window frame 50pt below the top of the primary display.
        let cgFrame = CGRect(x: 20, y: 50, width: 400, height: 300)
        let appKit = CaptureGeometry.appKitRect(fromCGGlobal: cgFrame, primaryDisplayHeight: primaryHeight)
        #expect(appKit == CGRect(x: 20, y: 450, width: 400, height: 300))

        // The AppKit rect's top-left corner flips back onto the CG origin corner.
        let topLeft = CGPoint(x: appKit.minX, y: appKit.maxY)
        #expect(CaptureGeometry.cgPoint(fromAppKitGlobal: topLeft, primaryDisplayHeight: primaryHeight) == cgFrame.origin)
    }

    // MARK: - Frozen snapshot crop rects

    private static let screen1x = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func cropRectAtScale1MatchesTheDisplayLocalRect() {
        let selection = CGRect(x: 100, y: 500, width: 200, height: 100)
        let pixels = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: selection,
            screenFrame: Self.screen1x,
            scale: 1,
            imagePixelSize: CGSize(width: 1000, height: 800)
        )
        let local = CaptureGeometry.displayLocalRect(fromAppKitGlobal: selection, screenFrame: Self.screen1x)
        #expect(pixels == local)
    }

    @Test func cropRectAtScale2ScalesFromTheImageTopLeft() {
        // AppKit y 500…700 measured from the bottom is 100…300 from the top.
        let selection = CGRect(x: 100, y: 500, width: 300, height: 200)
        let pixels = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: selection,
            screenFrame: Self.screen1x,
            scale: 2,
            imagePixelSize: CGSize(width: 2000, height: 1600)
        )
        #expect(pixels == CGRect(x: 200, y: 200, width: 600, height: 400))
    }

    @Test func cropRectOnASecondaryDisplayToTheLeftOfThePrimary() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: -1400, y: 800, width: 200, height: 50)
        let pixels = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: selection,
            screenFrame: screen,
            scale: 2,
            imagePixelSize: CGSize(width: 2880, height: 1800)
        )
        // 40 pt from the display's left edge, 50 pt down from its top.
        #expect(pixels == CGRect(x: 80, y: 100, width: 400, height: 100))
    }

    @Test func fullScreenSelectionCoversTheWholeSnapshot() {
        let size = CGSize(width: 2000, height: 1600)
        let pixels = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: Self.screen1x,
            screenFrame: Self.screen1x,
            scale: 2,
            imagePixelSize: size
        )
        #expect(pixels == CGRect(origin: .zero, size: size))
    }

    @Test func cropRectClampsAnOvershootAtTheScreenEdge() {
        // A drag that spills one point past the right and bottom edges must not
        // produce a rect CGImage.cropping would reject.
        let selection = CGRect(x: 990, y: -1, width: 11, height: 20)
        let size = CGSize(width: 2000, height: 1600)
        let pixels = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: selection,
            screenFrame: Self.screen1x,
            scale: 2,
            imagePixelSize: size
        )
        #expect(CGRect(origin: .zero, size: size).contains(pixels))
        #expect(!pixels.isEmpty)
        #expect(pixels.maxX == size.width)
        #expect(pixels.maxY == size.height)
    }

    @Test func cropRectForASelectionOffThisScreenIsEmpty() {
        let selection = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        let pixels = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: selection,
            screenFrame: Self.screen1x,
            scale: 2,
            imagePixelSize: CGSize(width: 2000, height: 1600)
        )
        #expect(pixels.isEmpty)
    }

    @Test func cropRectRoundsFractionalPointsToWholePixels() {
        let selection = CGRect(x: 10.4, y: 20.6, width: 30.2, height: 40.9)
        let pixels = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: selection,
            screenFrame: Self.screen1x,
            scale: 2,
            imagePixelSize: CGSize(width: 2000, height: 1600)
        )
        #expect(pixels == pixels.integral)
    }

    @Test func adjacentSelectionsTileWithoutOverlapOrGap() {
        // Independently rounded edges: the shared boundary lands on one pixel.
        let size = CGSize(width: 2000, height: 1600)
        let left = CGRect(x: 10, y: 100, width: 40.5, height: 50)
        let right = CGRect(x: 50.5, y: 100, width: 40, height: 50)
        let a = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: left, screenFrame: Self.screen1x, scale: 2, imagePixelSize: size
        )
        let b = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: right, screenFrame: Self.screen1x, scale: 2, imagePixelSize: size
        )
        #expect(a.maxX == b.minX)
    }

    // MARK: - Derived snapshot scale

    @Test func derivedScaleMatchesBackingScaleForAnExactRetinaSnapshot() {
        let scale = CaptureGeometry.derivedScale(
            imagePixelSize: CGSize(width: 3024, height: 1964),
            displayPointSize: CGSize(width: 1512, height: 982)
        )
        #expect(scale == 2)
    }

    @Test func derivedScaleIsOneForANonRetinaDisplay() {
        let scale = CaptureGeometry.derivedScale(
            imagePixelSize: CGSize(width: 1920, height: 1080),
            displayPointSize: CGSize(width: 1920, height: 1080)
        )
        #expect(scale == 1)
    }

    @Test func derivedScaleFollowsTheImageNotTheAssumedBackingScale() {
        // A scaled retina mode where SCK's rounding lands off a clean 1.5.
        let scale = CaptureGeometry.derivedScale(
            imagePixelSize: CGSize(width: 2057, height: 1329),
            displayPointSize: CGSize(width: 1370, height: 886)
        )
        #expect(scale != 1.5)
        #expect(abs(scale - 1.5015) < 0.001)
    }

    @Test func derivedScaleOfADegenerateDisplayIsOne() {
        let scale = CaptureGeometry.derivedScale(
            imagePixelSize: CGSize(width: 100, height: 100),
            displayPointSize: .zero
        )
        #expect(scale == 1)
    }

    @Test func aFullScreenSelectionMapsToTheWholeSnapshotAtADerivedScale() {
        // The reason scale is derived: this must hold even when the image is a
        // rounding step away from points × backingScaleFactor.
        let frame = CGRect(x: 0, y: 0, width: 1370, height: 886)
        let pixels = CGSize(width: 2057, height: 1329)
        let scale = CaptureGeometry.derivedScale(imagePixelSize: pixels, displayPointSize: frame.size)
        let rect = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: frame,
            screenFrame: frame,
            scale: scale,
            imagePixelSize: pixels
        )
        #expect(rect == CGRect(origin: .zero, size: pixels))
    }

    // MARK: - Captured selection (what the overlay draws)

    @Test func capturedSelectionMatchesTheCropOnASecondaryDisplay() {
        // The overlay draws in its own space; the crop maps the same rect
        // through AppKit global coordinates. Both must name the same pixels.
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 2880, height: 1800)
        let overlayRect = CGRect(x: 40.3, y: 50.7, width: 200.4, height: 99.6)
        let captured = CaptureGeometry.capturedSelection(
            overlayRect: overlayRect, screenFrame: screen, scale: 2, imagePixelSize: size
        )
        let crop = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: overlayRect.offsetBy(dx: screen.minX, dy: screen.minY),
            screenFrame: screen, scale: 2, imagePixelSize: size
        )
        #expect(captured.pixels == crop)
    }

    @Test func capturedSelectionSnapsTheDrawnRectToSnapshotPixels() {
        let size = CGSize(width: 2000, height: 1600)
        let captured = CaptureGeometry.capturedSelection(
            overlayRect: CGRect(x: 10.3, y: 20.6, width: 30.2, height: 40.9),
            screenFrame: Self.screen1x, scale: 2, imagePixelSize: size
        )
        // Every edge lands on a half-point (= one pixel at 2×) …
        for edge in [captured.overlayRect.minX, captured.overlayRect.minY, captured.overlayRect.maxX, captured.overlayRect.maxY] {
            #expect((edge * 2).rounded() == edge * 2)
        }
        // … and the drawn rect is exactly the crop, back in points.
        #expect(captured.overlayRect.width * 2 == captured.pixels.width)
        #expect(captured.overlayRect.height * 2 == captured.pixels.height)
        #expect(captured.overlayRect.minY == Self.screen1x.height - captured.pixels.maxY / 2)
    }

    @Test func capturedSelectionIsClampedLikeTheCrop() {
        let size = CGSize(width: 2000, height: 1600)
        let captured = CaptureGeometry.capturedSelection(
            overlayRect: CGRect(x: 990, y: -1, width: 11, height: 20),
            screenFrame: Self.screen1x, scale: 2, imagePixelSize: size
        )
        #expect(Self.screen1x.contains(captured.overlayRect))
        #expect(captured.overlayRect.maxX == Self.screen1x.maxX)
        #expect(captured.overlayRect.minY == 0)
    }

    @Test func capturedSelectionOfAClickIsEmpty() {
        // A click without a drag captures nothing, so nothing is drawn.
        let captured = CaptureGeometry.capturedSelection(
            overlayRect: CGRect(x: 100.2, y: 100.2, width: 0, height: 0),
            screenFrame: Self.screen1x, scale: 2, imagePixelSize: CGSize(width: 2000, height: 1600)
        )
        #expect(captured.pixels.isEmpty)
        #expect(captured.overlayRect.isEmpty)
    }
}

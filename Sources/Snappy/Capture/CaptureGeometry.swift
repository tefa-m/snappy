import CoreGraphics

/// Pure coordinate math for capture. Three coordinate systems are in play:
/// - AppKit global: origin at the bottom-left of the primary display, y grows up.
/// - CoreGraphics/ScreenCaptureKit global: origin at the top-left of the primary
///   display, y grows down.
/// - A frozen display snapshot: a full-display `CGImage` whose own space has its
///   origin at the image's top-left, y growing down — the same convention
///   `displayLocalRect(fromAppKitGlobal:screenFrame:)` produces and the one
///   `CGImage.cropping(to:)` expects. There is no second y-flip in the area path.
enum CaptureGeometry {
    /// Rect spanned by two arbitrary drag points (any drag direction).
    static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// Clamps a point into `bounds` (used while dragging beyond the overlay).
    static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// Clamps a rect into `bounds`.
    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        rect.intersection(bounds)
    }

    /// Points → pixels for a display's backing scale.
    static func pixelSize(of rect: CGRect, scale: CGFloat) -> CGSize {
        CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    }

    /// Pixels per point actually delivered by a frozen full-display snapshot.
    /// Derived rather than assumed: ScreenCaptureKit's own rounding can put the
    /// image a step away from `NSScreen.backingScaleFactor`, and it is the image
    /// that the crop and the 1:1 backdrop have to agree with.
    static func derivedScale(imagePixelSize: CGSize, displayPointSize: CGSize) -> CGFloat {
        guard displayPointSize.width > 0 else { return 1 }
        return imagePixelSize.width / displayPointSize.width
    }

    /// AppKit global rect → display-local rect with top-left origin.
    /// `screenFrame` is the display's frame in AppKit global coordinates.
    static func displayLocalRect(fromAppKitGlobal rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// AppKit global point → CoreGraphics global point (y flipped around the
    /// primary display's height).
    static func cgPoint(fromAppKitGlobal point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// CoreGraphics global rect (e.g. `SCWindow.frame`) → AppKit global rect.
    static func appKitRect(fromCGGlobal rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Frozen display snapshots

    /// AppKit global selection rect → pixel rect inside a frozen full-display
    /// snapshot, ready for `CGImage.cropping(to:)`.
    ///
    /// `cropping(to:)` reads its rect in the image's own space — origin at the
    /// image's top-left, y growing down — which is exactly what
    /// `displayLocalRect(fromAppKitGlobal:screenFrame:)` produces, so this is
    /// that conversion × the backing scale and nothing more. The four edges are
    /// rounded independently (adjacent selections tile without seams) and the
    /// result is clamped to the image: a one-pixel overshoot at a screen edge
    /// makes `cropping(to:)` return nil. An empty rect means the selection does
    /// not land on this snapshot at all.
    static func imagePixelRect(
        fromAppKitGlobal rect: CGRect,
        screenFrame: CGRect,
        scale: CGFloat,
        imagePixelSize: CGSize
    ) -> CGRect {
        let local = displayLocalRect(fromAppKitGlobal: rect, screenFrame: screenFrame)
        let minX = (local.minX * scale).rounded()
        let minY = (local.minY * scale).rounded()
        let maxX = (local.maxX * scale).rounded()
        let maxY = (local.maxY * scale).rounded()
        let unclamped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let bounds = CGRect(origin: .zero, size: imagePixelSize)
        let clamped = unclamped.intersection(bounds)
        return clamped.isNull ? .zero : clamped
    }

    /// What an in-progress area selection will capture, for display.
    ///
    /// `overlayRect` is the drag rect in the selection overlay's own space —
    /// points, origin bottom-left; the overlay covers exactly `screenFrame`.
    /// Returns the crop's pixel rect (the very `imagePixelRect` the capture
    /// uses) and those same rounded, clamped edges mapped back into the
    /// overlay. Drawing the second rect instead of the raw drag rect puts the
    /// border on real snapshot-pixel edges: crisp, and exactly where the
    /// capture will end. Both are empty when nothing would be captured.
    static func capturedSelection(
        overlayRect: CGRect,
        screenFrame: CGRect,
        scale: CGFloat,
        imagePixelSize: CGSize
    ) -> (pixels: CGRect, overlayRect: CGRect) {
        let global = overlayRect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        let pixels = imagePixelRect(
            fromAppKitGlobal: global,
            screenFrame: screenFrame,
            scale: scale,
            imagePixelSize: imagePixelSize
        )
        guard scale > 0, !pixels.isEmpty else { return (.zero, .zero) }
        let local = CGRect(
            x: pixels.minX / scale,
            y: screenFrame.height - pixels.maxY / scale,
            width: pixels.width / scale,
            height: pixels.height / scale
        )
        return (pixels, local)
    }
}

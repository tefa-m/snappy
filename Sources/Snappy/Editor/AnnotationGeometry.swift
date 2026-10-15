import CoreGraphics
import Foundation

/// Pure geometry for the annotation editor: aspect-fit canvas math, view↔image
/// conversions, hit-testing, and move/resize math. All coordinates are CG
/// convention (origin bottom-left, y grows up) — the canvas view is unflipped,
/// so no y-flips are needed anywhere. Never inline this math in UI code
/// (see docs/ARCHITECTURE.md).
enum AnnotationGeometry {

    // MARK: - Canvas fitting & view↔image conversion

    /// The part of the canvas view the capture is fitted into (Tahoe Glass):
    /// the canvas runs under the glass toolbar (full-size content view), so
    /// the fit uses only the unobscured `contentLayoutRect` area — already
    /// converted to view space — minus a bottom band for the status capsule.
    /// `nil` (no window yet) means the whole bounds are free. Never negative.
    static func fitArea(bounds: CGRect, unobscured: CGRect?, bottomInset: CGFloat) -> CGRect {
        var area = unobscured.map { $0.intersection(bounds) } ?? bounds
        if area.isNull { area = bounds }
        let inset = min(max(0, bottomInset), area.height)
        area.origin.y += inset
        area.size.height -= inset
        return area
    }

    /// Aspect-fit frame for a content rect inside the canvas bounds, centered.
    /// May upscale small content to fill the available space. Post-MVP M-F: the
    /// "content" is the (possibly image-overflowing, possibly negative-origin)
    /// CANVAS rect — only its SIZE matters for fitting; the origin is consumed
    /// by the point/rect converters below.
    static func fittedFrame(contentRect: CGRect, in bounds: CGRect, margin: CGFloat = 0) -> CGRect {
        let available = bounds.insetBy(dx: margin, dy: margin)
        guard contentRect.width > 0, contentRect.height > 0,
              available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / contentRect.width, available.height / contentRect.height)
        let size = CGSize(width: contentRect.width * scale, height: contentRect.height * scale)
        return CGRect(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func imagePoint(fromViewPoint point: CGPoint, contentRect: CGRect, fittedFrame: CGRect) -> CGPoint {
        guard fittedFrame.width > 0, fittedFrame.height > 0 else { return .zero }
        let scale = contentRect.width / fittedFrame.width
        return CGPoint(
            x: contentRect.minX + (point.x - fittedFrame.minX) * scale,
            y: contentRect.minY + (point.y - fittedFrame.minY) * scale
        )
    }

    static func viewPoint(fromImagePoint point: CGPoint, contentRect: CGRect, fittedFrame: CGRect) -> CGPoint {
        guard contentRect.width > 0 else { return .zero }
        let scale = fittedFrame.width / contentRect.width
        return CGPoint(
            x: fittedFrame.minX + (point.x - contentRect.minX) * scale,
            y: fittedFrame.minY + (point.y - contentRect.minY) * scale
        )
    }

    static func viewRect(fromImageRect rect: CGRect, contentRect: CGRect, fittedFrame: CGRect) -> CGRect {
        guard contentRect.width > 0 else { return .zero }
        let scale = fittedFrame.width / contentRect.width
        return CGRect(
            x: fittedFrame.minX + (rect.minX - contentRect.minX) * scale,
            y: fittedFrame.minY + (rect.minY - contentRect.minY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    /// Converts a length (tolerance, drag delta component) from view points to
    /// image pixels.
    static func imageLength(fromViewLength length: CGFloat, contentRect: CGRect, fittedFrame: CGRect) -> CGFloat {
        guard fittedFrame.width > 0 else { return length }
        return length * contentRect.width / fittedFrame.width
    }

    // Pre-M-F wrappers: the whole content rect is the image at the origin.
    // Existing callers and tests use these; the canvas passes a `contentRect`.

    static func fittedFrame(imageSize: CGSize, in bounds: CGRect, margin: CGFloat = 0) -> CGRect {
        fittedFrame(contentRect: CGRect(origin: .zero, size: imageSize), in: bounds, margin: margin)
    }

    static func imagePoint(fromViewPoint point: CGPoint, imageSize: CGSize, fittedFrame: CGRect) -> CGPoint {
        imagePoint(fromViewPoint: point, contentRect: CGRect(origin: .zero, size: imageSize), fittedFrame: fittedFrame)
    }

    static func viewPoint(fromImagePoint point: CGPoint, imageSize: CGSize, fittedFrame: CGRect) -> CGPoint {
        viewPoint(fromImagePoint: point, contentRect: CGRect(origin: .zero, size: imageSize), fittedFrame: fittedFrame)
    }

    static func viewRect(fromImageRect rect: CGRect, imageSize: CGSize, fittedFrame: CGRect) -> CGRect {
        viewRect(fromImageRect: rect, contentRect: CGRect(origin: .zero, size: imageSize), fittedFrame: fittedFrame)
    }

    static func imageLength(fromViewLength length: CGFloat, imageSize: CGSize, fittedFrame: CGRect) -> CGFloat {
        imageLength(fromViewLength: length, contentRect: CGRect(origin: .zero, size: imageSize), fittedFrame: fittedFrame)
    }

    // MARK: - Resize handles

    /// The eight resize handles, named by the rect edges they move
    /// (min/mid/max X × min/mid/max Y — mid×mid is not a handle).
    enum ResizeHandle: CaseIterable, Sendable {
        case minXminY, minXmidY, minXmaxY
        case midXminY, midXmaxY
        case maxXminY, maxXmidY, maxXmaxY

        var movesMinX: Bool { [.minXminY, .minXmidY, .minXmaxY].contains(self) }
        var movesMaxX: Bool { [.maxXminY, .maxXmidY, .maxXmaxY].contains(self) }
        var movesMinY: Bool { [.minXminY, .midXminY, .maxXminY].contains(self) }
        var movesMaxY: Bool { [.minXmaxY, .midXmaxY, .maxXmaxY].contains(self) }
    }

    static func handlePoint(_ handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        let x: CGFloat = handle.movesMinX ? rect.minX : (handle.movesMaxX ? rect.maxX : rect.midX)
        let y: CGFloat = handle.movesMinY ? rect.minY : (handle.movesMaxY ? rect.maxY : rect.midY)
        return CGPoint(x: x, y: y)
    }

    /// The handle within `radius` of `point`, nearest first; nil if none.
    static func handleHit(at point: CGPoint, rect: CGRect, radius: CGFloat) -> ResizeHandle? {
        var best: (handle: ResizeHandle, distance: CGFloat)?
        for handle in ResizeHandle.allCases {
            let p = handlePoint(handle, in: rect)
            let distance = hypot(point.x - p.x, point.y - p.y)
            if distance <= radius, distance < (best?.distance ?? .infinity) {
                best = (handle, distance)
            }
        }
        return best?.handle
    }

    /// Handle-vs-body arbitration for a selection's handles. `core` is the hit
    /// at the small radius, `full` at the large one. The core always wins; the
    /// outer ring only where the point is not on an annotation body — so a
    /// large handle target never swallows the body of a small selection.
    static func arbitrateHandle<Handle>(core: Handle?, full: Handle?, pointIsOnABody: Bool) -> Handle? {
        core ?? (pointIsOnABody ? nil : full)
    }

    /// Applies a drag delta to the edges a handle controls. The result is
    /// standardized, so dragging a handle across the opposite edge flips the
    /// rect instead of producing negative sizes.
    static func resized(_ rect: CGRect, dragging handle: ResizeHandle, by delta: CGVector) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        if handle.movesMinX { minX += delta.dx }
        if handle.movesMaxX { maxX += delta.dx }
        if handle.movesMinY { minY += delta.dy }
        if handle.movesMaxY { maxY += delta.dy }
        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }

    /// Offsets a rect by a delta, clamped so it stays inside `bounds`.
    static func movedRect(_ rect: CGRect, by delta: CGVector, within bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: rect.minX + delta.dx, y: rect.minY + delta.dy)
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return CGRect(origin: origin, size: rect.size)
    }

    // MARK: - Rectangle corner radius

    /// Slightly rounded corners for rectangle annotations: proportional to the
    /// stroke width, clamped so small rects never turn into capsules.
    static func rectangleCornerRadius(rect: CGRect, strokeWidth: CGFloat) -> CGFloat {
        max(0, min(2 * strokeWidth, min(rect.width, rect.height) / 4))
    }

    // MARK: - Shape hit-testing

    enum ShapeHit: Equatable {
        case edge, inside
    }

    /// Hit-tests a point against a shape's outline and interior. `tolerance`
    /// is the half-width of the "on the edge" band, in the same units as the
    /// rect (image pixels).
    static func shapeHit(at point: CGPoint, kind: ShapeKind, rect: CGRect, tolerance: CGFloat) -> ShapeHit? {
        switch kind {
        case .rectangle:
            guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            if inner.width > 0, inner.height > 0, inner.contains(point) { return .inside }
            return .edge

        case .oval:
            let a = rect.width / 2, b = rect.height / 2
            guard a > 0, b > 0 else { return nil }
            let dx = (point.x - rect.midX) / a
            let dy = (point.y - rect.midY) / b
            let r = sqrt(dx * dx + dy * dy)
            // Distance from the ellipse boundary, approximated in the scale of
            // the smaller semi-axis — exact for circles, close enough for hits.
            let boundaryDistance = abs(r - 1) * min(a, b)
            if boundaryDistance <= tolerance { return .edge }
            return r < 1 ? .inside : nil
        }
    }
}

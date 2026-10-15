import CoreGraphics
import Foundation

/// Pure geometry for the auto-expanding canvas (Post-MVP M-F): given the base
/// image bounds and the (already stroke-inflated) bounds of every annotation,
/// derive the canvas rect that fully contains them, expanding only the sides
/// that actually overflow and adding padding beyond those sides.
///
/// The canvas rect is FULLY DERIVED — there is no stored canvas state and
/// nothing about it enters the undo stack. The image always stays at its
/// origin `(0, 0)`; the canvas rect may therefore have a negative origin when
/// annotations spill off the left/bottom edges. Exactly two places consume
/// that offset: view↔image conversion and export translation.
enum CanvasGeometry {

    /// The canvas rect containing `imageBounds` plus every rect in
    /// `annotationRects`. A side that an annotation overflows extends to the
    /// annotation edge **plus `padding`**; a side nothing overflows stays flush
    /// with the image. Interior annotations never grow it, so the result grows
    /// and shrinks purely as a function of the current annotations. Rounded
    /// out to whole pixels (`.integral`).
    ///
    /// Growth is bounded: no side extends more than `maxExpansion` beyond the
    /// image, so repeatedly dragging an annotation outward (each drag covers
    /// more image pixels once the view re-fits) can't grow the canvas — and the
    /// export bitmap — without limit.
    static func canvasRect(
        imageBounds: CGRect, annotationRects: [CGRect], padding: CGFloat
    ) -> CGRect {
        guard !annotationRects.isEmpty else { return imageBounds }
        let pad = max(0, padding)

        var union = annotationRects[0]
        for rect in annotationRects.dropFirst() { union = union.union(rect) }

        // Only an overflowed side extends; a contained side keeps the image edge.
        let limit = maxExpansion(for: imageBounds)
        let minX = union.minX < imageBounds.minX
            ? max(union.minX - pad, imageBounds.minX - limit) : imageBounds.minX
        let minY = union.minY < imageBounds.minY
            ? max(union.minY - pad, imageBounds.minY - limit) : imageBounds.minY
        let maxX = union.maxX > imageBounds.maxX
            ? min(union.maxX + pad, imageBounds.maxX + limit) : imageBounds.maxX
        let maxY = union.maxY > imageBounds.maxY
            ? min(union.maxY + pad, imageBounds.maxY + limit) : imageBounds.maxY

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
    }

    /// Per-side cap on how far the canvas may extend past the image (pixels):
    /// the image's longer side, but at least 4096.
    static func maxExpansion(for imageBounds: CGRect) -> CGFloat {
        max(imageBounds.width, imageBounds.height, 4096)
    }
}

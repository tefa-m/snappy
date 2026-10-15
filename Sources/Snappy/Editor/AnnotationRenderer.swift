import CoreGraphics
import CoreText

/// Draws annotations into a CGContext in image-pixel space (origin
/// bottom-left) and flattens documents for export. The canvas view calls
/// `draw` with a scaled context, so what the canvas shows is exactly what
/// exports — one code path.
enum AnnotationRenderer {
    /// Draws annotations in array order (first = bottom, last = top).
    /// `base` is the document's base image — required only by blur/pixelate
    /// regions, which sample it; effects are skipped when it is nil.
    static func draw(_ annotations: [Annotation], in context: CGContext, base: CGImage? = nil) {
        let numbers = CounterGeometry.numbers(in: annotations)
        for annotation in annotations {
            switch annotation {
            case .shape(let shape):
                draw(shape, in: context)
            case .arrow(let arrow):
                draw(arrow, in: context)
            case .text(let text):
                draw(text, in: context)
            case .freehand(let stroke):
                draw(stroke, in: context)
            case .effect(let effect):
                if let base { draw(effect, in: context, base: base) }
            case .counter(let badge):
                draw(badge, number: numbers[badge.id] ?? 0, in: context)
            }
        }
    }

    /// Arrows are one filled tapered polygon (thin tail → arrowhead); the
    /// stroke color fills it, `hasFill` does not apply. A same-color
    /// round-join stroke around the polygon rounds every edge and corner
    /// (tail tip, barbs, apex) — its width is already accounted for in the
    /// polygon's half-widths (see ArrowGeometry.edgeRounding). Lines (M6) are
    /// a plain round-cap stroke from tail to head.
    private static func draw(_ arrow: ArrowAnnotation, in context: CGContext) {
        let color = arrow.style.strokeColor.cgColor
        switch arrow.kind {
        case .line:
            context.beginPath()
            context.move(to: arrow.tail)
            context.addLine(to: arrow.head)
            context.setStrokeColor(color)
            context.setLineCap(.round)
            context.setLineWidth(arrow.style.strokeWidth)
            context.strokePath()
        case .arrow:
            let polygon = ArrowGeometry.polygon(
                tail: arrow.tail, head: arrow.head, bow: arrow.bow,
                strokeWidth: arrow.style.strokeWidth
            )
            guard polygon.count >= 3 else { return }
            context.beginPath()
            context.addLines(between: polygon)
            context.closePath()
            context.setFillColor(color)
            context.setStrokeColor(color)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.setLineWidth(ArrowGeometry.edgeRounding(strokeWidth: arrow.style.strokeWidth))
            context.drawPath(using: .fillStroke)
        }
    }

    private static func draw(_ shape: ShapeAnnotation, in context: CGContext) {
        let path: CGPath
        switch shape.kind {
        case .rectangle:
            // Slightly rounded corners (see AnnotationGeometry) — hit-testing
            // stays rect-based; the tolerance band covers the corner rounding.
            let radius = AnnotationGeometry.rectangleCornerRadius(
                rect: shape.rect, strokeWidth: shape.style.strokeWidth
            )
            path = CGPath(
                roundedRect: shape.rect, cornerWidth: radius, cornerHeight: radius, transform: nil
            )
        case .oval:
            path = CGPath(ellipseIn: shape.rect, transform: nil)
        }
        if shape.style.hasFill {
            context.setFillColor(shape.style.strokeColor.withAlpha(AnnotationStyle.fillAlpha).cgColor)
            context.addPath(path)
            context.fillPath()
        }
        context.setStrokeColor(shape.style.strokeColor.cgColor)
        context.setLineWidth(shape.style.strokeWidth)
        context.addPath(path)
        context.strokePath()
    }

    private static func draw(_ text: TextAnnotation, in context: CGContext) {
        guard !text.text.isEmpty else { return }
        let metrics = TextGeometry.measure(text.text, fontSize: text.fontSize)
        let line = TextGeometry.line(
            text.text, fontSize: text.fontSize, color: text.style.strokeColor.cgColor
        )
        context.saveGState()
        context.textMatrix = .identity
        // The baseline sits `descent` above the bounding box bottom.
        context.textPosition = CGPoint(x: text.origin.x, y: text.origin.y + metrics.descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func draw(_ stroke: FreehandAnnotation, in context: CGContext) {
        guard stroke.points.count >= 2 else { return }
        context.beginPath()
        context.addPath(FreehandGeometry.path(for: stroke.points))
        context.setStrokeColor(stroke.style.strokeColor.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(stroke.style.strokeWidth)
        context.strokePath()
    }

    private static func draw(_ effect: EffectAnnotation, in context: CGContext, base: CGImage) {
        guard let (image, rect) = EffectRenderer.render(effect.kind, base: base, rect: effect.rect)
        else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(image, in: rect)
        context.restoreGState()
    }

    private static func draw(_ badge: CounterAnnotation, number: Int, in context: CGContext) {
        let rect = badge.boundingRect
        context.setFillColor(badge.style.strokeColor.cgColor)
        context.fillEllipse(in: rect)

        // Bold digits in white — or black on a light fill (yellow, green,
        // white) where white would fall under the 3:1 bold-text minimum.
        let text = String(number)
        let fontSize = CounterGeometry.fontSize(for: text, radius: badge.radius)
        let metrics = TextGeometry.measure(text, fontSize: fontSize, bold: true)
        let line = TextGeometry.line(
            text, fontSize: fontSize, color: badge.style.strokeColor.badgeLabelColor.cgColor, bold: true
        )
        context.saveGState()
        context.textMatrix = .identity
        // Vertically center the digits on the badge: the visual center of a
        // line sits (ascent - descent) / 2 above the baseline.
        context.textPosition = CGPoint(
            x: badge.center.x - metrics.size.width / 2,
            y: badge.center.y - (metrics.ascent - metrics.descent) / 2
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Flattens base image + annotations into a new image for Copy/Save at the
    /// image's own size (no canvas expansion).
    static func flatten(image: CGImage, annotations: [Annotation]) -> CGImage? {
        flatten(
            image: image, annotations: annotations,
            canvasRect: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            background: nil
        )
    }

    /// Flattens onto a `canvasRect` that may extend beyond the image (M-F
    /// auto-expanding canvas). The base image always sits at image-space
    /// `(0, 0)`; `canvasRect` may have a negative origin, so image space is
    /// translated by `-canvasRect.origin` into the output context. Newly
    /// exposed area outside the image is filled from `background` (nil ⇒ no
    /// expansion / no fill). When `canvasRect` equals the image bounds this is
    /// identical to the base-size flatten.
    static func flatten(
        image: CGImage, annotations: [Annotation], canvasRect: CGRect, background: CanvasBackground?
    ) -> CGImage? {
        let width = Int(canvasRect.width), height = Int(canvasRect.height)
        guard width > 0, height > 0, let context = makeContext(width: width, height: height, matching: image)
        else { return nil }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if canvasRect != imageBounds, let background {
            // Uniform fill: straight into the output context, no intermediate bitmap.
            context.setFillColor(background.fillColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        // Image + annotations share image space; shift it into the canvas rect.
        context.translateBy(x: -canvasRect.minX, y: -canvasRect.minY)
        context.draw(image, in: imageBounds)
        draw(annotations, in: context, base: image)
        return context.makeImage()
    }

    /// 8-bit RGBA output context. Takes the base image's colour space when it
    /// is an RGB one a bitmap context supports (a Display P3 capture stays P3
    /// instead of being gamut-mapped to sRGB on every export); sRGB otherwise.
    private static func makeContext(width: Int, height: Int, matching image: CGImage) -> CGContext? {
        func context(in space: CGColorSpace) -> CGContext? {
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        if let space = image.colorSpace, space.model == .rgb, let matched = context(in: space) {
            return matched
        }
        return CGColorSpace(name: CGColorSpace.sRGB).flatMap(context(in:))
    }
}

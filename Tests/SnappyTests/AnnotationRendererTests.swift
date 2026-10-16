import CoreGraphics
import Foundation
import Testing
@testable import Snappy

@Suite struct AnnotationRendererTests {
    private static let pureRed = AnnotationColor(red: 1, green: 0, blue: 0)

    private func whiteImage(width: Int = 100, height: Int = 100) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Samples a pixel in CG coordinates (origin bottom-left, like the model).
    private func pixel(of image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        // Create, draw into and read the context entirely inside the buffer's
        // borrow — a CGContext keeps the raw pointer, so it must not outlive it.
        return data.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Buffer row 0 is the top row; flip y from CG (bottom-up) coordinates.
            let index = ((height - 1 - y) * width + x) * 4
            return (raw[index], raw[index + 1], raw[index + 2], raw[index + 3])
        }
    }

    private func shape(
        _ kind: ShapeKind, rect: CGRect, width: CGFloat, fill: Bool = false
    ) -> Annotation {
        .shape(ShapeAnnotation(
            id: UUID(),
            kind: kind,
            rect: rect,
            style: AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: width, hasFill: fill)
        ))
    }

    @Test func flattenedImageKeepsBaseSize() throws {
        let flattened = try #require(AnnotationRenderer.flatten(image: whiteImage(), annotations: []))
        #expect(flattened.width == 100)
        #expect(flattened.height == 100)
    }

    @Test func rectangleStrokeRendersOnEdgesOnly() throws {
        let annotations = [shape(.rectangle, rect: CGRect(x: 10, y: 10, width: 40, height: 30), width: 4)]
        let flattened = try #require(AnnotationRenderer.flatten(image: whiteImage(), annotations: annotations))

        // On the left edge (stroke straddles x = 10): red.
        let edge = pixel(of: flattened, x: 10, y: 25)
        #expect(edge.r > 200 && edge.g < 80 && edge.b < 80)

        // Interior stays untouched white (no fill).
        let interior = pixel(of: flattened, x: 30, y: 25)
        #expect(interior.r > 250 && interior.g > 250 && interior.b > 250)

        // Well outside the shape: white.
        let outside = pixel(of: flattened, x: 70, y: 70)
        #expect(outside.r > 250 && outside.g > 250 && outside.b > 250)
    }

    @Test func ovalStrokeFollowsTheEllipseNotItsBounds() throws {
        let rect = CGRect(x: 50, y: 50, width: 40, height: 20)
        let annotations = [shape(.oval, rect: rect, width: 2)]
        let flattened = try #require(AnnotationRenderer.flatten(image: whiteImage(), annotations: annotations))

        // Leftmost point of the ellipse (minX, midY): red.
        let edge = pixel(of: flattened, x: 50, y: 60)
        #expect(edge.r > 200 && edge.g < 80 && edge.b < 80)

        // Ellipse center: white.
        let center = pixel(of: flattened, x: 70, y: 60)
        #expect(center.r > 250 && center.g > 250 && center.b > 250)

        // Bounding-rect corner is off the ellipse: white.
        let corner = pixel(of: flattened, x: 50, y: 50)
        #expect(corner.r > 250 && corner.g > 250 && corner.b > 250)
    }

    @Test func fillRendersTranslucentInterior() throws {
        let annotations = [shape(.rectangle, rect: CGRect(x: 10, y: 10, width: 40, height: 30), width: 2, fill: true)]
        let flattened = try #require(AnnotationRenderer.flatten(image: whiteImage(), annotations: annotations))

        // Pure red at 0.2 alpha over white ≈ (255, 204, 204).
        let interior = pixel(of: flattened, x: 30, y: 25)
        #expect(interior.r > 240)
        #expect(interior.g > 150 && interior.g < 240)
        #expect(interior.b > 150 && interior.b < 240)

        // Outside stays white.
        let outside = pixel(of: flattened, x: 70, y: 70)
        #expect(outside.g > 250)
    }

    @Test func rectangleCornersAreSlightlyRounded() throws {
        // Radius = min(2×6, 60/4) = 12: the sharp corner is cut away (the
        // corner pixel sits well outside the arc's stroke band) while edge
        // midpoints keep their stroke.
        let annotations = [shape(.rectangle, rect: CGRect(x: 10, y: 10, width: 60, height: 60), width: 6)]
        let flattened = try #require(AnnotationRenderer.flatten(image: whiteImage(), annotations: annotations))

        let corner = pixel(of: flattened, x: 10, y: 10)
        #expect(corner.r > 250 && corner.g > 250 && corner.b > 250)

        let edge = pixel(of: flattened, x: 10, y: 40)
        #expect(edge.r > 200 && edge.g < 80 && edge.b < 80)
    }

    @Test func arrowFillsTaperedShaftAndHead() throws {
        // Horizontal arrow 10→90 at y = 50, strokeWidth 6: head is 36 long
        // (base at x = 54, half-width 16.2), shaft half-width 5.1 at the base
        // tapering to 0.5 at the tail.
        let arrow = Annotation.arrow(ArrowAnnotation(
            id: UUID(),
            tail: CGPoint(x: 10, y: 50),
            head: CGPoint(x: 90, y: 50),
            style: AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: 6, hasFill: false)
        ))
        let flattened = try #require(AnnotationRenderer.flatten(image: whiteImage(), annotations: [arrow]))

        // On the shaft axis and inside the arrowhead: red.
        let shaft = pixel(of: flattened, x: 40, y: 50)
        #expect(shaft.r > 200 && shaft.g < 80 && shaft.b < 80)
        let head = pixel(of: flattened, x: 70, y: 50)
        #expect(head.r > 200 && head.g < 80 && head.b < 80)

        // Off the thin shaft, beyond the barbs, and past the tip: white.
        for (x, y) in [(40, 56), (70, 62), (95, 50)] {
            let outside = pixel(of: flattened, x: x, y: y)
            #expect(outside.r > 250 && outside.g > 250 && outside.b > 250)
        }
    }

    @Test func curvedArrowRendersAlongTheBulge() throws {
        // Bow 30 lifts the curve midpoint of a 10→90 arrow from y = 20 to
        // y = 50 — the paint must follow the curve, not the chord.
        let arrow = Annotation.arrow(ArrowAnnotation(
            id: UUID(),
            tail: CGPoint(x: 10, y: 20),
            head: CGPoint(x: 90, y: 20),
            style: AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: 4, hasFill: false),
            bow: 30
        ))
        let flattened = try #require(AnnotationRenderer.flatten(image: whiteImage(), annotations: [arrow]))

        // On the bulge (curve midpoint): red.
        let bulge = pixel(of: flattened, x: 50, y: 50)
        #expect(bulge.r > 200 && bulge.g < 80 && bulge.b < 80)

        // On the chord midpoint, 30 px below the curve: untouched white.
        let chord = pixel(of: flattened, x: 50, y: 20)
        #expect(chord.r > 250 && chord.g > 250 && chord.b > 250)
    }

    @Test func laterAnnotationsRenderOnTop() throws {
        // A blue rect drawn after a red rect at the same spot wins.
        let rect = CGRect(x: 20, y: 20, width: 20, height: 20)
        let red = shape(.rectangle, rect: rect, width: 4)
        let blue = Annotation.shape(ShapeAnnotation(
            id: UUID(),
            kind: .rectangle,
            rect: rect,
            style: AnnotationStyle(
                strokeColor: AnnotationColor(red: 0, green: 0, blue: 1),
                strokeWidth: 4,
                hasFill: false
            )
        ))
        let flattened = try #require(
            AnnotationRenderer.flatten(image: whiteImage(), annotations: [red, blue])
        )
        let edge = pixel(of: flattened, x: 20, y: 30)
        #expect(edge.b > 200 && edge.r < 80)
    }

    // MARK: - M6 tools

    /// Left half black, right half white — sharp vertical boundary at x = 50,
    /// so blur/pixelate visibly change pixels near it.
    private func halfBlackImage(width: Int = 100, height: Int = 100) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    @Test func lineRendersAsPlainStrokeWithoutHead() throws {
        let line = Annotation.arrow(ArrowAnnotation(
            id: UUID(),
            tail: CGPoint(x: 10, y: 50),
            head: CGPoint(x: 90, y: 50),
            style: AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: 4, hasFill: false),
            kind: .line
        ))
        let flattened = try #require(AnnotationRenderer.flatten(image: whiteImage(), annotations: [line]))

        // On the segment: red, at constant width along its whole length (no
        // widening head near x = 90 — unlike the arrow test's flare).
        for x in [30, 60, 88] {
            let on = pixel(of: flattened, x: x, y: 50)
            #expect(on.r > 200 && on.g < 80 && on.b < 80)
        }
        // Beyond the half-width and past the endpoints: white.
        for (x, y) in [(60, 56), (85, 57), (96, 50)] {
            let off = pixel(of: flattened, x: x, y: y)
            #expect(off.r > 250 && off.g > 250 && off.b > 250)
        }
    }

    @Test func textRendersInsideItsBoundingRect() throws {
        let style = AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: 4, hasFill: false)
        let text = TextAnnotation(id: UUID(), origin: CGPoint(x: 10, y: 40), text: "Hi", style: style)
        let flattened = try #require(
            AnnotationRenderer.flatten(image: whiteImage(), annotations: [.text(text)])
        )

        // Some pixel inside the measured bounds carries the text color.
        let bounds = text.boundingRect.integral
        var foundRed = false
        for x in Int(bounds.minX)...Int(bounds.maxX) where !foundRed {
            for y in Int(bounds.minY)...Int(bounds.maxY) where !foundRed {
                let p = pixel(of: flattened, x: min(x, 99), y: min(y, 99))
                foundRed = p.r > 150 && p.g < 100
            }
        }
        #expect(foundRed)

        // Far away from the label: untouched white.
        let outside = pixel(of: flattened, x: 90, y: 90)
        #expect(outside.r > 250 && outside.g > 250 && outside.b > 250)
    }

    @Test func counterBadgeRendersDiscWithWhiteNumber() throws {
        let style = AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: 6, hasFill: false)
        let badge = CounterAnnotation(id: UUID(), center: CGPoint(x: 50, y: 50), style: style)
        let flattened = try #require(
            AnnotationRenderer.flatten(image: whiteImage(), annotations: [.counter(badge)])
        )

        // Inside the disc, left of the digit (radius is 18): red fill.
        let disc = pixel(of: flattened, x: 38, y: 50)
        #expect(disc.r > 200 && disc.g < 80 && disc.b < 80)
        // Outside the disc: white background.
        let outside = pixel(of: flattened, x: 75, y: 50)
        #expect(outside.r > 250 && outside.g > 250 && outside.b > 250)
        // The white "1" shows up near the center.
        var foundWhite = false
        for x in 42...58 where !foundWhite {
            for y in 42...58 where !foundWhite {
                let p = pixel(of: flattened, x: x, y: y)
                foundWhite = p.r > 200 && p.g > 200 && p.b > 200
            }
        }
        #expect(foundWhite)
    }

    @Test func counterBadgeOnALightFillGetsADarkNumber() throws {
        // White digits on yellow were 1.5:1 — effectively invisible.
        let yellow = AnnotationColor(red: 1, green: 0.8, blue: 0)
        let style = AnnotationStyle(strokeColor: yellow, strokeWidth: 6, hasFill: false)
        let badge = CounterAnnotation(id: UUID(), center: CGPoint(x: 50, y: 50), style: style)
        let flattened = try #require(
            AnnotationRenderer.flatten(image: whiteImage(), annotations: [.counter(badge)])
        )
        var foundDark = false
        for x in 42...58 where !foundDark {
            for y in 42...58 where !foundDark {
                let p = pixel(of: flattened, x: x, y: y)
                foundDark = p.r < 60 && p.g < 60 && p.b < 60
            }
        }
        #expect(foundDark)
    }

    @Test func badgeNumberHundredStaysInsideTheDisc() throws {
        // 100 badges on one spot: the top one reads "100". Its ink must stay
        // inside the 18 px disc — e.g. at an export edge it would be clipped.
        let style = AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: 6, hasFill: false)
        let badges: [Annotation] = (0..<100).map { _ in
            .counter(CounterAnnotation(id: UUID(), center: CGPoint(x: 50, y: 50), style: style))
        }
        let flattened = try #require(AnnotationRenderer.flatten(image: whiteImage(), annotations: badges))
        for y in 44...56 {
            for x in [30, 31, 69, 70] { // 19–20 px from the centre: outside the disc
                let p = pixel(of: flattened, x: x, y: y)
                #expect(p.r > 250 && p.g > 250 && p.b > 250, "ink at (\(x), \(y))")
            }
        }
    }

    @Test func effectStrengthGrowsWithTheRegionOnSmallCaptures() {
        // A one-line region (36 px tall) in a 700×90 px capture: the image term
        // alone gave a 4 px blur that OCR read through.
        let small = CGSize(width: 700, height: 90), line = CGSize(width: 500, height: 36)
        #expect(EffectRenderer.blurRadius(imageSize: small, region: line) == 0.3 * 36)
        #expect(EffectRenderer.pixelScale(imageSize: small, region: line) == 0.5 * 36)
        // Large captures keep their (already strong) image-derived strength.
        let fiveK = CGSize(width: 5120, height: 2880)
        #expect(EffectRenderer.blurRadius(imageSize: fiveK, region: line) == 2880.0 / 50)
        #expect(EffectRenderer.pixelScale(imageSize: fiveK, region: line) == 2880.0 / 40)
        // Large regions are capped instead of dissolving into a flat colour.
        let big = CGSize(width: 1000, height: 600)
        #expect(EffectRenderer.blurRadius(imageSize: small, region: big) == 40)
        #expect(EffectRenderer.pixelScale(imageSize: small, region: big) == 64)
        // Tiny regions keep the floors.
        let tiny = CGSize(width: 8, height: 8)
        #expect(EffectRenderer.blurRadius(imageSize: tiny, region: tiny) == 4)
        #expect(EffectRenderer.pixelScale(imageSize: tiny, region: tiny) == 6)
    }

    @Test func blurChangesTheRegionAndNothingElse() throws {
        let style = AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: 4, hasFill: false)
        let effect = EffectAnnotation(
            id: UUID(), kind: .blur, rect: CGRect(x: 30, y: 30, width: 40, height: 20), style: style
        )
        let flattened = try #require(
            AnnotationRenderer.flatten(image: halfBlackImage(), annotations: [.effect(effect)])
        )

        // Inside the region the black/white boundary is softened: the pixel
        // just left of x = 50 lightens, the one just right darkens.
        let softenedDark = pixel(of: flattened, x: 48, y: 40)
        #expect(softenedDark.g > 20)
        let softenedLight = pixel(of: flattened, x: 52, y: 40)
        #expect(softenedLight.g < 235)

        // Outside the region the boundary stays razor sharp.
        let sharpDark = pixel(of: flattened, x: 48, y: 70)
        #expect(sharpDark.g < 10)
        let sharpLight = pixel(of: flattened, x: 51, y: 70)
        #expect(sharpLight.g > 245)
    }

    /// Fail closed: an effect that can't be rendered hides its region behind
    /// opaque grey — never the source pixels — and leaves the rest alone.
    @Test func effectThatFailsToRenderCoversItsRegionOpaquely() throws {
        let style = AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: 4, hasFill: false)
        let effect = EffectAnnotation(
            id: UUID(), kind: .blur, rect: CGRect(x: 30, y: 30, width: 40, height: 20), style: style
        )
        let base = halfBlackImage()
        let context = try #require(CGContext(
            data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        AnnotationRenderer.draw(effect, in: context, base: base, render: { _, _, _ in nil })
        let result = try #require(context.makeImage())

        // Both the black and the white half of the region become the same grey.
        for x in [35, 48, 52, 65] {
            let p = pixel(of: result, x: x, y: 40)
            #expect(abs(Int(p.g) - 128) <= 2 && p.a == 255)
        }
        // Outside the region the boundary is untouched.
        #expect(pixel(of: result, x: 48, y: 70).g < 10)
        #expect(pixel(of: result, x: 51, y: 70).g > 245)
    }

    @Test func pixelateChangesTheRegionAndNothingElse() throws {
        let style = AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: 4, hasFill: false)
        // minX = 47 aligns the pixel blocks so 49 and 50 (across the sharp
        // boundary) share one block inside the region.
        let effect = EffectAnnotation(
            id: UUID(), kind: .pixelate, rect: CGRect(x: 47, y: 30, width: 30, height: 20), style: style
        )
        let flattened = try #require(
            AnnotationRenderer.flatten(image: halfBlackImage(), annotations: [.effect(effect)])
        )

        // Inside: both sides of the former boundary got the same block color.
        let left = pixel(of: flattened, x: 49, y: 40)
        let right = pixel(of: flattened, x: 50, y: 40)
        #expect(abs(Int(left.g) - Int(right.g)) < 30)

        // Outside: the boundary is still a hard black/white step.
        let sharpDark = pixel(of: flattened, x: 49, y: 70)
        let sharpLight = pixel(of: flattened, x: 50, y: 70)
        #expect(Int(sharpLight.g) - Int(sharpDark.g) > 200)
    }

    // MARK: - Expanded-canvas flatten (M-F)

    @Test func expandedFlattenMatchesCanvasRectSize() throws {
        let canvasRect = CGRect(x: -10, y: -10, width: 120, height: 130)
        let flattened = try #require(AnnotationRenderer.flatten(
            image: whiteImage(), annotations: [], canvasRect: canvasRect, background: nil
        ))
        #expect(flattened.width == 120)
        #expect(flattened.height == 130)
    }

    @Test func negativeCoordinateAnnotationLandsAtTheRightPixel() throws {
        // Rectangle whose left edge sits at model x = -10 (outside the image),
        // on a canvas rect starting at (-20, 30). Its left stroke must render at
        // output x = 10 (‑10 − (‑20)), y = 20 (50 − 30).
        let rect = CGRect(x: -10, y: 40, width: 40, height: 20)
        let annotations = [shape(.rectangle, rect: rect, width: 4)]
        let canvasRect = CGRect(x: -20, y: 30, width: 140, height: 40)
        let flattened = try #require(AnnotationRenderer.flatten(
            image: whiteImage(), annotations: annotations, canvasRect: canvasRect, background: nil
        ))
        let onLeftStroke = pixel(of: flattened, x: 10, y: 20)
        #expect(onLeftStroke.r > 200 && onLeftStroke.g < 80 && onLeftStroke.b < 80)
    }

    @Test func flattenWithImageBoundsEqualsBaseSizePath() throws {
        // canvasRect == image bounds, no background → identical to the plain
        // flatten (the convenience overload delegates to exactly this).
        let annotations = [shape(.rectangle, rect: CGRect(x: 10, y: 10, width: 40, height: 30), width: 4)]
        let plain = try #require(AnnotationRenderer.flatten(image: whiteImage(), annotations: annotations))
        let explicit = try #require(AnnotationRenderer.flatten(
            image: whiteImage(), annotations: annotations,
            canvasRect: CGRect(x: 0, y: 0, width: 100, height: 100), background: nil
        ))
        #expect(plain.width == explicit.width && plain.height == explicit.height)
        for (x, y) in [(10, 25), (30, 25), (70, 70)] {
            let a = pixel(of: plain, x: x, y: y)
            let b = pixel(of: explicit, x: x, y: y)
            #expect(a.r == b.r && a.g == b.g && a.b == b.b)
        }
    }

    @Test func effectsAreSkippedWithoutABaseImage() {
        // draw(_:in:) without `base` must not crash or paint anything for
        // effect annotations (the canvas always passes the base; this guards
        // the default).
        let style = AnnotationStyle(strokeColor: Self.pureRed, strokeWidth: 4, hasFill: false)
        let effect = EffectAnnotation(
            id: UUID(), kind: .blur, rect: CGRect(x: 10, y: 10, width: 20, height: 20), style: style
        )
        let context = CGContext(
            data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        AnnotationRenderer.draw([.effect(effect)], in: context)
        #expect(context.makeImage() != nil)
    }

    // MARK: - Direct background fill, colour space

    @Test func expandedFlattenFillsTheExposedAreaWithTheBackgroundColor() throws {
        let background = CanvasBackground(
            imageBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            fill: CanvasBackground.RGBA(r: 0, g: 0, b: 1)
        )
        let canvasRect = CGRect(x: -10, y: -10, width: 120, height: 120)
        let flattened = try #require(AnnotationRenderer.flatten(
            image: whiteImage(), annotations: [], canvasRect: canvasRect, background: background
        ))
        // Margin pixel: the fill (blue). Pixel over the image: still white.
        let margin = pixel(of: flattened, x: 3, y: 3)
        #expect(margin.b > 240 && margin.r < 15 && margin.g < 15)
        let inside = pixel(of: flattened, x: 60, y: 60)
        #expect(inside.r > 240 && inside.g > 240 && inside.b > 240)
    }

    @Test func noBackgroundFillWhenTheCanvasIsTheImage() throws {
        let background = CanvasBackground(
            imageBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            fill: CanvasBackground.RGBA(r: 0, g: 0, b: 1)
        )
        let flattened = try #require(AnnotationRenderer.flatten(
            image: whiteImage(), annotations: [],
            canvasRect: CGRect(x: 0, y: 0, width: 100, height: 100), background: background
        ))
        let corner = pixel(of: flattened, x: 0, y: 0)
        #expect(corner.r > 240 && corner.g > 240 && corner.b > 240)
    }

    @Test func flattenKeepsTheBaseImagesWideGamutColorSpace() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(
            data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: p3, components: [0, 1, 0, 1])!) // P3 green
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let source = try #require(context.makeImage())

        let flattened = try #require(AnnotationRenderer.flatten(image: source, annotations: []))
        #expect(flattened.colorSpace?.name == CGColorSpace.displayP3)
        #expect(flattened.width == 20 && flattened.height == 20)
    }

    @Test func flattenFallsBackToSRGBForNonRGBImages() throws {
        let gray = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let context = try #require(CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let source = try #require(context.makeImage())

        let flattened = try #require(AnnotationRenderer.flatten(image: source, annotations: []))
        #expect(flattened.colorSpace?.name == CGColorSpace.sRGB)
    }

    // MARK: - Effect cache

    @Test func effectResultsAreCachedPerBaseKindAndRegion() throws {
        let cache = EffectCache()
        let base = halfBlackImage()
        let rect = CGRect(x: 10, y: 10, width: 30, height: 20)

        let first = try #require(EffectRenderer.render(.blur, base: base, rect: rect, cache: cache))
        #expect(cache.count == 1)
        let second = try #require(EffectRenderer.render(.blur, base: base, rect: rect, cache: cache))
        #expect(first.image === second.image) // served from cache
        #expect(cache.count == 1)

        // Different kind / region / base image → separate entries.
        _ = EffectRenderer.render(.pixelate, base: base, rect: rect, cache: cache)
        _ = EffectRenderer.render(.blur, base: base, rect: rect.offsetBy(dx: 5, dy: 0), cache: cache)
        _ = EffectRenderer.render(.blur, base: halfBlackImage(), rect: rect, cache: cache)
        #expect(cache.count == 4)

        cache.clear()
        #expect(cache.count == 0)
    }

    @Test func cachedAndFreshEffectOutputsAreIdentical() throws {
        let cache = EffectCache()
        let base = halfBlackImage()
        let rect = CGRect(x: 40, y: 30, width: 30, height: 20)
        let cached = try #require(EffectRenderer.render(.pixelate, base: base, rect: rect, cache: cache))
        let fresh = try #require(EffectRenderer.render(.pixelate, base: base, rect: rect, cache: EffectCache()))
        #expect(cached.rect == fresh.rect)
        #expect(pixel(of: cached.image, x: 5, y: 5) == pixel(of: fresh.image, x: 5, y: 5))
    }

    @Test func effectCacheEvictsLeastRecentlyUsedBeyondItsBound() {
        let cache = EffectCache(maxEntries: 4)
        let base = halfBlackImage()
        func region(_ i: Int) -> CGRect { CGRect(x: i, y: 5, width: 10, height: 10) }
        for i in 0..<4 { _ = EffectRenderer.render(.pixelate, base: base, rect: region(i), cache: cache) }
        // Touch region 0 so region 1 becomes the oldest.
        let touched = EffectRenderer.render(.pixelate, base: base, rect: region(0), cache: cache)
        _ = EffectRenderer.render(.pixelate, base: base, rect: region(4), cache: cache)
        #expect(cache.count == 4)
        let again = EffectRenderer.render(.pixelate, base: base, rect: region(0), cache: cache)
        #expect(touched?.image === again?.image) // survived eviction
    }

    @Test func effectCacheRespectsItsByteBudget() {
        let cache = EffectCache(maxEntries: 100, maxBytes: 10 * 10 * 4 * 2) // two 10×10 results
        let base = halfBlackImage()
        for i in 0..<5 {
            _ = EffectRenderer.render(
                .pixelate, base: base, rect: CGRect(x: i * 12, y: 5, width: 10, height: 10), cache: cache
            )
        }
        #expect(cache.count <= 2)
    }
}

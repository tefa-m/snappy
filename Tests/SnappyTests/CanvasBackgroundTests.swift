import CoreGraphics
import Testing
@testable import Snappy

@Suite struct CanvasBackgroundTests {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
    private let black = CanvasBackground.RGBA(r: 0, g: 0, b: 0)
    private let white = CanvasBackground.RGBA(r: 1, g: 1, b: 1)

    private func context(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    private func solidImage(gray: CGFloat, width: Int = 60, height: Int = 40) -> CGImage {
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Left half black, right half white — sharp boundary at the middle column.
    private func leftBlackImage(width: Int = 60, height: Int = 40) -> CGImage {
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return ctx.makeImage()!
    }

    /// White canvas with an isolated dark object away from most edges — mimics a
    /// screenshot whose real background is white plus some content/divider.
    private func whiteWithDarkObject(width: Int = 120, height: Int = 90) -> CGImage {
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A dark bar touching only the bottom edge center (a divider/object) —
        // three edges stay clean white, one edge is mostly white.
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: width * 2 / 5, y: 0, width: width / 5, height: 8))
        return ctx.makeImage()!
    }

    // MARK: - Memberwise init (fill supplied directly)

    @Test func memberwiseInitExposesFill() {
        let bg = CanvasBackground(imageBounds: bounds, fill: white)
        #expect(bg.fillColor == white)
        #expect(bg.imageBounds == bounds)
    }

    // MARK: - Detection from an image

    @Test func solidImageProducesItsColor() {
        let bg = CanvasBackground(image: solidImage(gray: 0.5))!
        #expect(abs(bg.fillColor.r - 0.5) < 0.02)
        #expect(abs(bg.fillColor.g - 0.5) < 0.02)
        #expect(abs(bg.fillColor.b - 0.5) < 0.02)
    }

    @Test func dominantBackgroundBeatsIsolatedDetail() {
        // Mostly-white capture with a dark divider on one edge → clean white,
        // NOT a smear of the dark pixels.
        let bg = CanvasBackground(image: whiteWithDarkObject())!
        #expect(bg.fillColor.r > 0.9)
        #expect(bg.fillColor.g > 0.9)
        #expect(bg.fillColor.b > 0.9)
    }

    @Test func splitImagePicksOneCleanColor() {
        // Half black / half white: detection must resolve to ONE of the two
        // clean colors — never a mid-gray smear between them.
        let bg = CanvasBackground(image: leftBlackImage())!
        let c = bg.fillColor
        let nearBlack = c.r < 0.1 && c.g < 0.1 && c.b < 0.1
        let nearWhite = c.r > 0.9 && c.g > 0.9 && c.b > 0.9
        #expect(nearBlack || nearWhite)
    }

    // MARK: - Direct fill colour

    @Test func cgColorIsSRGBTaggedWithTheFillComponents() throws {
        let bg = CanvasBackground(imageBounds: bounds, fill: CanvasBackground.RGBA(r: 0.2, g: 0.4, b: 0.6))
        let color = bg.fillColor.cgColor
        #expect(color.colorSpace?.name == CGColorSpace.sRGB)
        let components = try #require(color.components)
        #expect(components.count == 4)
        #expect(abs(components[0] - 0.2) < 1e-9)
        #expect(abs(components[1] - 0.4) < 1e-9)
        #expect(abs(components[2] - 0.6) < 1e-9)
        #expect(components[3] == 1)
    }

    // MARK: - Perimeter-only sampling

    /// Clean white perimeter, loud noise everywhere inside the sampled bands'
    /// reach: detection must read only the bands, so the result is white.
    @Test func onlyThePerimeterBandsInfluenceDetection() {
        let width = 200, height = 150
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 8 px white frame (the sampled depth); the entire interior stays black.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 8))
        ctx.fill(CGRect(x: 0, y: height - 8, width: width, height: 8))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: height))
        ctx.fill(CGRect(x: width - 8, y: 0, width: 8, height: height))
        let bg = CanvasBackground(image: ctx.makeImage()!)!
        #expect(bg.fillColor.r > 0.95 && bg.fillColor.g > 0.95 && bg.fillColor.b > 0.95)
    }

    /// Each band must be read from the matching side: a distinct colour on each
    /// edge, with three edges agreeing, must resolve to the majority.
    @Test func bandsAreMappedToTheirOwnEdges() {
        let width = 120, height = 90
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Bottom edge (CG y = 0) red; the other three stay blue.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 8))
        let bg = CanvasBackground(image: ctx.makeImage()!)!
        #expect(abs(bg.fillColor.r - 0.2) < 0.1)
        #expect(abs(bg.fillColor.b - 0.8) < 0.1)
    }

    @Test func tinyImagesDoNotCrashDetection() {
        for (w, h) in [(1, 1), (2, 1), (1, 3), (3, 3), (7, 5)] {
            let bg = CanvasBackground(image: solidImage(gray: 0.5, width: w, height: h))
            #expect(bg != nil)
            #expect(abs((bg?.fillColor.r ?? 0) - 0.5) < 0.02)
        }
    }

    @Test func detectionIsDeterministic() {
        let a = CanvasBackground(image: whiteWithDarkObject())!
        let b = CanvasBackground(image: whiteWithDarkObject())!
        #expect(a.fillColor == b.fillColor)
    }
}

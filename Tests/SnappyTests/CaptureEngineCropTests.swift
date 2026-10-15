import CoreGraphics
import Testing
@testable import Snappy

/// `CaptureEngine.crop` is `nonisolated` and pure CoreGraphics, so it tests
/// headlessly — which matters, because it encodes the one coordinate rule of the
/// frozen-capture path (the crop rect's origin is the image's TOP-left) and the
/// memory rule (the result must not share the snapshot's buffer).
@Suite struct CaptureEngineCropTests {
    /// A 4×4 sRGB image whose **top** half is red and bottom half is blue.
    /// CGContext draws with a bottom-left origin, so the red band is filled at
    /// the *high* y values — that flip is exactly what this fixture pins down.
    private func stripedImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2)) // bottom → blue
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 2, width: 4, height: 2)) // top → red
        return context.makeImage()!
    }

    /// Reads the image's dominant channel by re-rendering it 1×1.
    private func averageColor(of image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (pixel[1], pixel[2], pixel[3]) // premultipliedFirst: A R G B
    }

    @Test func cropTakesItsRectFromTheImagesTopLeft() {
        // y = 0…2 in crop space must be the RED band, i.e. the visual top.
        let cropped = CaptureEngine.crop(stripedImage(), to: CGRect(x: 0, y: 0, width: 4, height: 2))
        let color = try! #require(cropped.map(averageColor(of:)))
        #expect(color.r > 200)
        #expect(color.b < 50)
    }

    @Test func cropTakesTheBottomBandFromTheHigherRect() {
        let cropped = CaptureEngine.crop(stripedImage(), to: CGRect(x: 0, y: 2, width: 4, height: 2))
        let color = try! #require(cropped.map(averageColor(of:)))
        #expect(color.b > 200)
        #expect(color.r < 50)
    }

    @Test func cropReturnsTheRequestedPixelSize() {
        let cropped = CaptureEngine.crop(stripedImage(), to: CGRect(x: 1, y: 1, width: 2, height: 3))
        #expect(cropped?.width == 2)
        #expect(cropped?.height == 3)
    }

    @Test func cropDetachesFromTheSourceBuffer() {
        // A plain CGImage.cropping(to:) shares the parent's provider and
        // inherits its row stride, keeping the whole display snapshot alive.
        // The source has to be genuinely wide for this to be visible — narrow
        // images all land on CoreGraphics' minimum row alignment.
        let context = CGContext(
            data: nil,
            width: 256,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        let source = context.makeImage()!

        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        let attached = try! #require(source.cropping(to: rect))
        let detached = try! #require(CaptureEngine.crop(source, to: rect))
        #expect(attached.bytesPerRow == source.bytesPerRow)
        #expect(detached.bytesPerRow < source.bytesPerRow)
    }

    @Test func cropPreservesBitDepthAndColorSpace() {
        let source = stripedImage()
        let cropped = try! #require(CaptureEngine.crop(source, to: CGRect(x: 0, y: 0, width: 2, height: 2)))
        #expect(cropped.bitsPerComponent == source.bitsPerComponent)
        #expect(cropped.colorSpace?.name == source.colorSpace?.name)
    }

    @Test func cropOfAnEmptyRectIsNil() {
        #expect(CaptureEngine.crop(stripedImage(), to: .zero) == nil)
    }

    @Test func cropFullyOutsideTheImageIsNil() {
        #expect(CaptureEngine.crop(stripedImage(), to: CGRect(x: 100, y: 100, width: 4, height: 4)) == nil)
    }

    @Test func cropOfTheWholeSnapshotReturnsItWithoutCopying() {
        let source = stripedImage()
        let whole = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let result = try! #require(CaptureEngine.crop(source, to: whole))
        #expect(result === source)
    }

    @Test func cropOfARectLargerThanTheSnapshotAlsoReturnsIt() {
        let source = stripedImage()
        let result = try! #require(CaptureEngine.crop(source, to: CGRect(x: -2, y: -2, width: 20, height: 20)))
        #expect(result === source)
    }
}

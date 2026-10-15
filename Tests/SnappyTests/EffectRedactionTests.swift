import AppKit
import CoreText
import Testing
@testable import Snappy

/// Reproducible OCR harness for design review C1 (docs/design-reviews/
/// editor-canvas.md): draw a known secret, cover it with a blur / pixelate
/// annotation drawn around the line, flatten through the shipping renderer,
/// and run the shipping Vision OCR on the result. These check the measured
/// cases only. They are no guarantee of redaction in general: blur and
/// pixelate obscure the text, they don't remove it.
@Suite struct EffectRedactionTests {
    private static let secret = "Password: hunter2 Token 4821-7730"

    /// The secret in the system font at `pointSize × scale` px, black on
    /// white, plus the line's ink rect padded by 4 pt (a region drawn
    /// around the line).
    private func capture(width: Int, height: Int, pointSize: CGFloat, scale: CGFloat) -> (CGImage, CGRect) {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pointSize * scale), .foregroundColor: NSColor.black,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: Self.secret, attributes: attributes))
        let ink = CTLineGetImageBounds(line, context)
        let origin = CGPoint(x: 20 * scale, y: CGFloat(height) / 2)
        context.textPosition = origin
        CTLineDraw(line, context)
        let region = CGRect(
            x: origin.x + ink.minX - 4 * scale, y: origin.y + ink.minY - 4 * scale,
            width: ink.width + 8 * scale, height: ink.height + 8 * scale
        ).integral
        return (context.makeImage()!, region)
    }

    private func ocr(_ image: CGImage) async throws -> String {
        try await TextRecognizer.recognizeText(in: image)
    }

    /// The two cases that leaked before the region term: a 13 pt line in a
    /// one-line 2× capture, and 24 pt text in a small 2× capture.
    @Test(arguments: [
        (700, 90, CGFloat(13)),
        (1000, 140, CGFloat(24)),
    ])
    func effectsDefeatOCROnSmallCaptures(width: Int, height: Int, pointSize: CGFloat) async throws {
        let (image, region) = capture(width: width, height: height, pointSize: pointSize, scale: 2)
        // Sanity: unobscured, the harness does read the secret.
        #expect(try await ocr(image).contains("4821"))

        for kind in [EffectKind.blur, .pixelate] {
            let effect = Annotation.effect(EffectAnnotation(
                id: UUID(), kind: kind, rect: region,
                style: AnnotationStyle.defaultStyle(scale: 2)
            ))
            let flattened = try #require(AnnotationRenderer.flatten(image: image, annotations: [effect]))
            let text = try await ocr(flattened)
            #expect(!text.contains("4821"), "\(kind) leaked: \(text)")
            #expect(!text.contains("7730"), "\(kind) leaked: \(text)")
            #expect(!text.lowercased().contains("hunter"), "\(kind) leaked: \(text)")
        }
    }
}

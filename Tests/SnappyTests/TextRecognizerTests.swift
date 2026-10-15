import AppKit
import CoreText
import Testing
@testable import Snappy

/// Offline integration tests: render known text into a CGImage and run the
/// real Vision request against it — no fixtures from disk, no network.
@Suite struct TextRecognizerTests {
    private func render(lines: [String], size: CGSize = CGSize(width: 800, height: 300)) -> CGImage {
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("Helvetica" as CFString, 36, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        for (index, line) in lines.enumerated() {
            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: line, attributes: attributes)
            )
            context.textPosition = CGPoint(x: 24, y: size.height - 60 - CGFloat(index) * 70)
            CTLineDraw(ctLine, context)
        }
        return context.makeImage()!
    }

    @Test func recognizesEnglishAndGermanIncludingUmlauts() async throws {
        let image = render(lines: [
            "The quick brown fox",
            "Grüße aus Österreich",
            "Die Straße ist größer",
        ])
        let text = try await TextRecognizer.recognizeText(in: image)
        #expect(text.contains("The quick brown fox"))
        #expect(text.contains("Grüße aus Österreich"))
        #expect(text.contains("Die Straße ist größer"))
        // Lines must come back top-to-bottom.
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines.first?.contains("fox") == true)
        #expect(lines.last?.contains("Straße") == true)
    }

    @Test func blankImageYieldsEmptyString() async throws {
        let image = render(lines: [])
        let text = try await TextRecognizer.recognizeText(in: image)
        #expect(text.isEmpty)
    }
}

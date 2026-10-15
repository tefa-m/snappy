import CoreGraphics
import Testing
@testable import Snappy

@Suite struct TextAssemblerTests {
    private func obs(
        _ string: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 0.2,
        height: CGFloat = 0.05
    ) -> TextObservation {
        TextObservation(string: string, boundingBox: CGRect(x: x, y: y, width: width, height: height))
    }

    @Test func joinsTopToBottomRegardlessOfInputOrder() {
        let bottom = obs("second line", x: 0.1, y: 0.2)
        let top = obs("first line", x: 0.1, y: 0.8)
        #expect(TextAssembler.joinedText(from: [bottom, top]) == "first line\nsecond line")
    }

    @Test func fragmentsOnTheSameVisualLineJoinLeftToRight() {
        let right = obs("right", x: 0.6, y: 0.5)
        let left = obs("left", x: 0.1, y: 0.5)
        #expect(TextAssembler.joinedText(from: [right, left]) == "left right")
    }

    @Test func slightVerticalJitterStaysOnOneLine() {
        // Boxes overlap by 0.04 of their 0.05 height — same visual line.
        let a = obs("left", x: 0.1, y: 0.50)
        let b = obs("right", x: 0.4, y: 0.51)
        #expect(TextAssembler.joinedText(from: [b, a]) == "left right")
    }

    @Test func multiLineFixtureAssemblesCorrectly() {
        let observations = [
            obs("Zeile", x: 0.1, y: 0.4), // German: "line"
            obs("world", x: 0.35, y: 0.7),
            obs("dritte", x: 0.1, y: 0.1),
            obs("hello", x: 0.1, y: 0.7),
            obs("zweite", x: 0.35, y: 0.4),
        ]
        #expect(TextAssembler.joinedText(from: observations) == "hello world\nZeile zweite\ndritte")
    }

    @Test func trimsTrailingWhitespace() {
        let line = obs("hello   ", x: 0.1, y: 0.5)
        #expect(TextAssembler.joinedText(from: [line]) == "hello")
    }

    @Test func emptyInputYieldsEmptyString() {
        #expect(TextAssembler.joinedText(from: []) == "")
        #expect(TextAssembler.joinedText(from: [obs("", x: 0.1, y: 0.5)]) == "")
    }

    @Test func previewCollapsesNewlinesToOneLine() {
        #expect(TextAssembler.preview(of: "a\nb\nc") == "a b c")
    }

    @Test func previewTruncatesLongTextWithEllipsis() {
        let long = String(repeating: "x", count: 200)
        let preview = TextAssembler.preview(of: long, maxLength: 80)
        #expect(preview.count == 81)
        #expect(preview.hasSuffix("…"))
    }

    @Test func previewLeavesShortTextUntouched() {
        #expect(TextAssembler.preview(of: "short") == "short")
    }
}

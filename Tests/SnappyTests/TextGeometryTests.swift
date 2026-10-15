import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Snappy

@Suite struct TextGeometryTests {
    @Test func fontSizeDerivesFromStrokeWidthWithAFloor() {
        #expect(TextGeometry.fontSize(strokeWidth: 3) == 18)
        #expect(TextGeometry.fontSize(strokeWidth: 8) == 48)
        #expect(TextGeometry.fontSize(strokeWidth: 0.5) == 8)
    }

    @Test func measureReturnsPositiveBoundsForText() {
        let metrics = TextGeometry.measure("Hello", fontSize: 24)
        #expect(metrics.size.width > 0)
        #expect(metrics.size.height > 0)
        #expect(metrics.ascent > 0)
        #expect(metrics.size.height == metrics.ascent + metrics.descent)
    }

    @Test func measureGrowsWithTextAndFontSize() {
        let short = TextGeometry.measure("Hi", fontSize: 24)
        let long = TextGeometry.measure("Hi there", fontSize: 24)
        #expect(long.size.width > short.size.width)

        let small = TextGeometry.measure("Hi", fontSize: 12)
        #expect(short.size.width > small.size.width)
        #expect(short.size.height > small.size.height)
    }

    @Test func emptyTextMeasuresZero() {
        let metrics = TextGeometry.measure("", fontSize: 24)
        #expect(metrics.size == .zero)
    }

    @Test func annotationBoundingRectFollowsOriginAndText() {
        let style = AnnotationStyle(strokeColor: .red, strokeWidth: 4, hasFill: false)
        let text = TextAnnotation(
            id: UUID(), origin: CGPoint(x: 10, y: 20), text: "Hello", style: style
        )
        let rect = text.boundingRect
        #expect(rect.origin == CGPoint(x: 10, y: 20))
        #expect(rect.size == TextGeometry.measure("Hello", fontSize: text.fontSize).size)
    }

    @Test func boldFontIsBoldAndCachedSeparately() {
        let regular = TextGeometry.font(ofSize: 20)
        let bold = TextGeometry.font(ofSize: 20, bold: true)
        #expect(!CTFontGetSymbolicTraits(regular).contains(.traitBold))
        #expect(CTFontGetSymbolicTraits(bold).contains(.traitBold))
        #expect(CTFontGetSymbolicTraits(TextGeometry.font(ofSize: 20)).contains(.traitBold) == false)
    }
}

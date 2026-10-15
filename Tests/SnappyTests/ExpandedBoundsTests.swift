import CoreGraphics
import Foundation
import Testing
@testable import Snappy

/// `Annotation.expandedBounds` drives the auto-expanding canvas (M-F): it must
/// cover the annotation's *painted* extent so the canvas never clips it.
@Suite struct ExpandedBoundsTests {
    private func style(width: CGFloat) -> AnnotationStyle {
        AnnotationStyle(strokeColor: .red, strokeWidth: width, hasFill: false)
    }

    @Test func shapeGrowsByHalfStroke() {
        let shape = Annotation.shape(ShapeAnnotation(
            id: UUID(), kind: .rectangle,
            rect: CGRect(x: 10, y: 10, width: 20, height: 20), style: style(width: 8)
        ))
        #expect(shape.expandedBounds == CGRect(x: 6, y: 6, width: 28, height: 28))
    }

    @Test func arrowGrowsByArrowheadFlare() {
        let arrow = ArrowAnnotation(
            id: UUID(), tail: CGPoint(x: 0, y: 0), head: CGPoint(x: 100, y: 0), style: style(width: 4)
        )
        let inset = ArrowGeometry.maxHalfWidth(strokeWidth: 4)
        let expected = arrow.boundingRect.insetBy(dx: -inset, dy: -inset)
        #expect(Annotation.arrow(arrow).expandedBounds == expected)
        // The flare is much wider than a half-stroke — the head must not clip.
        #expect(inset > 4)
    }

    @Test func lineGrowsByHalfStrokeOnly() {
        let line = ArrowAnnotation(
            id: UUID(), tail: CGPoint(x: 0, y: 0), head: CGPoint(x: 100, y: 0),
            style: style(width: 6), kind: .line
        )
        #expect(Annotation.arrow(line).expandedBounds == line.boundingRect.insetBy(dx: -3, dy: -3))
    }

    @Test func textCounterEffectUsePlainBounds() {
        let text = Annotation.text(TextAnnotation(
            id: UUID(), origin: CGPoint(x: 5, y: 5), text: "Hi", style: style(width: 4)
        ))
        #expect(text.expandedBounds == text.boundingRect)

        let counter = Annotation.counter(CounterAnnotation(
            id: UUID(), center: CGPoint(x: 20, y: 20), style: style(width: 6)
        ))
        #expect(counter.expandedBounds == counter.boundingRect)

        let effect = Annotation.effect(EffectAnnotation(
            id: UUID(), kind: .blur, rect: CGRect(x: 0, y: 0, width: 10, height: 10), style: style(width: 4)
        ))
        #expect(effect.expandedBounds == effect.boundingRect)
    }
}

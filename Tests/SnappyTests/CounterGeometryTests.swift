import CoreGraphics
import Foundation
import Testing
@testable import Snappy

@Suite struct CounterGeometryTests {
    private static let style = AnnotationStyle(strokeColor: .red, strokeWidth: 6, hasFill: false)

    private static func badge(x: CGFloat) -> CounterAnnotation {
        CounterAnnotation(id: UUID(), center: CGPoint(x: x, y: 0), style: style)
    }

    // The M6 requirement: 1,2,3,4 → delete the second → 1,2,3.
    @Test func deletingAMiddleBadgeRenumbersTheRest() {
        let badges = (0..<4).map { Self.badge(x: CGFloat($0) * 10) }
        var annotations: [Annotation] = badges.map { .counter($0) }
        // A non-counter annotation in between must not consume a number.
        annotations.insert(
            .shape(ShapeAnnotation(id: UUID(), kind: .oval, rect: .zero, style: Self.style)), at: 2
        )

        var numbers = CounterGeometry.numbers(in: annotations)
        #expect(badges.map { numbers[$0.id] } == [1, 2, 3, 4])

        annotations.removeAll { $0.id == badges[1].id }
        numbers = CounterGeometry.numbers(in: annotations)
        #expect(numbers[badges[0].id] == 1)
        #expect(numbers[badges[2].id] == 2)
        #expect(numbers[badges[3].id] == 3)
        #expect(numbers[badges[1].id] == nil)
    }

    @Test func radiusScalesWithStrokeWidthAndHasAFloor() {
        #expect(CounterGeometry.radius(strokeWidth: 6) == 18)
        #expect(CounterGeometry.radius(strokeWidth: 12) == 36)
        #expect(CounterGeometry.radius(strokeWidth: 0.5) == 8) // floor for hairlines
    }

    @Test func digitsAreLargeEnoughAtTheDefaultSize() {
        // Default 3 pt width at 2x = 6 px stroke → 18 px radius → 21.6 px
        // digits = 10.8 pt, above the HIG's 10 pt macOS minimum.
        let radius = CounterGeometry.radius(strokeWidth: 6)
        #expect(CounterGeometry.fontSize(radius: radius) / 2 >= 10)
        // Two digits still fit inside the disc.
        let digits = TextGeometry.measure("99", fontSize: CounterGeometry.fontSize(radius: radius), bold: true)
        #expect(digits.size.width < radius * 2 * 0.9)
    }

    @Test func longNumbersShrinkToFitTheDisc() {
        let radius = CounterGeometry.radius(strokeWidth: 6) // 18 px, the 2x default
        // Two digits keep the full size.
        #expect(CounterGeometry.fontSize(for: "99", radius: radius) == CounterGeometry.fontSize(radius: radius))
        for label in ["100", "999", "1000"] {
            let size = CounterGeometry.fontSize(for: label, radius: radius)
            #expect(size < CounterGeometry.fontSize(radius: radius))
            let width = TextGeometry.measure(label, fontSize: size, bold: true).size.width
            #expect(width <= 2 * radius * CounterGeometry.maxLabelWidthFraction + 0.01)
        }
    }

    @Test func hitTestsTheDisc() {
        let center = CGPoint(x: 50, y: 50)
        #expect(CounterGeometry.hits(CGPoint(x: 55, y: 50), center: center, radius: 10, tolerance: 2))
        #expect(CounterGeometry.hits(CGPoint(x: 61, y: 50), center: center, radius: 10, tolerance: 2))
        #expect(!CounterGeometry.hits(CGPoint(x: 63, y: 50), center: center, radius: 10, tolerance: 2))
    }

    @Test func boundingRectIsCenteredOnTheBadge() {
        let badge = Self.badge(x: 40)
        let rect = badge.boundingRect
        #expect(rect.midX == 40)
        #expect(rect.midY == 0)
        #expect(rect.width == badge.radius * 2)
    }
}

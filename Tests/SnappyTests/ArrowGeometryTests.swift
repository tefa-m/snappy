import CoreGraphics
import Foundation
import Testing
@testable import Snappy

@Suite struct ArrowGeometryTests {
    private let style = AnnotationStyle(
        strokeColor: .red, strokeWidth: 4, hasFill: false
    )

    /// Arrows pointing into all four quadrants from the origin.
    private let quadrantHeads = [
        CGPoint(x: 100, y: 60), CGPoint(x: -100, y: 60),
        CGPoint(x: -100, y: -60), CGPoint(x: 100, y: -60),
    ]

    private func expectClose(
        _ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 0.001,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            hypot(a.x - b.x, a.y - b.y) <= tolerance,
            "\(a) is not within \(tolerance) of \(b)",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Straight polygon

    @Test func apexIsExactlyTheHeadInAllQuadrants() {
        for head in quadrantHeads {
            let polygon = ArrowGeometry.polygon(tail: .zero, head: head, strokeWidth: 4)
            #expect(polygon.count == 7)
            #expect(polygon[3] == head)
        }
    }

    @Test func everyOutlinePointLiesBehindTheHead() {
        for head in quadrantHeads {
            let length = hypot(head.x, head.y)
            let dir = CGVector(dx: head.x / length, dy: head.y / length)
            let polygon = ArrowGeometry.polygon(tail: .zero, head: head, strokeWidth: 4)
            for (index, p) in polygon.enumerated() where index != 3 {
                let along = (p.x - head.x) * dir.dx + (p.y - head.y) * dir.dy
                #expect(along < 0)
            }
        }
    }

    @Test func taperGrowsFromTailToShaftToBarbs() {
        // Horizontal arrow: widths are pure y-differences.
        let polygon = ArrowGeometry.polygon(
            tail: .zero, head: CGPoint(x: 200, y: 0), strokeWidth: 4
        )
        let tailWidth = abs(polygon[0].y - polygon[6].y)
        let shaftWidth = abs(polygon[1].y - polygon[5].y)
        let barbWidth = abs(polygon[2].y - polygon[4].y)
        #expect(tailWidth < shaftWidth)
        #expect(shaftWidth < barbWidth)
        // Polygon width 1.7 × strokeWidth + the renderer's 0.3 × rounding
        // stroke = 2.0 × strokeWidth visible at the head end (M-D beef-up).
        #expect(shaftWidth == 6.8)
        #expect(ArrowGeometry.edgeRounding(strokeWidth: 4) == 1.2)
    }

    @Test func headScalesWithStrokeWidth() {
        let thin = ArrowGeometry.polygon(tail: .zero, head: CGPoint(x: 200, y: 0), strokeWidth: 4)
        let thick = ArrowGeometry.polygon(tail: .zero, head: CGPoint(x: 200, y: 0), strokeWidth: 8)
        let thinBarb = abs(thin[2].y - thin[4].y)
        let thickBarb = abs(thick[2].y - thick[4].y)
        #expect(thickBarb == 2 * thinBarb)
        // Head length doubles too (distance from barb base to apex).
        #expect(200 - thick[2].x == 2 * (200 - thin[2].x))
    }

    @Test func shortArrowShrinksTheHeadProportionally() {
        // Length 20 caps the head at 45% of the arrow: 9 long, 4.05 half-wide.
        let polygon = ArrowGeometry.polygon(
            tail: .zero, head: CGPoint(x: 20, y: 0), strokeWidth: 8
        )
        #expect(polygon[2] == CGPoint(x: 11, y: 4.05))
    }

    @Test func degenerateArrowHasNoPolygon() {
        let point = CGPoint(x: 5, y: 5)
        #expect(ArrowGeometry.polygon(tail: point, head: point, strokeWidth: 4).isEmpty)
    }

    // MARK: - The bow scalar and its curve

    @Test func zeroBowIsExactlyTheStraightPolygon() {
        for head in quadrantHeads {
            let straight = ArrowGeometry.polygon(tail: .zero, head: head, strokeWidth: 4)
            let explicit = ArrowGeometry.polygon(tail: .zero, head: head, bow: 0, strokeWidth: 4)
            #expect(explicit == straight)
        }
    }

    @Test func curveMidpointSitsExactlyBowOffTheChordInAllQuadrants() {
        for head in quadrantHeads {
            for bow: CGFloat in [25, -25] {
                let mid = ArrowGeometry.point(onCurve: 0.5, tail: .zero, head: head, bow: bow)
                let chordMid = CGPoint(x: head.x / 2, y: head.y / 2)
                // Distance from the chord midpoint equals |bow| …
                #expect(abs(hypot(mid.x - chordMid.x, mid.y - chordMid.y) - abs(bow)) < 0.001)
                // … and lies on the chord normal with the bow's sign.
                let length = hypot(head.x, head.y)
                let normal = CGVector(dx: -head.y / length, dy: head.x / length)
                let projected = (mid.x - chordMid.x) * normal.dx + (mid.y - chordMid.y) * normal.dy
                #expect(abs(projected - bow) < 0.001)
            }
        }
    }

    @Test func curvedHeadSitsOnTheEndTangentWithApexAtHead() {
        let tail = CGPoint.zero, head = CGPoint(x: 100, y: 0)
        let bow: CGFloat = 30
        let outline = ArrowGeometry.polygon(tail: tail, head: head, bow: bow, strokeWidth: 4)
        #expect(outline.count > 7) // flattened spine, not the 7-point shape

        let apexIndex = outline.firstIndex(of: head)
        #expect(apexIndex != nil)
        guard let apexIndex else { return }

        // The barbs straddle the head base, which lies on the end tangent.
        let barbA = outline[apexIndex - 1], barbB = outline[apexIndex + 1]
        let base = CGPoint(x: (barbA.x + barbB.x) / 2, y: (barbA.y + barbB.y) / 2)
        let t = ArrowGeometry.tangent(at: 1, tail: tail, head: head, bow: bow)
        let tLength = hypot(t.dx, t.dy)
        let unit = CGVector(dx: t.dx / tLength, dy: t.dy / tLength)
        let headLength: CGFloat = 6.0 * 4 // headLengthFactor × strokeWidth, uncapped here
        expectClose(
            base,
            CGPoint(x: head.x - unit.dx * headLength, y: head.y - unit.dy * headLength),
            tolerance: 0.5
        )
    }

    @Test func bowProjectionIgnoresAlongChordDragAndKeepsSign() {
        let tail = CGPoint.zero, head = CGPoint(x: 100, y: 0)
        #expect(ArrowGeometry.bow(forDragPoint: CGPoint(x: 70, y: 30), tail: tail, head: head) == 30)
        #expect(ArrowGeometry.bow(forDragPoint: CGPoint(x: 20, y: 30), tail: tail, head: head) == 30)
        #expect(ArrowGeometry.bow(forDragPoint: CGPoint(x: 50, y: -30), tail: tail, head: head) == -30)
    }

    @Test func snappedBowReturnsLiteralZeroInsideTheSnapZone() {
        let tail = CGPoint.zero, head = CGPoint(x: 100, y: 0)
        #expect(ArrowGeometry.snappedBow(forDragPoint: CGPoint(x: 50, y: 3), tail: tail, head: head) == 0)
        #expect(ArrowGeometry.snappedBow(forDragPoint: CGPoint(x: 50, y: 5), tail: tail, head: head) == 5)
    }

    @Test func withBowClampsToThreeQuartersOfTheChord() {
        let arrow = ArrowAnnotation(
            id: UUID(), tail: .zero, head: CGPoint(x: 100, y: 0), style: style
        )
        #expect(arrow.withBow(200).bow == 75)
        #expect(arrow.withBow(-200).bow == -75)
        #expect(arrow.withBow(10).bow == 10)
    }

    @Test func curvedHitTestFollowsTheBulgeNotTheChord() {
        let tail = CGPoint.zero, head = CGPoint(x: 100, y: 0)
        // On the bulge (the curve midpoint): hit.
        #expect(ArrowGeometry.hits(
            CGPoint(x: 50, y: 40), tail: tail, head: head, bow: 40, strokeWidth: 4, tolerance: 2
        ))
        // On the chord midpoint, far below the curve: miss.
        #expect(!ArrowGeometry.hits(
            CGPoint(x: 50, y: 0), tail: tail, head: head, bow: 40, strokeWidth: 4, tolerance: 2
        ))
    }

    @Test func boundingRectContainsTheBulge() {
        let rect = ArrowGeometry.boundingRect(tail: .zero, head: CGPoint(x: 100, y: 0), bow: 40)
        #expect(abs(rect.maxY - 40) < 0.001)
        #expect(rect.minX == 0 && rect.maxX == 100 && rect.minY == 0)

        let negative = ArrowGeometry.boundingRect(tail: .zero, head: CGPoint(x: 100, y: 0), bow: -40)
        #expect(abs(negative.minY + 40) < 0.001)
    }

    // MARK: - Shaft hit-testing (straight)

    @Test func segmentDistanceMeasuresPerpendicularAndEndpointDistance() {
        let a = CGPoint.zero, b = CGPoint(x: 10, y: 0)
        #expect(ArrowGeometry.segmentDistance(from: CGPoint(x: 5, y: 3), to: a, b) == 3)
        #expect(ArrowGeometry.segmentDistance(from: CGPoint(x: 15, y: 0), to: a, b) == 5)
        #expect(ArrowGeometry.segmentDistance(from: CGPoint(x: 3, y: 4), to: a, a) == 5)
    }

    @Test func shaftHitsWithinToleranceAndMissesBeyond() {
        let tail = CGPoint(x: 10, y: 50), head = CGPoint(x: 90, y: 50)
        // Max half-width = 0.45 × min(6×4, 0.45×80) = 10.8, tolerance 2 → 12.8.
        #expect(ArrowGeometry.hits(
            CGPoint(x: 50, y: 55), tail: tail, head: head, strokeWidth: 4, tolerance: 2
        ))
        #expect(!ArrowGeometry.hits(
            CGPoint(x: 50, y: 64), tail: tail, head: head, strokeWidth: 4, tolerance: 2
        ))
        #expect(!ArrowGeometry.hits(
            CGPoint(x: 120, y: 50), tail: tail, head: head, strokeWidth: 4, tolerance: 2
        ))
    }

    // MARK: - Handles

    @Test func handleHitFindsTheNearestOfThreeWithinRadius() {
        let tail = CGPoint.zero, head = CGPoint(x: 100, y: 0)
        let bend = CGPoint(x: 50, y: 20)
        #expect(ArrowGeometry.handleHit(
            at: CGPoint(x: 2, y: 3), tail: tail, head: head, bend: bend, radius: 7
        ) == .tail)
        #expect(ArrowGeometry.handleHit(
            at: CGPoint(x: 98, y: -3), tail: tail, head: head, bend: bend, radius: 7
        ) == .head)
        #expect(ArrowGeometry.handleHit(
            at: CGPoint(x: 48, y: 18), tail: tail, head: head, bend: bend, radius: 7
        ) == .bend)
        #expect(ArrowGeometry.handleHit(
            at: CGPoint(x: 50, y: 50), tail: tail, head: head, bend: bend, radius: 7
        ) == nil)
    }

    @Test func lineWithoutBendHandleNeverReportsBend() {
        let tail = CGPoint.zero, head = CGPoint(x: 100, y: 0)
        // The exact curve midpoint of a straight chord — with bend: nil the
        // nearest handle is an endpoint, out of radius here.
        #expect(ArrowGeometry.handleHit(
            at: CGPoint(x: 50, y: 0), tail: tail, head: head, bend: nil, radius: 7
        ) == nil)
    }

    @Test func movingOneEndpointKeepsTheOtherFixedAndPreservesTheBow() {
        let arrow = ArrowAnnotation(
            id: UUID(), tail: CGPoint(x: 10, y: 20), head: CGPoint(x: 80, y: 90), style: style
        ).withBow(20)
        let movedTail = arrow.movingEndpoint(.tail, to: CGPoint(x: 0, y: 0))
        #expect(movedTail.tail == .zero)
        #expect(movedTail.head == arrow.head)
        #expect(movedTail.bow == 20)

        let movedHead = arrow.movingEndpoint(.head, to: CGPoint(x: 100, y: 100))
        #expect(movedHead.head == CGPoint(x: 100, y: 100))
        #expect(movedHead.tail == arrow.tail)
        #expect(movedHead.bow == 20)

        // .bend is a documented no-op for movingEndpoint.
        #expect(arrow.movingEndpoint(.bend, to: .zero) == arrow)
    }

    @Test func movingAnEndpointReclampsTheBowToTheNewChord() {
        let arrow = ArrowAnnotation(
            id: UUID(), tail: CGPoint(x: 0, y: 0), head: CGPoint(x: 100, y: 0), style: style
        ).withBow(70) // within 0.75 × 100
        #expect(arrow.bow == 70)

        // Shorten the chord to 20 → the bow may be at most 0.75 × 20 = 15.
        let shortened = arrow.movingEndpoint(.head, to: CGPoint(x: 20, y: 0))
        #expect(abs(shortened.bow - 15) < 1e-9)

        // Sign is preserved when clamping.
        let negative = ArrowAnnotation(
            id: UUID(), tail: CGPoint(x: 0, y: 0), head: CGPoint(x: 100, y: 0), style: style
        ).withBow(-70)
        #expect(abs(negative.movingEndpoint(.tail, to: CGPoint(x: 80, y: 0)).bow + 15) < 1e-9)

        // A straight line (bow 0) is unaffected.
        let line = ArrowAnnotation(
            id: UUID(), tail: .zero, head: CGPoint(x: 50, y: 50), style: style, kind: .line
        )
        #expect(line.movingEndpoint(.head, to: CGPoint(x: 5, y: 5)).bow == 0)
    }

    // MARK: - Whole-arrow move

    @Test func movedArrowClampsToBoundsWithoutChangingItsShape() {
        let arrow = Annotation.arrow(ArrowAnnotation(
            id: UUID(), tail: CGPoint(x: 10, y: 10), head: CGPoint(x: 60, y: 40), style: style
        ))
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let moved = arrow.moved(by: CGVector(dx: 1000, dy: -1000), within: bounds)
        guard case .arrow(let result) = moved else {
            Issue.record("expected an arrow")
            return
        }
        #expect(result.tail == CGPoint(x: 50, y: 0))
        #expect(result.head == CGPoint(x: 100, y: 30))
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import Snappy

@Suite struct FreehandGeometryTests {
    private let zigzag = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 10, y: 20),
        CGPoint(x: 20, y: -5),
        CGPoint(x: 30, y: 10),
        CGPoint(x: 40, y: 0),
    ]

    @Test func smoothingPreservesEndpointsAndContinuity() throws {
        let segments = FreehandGeometry.smoothedSegments(zigzag)
        #expect(try #require(segments.first).start == zigzag.first)
        #expect(try #require(segments.last).end == zigzag.last)
        for (a, b) in zip(segments, segments.dropFirst()) {
            #expect(a.end == b.start)
        }
    }

    // Quadratic curves stay inside the convex hull of their defining points,
    // so it suffices that every defining point stays inside the input's
    // bounding box — the smoothed path cannot spike outside it.
    @Test func smoothingStaysInsideTheInputBoundingBox() {
        let xs = zigzag.map(\.x), ys = zigzag.map(\.y)
        let box = CGRect(
            x: xs.min()!, y: ys.min()!,
            width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!
        )
        for segment in FreehandGeometry.smoothedSegments(zigzag) {
            for p in [segment.start, segment.control, segment.end] {
                #expect(box.insetBy(dx: -0.001, dy: -0.001).contains(p))
            }
        }
    }

    @Test func fewPointsDegradeGracefully() {
        #expect(FreehandGeometry.smoothedSegments([]).isEmpty)
        #expect(FreehandGeometry.smoothedSegments([CGPoint(x: 1, y: 1)]).isEmpty)

        let pair = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        let segments = FreehandGeometry.smoothedSegments(pair)
        #expect(segments.count == 1)
        #expect(segments[0].start == pair[0])
        #expect(segments[0].end == pair[1])
    }

    @Test func smoothingIsStableForAFixture() {
        // Same input → same output (pure function, no hidden state).
        #expect(FreehandGeometry.smoothedSegments(zigzag) == FreehandGeometry.smoothedSegments(zigzag))
    }

    @Test func hitTestsThePolyline() {
        // Near the first segment (0,0)→(10,20): hit.
        #expect(FreehandGeometry.hits(
            CGPoint(x: 5, y: 10), points: zigzag, strokeWidth: 4, tolerance: 2
        ))
        // Far from every segment: miss.
        #expect(!FreehandGeometry.hits(
            CGPoint(x: 20, y: 40), points: zigzag, strokeWidth: 4, tolerance: 2
        ))
        // A single-point stroke hits only near that point.
        let dot = [CGPoint(x: 5, y: 5)]
        #expect(FreehandGeometry.hits(CGPoint(x: 6, y: 6), points: dot, strokeWidth: 4, tolerance: 2))
        #expect(!FreehandGeometry.hits(CGPoint(x: 15, y: 5), points: dot, strokeWidth: 4, tolerance: 2))
    }
}

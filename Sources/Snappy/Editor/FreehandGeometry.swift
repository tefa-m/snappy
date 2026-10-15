import CoreGraphics
import Foundation

/// Pure geometry for the freehand pen (M6): point thinning while drawing,
/// midpoint-quadratic smoothing for rendering, and polyline hit-testing.
/// All lengths are in the same units as the points (image pixels).
enum FreehandGeometry {

    /// Minimum distance between recorded drag points, in view points — the
    /// canvas converts to image pixels. Thinning keeps the model small and the
    /// smoothed path stable.
    static let minSampleDistanceInView: CGFloat = 2

    /// One quadratic Bézier segment of the smoothed stroke.
    struct QuadSegment: Equatable {
        var start: CGPoint
        var control: CGPoint
        var end: CGPoint
    }

    /// Classic midpoint smoothing: curve through consecutive midpoints using
    /// the recorded points as controls. Endpoints are preserved exactly; every
    /// segment stays inside the convex hull of its three defining points, so
    /// the smoothed path never spikes outside the input's bounding box.
    /// Fewer than 3 points yield a single straight segment.
    static func smoothedSegments(_ points: [CGPoint]) -> [QuadSegment] {
        guard points.count >= 2 else { return [] }
        guard points.count >= 3 else {
            let mid = midpoint(points[0], points[1])
            return [QuadSegment(start: points[0], control: mid, end: points[1])]
        }
        var segments: [QuadSegment] = []
        var start = points[0]
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let end = index == points.count - 2
                ? points[index + 1]
                : midpoint(control, points[index + 1])
            segments.append(QuadSegment(start: start, control: control, end: end))
            start = end
        }
        return segments
    }

    static func path(for points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        let segments = smoothedSegments(points)
        guard let first = segments.first else {
            if let only = points.first {
                path.move(to: only)
                path.addLine(to: only)
            }
            return path
        }
        path.move(to: first.start)
        for segment in segments {
            path.addQuadCurve(to: segment.end, control: segment.control)
        }
        return path
    }

    /// Hit-tests a point against the raw polyline (good enough — smoothing
    /// stays within the hull of neighboring points).
    static func hits(
        _ point: CGPoint, points: [CGPoint], strokeWidth: CGFloat, tolerance: CGFloat
    ) -> Bool {
        guard !points.isEmpty else { return false }
        let reach = tolerance + strokeWidth / 2
        if points.count == 1 {
            return hypot(point.x - points[0].x, point.y - points[0].y) <= reach
        }
        for index in 0..<(points.count - 1) {
            if ArrowGeometry.segmentDistance(from: point, to: points[index], points[index + 1]) <= reach {
                return true
            }
        }
        return false
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

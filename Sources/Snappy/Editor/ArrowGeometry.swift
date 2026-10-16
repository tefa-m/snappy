import CoreGraphics
import Foundation

/// Pure geometry for the arrow tool (M5, curved in Post-MVP M-D): the tapered
/// arrow outline (straight or bowed), the quadratic curve the bow defines,
/// shaft hit-testing, and handle hits. All lengths are in the same units as
/// the endpoints (image pixels). Never inline this math in UI code
/// (see docs/ARCHITECTURE.md).
///
/// The bend is a scalar `bow`: the signed perpendicular displacement of the
/// curve MIDPOINT from the chord midpoint. The quadratic Bézier control point
/// is `M + 2·bow·n̂` (the factor 2 puts the on-curve midpoint exactly `bow`
/// off the chord), so `bow == 0` is exactly the straight arrow.
enum ArrowGeometry {

    // Proportions of the tapered arrow, relative to strokeWidth (the shaft
    // thickness at the head end). Tuned for a clean look: a thin tail growing
    // into a full-width shaft that flares into a filled triangular head.
    // Post-MVP M-D made the arrow beefier: bigger head, thicker head-end shaft.
    private static let headLengthFactor: CGFloat = 6.0
    /// Arrowhead half-width as a fraction of its length (barb flare).
    private static let headWidthRatio: CGFloat = 0.45
    /// Shaft half-width at the head end, as a fraction of strokeWidth. The
    /// renderer adds a round-join stroke of `edgeRounding` on top (rounded
    /// edges), so the VISIBLE shaft width is (2 × 0.85 + 0.3) × strokeWidth =
    /// 2.0 × strokeWidth — thickening toward the head (author feedback).
    private static let shaftWidthFactor: CGFloat = 0.85
    /// Tail half-width as a fraction of strokeWidth (the "ergonomic" taper).
    private static let tailWidthFactor: CGFloat = 0.08
    /// Head length is capped to this fraction of the arrow, so short arrows
    /// shrink the head proportionally instead of degenerating.
    private static let maxHeadLengthRatio: CGFloat = 0.45
    /// Flattening resolution for curved arrows (number of curve segments).
    private static let curveSegments = 32
    /// Bend drags snap the bow to 0 (perfectly straight) below this offset
    /// (image px) — dragging the bend handle back to the chord is guaranteed
    /// to restore a straight arrow.
    static let bowSnapThreshold: CGFloat = 4

    // MARK: - The quadratic curve defined by (tail, head, bow)

    /// Control point of the quadratic Bézier: chord midpoint + 2·bow·n̂.
    static func controlPoint(tail: CGPoint, head: CGPoint, bow: CGFloat) -> CGPoint {
        let mid = CGPoint(x: (tail.x + head.x) / 2, y: (tail.y + head.y) / 2)
        guard let n = chordNormal(tail: tail, head: head) else { return mid }
        return CGPoint(x: mid.x + 2 * bow * n.dx, y: mid.y + 2 * bow * n.dy)
    }

    /// Point on the curve at parameter `t` in 0…1 (t=0 tail, t=1 head).
    static func point(onCurve t: CGFloat, tail: CGPoint, head: CGPoint, bow: CGFloat) -> CGPoint {
        let control = controlPoint(tail: tail, head: head, bow: bow)
        let u = 1 - t
        return CGPoint(
            x: u * u * tail.x + 2 * u * t * control.x + t * t * head.x,
            y: u * u * tail.y + 2 * u * t * control.y + t * t * head.y
        )
    }

    /// Tangent (unnormalized derivative) of the curve at parameter `t`.
    static func tangent(at t: CGFloat, tail: CGPoint, head: CGPoint, bow: CGFloat) -> CGVector {
        let control = controlPoint(tail: tail, head: head, bow: bow)
        return CGVector(
            dx: 2 * (1 - t) * (control.x - tail.x) + 2 * t * (head.x - control.x),
            dy: 2 * (1 - t) * (control.y - tail.y) + 2 * t * (head.y - control.y)
        )
    }

    /// Unit normal of the chord (left of tail→head); nil for degenerate arrows.
    private static func chordNormal(tail: CGPoint, head: CGPoint) -> CGVector? {
        let length = hypot(head.x - tail.x, head.y - tail.y)
        guard length > 0.001 else { return nil }
        return CGVector(dx: -(head.y - tail.y) / length, dy: (head.x - tail.x) / length)
    }

    /// The signed bow that puts the curve midpoint at `point`: the projection
    /// of `point` onto the chord normal, measured from the chord midpoint.
    /// Along-chord drag components are ignored (1 degree of freedom), so
    /// dragging back to the chord always returns exactly to straight.
    static func bow(forDragPoint point: CGPoint, tail: CGPoint, head: CGPoint) -> CGFloat {
        guard let n = chordNormal(tail: tail, head: head) else { return 0 }
        let mid = CGPoint(x: (tail.x + head.x) / 2, y: (tail.y + head.y) / 2)
        return (point.x - mid.x) * n.dx + (point.y - mid.y) * n.dy
    }

    /// `bow(forDragPoint:)` with the snap-to-straight zone applied.
    static func snappedBow(forDragPoint point: CGPoint, tail: CGPoint, head: CGPoint) -> CGFloat {
        let raw = bow(forDragPoint: point, tail: tail, head: head)
        return abs(raw) < bowSnapThreshold ? 0 : raw
    }

    /// Bounding rect of the curve spine (chord rect for `bow == 0`), from the
    /// analytic extrema of the quadratic. Like the straight arrow's rect it
    /// ignores stroke widths — hit tolerance covers those.
    static func boundingRect(tail: CGPoint, head: CGPoint, bow: CGFloat) -> CGRect {
        var minX = min(tail.x, head.x), maxX = max(tail.x, head.x)
        var minY = min(tail.y, head.y), maxY = max(tail.y, head.y)
        if bow != 0 {
            let control = controlPoint(tail: tail, head: head, bow: bow)
            // Per axis, B'(t) = 0 at t = (p0 − p1) / (p0 − 2p1 + p2).
            func extremum(_ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat? {
                let denominator = p0 - 2 * p1 + p2
                guard abs(denominator) > 0.0001 else { return nil }
                let t = (p0 - p1) / denominator
                guard t > 0, t < 1 else { return nil }
                let u = 1 - t
                return u * u * p0 + 2 * u * t * p1 + t * t * p2
            }
            if let x = extremum(tail.x, control.x, head.x) {
                minX = min(minX, x); maxX = max(maxX, x)
            }
            if let y = extremum(tail.y, control.y, head.y) {
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Outline polygon

    /// The filled outline of an arrow from `tail` to `head`. For `bow == 0`
    /// this is the exact 7-point construction: [tail edge, shaft edge, barb,
    /// apex (= head), barb, shaft edge, tail edge]. For a bowed arrow the
    /// spine follows the flattened curve with the same tail→shaft taper, and
    /// the head sits on the END TANGENT of the curve, so the arrowhead always
    /// points where the curve arrives. Empty when the arrow is degenerate.
    static func polygon(
        tail: CGPoint, head: CGPoint, bow: CGFloat = 0, strokeWidth: CGFloat
    ) -> [CGPoint] {
        let chord = hypot(head.x - tail.x, head.y - tail.y)
        guard chord > 0.001 else { return [] }
        let width = max(strokeWidth, 1)

        guard bow != 0 else {
            return straightPolygon(tail: tail, head: head, chord: chord, width: width)
        }

        // Flatten the curve and measure arc lengths.
        let samples = (0...curveSegments).map {
            point(onCurve: CGFloat($0) / CGFloat(curveSegments), tail: tail, head: head, bow: bow)
        }
        var arcLengths: [CGFloat] = [0]
        arcLengths.reserveCapacity(samples.count)
        for i in 1..<samples.count {
            let d = hypot(samples[i].x - samples[i - 1].x, samples[i].y - samples[i - 1].y)
            arcLengths.append(arcLengths[i - 1] + d)
        }
        let total = arcLengths[arcLengths.count - 1]
        guard total > 0.001 else { return [] }

        let headLength = min(headLengthFactor * width, maxHeadLengthRatio * total)
        let headHalf = headWidthRatio * headLength
        let shaftHalf = min(shaftWidthFactor * width, 0.8 * headHalf)
        let tailHalf = min(max(0.5, tailWidthFactor * width), shaftHalf)
        let spineLength = total - headLength

        // Spine samples up to arc length `spineLength`, ending with a point
        // interpolated exactly there (where the shaft meets the head).
        var spine: [CGPoint] = []
        for i in 0..<samples.count where arcLengths[i] < spineLength {
            spine.append(samples[i])
        }
        if let last = spine.indices.last {
            let nextIndex = last + 1
            let segment = arcLengths[nextIndex] - arcLengths[last]
            let t = segment > 0 ? (spineLength - arcLengths[last]) / segment : 0
            let a = samples[last], b = samples[nextIndex]
            spine.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        guard spine.count >= 2 else { return [] }

        // Per-sample unit normals, averaging adjacent segment directions.
        func normalized(_ v: CGVector) -> CGVector? {
            let length = hypot(v.dx, v.dy)
            guard length > 0.0001 else { return nil }
            return CGVector(dx: v.dx / length, dy: v.dy / length)
        }
        var normals: [CGVector] = []
        normals.reserveCapacity(spine.count)
        for i in spine.indices {
            let previous = spine[max(i - 1, 0)]
            let next = spine[min(i + 1, spine.count - 1)]
            let direction = normalized(CGVector(dx: next.x - previous.x, dy: next.y - previous.y))
                ?? CGVector(dx: 1, dy: 0)
            normals.append(CGVector(dx: -direction.dy, dy: direction.dx))
        }

        // Head on the end tangent, so the tip always points where the curve
        // arrives (requirement: arrowhead aligned with the final direction).
        let control = controlPoint(tail: tail, head: head, bow: bow)
        guard let endTangent = normalized(CGVector(dx: head.x - control.x, dy: head.y - control.y))
        else { return [] }
        let endNormal = CGVector(dx: -endTangent.dy, dy: endTangent.dx)
        let base = CGPoint(x: head.x - endTangent.dx * headLength, y: head.y - endTangent.dy * headLength)

        // Left side tail→base, arrowhead, right side base→tail.
        func halfWidth(at index: Int) -> CGFloat {
            let s = min(arcLengths[min(index, arcLengths.count - 1)], spineLength)
            return tailHalf + (shaftHalf - tailHalf) * (spineLength > 0 ? s / spineLength : 1)
        }
        var outline: [CGPoint] = []
        for i in spine.indices {
            let half = halfWidth(at: i)
            outline.append(CGPoint(x: spine[i].x + normals[i].dx * half, y: spine[i].y + normals[i].dy * half))
        }
        outline.append(CGPoint(x: base.x + endNormal.dx * headHalf, y: base.y + endNormal.dy * headHalf))
        outline.append(head)
        outline.append(CGPoint(x: base.x - endNormal.dx * headHalf, y: base.y - endNormal.dy * headHalf))
        for i in spine.indices.reversed() {
            let half = halfWidth(at: i)
            outline.append(CGPoint(x: spine[i].x - normals[i].dx * half, y: spine[i].y - normals[i].dy * half))
        }
        return outline
    }

    /// The exact M5 construction — `polygon` with `bow == 0` must stay
    /// bit-identical to the pre-bend arrow.
    private static func straightPolygon(
        tail: CGPoint, head: CGPoint, chord: CGFloat, width: CGFloat
    ) -> [CGPoint] {
        let dir = CGVector(dx: (head.x - tail.x) / chord, dy: (head.y - tail.y) / chord)
        let perp = CGVector(dx: -dir.dy, dy: dir.dx)

        let headLength = min(headLengthFactor * width, maxHeadLengthRatio * chord)
        let headHalf = headWidthRatio * headLength
        let shaftHalf = min(shaftWidthFactor * width, 0.8 * headHalf)
        let tailHalf = min(max(0.5, tailWidthFactor * width), shaftHalf)

        let base = CGPoint(x: head.x - dir.dx * headLength, y: head.y - dir.dy * headLength)

        func at(_ point: CGPoint, _ half: CGFloat) -> CGPoint {
            CGPoint(x: point.x + perp.dx * half, y: point.y + perp.dy * half)
        }
        return [
            at(tail, tailHalf),
            at(base, shaftHalf),
            at(base, headHalf),
            head,
            at(base, -headHalf),
            at(base, -shaftHalf),
            at(tail, -tailHalf),
        ]
    }

    /// Upper bound on the outline's half-width (image px), used to inflate an
    /// arrow's bounding rect so the auto-expanding canvas (M-F) contains the
    /// full arrowhead flare. The head half-width is `headWidthRatio ×
    /// headLength`, and `headLength ≤ headLengthFactor × strokeWidth`, plus half
    /// the round-join outset — a safe over-estimate for short arrows too.
    static func maxHalfWidth(strokeWidth: CGFloat) -> CGFloat {
        let width = max(strokeWidth, 1)
        return headWidthRatio * headLengthFactor * width + edgeRounding(strokeWidth: width) / 2
    }

    /// Width of the round-join/round-cap stroke the renderer draws around the
    /// polygon to give the arrow rounded edges. The polygon's half-widths are
    /// tuned with this outset (half of it per side) already accounted for.
    static func edgeRounding(strokeWidth: CGFloat) -> CGFloat {
        0.3 * max(strokeWidth, 1)
    }

    // MARK: - Hit-testing

    /// Distance from a point to the segment `a`–`b`.
    static func segmentDistance(from point: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * ab.dx + (point.y - a.y) * ab.dy) / lengthSquared, 0), 1)
        let nearest = CGPoint(x: a.x + ab.dx * t, y: a.y + ab.dy * t)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    /// Hit-tests a point against the arrow: within `tolerance` of the widest
    /// part of the outline, measured from the (flattened) spine.
    static func hits(
        _ point: CGPoint, tail: CGPoint, head: CGPoint, bow: CGFloat = 0,
        strokeWidth: CGFloat, tolerance: CGFloat
    ) -> Bool {
        let chord = hypot(head.x - tail.x, head.y - tail.y)
        guard chord > 0.001 else { return false }
        let width = max(strokeWidth, 1)

        if bow == 0 {
            let headLength = min(headLengthFactor * width, maxHeadLengthRatio * chord)
            let maxHalf = headWidthRatio * headLength
            return segmentDistance(from: point, to: tail, head) <= tolerance + maxHalf
        }

        let samples = (0...curveSegments).map {
            Self.point(onCurve: CGFloat($0) / CGFloat(curveSegments), tail: tail, head: head, bow: bow)
        }
        var distance = CGFloat.greatestFiniteMagnitude
        var total: CGFloat = 0
        for i in 1..<samples.count {
            distance = min(distance, segmentDistance(from: point, to: samples[i - 1], samples[i]))
            total += hypot(samples[i].x - samples[i - 1].x, samples[i].y - samples[i - 1].y)
        }
        let headLength = min(headLengthFactor * width, maxHeadLengthRatio * total)
        let maxHalf = headWidthRatio * headLength
        return distance <= tolerance + maxHalf
    }

    /// The handle within `radius` of `point`, nearest first; nil if none.
    /// `bend` is the bend handle's position (`point(onCurve: 0.5)`) — pass nil
    /// for lines, which have no bend handle. All points share one coordinate
    /// space (the canvas passes view points).
    static func handleHit(
        at point: CGPoint, tail: CGPoint, head: CGPoint, bend: CGPoint?, radius: CGFloat
    ) -> ArrowHandle? {
        var candidates: [(ArrowHandle, CGFloat)] = [
            (.tail, hypot(point.x - tail.x, point.y - tail.y)),
            (.head, hypot(point.x - head.x, point.y - head.y)),
        ]
        if let bend {
            candidates.append((.bend, hypot(point.x - bend.x, point.y - bend.y)))
        }
        let nearest = candidates.min { $0.1 < $1.1 }!
        return nearest.1 <= radius ? nearest.0 : nil
    }
}

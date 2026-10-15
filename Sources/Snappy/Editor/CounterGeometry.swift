import CoreGraphics
import Foundation

/// Pure geometry for counter badges (M6): badge radius from the stroke width,
/// derived numbering, and hit-testing.
enum CounterGeometry {

    /// Badge radius in the same units as strokeWidth (image pixels).
    static func radius(strokeWidth: CGFloat) -> CGFloat {
        max(8, 3 * strokeWidth)
    }

    /// Number font size for a badge of the given radius. 1.2 × radius puts
    /// the default badge (3 pt width → 9 pt radius) at 10.8 pt — above the
    /// HIG's 10 pt macOS minimum (1.1 × gave 9.9 pt); "99" still fits the
    /// disc. Digits render bold (see AnnotationRenderer).
    static func fontSize(radius: CGFloat) -> CGFloat {
        radius * 1.2
    }

    /// Widest the bold number may set: 80 % of the diameter. At that width a
    /// line 1.2 × radius tall keeps its ink inside the disc (the text box's
    /// corners sit at ~0.9 × radius from the centre), so the badge's declared
    /// bounds stay its painted bounds.
    static let maxLabelWidthFraction: CGFloat = 0.8

    /// Font size for the badge's actual number: `fontSize(radius:)`, shrunk
    /// just enough for 3+ digits ("100" in bold is ~1.08 × the diameter at
    /// the full size) to fit `maxLabelWidthFraction` of the diameter. The
    /// system font's optical sizing loosens tracking as it shrinks, so width is
    /// not proportional to size — re-measure until it fits (2–3 passes).
    static func fontSize(for label: String, radius: CGFloat) -> CGFloat {
        let maxWidth = 2 * radius * maxLabelWidthFraction
        var size = fontSize(radius: radius)
        for _ in 0..<6 {
            let width = TextGeometry.measure(label, fontSize: size, bold: true).size.width
            guard width > maxWidth else { break }
            size *= maxWidth / width * 0.99
        }
        return size
    }

    /// Displayed numbers, derived from each badge's order among the counter
    /// annotations in the array (z-order = creation order). Deleting a middle
    /// badge renumbers the rest automatically, and undo restores numbering
    /// because it restores order.
    static func numbers(in annotations: [Annotation]) -> [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        var next = 1
        for annotation in annotations {
            if case .counter(let badge) = annotation {
                numbers[badge.id] = next
                next += 1
            }
        }
        return numbers
    }

    static func hits(_ point: CGPoint, center: CGPoint, radius: CGFloat, tolerance: CGFloat) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= radius + tolerance
    }
}

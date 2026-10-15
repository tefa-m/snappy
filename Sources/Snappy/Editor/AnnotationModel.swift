import CoreGraphics
import Foundation

/// sRGB color as plain components so the model stays AppKit-free and testable.
struct AnnotationColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    func withAlpha(_ alpha: CGFloat) -> AnnotationColor {
        var color = self
        color.alpha = alpha
        return color
    }

    /// The default annotation color, #FF3B30. A fixed value on purpose: it is
    /// content that gets exported, so it must not follow the appearance the
    /// way NSColor.systemRed does (#FF383C light / #FF4245 dark on macOS 26).
    static let red = AnnotationColor(red: 1, green: 0.23, blue: 0.19)
    static let white = AnnotationColor(red: 1, green: 1, blue: 1)
    static let black = AnnotationColor(red: 0, green: 0, blue: 0)

    /// WCAG relative luminance (alpha ignored — annotations are opaque).
    var relativeLuminance: CGFloat {
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1…21.
    func contrastRatio(with other: AnnotationColor) -> CGFloat {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Digit colour for a counter badge filled with this colour. White by
    /// default (the conventional look), black once white drops under 3:1 —
    /// the WCAG/HIG minimum for bold text — so a yellow, green or white badge
    /// never loses its number.
    var badgeLabelColor: AnnotationColor {
        contrastRatio(with: .white) >= 3 ? .white : .black
    }
}

/// Visual style of an annotation. All lengths are in image pixels (the canvas
/// converts from view points), so canvas and export render identically.
/// strokeWidth also drives derived sizes: text font size (TextGeometry) and
/// counter badge radius (CounterGeometry).
struct AnnotationStyle: Equatable, Sendable {
    var strokeColor: AnnotationColor
    var strokeWidth: CGFloat
    /// Translucent highlight fill using the stroke color at `fillAlpha`.
    var hasFill: Bool

    static let fillAlpha: CGFloat = 0.2

    static func defaultStyle(scale: CGFloat) -> AnnotationStyle {
        AnnotationStyle(strokeColor: .red, strokeWidth: 3 * scale, hasFill: false)
    }
}

enum ShapeKind: Equatable, Sendable {
    case rectangle, oval
}

/// Rectangle / oval highlight. `rect` is in image-pixel coordinates with
/// origin bottom-left (CG convention), always standardized.
struct ShapeAnnotation: Equatable, Identifiable, Sendable {
    let id: UUID
    var kind: ShapeKind
    var rect: CGRect
    var style: AnnotationStyle
}

/// The three edit handles of a selected arrow: the two endpoints plus the
/// curve/bend handle at the curve midpoint (arrows only — lines have no bend).
enum ArrowHandle: Equatable, Sendable {
    case tail, head, bend
}

/// Rendering variants of the two-endpoint tool: a tapered arrow, or a plain
/// straight line ("arrow minus the head", M6).
enum ArrowKind: Equatable, Sendable {
    case arrow, line
}

/// Arrow or straight line drawn from `tail` to `head`, both in image-pixel
/// coordinates with origin bottom-left. Arrows render as a single filled
/// tapered polygon (thin at the tail, widening into the arrowhead) —
/// `style.strokeWidth` is the shaft thickness at the head end. Lines render as
/// a round-cap stroke of `strokeWidth`. `hasFill` does not apply to either.
struct ArrowAnnotation: Equatable, Identifiable, Sendable {
    let id: UUID
    var tail: CGPoint
    var head: CGPoint
    var style: AnnotationStyle
    var kind: ArrowKind = .arrow
    /// Signed perpendicular displacement (image px) of the CURVE MIDPOINT from
    /// the chord midpoint. A scalar (not a stored control point) so endpoint
    /// drags preserve the bend and `offset(by:)` needs no extra work;
    /// `bow == 0` is literally "straight". Lines never set it.
    var bow: CGFloat = 0

    var boundingRect: CGRect {
        ArrowGeometry.boundingRect(tail: tail, head: head, bow: bow)
    }

    /// Moves one endpoint, leaving the other fixed. The bow is preserved —
    /// it is relative to the chord — but re-clamped to the new chord length, so
    /// shortening a strongly bent arrow can't fold it back on itself. `.bend` is
    /// a documented no-op here: bend drags go through `withBow(_:)` instead.
    func movingEndpoint(_ handle: ArrowHandle, to point: CGPoint) -> ArrowAnnotation {
        var arrow = self
        switch handle {
        case .tail: arrow.tail = point
        case .head: arrow.head = point
        case .bend: break
        }
        return arrow.withBow(arrow.bow)
    }

    /// Returns the arrow with the bow set, clamped to ±0.75 × chord length so
    /// the curve can never fold back over itself.
    func withBow(_ bow: CGFloat) -> ArrowAnnotation {
        var arrow = self
        let limit = 0.75 * hypot(head.x - tail.x, head.y - tail.y)
        arrow.bow = min(max(bow, -limit), limit)
        return arrow
    }

    func offset(by delta: CGVector) -> ArrowAnnotation {
        var arrow = self
        arrow.tail = CGPoint(x: tail.x + delta.dx, y: tail.y + delta.dy)
        arrow.head = CGPoint(x: head.x + delta.dx, y: head.y + delta.dy)
        return arrow
    }
}

/// Single-line text label. `origin` is the bottom-left corner of the text's
/// bounding box in image pixels; the box size is derived from the text and the
/// font size (which is derived from `style.strokeWidth` — see TextGeometry),
/// so the model stores no redundant geometry.
struct TextAnnotation: Equatable, Identifiable, Sendable {
    let id: UUID
    var origin: CGPoint
    var text: String
    var style: AnnotationStyle

    var fontSize: CGFloat { TextGeometry.fontSize(strokeWidth: style.strokeWidth) }

    var boundingRect: CGRect {
        CGRect(origin: origin, size: TextGeometry.measure(text, fontSize: fontSize).size)
    }

    func offset(by delta: CGVector) -> TextAnnotation {
        var text = self
        text.origin = CGPoint(x: origin.x + delta.dx, y: origin.y + delta.dy)
        return text
    }
}

/// Freehand pen stroke: the raw drag points in image pixels. Rendering smooths
/// them into a quadratic-curve path (FreehandGeometry).
struct FreehandAnnotation: Equatable, Identifiable, Sendable {
    let id: UUID
    var points: [CGPoint]
    var style: AnnotationStyle

    var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func offset(by delta: CGVector) -> FreehandAnnotation {
        var stroke = self
        stroke.points = points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
        return stroke
    }
}

enum EffectKind: Equatable, Sendable {
    case blur, pixelate
}

/// Region of the base image rendered blurred / pixelated (CoreImage). The
/// effect strength is derived from the base image size at render time
/// (EffectRenderer), so the model stays a plain rect. Style is kept for
/// protocol uniformity but does not affect rendering.
struct EffectAnnotation: Equatable, Identifiable, Sendable {
    let id: UUID
    var kind: EffectKind
    var rect: CGRect
    var style: AnnotationStyle
}

/// Auto-numbered counter badge centered on `center`. The displayed number is
/// NOT stored — it is derived from the badge's order among counter annotations
/// in the document (CounterGeometry.numbers), so deleting a middle badge
/// renumbers the rest automatically and undo restores numbering for free.
struct CounterAnnotation: Equatable, Identifiable, Sendable {
    let id: UUID
    var center: CGPoint
    var style: AnnotationStyle

    var radius: CGFloat { CounterGeometry.radius(strokeWidth: style.strokeWidth) }

    var boundingRect: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    func offset(by delta: CGVector) -> CounterAnnotation {
        var badge = self
        badge.center = CGPoint(x: center.x + delta.dx, y: center.y + delta.dy)
        return badge
    }
}

/// Compares two annotation lists (before/after one undo or redo step).
enum AnnotationDiff {
    /// The id of the ONE annotation that is new or changed in `new`, or nil
    /// when nothing — or more than one annotation — differs. Removals don't
    /// count: a removed annotation has nothing left to point at. Used to
    /// select what an undo/redo just restored, so its result is visible.
    static func soleChangedID(from old: [Annotation], to new: [Annotation]) -> UUID? {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: UUID?
        for annotation in new where before[annotation.id] != annotation {
            guard changed == nil else { return nil }
            changed = annotation.id
        }
        return changed
    }

    /// What an undo/redo step should select: the one annotation it brought
    /// back or changed; nil — clear the selection — when the step swapped the
    /// image (crop, which also offsets every annotation) or touched none or
    /// several, so no arbitrary survivor is presented as "the result".
    static func selectionAfterUndo(
        from old: [Annotation], to new: [Annotation], imageChanged: Bool
    ) -> UUID? {
        imageChanged ? nil : soleChangedID(from: old, to: new)
    }
}

/// One annotation on the document. An enum (not a protocol) so the model keeps
/// value semantics — whole-value snapshots are trivially storable for undo and
/// comparable in tests.
enum Annotation: Equatable, Identifiable, Sendable {
    case shape(ShapeAnnotation)
    case arrow(ArrowAnnotation)
    case text(TextAnnotation)
    case freehand(FreehandAnnotation)
    case effect(EffectAnnotation)
    case counter(CounterAnnotation)

    var id: UUID {
        switch self {
        case .shape(let shape): shape.id
        case .arrow(let arrow): arrow.id
        case .text(let text): text.id
        case .freehand(let stroke): stroke.id
        case .effect(let effect): effect.id
        case .counter(let badge): badge.id
        }
    }

    var boundingRect: CGRect {
        switch self {
        case .shape(let shape): shape.rect
        case .arrow(let arrow): arrow.boundingRect
        case .text(let text): text.boundingRect
        case .freehand(let stroke): stroke.boundingRect
        case .effect(let effect): effect.rect
        case .counter(let badge): badge.boundingRect
        }
    }

    var style: AnnotationStyle {
        switch self {
        case .shape(let shape): shape.style
        case .arrow(let arrow): arrow.style
        case .text(let text): text.style
        case .freehand(let stroke): stroke.style
        case .effect(let effect): effect.style
        case .counter(let badge): badge.style
        }
    }

    /// Bounding rect inflated to cover the annotation's VISIBLE extent, so the
    /// auto-expanding canvas (M-F) never clips painted pixels: stroked kinds
    /// grow by half their stroke, arrows by the full arrowhead flare
    /// (`ArrowGeometry.maxHalfWidth`). Text / counter / effect already report
    /// their painted bounds, so they use `boundingRect` as-is.
    var expandedBounds: CGRect {
        switch self {
        case .shape(let shape):
            let inset = shape.style.strokeWidth / 2
            return shape.rect.insetBy(dx: -inset, dy: -inset)
        case .arrow(let arrow):
            let inset = arrow.kind == .arrow
                ? ArrowGeometry.maxHalfWidth(strokeWidth: arrow.style.strokeWidth)
                : arrow.style.strokeWidth / 2
            return arrow.boundingRect.insetBy(dx: -inset, dy: -inset)
        case .freehand(let stroke):
            let inset = stroke.style.strokeWidth / 2
            return stroke.boundingRect.insetBy(dx: -inset, dy: -inset)
        case .text, .counter, .effect:
            return boundingRect
        }
    }

    /// Whether `withRect` applies (rect resize handles are shown).
    var isRectResizable: Bool {
        switch self {
        case .shape, .effect: true
        case .arrow, .text, .freehand, .counter: false
        }
    }

    /// Rect-based resizing — shapes and effect regions only. Arrows/lines are
    /// edited via endpoint handles, text/freehand/counter sizes derive from
    /// their content and style, so those return themselves unchanged.
    func withRect(_ rect: CGRect) -> Annotation {
        switch self {
        case .shape(var shape):
            shape.rect = rect
            return .shape(shape)
        case .effect(var effect):
            effect.rect = rect
            return .effect(effect)
        case .arrow, .text, .freehand, .counter:
            return self
        }
    }

    func withStyle(_ style: AnnotationStyle) -> Annotation {
        switch self {
        case .shape(var shape):
            shape.style = style
            return .shape(shape)
        case .arrow(var arrow):
            arrow.style = style
            return .arrow(arrow)
        case .text(var text):
            text.style = style
            return .text(text)
        case .freehand(var stroke):
            stroke.style = style
            return .freehand(stroke)
        case .effect(var effect):
            effect.style = style
            return .effect(effect)
        case .counter(var badge):
            badge.style = style
            return .counter(badge)
        }
    }

    /// Translates the annotation by an unclamped delta (used by crop remapping
    /// and by `moved`, which clamps first).
    func offset(by delta: CGVector) -> Annotation {
        switch self {
        case .shape(var shape):
            shape.rect = shape.rect.offsetBy(dx: delta.dx, dy: delta.dy)
            return .shape(shape)
        case .arrow(let arrow):
            return .arrow(arrow.offset(by: delta))
        case .text(let text):
            return .text(text.offset(by: delta))
        case .freehand(let stroke):
            return .freehand(stroke.offset(by: delta))
        case .effect(var effect):
            effect.rect = effect.rect.offsetBy(dx: delta.dx, dy: delta.dy)
            return .effect(effect)
        case .counter(let badge):
            return .counter(badge.offset(by: delta))
        }
    }

    func moved(by delta: CGVector, within bounds: CGRect) -> Annotation {
        let moved = AnnotationGeometry.movedRect(boundingRect, by: delta, within: bounds)
        let clamped = CGVector(dx: moved.minX - boundingRect.minX, dy: moved.minY - boundingRect.minY)
        return offset(by: clamped)
    }
}

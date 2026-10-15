import AppKit

/// Draws the chrome both capture overlays share — the two-tone selection edge
/// and the dark label chips. Layout comes from the pure `OverlayGeometry`.
@MainActor
enum OverlayChrome {
    /// Two-tone edge just outside `target`: white against the target, then a
    /// translucent black line. Sides that would fall outside `bounds` (the
    /// overlay) are drawn just inside instead, so they never disappear.
    static func strokeEdge(around target: CGRect, within bounds: CGRect) {
        let rects = OverlayGeometry.edgeStrokeRects(around: target, within: bounds)
        for (rect, color) in [
            (rects.inner, NSColor.white),
            (rects.outer, NSColor.black.withAlphaComponent(OverlayGeometry.edgeShadeAlpha)),
        ] {
            color.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = OverlayGeometry.edgeLineWidth
            path.stroke()
        }
    }

    /// White text on a dark rounded chip: 70 % black (worst case 8.5:1, over
    /// white), opaque under Reduce Transparency. Read per draw — the overlays
    /// live for seconds and redraw on every drag / hover change.
    static func drawChip(_ text: String, attributes: [NSAttributedString.Key: Any], frame: CGRect, padding: CGFloat) {
        let fill = OverlayGeometry.chipFill(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        NSColor(white: fill.white, alpha: fill.alpha).setFill()
        NSBezierPath(roundedRect: frame, xRadius: padding, yRadius: padding).fill()
        text.draw(at: CGPoint(x: frame.minX + padding, y: frame.minY + padding), withAttributes: attributes)
    }
}

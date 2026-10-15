import CoreGraphics

/// Pure layout of the capture overlays' chrome — the selection edge and the
/// size / app-name chips — shared by the area-selection and window-pick
/// overlays. Unit-tested; the overlay views only draw what this returns.
enum OverlayGeometry {
    // MARK: - Selection edge

    /// Both overlays outline their target with the same two-tone edge, drawn
    /// *outside* it: a white line against the target, then a black line at
    /// `edgeShadeAlpha`. Against any uniform sRGB backdrop one of the two
    /// reaches at least 3:1 (white carries dark content, the shade carries
    /// light content) — a calculation, not a promise about every busy
    /// screenshot. A lone white line is 1:1 on white, and the accent colour
    /// stays under 3:1 against most backdrops.
    static let edgeLineWidth: CGFloat = 1
    static let edgeShadeAlpha: CGFloat = 0.6

    /// Rects to stroke with `edgeLineWidth` for the inner (white) and outer
    /// (shade) lines. Each path runs through the middle of its line, so the
    /// two lines sit side by side just outside `target`.
    ///
    /// A side that touches the edge of `bounds` (a selection against the
    /// screen edge, a maximised window) has no room outside, so its lines
    /// fold inward over the target — same order, shade outermost — instead of
    /// being clipped away. Only the drawing moves; the crop never does.
    static func edgeStrokeRects(around target: CGRect, within bounds: CGRect) -> (inner: CGRect, outer: CGRect) {
        let reach = target.insetBy(dx: -edgeOutset, dy: -edgeOutset).intersection(bounds)
        guard !reach.isNull else { return (.zero, .zero) }
        let half = edgeLineWidth / 2
        return (
            reach.insetBy(dx: edgeLineWidth + half, dy: edgeLineWidth + half),
            reach.insetBy(dx: half, dy: half)
        )
    }

    // MARK: - Chips

    /// Grey level and opacity of the chips' scrim. 70 % black normally;
    /// opaque under Reduce Transparency (AppKit: backgrounds should be opaque
    /// then), at the grey 70 % black makes over white — the same look and the
    /// same 8.5:1 worst case, now on every backdrop.
    static func chipFill(reduceTransparency: Bool) -> (white: CGFloat, alpha: CGFloat) {
        reduceTransparency ? (0.3, 1) : (0, 0.7)
    }

    // MARK: - Area selection size chip

    /// Inner padding of the size chip, and its gap below the selection edge.
    static let sizeChipPadding: CGFloat = 4
    static let sizeChipGap: CGFloat = 4

    /// "W × H" in points of what will actually be captured — derived from the
    /// crop's pixel rect, so the readout and the result agree. An odd pixel
    /// count at 2× is a half point and says so ("150.5"); one decimal also
    /// absorbs a derived scale a hair off 2 (SCK rounding) without noise.
    static func sizeReadout(capturedPixels: CGSize, scale: CGFloat) -> String {
        guard scale > 0 else { return "0 × 0" }
        return "\(points(capturedPixels.width / scale)) × \(points(capturedPixels.height / scale))"
    }

    private static func points(_ value: CGFloat) -> String {
        let tenths = Int((value * 10).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
    }

    /// Frame of the size chip: below the selection, right-aligned with it;
    /// tucked inside the selection's bottom edge when there is no room below;
    /// always fully inside `bounds`.
    static func sizeChipFrame(textSize: CGSize, selection: CGRect, bounds: CGRect) -> CGRect {
        let size = chipSize(textSize: textSize, padding: sizeChipPadding)
        let below = selection.minY - edgeOutset - sizeChipGap - size.height
        let y = below >= bounds.minY ? below : selection.minY
        return clamped(CGRect(x: selection.maxX - size.width, y: y, width: size.width, height: size.height), into: bounds)
    }

    // MARK: - Window pick title chip

    /// Inner padding of the app-name chip, and its gap above the window edge.
    static let titleChipPadding: CGFloat = 5
    static let titleChipGap: CGFloat = 4

    /// Frame of the app-name chip: centred above the part of the window that
    /// is on this screen, pulled down over the window's top when there is no
    /// room above; always fully inside `bounds`. Nil when the window is not on
    /// this screen at all.
    static func titleChipFrame(textSize: CGSize, window: CGRect, bounds: CGRect) -> CGRect? {
        let visible = window.intersection(bounds)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        let size = chipSize(textSize: textSize, padding: titleChipPadding)
        let frame = CGRect(
            x: visible.midX - size.width / 2,
            y: visible.maxY + edgeOutset + titleChipGap,
            width: size.width,
            height: size.height
        )
        return clamped(frame, into: bounds)
    }

    // MARK: - Helpers

    /// How far the two-tone edge reaches outside its target.
    private static var edgeOutset: CGFloat { 2 * edgeLineWidth }

    private static func chipSize(textSize: CGSize, padding: CGFloat) -> CGSize {
        CGSize(width: textSize.width + 2 * padding, height: textSize.height + 2 * padding)
    }

    /// Moves `frame` (without resizing it) so it lies inside `bounds`; a frame
    /// larger than `bounds` is pinned to its leading / bottom edge.
    static func clamped(_ frame: CGRect, into bounds: CGRect) -> CGRect {
        var result = frame
        result.origin.x = max(min(frame.minX, bounds.maxX - frame.width), bounds.minX)
        result.origin.y = max(min(frame.minY, bounds.maxY - frame.height), bounds.minY)
        return result
    }
}

import CoreGraphics

/// Pure zoom/resize math for pinned screenshot windows (AppKit coordinates).
enum PinGeometry {
    /// Converts one scroll-wheel event's delta into a zoom factor.
    /// ~1.5% per scroll unit; a single event can at most halve/double.
    static func zoomFactor(forScrollDeltaY delta: CGFloat) -> CGFloat {
        min(max(1 + delta * 0.015, 0.5), 2)
    }

    /// Scales `frame` by `factor` around `anchor` (same coordinate space,
    /// typically the cursor position), preserving aspect ratio. The factor is
    /// clamped so the resulting width stays within `minWidth...maxWidth`; the
    /// anchor point stays fixed on screen.
    static func zoomedFrame(
        _ frame: CGRect,
        factor: CGFloat,
        anchor: CGPoint,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return frame }
        let width = min(max(frame.width * factor, minWidth), maxWidth)
        let effective = width / frame.width
        return CGRect(
            x: anchor.x - (anchor.x - frame.minX) * effective,
            y: anchor.y - (anchor.y - frame.minY) * effective,
            width: width,
            height: frame.height * effective
        )
    }

    /// Frame after dragging the bottom-right corner to `bottomRight`: the
    /// top-left corner stays fixed, width follows the cursor, and height keeps
    /// `aspectRatio` (width ÷ height). Width is clamped to `minWidth...maxWidth`.
    static func cornerResizedFrame(
        _ frame: CGRect,
        bottomRight: CGPoint,
        aspectRatio: CGFloat,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGRect {
        guard aspectRatio > 0 else { return frame }
        let width = min(max(bottomRight.x - frame.minX, minWidth), maxWidth)
        let height = width / aspectRatio
        return CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }

    /// Whether `point` (view coordinates, non-flipped: origin bottom-left)
    /// lies in the bottom-right square of side `cornerSize` that resizes the
    /// pin. Points outside `bounds` (e.g. a mouse-up after a clamped resize
    /// drag) are never in the corner.
    static func isInResizeCorner(_ point: CGPoint, bounds: CGRect, cornerSize: CGFloat) -> Bool {
        point.x >= bounds.maxX - cornerSize && point.x <= bounds.maxX
            && point.y >= bounds.minY && point.y <= bounds.minY + cornerSize
    }

    /// Whether the hover toolbar fits inside a pin of `pinSize` with `inset`
    /// on every side — in both dimensions, so a short pin hides it rather than
    /// clipping it at the bottom edge.
    static func toolbarFits(pinSize: CGSize, toolbarSize: CGSize, inset: CGFloat) -> Bool {
        pinSize.width >= toolbarSize.width + 2 * inset
            && pinSize.height >= toolbarSize.height + 2 * inset
    }
}

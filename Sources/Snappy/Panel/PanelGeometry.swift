import CoreGraphics

/// Pure placement math for the floating preview panel (AppKit coordinates,
/// y grows up).
enum PanelGeometry {
    /// Origin for a panel of `panelSize` anchored to `anchorRect` (the captured
    /// area, AppKit global) inside `screenFrame` (the screen's visible frame).
    ///
    /// Preferred spot: below the anchor, right-aligned with it. If there is no
    /// room below, flips above the anchor; either way the result is clamped so
    /// the panel lies fully inside `screenFrame` (overlapping the anchor as a
    /// last resort — never off-screen).
    static func panelOrigin(
        panelSize: CGSize,
        anchorRect: CGRect,
        screenFrame: CGRect,
        gap: CGFloat = 8
    ) -> CGPoint {
        var x = anchorRect.maxX - panelSize.width
        var y = anchorRect.minY - gap - panelSize.height
        if y < screenFrame.minY {
            y = anchorRect.maxY + gap
        }
        // Clamp inside the screen; the lower bound wins if the panel is larger
        // than the screen, keeping the top-left area reachable.
        x = max(min(x, screenFrame.maxX - panelSize.width), screenFrame.minX)
        y = max(min(y, screenFrame.maxY - panelSize.height), screenFrame.minY)
        return CGPoint(x: x, y: y)
    }
}

import AppKit

/// Tracking-area options for the capture overlays — pure, unit-tested.
///
/// `.activeAlways` is **not supported** together with `.cursorUpdate`
/// (NSTrackingArea.h: "Not supported for NSTrackingCursorUpdate"), so cursor
/// updates get their own area. Mouse-moved tracking must stay `.activeAlways`:
/// the area panel is non-activating and may be key while the app is not active.
enum OverlayTracking {
    /// Hover / Esc-follows-the-cursor tracking, regardless of activation.
    static let pointer: NSTrackingArea.Options = [.activeAlways, .mouseMoved, .inVisibleRect]
    /// `cursorUpdate(with:)` delivery — key-window scoped, which the overlay
    /// under the mouse always is (`makeKey()` works without activation).
    static let cursor: NSTrackingArea.Options = [.activeInKeyWindow, .cursorUpdate, .inVisibleRect]
}

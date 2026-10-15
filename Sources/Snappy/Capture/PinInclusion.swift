import CoreGraphics

/// Which of Snappy's own windows a screenshot or recording keeps: the open pins.
///
/// Everything else of ours (preview panel, editor, overlays, menus, recording
/// chrome) is excluded by application. Pins are the exception because a pin is
/// the user's own screenshot content, deliberately placed on screen — capturing
/// "the screen including my pin" has to work. The window IDs are the pins'
/// `NSWindow.windowNumber`s, registered by `PinWindowController` while open.
@MainActor
enum PinWindowRegistry {
    private(set) static var windowIDs: Set<CGWindowID> = []

    static func register(_ id: CGWindowID) { windowIDs.insert(id) }
    static func unregister(_ id: CGWindowID) { windowIDs.remove(id) }
}

/// PURE decision logic for keeping pins in a capture.
enum PinInclusion {
    /// ScreenCaptureKit can only except windows it lists, and the warm
    /// `SCShareableContent` cache may predate a pin that was opened since. When
    /// an open pin is missing from the cached list one fresh fetch is needed —
    /// only ever while pins exist, so the common path keeps its cached speed.
    static func needsFreshContent(pinIDs: Set<CGWindowID>, listedIDs: Set<CGWindowID>) -> Bool {
        !pinIDs.isSubset(of: listedIDs)
    }
}

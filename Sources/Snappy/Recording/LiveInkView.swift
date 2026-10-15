import AppKit
import QuartzCore

/// The on-screen ink canvas: fills the ink panel, which covers exactly the
/// target frame (a W + part's part, so ink outside the part is hidden). Draws the current `InkScene` with `InkRenderer` — the same
/// code the compositor runs on every video frame — through
/// `FrameDecoratingGeometry.transform`, i.e. the view is "a frame whose output
/// rect is the view's bounds". Reports drags in AppKit-global points and keys
/// as raw events; `LiveInkPanel` decides what they mean.
@MainActor
final class LiveInkView: NSView {
    var scene = InkScene.empty {
        didSet { if scene != oldValue { needsDisplay = true } }
    }
    /// The target's AppKit-global frame — where `bounds` sits on screen.
    var targetFrame = CGRect.zero {
        didSet { if targetFrame != oldValue { needsDisplay = true } }
    }
    /// The recorded window's frame when the target is only a part of it
    /// (window-anchored ink resolves against it, Q42); nil otherwise.
    var windowFrame: CGRect? {
        didSet { if windowFrame != oldValue { needsDisplay = true } }
    }
    /// A tool is picked: crosshair pointer over the canvas.
    var drawsWithTool = false {
        didSet {
            guard drawsWithTool != oldValue else { return }
            if drawsWithTool, isMouseInside { NSCursor.crosshair.set() }
        }
    }
    /// Host clock for fade evaluation (`CACurrentMediaTime`, as the video).
    var clock: () -> TimeInterval = CACurrentMediaTime

    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    /// Returns true when the key was handled.
    var onKeyDown: ((NSEvent) -> Bool)?

    private var isMouseInside = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !scene.strokes.isEmpty else { return }
        context.saveGState()
        context.concatenate(FrameDecoratingGeometry.transform(targetFrame: targetFrame, outputRect: bounds))
        InkRenderer.draw(scene, in: context, targetFrame: targetFrame, windowFrame: windowFrame, time: clock())
        context.restoreGState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let point = globalPoint(of: event) else { return }
        onMouseDown?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = globalPoint(of: event) else { return }
        onMouseDragged?(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let point = globalPoint(of: event) else { return }
        onMouseUp?(point)
    }

    private func globalPoint(of event: NSEvent) -> CGPoint? {
        window?.convertPoint(toScreen: event.locationInWindow)
    }

    // MARK: - Pointer

    /// `.activeAlways`: the panel is non-activating, so Snappy is usually not
    /// the active app while you draw. No `.cursorUpdate` here — it isn't
    /// supported with `.activeAlways` (ARCHITECTURE overlay invariant 3).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        if drawsWithTool { NSCursor.crosshair.set() }
    }

    override func mouseMoved(with event: NSEvent) {
        isMouseInside = true
        if drawsWithTool { NSCursor.crosshair.set() }
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
    }

    // MARK: - Keys (draw mode, or Setup after a click made the panel key)

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    /// ⌘Z / ⇧⌘Z arrive as key equivalents first; there is no main menu to
    /// take them (ARCHITECTURE quirk "No main menu").
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        return onKeyDown?(event) == true || super.performKeyEquivalent(with: event)
    }
}

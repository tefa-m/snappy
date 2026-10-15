import AppKit

@MainActor
struct AreaSelectionResult {
    /// Selection in AppKit global coordinates.
    let globalRect: CGRect
    /// The frozen snapshot the selection was made on — the capture is cropped
    /// out of it, so no second trip to ScreenCaptureKit is needed.
    let frozen: FrozenScreen

    var screen: NSScreen { frozen.screen }
}

/// Full-screen selection overlay, one panel per display, each showing that
/// display's frozen snapshot as an opaque backdrop. The drag is constrained to
/// the display it started on; Esc cancels.
///
/// The snapshots are taken *before* the app activates and before **anything of
/// ours reaches the screen**, so an open context menu, menu-bar menu or tooltip
/// is still in the pixels. Activating afterwards dismisses that menu for real —
/// which is both necessary (its modal tracking loop would otherwise swallow our
/// first click) and harmless (it is already in the snapshot, and the user still
/// sees it on the backdrop).
///
/// **Do not put any window up before the freeze.** Ordering a panel front and
/// calling `makeKey()` cancels a foreign menu's tracking loop, so the menu is
/// gone by the time the snapshot is taken — the exact bug this whole design
/// exists to prevent. That was tried (an "instant crosshair" phase) and reverted;
/// see the rejection note in `features/capture.md`.
@MainActor
final class AreaSelectionController {
    private var overlays: [SelectionOverlayPanel] = []
    private var snapshots: [FrozenScreen]
    private let completion: (AreaSelectionResult?) -> Void
    private var finished = false
    private var escMonitor: Any?

    init(snapshots: [FrozenScreen], completion: @escaping (AreaSelectionResult?) -> Void) {
        self.snapshots = snapshots
        self.completion = completion
    }

    func begin() {
        // One overlay per *frozen* screen, never per NSScreen: every overlay
        // must have a backdrop, and the set must match what was captured.
        overlays = snapshots.map { frozen in
            SelectionOverlayPanel(
                frozen: frozen,
                onSelect: { [weak self] viewRect, panel in
                    guard let self else { return }
                    let globalRect = panel.convertToScreen(viewRect)
                    self.finish(with: AreaSelectionResult(globalRect: globalRect, frozen: panel.frozen))
                },
                onCancel: { [weak self] in
                    self?.finish(with: nil)
                }
            )
        }

        // Order front first: the opaque backdrops are already covering the
        // screen when activation dismisses the foreign menu, so the dismissal
        // is invisible. Activating first would flash the live, menu-less screen.
        for overlay in overlays {
            overlay.orderFrontRegardless()
        }
        NSApp.activate()
        overlayUnderMouse()?.makeKey()
        NSCursor.crosshair.set()

        // Fallback: cancel on Esc / Q even if no overlay is the key window.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard OverlayKeys.isCancel(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                flags: event.modifierFlags
            ) else { return event }
            MainActor.assumeIsolated {
                self.finish(with: nil)
            }
            return nil
        }

        // Cooperative activation can be declined now that it happens after the
        // freeze's await. The panels are non-activating so Esc works regardless,
        // but a foreign menu's tracking loop only ends when its app deactivates
        // — so retry once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.finished, !NSApp.isActive else { return }
            NSApp.activate()
            self.overlayUnderMouse()?.makeKey()
        }
    }

    private func overlayUnderMouse() -> SelectionOverlayPanel? {
        let mouse = NSEvent.mouseLocation
        return overlays.first { $0.frame.contains(mouse) } ?? overlays.first
    }

    private func finish(with result: AreaSelectionResult?) {
        guard !finished else { return }
        finished = true
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        for overlay in overlays {
            // Order out first, *then* drop the image: emptying the layer of a
            // window still on screen can composite a frame of bare background.
            overlay.orderOut(nil)
            // Drop the full-display images promptly — tens of MB per display.
            overlay.releaseBackdrop()
        }
        overlays = []
        snapshots = []
        completion(result)
    }
}

/// Borderless opaque panel covering one screen during area selection.
///
/// A **non-activating** panel: it takes key status via `makeKey()` without the
/// app being active, so Esc keeps working even if macOS declines the activation
/// that happens after the freeze's await.
@MainActor
final class SelectionOverlayPanel: NSPanel {
    let frozen: FrozenScreen
    private let backdrop: FrozenBackdropView

    /// `NSWindow.screen` can change while ordering out; keep the assignment.
    var assignedScreen: NSScreen { frozen.screen }

    init(
        frozen: FrozenScreen,
        onSelect: @escaping (CGRect, SelectionOverlayPanel) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.frozen = frozen
        backdrop = FrozenBackdropView(image: frozen.image, scale: frozen.scale)
        super.init(
            contentRect: frozen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        // NSPanel hides itself when the app deactivates; the overlay must not.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        // `.default` makes AppKit infer `.utilityWindow` for an NSPanel, which
        // fades the window in AND out. Over a full-screen frozen backdrop that
        // reads as the screen pulsing on and off. NSWindow infers no animation,
        // which is why this only appeared when the overlay became a panel.
        animationBehavior = .none
        // Never shown (borderless); VoiceOver announces it. Same name as the
        // menu item that starts the flow.
        title = "Capture Area"

        let view = SelectionOverlayView(
            screenFrame: frozen.frame,
            scale: frozen.scale,
            imagePixelSize: frozen.pixelSize,
            onSelect: { [weak self] rect in
                guard let self else { return }
                onSelect(rect, self)
            },
            onCancel: onCancel
        )
        // The backdrop is the *parent*: a view's draw(_:) output composites
        // below its subviews, so the selection tint must be a child of the
        // image, not the other way round. It also keeps the full-display image
        // in a compositor layer that never redraws while dragging.
        //
        // Install the backdrop FIRST — it is created at .zero and only gets the
        // content rect here; sizing the subview before that would autoresize it
        // from a zero-sized superview.
        contentView = backdrop
        view.frame = backdrop.bounds
        view.autoresizingMask = [.width, .height]
        backdrop.addSubview(view)
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }

    func releaseBackdrop() {
        backdrop.releaseImage()
    }
}

/// Shows one display's frozen snapshot 1:1 as an opaque compositor layer.
@MainActor
private final class FrozenBackdropView: NSView {
    private let contentsScaleForImage: CGFloat

    init(image: CGImage, scale: CGFloat) {
        contentsScaleForImage = scale
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.contentsScale = scale
        // Layer bounds (points) × contentsScale == image pixels, so .resize is
        // a straight blit; .nearest keeps it that way if anything is fractional.
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isOpaque: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // AppKit resets contentsScale to the window's backing scale on its own
        // schedule; the snapshot's own scale is the authority here.
        layer?.contentsScale = contentsScaleForImage
    }

    func releaseImage() {
        layer?.contents = nil
    }
}

/// Draws the selection over the frozen backdrop — a faint tint inside the
/// selected region, its two-tone edge and a size chip, and nothing at all
/// before the drag starts; reports the completed drag.
@MainActor
final class SelectionOverlayView: NSView {
    private let onSelect: (CGRect) -> Void
    private let onCancel: () -> Void

    /// The frozen snapshot's geometry: what is drawn is what the crop will
    /// take (see `CaptureGeometry.capturedSelection`).
    private let screenFrame: CGRect
    private let scale: CGFloat
    private let imagePixelSize: CGSize

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(
        screenFrame: CGRect,
        scale: CGFloat,
        imagePixelSize: CGSize,
        onSelect: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screenFrame = screenFrame
        self.scale = scale
        self.imagePixelSize = imagePixelSize
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Area selection")
        setAccessibilityHelp("Drag to select the area to capture. Press Escape or Q to cancel.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    /// Start the drag with the very first click, even if the window was not
    /// key yet — no "click to focus first".
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selectionRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CaptureGeometry.normalizedRect(from: dragStart, to: dragCurrent)
    }

    // MARK: - Cursor & tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // Two areas: mouse-moved stays .activeAlways (works before the window
        // is key and while the app is inactive), but .activeAlways is not
        // supported for .cursorUpdate — see OverlayTracking.
        for options in [OverlayTracking.pointer, OverlayTracking.cursor] {
            addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        // Follow the cursor across displays so Esc reaches the overlay under
        // the mouse; keep the crosshair while doing so.
        if let window, !window.isKeyWindow {
            window.makeKey()
        }
        NSCursor.crosshair.set()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragCurrent = CaptureGeometry.clamp(point, to: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragCurrent = nil
        }
        guard let rect = selectionRect, rect.width >= 1, rect.height >= 1 else {
            needsDisplay = true
            return
        }
        onSelect(rect)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if OverlayKeys.isCancel(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            flags: event.modifierFlags
        ) { // Esc / Q
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    /// Tint colour of the selected region. Deliberately faint: the point of the
    /// frozen backdrop is that the screen looks untouched, so the overlay must
    /// not announce itself.
    private static let selectionTint = NSColor.black.withAlphaComponent(0.12)

    private static let sizeChipAttributes: [NSAttributedString.Key: Any] = [
        // Monospaced digits: the chip doesn't jitter while the numbers change.
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    override func draw(_ dirtyRect: NSRect) {
        // Nothing at all until the drag starts — the frozen backdrop is then
        // pixel-identical to the live screen, which is the whole illusion.
        // Once dragging, only the *selection* is tinted; the surroundings are
        // never painted, so nothing can erase the snapshot under them.
        guard let selectionRect else { return }
        // Draw what the crop will take, not the raw drag: snapshot-pixel edges
        // (crisp, exact), and nothing at all for a click that captures nothing.
        let captured = CaptureGeometry.capturedSelection(
            overlayRect: selectionRect,
            screenFrame: screenFrame,
            scale: scale,
            imagePixelSize: imagePixelSize
        )
        guard !captured.pixels.isEmpty else { return }
        let rect = captured.overlayRect

        Self.selectionTint.setFill()
        rect.fill() // CoreGraphics clips to dirtyRect; no band filtering needed.
        OverlayChrome.strokeEdge(around: rect, within: bounds)

        let text = OverlayGeometry.sizeReadout(capturedPixels: captured.pixels.size, scale: scale)
        let chip = OverlayGeometry.sizeChipFrame(
            textSize: text.size(withAttributes: Self.sizeChipAttributes),
            selection: rect,
            bounds: bounds
        )
        OverlayChrome.drawChip(
            text,
            attributes: Self.sizeChipAttributes,
            frame: chip,
            padding: OverlayGeometry.sizeChipPadding
        )
    }
}

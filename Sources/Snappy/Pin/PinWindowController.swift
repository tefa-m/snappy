import AppKit

/// One pinned screenshot: an always-on-top borderless window showing the
/// capture, draggable anywhere, scroll-zoomable around the cursor, resizable
/// via its bottom-right corner (aspect kept, diagonal-resize pointer there),
/// slightly translucent while hovered (opaque under Reduce Transparency) with
/// a floating Close·Edit·Copy toolbar, closed with Esc, Q or a
/// double-click. Multiple pins coexist — the coordinator owns the collection.
@MainActor
final class PinWindowController {
    private let window: PinWindow
    private let image: CGImage
    private let scale: CGFloat
    private let onClose: (PinWindowController) -> Void
    private let onEdit: (CGImage, CGFloat, CGRect) -> Void
    private let onCopy: (CGImage, CGFloat) -> Void
    private var closed = false

    /// `frame` is the desired window frame in AppKit global coordinates
    /// (normally the captured area, so the pin appears exactly in place).
    /// The pin retains the image and its backing scale so Edit can reopen the
    /// annotation editor and Copy can put the full image on the pasteboard.
    init(
        image: CGImage,
        scale: CGFloat,
        frame: CGRect,
        onClose: @escaping (PinWindowController) -> Void,
        onEdit: @escaping (CGImage, CGFloat, CGRect) -> Void,
        onCopy: @escaping (CGImage, CGFloat) -> Void
    ) {
        self.image = image
        self.scale = scale
        self.onClose = onClose
        self.onEdit = onEdit
        self.onCopy = onCopy
        window = PinWindow(image: image, frame: frame)
        window.onCloseRequested = { [weak self] in self?.close() }
        window.onEditRequested = { [weak self] in self?.edit() }
        window.onCopyRequested = { [weak self] in
            guard let self else { return }
            self.onCopy(self.image, self.scale)
        }
    }

    func show() {
        window.orderFrontRegardless()
        // Pins stay in screenshots and recordings (see `PinWindowRegistry`).
        PinWindowRegistry.register(CGWindowID(window.windowNumber))
    }

    func close() {
        guard !closed else { return }
        closed = true
        PinWindowRegistry.unregister(CGWindowID(window.windowNumber))
        window.orderOut(nil)
        onClose(self)
    }

    /// Edit closes the pin and hands the image back to the coordinator, which
    /// reopens the annotation editor (same path as the preview panel's Edit).
    private func edit() {
        guard !closed else { return }
        let frame = window.frame
        close()
        onEdit(image, scale, frame)
    }
}

@MainActor
private final class PinWindow: NSWindow {
    var onCloseRequested: (() -> Void)?
    var onEditRequested: (() -> Void)?
    var onCopyRequested: (() -> Void)?

    init(image: CGImage, frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        let view = PinView(
            image: image,
            aspectRatio: frame.width / max(frame.height, 1),
            minWidth: min(PinView.minWidth, frame.width)
        )
        view.onCloseRequested = { [weak self] in self?.onCloseRequested?() }
        view.onEditRequested = { [weak self] in self?.onEditRequested?() }
        view.onCopyRequested = { [weak self] in self?.onCopyRequested?() }
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 53 || key == PinAction.close.shortcutKey { // Esc / Q
            onCloseRequested?()
        } else if key == PinAction.edit.shortcutKey, ShortcutKeys.isBareKey(event.modifierFlags) {
            onEditRequested?()
        } else if key == PinAction.copy.shortcutKey, ShortcutKeys.isBareKey(event.modifierFlags) {
            onCopyRequested?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class PinView: NSView {
    var onCloseRequested: (() -> Void)?
    var onEditRequested: (() -> Void)?
    var onCopyRequested: (() -> Void)?

    private let aspectRatio: CGFloat
    /// Zoom/resize floor, fixed at creation: `min(80, initial width)` so a pin
    /// narrower than 80 pt can still be zoomed back to its original size.
    private let floorWidth: CGFloat
    private var isResizing = false
    private var isHovering = false
    private let toolbarView = PinToolbarView()

    private static let cornerHitSize: CGFloat = 16
    fileprivate static let minWidth: CGFloat = 80
    private static let toolbarInset: CGFloat = 8
    private static let toolbarFadeDuration: TimeInterval = 0.15

    init(image: CGImage, aspectRatio: CGFloat, minWidth: CGFloat) {
        self.aspectRatio = max(aspectRatio, 0.01)
        floorWidth = minWidth
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        toolbarView.onClose = { [weak self] in self?.onCloseRequested?() }
        toolbarView.onEdit = { [weak self] in self?.onEditRequested?() }
        toolbarView.onCopy = { [weak self] in self?.onCopyRequested?() }
        toolbarView.alphaValue = 0
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbarView)
        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.toolbarInset),
            toolbarView.topAnchor.constraint(equalTo: topAnchor, constant: Self.toolbarInset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    /// Interact with the pin on the first click even if the app is inactive.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var maxWidth: CGFloat {
        max((window?.screen ?? NSScreen.main)?.visibleFrame.width ?? 1200, Self.minWidth)
    }

    // MARK: - Hover transparency + toolbar

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // .inVisibleRect covers the whole pin including the toolbar subview,
        // so pin → toolbar pointer moves produce no exit/enter churn.
        // .mouseMoved drives the resize-corner pointer.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        // Separate area for AppKit's cursor arbitration: .cursorUpdate is not
        // supported with .activeAlways (NSTrackingArea.h), so it only runs
        // while Snappy is active; mouseMoved stays the best-effort path.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    /// Re-asserts the pointer whenever AppKit arbitrates it (entry, view or
    /// window changes), so it can't be reset to the arrow over the corner.
    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: event)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateHoverAlpha()
        updateToolbarVisibility(animated: true)
        updateCursor(at: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateHoverAlpha()
        updateToolbarVisibility(animated: true)
        if !isResizing { NSCursor.arrow.set() }
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: event)
    }

    private func updateHoverAlpha() {
        let alpha = PinHover.windowAlpha(
            hovering: isHovering,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        window?.animator().alphaValue = alpha
    }

    /// The bottom-right resize corner shows the system diagonal-resize
    /// pointer, so the invisible 16 pt hit zone is discoverable.
    private func updateCursor(at event: NSEvent) {
        guard !isResizing else { return }
        let point = convert(event.locationInWindow, from: nil)
        if PinGeometry.isInResizeCorner(point, bounds: bounds, cornerSize: Self.cornerHitSize) {
            Self.resizeCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private static let resizeCursor = NSCursor.frameResize(position: .bottomRight, directions: .all)

    override func layout() {
        super.layout()
        // Re-check on every resize: tiny pins hide the toolbar entirely.
        updateToolbarVisibility(animated: false)
    }

    private func updateToolbarVisibility(animated: Bool) {
        let fits = PinGeometry.toolbarFits(
            pinSize: bounds.size, toolbarSize: toolbarView.fittingSize, inset: Self.toolbarInset
        )
        // Alpha 0 alone leaves the buttons hit-testable: a click on a tiny pin
        // must never land on an invisible Close.
        toolbarView.isHidden = !fits
        let target: CGFloat = (isHovering && fits) ? 1 : 0
        guard toolbarView.alphaValue != target else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.toolbarFadeDuration
                toolbarView.animator().alphaValue = target
            }
        } else {
            toolbarView.alphaValue = target
        }
    }

    // MARK: - Move / resize / close

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // Take key so a subsequent Esc closes this pin.
        window.makeKey()
        // Control-click is a secondary click: menu, not a drag.
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if event.clickCount == 2 {
            onCloseRequested?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if PinGeometry.isInResizeCorner(point, bounds: bounds, cornerSize: Self.cornerHitSize) {
            isResizing = true
        } else {
            window.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing, let window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let frame = PinGeometry.cornerResizedFrame(
            window.frame,
            bottomRight: screenPoint,
            aspectRatio: aspectRatio,
            minWidth: floorWidth,
            maxWidth: maxWidth
        )
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        isResizing = false
        // Outside the pin (a release past the resize clamp) this sets the
        // arrow, never the resize pointer.
        updateCursor(at: event)
    }

    // MARK: - Context menu

    /// Secondary click offers Edit · Copy · Close — the mouse route to the
    /// actions on pins too small for the hover toolbar.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (index, group) in PinAction.contextMenuGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for action in group {
                let item = NSMenuItem(
                    title: action.title, action: #selector(contextMenuItemChosen(_:)), keyEquivalent: ""
                )
                item.target = self
                item.image = NSImage(systemSymbolName: action.menuSymbolName, accessibilityDescription: nil)
                item.tag = PinAction.allCases.firstIndex(of: action)!
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func contextMenuItemChosen(_ sender: NSMenuItem) {
        switch PinAction.allCases[sender.tag] {
        case .close: onCloseRequested?()
        case .edit: onEditRequested?()
        case .copy: onCopyRequested?()
        }
    }

    // MARK: - Scroll zoom

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let factor = PinGeometry.zoomFactor(forScrollDeltaY: event.scrollingDeltaY)
        let anchor = window.convertPoint(toScreen: event.locationInWindow)
        let frame = PinGeometry.zoomedFrame(
            window.frame,
            factor: factor,
            anchor: anchor,
            minWidth: floorWidth,
            maxWidth: maxWidth
        )
        window.setFrame(frame, display: true)
    }
}

// MARK: - Hover toolbar

/// Compact Liquid Glass toolbar floating in the pin's top-left corner while
/// hovered: Close (red) · Edit · Copy. Same button style as the preview panel:
/// borderless `.toolbar` buttons (hover highlight, no bezel boxes on the glass)
/// at the HIG default macOS control size of 28 pt.
@MainActor
private final class PinToolbarView: NSGlassEffectView {
    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?

    private static let buttonSize: CGFloat = 28
    private static let spacing: CGFloat = 4
    private static let padding: CGFloat = 4

    init() {
        super.init(frame: .zero)
        // Concentric with the buttons' hover highlight inside the 4 pt
        // padding; matches the preview panel's glass radius.
        cornerRadius = 10

        let buttons = PinAction.allCases.map(makeButton)
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = Self.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView = stack
        NSLayoutConstraint.activate([
            // A horizontal stack with centre-Y alignment does not size itself
            // from its top/bottom insets — without this the glass collapsed to
            // 10 pt tall with the icons spilling out of it.
            stack.heightAnchor.constraint(equalToConstant: Self.buttonSize + 2 * Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func makeButton(for action: PinAction) -> NSButton {
        var configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if action == .close {
            // Red macOS-style close control (M-C spec): white × on a
            // red disc — 3.4–3.6:1, above the 3:1 non-text minimum.
            configuration = configuration.applying(.init(paletteColors: [.white, .systemRed]))
        }
        let image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        let button = PinToolbarButton(image: image, target: self, action: #selector(buttonClicked(_:)))
        // `.toolbar` ignores controlSize, so pin the size explicitly.
        button.bezelStyle = .toolbar
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
        button.setAccessibilityLabel(action.title)
        button.toolTip = action.toolTip
        button.tag = PinAction.allCases.firstIndex(of: action)!
        return button
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        switch PinAction.allCases[sender.tag] {
        case .close: onClose?()
        case .edit: onEdit?()
        case .copy: onCopy?()
        }
    }
}

/// Toolbar buttons react to the first click even while Snappy is inactive —
/// same click-through behavior as the pin itself.
@MainActor
private final class PinToolbarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

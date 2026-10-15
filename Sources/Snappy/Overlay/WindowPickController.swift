import AppKit
import ScreenCaptureKit

struct SCWindowSelection {
    let window: SCWindow
    /// Window frame converted to AppKit global coordinates (panel anchor).
    let appKitFrame: CGRect
    /// The screen the window (mostly) sits on.
    let screen: NSScreen?
    /// Backing scale of that screen.
    let scale: CGFloat
}

/// Window capture picker: highlights the window under the cursor, click
/// captures it, Esc or Q cancels.
@MainActor
final class WindowPickController {
    private var overlays: [WindowPickOverlayWindow] = []
    private let candidates: [SCWindow]
    private let completion: (SCWindowSelection?) -> Void
    private var finished = false
    /// The window the overlays currently highlight (nil = none).
    private var highlightedWindowID: CGWindowID?
    private var escMonitor: Any?

    init(content: SCShareableContent, completion: @escaping (SCWindowSelection?) -> Void) {
        // Normal app windows only: on screen, standard layer, not our own.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        candidates = content.windows.filter { window in
            window.isOnScreen
                && window.windowLayer == 0
                && window.owningApplication?.processID != ownPID
                && window.frame.width >= 40 && window.frame.height >= 40
        }
        self.completion = completion
    }

    func begin() {
        overlays = NSScreen.screens.map { screen in
            WindowPickOverlayWindow(
                screen: screen,
                onClick: { [weak self] in self?.pickWindowUnderMouse() },
                onCancel: { [weak self] in self?.finish(with: nil) }
            )
        }

        // The app must be truly active for the overlays to receive key events
        // (Esc) and react to the first click.
        NSApp.activate()
        for overlay in overlays {
            overlay.orderFrontRegardless()
            overlay.onMouseMoved = { [weak self] in self?.updateHighlight() }
        }
        let mouse = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKeyAndOrderFront(nil)
        updateHighlight()

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
    }

    private var primaryDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private func windowUnderMouse() -> SCWindow? {
        let cgMouse = CaptureGeometry.cgPoint(
            fromAppKitGlobal: NSEvent.mouseLocation,
            primaryDisplayHeight: primaryDisplayHeight
        )
        // SCShareableContent windows are ordered front to back.
        return candidates.first { $0.frame.contains(cgMouse) }
    }

    private func updateHighlight() {
        let target = windowUnderMouse()
        // Every mouse move lands here; invalidating each full-screen overlay is
        // only worth it when the hovered window actually changed.
        guard target?.windowID != highlightedWindowID else { return }
        highlightedWindowID = target?.windowID
        let appKitFrame = target.map {
            CaptureGeometry.appKitRect(fromCGGlobal: $0.frame, primaryDisplayHeight: primaryDisplayHeight)
        }
        for overlay in overlays {
            overlay.highlight(globalRect: appKitFrame, title: target?.owningApplication?.applicationName)
        }
    }

    private func pickWindowUnderMouse() {
        guard let window = windowUnderMouse() else {
            finish(with: nil)
            return
        }
        let appKitFrame = CaptureGeometry.appKitRect(
            fromCGGlobal: window.frame,
            primaryDisplayHeight: primaryDisplayHeight
        )
        let screen = NSScreen.screens
            .max { $0.frame.intersection(appKitFrame).area < $1.frame.intersection(appKitFrame).area }
        finish(with: SCWindowSelection(
            window: window,
            appKitFrame: appKitFrame,
            screen: screen,
            scale: screen?.backingScaleFactor ?? 2
        ))
    }

    private func finish(with result: SCWindowSelection?) {
        guard !finished else { return }
        finished = true
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        for overlay in overlays {
            overlay.orderOut(nil)
        }
        overlays = []
        completion(result)
    }
}

private extension CGRect {
    var area: CGFloat { isEmpty ? 0 : width * height }
}

/// Transparent per-screen overlay that dims the screen and highlights the
/// hovered window: undimmed, accent-tinted, outlined with the two-tone edge
/// both capture overlays share, and named by an app-name chip.
@MainActor
final class WindowPickOverlayWindow: NSWindow {
    var onMouseMoved: (() -> Void)?

    private let pickView: WindowPickOverlayView

    init(screen: NSScreen, onClick: @escaping () -> Void, onCancel: @escaping () -> Void) {
        pickView = WindowPickOverlayView(onClick: onClick, onCancel: onCancel)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        // Never shown (borderless); VoiceOver announces it. Same name as the
        // menu item that starts the flow.
        title = "Capture Window"

        contentView = pickView
        makeFirstResponder(pickView)
    }

    override var canBecomeKey: Bool { true }

    /// Called by the view's always-active tracking area.
    func viewMouseMoved() {
        if !isKeyWindow {
            makeKey()
        }
        onMouseMoved?()
    }

    /// Highlights the part of `globalRect` (AppKit global) on this screen.
    func highlight(globalRect: CGRect?, title: String?) {
        if let globalRect {
            let local = convertFromScreen(globalRect)
            pickView.highlightRect = local.intersects(pickView.bounds) ? local : nil
        } else {
            pickView.highlightRect = nil
        }
        pickView.appName = title
    }
}

@MainActor
final class WindowPickOverlayView: NSView {
    var highlightRect: CGRect? {
        didSet { needsDisplay = true }
    }
    var appName: String? {
        didSet { needsDisplay = true }
    }

    private let onClick: () -> Void
    private let onCancel: () -> Void

    init(onClick: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onClick = onClick
        self.onCancel = onCancel
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Window picker")
        setAccessibilityHelp("Click a window to capture it. Press Escape or Q to cancel.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    /// React to the very first click even if the window was not key yet.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: OverlayTracking.pointer, owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        (window as? WindowPickOverlayWindow)?.viewMouseMoved()
    }

    override func mouseUp(with event: NSEvent) {
        onClick()
    }

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

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        guard let rect = highlightRect else { return }

        NSColor.clear.setFill()
        rect.fill(using: .copy)
        // The accent tint is the colour cue; the edge carries the contrast
        // (an accent stroke alone is under 3:1 on most backdrops).
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        rect.fill()
        OverlayChrome.strokeEdge(around: rect, within: bounds)

        if let appName {
            let chip = OverlayGeometry.titleChipFrame(
                textSize: appName.size(withAttributes: Self.titleChipAttributes),
                window: rect,
                bounds: bounds
            )
            if let chip {
                OverlayChrome.drawChip(
                    appName,
                    attributes: Self.titleChipAttributes,
                    frame: chip,
                    padding: OverlayGeometry.titleChipPadding
                )
            }
        }
    }

    private static let titleChipAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
}

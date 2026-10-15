import AppKit

/// Actions offered by the post-capture preview panel, in display order.
/// Record comes last: the five screenshot actions keep their places.
enum PreviewAction: CaseIterable {
    case edit, copy, save, ocr, pin, record

    var title: String {
        switch self {
        case .edit: "Edit"
        case .copy: "Copy"
        case .save: "Save"
        case .ocr: "OCR"
        case .pin: "Pin"
        case .record: "Record"
        }
    }

    var symbolName: String {
        switch self {
        // HIG standard icons: `pencil` means Rename, so Edit uses the Markup
        // symbol; Copy uses the standard `document.on.document`.
        case .edit: "pencil.tip.crop.circle"
        case .copy: "document.on.document"
        case .save: "square.and.arrow.down"
        case .ocr: "text.viewfinder"
        case .pin: "pin"
        case .record: "record.circle"
        }
    }

    /// Single-key shortcut while the panel is key, advertised (uppercase) in
    /// the tooltip.
    var shortcutKey: String {
        switch self {
        case .edit: "e"
        case .copy: "c"
        case .save: "s"
        case .ocr: "o"
        case .pin: "p"
        case .record: "r"
        }
    }

    /// Tooltip in the app-wide "… (KEY)" form, led by a verb phrase that says
    /// what the action does rather than repeating the button's name (HIG
    /// Offering help). Save names the destination folder.
    func toolTip(saveFolderName: String) -> String {
        let description = switch self {
        case .edit: "Annotate in the editor"
        case .copy: "Copy image to clipboard"
        case .save: "Save PNG to \(saveFolderName)"
        case .ocr: "Recognize text and copy it"
        case .pin: "Pin above all windows"
        case .record: "Record this area"
        }
        return "\(description) (\(shortcutKey.uppercased()))"
    }
}

/// Floating post-capture panel: image preview on top, the action buttons
/// below. A non-activating `NSPanel` so clicking it never activates Snappy or
/// pulls focus from the frontmost app. Esc and click-away dismiss it; the
/// coordinator dismisses it after actions.
@MainActor
final class PreviewPanelController {
    /// The capture the panel is showing.
    let image: CGImage
    /// Backing scale the capture was taken at (pixels per point).
    let scale: CGFloat
    /// Captured area in AppKit global coordinates — the panel anchors to it,
    /// and Pin reuses it as the pin window's position.
    let anchorRect: CGRect
    /// The screen the panel was shown on — the capture's display, which Record
    /// keeps the recording on (one display per recording).
    private(set) var screen: NSScreen?

    private let panel: PreviewPanel
    private let onAction: (PreviewAction) -> Void
    private let onDismiss: () -> Void
    private var mouseMonitors: [Any] = []
    private var keyMonitor: Any?
    private var closed = false

    private static let maxPreviewSize = CGSize(width: 320, height: 240)
    private static let buttonSize = CGSize(width: 32, height: 28)
    private static let glassCornerRadius: CGFloat = 18
    private static let contentInset: CGFloat = 10

    init(
        image: CGImage,
        scale: CGFloat,
        anchorRect: CGRect,
        onAction: @escaping (PreviewAction) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.image = image
        self.scale = scale
        self.anchorRect = anchorRect
        self.onAction = onAction
        self.onDismiss = onDismiss
        panel = PreviewPanel()
        buildContent()
        panel.onEsc = { [weak self] in self?.dismiss() }
        panel.onActionKey = { [weak self] action in self?.onAction(action) }
    }

    /// Image size in points at 1:1 (pixels ÷ backing scale).
    var imagePointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    // MARK: - Lifecycle

    func show(on screen: NSScreen) {
        self.screen = screen
        let origin = PanelGeometry.panelOrigin(
            panelSize: panel.frame.size,
            anchorRect: anchorRect,
            screenFrame: screen.visibleFrame
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        // Grants key without activating (non-activating panel), so Esc works.
        panel.makeKey()
        installMonitors()
    }

    /// Orders the panel out without calling `onDismiss` — used by the
    /// coordinator after an action was chosen.
    func close() {
        guard !closed else { return }
        closed = true
        removeMonitors()
        panel.orderOut(nil)
    }

    /// User dismissal (Esc / click-away): closes and notifies the coordinator.
    private func dismiss() {
        guard !closed else { return }
        close()
        onDismiss()
    }

    // MARK: - Content

    private func buildContent() {
        let pointSize = imagePointSize
        let fit = min(1, Self.maxPreviewSize.width / pointSize.width,
                      Self.maxPreviewSize.height / pointSize.height)
        let previewSize = CGSize(width: pointSize.width * fit, height: pointSize.height * fit)

        let nsImage = NSImage(cgImage: image, size: pointSize)
        let imageView = NSImageView(image: nsImage)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Tahoe Glass: concentric corners — the preview's radius is the
        // glass radius minus the 10 pt inset around it.
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.glassCornerRadius - Self.contentInset
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: previewSize.width),
            imageView.heightAnchor.constraint(equalToConstant: previewSize.height),
        ])

        let saveFolderName = FileManager.default.displayName(atPath: SettingsStore.shared.saveDirectory.path)
        let buttons = PreviewAction.allCases.map { action in
            let image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)
                ?? NSImage()
            let button = NSButton(image: image, target: self, action: #selector(buttonClicked(_:)))
            // Borderless toolbar style (hover highlight only) — no bezel boxes
            // stacked on the glass. `.toolbar` ignores controlSize and sizes to
            // ~27×23 pt, so pin the HIG default macOS control size (28 pt).
            button.bezelStyle = .toolbar
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.buttonSize.width),
                button.heightAnchor.constraint(equalToConstant: Self.buttonSize.height),
            ])
            button.toolTip = action.toolTip(saveFolderName: saveFolderName)
            button.tag = PreviewAction.allCases.firstIndex(of: action)!
            return button
        }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [imageView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The inset lives on a container, not on `stack.edgeInsets`: a vertical
        // stack with `.centerX` alignment drops its left/right edge insets, which
        // put the image flush against the glass and broke the concentric corners.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        let inset = Self.contentInset
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
        ])

        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.glassCornerRadius
        glass.contentView = container
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: glass.topAnchor),
            container.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
        ])

        let size = container.fittingSize
        panel.setContentSize(size)
        panel.contentView = glass
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        onAction(PreviewAction.allCases[sender.tag])
    }

    // MARK: - Dismissal monitors

    private func installMonitors() {
        // Clicks in other apps (global monitors never see our own events).
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { _ in
                MainActor.assumeIsolated {
                    self.dismiss()
                }
            }
        )
        if let globalMonitor {
            mouseMonitors.append(globalMonitor)
        }
        // Clicks on our own windows other than the panel (pins, editor, menu).
        // Inspect NSEvent outside assumeIsolated — NSEvent is non-Sendable.
        let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak panel] event in
                guard event.window !== panel else { return event }
                MainActor.assumeIsolated {
                    self.dismiss()
                }
                return event
            }
        )
        if let localMonitor {
            mouseMonitors.append(localMonitor)
        }
        // Esc fallback while another of our windows is key.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
            guard event.keyCode == 53, event.window === panel else { return event }
            MainActor.assumeIsolated {
                self.dismiss()
            }
            return nil
        }
    }

    private func removeMonitors() {
        for monitor in mouseMonitors {
            NSEvent.removeMonitor(monitor)
        }
        mouseMonitors = []
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// Borderless non-activating floating panel that can take key status (for Esc)
/// without activating the app.
@MainActor
private final class PreviewPanel: NSPanel {
    var onEsc: (() -> Void)?
    var onActionKey: ((PreviewAction) -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 53 || key == "q" { // Esc / Q dismiss
            onEsc?()
            return
        }
        // Single-key action shortcuts (E/C/S/O/P/R), advertised in the tooltips.
        if ShortcutKeys.isBareKey(event.modifierFlags),
           let key,
           let action = PreviewAction.allCases.first(where: { $0.shortcutKey == key }) {
            onActionKey?(action)
            return
        }
        super.keyDown(with: event)
    }
}

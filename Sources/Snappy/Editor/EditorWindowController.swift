import AppKit

/// The editor's non-tool toolbar actions. Tooltips live here (pure,
/// unit-tested) in the app-wide "<verb phrase> (KEY)" form shared with
/// `PreviewAction.toolTip(saveFolderName:)`.
enum EditorAction: CaseIterable {
    case copy, save, pin, undo, redo

    var label: String {
        switch self {
        case .copy: "Copy"
        case .save: "Save"
        case .pin: "Pin"
        case .undo: "Undo"
        case .redo: "Redo"
        }
    }

    /// Copy/Undo/Redo are HIG standard icons (`icons.md` › Standard icons).
    var symbolName: String {
        switch self {
        case .copy: "document.on.document"
        case .save: "square.and.arrow.down"
        case .pin: "pin"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        }
    }

    /// Display-only: the bindings themselves live in the canvas's
    /// `performKeyEquivalent`.
    var shortcut: String {
        switch self {
        case .copy: "⇧⌘C"
        case .save: "⌘S"
        case .pin: "⌘P"
        case .undo: "⌘Z"
        case .redo: "⇧⌘Z"
        }
    }

    /// Says what the action does rather than repeating the button's name
    /// (HIG Offering help); Save names the destination folder like the panel.
    func toolTip(saveFolderName: String) -> String {
        let description = switch self {
        case .copy: "Copy and close"
        case .save: "Save PNG to \(saveFolderName)"
        case .pin: "Pin above all windows and close"
        case .undo: "Revert the last change"
        case .redo: "Reapply the last undone change"
        }
        return "\(description) (\(shortcut))"
    }
}

/// The annotation editor (M4–M6), in the Tahoe Glass look (2026-10-08): one
/// unified header — the macOS window controls and all actions
/// share a single titlebar (`NSToolbar`, `.unified`: 36 pt system hit
/// targets — `.unifiedCompact` gives 24 pt) whose Liquid Glass groups float
/// over the AnnotationCanvasView (full-size content view, transparent
/// titlebar). Owns the document; Copy/Save/Pin flatten via
/// AnnotationRenderer, so the export is pixel-identical to the canvas.
///
/// Toolbar structure (author feedback, 2026-07-18): every action is its OWN
/// toolbar item — never a monolithic segmented control — so NSToolbar's
/// native "…" overflow menu absorbs whatever doesn't fit and returns items
/// as the window grows. Groups, in order: Undo·Redo, the tools (primary six
/// first: Select·Arrow·Text·Rectangle·Blur·Counter), style controls, then
/// Save·Pin and the prominent Copy at the trailing edge (the "done" action).
/// Visibility priorities make the "rest" overflow before the primary groups.
@MainActor
final class EditorWindowController: NSObject {
    private let window: NSWindow
    private let document: AnnotationDocument
    private let canvas: AnnotationCanvasView
    private let settings: SettingsStore
    /// Called with the flattened image, its backing scale, and a suggested pin
    /// frame (AppKit global points) when the user pins from the editor.
    private let onPin: (CGImage, CGFloat, CGRect) -> Void
    /// Fired (on the next run-loop turn) when the window closes by any route —
    /// Copy, Pin, Q, Esc, the traffic light — so the coordinator can release
    /// this controller, its window's only strong owner.
    private let onClose: (EditorWindowController) -> Void
    private let toolbar = NSToolbar(identifier: "SnappyEditorToolbar")
    /// Glass capsule at the bottom centre: "Shot W × H · 100%".
    private let statusLabel = NSTextField(labelWithString: "")

    /// `.minimal`: swatch + chevron with the system colour popover — the
    /// well style meant for toolbars (no bezel box on the glass).
    private let colorWell = NSColorWell(style: .minimal)
    private let widthPopup = NSPopUpButton()
    private let fillCheckbox: NSButton

    /// Stroke widths offered in the popup, in screen points (multiplied by the
    /// capture's backing scale to get the model's image-pixel width). Also
    /// drives text size and counter badge size (see TextGeometry/CounterGeometry).
    private static let strokeWidthsInPoints: [CGFloat] = [1, 2, 3, 5, 8]

    init(
        image: CGImage,
        scale: CGFloat,
        settings: SettingsStore = .shared,
        onPin: @escaping (CGImage, CGFloat, CGRect) -> Void,
        onClose: @escaping (EditorWindowController) -> Void
    ) {
        self.settings = settings
        self.onPin = onPin
        self.onClose = onClose
        document = AnnotationDocument(image: image, scale: scale)
        canvas = AnnotationCanvasView(
            document: document, style: .defaultStyle(scale: scale), settings: settings
        )
        // A half-filled shape reads as "fill the highlight"; the old
        // paintbrush read as a drawing tool next to Pen.
        fillCheckbox = NSButton(image: Self.symbol("square.lefthalf.filled", "Fill"), target: nil, action: nil)

        let pointSize = CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let fit = min(1, visible.width * 0.8 / pointSize.width, visible.height * 0.7 / pointSize.height)
        // Small captures still open wide enough that NO toolbar item starts in
        // the overflow menu (HIG Toolbars); never wider than the screen, never
        // narrower than minSize (primary groups visible — author feedback).
        let canvasSize = CGSize(
            width: max(
                Self.minWindowSize.width,
                min(Self.fullToolbarWidth, visible.width),
                pointSize.width * fit
            ),
            height: max(360, pointSize.height * fit)
        )

        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: canvasSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Hidden in the titlebar, but VoiceOver, Mission Control and window
        // lists read it — and several editors can be open at once.
        window.title = Self.windowTitle(pointSize: pointSize)
        window.isReleasedWhenClosed = false
        window.minSize = Self.minWindowSize

        super.init()

        window.delegate = self

        configureControls()
        // Start from the canvas's creation style — the model's colour
        // (AnnotationColor.red, #FF3B30), not `.systemRed`, which is #FF383C
        // light / #FF4245 dark and got baked into the next annotation by the
        // first unrelated style change (d-canvas review I7).
        syncControls(with: nil)

        // The canvas fills the whole window, under the glass toolbar; the only
        // other content is the status capsule floating above its bottom edge.
        window.titlebarAppearsTransparent = true
        let container = NSView(frame: CGRect(origin: .zero, size: canvasSize))
        canvas.frame = container.bounds
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        installStatusCapsule(in: container)
        window.contentView = container
        window.setContentSize(canvasSize)

        // One unified header: window controls + actions share the
        // titlebar; every control is its own NSToolbarItem. `.unified` (52 pt
        // bar, 36×36 pt items) rather than `.unifiedCompact` (40 pt bar,
        // 24 pt items): HIG default macOS control size is 28 pt.
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = Self.identifier(for: canvas.tool)

        document.onChange = { [weak self] in
            guard let self else { return }
            self.canvas.documentDidChange()
            self.toolbar.validateVisibleItems()
            // Crop (and its undo/redo) changes the image size in the title;
            // canvas growth changes the zoom.
            self.refreshTitle()
            self.refreshStatus()
        }
        canvas.onViewportChange = { [weak self] in self?.refreshStatus() }
        canvas.onSelectionChange = { [weak self] annotation in
            self?.syncControls(with: annotation)
        }
        canvas.onCommand = { [weak self] command in
            switch command {
            case .copy: self?.copyExport()
            case .save: self?.saveExport()
            case .pin: self?.pinExport()
            case .selectTool(let tool): self?.selectTool(tool)
            case .close: self?.window.close()
            }
        }
    }

    func show() {
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        refreshStatus()
    }

    /// Space kept below the capture for the status capsule (capsule height
    /// plus its gap to the window edge and to the capture).
    private static let statusBand: CGFloat = 44

    /// The bottom status capsule: a passive readout, so it ignores the mouse
    /// (`StatusGlassView`) and drawing works right up to the window edge.
    private func installStatusCapsule(in container: NSView) {
        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let glass = StatusGlassView()
        glass.cornerRadius = 14
        let inner = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(statusLabel)
        glass.contentView = inner
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
            inner.topAnchor.constraint(equalTo: glass.topAnchor),
            inner.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            glass.heightAnchor.constraint(equalToConstant: 28),
            glass.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        canvas.bottomInset = Self.statusBand
    }

    private func refreshStatus() {
        let text = EditorStatus.text(title: window.title, zoomPercent: canvas.zoomPercent)
        if statusLabel.stringValue != text { statusLabel.stringValue = text }
    }

    /// Minimum window size — wide enough that the export group and the six
    /// primary tools stay visible in the titlebar (the rest may overflow).
    private static let minWindowSize = CGSize(width: 700, height: 400)

    /// Content width at which every toolbar item fits without overflowing:
    /// measured 940 pt on macOS 26 (`.unified`, iconOnly, 12 pt symbols),
    /// plus a margin. Re-measure when items are added or restyled.
    private static let fullToolbarWidth: CGFloat = 960

    /// Window title — never the app name (HIG Toolbars › Titles), short, and
    /// distinct between editors of different captures.
    static func windowTitle(pointSize: CGSize) -> String {
        "Shot \(Int(pointSize.width.rounded())) × \(Int(pointSize.height.rounded()))"
    }

    private func refreshTitle() {
        let title = Self.windowTitle(pointSize: CGSize(
            width: CGFloat(document.image.width) / document.scale,
            height: CGFloat(document.image.height) / document.scale
        ))
        if window.title != title { window.title = title }
    }

    /// The Save tooltip names the folder Save will actually write to; the
    /// folder can change in Settings while an editor stays open.
    private func refreshSaveToolTip() {
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == .editorSave }) else { return }
        item.toolTip = EditorAction.save.toolTip(saveFolderName: saveFolderName)
    }

    private var saveFolderName: String {
        FileManager.default.displayName(atPath: settings.saveDirectory.path)
    }

    // MARK: - Controls

    /// Tooltips for the style controls (no key: they have no shortcut).
    static let colorToolTip = "Choose the annotation color"
    static let sizeToolTip = "Set stroke width, text size and badge size"
    static let fillToolTip = "Fill rectangles and ovals with a tint"

    private func configureControls() {
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.isContinuous = false
        colorWell.toolTip = Self.colorToolTip
        colorWell.setAccessibilityLabel("Color")

        for width in Self.strokeWidthsInPoints {
            widthPopup.addItem(withTitle: "\(Int(width)) pt")
            widthPopup.lastItem?.tag = Int(width)
        }
        widthPopup.selectItem(withTag: 3)
        widthPopup.target = self
        widthPopup.action = #selector(styleChanged)
        widthPopup.toolTip = Self.sizeToolTip
        widthPopup.setAccessibilityLabel("Size")

        fillCheckbox.target = self
        fillCheckbox.action = #selector(styleChanged)
        fillCheckbox.setButtonType(.pushOnPushOff)
        fillCheckbox.toolTip = Self.fillToolTip

        // Toolbar-style bezels (hover/on-state highlight only, no bezel box on
        // the glass). NSToolbar sizes view items itself — 36 pt tall in the
        // `.unified` bar — so no controlSize or width pins here.
        widthPopup.bezelStyle = .toolbar
        fillCheckbox.bezelStyle = .toolbar
    }

    /// Small, smooth SF Symbols (author feedback: modern and a bit smaller).
    private static func symbol(_ name: String, _ description: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        return image.withSymbolConfiguration(configuration) ?? image
    }

    // MARK: - Actions

    @objc private func toolItemClicked(_ sender: NSToolbarItem) {
        guard let spec = Self.toolSpecs.first(where: { $0.id == sender.itemIdentifier }) else { return }
        canvas.tool = spec.tool
        window.makeFirstResponder(canvas)
    }

    /// Tool switch from a canvas keyboard shortcut — keeps the toolbar
    /// selection in sync.
    private func selectTool(_ tool: EditorTool) {
        canvas.tool = tool
        toolbar.selectedItemIdentifier = Self.identifier(for: tool)
    }

    @objc private func styleChanged() {
        canvas.apply(style: styleFromControls())
        window.makeFirstResponder(canvas)
    }

    @objc private func undoTapped() {
        document.undoManager.undo()
        window.makeFirstResponder(canvas)
    }

    @objc private func redoTapped() {
        document.undoManager.redo()
        window.makeFirstResponder(canvas)
    }

    @objc private func copyTapped() { copyExport() }
    @objc private func saveTapped() { saveExport() }
    @objc private func pinTapped() { pinExport() }

    // Overflow-menu forms of the style controls (custom-view items have no
    // usable menu form of their own): they drive the same controls, so
    // `styleFromControls()` stays the single source.

    @objc private func colorMenuChosen(_ sender: NSMenuItem) {
        colorWell.activate(true) // opens the shared Colors panel on this well
    }

    @objc private func sizeMenuChosen(_ sender: NSMenuItem) {
        widthPopup.selectItem(withTag: sender.tag)
        styleChanged()
    }

    @objc private func fillMenuChosen(_ sender: NSMenuItem) {
        fillCheckbox.state = fillCheckbox.state == .on ? .off : .on
        styleChanged()
    }

    /// Model colour → well colour: fixed sRGB components, so the colour can
    /// never follow the appearance the way a system colour does.
    static func wellColor(for color: AnnotationColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// Well colour → model colour (sRGB); `.red` if it has no sRGB form.
    static func annotationColor(from color: NSColor) -> AnnotationColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return .red }
        return AnnotationColor(
            red: srgb.redComponent, green: srgb.greenComponent,
            blue: srgb.blueComponent, alpha: srgb.alphaComponent
        )
    }

    private func styleFromControls() -> AnnotationStyle {
        let color = Self.annotationColor(from: colorWell.color)
        let widthInPoints = CGFloat(widthPopup.selectedTag())
        return AnnotationStyle(
            strokeColor: color,
            strokeWidth: max(1, widthInPoints) * document.scale,
            hasFill: fillCheckbox.state == .on
        )
    }

    /// Mirrors the selected annotation's style into the controls — or, with no
    /// selection, the canvas's current creation style (programmatic updates
    /// don't fire the controls' actions, so this can't loop).
    private func syncControls(with annotation: Annotation?) {
        // No selection: the controls describe what the NEXT annotation will use.
        let style = annotation?.style ?? canvas.currentStyle
        colorWell.color = Self.wellColor(for: style.strokeColor)
        let widthInPoints = Int((style.strokeWidth / document.scale).rounded())
        let nearest = Self.strokeWidthsInPoints.min {
            abs($0 - CGFloat(widthInPoints)) < abs($1 - CGFloat(widthInPoints))
        }
        widthPopup.selectItem(withTag: Int(nearest ?? 3))
        fillCheckbox.state = style.hasFill ? .on : .off
    }

    // MARK: - Export

    /// Every export path starts here: a label still being typed lives only in
    /// the overlay text field, so it must reach the document before flattening.
    private func flattenedImage() -> CGImage? {
        canvas.commitPendingEdits()
        // Include any auto-expanded canvas area (M-F): Copy/Save/Pin all embed
        // the expansion, so a pinned/reopened result carries it baked in.
        let canvasRect = document.canvasRect(padding: settings.canvasPadding * document.scale)
        // The background is only needed (and only sampled) when the canvas grew.
        let background = canvasRect == document.imageBounds ? nil : document.canvasBackground
        return AnnotationRenderer.flatten(
            image: document.image, annotations: document.annotations,
            canvasRect: canvasRect, background: background
        )
    }

    private func copyExport() {
        guard let image = flattenedImage() else {
            showAlert(UserFacingText.annotatedImageFailed)
            return
        }
        Clipboard.copy(image, scale: document.scale)
        // Copy is a "done" action: close the editor (author feedback).
        window.close()
    }

    private func saveExport() {
        guard let image = flattenedImage() else {
            showAlert(UserFacingText.annotatedImageFailed)
            return
        }
        do {
            try ScreenshotSaver.save(image, scale: document.scale, to: settings.saveDirectory)
        } catch {
            let folderName = FileManager.default.displayName(atPath: settings.saveDirectory.path)
            showAlert(UserFacingText.saveFailed(error, folderName: folderName))
        }
    }

    /// Pin is a "done" action like Copy: the annotated result floats on top
    /// (centered where the editor was, 1:1 points) and the editor closes.
    private func pinExport() {
        guard let image = flattenedImage() else {
            showAlert(UserFacingText.annotatedImageFailed)
            return
        }
        let size = CGSize(
            width: CGFloat(image.width) / document.scale,
            height: CGFloat(image.height) / document.scale
        )
        let editorFrame = window.frame
        let pinFrame = CGRect(
            x: editorFrame.midX - size.width / 2,
            y: editorFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        onPin(image, document.scale, pinFrame)
        window.close()
    }

    /// A sheet on this editor, not an app-modal alert: `runModal` froze every
    /// pin and every other editor until dismissed.
    /// Shared copy from `UserFacingText`, shown as a sheet so pins and other
    /// editors stay usable.
    private func showAlert(_ text: AlertText) {
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.beginSheetModal(for: window)
    }
}

// MARK: - Window lifecycle

extension EditorWindowController: NSWindowDelegate {
    /// Coming back from Settings makes the editor key again.
    func windowDidBecomeKey(_ notification: Notification) {
        refreshSaveToolTip()
    }

    func windowWillClose(_ notification: Notification) {
        // Deferred: closing is often triggered from this controller's own
        // methods (Copy/Pin), and releasing it mid-call — or mid-close, while
        // AppKit still talks to its window delegate — is not safe.
        EffectRenderer.clearCache() // it holds the editor's base image alive
        Task { @MainActor [self] in onClose(self) }
    }
}

// MARK: - Unified titlebar toolbar

/// The status capsule shows text only — clicks and drags pass through to the
/// canvas underneath.
private final class StatusGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSToolbarItem.Identifier {
    static let editorCopy = Self("editorCopy")
    static let editorSave = Self("editorSave")
    static let editorPin = Self("editorPin")
    static let editorColor = Self("editorColor")
    static let editorWidth = Self("editorWidth")
    static let editorFill = Self("editorFill")
    static let editorUndo = Self("editorUndo")
    static let editorRedo = Self("editorRedo")
}

extension EditorWindowController: NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    struct ToolSpec {
        let id: NSToolbarItem.Identifier
        let tool: EditorTool
        let symbol: String
        let label: String
        /// What the tool does — a verb phrase, never just the label.
        let help: String
        /// Display-only: the bindings live in the canvas's `keyDown`.
        let key: String
        /// Primary tools stay visible; the rest overflow into "…" first.
        let primary: Bool

        /// App-wide tooltip form "<verb phrase> (KEY)", sentence case.
        var toolTip: String { "\(help) (\(key))" }
    }

    /// Tool order: the six primary tools first, then the rest.
    static let toolSpecs: [ToolSpec] = [
        ToolSpec(id: .init("toolSelect"), tool: .select, symbol: "cursorarrow", label: "Select",
                 help: "Select, move and resize annotations", key: "V", primary: true),
        ToolSpec(id: .init("toolArrow"), tool: .arrow, symbol: "arrow.up.right", label: "Arrow",
                 help: "Draw an arrow from tail to head", key: "A", primary: true),
        ToolSpec(id: .init("toolText"), tool: .text, symbol: "textformat", label: "Text",
                 help: "Add a text label", key: "T", primary: true),
        ToolSpec(id: .init("toolRectangle"), tool: .shape(.rectangle), symbol: "rectangle", label: "Rectangle",
                 help: "Highlight an area with a rectangle", key: "R", primary: true),
        ToolSpec(id: .init("toolBlur"), tool: .effect(.blur), symbol: "drop", label: "Blur",
                 help: "Blur a region to hide it", key: "B", primary: true),
        ToolSpec(id: .init("toolCounter"), tool: .counter, symbol: "1.circle", label: "Counter",
                 help: "Add numbered step badges", key: "N", primary: true),
        ToolSpec(id: .init("toolOval"), tool: .shape(.oval), symbol: "oval", label: "Oval",
                 help: "Highlight an area with an oval", key: "O", primary: false),
        ToolSpec(id: .init("toolLine"), tool: .line, symbol: "line.diagonal", label: "Line",
                 help: "Draw a straight line", key: "L", primary: false),
        ToolSpec(id: .init("toolPen"), tool: .freehand, symbol: "scribble", label: "Pen",
                 help: "Draw freehand", key: "P", primary: false),
        ToolSpec(id: .init("toolPixelate"), tool: .effect(.pixelate), symbol: "rectangle.split.3x3", label: "Pixelate",
                 help: "Pixelate a region to hide it", key: "X", primary: false),
        ToolSpec(id: .init("toolCrop"), tool: .crop, symbol: "crop", label: "Crop",
                 help: "Crop the image", key: "C", primary: false),
    ]

    fileprivate static func identifier(for tool: EditorTool) -> NSToolbarItem.Identifier? {
        toolSpecs.first { $0.tool == tool }?.id
    }

    /// Symbol/label lookup shared with the tool-aware cursor: the cursor badge
    /// and tool-name flash must match the toolbar exactly.
    static func toolSpec(for tool: EditorTool) -> (symbol: String, label: String)? {
        toolSpecs.first { $0.tool == tool }.map { ($0.symbol, $0.label) }
    }

    /// Tahoe Glass groups: Undo·Redo after the traffic lights, the tools
    /// (primary six first) and the style controls in the middle, and the
    /// export group at the trailing edge, ending on the prominent Copy — the
    /// HIG's place for the "done" action.
    static var toolbarOrder: [NSToolbarItem.Identifier] {
        [.editorUndo, .editorRedo, .flexibleSpace]
            + toolSpecs.map(\.id)
            + [.space, .editorColor, .editorWidth, .editorFill,
               .flexibleSpace, .editorSave, .editorPin, .editorCopy]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarOrder
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarOrder
    }

    /// The tool items behave as a radio group: NSToolbar highlights the
    /// selected one (kept in sync with keyboard tool shortcuts).
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolSpecs.map(\.id)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if let spec = Self.toolSpecs.first(where: { $0.id == itemIdentifier }) {
            return imageItem(
                itemIdentifier, symbol: spec.symbol, label: spec.label, tip: spec.toolTip,
                action: #selector(toolItemClicked), priority: spec.primary ? .high : .standard
            )
        }
        switch itemIdentifier {
        case .editorCopy:
            // Tinted with the accent colour on its own glass platter.
            let item = actionItem(.copy, action: #selector(copyTapped), priority: .high)
            item.style = .prominent
            return item
        case .editorSave: return actionItem(.save, action: #selector(saveTapped), priority: .high)
        case .editorPin: return actionItem(.pin, action: #selector(pinTapped), priority: .high)
        case .editorUndo: return actionItem(.undo, action: #selector(undoTapped), priority: .low)
        case .editorRedo: return actionItem(.redo, action: #selector(redoTapped), priority: .low)
        case .editorColor:
            return viewItem(itemIdentifier, view: colorWell, label: "Color", menuForm: colorMenuForm())
        case .editorWidth:
            return viewItem(itemIdentifier, view: widthPopup, label: "Size", menuForm: sizeMenuForm())
        case .editorFill:
            return viewItem(itemIdentifier, view: fillCheckbox, label: "Fill", menuForm: fillMenuForm())
        default:
            return nil
        }
    }

    private func actionItem(
        _ action: EditorAction, action selector: Selector, priority: NSToolbarItem.VisibilityPriority
    ) -> NSToolbarItem {
        imageItem(
            identifier(for: action), symbol: action.symbolName, label: action.label,
            tip: action.toolTip(saveFolderName: saveFolderName), action: selector, priority: priority
        )
    }

    private func identifier(for action: EditorAction) -> NSToolbarItem.Identifier {
        switch action {
        case .copy: .editorCopy
        case .save: .editorSave
        case .pin: .editorPin
        case .undo: .editorUndo
        case .redo: .editorRedo
        }
    }

    /// Image-based items (not custom views) participate fully in the native
    /// "…" overflow menu — they appear there with their label and stay
    /// clickable.
    private func imageItem(
        _ id: NSToolbarItem.Identifier, symbol: String, label: String, tip: String,
        action: Selector, priority: NSToolbarItem.VisibilityPriority
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = Self.symbol(symbol, label)
        item.label = label
        item.toolTip = tip
        item.target = self
        item.action = action
        item.isBordered = true
        item.visibilityPriority = priority
        return item
    }

    /// Custom-view items need an explicit menu form: AppKit's default one is
    /// a bare label with no state, so an overflowed Size or Fill showed
    /// neither the current value nor a way to change it.
    private func viewItem(
        _ id: NSToolbarItem.Identifier, view: NSView, label: String, menuForm: NSMenuItem
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = view
        item.label = label
        item.toolTip = view.toolTip
        item.menuFormRepresentation = menuForm
        item.visibilityPriority = .standard
        return item
    }

    private func colorMenuForm() -> NSMenuItem {
        let item = NSMenuItem(title: "Color…", action: #selector(colorMenuChosen), keyEquivalent: "")
        item.target = self
        return item
    }

    private func sizeMenuForm() -> NSMenuItem {
        let item = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Size")
        for width in Self.strokeWidthsInPoints {
            let entry = NSMenuItem(title: "\(Int(width)) pt", action: #selector(sizeMenuChosen), keyEquivalent: "")
            entry.tag = Int(width)
            entry.target = self
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func fillMenuForm() -> NSMenuItem {
        let item = NSMenuItem(title: "Fill", action: #selector(fillMenuChosen), keyEquivalent: "")
        item.target = self
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .editorUndo: document.undoManager.canUndo
        case .editorRedo: document.undoManager.canRedo
        default: true
        }
    }

    /// Overflow-menu entries: checkmarks mirror the controls, and Undo/Redo
    /// stay disabled when there is nothing to undo — the toolbar validation
    /// above does not reach their menu forms.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(sizeMenuChosen):
            menuItem.state = menuItem.tag == widthPopup.selectedTag() ? .on : .off
        case #selector(fillMenuChosen):
            menuItem.state = fillCheckbox.state
        case #selector(undoTapped):
            return document.undoManager.canUndo
        case #selector(redoTapped):
            return document.undoManager.canRedo
        default:
            break
        }
        return true
    }
}

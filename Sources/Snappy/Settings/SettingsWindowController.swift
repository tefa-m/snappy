import AppKit

/// Single-pane settings window ("Snappy Settings"): save folder, the capture
/// shortcuts (click-to-record fields, `HotKeyField`) and how to free them
/// from macOS, the editor options and the Recording section
/// (`RecordingSettingsSection`, with the Draw Mode / Magic Pen fields).
@MainActor
final class SettingsWindowController: NSObject {
    private let settings: SettingsStore
    private let hotKeys: GlobalHotKeys
    let window: NSWindow // internal for tests
    /// Pop-up path control: folder icon + name, its menu lists the parent
    /// folders plus a Choose… item (HIG Path controls) — replaces a raw POSIX
    /// path label and a separate Choose… button.
    private let folderControl = NSPathControl()
    private let cursorCheckbox = NSButton(
        checkboxWithTitle: "Show tool icon next to the pointer",
        target: nil, action: nil
    )
    private let paddingField = NSTextField(string: "")
    private let paddingStepper = NSStepper()
    private let recording: RecordingSettingsSection
    private let captureAreaField: HotKeyField
    private let fullscreenField: HotKeyField
    private let grid = NSGridView()
    /// Holds the pane; scrolls only when the pane is taller than the screen
    /// allows (`SettingsPaneFit`).
    private let scrollView = NSScrollView()
    private var hasBeenShown = false
    /// Margin between the window edges and the grid.
    private static let paneInset: CGFloat = 20

    /// Opens System Settings › Keyboard; the Screenshots shortcuts sit one
    /// sheet deeper (Keyboard Shortcuts…), which no URL reaches.
    private static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    private static let shortcutHintText =
        "For these to work, turn off the macOS screenshot shortcuts in Keyboard Shortcuts… › Screenshots."

    /// `setMagicPenWidth` is `RecordingCoordinator.setMagicPenWidth` — the
    /// thickness applies live during a session, like the menu bar's.
    /// `hotKeys` binds a recorded shortcut at once (nil: only saved).
    init(
        settings: SettingsStore = .shared,
        hotKeys: GlobalHotKeys? = nil,
        setMagicPenWidth: @escaping @MainActor (InkWidth) -> Void
    ) {
        self.settings = settings
        let hotKeys = hotKeys ?? GlobalHotKeys(settings: settings, center: nil)
        self.hotKeys = hotKeys
        recording = RecordingSettingsSection(settings: settings, hotKeys: hotKeys, setMagicPenWidth: setMagicPenWidth)
        // One hint for both capture fields; a refusal replaces it.
        let shortcutHint = Self.hintLabel(Self.shortcutHintText)
        let captureKeys: [SnappyHotKey] = [.captureArea, .captureFullscreen]
        captureAreaField = HotKeyField(
            .captureArea, hotKeys: hotKeys, hint: shortcutHint, hintText: Self.shortcutHintText, sharedBy: captureKeys
        )
        fullscreenField = HotKeyField(
            .captureFullscreen, hotKeys: hotKeys, hint: shortcutHint, hintText: Self.shortcutHintText,
            sharedBy: captureKeys
        )
        window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable], // minimize/zoom dimmed (HIG Settings)
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Snappy Settings"
        window.isReleasedWhenClosed = false

        folderControl.pathStyle = .popUp
        folderControl.isEditable = true
        // Folders only — the default (nil) accepts any dropped file.
        folderControl.allowedTypes = ["public.folder"]
        folderControl.delegate = self
        folderControl.target = self
        folderControl.action = #selector(folderChanged)
        folderControl.setAccessibilityLabel("Save screenshots to")

        let keyboardButton = NSButton(
            title: "Open Keyboard Settings",
            target: self,
            action: #selector(openKeyboardSettings)
        )

        cursorCheckbox.target = self
        cursorCheckbox.action = #selector(cursorCheckboxToggled)

        // Design decision: ≥ 28 pt controls. `.large` is AppKit's own size for
        // that (push button 28 pt tall, stepper 23 × 30 pt, same 13 pt font);
        // the number field and the pop-up path control have no large variant
        // (measured 24 / 25 pt either way) and keep their native bezels.
        for control in [keyboardButton, cursorCheckbox, paddingStepper] as [NSControl] {
            control.controlSize = .large
        }

        // Stepper + editable field (HIG Steppers: pair with a field when large
        // changes are likely — 0…100 in steps of 4 is up to 25 clicks). The old
        // small stepper measured 17×22 pt, under the 20 pt minimum.
        paddingStepper.minValue = Double(CanvasPaddingInput.range.lowerBound)
        paddingStepper.maxValue = Double(CanvasPaddingInput.range.upperBound)
        paddingStepper.increment = 4
        paddingStepper.valueWraps = false
        paddingStepper.target = self
        paddingStepper.action = #selector(paddingStepped)
        paddingStepper.setAccessibilityLabel("Canvas padding")
        paddingField.alignment = .right
        paddingField.cell?.sendsActionOnEndEditing = true
        paddingField.target = self
        paddingField.action = #selector(paddingTyped)
        paddingField.setAccessibilityLabel("Canvas padding in points")
        paddingField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let paddingRow = NSStackView(views: [
            paddingField, paddingStepper, NSTextField(labelWithString: "pt"),
        ])
        paddingRow.orientation = .horizontal
        paddingRow.alignment = .centerY
        paddingRow.spacing = 6
        let paddingHint = Self.hintLabel("Extra space around annotations that extend past the screenshot.")

        let empty = NSGridCell.emptyContentView
        for row in [
            [NSTextField(labelWithString: "Save screenshots to:"), folderControl],
            [NSTextField(labelWithString: "Capture area:"), captureAreaField.row],
            [NSTextField(labelWithString: "Capture screen:"), fullscreenField.row],
            [empty, shortcutHint],
            [empty, keyboardButton],
            [NSTextField(labelWithString: "Editor:"), cursorCheckbox],
            [NSTextField(labelWithString: "Canvas padding:"), paddingRow],
            [empty, paddingHint],
        ] as [[NSView]] {
            grid.addRow(with: row)
        }
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        // Groups: folder | shortcuts (+ hint, button) | editor | padding (+ hint).
        for row in [1, 5, 6] { grid.row(at: row).topPadding = 10 }
        recording.append(to: grid)
        for field in [captureAreaField, fullscreenField] {
            field.onHeightChange = { [weak self] in self?.fitToScreen() }
        }
        recording.onHeightChange = { [weak self] in self?.fitToScreen() }
        grid.translatesAutoresizingMaskIntoConstraints = false

        // The pane is the scroll view's (flipped, top-anchored) document; the
        // window is sized by `fitToScreen`, not by these constraints.
        let inset = Self.paneInset
        let pane = FlippedView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(grid)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = pane
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: pane.topAnchor, constant: inset),
            grid.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: inset),
            grid.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -inset),
            grid.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -inset),
            pane.topAnchor.constraint(equalTo: clip.topAnchor),
            pane.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            pane.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        window.contentView = scrollView
        window.delegate = self

        // Resolution, display arrangement or Dock changes move the visible frame.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        syncFromSettings()
    }

    /// 11 pt secondary help text under a control, wrapping at the column width.
    fileprivate static func hintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 280
        return label
    }

    /// The Magic Pen thickness changed elsewhere (`RecordingCoordinator
    /// .onMagicPenWidthChange`) — an open window shows it at once.
    func showMagicPenWidth(_ width: InkWidth) {
        recording.showMagicPenWidth(width)
    }

    func show() {
        syncFromSettings()
        NSApp.activate()
        fitToScreen()
        // Centre once; afterwards the window reopens where it was left.
        if !hasBeenShown {
            window.center()
            hasBeenShown = true
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Natural pane size when it fits the screen's visible frame; otherwise as
    /// tall as fits, with the pane scrolling. Keeps the top edge, then slides
    /// the window back into the visible frame — also while it's closed, so a
    /// reopen after a Dock/resolution change lands inside it (`show()` refits
    /// before ordering front).
    private func fitToScreen() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let natural = grid.fittingSize
        let content = CGSize(
            width: ceil(natural.width) + 2 * Self.paneInset,
            height: ceil(natural.height) + 2 * Self.paneInset
        )
        let scrollerWidth = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
        let fit = SettingsPaneFit.fit(
            content: content,
            visibleHeight: screen.visibleFrame.height,
            chromeHeight: window.frameRect(forContentRect: .zero).height,
            scrollerWidth: scrollerWidth
        )
        scrollView.hasVerticalScroller = fit.scrolls
        let frame = SettingsPaneFit.windowFrame(
            size: window.frameRect(forContentRect: NSRect(origin: .zero, size: fit.contentSize)).size,
            keepingTopOf: window.frame,
            in: screen.visibleFrame
        )
        window.setFrame(frame, display: window.isVisible)
    }

    @objc private func screenParametersChanged() {
        if window.isVisible { fitToScreen() }
    }

    private func syncFromSettings() {
        folderControl.url = settings.saveDirectory
        cursorCheckbox.state = settings.toolAwareCursorEnabled ? .on : .off
        showPadding(Int(settings.canvasPadding.rounded()))
        captureAreaField.sync()
        fullscreenField.sync()
        recording.syncFromSettings()
    }

    private func showPadding(_ points: Int) {
        paddingStepper.integerValue = points
        paddingField.stringValue = "\(points)"
    }

    // MARK: - Actions

    @objc private func folderChanged() {
        // Choosing a parent folder from the pop-up menu reports it as the
        // clicked item; Choose… sets the control's URL directly.
        if let clicked = folderControl.clickedPathItem?.url {
            folderControl.url = clicked
        }
        guard let url = folderControl.url, SaveFolderValidation.isUsableFolder(url) else {
            NSSound.beep()
            folderControl.url = settings.saveDirectory
            return
        }
        settings.saveDirectory = url
    }

    @objc private func openKeyboardSettings() {
        if let url = Self.keyboardSettingsURL, NSWorkspace.shared.open(url) { return }
        if let url = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(url) }
    }

    @objc private func cursorCheckboxToggled() {
        settings.toolAwareCursorEnabled = cursorCheckbox.state == .on
    }

    @objc private func paddingStepped() {
        settings.canvasPadding = CGFloat(paddingStepper.integerValue)
        showPadding(paddingStepper.integerValue)
    }

    @objc private func paddingTyped() {
        let points = CanvasPaddingInput.value(
            from: paddingField.stringValue,
            current: Int(settings.canvasPadding.rounded())
        )
        settings.canvasPadding = CGFloat(points)
        showPadding(points)
    }
}

extension SettingsWindowController {
    /// A recorder is waiting for a key (the hot keys are paused meanwhile).
    var isRecordingShortcut: Bool { (window.firstResponder as? HotKeyRecorderButton)?.isRecording == true }

    /// Starts `hotKey`'s recorder, as a click would — for tests.
    func recordShortcut(_ hotKey: SnappyHotKey) {
        let fields = [captureAreaField, fullscreenField] + recording.hotKeyFields
        fields.first { $0.hotKey == hotKey }?.startRecording()
    }
}

extension SettingsWindowController: NSWindowDelegate {
    /// Opening Settings retries a hot key another app had taken, so the
    /// fields show whether it works now.
    func windowDidBecomeKey(_ notification: Notification) {
        recording.refreshWindowPartsStatus()
        hotKeys.retryUnbound()
    }

    /// Backstop for `SettingsWindow.close` — a recorder never outlives the
    /// window with every hot key paused.
    func windowWillClose(_ notification: Notification) {
        (window as? SettingsWindow)?.cancelShortcutRecording()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        fitToScreen()
    }
}

/// Top-anchored scroll document: the pane reads from the top, as before.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension SettingsWindowController: NSPathControlDelegate {
    func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.directoryURL = settings.saveDirectory
        openPanel.prompt = "Use This Folder"
    }
}

/// Handles ⌘W and the text-editing shortcuts itself — see `SettingsKeyCommand`.
/// While a shortcut recorder is recording, every key equivalent (⌘W too)
/// goes to it instead: it is the shortcut being typed.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let recorder = firstResponder as? HotKeyRecorderButton, recorder.isRecording {
            recorder.record(event)
            return true
        }
        let command = SettingsKeyCommand(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            flags: event.modifierFlags
        )
        switch command {
        case .close:
            performClose(nil)
            return true
        case .cut: return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case .copy: return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case .paste: return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case .selectAll: return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case nil: return super.performKeyEquivalent(with: event)
        }
    }

    override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        // Switching apps (⌘Tab, a click elsewhere) abandons it too — also
        // when this window wasn't key at that moment.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
    }

    /// Clicking into another app abandons a half-typed shortcut.
    override func resignKey() {
        super.resignKey()
        cancelShortcutRecording()
    }

    /// Review r1 #1: `close()` keeps the first responder and never calls its
    /// `resignFirstResponder`, so a recorder would stay recording — with
    /// every global hot key paused — after the red close button or ⌘W.
    override func close() {
        cancelShortcutRecording()
        super.close()
    }

    @objc private func applicationDidResignActive() {
        cancelShortcutRecording()
    }

    /// Ends a recorder's recording (resuming the hot keys); a no-op otherwise.
    func cancelShortcutRecording() {
        (firstResponder as? HotKeyRecorderButton)?.cancelRecording()
    }
}

// MARK: - Recording

/// Settings → Recording (`features/recording.md` › Settings → Recording): one
/// control per row of that table, each written straight to `SettingsStore`.
/// A session reads them all at its start — except the Magic Pen thickness and
/// the two hot keys, which a running session picks up live.
///
/// Self-contained on purpose — its rows go into the pane's grid after a
/// separator and a heading, and could fill a Recording tab's grid instead
/// without changes if the single pane ever gets too tall.
@MainActor
final class RecordingSettingsSection: NSObject {
    private let settings: SettingsStore
    private let setMagicPenWidth: @MainActor (InkWidth) -> Void
    private let countdownPopUp = NSPopUpButton()
    private let frameRatePopUp = NSPopUpButton()
    private let qualityPopUp = NSPopUpButton()
    private let exportScalePopUp = NSPopUpButton()
    private let cursorCheckbox = NSButton(checkboxWithTitle: "Pointer", target: nil, action: nil)
    private let clicksCheckbox = NSButton(checkboxWithTitle: "Click ripples", target: nil, action: nil)
    private let colorPopUp = NSPopUpButton()
    private let widthPopUp = NSPopUpButton()
    private let fadingCheckbox = NSButton(
        checkboxWithTitle: "On when a recording starts",
        target: nil, action: nil
    )
    private let fadeDelayLabel = NSTextField(labelWithString: "")
    private let fadeDelayStepper = NSStepper()
    private let drawModeField: HotKeyField
    // Magic Pen: its own shortcut field and thickness (also in the menu bar).
    private let magicPenField: HotKeyField
    let magicPenWidthPopUp = NSPopUpButton() // internal for tests
    // Window parts (Q39): Accessibility status + a way to grant it.
    private let partsStatusImage = NSImageView()
    private let partsStatusLabel = NSTextField(labelWithString: "")
    private let partsSettingsButton = NSButton(title: "Open System Settings…", target: nil, action: nil)
    private let partsHint = SettingsWindowController.hintLabel("")
    private var partsStatus: WindowPartPermission.Status?

    /// Its two recorders, for `SettingsWindowController.recordShortcut`.
    fileprivate var hotKeyFields: [HotKeyField] { [drawModeField, magicPenField] }

    /// A hint under a recorder changed its line count — the window refits.
    var onHeightChange: (() -> Void)? {
        didSet { for field in [drawModeField, magicPenField] { field.onHeightChange = onHeightChange } }
    }

    private static let hotKeyHintText =
        "Switches between drawing and using your app while recording."
    private static let magicPenHintText =
        "Draws ink that fades on its own while recording. Change the thickness with [ ] while drawing, "
            + "or from the menu bar — while recording, right-click its red ●."

    /// `hotKeys` binds a recorded shortcut at once (nil: only saved).
    init(
        settings: SettingsStore,
        hotKeys: GlobalHotKeys? = nil,
        setMagicPenWidth: @escaping @MainActor (InkWidth) -> Void
    ) {
        self.settings = settings
        self.setMagicPenWidth = setMagicPenWidth
        let hotKeys = hotKeys ?? GlobalHotKeys(settings: settings, center: nil)
        drawModeField = HotKeyField(
            .drawMode, hotKeys: hotKeys,
            hint: SettingsWindowController.hintLabel(Self.hotKeyHintText), hintText: Self.hotKeyHintText
        )
        magicPenField = HotKeyField(
            .magicPen, hotKeys: hotKeys,
            hint: SettingsWindowController.hintLabel(Self.magicPenHintText), hintText: Self.magicPenHintText
        )
        super.init()

        Self.fill(countdownPopUp, RecordingCountdown.allCases, title: RecordingSettingsText.countdown)
        Self.fill(frameRatePopUp, RecordingFrameRate.allCases, title: RecordingSettingsText.frameRate)
        Self.fill(qualityPopUp, RecordingQuality.allCases, title: RecordingSettingsText.quality)
        Self.fill(exportScalePopUp, Array(ExportScale.allCases.reversed()), title: \.title)
        Self.fill(colorPopUp, InkColorPreset.allCases, title: \.title, image: Self.swatch)
        Self.fill(widthPopUp, InkWidth.allCases, title: \.title, image: Self.lineSample)
        Self.fill(magicPenWidthPopUp, InkWidth.allCases, title: \.title, image: Self.magicPenLineSample)
        countdownPopUp.setAccessibilityLabel("Countdown")
        frameRatePopUp.setAccessibilityLabel("Frame rate")
        qualityPopUp.setAccessibilityLabel("Video quality")
        exportScalePopUp.setAccessibilityLabel("Default export size")
        colorPopUp.setAccessibilityLabel("Ink color")
        widthPopUp.setAccessibilityLabel("Line width")
        magicPenWidthPopUp.setAccessibilityLabel("Magic Pen thickness")
        for popUp in [
            countdownPopUp, frameRatePopUp, qualityPopUp, exportScalePopUp, colorPopUp, widthPopUp, magicPenWidthPopUp,
        ] {
            popUp.target = self
            popUp.action = #selector(popUpChanged(_:))
        }
        for checkbox in [cursorCheckbox, clicksCheckbox, fadingCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(checkboxToggled(_:))
        }
        cursorCheckbox.setAccessibilityLabel("Show pointer in video")
        clicksCheckbox.setAccessibilityLabel("Show click ripples in video")
        fadingCheckbox.setAccessibilityLabel("Fading ink on when a recording starts")
        // `.large` doesn't make a checkbox taller (it stays 18 pt); the frame is
        // the hit region, so give it the 28 pt the other controls have.
        for checkbox in [cursorCheckbox, clicksCheckbox, fadingCheckbox] {
            checkbox.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }

        // 1…10 in steps of 1 is at most nine clicks, so a plain stepper next to
        // its value is enough (HIG Steppers) — no field to type into.
        fadeDelayStepper.minValue = Double(RecordingSettings.fadeDelayRange.lowerBound)
        fadeDelayStepper.maxValue = Double(RecordingSettings.fadeDelayRange.upperBound)
        fadeDelayStepper.increment = 1
        fadeDelayStepper.valueWraps = false
        fadeDelayStepper.target = self
        fadeDelayStepper.action = #selector(fadeDelayStepped)
        fadeDelayStepper.setAccessibilityLabel("Fade delay")
        // Wide enough for "10 seconds", so the stepper never shifts.
        fadeDelayLabel.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.textWidth(RecordingSettingsText.seconds(10))
        ).isActive = true

        partsSettingsButton.target = self
        partsSettingsButton.action = #selector(openAccessibilitySettings)
        partsSettingsButton.toolTip = "Open Privacy & Security › Accessibility in System Settings"
        // The label says it; the symbol only repeats it.
        partsStatusImage.setAccessibilityElement(false)
        partsStatusLabel.setAccessibilityLabel("Window parts")

        // ≥ 28 pt controls (Design decision, see the padding stepper above).
        for control in [
            countdownPopUp, frameRatePopUp, qualityPopUp, exportScalePopUp, cursorCheckbox, clicksCheckbox,
            colorPopUp, widthPopUp, fadingCheckbox, fadeDelayStepper, magicPenWidthPopUp, partsSettingsButton,
        ] as [NSControl] {
            control.controlSize = .large
        }
    }

    /// Adds a separator, the "Recording" heading and the section's rows to the
    /// bottom of `grid` (label column first, trailing colons like the rows above).
    func append(to grid: NSGridView) {
        let empty = NSGridCell.emptyContentView
        let heading = NSTextField(labelWithString: "Recording")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let fadeDelayRow = Self.row([fadeDelayLabel, fadeDelayStepper])
        let inkRow = Self.row([colorPopUp, widthPopUp])
        // Word joiners keep "1–5" on one line.
        let inkHint = SettingsWindowController.hintLabel(
            "Each recording starts with these. While drawing, change them with 1\u{2060}–\u{2060}5, [ ] and F."
        )

        let first = grid.numberOfRows
        grid.addRow(with: [Self.separator(), empty])
        grid.addRow(with: [heading, empty])
        // Video
        grid.addRow(with: [NSTextField(labelWithString: "Countdown:"), countdownPopUp])
        grid.addRow(with: [NSTextField(labelWithString: "Frame rate:"), frameRatePopUp])
        grid.addRow(with: [NSTextField(labelWithString: "Quality:"), qualityPopUp])
        grid.addRow(with: [NSTextField(labelWithString: "Default export size:"), exportScalePopUp])
        grid.addRow(with: [NSTextField(labelWithString: "Show in video:"), cursorCheckbox])
        grid.addRow(with: [empty, clicksCheckbox])
        // Ink
        grid.addRow(with: [NSTextField(labelWithString: "Ink:"), inkRow])
        grid.addRow(with: [NSTextField(labelWithString: "Fading ink:"), fadingCheckbox])
        grid.addRow(with: [NSTextField(labelWithString: "Fade after:"), fadeDelayRow])
        grid.addRow(with: [empty, inkHint])
        // Draw-mode shortcut
        grid.addRow(with: [NSTextField(labelWithString: "Draw mode:"), drawModeField.row])
        grid.addRow(with: [empty, drawModeField.hint])
        // Magic Pen (shortcut + thickness)
        grid.addRow(with: [NSTextField(labelWithString: "Magic Pen:"), magicPenField.row])
        grid.addRow(with: [NSTextField(labelWithString: "Magic Pen thickness:"), magicPenWidthPopUp])
        grid.addRow(with: [empty, magicPenField.hint])
        // Window parts (Accessibility)
        let partsRow = Self.row([partsStatusImage, partsStatusLabel, partsSettingsButton])
        grid.addRow(with: [NSTextField(labelWithString: "Window parts:"), partsRow])
        grid.addRow(with: [empty, partsHint])

        // Separator and heading span both columns, flush with the labels.
        for offset in 0...1 {
            let row = grid.row(at: first + offset)
            row.mergeCells(in: NSRange(location: 0, length: 2))
            row.cell(at: 0).xPlacement = offset == 0 ? .fill : .leading
        }
        grid.row(at: first).topPadding = 14
        grid.row(at: first + 1).topPadding = 8
        // The 28 pt checkboxes draw their box and title centred, which the
        // grid's first-baseline alignment doesn't know — centre those rows so
        // the labels line up with the titles.
        for offset in [6, 7, 9] {
            let row = grid.row(at: first + offset)
            row.rowAlignment = .none
            row.yPlacement = .center
        }
        // The status row is as tall as its 28 pt button: centre it too.
        let partsGridRow = grid.row(at: first + 17)
        partsGridRow.rowAlignment = .none
        partsGridRow.yPlacement = .center
        // Groups: video (countdown, rate, quality, export size) | show in video
        // | ink | draw mode | Magic Pen | window parts.
        for offset in [6, 8, 12, 14, 17] { grid.row(at: first + offset).topPadding = 10 }
    }

    func syncFromSettings() {
        Self.select(settings.recordingCountdown, in: countdownPopUp)
        Self.select(settings.recordingFrameRate, in: frameRatePopUp)
        Self.select(settings.recordingQuality, in: qualityPopUp)
        if let index = Array(ExportScale.allCases.reversed()).firstIndex(of: settings.recordingExportScale) {
            exportScalePopUp.selectItem(at: index)
        }
        Self.select(settings.recordingDefaultColor, in: colorPopUp)
        Self.select(settings.recordingDefaultWidth, in: widthPopUp)
        Self.select(settings.recordingMagicPenWidth, in: magicPenWidthPopUp)
        cursorCheckbox.state = settings.recordingShowsCursor ? .on : .off
        clicksCheckbox.state = settings.recordingShowsClicks ? .on : .off
        fadingCheckbox.state = settings.recordingFadingInkAtStart ? .on : .off
        showFadeDelay(settings.recordingFadeDelay)
        drawModeField.sync()
        magicPenField.sync()
        refreshWindowPartsStatus()
    }

    /// Re-reads the Accessibility grant — on show and whenever the window
    /// becomes key (the person may come back from System Settings).
    func refreshWindowPartsStatus() {
        let status = WindowPartPermission.status(isTrusted: WindowPartAccess.shared.isTrusted)
        guard status != partsStatus else { return }
        let hadStatus = partsStatus != nil
        partsStatus = status
        partsStatusLabel.stringValue = status.title
        let symbol = NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
        partsStatusImage.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [status.offersSettings ? .systemYellow : .systemGreen])
        )
        partsSettingsButton.isHidden = !status.offersSettings
        partsHint.stringValue = status.detail
        if hadStatus { onHeightChange?() }
    }

    /// The Magic Pen thickness changed elsewhere (menu bar, [ ], toolbar).
    func showMagicPenWidth(_ width: InkWidth) {
        Self.select(width, in: magicPenWidthPopUp)
    }

    private func showFadeDelay(_ seconds: Int) {
        fadeDelayStepper.integerValue = seconds
        fadeDelayLabel.stringValue = RecordingSettingsText.seconds(seconds)
    }

    // MARK: Actions

    @objc private func openAccessibilitySettings() {
        if let url = WindowPartPermission.settingsURL, NSWorkspace.shared.open(url) { return }
        if let url = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(url) }
    }

    @objc private func popUpChanged(_ sender: NSPopUpButton) {
        switch sender {
        case countdownPopUp: Self.selection(of: sender).map { settings.recordingCountdown = $0 }
        case frameRatePopUp: Self.selection(of: sender).map { settings.recordingFrameRate = $0 }
        case qualityPopUp: Self.selection(of: sender).map { settings.recordingQuality = $0 }
        case exportScalePopUp:
            // Listed largest first (100 % leads, like the other defaults).
            let stops = Array(ExportScale.allCases.reversed())
            if stops.indices.contains(sender.indexOfSelectedItem) {
                settings.recordingExportScale = stops[sender.indexOfSelectedItem]
            }
        case colorPopUp: Self.selection(of: sender).map { settings.recordingDefaultColor = $0 }
        case widthPopUp: Self.selection(of: sender).map { settings.recordingDefaultWidth = $0 }
        case magicPenWidthPopUp: Self.selection(of: sender).map { setMagicPenWidth($0) }
        default: break
        }
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let isOn = sender.state == .on
        switch sender {
        case cursorCheckbox: settings.recordingShowsCursor = isOn
        case clicksCheckbox: settings.recordingShowsClicks = isOn
        case fadingCheckbox: settings.recordingFadingInkAtStart = isOn
        default: break
        }
    }

    @objc private func fadeDelayStepped() {
        settings.recordingFadeDelay = fadeDelayStepper.integerValue
        showFadeDelay(settings.recordingFadeDelay)
    }

    // MARK: Building blocks

    /// One menu item per option, in `allCases` order, so the item index is
    /// the option's index.
    private static func fill<Option>(
        _ popUp: NSPopUpButton,
        _ options: [Option],
        title: (Option) -> String,
        image: ((Option) -> NSImage)? = nil
    ) {
        popUp.removeAllItems()
        for option in options {
            popUp.addItem(withTitle: title(option))
            popUp.lastItem?.image = image?(option)
        }
    }

    private static func select<Option: CaseIterable & Equatable>(_ option: Option, in popUp: NSPopUpButton) {
        if let index = Array(Option.allCases).firstIndex(of: option) { popUp.selectItem(at: index) }
    }

    private static func selection<Option: CaseIterable>(of popUp: NSPopUpButton) -> Option? {
        let options = Array(Option.allCases)
        let index = popUp.indexOfSelectedItem
        return options.indices.contains(index) ? options[index] : nil
    }

    /// A 12 pt dot in the preset's colour with a hairline edge, so white
    /// still shows on a white menu.
    private static func swatch(_ preset: InkColorPreset) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            (NSColor(cgColor: preset.color.cgColor) ?? .black).setFill()
            dot.fill()
            NSColor.tertiaryLabelColor.setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
            return true
        }
        image.accessibilityDescription = preset.title
        return image
    }

    /// A short horizontal stroke as thick as the width draws (template, so it
    /// follows the menu's text colour in light and dark).
    private static func lineSample(_ width: InkWidth) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 12), flipped: false) { rect in
            let thickness = width.points / 2 // 1 / 2 / 4 pt — 2 / 4 / 8 at full size crowd the menu
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 1, y: rect.midY - thickness / 2, width: rect.width - 2, height: thickness),
                xRadius: thickness / 2, yRadius: thickness / 2
            ).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = width.title
        return image
    }

    /// The line sample at Magic Pen thickness, in the Magic Pen's colour
    /// (not a template — it shows the ink as drawn).
    private static func magicPenLineSample(_ width: InkWidth) -> NSImage {
        let ink = MagicPenLook.color
        let image = NSImage(size: NSSize(width: 16, height: 12), flipped: false) { rect in
            let thickness = width.magicPenPoints / 2 // 2 / 3 / 5 pt in the menu
            NSColor(srgbRed: ink.red, green: ink.green, blue: ink.blue, alpha: MagicPenLook.alpha).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 1, y: rect.midY - thickness / 2, width: rect.width - 2, height: thickness),
                xRadius: thickness / 2, yRadius: thickness / 2
            ).fill()
            return true
        }
        image.accessibilityDescription = width.title
        return image
    }

    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width) + 4
    }
}

/// One remappable hot key's Settings controls (`SnappyHotKey`): the
/// recorder, its Reset button and the hint under them, which shows why a
/// shortcut was refused. Every change goes through `GlobalHotKeys`, which
/// binds it at once — a refused one leaves the old shortcut in place.
@MainActor
private final class HotKeyField: NSObject {
    let hotKey: SnappyHotKey
    let hint: NSTextField
    /// Recorder + Reset, for the grid's control column.
    let row: NSStackView
    /// A hint changed its line count — the window refits.
    var onHeightChange: (() -> Void)?
    private let hotKeys: GlobalHotKeys
    private let recorder: HotKeyRecorderButton
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let hintText: String
    /// The hot keys whose fields show their status in `hint`.
    private let hintHotKeys: [SnappyHotKey]

    /// `hint` may be shared with other fields (the two capture hot keys):
    /// `sharedBy` lists them all.
    init(
        _ hotKey: SnappyHotKey, hotKeys: GlobalHotKeys, hint: NSTextField, hintText: String,
        sharedBy hintHotKeys: [SnappyHotKey]? = nil
    ) {
        self.hotKey = hotKey
        self.hotKeys = hotKeys
        self.hint = hint
        self.hintText = hintText
        self.hintHotKeys = hintHotKeys ?? [hotKey]
        recorder = HotKeyRecorderButton(kind: hotKey)
        row = NSStackView(views: [recorder, resetButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        super.init()
        recorder.reserved = { [hotKeys] in hotKey.reserved(in: hotKeys.bindings) }
        recorder.onRecord = { [weak self] combo in self?.recorded(combo) }
        recorder.onFeedback = { [weak self] rejection in self?.showFeedback(rejection) }
        // Snappy's own hot keys must reach the recorder, not fire.
        recorder.onRecordingChange = { [hotKeys] active in hotKeys.setRecorderActive(active) }
        // A combo or its label changed elsewhere (a layout switch, the other
        // field); a hot key went live or was lost (resume, retry).
        hotKeys.onChange.append { [weak self] changed, combo in
            guard let self, changed == self.hotKey, !self.recorder.isRecording else { return }
            self.show(combo)
        }
        hotKeys.onStatusChange.append { [weak self] in
            guard let self, !self.recorder.isRecording else { return }
            self.show(hotKeys.bindings[hotKey])
            self.showFeedback(nil)
        }
        resetButton.target = self
        resetButton.action = #selector(reset)
        resetButton.toolTip = hotKey.resetToolTip
        // ≥ 28 pt controls (Design decision, see the padding stepper).
        recorder.controlSize = .large
        resetButton.controlSize = .large
    }

    /// Shows the saved shortcut, abandoning a half-typed one.
    func sync() {
        recorder.cancelRecording()
        show(hotKeys.bindings[hotKey])
        showFeedback(nil)
    }

    /// Starts recording, as a click would.
    func startRecording() {
        recorder.startRecording()
    }

    /// Reset stays enabled on the default while it isn't live: it retries.
    private func show(_ combo: HotKeyCombo) {
        recorder.combo = combo
        resetButton.isEnabled = combo != hotKey.defaultCombo || !hotKeys.isLive(hotKey)
    }

    /// Bound while the hot keys are still paused (`HotKeyRecorderButton`
    /// resumes them only afterwards): the new combo is held before the old
    /// one is let go, and the recorder shows a refusal itself.
    private func recorded(_ combo: HotKeyCombo) -> HotKeyRecorderInput.Rejection? {
        let rejection = hotKeys.set(hotKey, to: combo)
        show(hotKeys.bindings[hotKey])
        return rejection
    }

    /// Back to the default — refused like a typed shortcut when another hot
    /// key holds it now, or the system won't give it back.
    @objc private func reset() {
        recorder.cancelRecording()
        if let rejection = hotKeys.reset(hotKey) {
            refuse(rejection)
        } else {
            showFeedback(nil)
        }
        show(hotKeys.bindings[hotKey])
    }

    private func refuse(_ rejection: HotKeyRecorderInput.Rejection) {
        NSSound.beep()
        showFeedback(rejection)
    }

    /// Why the last key was refused (also spoken, since the field itself
    /// doesn't change); nil: the hint — or, while a hot key sharing it isn't
    /// live, that it's taken (`SnappyHotKey.unboundMessage`).
    private func showFeedback(_ rejection: HotKeyRecorderInput.Rejection?) {
        let lines = hint.intrinsicContentSize.height
        defer { if hint.intrinsicContentSize.height != lines { onHeightChange?() } }
        let message: String
        if let rejection {
            message = rejection.message
        } else if let unbound = hintHotKeys.first(where: { !hotKeys.isLive($0) }) {
            message = unbound.unboundMessage
        } else {
            hint.stringValue = hintText
            hint.textColor = .secondaryLabelColor
            return
        }
        guard hint.stringValue != message else { return }
        hint.stringValue = message
        hint.textColor = .labelColor
        NSAccessibility.post(
            element: recorder,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

/// A shortcut field (`kind`): click (or Space) to record, then press the new
/// combination. Every key goes through PURE `HotKeyRecorderInput`; keys
/// AppKit offers as key equivalents first (⌘/⌃ combos) arrive through
/// `SettingsWindow.performKeyEquivalent`, the rest through `keyDown`.
/// Snappy's own hot keys would never arrive — Carbon swallows them — so the
/// center is suspended while recording (`onRecordingChange`); they are then
/// refused here as already Snappy's.
@MainActor
private final class HotKeyRecorderButton: NSButton {
    let kind: SnappyHotKey
    var combo: HotKeyCombo {
        didSet { if !isRecording { title = combo.displayString } }
    }
    var reserved: () -> [ReservedHotKey] = { [] }
    /// An accepted combo, offered while the hot keys are still paused;
    /// returns why it was refused, nil when it took.
    var onRecord: ((HotKeyCombo) -> HotKeyRecorderInput.Rejection?)?
    /// A refused key, or nil once the field is back to normal.
    var onFeedback: ((HotKeyRecorderInput.Rejection?) -> Void)?
    /// Recording started (true) or ended (false), however it ended.
    var onRecordingChange: ((Bool) -> Void)?
    private(set) var isRecording = false

    init(kind: SnappyHotKey) {
        self.kind = kind
        combo = kind.defaultCombo
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        title = combo.displayString
        target = self
        action = #selector(clicked)
        toolTip = kind.recorderToolTip
        setAccessibilityLabel(kind.recorderAccessibilityLabel)
        // Wide enough for "Type Shortcut", so the row doesn't jump.
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Plain buttons only take focus with Full Keyboard Access; recording needs
    // it always, or the key presses would go elsewhere.
    override var acceptsFirstResponder: Bool { true }

    @objc private func clicked() {
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !isRecording, window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        title = HotKeyRecorderInput.pendingTitle(flags: [])
        bezelColor = .controlAccentColor
        onRecordingChange?(true)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    override func flagsChanged(with event: NSEvent) {
        if isRecording { title = HotKeyRecorderInput.pendingTitle(flags: event.modifierFlags) }
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    /// One key press while recording. An accepted combo is only offered
    /// (`onRecord`): the owner shows what was actually bound.
    func record(_ event: NSEvent) {
        let outcome = HotKeyRecorderInput.outcome(
            keyCode: event.keyCode, flags: event.modifierFlags, reserved: reserved()
        )
        switch outcome {
        case .accept(let newCombo):
            // Review r1 #2: bind first, still paused — `HotKeyCenter.replace`
            // acquires the new combo for real, and a refusal keeps the old
            // one — and only then resume the rest.
            let rejection = onRecord?(newCombo)
            stopRecording()
            if let rejection {
                NSSound.beep()
                onFeedback?(rejection)
            }
        case .cancel:
            cancelRecording()
        case .leave:
            cancelRecording()
            if event.modifierFlags.contains(.shift) {
                window?.selectKeyView(preceding: self)
            } else {
                window?.selectKeyView(following: self)
            }
        case .reject(let rejection):
            NSSound.beep()
            onFeedback?(rejection)
        }
    }

    /// Back to showing the current combo; a no-op when not recording.
    func cancelRecording() {
        guard isRecording else { return }
        stopRecording()
    }

    /// Feedback is cleared before the resume, so the status the resume
    /// reports (a combo taken meanwhile) stays visible.
    private func stopRecording() {
        isRecording = false
        bezelColor = nil
        title = combo.displayString
        onFeedback?(nil)
        onRecordingChange?(false)
    }
}

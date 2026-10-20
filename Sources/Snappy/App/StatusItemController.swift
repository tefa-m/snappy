import AppKit

/// PURE description of the status menu's items — unit-tested.
///
/// HIG Menus › Labels: title-style verb phrases, and an ellipsis when the
/// command needs more input before it completes — Area and Window wait for a
/// selection, Entire Screen fires at once (the same split as Preview's File ›
/// Take Screenshot). "Entire Screen" is Apple's own term; "fullscreen" is the
/// window mode. HIG Menus › Icons: symbols for the capture and recording
/// groups (the app's key features) and Settings; Quit has no standard symbol,
/// so none. "Record Area…" waits for a selection (ellipsis); "Reopen Last
/// Recording" opens at once and is disabled while there is no take; "Magic
/// Pen Thickness" is a submenu (`MagicPenThicknessMenu`), no command itself.
enum StatusMenuCommand: CaseIterable {
    case captureArea
    case captureWindow
    case captureEntireScreen
    case recordArea
    case reopenLastRecording
    case magicPenThickness
    case settings
    case quit

    var title: String {
        switch self {
        case .captureArea: "Capture Area…"
        case .captureWindow: "Capture Window…"
        case .captureEntireScreen: "Capture Entire Screen"
        case .recordArea: "Record Area…"
        case .reopenLastRecording: "Reopen Last Recording"
        case .magicPenThickness: MagicPenThicknessMenu.title
        case .settings: "Settings…"
        case .quit: "Quit Snappy"
        }
    }

    var symbolName: String? {
        switch self {
        case .captureArea: "rectangle.dashed"
        case .captureWindow: "macwindow"
        case .captureEntireScreen: "display"
        case .recordArea: "record.circle"
        case .reopenLastRecording: "play.rectangle"
        case .magicPenThickness: MagicPenThicknessMenu.symbolName
        case .settings: "gearshape"
        case .quit: nil
        }
    }

    /// Display-only for the two capture shortcuts — the configured combos
    /// (`bindings`, ⇧⌘4 / ⇧⌘3 by default): the global triggers are
    /// HotKeyCenter's Carbon hot keys, which fire (and swallow them)
    /// system-wide. Window capture has no shortcut (menu-only by decision);
    /// recording starts from ⇧⌘4 → R, so its menu items show none.
    func keyEquivalent(in bindings: HotKeyBindings = .defaults) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        switch self {
        case .captureArea: bindings.captureArea.menuKeyEquivalent
        case .captureWindow: ("", [])
        case .captureEntireScreen: bindings.captureFullscreen.menuKeyEquivalent
        case .recordArea, .reopenLastRecording, .magicPenThickness: ("", [])
        case .settings: (",", [.command])
        case .quit: ("q", [.command])
        }
    }

    /// Separator *before* this item.
    var startsGroup: Bool { self == .recordArea || self == .settings || self == .quit }

    /// Opens a submenu instead of acting.
    var hasSubmenu: Bool { self == .magicPenThickness }
}

/// The Magic Pen thickness choices — PURE, unit-tested. Shown as the status
/// menu's "Magic Pen Thickness" submenu and, while recording, in the menu a
/// right-click or ⌥-click on the red ● opens (`RecordingStatusMenu`).
/// Checkmark on the current one (HIG Menus › toggled items).
enum MagicPenThicknessMenu {
    static let title = "Magic Pen Thickness"
    static let symbolName = "wand.and.stars"

    struct Item: Equatable {
        let width: InkWidth
        let title: String
        let isChecked: Bool
    }

    static func items(current: InkWidth) -> [Item] {
        InkWidth.allCases.map { Item(width: $0, title: $0.title, isChecked: $0 == current) }
    }
}

/// What a click on the recording item does (2026-10-09: a plain click
/// stops — unchanged). A right-click, ⌃-click or ⌥-click opens the
/// recording menu instead — PURE, unit-tested.
enum RecordingStatusClick: Equatable {
    case stop
    case showMenu

    static func action(isRightClick: Bool, modifiers: NSEvent.ModifierFlags) -> RecordingStatusClick {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if isRightClick || flags.contains(.option) || flags.contains(.control) { return .showMenu }
        return .stop
    }
}

/// The small menu of the recording item: the Magic Pen thickness (changed
/// live), then Stop — PURE, unit-tested.
enum RecordingStatusMenu {
    enum Entry: Equatable {
        /// A section header ("Magic Pen Thickness").
        case header(String)
        case thickness(MagicPenThicknessMenu.Item)
        case separator
        /// "Stop Recording", ⇧⌘4 shown as its (display-only) key equivalent.
        case stop
    }

    static let stopTitle = "Stop Recording"

    static func entries(magicPenWidth: InkWidth) -> [Entry] {
        [.header(MagicPenThicknessMenu.title)]
            + MagicPenThicknessMenu.items(current: magicPenWidth).map(Entry.thickness)
            + [.separator, .stop]
    }
}

/// The menu bar item while a recording runs: a red ● and the elapsed time
/// (`● 0:42`), a click stops it (`features/recording.md`, Recording chrome;
/// 2026-10-09) — PURE, unit-tested. The menu bar is always on screen,
/// so this is the indicator that stays visible when the recorded window or
/// the toolbar is off screen.
enum RecordingStatusGlyph {
    /// Only while frames are being recorded: not in Setup or the countdown,
    /// and no longer while the take is finalised (Stop was already sent).
    static func showsStop(for phase: RecordingPhase?) -> Bool {
        phase?.isRecording == true
    }

    static let symbolName = "circle.fill"
    /// HIG Offering help: what a click does, and the hot key that does the
    /// same — the Capture Area combo as configured (`stopCombo`), read on
    /// entering recording and again whenever it changes.
    /// (The right-click menu is named in Settings → Recording's Magic Pen hint
    /// and offered to VoiceOver as `menuActionName`.)
    /// A nil combo (the Capture Area hot key isn't live) names no shortcut.
    static func toolTip(stopCombo: HotKeyCombo?) -> String {
        guard let stopCombo else { return "Stop recording" }
        return "Stop recording (\(stopCombo.displayString))"
    }
    /// VoiceOver's custom action on the item (the right-click menu).
    static let menuActionName = "Magic Pen Thickness"
    static let accessibilityDescription = "Recording"

    /// The text beside the ●: the elapsed time, same clock and rounding as
    /// the toolbar timer (`RecordingTimerText`), in its compact form.
    static func title(elapsed: TimeInterval) -> String {
        RecordingTimerText.compact(elapsed: elapsed)
    }

    /// What VoiceOver reads for the item.
    static func accessibilityLabel(elapsed: TimeInterval) -> String {
        "Recording, \(title(elapsed: elapsed)), click to stop"
    }

    /// Seconds until the readout next changes — the next whole second since
    /// the start — so the item ticks once per second, on the second.
    static func delayUntilNextTick(elapsed: TimeInterval) -> TimeInterval {
        let elapsed = max(0, elapsed)
        return (elapsed.rounded(.down) + 1) - elapsed
    }

    /// Red, not a template: the menu bar's usual recording signal. The
    /// running time carries the state too (never colour alone).
    @MainActor
    static func image() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [.systemRed]))
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }
}

/// What `StatusItemController` drives: an `NSStatusItem` in the app, a plain
/// stand-in in tests (a real one lands in the menu bar).
@MainActor
protocol StatusItemHosting: AnyObject {
    var length: CGFloat { get set }
    var menu: NSMenu? { get set }
    var button: NSStatusBarButton? { get }
}

extension NSStatusItem: StatusItemHosting {}

/// The clock the recording readout ticks on — injectable, so tests can step
/// through seconds without waiting for them.
struct StatusItemTicker {
    var now: @MainActor () -> ContinuousClock.Instant = { .now }
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    static let live = StatusItemTicker()
}

/// Owns the menu bar item and its menu — the app's only always-visible UI.
@MainActor
final class StatusItemController: NSObject, NSMenuItemValidation {
    private let statusItem: any StatusItemHosting
    private let ticker: StatusItemTicker
    private let captureCoordinator: CaptureCoordinator
    private let recordingCoordinator: RecordingCoordinator
    /// Settings' shortcut fields change the hot keys through it.
    private let globalHotKeys: GlobalHotKeys
    private var settingsWindowController: SettingsWindowController?
    /// The item currently shows the recording ● (see `recordingPhaseDidChange`).
    private var showingStop = false
    /// When the pipeline started writing (`RecordingCoordinator.onCaptureStart`)
    /// — the toolbar timer's start too.
    private var captureStart: ContinuousClock.Instant?
    private var tickTask: Task<Void, Never>?

    init(
        captureCoordinator: CaptureCoordinator,
        recordingCoordinator: RecordingCoordinator,
        globalHotKeys: GlobalHotKeys = GlobalHotKeys(center: nil),
        statusItem: any StatusItemHosting = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength),
        ticker: StatusItemTicker = .live
    ) {
        self.captureCoordinator = captureCoordinator
        self.recordingCoordinator = recordingCoordinator
        self.globalHotKeys = globalHotKeys
        self.statusItem = statusItem
        self.ticker = ticker
        super.init()

        if let button = statusItem.button {
            button.image = Self.menuBarImage()
        }
        statusItem.menu = makeMenu()
        recordingCoordinator.onPhaseChange = { [weak self] phase in
            self?.recordingPhaseDidChange(phase)
        }
        recordingCoordinator.onCaptureStart = { [weak self] start in
            self?.captureDidStart(at: start)
        }
        recordingCoordinator.onMagicPenWidthChange = { [weak self] width in
            self?.settingsWindowController?.showMagicPenWidth(width)
        }
        // A Capture Area remap (or a layout switch) mid-recording, or the
        // combo going live / being lost (a resume, a retry): the red ● must
        // not advertise a dead stop shortcut.
        globalHotKeys.onChange.append { [weak self] hotKey, _ in
            guard hotKey == .captureArea else { return }
            self?.refreshStopToolTip()
        }
        globalHotKeys.onStatusChange.append { [weak self] in self?.refreshStopToolTip() }
    }

    private func refreshStopToolTip() {
        guard showingStop else { return }
        statusItem.button?.toolTip = RecordingStatusGlyph.toolTip(stopCombo: globalHotKeys.liveStopCombo)
    }

    /// While recording the status item is a red ● plus the elapsed time,
    /// without a menu, and a click stops the recording; every other phase
    /// (and nil — the session ended) restores the glyph and the menu.
    private func recordingPhaseDidChange(_ phase: RecordingPhase?) {
        let showsStop = RecordingStatusGlyph.showsStop(for: phase)
        guard showsStop != showingStop, let button = statusItem.button else { return }
        showingStop = showsStop
        if showsStop {
            statusItem.length = NSStatusItem.variableLength
            button.image = RecordingStatusGlyph.image()
            button.imagePosition = .imageLeading
            // Monospaced digits: the item only widens when a digit is added.
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.toolTip = RecordingStatusGlyph.toolTip(stopCombo: globalHotKeys.liveStopCombo)
            button.target = self
            button.action = #selector(recordingItemClicked)
            // A right-click sends the action too; `RecordingStatusClick`
            // tells the two apart (plain click = stop, unchanged).
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: RecordingStatusGlyph.menuActionName) { [weak self] in
                    self?.showRecordingMenu()
                    return true
                },
            ])
            // Without a menu, a click sends the button's action.
            statusItem.menu = nil
            showElapsed(captureStart.map(seconds(since:)) ?? 0)
        } else {
            tickTask?.cancel()
            tickTask = nil
            captureStart = nil
            button.title = ""
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(nil)
            button.image = Self.menuBarImage()
            button.toolTip = nil
            button.action = nil
            button.sendAction(on: [.leftMouseUp])
            button.setAccessibilityCustomActions(nil)
            statusItem.length = NSStatusItem.squareLength
            statusItem.menu = makeMenu()
        }
    }

    /// Counts from the instant the toolbar timer starts, once per second.
    private func captureDidStart(at start: ContinuousClock.Instant) {
        captureStart = start
        tickTask?.cancel()
        let ticker = ticker
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                let elapsed = (ticker.now() - start) / .seconds(1)
                self?.showElapsed(elapsed)
                await ticker.sleep(.seconds(RecordingStatusGlyph.delayUntilNextTick(elapsed: elapsed)))
            }
        }
    }

    private func showElapsed(_ elapsed: TimeInterval) {
        guard showingStop, let button = statusItem.button else { return }
        button.title = RecordingStatusGlyph.title(elapsed: elapsed)
        button.setAccessibilityLabel(RecordingStatusGlyph.accessibilityLabel(elapsed: elapsed))
    }

    /// The toolbar timer's formula (`RecordingChrome`), so both readouts agree.
    private func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        (ticker.now() - start) / .seconds(1)
    }

    /// The recording item: a plain click stops (2026-10-09); a
    /// right-, ⌃- or ⌥-click opens the Magic Pen thickness + Stop menu.
    @objc private func recordingItemClicked() {
        // Only the click itself counts: anything else (VoiceOver press, a
        // stale key event) is a plain click.
        var click = RecordingStatusClick.stop
        if let event = NSApp.currentEvent,
           [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type) {
            click = RecordingStatusClick.action(
                isRightClick: event.type == .rightMouseUp || event.type == .rightMouseDown,
                modifiers: event.modifierFlags
            )
        }
        switch click {
        case .stop: recordingCoordinator.stop()
        case .showMenu: showRecordingMenu()
        }
    }

    @objc private func stopRecording() {
        recordingCoordinator.stop()
    }

    /// Built fresh on every open from `RecordingStatusMenu`, popped up under
    /// the item (the item itself keeps no menu, so a plain click still stops).
    private func showRecordingMenu() {
        guard showingStop, let button = statusItem.button else { return }
        let menu = NSMenu()
        for entry in RecordingStatusMenu.entries(magicPenWidth: recordingCoordinator.magicPenWidth) {
            switch entry {
            case .header(let title):
                menu.addItem(.sectionHeader(title: title))
            case .thickness(let choice):
                menu.addItem(thicknessItem(choice))
            case .separator:
                menu.addItem(.separator())
            case .stop:
                // Display only: the Capture Area hot key, as configured —
                // none while it isn't live.
                let shortcut = globalHotKeys.liveStopCombo?.menuKeyEquivalent
                let item = NSMenuItem(
                    title: RecordingStatusMenu.stopTitle, action: #selector(stopRecording),
                    keyEquivalent: shortcut?.key ?? ""
                )
                item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
                item.target = self
                menu.addItem(item)
            }
        }
        let y = button.isFlipped ? button.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: button)
    }

    /// One Magic Pen thickness choice; its checkmark is refreshed in
    /// `validateMenuItem` whenever a menu opens.
    private func thicknessItem(_ choice: MagicPenThicknessMenu.Item) -> NSMenuItem {
        let item = NSMenuItem(title: choice.title, action: #selector(magicPenWidthChosen(_:)), keyEquivalent: "")
        item.target = self
        item.tag = choice.width.rawValue
        item.state = choice.isChecked ? .on : .off
        return item
    }

    @objc private func magicPenWidthChosen(_ sender: NSMenuItem) {
        guard let width = InkWidth(rawValue: sender.tag) else { return }
        recordingCoordinator.setMagicPenWidth(width)
    }

    /// Bundled template "S" glyph; falls back to an SF Symbol when running
    /// unbundled (`swift run`), where bundle resources don't exist.
    private static func menuBarImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            image.accessibilityDescription = "Snappy"
            return image
        }
        return NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Snappy"
        )
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for command in StatusMenuCommand.allCases {
            if command.startsGroup { menu.addItem(.separator()) }
            if command == .quit { menu.addItem(Self.versionItem()) }
            if command.hasSubmenu {
                menu.addItem(magicPenThicknessItem(command))
                continue
            }
            let shortcut = command.keyEquivalent(in: globalHotKeys.bindings)
            let item = NSMenuItem(
                title: command.title,
                action: action(for: command),
                keyEquivalent: shortcut.key
            )
            item.keyEquivalentModifierMask = shortcut.modifiers
            item.target = self
            if let symbol = command.symbolName {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        return menu
    }

    /// "Magic Pen Thickness ▸ Thin · Medium · Thick" (checkmark on the
    /// current one), also usable outside a recording — it is a setting.
    private func magicPenThicknessItem(_ command: StatusMenuCommand) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
        if let symbol = command.symbolName {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        let submenu = NSMenu(title: command.title)
        for choice in MagicPenThicknessMenu.items(current: recordingCoordinator.magicPenWidth) {
            submenu.addItem(thicknessItem(choice))
        }
        item.submenu = submenu
        return item
    }

    /// Disabled "Snappy 1.1.0-7-gabc1234" line — answers "which build is this?".
    private static func versionItem() -> NSMenuItem {
        let item = NSMenuItem(title: AppVersion.menuTitle, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(for command: StatusMenuCommand) -> Selector {
        switch command {
        case .captureArea: #selector(captureArea)
        case .captureWindow: #selector(captureWindow)
        case .captureEntireScreen: #selector(captureFullscreen)
        case .recordArea: #selector(recordArea)
        case .reopenLastRecording: #selector(reopenLastRecording)
        case .magicPenThickness: #selector(magicPenWidthChosen(_:)) // never used: a submenu
        case .settings: #selector(openSettings)
        case .quit: #selector(quit)
        }
    }

    // MARK: - Actions

    @objc private func captureArea() {
        captureCoordinator.captureArea(trigger: .menu)
    }

    @objc private func captureWindow() {
        captureCoordinator.captureWindow()
    }

    @objc private func captureFullscreen() {
        captureCoordinator.captureFullscreen(trigger: .menu)
    }

    @objc private func recordArea() {
        captureCoordinator.recordArea()
    }

    @objc private func reopenLastRecording() {
        recordingCoordinator.reopenLastRecording()
    }

    /// The menu auto-enables its items through this when it opens — also
    /// where the capture items pick up a hot key Settings changed.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let command: StatusMenuCommand? = switch menuItem.action {
        case #selector(captureArea): .captureArea
        case #selector(captureFullscreen): .captureEntireScreen
        default: nil
        }
        if let command {
            let shortcut = command.keyEquivalent(in: globalHotKeys.bindings)
            menuItem.keyEquivalent = shortcut.key
            menuItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        if menuItem.action == #selector(reopenLastRecording) {
            return recordingCoordinator.canReopenLastRecording
        }
        if menuItem.action == #selector(magicPenWidthChosen(_:)) {
            menuItem.state = menuItem.tag == recordingCoordinator.magicPenWidth.rawValue ? .on : .off
        }
        return true
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            // Magic Pen thickness goes through the coordinator, as from the
            // menu bar, so a running session picks it up live.
            settingsWindowController = SettingsWindowController(hotKeys: globalHotKeys) { [recordingCoordinator] width in
                recordingCoordinator.setMagicPenWidth(width)
            }
        }
        settingsWindowController?.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

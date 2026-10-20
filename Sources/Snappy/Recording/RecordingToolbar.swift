import AppKit

/// The recording toolbar's controls, in display order (`features/recording.md`,
/// Recording chrome): `● Record / ■ Stop · 00:00 | Area · Window | Pointer ·
/// Pen · Highlighter · Arrow · Oval · Box | color · width · fading | Clear ·
/// draw/interact · Magic Pen | Cancel`
/// — PURE, unit-tested. Record and Stop share the first slot; the timer is a
/// label, not an item.
enum RecordingToolbarItem: CaseIterable, Equatable, Hashable {
    case record, stop
    case area, window
    case pointer, pen, highlighter, arrow, oval, box
    case color, width, fading
    case clear, drawMode, magicPen
    case cancel

    /// The toolbar's groups, separated by dividers. `.record` stands for the
    /// Record/Stop slot (`RecordingToolbarState.primary`), followed by the timer.
    static let groups: [[RecordingToolbarItem]] = [
        [.record],
        [.area, .window],
        [.pointer, .pen, .highlighter, .arrow, .oval, .box],
        [.color, .width, .fading],
        [.clear, .drawMode, .magicPen],
        [.cancel],
    ]

    /// The picker items: Pointer, then the drawing tools.
    static let toolItems: [RecordingToolbarItem] = [.pointer, .pen, .highlighter, .arrow, .oval, .box]

    /// Short name — the VoiceOver label of the icon-only button.
    var title: String {
        switch self {
        case .record: "Record"
        case .stop: "Stop"
        case .area: "Snap to Area"
        case .window: "Snap to Window"
        case .pointer: "Pointer"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .arrow: "Arrow"
        case .oval: "Oval"
        case .box: "Box"
        case .color: "Color"
        case .width: "Line Width"
        case .fading: "Fading Ink"
        case .clear: "Clear"
        case .drawMode: "Draw Mode"
        case .magicPen: "Magic Pen"
        case .cancel: "Cancel"
        }
    }

    /// The same symbols as the editor's matching tools (`cursorarrow`,
    /// `scribble`, `arrow.up.right`, `oval`, `rectangle`), so a tool looks the
    /// same wherever it appears. Borderless symbols (HIG Toolbars › Actions),
    /// except Record/Stop, whose filled red disc is the recording convention.
    var symbolName: String {
        switch self {
        case .record: "record.circle.fill"
        case .stop: "stop.circle.fill"
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .pointer: "cursorarrow"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .oval: "oval"
        case .box: "rectangle"
        case .color: "circle.fill"
        case .width: "lineweight"
        case .fading: "timer"
        case .clear: "trash"
        case .drawMode: "hand.draw"
        case .magicPen: "wand.and.stars"
        case .cancel: "xmark"
        }
    }

    /// The tool this item picks; nil for everything but the five tools.
    var tool: InkTool? {
        switch self {
        case .pen: .pen
        case .highlighter: .highlighter
        case .arrow: .arrow
        case .oval: .oval
        case .box: .box
        default: nil
        }
    }

    init?(tool: InkTool) {
        switch tool {
        case .pen: self = .pen
        case .highlighter: self = .highlighter
        case .arrow: self = .arrow
        case .oval: self = .oval
        case .box: self = .box
        }
    }

    /// The snap mode this item enters; nil for everything but Area and Window.
    var snapKind: SnapKind? {
        switch self {
        case .area: .area
        case .window: .window
        default: nil
        }
    }

    /// What a click sends. nil for Color and Width, which open a menu first
    /// (`widthCommands(from:to:)` for the width steps). Area and Window send
    /// S / W's `.snap`; a click on the snap mode already on goes back instead
    /// (`command(phase:)`).
    var command: RecordingCommand? {
        switch self {
        case .record: .record
        case .stop: .stop
        case .area, .window: snapKind.map(RecordingCommand.snap)
        case .pointer: .pointer
        case .pen, .highlighter, .arrow, .oval, .box: tool.map(RecordingCommand.tool)
        case .color, .width: nil
        case .fading: .ink(.toggleFading)
        case .clear: .ink(.clear)
        case .drawMode: .toggleDrawMode
        case .magicPen: .toggleMagicPen
        case .cancel: .cancel
        }
    }

    /// What a click sends in `phase` — `command`, except that in snap mode
    /// the button of the mode already on steps back — same as Esc / Q, it returns
    /// to where you were (the Setup mode or tool snapping started from) — exactly what
    /// pressing its key again does there (`RecordingKeyMap`, Q33).
    func command(phase: RecordingPhase) -> RecordingCommand? {
        if case .snapping(let kind, _, _) = phase, snapKind == kind { return .stepBack }
        return command
    }

    /// The item's shortcut — the `RecordingKeyMap` binding, or the hot key for
    /// Stop / Draw Mode / Magic Pen (`stopKey` / `drawModeKey` / `magicPenKey`,
    /// the configured combos) — whether or not it works in the current phase
    /// (`key(drawModeKey:magicPenKey:phase:)` decides that).
    func shortcut(drawModeKey: String, magicPenKey: String = "", stopKey: String = "⇧⌘4") -> String {
        switch self {
        case .record: "R"
        case .stop: stopKey
        case .area: "S"
        case .window: "W"
        case .pointer: "V"
        case .pen: "P"
        case .highlighter: "H"
        case .arrow: "A"
        case .oval: "O"
        case .box: "B"
        case .color: "1–5"
        case .width: "[ or ]"
        case .fading: "F"
        case .clear: "⌫"
        case .drawMode: drawModeKey
        case .magicPen: magicPenKey
        case .cancel: "Esc"
        }
    }

    /// The shortcut the tooltip advertises in `phase`: only when pressing it
    /// there does what clicking the button does (tested against
    /// `RecordingKeyMap` and `RecordingSession`). Tool and style keys reach
    /// Snappy only in Setup and draw mode — in interact mode they belong to
    /// the user's app (Q15); R only starts from Setup; S and W work in Setup
    /// and snap mode only; ⇧⌘4 and the draw-mode
    /// hot key act only while recording; and Esc cancels only from Setup's
    /// Pointer mode — elsewhere it steps back one level instead. In Magic
    /// Pen mode the keys of draw mode work, except F (Magic Pen ink always
    /// fades); [ ] there step the Magic Pen thickness, which is what the
    /// Width menu sets in that mode too.
    ///
    /// A nil `drawModeKey` / `magicPenKey` means that hot key couldn't be
    /// registered this session: its toggle then has no shortcut to advertise.
    /// A nil `stopKey` likewise: the Capture Area combo isn't live (the
    /// system refused it), so Stop names no shortcut.
    func key(
        drawModeKey: String?, magicPenKey: String? = nil, stopKey: String? = "⇧⌘4", phase: RecordingPhase
    ) -> String? {
        if self == .drawMode, drawModeKey == nil { return nil }
        if self == .magicPen, magicPenKey == nil { return nil }
        if self == .stop, stopKey == nil { return nil }
        let live: Bool
        switch self {
        case .record:
            if case .setup = phase { live = true } else { live = false }
        case .area, .window:
            switch phase {
            case .setup, .snapping: live = true
            default: live = false
            }
        case .stop, .drawMode, .magicPen:
            live = phase.isRecording
        case .cancel:
            live = phase == .setup(.pointer)
        case .pointer, .pen, .highlighter, .arrow, .oval, .box, .color, .width, .clear:
            switch phase {
            case .setup, .recording(.draw), .recording(.magicPen): live = true
            default: live = false
            }
        case .fading:
            switch phase {
            case .setup, .recording(.draw): live = true
            default: live = false
            }
        }
        return live
            ? shortcut(drawModeKey: drawModeKey ?? "", magicPenKey: magicPenKey ?? "", stopKey: stopKey ?? "")
            : nil
    }

    /// Tooltip in the app-wide "<verb phrase> (KEY)" form (HIG Offering help:
    /// say what it does, never just the name), with the key only where it
    /// works (`key(drawModeKey:phase:)`). Pointer and Cancel change meaning
    /// once recording: Pointer hands the mouse back to the user's app, Cancel
    /// throws the take away. In snap mode the snap button that is on goes
    /// back to the previous target (`command(phase:)`).
    func toolTip(
        drawModeKey: String?, magicPenKey: String? = nil, stopKey: String? = "⇧⌘4", phase: RecordingPhase
    ) -> String {
        let recording = phase.isRecording || phase == .stopping
        let magicPen = if case .recording(.magicPen) = phase { true } else { false }
        let snapping: SnapKind? = if case .snapping(let kind, _, _) = phase { kind } else { nil }
        let leavesSnapMode = snapKind != nil && snapKind == snapping
        let description = switch self {
        case .record: "Start recording this area"
        case .stop: "Stop recording and preview it"
        case .area: leavesSnapMode ? "Stop snapping and go back to the previous target" : "Snap to a window's area"
        case .window: leavesSnapMode ? "Stop snapping and go back to the previous target" : "Snap to a window"
        case .pointer: recording ? "Stop drawing and use your app" : "Move and resize the area"
        case .pen: "Draw freehand"
        case .highlighter: "Mark text with a translucent highlighter"
        case .arrow: "Draw an arrow from tail to head"
        case .oval: "Highlight an area with an oval"
        case .box: "Highlight an area with a box"
        case .color: "Choose the ink color"
        case .width: magicPen ? "Choose the Magic Pen thickness" : "Choose the line width"
        case .fading: "Fade new strokes out after a few seconds"
        case .clear: "Clear all annotations"
        case .drawMode: "Switch between drawing and using your app"
        case .magicPen: "Draw fading ink"
        case .cancel: recording ? "Discard this recording" : "Cancel recording"
        }
        guard let key = key(drawModeKey: drawModeKey, magicPenKey: magicPenKey, stopKey: stopKey, phase: phase) else {
            return description
        }
        return "\(description) (\(key))"
    }

    /// The `[` / `]` steps from the current width to the one picked in the
    /// Width menu (the session only knows relative steps).
    static func widthCommands(from current: InkWidth, to target: InkWidth) -> [InkCommand] {
        let steps = target.rawValue - current.rawValue
        return Array(repeating: steps > 0 ? .thicker : .thinner, count: abs(steps))
    }
}

/// What the toolbar shows for a session phase — PURE, unit-tested. Mirrors
/// `RecordingSession`'s rules so a control is enabled exactly when the session
/// would act on its command: tools and style in Setup and while recording
/// (a tool picked in interact mode enters draw mode); Record in Setup; Area
/// and Window in Setup and snap mode; Stop, the draw/interact toggle and
/// Magic Pen while recording; only Cancel while counting down; nothing once
/// the file is being finalised. Disabled controls stay in place, dimmed.
struct RecordingToolbarState: Equatable {
    /// `.record` before recording, `.stop` from recording on.
    let primary: RecordingToolbarItem
    /// The phase it was built from (tooltips depend on it).
    let phase: RecordingPhase
    /// The highlighted picker item: Pointer or the current tool.
    let selected: RecordingToolbarItem?
    /// Draw mode is on (the toggle shows its on state).
    let drawModeOn: Bool
    /// Magic Pen mode is on — its toggle shows the on state instead of draw
    /// mode's, and no tool is selected (it draws Magic Pen strokes only).
    let magicPenOn: Bool
    /// The snap mode that is on — its Area / Window button shows the on state.
    let snapping: SnapKind?
    private let enabled: Set<RecordingToolbarItem>

    init(phase: RecordingPhase) {
        self.phase = phase
        magicPenOn = if case .recording(.magicPen) = phase { true } else { false }
        snapping = if case .snapping(let kind, _, _) = phase { kind } else { nil }
        let snap: Set<RecordingToolbarItem> = [.area, .window]
        let tools = Set(RecordingToolbarItem.toolItems)
        let ink: Set<RecordingToolbarItem> = [.color, .width, .fading, .clear]
        switch phase {
        case .setup(let mode):
            primary = .record
            selected = Self.item(for: mode)
            drawModeOn = false
            enabled = tools.union(ink).union(snap).union([.record, .cancel])
        case .snapping(_, _, let returnTo):
            primary = .record
            selected = Self.item(for: returnTo)
            drawModeOn = false
            enabled = snap.union([.cancel])
        case .countdown:
            primary = .record
            selected = .pointer
            drawModeOn = false
            enabled = [.cancel]
        case .recording(let mode):
            primary = .stop
            switch mode {
            case .draw(let tool):
                selected = RecordingToolbarItem(tool: tool)
                drawModeOn = true
            case .magicPen:
                selected = nil
                drawModeOn = false
            case .interact:
                selected = .pointer
                drawModeOn = false
            }
            enabled = tools.union(ink).union([.stop, .drawMode, .magicPen, .cancel])
        case .stopping, .finished, .cancelled:
            primary = .stop
            selected = nil
            drawModeOn = false
            enabled = []
        }
    }

    func isEnabled(_ item: RecordingToolbarItem) -> Bool {
        enabled.contains(item)
    }

    private static func item(for mode: SetupMode) -> RecordingToolbarItem? {
        switch mode {
        case .pointer: .pointer
        case .tool(let tool): RecordingToolbarItem(tool: tool)
        }
    }
}

/// The toolbar's elapsed-time readout — PURE, unit-tested. "00:00" up to
/// 59:59, then "1:00:00"; whole seconds, never rounded up.
enum RecordingTimerText {
    /// The toolbar readout: `00:42`, `1:02:03`.
    static func string(elapsed: TimeInterval) -> String {
        let (hours, minutes, seconds) = components(elapsed)
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The menu bar readout, as short as possible: `0:42`, `12:05`,
    /// `1:02:03` (2026-10-09).
    static func compact(elapsed: TimeInterval) -> String {
        let (hours, minutes, seconds) = components(elapsed)
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Whole seconds elapsed, split; never negative.
    private static func components(_ elapsed: TimeInterval) -> (Int, Int, Int) {
        let total = max(0, Int(elapsed.rounded(.down)))
        return (total / 3600, total / 60 % 60, total % 60)
    }

    /// The width the label reserves, so the toolbar doesn't change size as the
    /// digits tick (monospaced digits, the widest one-hour-free value).
    static let widestSample = "00:00"
}

// MARK: - View

/// The recording view's Liquid Glass toolbar (Tahoe Glass, like the editor
/// toolbar and the preview panel): one glass capsule of borderless `.toolbar`
/// buttons at the HIG default 28 pt, groups split by hairline dividers, no
/// bezel boxes on the glass. Record/Stop is the one coloured control.
///
/// It never takes keyboard focus — it lives in a non-key panel — and its
/// buttons accept the first mouse, so a click works while the user's app is
/// active and keeps the keyboard there (interact mode).
@MainActor
final class RecordingToolbarView: NSGlassEffectView {
    /// A click on a control (Color and Width report the menu choice).
    var onCommand: ((RecordingCommand) -> Void)?
    /// The toolbar's fitting size changed on its own — the readout grew from
    /// "59:59" to "1:00:00" (or to ten hours) — so its panel must be re-fitted.
    var onFittingSizeChange: (() -> Void)?

    private static let buttonSize: CGFloat = 28
    private static let spacing: CGFloat = 4
    private static let padding: CGFloat = 4
    private static let dividerHeight: CGFloat = 16
    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

    private var buttons: [RecordingToolbarItem: NSButton] = [:]
    private let primaryButton: NSButton
    private let timerLabel = NSTextField(labelWithString: RecordingTimerText.string(elapsed: 0))
    private var state = RecordingToolbarState(phase: .setup(.pointer))
    private var inkStyle = InkStyle(color: .red, width: .medium, fading: false)
    private var timerRunning = false
    private var drawModeKey: String?
    private var magicPenKey: String?
    /// The Capture Area hot key, which stops a recording (Settings may change it).
    private var stopKey: String? = HotKeyCombo.defaultCapture.displayString

    /// `drawModeKey` / `magicPenKey`: the configured hot keys as displayed
    /// (⌃⌥D, ⌃⌥P), nil when one isn't registered.
    init(drawModeKey: String?, magicPenKey: String? = nil) {
        self.drawModeKey = drawModeKey
        self.magicPenKey = magicPenKey
        primaryButton = RecordingToolbarButton()
        super.init(frame: .zero)
        // A capsule: concentric with the 28 pt buttons inside the 4 pt padding.
        cornerRadius = (Self.buttonSize + 2 * Self.padding) / 2

        var arranged: [NSView] = []
        for (index, group) in RecordingToolbarItem.groups.enumerated() {
            if index > 0 { arranged.append(Self.divider()) }
            for item in group {
                if item == .record {
                    configure(primaryButton, for: .record)
                    arranged.append(primaryButton)
                    arranged.append(makeTimerLabel())
                } else {
                    let button = RecordingToolbarButton()
                    configure(button, for: item)
                    buttons[item] = button
                    arranged.append(button)
                }
            }
        }

        let stack = NSStackView(views: arranged)
        stack.orientation = .horizontal
        stack.spacing = Self.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: Self.padding, left: Self.padding * 2, bottom: Self.padding, right: Self.padding * 2
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView = stack
        NSLayoutConstraint.activate([
            // A horizontal stack ignores its top/bottom insets when sizing
            // (ARCHITECTURE › pins) — pin the height or the glass collapses.
            stack.heightAnchor.constraint(equalToConstant: Self.buttonSize + 2 * Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Updates

    func apply(_ state: RecordingToolbarState) {
        guard state != self.state else { return }
        self.state = state
        render()
    }

    func apply(style: InkStyle) {
        guard style != self.inkStyle else { return }
        self.inkStyle = style
        render()
    }

    /// The elapsed time; `running` false dims it (not started, or finalising).
    func showElapsed(_ elapsed: TimeInterval, running: Bool) {
        let text = RecordingTimerText.string(elapsed: elapsed)
        let grew = text.count != timerLabel.stringValue.count
        timerLabel.stringValue = text
        if grew {
            // Only the digit count changes the width (monospaced digits).
            onFittingSizeChange?()
        }
        timerLabel.setAccessibilityValue(Self.spokenDuration(elapsed))
        if running != timerRunning {
            timerRunning = running
            timerLabel.textColor = running ? .labelColor : .secondaryLabelColor
        }
    }

    /// The session's draw-mode hot key changed (nil: it couldn't be
    /// registered, so no tooltip advertises it).
    func setDrawModeKey(_ key: String?) {
        guard key != drawModeKey else { return }
        drawModeKey = key
        render()
    }

    /// The session's Magic Pen hot key, same rules as `setDrawModeKey`.
    func setMagicPenKey(_ key: String?) {
        guard key != magicPenKey else { return }
        magicPenKey = key
        render()
    }

    /// The configured Capture Area hot key, named by Stop's tooltip.
    func setStopKey(_ key: String?) {
        guard key != stopKey else { return }
        stopKey = key
        render()
    }

    private func render() {
        configure(primaryButton, for: state.primary)
        primaryButton.isEnabled = state.isEnabled(state.primary)
        for (item, button) in buttons {
            button.isEnabled = state.isEnabled(item)
            button.toolTip = item.toolTip(
                drawModeKey: drawModeKey, magicPenKey: magicPenKey, stopKey: stopKey, phase: state.phase
            )
            switch item {
            case .pointer, .pen, .highlighter, .arrow, .oval, .box:
                setOn(state.selected == item, button)
            case .area, .window:
                setOn(item.snapKind == state.snapping, button)
            case .fading:
                setOn(inkStyle.fading, button)
            case .drawMode:
                setOn(state.drawModeOn, button)
            case .magicPen:
                setOn(state.magicPenOn, button)
            case .color:
                button.image = Self.swatch(for: inkStyle.color)
                button.setAccessibilityValue(inkStyle.color.title)
            case .width:
                button.setAccessibilityValue((state.magicPenOn ? inkStyle.magicPenWidth : inkStyle.width).title)
                button.contentTintColor = .labelColor
            default:
                button.contentTintColor = .labelColor
            }
        }
    }

    /// The selected tool and an active toggle show the `.toolbar` on-state
    /// platter — a shape, not just a colour (HIG Accessibility); off buttons
    /// show theirs only under the pointer. Symbols stay monochrome (HIG
    /// Toolbars: no tinted controls).
    private func setOn(_ on: Bool, _ button: NSButton) {
        button.state = on ? .on : .off
        button.contentTintColor = .labelColor
        button.showsBorderOnlyWhileMouseInside = !on
    }

    // MARK: - Building

    private func configure(_ button: NSButton, for item: RecordingToolbarItem) {
        var configuration = Self.symbolConfiguration
        if item == .record || item == .stop {
            // White glyph on a red disc — the recording convention, and the
            // toolbar's single coloured control (HIG Liquid Glass color: color
            // for status and the primary action only). 3.5:1 against white.
            configuration = configuration.applying(.init(paletteColors: [.white, .systemRed]))
        }
        button.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title)?
            .withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        // Borderless toolbar style — no bezel boxes stacked on the glass:
        // outside a real NSToolbar `.toolbar` draws a box around every button
        // unless it only shows on hover (`setOn` keeps the on-state platter).
        // `.toolbar` ignores controlSize, so pin the HIG default macOS
        // control size (28 pt).
        button.bezelStyle = .toolbar
        button.showsBorderOnlyWhileMouseInside = true
        button.setAccessibilityLabel(item.title)
        button.toolTip = item.toolTip(
            drawModeKey: drawModeKey, magicPenKey: magicPenKey, stopKey: stopKey, phase: state.phase
        )
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.tag = RecordingToolbarItem.allCases.firstIndex(of: item)!
        switch item {
        case .area, .window, .pointer, .pen, .highlighter, .arrow, .oval, .box, .fading, .drawMode, .magicPen:
            button.setButtonType(.pushOnPushOff)
        default:
            button.setButtonType(.momentaryPushIn)
        }
        guard button.constraints.isEmpty else { return }
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
    }

    private func makeTimerLabel() -> NSTextField {
        // Monospaced digits so the readout doesn't jitter as it ticks.
        timerLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        timerLabel.textColor = .secondaryLabelColor
        timerLabel.alignment = .center
        timerLabel.setAccessibilityLabel("Elapsed Time")
        timerLabel.setAccessibilityValue(Self.spokenDuration(0))
        let width = (RecordingTimerText.widestSample as NSString)
            .size(withAttributes: [.font: timerLabel.font as Any]).width.rounded(.up) + 6
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
        return timerLabel
    }

    private static func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 1),
            box.heightAnchor.constraint(equalToConstant: dividerHeight),
        ])
        // A few points either side, on top of the stack spacing.
        let holder = NSStackView(views: [box])
        holder.edgeInsets = NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)
        return holder
    }

    /// A filled disc in the preset's exact ink color with a hairline ring, so
    /// White still reads on light glass.
    private static func swatch(for preset: InkColorPreset) -> NSImage {
        let ink = preset.color
        let fill = NSColor(srgbRed: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let disc = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            fill.setFill()
            disc.fill()
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            disc.lineWidth = 1
            disc.stroke()
            return true
        }
        image.accessibilityDescription = "Color: \(preset.title)"
        return image
    }

    private static func spokenDuration(_ elapsed: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: max(0, elapsed.rounded(.down))) ?? ""
    }

    // MARK: - Actions

    @objc private func buttonClicked(_ sender: NSButton) {
        let item = RecordingToolbarItem.allCases[sender.tag]
        switch item {
        case .color:
            showColorMenu(from: sender)
        case .width:
            showWidthMenu(from: sender)
        default:
            if let command = item.command(phase: state.phase) { onCommand?(command) }
        }
        // On/off buttons flip themselves on click. The session's answer has
        // already come back through `apply` when the command changed
        // something; when it was ignored (e.g. the tool already picked),
        // restore what the state says.
        render()
    }

    private func showColorMenu(from button: NSButton) {
        let menu = NSMenu()
        for preset in InkColorPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(colorChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.rawValue
            item.image = Self.swatch(for: preset)
            item.state = preset == inkStyle.color ? .on : .off
            // Display only: the digit works in Setup and draw mode.
            item.keyEquivalent = preset.key
            item.keyEquivalentModifierMask = []
            menu.addItem(item)
        }
        popUp(menu, under: button)
    }

    /// In Magic Pen mode the menu sets the Magic Pen thickness — what is
    /// being drawn with — otherwise the line width.
    private func showWidthMenu(from button: NSButton) {
        let menu = NSMenu()
        let current = state.magicPenOn ? inkStyle.magicPenWidth : inkStyle.width
        for width in InkWidth.allCases {
            let item = NSMenuItem(title: width.title, action: #selector(widthChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = width.rawValue
            item.state = width == current ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, under: button)
    }

    private func popUp(_ menu: NSMenu, under button: NSButton) {
        let y = button.isFlipped ? button.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: button)
    }

    @objc private func colorChosen(_ sender: NSMenuItem) {
        guard let preset = InkColorPreset(rawValue: sender.tag) else { return }
        onCommand?(.ink(.color(preset)))
    }

    @objc private func widthChosen(_ sender: NSMenuItem) {
        guard let width = InkWidth(rawValue: sender.tag) else { return }
        if state.magicPenOn {
            onCommand?(.ink(.magicPenWidth(width)))
            return
        }
        for step in RecordingToolbarItem.widthCommands(from: inkStyle.width, to: width) {
            onCommand?(.ink(step))
        }
    }
}

/// Toolbar buttons react to the first click even while Snappy is inactive —
/// the user's app stays frontmost while recording in interact mode.
@MainActor
private final class RecordingToolbarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

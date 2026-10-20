import AppKit
import Carbon.HIToolbox
import Testing

@testable import Snappy

@Suite("RecordingToolbar")
struct RecordingToolbarTests {
    private let drawKey = HotKeyCombo.defaultDrawMode.displayString
    private let magicKey = HotKeyCombo.defaultMagicPen.displayString

    // MARK: - Items

    @Test("Groups follow the design: Record·timer | Area·Window | tools | style | Clear·toggle·Magic Pen | Cancel")
    func groups() {
        #expect(RecordingToolbarItem.groups == [
            [.record],
            [.area, .window],
            [.pointer, .pen, .highlighter, .arrow, .oval, .box],
            [.color, .width, .fading],
            [.clear, .drawMode, .magicPen],
            [.cancel],
        ])
        // Every item has a place; Stop shares Record's slot.
        let placed = Set(RecordingToolbarItem.groups.joined()).union([.stop])
        #expect(placed == Set(RecordingToolbarItem.allCases))
        #expect(RecordingToolbarItem.toolItems == RecordingToolbarItem.groups[2])
    }

    @Test("The five tool buttons are the five ink tools, in order")
    func tools() {
        let tools = RecordingToolbarItem.toolItems.compactMap(\.tool)
        #expect(tools == InkTool.allCases)
        for tool in InkTool.allCases {
            #expect(RecordingToolbarItem(tool: tool)?.tool == tool)
            #expect(RecordingToolbarItem(tool: tool)?.command == .tool(tool))
        }
    }

    @Test("Commands: each button sends what its key does; Color and Width open menus")
    func commands() {
        #expect(RecordingToolbarItem.record.command == .record)
        #expect(RecordingToolbarItem.stop.command == .stop)
        #expect(RecordingToolbarItem.pointer.command == .pointer)
        #expect(RecordingToolbarItem.fading.command == .ink(.toggleFading))
        #expect(RecordingToolbarItem.clear.command == .ink(.clear))
        #expect(RecordingToolbarItem.drawMode.command == .toggleDrawMode)
        #expect(RecordingToolbarItem.magicPen.command == .toggleMagicPen)
        #expect(RecordingToolbarItem.cancel.command == .cancel)
        #expect(RecordingToolbarItem.area.command == .snap(.area))
        #expect(RecordingToolbarItem.window.command == .snap(.window))
        #expect(RecordingToolbarItem.color.command == nil)
        #expect(RecordingToolbarItem.width.command == nil)
    }

    @Test("Area / Window: S / W's snap; the mode already on steps back, the other one switches")
    func snapCommands() {
        let target = RecordingToolbarStateTests.target
        #expect(RecordingToolbarItem.area.snapKind == .area)
        #expect(RecordingToolbarItem.window.snapKind == .window)
        #expect(RecordingToolbarItem.allCases.filter { $0.snapKind != nil } == [.area, .window])
        for phase: RecordingPhase in [.setup(.pointer), .setup(.tool(.pen))] {
            #expect(RecordingToolbarItem.area.command(phase: phase) == .snap(.area))
            #expect(RecordingToolbarItem.window.command(phase: phase) == .snap(.window))
        }
        let snapArea = RecordingPhase.snapping(.area, previous: target, returnTo: .pointer)
        #expect(RecordingToolbarItem.area.command(phase: snapArea) == .stepBack)
        #expect(RecordingToolbarItem.window.command(phase: snapArea) == .snap(.window))
        let snapWindow = RecordingPhase.snapping(.window, previous: target, returnTo: .pointer)
        #expect(RecordingToolbarItem.window.command(phase: snapWindow) == .stepBack)
        #expect(RecordingToolbarItem.area.command(phase: snapWindow) == .snap(.area))
        // Every other item sends the same command in every phase.
        for phase in RecordingToolbarStateTests.phases.map(\.phase) {
            for item in RecordingToolbarItem.allCases where item.snapKind == nil {
                #expect(item.command(phase: phase) == item.command, "\(item) in \(phase)")
            }
        }
    }

    @Test("Area / Window: the active one steps back from Pointer, like Esc")
    func snapClickStepsBack() {
        var session = RecordingSession(target: RecordingToolbarStateTests.target, countdownSeconds: 3)
        session.handle(.command(RecordingToolbarItem.window.command(phase: session.phase)!))
        #expect(session.phase == .snapping(.window, previous: RecordingToolbarStateTests.target, returnTo: .pointer))
        let hovered = RecordingTarget.area(globalRect: CGRect(x: 50, y: 50, width: 200, height: 100), displayID: 1)
        session.handle(.targetChanged(hovered))
        session.handle(.command(RecordingToolbarItem.area.command(phase: session.phase)!))
        #expect(session.phase == .snapping(.area, previous: RecordingToolbarStateTests.target, returnTo: .pointer))
        session.handle(.command(RecordingToolbarItem.area.command(phase: session.phase)!))
        #expect(session.phase == .setup(.pointer))
        #expect(session.target == RecordingToolbarStateTests.target)
    }

    @Test("Area / Window: the active one steps back to the Setup tool snapping started from, same as Esc / Q")
    func snapClickReturnsToTheToolItCameFrom() {
        let target = RecordingToolbarStateTests.target
        for kind in [SnapKind.area, .window] {
            let item: RecordingToolbarItem = kind == .area ? .area : .window
            func snapFromPen() -> RecordingSession {
                var session = RecordingSession(target: target, countdownSeconds: 3)
                session.handle(.command(RecordingToolbarItem.pen.command(phase: session.phase)!))
                #expect(session.phase == .setup(.tool(.pen)))
                session.handle(.command(item.command(phase: session.phase)!))
                #expect(session.phase == .snapping(kind, previous: target, returnTo: .tool(.pen)))
                return session
            }
            var clicked = snapFromPen()
            clicked.handle(.command(item.command(phase: clicked.phase)!))
            var escaped = snapFromPen()
            escaped.handle(.command(.stepBack))
            #expect(clicked.phase == .setup(.tool(.pen)), "\(kind): back to Pen, not Pointer")
            #expect(clicked.phase == escaped.phase, "\(kind): the click equals Esc / Q")
            #expect(clicked.target == target)
        }
    }

    @Test("Area / Window tooltips: S / W in Setup and snap mode only")
    func snapTooltips() {
        let target = RecordingToolbarStateTests.target
        #expect(RecordingToolbarItem.area.toolTip(drawModeKey: drawKey, phase: .setup(.pointer)) == "Snap to a window's area (S)")
        #expect(RecordingToolbarItem.window.toolTip(drawModeKey: drawKey, phase: .setup(.tool(.box))) == "Snap to a window (W)")
        let snapWindow = RecordingPhase.snapping(.window, previous: target, returnTo: .pointer)
        #expect(RecordingToolbarItem.window.toolTip(drawModeKey: drawKey, phase: snapWindow)
            == "Stop snapping and go back to the previous target (W)")
        #expect(RecordingToolbarItem.area.toolTip(drawModeKey: drawKey, phase: snapWindow) == "Snap to a window's area (S)")
        for phase: RecordingPhase in [.countdown(remaining: 2), .recording(.interact), .recording(.draw(.pen)), .stopping] {
            #expect(RecordingToolbarItem.area.toolTip(drawModeKey: drawKey, phase: phase) == "Snap to a window's area")
            #expect(RecordingToolbarItem.window.toolTip(drawModeKey: drawKey, phase: phase) == "Snap to a window")
        }
    }

    @Test("Shortcuts: the key map's bindings and the three hot keys")
    func shortcuts() {
        #expect(RecordingToolbarItem.allCases.map { $0.shortcut(drawModeKey: drawKey, magicPenKey: magicKey) } == [
            "R", "⇧⌘4", "S", "W", "V", "P", "H", "A", "O", "B", "1–5", "[ or ]", "F", "⌫", "⌃⌥D", "⌃⌥P", "Esc",
        ])
    }

    @Test("Magic Pen: named and drawn as a wand, ⌃⌥P advertised only while recording and only when registered")
    func magicPenItem() {
        let item = RecordingToolbarItem.magicPen
        #expect(item.title == "Magic Pen")
        #expect(item.symbolName == "wand.and.stars")
        #expect(item.toolTip(drawModeKey: drawKey, magicPenKey: magicKey, phase: .recording(.interact))
            == "Draw fading ink (⌃⌥P)")
        #expect(item.toolTip(drawModeKey: drawKey, magicPenKey: magicKey, phase: .recording(.magicPen(resume: nil)))
            == "Draw fading ink (⌃⌥P)")
        #expect(item.toolTip(drawModeKey: drawKey, magicPenKey: magicKey, phase: .setup(.pointer)) == "Draw fading ink")
        // Refused by the system this session: no dead shortcut.
        #expect(item.toolTip(drawModeKey: drawKey, magicPenKey: nil, phase: .recording(.interact)) == "Draw fading ink")
        // In Magic Pen mode the Width control is the Magic Pen's thickness.
        #expect(RecordingToolbarItem.width.toolTip(
            drawModeKey: drawKey, magicPenKey: magicKey, phase: .recording(.magicPen(resume: nil))
        ) == "Choose the Magic Pen thickness ([ or ])")
        // F does nothing there (Magic Pen ink always fades).
        #expect(RecordingToolbarItem.fading.toolTip(
            drawModeKey: drawKey, magicPenKey: magicKey, phase: .recording(.magicPen(resume: nil))
        ) == "Fade new strokes out after a few seconds")
    }

    /// HIG Offering help: a verb phrase, sentence case, ≤ 75 characters, not
    /// just the control's name — the editor toolbar's rules.
    @Test("Tooltips read '<verb phrase> (KEY)' in every phase, the key only where it works")
    func tooltips() {
        for phase in RecordingToolbarStateTests.phases.map(\.phase) {
            for item in RecordingToolbarItem.allCases {
                let tip = item.toolTip(drawModeKey: drawKey, magicPenKey: magicKey, phase: phase)
                if let key = item.key(drawModeKey: drawKey, magicPenKey: magicKey, phase: phase) {
                    #expect(tip.hasSuffix(" (\(key))"), "\(item): \(tip)")
                } else {
                    #expect(!tip.hasSuffix(")"), "\(item) in \(phase): \(tip)")
                }
                #expect(!tip.hasPrefix("\(item.title) ("))
                #expect(tip.count <= 75)
                #expect(tip.first?.isUppercase == true)
            }
        }
        #expect(RecordingToolbarItem.arrow.toolTip(drawModeKey: drawKey, phase: .setup(.pointer))
            == "Draw an arrow from tail to head (A)")
        #expect(RecordingToolbarItem.drawMode.toolTip(drawModeKey: drawKey, phase: .recording(.interact))
            == "Switch between drawing and using your app (⌃⌥D)")
    }

    @Test("Shared tools use the editor's wording")
    @MainActor
    func tooltipsMatchEditor() {
        let editor = Dictionary(uniqueKeysWithValues: EditorWindowController.toolSpecs.map { ($0.label, $0.help) })
        let setup = RecordingPhase.setup(.pointer)
        #expect(RecordingToolbarItem.pen.toolTip(drawModeKey: drawKey, phase: setup) == "\(editor["Pen"]!) (P)")
        #expect(RecordingToolbarItem.arrow.toolTip(drawModeKey: drawKey, phase: setup) == "\(editor["Arrow"]!) (A)")
        #expect(RecordingToolbarItem.oval.toolTip(drawModeKey: drawKey, phase: setup) == "\(editor["Oval"]!) (O)")
    }

    @Test("Cancel advertises Esc only where Esc cancels: Setup in Pointer mode (review r1 #2)")
    func cancelKey() {
        let target = RecordingToolbarStateTests.target
        #expect(RecordingToolbarItem.cancel.toolTip(drawModeKey: drawKey, phase: .setup(.pointer)) == "Cancel recording (Esc)")
        for phase: RecordingPhase in [
            .setup(.tool(.pen)), .snapping(.area, previous: target, returnTo: .pointer), .countdown(remaining: 2),
        ] {
            #expect(RecordingToolbarItem.cancel.toolTip(drawModeKey: drawKey, phase: phase) == "Cancel recording")
        }
        #expect(RecordingToolbarItem.cancel.toolTip(drawModeKey: drawKey, phase: .recording(.draw(.pen)))
            == "Discard this recording")
        #expect(RecordingToolbarItem.pointer.toolTip(drawModeKey: drawKey, phase: .recording(.draw(.pen)))
            == "Stop drawing and use your app (V)")
        // Interact mode: the letters belong to the user's app (Q15).
        #expect(RecordingToolbarItem.pen.toolTip(drawModeKey: drawKey, phase: .recording(.interact)) == "Draw freehand")
    }

    /// What pressing `key` does in `phase`, as a command — through the key map
    /// for keys Snappy receives, through the session for the two hot keys.
    private func keyCommands(_ item: RecordingToolbarItem, phase: RecordingPhase) -> [RecordingCommand?] {
        func mapped(_ keyCode: Int, _ characters: String) -> RecordingCommand? {
            RecordingKeyMap.command(phase: phase, keyCode: UInt16(keyCode), characters: characters, modifiers: [])
        }
        switch item {
        case .stop: return [.stop]
        case .drawMode: return [.toggleDrawMode]
        case .magicPen: return [.toggleMagicPen]
        case .cancel: return [mapped(kVK_Escape, "\u{1B}")]
        case .clear: return [mapped(kVK_Delete, "\u{7F}")]
        case .color: return InkColorPreset.allCases.map { mapped(0, $0.key) }
        case .width: return [mapped(kVK_ANSI_LeftBracket, "["), mapped(kVK_ANSI_RightBracket, "]")]
        default: return [mapped(0, item.shortcut(drawModeKey: drawKey).lowercased())]
        }
    }

    /// What clicking the button does — one command sequence per key above,
    /// from a style whose widths are `width`. The Width menu's matching
    /// choices are one step either side of it: in Magic Pen mode the menu
    /// sets the Magic Pen thickness directly, otherwise it steps the line width.
    private func clickCommands(
        _ item: RecordingToolbarItem, phase: RecordingPhase, width: InkWidth
    ) -> [[RecordingCommand]] {
        switch item {
        case .color: return InkColorPreset.allCases.map { [.ink(.color($0))] }
        case .width:
            let choices = [width.thinner, width.thicker]
            if case .recording(.magicPen) = phase { return choices.map { [.ink(.magicPenWidth($0))] } }
            return choices.map { RecordingToolbarItem.widthCommands(from: width, to: $0).map { .ink($0) } }
        default: return [[item.command(phase: phase)!]]
        }
    }

    /// A key press and a click do the same thing: style commands by the
    /// style they leave `base` in; every other outcome must match exactly
    /// (undo, redo and clear never stand in for each other — review nit).
    private func sameEffect(_ press: RecordingOutcome, _ clicks: [RecordingOutcome], from base: InkStyle) -> Bool {
        func styled(_ outcomes: [RecordingOutcome]) -> InkStyle? {
            var style = base
            for outcome in outcomes {
                guard case .ink(let command) = outcome, command.isStyle else { return nil }
                style = style.applying(command)
            }
            return style
        }
        if let pressed = styled([press]), let clicked = styled(clicks) { return pressed == clicked }
        return [press] == clicks
    }

    @Test("A tooltip advertises a key exactly when pressing it does what the click does (review r1 #2)",
          arguments: InkWidth.allCases)
    func advertisedKeysAreTrue(width: InkWidth) {
        let base = InkStyle(color: .red, width: width, fading: false, magicPenWidth: width)
        for session in RecordingToolbarStateTests.phases {
            for item in RecordingToolbarItem.allCases {
                let keys = keyCommands(item, phase: session.phase)
                let clicks = clickCommands(item, phase: session.phase, width: width)
                let same = keys.count == clicks.count && zip(keys, clicks).allSatisfy { key, click in
                    guard let key else { return false }
                    var pressed = session, clicked = session
                    let pressOutcome = pressed.handle(.command(key))
                    let clickOutcomes = click.map { clicked.handle(.command($0)) }
                    // The hot keys are delivered in every phase; they only
                    // count where the session acts on them.
                    if [.stop, .drawMode, .magicPen].contains(item), pressOutcome == .ignored { return false }
                    return pressed == clicked && sameEffect(pressOutcome, clickOutcomes, from: base)
                }
                let advertised = item.key(drawModeKey: drawKey, magicPenKey: magicKey, phase: session.phase) != nil
                #expect(advertised == same, "\(item) in \(session.phase) from \(width)")
            }
        }
    }

    @Test("Equal effects are content-exact: undo, redo and clear never match each other")
    func contentCommandsCompareExactly() {
        let base = InkStyle(color: .red, width: .medium, fading: false, magicPenWidth: .medium)
        let content: [InkCommand] = [.undo, .redo, .clear]
        for a in content {
            for b in content {
                #expect(sameEffect(.ink(a), [.ink(b)], from: base) == (a == b), "\(a) vs \(b)")
            }
        }
        #expect(!sameEffect(.ink(.undo), [], from: base), "a no-op click is not an undo")
    }

    @Test("Every symbol exists on this system")
    @MainActor
    func symbolsResolve() {
        for item in RecordingToolbarItem.allCases {
            #expect(NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil) != nil, "\(item.symbolName)")
        }
    }

    @Test("Same symbols as the editor's matching tools")
    @MainActor
    func symbolsMatchEditor() {
        let editor = Dictionary(uniqueKeysWithValues: EditorWindowController.toolSpecs.map { ($0.label, $0.symbol) })
        #expect(RecordingToolbarItem.pointer.symbolName == editor["Select"])
        #expect(RecordingToolbarItem.pen.symbolName == editor["Pen"])
        #expect(RecordingToolbarItem.arrow.symbolName == editor["Arrow"])
        #expect(RecordingToolbarItem.oval.symbolName == editor["Oval"])
        #expect(RecordingToolbarItem.box.symbolName == editor["Rectangle"])
    }

    // MARK: - Width menu

    @Test("Width menu choices become [ / ] steps that land on the chosen width")
    func widthSteps() {
        #expect(RecordingToolbarItem.widthCommands(from: .thin, to: .thick) == [.thicker, .thicker])
        #expect(RecordingToolbarItem.widthCommands(from: .thick, to: .medium) == [.thinner])
        #expect(RecordingToolbarItem.widthCommands(from: .medium, to: .medium).isEmpty)
        for from in InkWidth.allCases {
            for to in InkWidth.allCases {
                let style = RecordingToolbarItem.widthCommands(from: from, to: to)
                    .reduce(InkStyle(color: .red, width: from, fading: false)) { $0.applying($1) }
                #expect(style.width == to)
            }
        }
    }

    // MARK: - Timer

    @Test("Timer text: mm:ss, then h:mm:ss; whole seconds, never rounded up")
    func timerText() {
        #expect(RecordingTimerText.string(elapsed: 0) == "00:00")
        #expect(RecordingTimerText.string(elapsed: 0.99) == "00:00")
        #expect(RecordingTimerText.string(elapsed: 59.9) == "00:59")
        #expect(RecordingTimerText.string(elapsed: 61) == "01:01")
        #expect(RecordingTimerText.string(elapsed: 3599) == "59:59")
        #expect(RecordingTimerText.string(elapsed: 3600) == "1:00:00")
        #expect(RecordingTimerText.string(elapsed: 3725) == "1:02:05")
        #expect(RecordingTimerText.string(elapsed: -3) == "00:00")
    }
}

@Suite("RecordingToolbarState")
struct RecordingToolbarStateTests {
    static let target = RecordingTarget.area(globalRect: CGRect(x: 0, y: 0, width: 400, height: 300), displayID: 1)

    /// A session driven into each phase the toolbar can see.
    private static func session(_ commands: [RecordingEvent], countdown: Int = 3) -> RecordingSession {
        var session = RecordingSession(target: target, countdownSeconds: countdown)
        for event in commands { session.handle(event) }
        return session
    }

    static let phases: [RecordingSession] = [
        session([]),                                                          // setup pointer
        session([.command(.tool(.arrow))]),                                   // setup tool
        session([.command(.snap(.window))]),                                  // snapping
        session([.command(.tool(.oval)), .command(.snap(.area))]),            // snapping (area, from a tool)
        session([.command(.record)]),                                         // countdown
        session([.command(.record)], countdown: 0),                           // recording interact
        session([.command(.record), .command(.toggleDrawMode)], countdown: 0), // draw (pen)
        session([.command(.record), .command(.tool(.box))], countdown: 0),    // draw (box)
        session([.command(.record), .command(.toggleMagicPen)], countdown: 0), // Magic Pen from interact
        session([.command(.record), .command(.tool(.oval)), .command(.toggleMagicPen)], countdown: 0), // … from draw
        session([.command(.record), .command(.stop)], countdown: 0),          // stopping
    ]

    /// What a click on `item` sends in `phase` (Color/Width: a representative
    /// menu choice).
    private static func command(for item: RecordingToolbarItem, phase: RecordingPhase) -> RecordingCommand {
        switch item {
        case .color: .ink(.color(.blue))
        case .width: .ink(.thicker)
        default: item.command(phase: phase)!
        }
    }

    @Test("A control is enabled exactly when the session would act on its command")
    func enabledMatchesSession() {
        #expect(Self.phases.map(\.phase) == [
            .setup(.pointer), .setup(.tool(.arrow)), .snapping(.window, previous: Self.target, returnTo: .pointer),
            .snapping(.area, previous: Self.target, returnTo: .tool(.oval)),
            .countdown(remaining: 3), .recording(.interact), .recording(.draw(.pen)), .recording(.draw(.box)),
            .recording(.magicPen(resume: nil)), .recording(.magicPen(resume: .oval)), .stopping,
        ])
        for session in Self.phases {
            let state = RecordingToolbarState(phase: session.phase)
            for item in RecordingToolbarItem.allCases where item != state.selected {
                var probe = session
                let acted = probe.handle(.command(Self.command(for: item, phase: session.phase))) != .ignored
                #expect(state.isEnabled(item) == acted, "\(item) in \(session.phase)")
            }
            // The selected tool stays enabled (a click on it is a harmless no-op)
            // except while snapping/counting down/stopping.
            if let selected = state.selected, session.phase.isRecording || session.phase == .setup(.pointer)
                || session.phase == .setup(.tool(.arrow)) {
                #expect(state.isEnabled(selected))
            }
        }
    }

    @Test("Record before recording, Stop from recording on")
    func primary() {
        #expect(RecordingToolbarState(phase: .setup(.pointer)).primary == .record)
        #expect(RecordingToolbarState(phase: .countdown(remaining: 2)).primary == .record)
        #expect(RecordingToolbarState(phase: .recording(.interact)).primary == .stop)
        #expect(RecordingToolbarState(phase: .stopping).primary == .stop)
        #expect(!RecordingToolbarState(phase: .stopping).isEnabled(.stop))
    }

    @Test("Selection: Pointer or the tool; draw mode lights the toggle")
    func selection() {
        #expect(RecordingToolbarState(phase: .setup(.pointer)).selected == .pointer)
        #expect(RecordingToolbarState(phase: .setup(.tool(.highlighter))).selected == .highlighter)
        #expect(RecordingToolbarState(phase: .snapping(.area, previous: Self.target, returnTo: .tool(.oval))).selected == .oval)
        let interact = RecordingToolbarState(phase: .recording(.interact))
        #expect(interact.selected == .pointer)
        #expect(!interact.drawModeOn)
        let draw = RecordingToolbarState(phase: .recording(.draw(.arrow)))
        #expect(draw.selected == .arrow)
        #expect(draw.drawModeOn)
        #expect(!draw.magicPenOn)
        #expect(RecordingToolbarState(phase: .stopping).selected == nil)
    }

    @Test("Magic Pen lights its own toggle only: no tool selected, draw mode off, enabled only while recording")
    func magicPenState() {
        for resume: InkTool? in [nil, .arrow] {
            let state = RecordingToolbarState(phase: .recording(.magicPen(resume: resume)))
            #expect(state.magicPenOn)
            #expect(!state.drawModeOn)
            #expect(state.selected == nil)
            #expect(state.isEnabled(.magicPen) && state.isEnabled(.stop))
        }
        #expect(!RecordingToolbarState(phase: .recording(.interact)).magicPenOn)
        #expect(RecordingToolbarState(phase: .recording(.interact)).isEnabled(.magicPen))
        #expect(RecordingToolbarState(phase: .recording(.draw(.pen))).isEnabled(.magicPen))
        for phase: RecordingPhase in [.setup(.pointer), .countdown(remaining: 1), .stopping] {
            #expect(!RecordingToolbarState(phase: phase).isEnabled(.magicPen), "\(phase)")
        }
    }

    @Test("Area / Window: enabled in Setup and snap mode, on for the active snap mode, dimmed — never hidden — later")
    func snapState() {
        let target = Self.target
        for phase: RecordingPhase in [.setup(.pointer), .setup(.tool(.arrow))] {
            let state = RecordingToolbarState(phase: phase)
            #expect(state.isEnabled(.area) && state.isEnabled(.window), "\(phase)")
            #expect(state.snapping == nil)
        }
        for kind: SnapKind in [.area, .window] {
            let state = RecordingToolbarState(phase: .snapping(kind, previous: target, returnTo: .tool(.oval)))
            #expect(state.snapping == kind)
            #expect(state.isEnabled(.area) && state.isEnabled(.window) && state.isEnabled(.cancel))
            #expect(!state.isEnabled(.record))
            #expect(state.selected == .oval, "the tool picker keeps the mode it returns to")
        }
        for phase: RecordingPhase in [
            .countdown(remaining: 1), .recording(.interact), .recording(.draw(.pen)),
            .recording(.magicPen(resume: nil)), .stopping,
        ] {
            let state = RecordingToolbarState(phase: phase)
            #expect(!state.isEnabled(.area) && !state.isEnabled(.window), "\(phase)")
            #expect(state.snapping == nil)
        }
        // Still laid out in every phase: the groups are fixed.
        #expect(RecordingToolbarItem.groups.joined().contains(.area))
        #expect(RecordingToolbarItem.groups.joined().contains(.window))
    }

    @Test("The state keeps its phase for the tooltips")
    func keepsPhase() {
        #expect(RecordingToolbarState(phase: .countdown(remaining: 1)).phase == .countdown(remaining: 1))
    }
}

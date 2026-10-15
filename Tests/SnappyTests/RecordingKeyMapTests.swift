import AppKit
import Carbon.HIToolbox
import Testing
@testable import Snappy

@Suite("RecordingKeyMap")
struct RecordingKeyMapTests {
    private static let target = RecordingTarget.area(globalRect: CGRect(x: 0, y: 0, width: 10, height: 10), displayID: 1)

    /// Letter / symbol keys: (characters, keyCode). Key codes matter only for
    /// Esc and ⌫; the map reads characters otherwise.
    private static let letters: [String: Int] = [
        "r": kVK_ANSI_R, "s": kVK_ANSI_S, "w": kVK_ANSI_W, "v": kVK_ANSI_V, "p": kVK_ANSI_P,
        "h": kVK_ANSI_H, "a": kVK_ANSI_A, "o": kVK_ANSI_O, "b": kVK_ANSI_B, "f": kVK_ANSI_F,
        "q": kVK_ANSI_Q, "z": kVK_ANSI_Z, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
        "6": kVK_ANSI_6, "c": kVK_ANSI_C, "e": kVK_ANSI_E, "d": kVK_ANSI_D, "x": kVK_ANSI_X,
    ]

    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [], in phase: RecordingPhase) -> RecordingCommand? {
        RecordingKeyMap.command(
            phase: phase, keyCode: UInt16(Self.letters[characters.lowercased()]!),
            characters: characters, modifiers: modifiers
        )
    }

    private func esc(_ modifiers: NSEvent.ModifierFlags = [], in phase: RecordingPhase) -> RecordingCommand? {
        RecordingKeyMap.command(phase: phase, keyCode: UInt16(kVK_Escape), characters: "\u{1B}", modifiers: modifiers)
    }

    private func delete(in phase: RecordingPhase) -> RecordingCommand? {
        RecordingKeyMap.command(phase: phase, keyCode: UInt16(kVK_Delete), characters: "\u{7F}", modifiers: [])
    }

    /// The table shared by Setup and draw mode (everything but R / S / W).
    private static let inkTable: [(String, RecordingCommand)] = [
        ("v", .pointer),
        ("p", .tool(.pen)), ("h", .tool(.highlighter)), ("a", .tool(.arrow)),
        ("o", .tool(.oval)), ("b", .tool(.box)),
        ("f", .ink(.toggleFading)),
        ("1", .ink(.color(.red))), ("2", .ink(.color(.yellow))), ("3", .ink(.color(.green))),
        ("4", .ink(.color(.blue))), ("5", .ink(.color(.white))),
        ("[", .ink(.thinner)), ("]", .ink(.thicker)),
        ("q", .stepBack),
    ]

    private static let setupPhases: [RecordingPhase] = [.setup(.pointer), .setup(.tool(.arrow))]

    // MARK: - Setup

    @Test(arguments: setupPhases)
    func setupMapsEveryKeyInTheTable(phase: RecordingPhase) {
        #expect(key("r", in: phase) == .record)
        #expect(key("s", in: phase) == .snap(.area))
        #expect(key("w", in: phase) == .snap(.window))
        for (characters, command) in Self.inkTable {
            #expect(key(characters, in: phase) == command, "\(characters)")
        }
        #expect(delete(in: phase) == .ink(.clear))
        #expect(key("z", .command, in: phase) == .ink(.undo))
        #expect(key("Z", [.command, .shift], in: phase) == .ink(.redo))
        #expect(esc(in: phase) == .stepBack)
    }

    @Test func unmappedKeysAreNil() {
        for characters in ["c", "e", "d", "x", "6", "z"] {
            #expect(key(characters, in: .setup(.pointer)) == nil, "\(characters)")
        }
    }

    @Test func shiftAndCapsLockAreTolerated() {
        #expect(key("R", .shift, in: .setup(.pointer)) == .record)
        #expect(key("R", .capsLock, in: .setup(.pointer)) == .record)
        #expect(key("P", [.shift, .capsLock], in: .setup(.pointer)) == .tool(.pen))
        #expect(key("z", [.command, .capsLock], in: .setup(.pointer)) == .ink(.undo))
    }

    @Test func realModifiersDisableSingleLetters() {
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option] {
            #expect(key("r", modifiers, in: .setup(.pointer)) == nil)
            #expect(key("p", modifiers, in: .setup(.pointer)) == nil)
            #expect(esc(modifiers, in: .setup(.pointer)) == nil)
        }
        #expect(key("z", [.command, .option], in: .setup(.pointer)) == nil)
        #expect(key("z", .control, in: .setup(.pointer)) == nil)
    }

    // MARK: - Snapping

    private func enter(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = [], in phase: RecordingPhase) -> RecordingCommand? {
        RecordingKeyMap.command(phase: phase, keyCode: UInt16(keyCode), characters: "\r", modifiers: modifiers)
    }

    /// Q33, S and W alike: the same key again steps back (= Esc), the other
    /// switches, Return / keypad Enter confirm (`.snap(kind)` with the current
    /// kind is the session's confirm).
    @Test(arguments: [SnapKind.area, .window])
    func snapKeysSameStepsBackOtherSwitchesEnterConfirms(kind: SnapKind) {
        let phase = RecordingPhase.snapping(kind, previous: Self.target, returnTo: .pointer)
        let same = kind == .area ? "s" : "w"
        let other = kind == .area ? "w" : "s"
        let otherKind: SnapKind = kind == .area ? .window : .area
        #expect(key(same, in: phase) == .stepBack)
        #expect(key(same.uppercased(), .shift, in: phase) == .stepBack)
        #expect(key(other, in: phase) == .snap(otherKind))
        #expect(enter(kVK_Return, in: phase) == .snap(kind))
        // Keypad Enter carries .numericPad (sometimes .function); Caps Lock is ignored.
        #expect(enter(kVK_ANSI_KeypadEnter, .numericPad, in: phase) == .snap(kind))
        #expect(enter(kVK_ANSI_KeypadEnter, [.numericPad, .function], in: phase) == .snap(kind))
        #expect(enter(kVK_Return, .capsLock, in: phase) == .snap(kind))
        for modifiers: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            #expect(enter(kVK_Return, modifiers, in: phase) == nil)
        }
    }

    /// Return confirms only while snapping — Setup, the countdown and draw mode ignore it.
    @Test func returnOutsideSnappingDoesNothing() {
        for phase: RecordingPhase in [.setup(.pointer), .setup(.tool(.pen)), .countdown(remaining: 2), .recording(.draw(.pen))] {
            #expect(enter(kVK_Return, in: phase) == nil)
            #expect(enter(kVK_ANSI_KeypadEnter, .numericPad, in: phase) == nil)
        }
    }

    /// Through the real session: S, S is back to the previous target; S, W
    /// switches and keeps it; Return keeps the hovered one.
    @Test func snapKeysDriveTheSession() {
        let previous = Self.target
        let hovered = RecordingTarget.area(globalRect: CGRect(x: 50, y: 50, width: 200, height: 100), displayID: 1)
        func snapping(_ keys: [RecordingCommand?]) -> RecordingSession {
            var session = RecordingSession(target: previous, countdownSeconds: 3)
            session.handle(.command(.snap(.area)))
            session.handle(.targetChanged(hovered))
            for command in keys { if let command { session.handle(.command(command)) } }
            return session
        }
        let phase = RecordingPhase.snapping(.area, previous: previous, returnTo: .pointer)
        let back = snapping([key("s", in: phase)])
        #expect(back.phase == .setup(.pointer))
        #expect(back.target == previous)
        let confirmed = snapping([enter(kVK_Return, in: phase)])
        #expect(confirmed.phase == .setup(.pointer))
        #expect(confirmed.target == hovered)
        let switched = snapping([key("w", in: phase)])
        #expect(switched.phase == .snapping(.window, previous: previous, returnTo: .pointer))
        // W again in W mode: back to the target from before snapping.
        let switchedPhase = RecordingPhase.snapping(.window, previous: previous, returnTo: .pointer)
        let switchedBack = snapping([key("w", in: phase), key("w", in: switchedPhase)])
        #expect(switchedBack.phase == .setup(.pointer))
        #expect(switchedBack.target == previous)
    }

    @Test func snappingOnlyKnowsSWEnterAndStepBack() {
        let phase = RecordingPhase.snapping(.area, previous: Self.target, returnTo: .pointer)
        #expect(key("s", in: phase) == .stepBack)
        #expect(key("w", in: phase) == .snap(.window))
        #expect(esc(in: phase) == .stepBack)
        #expect(key("q", in: phase) == .stepBack)
        #expect(key("r", in: phase) == nil)
        #expect(delete(in: phase) == nil)
        #expect(key("z", .command, in: phase) == nil)
        for (characters, command) in Self.inkTable where command != .stepBack {
            #expect(key(characters, in: phase) == nil, "\(characters)")
        }
    }

    // MARK: - Countdown

    @Test func countdownOnlyStepsBack() {
        let phase = RecordingPhase.countdown(remaining: 2)
        #expect(esc(in: phase) == .stepBack)
        #expect(key("q", in: phase) == .stepBack)
        for characters in ["r", "s", "w", "p", "v", "1", "[", "f"] {
            #expect(key(characters, in: phase) == nil, "\(characters)")
        }
        #expect(delete(in: phase) == nil)
        #expect(key("z", .command, in: phase) == nil)
    }

    // MARK: - Recording

    @Test func drawModeHasTheToolTableWithoutRSW() {
        let phase = RecordingPhase.recording(.draw(.pen))
        for (characters, command) in Self.inkTable {
            #expect(key(characters, in: phase) == command, "\(characters)")
        }
        #expect(delete(in: phase) == .ink(.clear))
        #expect(key("z", .command, in: phase) == .ink(.undo))
        #expect(key("Z", [.command, .shift], in: phase) == .ink(.redo))
        #expect(esc(in: phase) == .stepBack)
        #expect(key("r", in: phase) == nil)
        #expect(key("s", in: phase) == nil)
        #expect(key("w", in: phase) == nil)
    }

    @Test(arguments: [nil, InkTool.highlighter])
    func magicPenHasTheDrawTableButBracketsStepItsThicknessAndFIsOff(resume: InkTool?) {
        let phase = RecordingPhase.recording(.magicPen(resume: resume))
        for (characters, command) in Self.inkTable {
            let expected: RecordingCommand? = switch characters {
            case "[": .ink(.magicPenThinner)
            case "]": .ink(.magicPenThicker)
            case "f": nil // Magic Pen strokes always fade
            default: command
            }
            #expect(key(characters, in: phase) == expected, "\(characters)")
        }
        #expect(delete(in: phase) == .ink(.clear))
        #expect(key("z", .command, in: phase) == .ink(.undo))
        #expect(key("Z", [.command, .shift], in: phase) == .ink(.redo))
        #expect(esc(in: phase) == .stepBack)
        for characters in ["r", "s", "w"] {
            #expect(key(characters, in: phase) == nil, "\(characters)")
        }
    }

    @Test func magicPenKeysNeedNoModifierButTolerateCapsLock() {
        let phase = RecordingPhase.recording(.magicPen(resume: nil))
        #expect(key("]", .capsLock, in: phase) == .ink(.magicPenThicker))
        // ⌃⌥P itself is the Carbon hot key and never reaches the map; a
        // modified bracket or letter maps to nothing (never leaks a tool).
        #expect(key("[", [.control, .option], in: phase) == nil)
        #expect(key("p", [.control, .option], in: phase) == nil)
    }

    @Test func interactModeAndLaterPhasesPassEveryKeyThrough() {
        let phases: [RecordingPhase] = [
            .recording(.interact), .stopping, .finished(URL(filePath: "/tmp/t.mp4")), .cancelled,
        ]
        for phase in phases {
            for characters in Self.letters.keys {
                #expect(key(characters, in: phase) == nil, "\(characters) in \(phase)")
                #expect(key(characters, .command, in: phase) == nil, "⌘\(characters) in \(phase)")
            }
            #expect(esc(in: phase) == nil)
            #expect(delete(in: phase) == nil)
        }
    }

    @Test func missingCharactersOnlyLeaveKeyCodeKeys() {
        #expect(RecordingKeyMap.command(phase: .setup(.pointer), keyCode: 0, characters: nil, modifiers: []) == nil)
        #expect(RecordingKeyMap.command(
            phase: .setup(.pointer), keyCode: UInt16(kVK_Escape), characters: nil, modifiers: []
        ) == .stepBack)
    }
}

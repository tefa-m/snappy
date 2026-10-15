import AppKit
import Carbon.HIToolbox

/// PURE key → command table of the recording view, per phase — unit-tested
/// for every key in every phase. Used by whichever recording window is key
/// (the Setup overlay, the ink panel in draw mode); none of them map keys
/// themselves.
///
/// | Phase | Keys |
/// | ----- | ---- |
/// | Setup | R · S W · V P H A O B · F · ⌫ · 1–5 · [ ] · ⌘Z ⇧⌘Z · Esc/Q |
/// | Snapping | S W (same = back, other = switch) · Return/Enter (confirm) · Esc/Q |
/// | Countdown | Esc/Q (back to Setup) |
/// | Recording, draw mode | as Setup without R / S / W |
/// | Recording, Magic Pen | as draw mode, but [ ] step the Magic Pen thickness and F does nothing (it always fades) |
/// | Recording, interact mode · stopping · ended | nothing — every key belongs to the user's app (Q2/Q15) |
///
/// Single letters go through `ShortcutKeys.isBareKey` (Shift and Caps Lock
/// tolerated, compared lowercased), like every other single-key shortcut.
enum RecordingKeyMap {
    static func command(
        phase: RecordingPhase, keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> RecordingCommand? {
        switch phase {
        case .setup:
            command(keyCode: keyCode, characters: characters, modifiers: modifiers, layer: .setup)
        case .snapping(let kind, _, _):
            snapping(kind, keyCode: keyCode, characters: characters, modifiers: modifiers)
        case .countdown:
            command(keyCode: keyCode, characters: characters, modifiers: modifiers, layer: .countdown)
        case .recording(.draw):
            command(keyCode: keyCode, characters: characters, modifiers: modifiers, layer: .draw)
        case .recording(.magicPen):
            command(keyCode: keyCode, characters: characters, modifiers: modifiers, layer: .magicPen)
        case .recording(.interact), .stopping, .finished, .cancelled:
            nil
        }
    }

    /// Convenience for a `keyDown` handler. Read the event's fields here, not
    /// inside `MainActor.assumeIsolated` (NSEvent is non-Sendable).
    static func command(for event: NSEvent, phase: RecordingPhase) -> RecordingCommand? {
        command(
            phase: phase, keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags
        )
    }

    /// Snap mode (Q33), S and W alike: the same key again steps back (= Esc),
    /// the other one switches, Return / keypad Enter confirm the hovered pick
    /// (`.snap(kind)` with the current kind is the session's confirm, like a
    /// click). ↑ / ↓ are the part picker's (`WindowPartStep`), not commands.
    private static func snapping(
        _ kind: SnapKind, keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> RecordingCommand? {
        if [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(keyCode)) {
            // Enter carries `.numericPad` (and on some keyboards `.function`).
            let flags = modifiers.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            return flags.isEmpty ? .snap(kind) : nil
        }
        let command = command(keyCode: keyCode, characters: characters, modifiers: modifiers, layer: .snapping)
        if command == .snap(kind) { return .stepBack }
        return command
    }

    private enum Layer {
        case setup, snapping, countdown, draw, magicPen

        var hasStart: Bool { self == .setup }
        var hasSnap: Bool { self == .setup || self == .snapping }
        var hasInk: Bool { self == .setup || self == .draw || self == .magicPen }
    }

    private static func command(
        keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, layer: Layer
    ) -> RecordingCommand? {
        let key = characters?.lowercased()
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)

        // ⌘Z / ⇧⌘Z — the only modified keys in the table.
        if layer.hasInk, key == "z" {
            if flags == .command { return .ink(.undo) }
            if flags == [.command, .shift] { return .ink(.redo) }
        }
        guard ShortcutKeys.isBareKey(modifiers) else { return nil }

        if Int(keyCode) == kVK_Escape { return .stepBack }
        if layer.hasInk, Int(keyCode) == kVK_Delete { return .ink(.clear) }
        guard let key else { return nil }
        if key == "q" { return .stepBack }

        if layer.hasStart, key == "r" { return .record }
        if layer.hasSnap {
            if key == "s" { return .snap(.area) }
            if key == "w" { return .snap(.window) }
        }
        guard layer.hasInk else { return nil }

        switch key {
        case "v": return .pointer
        case "p": return .tool(.pen)
        case "h": return .tool(.highlighter)
        case "a": return .tool(.arrow)
        case "o": return .tool(.oval)
        case "b": return .tool(.box)
        // Magic Pen strokes always fade; [ ] are its own thickness there.
        case "f": return layer == .magicPen ? nil : .ink(.toggleFading)
        case "[": return .ink(layer == .magicPen ? .magicPenThinner : .thinner)
        case "]": return .ink(layer == .magicPen ? .magicPenThicker : .thicker)
        default:
            if let preset = InkColorPreset.allCases.first(where: { $0.key == key }) {
                return .ink(.color(preset))
            }
            return nil
        }
    }
}

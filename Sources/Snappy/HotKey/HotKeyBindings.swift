import AppKit
import Carbon.HIToolbox

// The four remappable hot keys as values, and the recorder rule — PURE,
// unit-tested (`HotKeyBindingsTests`). Their live side is `GlobalHotKeys`.

/// A shortcut a hot key recorder must not take: another of Snappy's own hot
/// keys (Carbon would route the keystroke to only one of the two bindings).
struct ReservedHotKey: Equatable {
    let combo: HotKeyCombo
    /// What it does, as the menu names it ("Capture Area").
    let name: String
}

/// Snappy's four remappable global hot keys (2026-10-20), each with its own
/// Settings recorder + Reset: Capture Area (⇧⌘4) and Capture Entire Screen
/// (⇧⌘3) — registered for the app's lifetime — and the session-only Draw Mode
/// (⌃⌥D) and Magic Pen (⌃⌥P). In-session single-letter keys stay fixed.
enum SnappyHotKey: CaseIterable, Equatable {
    case captureArea, captureFullscreen, drawMode, magicPen

    /// As the menu and the refusal message name it ("… is already Snappy’s
    /// Draw Mode shortcut").
    var name: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureFullscreen: "Capture Entire Screen"
        case .drawMode: "Draw Mode"
        case .magicPen: "Magic Pen"
        }
    }

    var defaultCombo: HotKeyCombo {
        switch self {
        case .captureArea: .defaultCapture
        case .captureFullscreen: .defaultFullscreen
        case .drawMode: .defaultDrawMode
        case .magicPen: .defaultMagicPen
        }
    }

    var action: HotKeyAction {
        switch self {
        case .captureArea: .captureArea
        case .captureFullscreen: .captureFullscreen
        case .drawMode: .toggleDrawMode
        case .magicPen: .toggleMagicPen
        }
    }

    /// Registered only while a recording session is active.
    var isSessionOnly: Bool { self == .drawMode || self == .magicPen }

    /// The recorder button's tooltip and VoiceOver label.
    var recorderToolTip: String { "Record a new \(name) shortcut (Space)" }
    var recorderAccessibilityLabel: String { "\(name) shortcut" }
    /// The Reset button's tooltip: the key is the one that presses the
    /// focused button, not the combo being restored (`<verb phrase> (KEY)`).
    var resetToolTip: String { "Reset the \(name) shortcut to \(defaultCombo.displayString) (Space)" }

    /// What this recorder refuses: every *other* Snappy hot key as configured.
    func reserved(in bindings: HotKeyBindings) -> [ReservedHotKey] {
        Self.allCases.filter { $0 != self }.map { ReservedHotKey(combo: bindings[$0], name: $0.name) }
    }
}

extension SnappyHotKey {
    /// Under the field while its stored combo isn't live — another app took
    /// it (at launch, or while a recorder had the hot keys paused). Leads
    /// with the approved refusal copy; names the hot key, since the two
    /// capture fields share one hint. Snappy retries when Settings opens or
    /// the app becomes active, and when the same combo is recorded again.
    var unboundMessage: String {
        "That shortcut is already taken — \(name) is off until it’s free or you choose another."
    }
}

/// The configured combo of each `SnappyHotKey` — PURE value, read from and
/// written to `SettingsStore`.
struct HotKeyBindings: Equatable {
    var captureArea: HotKeyCombo = .defaultCapture
    var captureFullscreen: HotKeyCombo = .defaultFullscreen
    var drawMode: HotKeyCombo = .defaultDrawMode
    var magicPen: HotKeyCombo = .defaultMagicPen

    static let defaults = HotKeyBindings()

    subscript(hotKey: SnappyHotKey) -> HotKeyCombo {
        get {
            switch hotKey {
            case .captureArea: captureArea
            case .captureFullscreen: captureFullscreen
            case .drawMode: drawMode
            case .magicPen: magicPen
            }
        }
        set {
            switch hotKey {
            case .captureArea: captureArea = newValue
            case .captureFullscreen: captureFullscreen = newValue
            case .drawMode: drawMode = newValue
            case .magicPen: magicPen = newValue
            }
        }
    }

    /// `combo` for `hotKey` is refused when another Snappy hot key holds it
    /// now (Carbon would route the keystroke to only one of the two). Its own
    /// current combo is never a clash.
    func conflict(for hotKey: SnappyHotKey, combo: HotKeyCombo) -> HotKeyRecorderInput.Rejection? {
        hotKey.reserved(in: self).first { $0.combo == combo }.map { .reserved($0) }
    }

    /// Reset to the default — refused (with the reason) when another hot key
    /// holds that default now, as for a typed clash.
    func resetRejection(for hotKey: SnappyHotKey) -> HotKeyRecorderInput.Rejection? {
        conflict(for: hotKey, combo: hotKey.defaultCombo)
    }
}

/// A shortcut recorder: one key press while recording → what happens. Esc
/// cancels; Tab leaves the field (and keeps moving focus); every other key
/// becomes the new combo or is rejected with a reason. One rule for all four
/// hot keys (Creator decision, 2026-10-20 — replaces the 2026-10-09 ⌃/⌥-only
/// rule for the session keys): at least one of ⌘, ⌃ or ⌥, so ⌘D / ⌘P may be
/// Draw Mode / Magic Pen.
enum HotKeyRecorderInput {
    enum Outcome: Equatable {
        case accept(HotKeyCombo)
        /// Esc — keep the current shortcut.
        case cancel
        /// Tab / ⇧Tab — stop recording, let the key move focus as usual.
        case leave
        case reject(Rejection)
    }

    enum Rejection: Equatable {
        /// None of ⌘, ⌃, ⌥ held (a bare key, or ⇧ alone).
        case needsModifier
        /// Not a letter or digit.
        case unsupportedKey
        case reserved(ReservedHotKey)
        /// `RegisterEventHotKey` refused it: macOS or another app owns the
        /// combo. The old shortcut stays.
        case unavailable(HotKeyCombo)

        /// Shown under the field in place of the hint, and announced.
        var message: String {
            switch self {
            case .needsModifier: "Include ⌘, ⌃ or ⌥ in the shortcut."
            case .unsupportedKey: "Use a letter or number key."
            case .reserved(let hotKey): "\(hotKey.combo.displayString) is already Snappy’s \(hotKey.name) shortcut."
            // Approved copy, verbatim (Creator decision, 2026-10-20).
            case .unavailable: "That shortcut is already taken"
            }
        }
    }

    private static let escapeKeyCode = UInt16(kVK_Escape)
    private static let tabKeyCode = UInt16(kVK_Tab)

    static func outcome(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        reserved: [ReservedHotKey]
    ) -> Outcome {
        let modifiers = carbonModifiers(from: flags)
        if keyCode == escapeKeyCode { return .cancel }
        if keyCode == tabKeyCode, modifiers & ~UInt32(shiftKey) == 0 { return .leave }
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else { return .reject(.needsModifier) }
        let combo = HotKeyCombo(keyCode: UInt32(keyCode), carbonModifiers: modifiers)
        guard combo.hasKeyName else { return .reject(.unsupportedKey) }
        if let taken = reserved.first(where: { $0.combo == combo }) { return .reject(.reserved(taken)) }
        return .accept(combo)
    }

    /// The four shortcut modifiers as a Carbon mask; Caps Lock, Fn and the
    /// numeric-pad flag are ignored.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// The field's title while recording: the modifiers held so far ("⌃⌥…"),
    /// or a prompt before any is pressed.
    static func pendingTitle(flags: NSEvent.ModifierFlags) -> String {
        let modifiers = carbonModifiers(from: flags)
        guard modifiers != 0 else { return "Type Shortcut" }
        return HotKeyCombo.modifierSymbols(modifiers) + "…"
    }
}

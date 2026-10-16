import AppKit
import Carbon.HIToolbox

// PURE helpers for the settings window — unit-tested.

extension HotKeyCombo {
    /// Menu-style shortcut text, e.g. "⇧⌘4": modifiers in Apple's order
    /// (⌃⌥⇧⌘), then the key. Covers the letter and digit keys a screenshot
    /// shortcut uses; anything else falls back to its key code.
    var displayString: String {
        Self.modifierSymbols(carbonModifiers) + (Self.keyNames[Int(keyCode)] ?? "Key \(keyCode)")
    }

    /// "⌃⌥⇧⌘" for the modifiers set in a Carbon mask, in Apple's order.
    static func modifierSymbols(_ carbonModifiers: UInt32) -> String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
    ]
}

/// Standard ⌘-shortcuts the settings window handles itself. Snappy has no
/// main menu (`LSUIElement`), and AppKit routes ⌘W and the text-editing
/// shortcuts through the menu bar — without this, ⌘W wouldn't close the window
/// and ⌘V wouldn't paste into the padding field (HIG Keyboards).
enum SettingsKeyCommand: Equatable {
    case close
    case cut
    case copy
    case paste
    case selectAll

    /// Only plain ⌘+key (Caps Lock ignored, like `ShortcutKeys.isBareKey`).
    init?(charactersIgnoringModifiers characters: String, flags: NSEvent.ModifierFlags) {
        let modifiers = flags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard modifiers == .command else { return nil }
        switch characters.lowercased() {
        case "w": self = .close
        case "x": self = .cut
        case "c": self = .copy
        case "v": self = .paste
        case "a": self = .selectAll
        default: return nil
        }
    }
}

/// The save-folder path control accepts drops and Choose…; only an existing
/// local directory may become the save folder (a dropped PNG would otherwise
/// be persisted and make every Save fail).
enum SaveFolderValidation {
    static func isUsableFolder(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// The canvas-padding field: typed text → stored points.
enum CanvasPaddingInput {
    static let range = 0...100

    /// Whole points, clamped to `range`; anything that isn't a number keeps
    /// `current` (the field then snaps back to it).
    static func value(from text: String, current: Int) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "pt", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let number = Double(trimmed), number.isFinite else { return current }
        // Clamp while still a Double: `Int(_:)` traps on values it can't
        // represent, and "1e100" is finite.
        let clamped = min(Double(range.upperBound), max(Double(range.lowerBound), number.rounded()))
        return Int(clamped)
    }
}

// MARK: - Settings → Recording (features/recording.md)

extension HotKeyCombo {
    /// True when `displayString` can name the key (A–Z, 0–9). The draw-mode
    /// recorder only takes those: "⌃⌥Key 122" would be unreadable, and HIG
    /// Keyboards advises non-⌘ modifiers "only with the alphabetic characters".
    var hasKeyName: Bool { Self.keyNames[Int(keyCode)] != nil }
}

/// Menu titles of the recording pop-ups and the fade-delay value.
enum RecordingSettingsText {
    static func seconds(_ count: Int) -> String {
        count == 1 ? "1 second" : "\(count) seconds"
    }

    static func countdown(_ countdown: RecordingCountdown) -> String {
        countdown == .off ? "Off" : seconds(countdown.seconds)
    }

    static func frameRate(_ rate: RecordingFrameRate) -> String {
        "\(rate.framesPerSecond) fps"
    }

    static func quality(_ quality: RecordingQuality) -> String {
        switch quality {
        case .standard: "Standard"
        case .high: "High"
        }
    }
}

/// A shortcut a recording hot key must not take: Snappy's own global ones and
/// the other recording hot key (Carbon would route the keystroke to only one
/// of the two bindings).
struct ReservedHotKey: Equatable {
    let combo: HotKeyCombo
    /// What it does, as the menu names it ("Capture Area").
    let name: String

    /// ⇧⌘4 / ⇧⌘3 as currently configured.
    static func snappyGlobal(capture: HotKeyCombo, fullscreen: HotKeyCombo) -> [ReservedHotKey] {
        [
            ReservedHotKey(combo: capture, name: "Capture Area"),
            ReservedHotKey(combo: fullscreen, name: "Capture Entire Screen"),
        ]
    }
}

/// The two session-only recording hot keys, each with its own Settings →
/// Recording recorder: Draw Mode (⌃⌥D) and Magic Pen (⌃⌥P). Same rules for
/// both (`HotKeyRecorderInput`); each refuses Snappy's global hot keys and
/// the other one.
enum RecordingHotKey: CaseIterable, Equatable {
    case drawMode, magicPen

    /// As the refusal message names it ("… is already Snappy’s Draw Mode shortcut").
    var name: String {
        switch self {
        case .drawMode: "Draw Mode"
        case .magicPen: "Magic Pen"
        }
    }

    var defaultCombo: HotKeyCombo {
        switch self {
        case .drawMode: .defaultDrawMode
        case .magicPen: .defaultMagicPen
        }
    }

    /// The recorder button's tooltip and VoiceOver label.
    var recorderToolTip: String { "Record a new \(name) shortcut (Space)" }
    var recorderAccessibilityLabel: String { "\(name) shortcut" }
    /// The Reset button's tooltip: the key is the one that presses the
    /// focused button, not the combo being restored (`<verb phrase> (KEY)`).
    var resetToolTip: String { "Reset the \(name) shortcut to \(defaultCombo.displayString) (Space)" }

    /// What this recorder refuses: ⇧⌘4 / ⇧⌘3 as configured, and the other
    /// recording hot key's current combo.
    func reserved(
        capture: HotKeyCombo, fullscreen: HotKeyCombo, drawMode: HotKeyCombo, magicPen: HotKeyCombo
    ) -> [ReservedHotKey] {
        let other: ReservedHotKey = switch self {
        case .drawMode: ReservedHotKey(combo: magicPen, name: RecordingHotKey.magicPen.name)
        case .magicPen: ReservedHotKey(combo: drawMode, name: RecordingHotKey.drawMode.name)
        }
        return ReservedHotKey.snappyGlobal(capture: capture, fullscreen: fullscreen) + [other]
    }
}

/// A recording shortcut recorder (draw mode, Magic Pen): one key press while
/// recording → what happens. Esc cancels; Tab leaves the field (and keeps moving focus); every
/// other key becomes the new combo or is rejected with a reason.
///
/// The combo must hold ⌃ or ⌥ (Design decision, 2026-10-09): Carbon swallows
/// it system-wide for the whole session, so a ⌘ shortcut like ⌘C would stop
/// copy/paste working in the app being recorded.
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
        /// No modifier but ⇧ held.
        case needsModifier
        /// ⌘ (or ⇧⌘) without ⌃ or ⌥ — that belongs to the user's apps.
        case commandOnly
        /// Not a letter or digit.
        case unsupportedKey
        case reserved(ReservedHotKey)

        /// Shown under the field in place of the hint, and announced.
        var message: String {
            switch self {
            case .needsModifier: "Include ⌃ or ⌥ in the shortcut."
            case .commandOnly: "Include ⌃ or ⌥ — ⌘ shortcuts belong to your apps."
            case .unsupportedKey: "Use a letter or number key."
            case .reserved(let hotKey): "\(hotKey.combo.displayString) is already Snappy’s \(hotKey.name) shortcut."
            }
        }
    }

    private static let escapeKeyCode = UInt16(kVK_Escape)
    private static let tabKeyCode = UInt16(kVK_Tab)

    static func outcome(keyCode: UInt16, flags: NSEvent.ModifierFlags, reserved: [ReservedHotKey]) -> Outcome {
        let modifiers = carbonModifiers(from: flags)
        if keyCode == escapeKeyCode { return .cancel }
        if keyCode == tabKeyCode, modifiers & ~UInt32(shiftKey) == 0 { return .leave }
        guard modifiers & UInt32(controlKey | optionKey) != 0 else {
            return .reject(modifiers & UInt32(cmdKey) != 0 ? .commandOnly : .needsModifier)
        }
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

/// Settings window sizing (Design decision, T6 review round 1): the pane at its
/// natural size whenever it fits the screen's visible frame — nothing changes
/// then — otherwise clamped to that height with the content scrolling.
enum SettingsPaneFit {
    struct Fit: Equatable {
        var contentSize: CGSize
        var scrolls: Bool
    }

    /// Floor for absurdly small visible frames; the pane then scrolls.
    static let minimumContentHeight: CGFloat = 200

    /// `chromeHeight` = title bar (window frame minus content), `scrollerWidth`
    /// = what a legacy (always-visible) scroller takes from the width; 0 for
    /// overlay scrollers.
    static func fit(
        content: CGSize, visibleHeight: CGFloat, chromeHeight: CGFloat, scrollerWidth: CGFloat
    ) -> Fit {
        let available = max(minimumContentHeight, (visibleHeight - chromeHeight).rounded(.down))
        guard content.height > available else { return Fit(contentSize: content, scrolls: false) }
        return Fit(contentSize: CGSize(width: content.width + scrollerWidth, height: available), scrolls: true)
    }

    /// The window's frame after a refit: `size`, keeping `current`'s top-left
    /// corner, then `placed` inside `visible`. Applied on every refit, also
    /// while the window is closed (review round 2): a reopen after the Dock or
    /// resolution changed would otherwise keep the saved top edge and leave
    /// the clamped window's bottom under the Dock.
    static func windowFrame(size: CGSize, keepingTopOf current: CGRect, in visible: CGRect) -> CGRect {
        let resized = CGRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
        return placed(resized, in: visible)
    }

    /// `frame` moved (never resized) so it lies inside `visible` vertically:
    /// keeps its top edge if it can, else slides up from the Dock, and the top
    /// wins when it's taller than `visible`. Horizontal position is left alone.
    static func placed(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var placed = frame
        if placed.minY < visible.minY { placed.origin.y = visible.minY }
        if placed.maxY > visible.maxY { placed.origin.y = visible.maxY - placed.height }
        return placed
    }
}

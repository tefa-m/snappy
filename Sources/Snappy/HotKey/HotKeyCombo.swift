import Carbon.HIToolbox
import Foundation

/// A global hot key combination: virtual key code + Carbon modifier mask.
/// Stored in UserDefaults; the user can remap it in Settings.
struct HotKeyCombo: Equatable {
    /// Virtual key code (`kVK_*`).
    let keyCode: UInt32
    /// Carbon modifier mask (`cmdKey | shiftKey | optionKey | controlKey`).
    let carbonModifiers: UInt32

    /// ⇧⌘4 — deliberately the same combo as the system screenshot shortcut it
    /// replaces (the system one must be disabled in System Settings).
    static let defaultCapture = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_4),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    /// ⇧⌘3 — like ⇧⌘4, deliberately the same combo as the system screenshot
    /// shortcut it replaces (the system one must be disabled in System Settings).
    static let defaultFullscreen = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_3),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    // MARK: - UserDefaults representation

    private enum Field {
        static let keyCode = "keyCode"
        static let modifiers = "modifiers"
    }

    var userDefaultsRepresentation: [String: Int] {
        [Field.keyCode: Int(keyCode), Field.modifiers: Int(carbonModifiers)]
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(userDefaultsRepresentation dict: [String: Int]) {
        guard
            let keyCode = dict[Field.keyCode],
            let modifiers = dict[Field.modifiers],
            let code = UInt32(exactly: keyCode),
            let mods = UInt32(exactly: modifiers)
        else { return nil }
        self.init(keyCode: code, carbonModifiers: mods)
    }
}

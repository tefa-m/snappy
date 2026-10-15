import AppKit

/// Pure modifier-flag logic for keyboard shortcuts.
enum ShortcutKeys {
    /// True when the event carries no "real" modifiers — i.e. a single-letter
    /// shortcut should fire. Shift is tolerated (character compares are done
    /// lowercased) and Caps Lock is ignored: it is a latched state that stays
    /// in `modifierFlags` while enabled and must never disable shortcuts.
    static func isBareKey(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.shift, .capsLock])
            .isEmpty
    }
}

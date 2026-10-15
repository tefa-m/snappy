import AppKit

/// Pure key handling shared by both capture overlays — unit-tested.
enum OverlayKeys {
    /// Esc, or a bare Q (standing rule: "Q or Esc closes any transient
    /// window"). Q is matched by character so it follows the keyboard layout,
    /// and only without ⌘/⌥/⌃ — Shift and Caps Lock are tolerated
    /// (`ShortcutKeys.isBareKey`).
    static func isCancel(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        if keyCode == 53 { return true } // Esc
        return characters?.lowercased() == "q" && ShortcutKeys.isBareKey(flags)
    }
}

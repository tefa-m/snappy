import Carbon.HIToolbox
import Foundation
import Synchronization

/// What a key reads as on the keyboard in use. A `HotKeyCombo` stores the
/// **virtual key code** — the physical key, which is what Carbon binds — but
/// its label must follow the current layout: on French AZERTY the key at
/// `kVK_ANSI_Q` is labelled A. The legend comes from the selected input
/// source's layout (`UCKeyTranslate`), cached until the layout changes
/// (`invalidate`, on `kTISNotifySelectedKeyboardInputSourceChanged`); keys or
/// layouts that yield no ASCII letter or digit fall back to the US names
/// (`usName`, PURE — as macOS does for ⌘-shortcuts on non-Latin layouts).
///
/// The Text Input Sources API aborts off the main thread, so only the main
/// thread (all of Snappy's UI) reads the layout; elsewhere a label not yet
/// cached is the US one.
enum KeyLegend {
    /// The key's label: the current layout's, else the US one; nil for a key
    /// that is neither a letter nor a digit.
    static func name(for keyCode: UInt32) -> String? {
        if let cached = cache.withLock({ $0[keyCode] }) { return cached }
        guard Thread.isMainThread else { return usName(for: keyCode) }
        let name = layoutName(for: keyCode) ?? usName(for: keyCode)
        cache.withLock { $0[keyCode] = .some(name) }
        return name
    }

    /// Forget cached labels — the keyboard layout changed.
    static func invalidate() {
        cache.withLock { $0.removeAll() }
    }

    /// US ANSI names of the letter and digit keys — PURE, the fallback.
    static func usName(for keyCode: UInt32) -> String? {
        usNames[Int(keyCode)]
    }

    /// A typed character as a key label: an ASCII letter (uppercased) or
    /// digit; nil otherwise ("é", "&", dead keys, several characters) —
    /// PURE. AZERTY's digit row types "&é\"'" unshifted, so `layoutName`
    /// asks for the shifted character too.
    static func legend(fromTyped characters: String) -> String? {
        guard characters.count == 1, let character = characters.first, character.isASCII,
              character.isLetter || character.isNumber
        else { return nil }
        return characters.uppercased()
    }

    // MARK: - Private

    /// `.some(nil)` caches "no name" too.
    private static let cache = Mutex<[UInt32: String?]>([:])

    private static func layoutName(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            // Unshifted first, then shifted (AZERTY digits).
            for modifiers in [0, UInt32(shiftKey >> 8) & 0xFF] {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), modifiers,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, characters.count, &length, &characters
                )
                guard status == noErr, length > 0 else { continue }
                if let legend = legend(fromTyped: String(utf16CodeUnits: characters, count: length)) {
                    return legend
                }
            }
            return nil
        }
    }

    private static let usNames: [Int: String] = [
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

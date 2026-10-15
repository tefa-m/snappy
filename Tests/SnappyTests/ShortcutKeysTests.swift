import AppKit
import Testing

@testable import Snappy

@Suite("ShortcutKeys")
struct ShortcutKeysTests {
    @Test("Bare and Shift/Caps Lock-only flags count as bare keys")
    func bareCombinations() {
        #expect(ShortcutKeys.isBareKey([]))
        #expect(ShortcutKeys.isBareKey([.capsLock]))
        #expect(ShortcutKeys.isBareKey([.shift]))
        #expect(ShortcutKeys.isBareKey([.shift, .capsLock]))
    }

    @Test("Real modifiers disqualify a bare key")
    func realModifiers() {
        #expect(!ShortcutKeys.isBareKey([.command]))
        #expect(!ShortcutKeys.isBareKey([.control]))
        #expect(!ShortcutKeys.isBareKey([.option]))
        #expect(!ShortcutKeys.isBareKey([.command, .capsLock]))
    }

    @Test("Device-dependent bits are masked out before the check")
    func deviceDependentBitsIgnored() {
        // Raw hardware bits (e.g. left/right Shift distinction) outside the
        // device-independent mask must not affect the result.
        let rawHardwareBit = NSEvent.ModifierFlags(rawValue: 1 << 1)
        #expect(ShortcutKeys.isBareKey(rawHardwareBit.union(.capsLock)))
    }
}

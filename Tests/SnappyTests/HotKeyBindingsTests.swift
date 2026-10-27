import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import Snappy

/// The hot key values and the recorder rule (`HotKey/HotKeyBindings.swift`).
@Suite("Hot key bindings")
struct HotKeyBindingsTests {
    private static let snappyKeys = [
        ReservedHotKey(combo: .defaultCapture, name: "Capture Area"),
        ReservedHotKey(combo: .defaultFullscreen, name: "Capture Entire Screen"),
    ]

    private static func outcome(
        _ keyCode: Int,
        _ flags: NSEvent.ModifierFlags,
        reserved: [ReservedHotKey] = snappyKeys
    ) -> HotKeyRecorderInput.Outcome {
        HotKeyRecorderInput.outcome(keyCode: UInt16(keyCode), flags: flags, reserved: reserved)
    }

    @Test("Recorder accepts a letter or digit with ⌃ or ⌥ — ⇧ and ⌘ only on top")
    func recorderAccepts() {
        let d = UInt32(kVK_ANSI_D)
        #expect(Self.outcome(kVK_ANSI_D, [.control, .option])
            == .accept(HotKeyCombo(keyCode: d, carbonModifiers: UInt32(controlKey | optionKey))))
        #expect(Self.outcome(kVK_ANSI_D, .control) == .accept(HotKeyCombo(keyCode: d, carbonModifiers: UInt32(controlKey))))
        #expect(Self.outcome(kVK_ANSI_D, .option) == .accept(HotKeyCombo(keyCode: d, carbonModifiers: UInt32(optionKey))))
        #expect(Self.outcome(kVK_ANSI_D, [.option, .command])
            == .accept(HotKeyCombo(keyCode: d, carbonModifiers: UInt32(optionKey | cmdKey))))
        #expect(Self.outcome(kVK_ANSI_D, [.shift, .control])
            == .accept(HotKeyCombo(keyCode: d, carbonModifiers: UInt32(shiftKey | controlKey))))
        #expect(Self.outcome(kVK_ANSI_5, [.control, .shift, .option, .command])
            == .accept(HotKeyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(controlKey | shiftKey | optionKey | cmdKey))))
        // Caps Lock, Fn and the numeric-pad flag never become modifiers.
        #expect(Self.outcome(kVK_ANSI_D, [.control, .option, .capsLock, .function, .numericPad])
            == .accept(.defaultDrawMode))
    }

    @Test("Recorder rejects bare and ⇧-only keys, unnamed keys, and Snappy's own hot keys")
    func recorderRejects() {
        #expect(Self.outcome(kVK_ANSI_D, []) == .reject(.needsModifier))
        #expect(Self.outcome(kVK_ANSI_D, .shift) == .reject(.needsModifier))
        #expect(Self.outcome(kVK_ANSI_D, .capsLock) == .reject(.needsModifier))
        #expect(Self.outcome(kVK_Space, []) == .reject(.needsModifier))
        #expect(Self.outcome(kVK_F5, .option) == .reject(.unsupportedKey))
        #expect(Self.outcome(kVK_F5, .command) == .reject(.unsupportedKey))
        #expect(Self.outcome(kVK_LeftArrow, [.control, .function]) == .reject(.unsupportedKey))
        #expect(Self.outcome(kVK_ANSI_Slash, .option) == .reject(.unsupportedKey))
        // Snappy's own are refused by name.
        #expect(Self.outcome(kVK_ANSI_4, [.shift, .command]) == .reject(.reserved(Self.snappyKeys[0])))
        #expect(Self.outcome(kVK_ANSI_3, [.shift, .command]) == .reject(.reserved(Self.snappyKeys[1])))
        // Only the exact combo is taken: ⌃⇧⌘4 is free.
        #expect(Self.outcome(kVK_ANSI_4, [.control, .shift, .command])
            == .accept(HotKeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(controlKey | shiftKey | cmdKey))))
    }

    /// Creator decision 2026-10-20: one rule for all four — ⌘ alone counts,
    /// so ⌘D / ⌘P may be Draw Mode / Magic Pen (the ⌃/⌥-only rule is gone).
    @Test("⌘ and ⇧⌘ shortcuts are accepted for every hot key")
    func recorderAcceptsCommandOnly() {
        for key in [kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_P, kVK_ANSI_W, kVK_ANSI_7] {
            let code = UInt32(key)
            #expect(Self.outcome(key, .command) == .accept(HotKeyCombo(keyCode: code, carbonModifiers: UInt32(cmdKey))))
            #expect(Self.outcome(key, [.shift, .command])
                == .accept(HotKeyCombo(keyCode: code, carbonModifiers: UInt32(shiftKey | cmdKey))))
            #expect(Self.outcome(key, [.command, .capsLock])
                == .accept(HotKeyCombo(keyCode: code, carbonModifiers: UInt32(cmdKey))))
        }
    }

    @Test("Reserved hot keys follow the configured capture shortcuts")
    func recorderReservedFollowsSettings() {
        let custom = HotKeyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(controlKey | optionKey))
        var bindings = HotKeyBindings.defaults
        bindings.captureArea = custom
        let reserved = SnappyHotKey.drawMode.reserved(in: bindings)
        #expect(Self.outcome(kVK_ANSI_X, [.control, .option], reserved: reserved) == .reject(.reserved(reserved[0])))
        let fullscreen = HotKeyCombo(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(controlKey | shiftKey))
        bindings.captureFullscreen = fullscreen
        let both = SnappyHotKey.drawMode.reserved(in: bindings)
        #expect(Self.outcome(kVK_ANSI_3, [.control, .shift], reserved: both) == .reject(.reserved(both[1])))
        #expect(Self.outcome(kVK_ANSI_3, [.control, .shift], reserved: reserved)
            == .accept(fullscreen))
    }

    @Test("Each recording recorder refuses Snappy's global hot keys and the other recording hot key")
    func recordingHotKeysReserveEachOther() {
        let draw = HotKeyCombo.defaultDrawMode, magic = HotKeyCombo.defaultMagicPen
        let forDraw = SnappyHotKey.drawMode.reserved(in: .defaults)
        let forMagic = SnappyHotKey.magicPen.reserved(in: .defaults)
        #expect(forDraw == Self.snappyKeys + [ReservedHotKey(combo: magic, name: "Magic Pen")])
        #expect(forMagic == Self.snappyKeys + [ReservedHotKey(combo: draw, name: "Draw Mode")])
        #expect(Self.outcome(kVK_ANSI_P, [.control, .option], reserved: forDraw) == .reject(.reserved(forDraw[2])))
        #expect(Self.outcome(kVK_ANSI_D, [.control, .option], reserved: forMagic) == .reject(.reserved(forMagic[2])))
        #expect(Self.outcome(kVK_ANSI_P, [.control, .option], reserved: forMagic) == .accept(magic))
        #expect(HotKeyRecorderInput.Rejection.reserved(forDraw[2]).message
            == "⌃⌥P is already Snappy’s Magic Pen shortcut.")
        // ⌘P is a valid Magic Pen combo.
        #expect(Self.outcome(kVK_ANSI_P, .command, reserved: forMagic)
            == .accept(HotKeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(cmdKey))))
    }

    @Test("Shortcut recorders: names, defaults, actions, rules and HIG tooltips")
    func snappyHotKeyNames() {
        #expect(SnappyHotKey.allCases.map(\.name) == ["Capture Area", "Capture Entire Screen", "Draw Mode", "Magic Pen"])
        #expect(SnappyHotKey.allCases.map(\.defaultCombo)
            == [.defaultCapture, .defaultFullscreen, .defaultDrawMode, .defaultMagicPen])
        #expect(SnappyHotKey.allCases.map(\.action)
            == [.captureArea, .captureFullscreen, .toggleDrawMode, .toggleMagicPen])
        #expect(SnappyHotKey.allCases.filter(\.isSessionOnly) == [.drawMode, .magicPen])
        #expect(SnappyHotKey.captureArea.unboundMessage
            == "That shortcut is already taken — Capture Area is off until it’s free or you choose another.")
        #expect(SnappyHotKey.magicPen.recorderToolTip == "Record a new Magic Pen shortcut (Space)")
        #expect(SnappyHotKey.magicPen.resetToolTip == "Reset the Magic Pen shortcut to ⌃⌥P (Space)")
        #expect(SnappyHotKey.drawMode.resetToolTip == "Reset the Draw Mode shortcut to ⌃⌥D (Space)")
        #expect(SnappyHotKey.captureArea.resetToolTip == "Reset the Capture Area shortcut to ⇧⌘4 (Space)")
        #expect(SnappyHotKey.drawMode.recorderAccessibilityLabel == "Draw Mode shortcut")
        #expect(SnappyHotKey.captureFullscreen.recorderAccessibilityLabel == "Capture Entire Screen shortcut")
    }

    @Test("Capture recorders take ⌘, ⌃ or ⌥ (⇧ only on top) and refuse the other Snappy hot keys")
    func captureRecorderRule() {
        let five = UInt32(kVK_ANSI_5)
        #expect(Self.outcome(kVK_ANSI_5, [.shift, .command], reserved: [])
            == .accept(HotKeyCombo(keyCode: five, carbonModifiers: UInt32(shiftKey | cmdKey))))
        #expect(Self.outcome(kVK_ANSI_5, .command, reserved: [])
            == .accept(HotKeyCombo(keyCode: five, carbonModifiers: UInt32(cmdKey))))
        #expect(Self.outcome(kVK_ANSI_5, .option, reserved: [])
            == .accept(HotKeyCombo(keyCode: five, carbonModifiers: UInt32(optionKey))))
        #expect(Self.outcome(kVK_ANSI_5, .control, reserved: [])
            == .accept(HotKeyCombo(keyCode: five, carbonModifiers: UInt32(controlKey))))
        #expect(Self.outcome(kVK_ANSI_5, []) == .reject(.needsModifier))
        #expect(Self.outcome(kVK_ANSI_5, .shift) == .reject(.needsModifier))
        #expect(Self.outcome(kVK_F5, .command) == .reject(.unsupportedKey))
        #expect(Self.outcome(kVK_Escape, .command) == .cancel)
        // Capture Entire Screen may not take Capture Area's ⇧⌘4, nor Draw Mode's ⌃⌥D.
        let forScreen = SnappyHotKey.captureFullscreen.reserved(in: .defaults)
        #expect(forScreen.map(\.name) == ["Capture Area", "Draw Mode", "Magic Pen"])
        #expect(Self.outcome(kVK_ANSI_4, [.shift, .command], reserved: forScreen)
            == .reject(.reserved(forScreen[0])))
        #expect(Self.outcome(kVK_ANSI_D, [.control, .option], reserved: forScreen)
            == .reject(.reserved(forScreen[1])))
        // Its own current combo is no clash.
        #expect(Self.outcome(kVK_ANSI_3, [.shift, .command], reserved: forScreen)
            == .accept(.defaultFullscreen))
    }

    @Test("Bindings: subscript per hot key, clashes with another hot key, reset refused when taken")
    func hotKeyBindings() {
        var bindings = HotKeyBindings.defaults
        for hotKey in SnappyHotKey.allCases { #expect(bindings[hotKey] == hotKey.defaultCombo) }
        let x = HotKeyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(controlKey | optionKey))
        bindings[.magicPen] = x
        #expect(bindings.magicPen == x)
        #expect(bindings[.drawMode] == .defaultDrawMode)
        #expect(bindings.conflict(for: .magicPen, combo: x) == nil, "its own combo")
        #expect(bindings.conflict(for: .captureArea, combo: x)
            == .reserved(ReservedHotKey(combo: x, name: "Magic Pen")))
        #expect(bindings.conflict(for: .captureArea, combo: .defaultFullscreen)
            == .reserved(ReservedHotKey(combo: .defaultFullscreen, name: "Capture Entire Screen")))
        #expect(bindings.conflict(for: .captureArea, combo: .defaultMagicPen) == nil, "⌃⌥P is free now")
        // Draw Mode takes ⌃⌥P: Magic Pen's Reset is refused, naming Draw Mode.
        bindings[.drawMode] = .defaultMagicPen
        #expect(bindings.resetRejection(for: .magicPen)
            == .reserved(ReservedHotKey(combo: .defaultMagicPen, name: "Draw Mode")))
        #expect(bindings.resetRejection(for: .drawMode) == nil)
        #expect(HotKeyBindings.defaults.resetRejection(for: .captureArea) == nil)
    }

    @Test("Esc cancels with any modifiers; Tab and ⇧Tab leave; ⌃Tab is just an unnamed key")
    func recorderEscapeAndTab() {
        #expect(Self.outcome(kVK_Escape, []) == .cancel)
        #expect(Self.outcome(kVK_Escape, [.command, .option]) == .cancel)
        #expect(Self.outcome(kVK_Tab, []) == .leave)
        #expect(Self.outcome(kVK_Tab, .shift) == .leave)
        #expect(Self.outcome(kVK_Tab, .control) == .reject(.unsupportedKey))
    }

    @Test("Rejection messages name the fix, and the taken shortcut by its menu name")
    func recorderMessages() {
        #expect(HotKeyRecorderInput.Rejection.needsModifier.message == "Include ⌘, ⌃ or ⌥ in the shortcut.")
        // Approved copy, verbatim (Creator decision 2026-10-20).
        #expect(HotKeyRecorderInput.Rejection.unavailable(.defaultCapture).message == "That shortcut is already taken")
        #expect(HotKeyRecorderInput.Rejection.unsupportedKey.message == "Use a letter or number key.")
        #expect(HotKeyRecorderInput.Rejection.reserved(Self.snappyKeys[0]).message
            == "⇧⌘4 is already Snappy’s Capture Area shortcut.")
        #expect(HotKeyRecorderInput.Rejection.reserved(Self.snappyKeys[1]).message
            == "⇧⌘3 is already Snappy’s Capture Entire Screen shortcut.")
    }

    @Test("While recording, the field shows the held modifiers in Apple's order")
    func recorderPendingTitle() {
        #expect(HotKeyRecorderInput.pendingTitle(flags: []) == "Type Shortcut")
        #expect(HotKeyRecorderInput.pendingTitle(flags: .capsLock) == "Type Shortcut")
        #expect(HotKeyRecorderInput.pendingTitle(flags: [.command, .control]) == "⌃⌘…")
        #expect(HotKeyRecorderInput.pendingTitle(flags: [.command, .shift, .option, .control]) == "⌃⌥⇧⌘…")
    }

    @Test("Carbon modifier mask from AppKit flags")
    func carbonModifierMask() {
        #expect(HotKeyRecorderInput.carbonModifiers(from: []) == 0)
        #expect(HotKeyRecorderInput.carbonModifiers(from: [.command, .shift])
            == UInt32(cmdKey | shiftKey))
        #expect(HotKeyRecorderInput.carbonModifiers(from: [.control, .option, .capsLock, .help])
            == UInt32(controlKey | optionKey))
    }
}

import AppKit
import Foundation
import Carbon.HIToolbox
import Testing

@testable import Snappy

@Suite("Settings formatting")
struct SettingsFormattingTests {
    @Test("Default hot keys display as ⇧⌘4 and ⇧⌘3")
    func defaultHotKeys() {
        #expect(HotKeyCombo.defaultCapture.displayString == "⇧⌘4")
        #expect(HotKeyCombo.defaultFullscreen.displayString == "⇧⌘3")
    }

    @Test("Modifiers follow Apple's ⌃⌥⇧⌘ order")
    func modifierOrder() {
        let all = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        #expect(HotKeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: all).displayString == "⌃⌥⇧⌘S")
        #expect(HotKeyCombo(keyCode: 0x7A, carbonModifiers: UInt32(cmdKey)).displayString == "⌘Key 122")
    }

    @Test("Only plain ⌘ + W/X/C/V/A map to settings-window commands")
    func keyCommands() {
        #expect(SettingsKeyCommand(charactersIgnoringModifiers: "w", flags: .command) == .close)
        #expect(SettingsKeyCommand(charactersIgnoringModifiers: "W", flags: [.command, .capsLock]) == .close)
        #expect(SettingsKeyCommand(charactersIgnoringModifiers: "v", flags: .command) == .paste)
        #expect(SettingsKeyCommand(charactersIgnoringModifiers: "a", flags: .command) == .selectAll)
        #expect(SettingsKeyCommand(charactersIgnoringModifiers: "w", flags: [.command, .shift]) == nil)
        #expect(SettingsKeyCommand(charactersIgnoringModifiers: "w", flags: []) == nil)
        #expect(SettingsKeyCommand(charactersIgnoringModifiers: "q", flags: .command) == nil)
    }

    @Test("Padding input: whole points, clamped, garbage keeps the current value")
    func paddingInput() {
        #expect(CanvasPaddingInput.value(from: "24", current: 16) == 24)
        #expect(CanvasPaddingInput.value(from: " 12 pt ", current: 16) == 12)
        #expect(CanvasPaddingInput.value(from: "7.6", current: 16) == 8)
        #expect(CanvasPaddingInput.value(from: "250", current: 16) == 100)
        #expect(CanvasPaddingInput.value(from: "-3", current: 16) == 0)
        #expect(CanvasPaddingInput.value(from: "abc", current: 16) == 16)
        #expect(CanvasPaddingInput.value(from: "", current: 16) == 16)
    }

    @Test("Padding input: finite values beyond Int never trap, non-finite keep the current value")
    func paddingInputExtremes() {
        #expect(CanvasPaddingInput.value(from: "1e100", current: 16) == 100)
        #expect(CanvasPaddingInput.value(from: "-1e100", current: 16) == 0)
        #expect(CanvasPaddingInput.value(from: "\(Double(Int.max))", current: 16) == 100)
        #expect(CanvasPaddingInput.value(from: String(repeating: "9", count: 40), current: 16) == 100)
        #expect(CanvasPaddingInput.value(from: "nan", current: 16) == 16)
        #expect(CanvasPaddingInput.value(from: "inf", current: 16) == 16)
        #expect(CanvasPaddingInput.value(from: "-infinity", current: 16) == 16)
    }

    @Test("Only an existing local directory is a usable save folder")
    func saveFolderValidation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "snappy-folder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "shot.png")
        try Data([0]).write(to: file)

        #expect(SaveFolderValidation.isUsableFolder(dir))
        #expect(!SaveFolderValidation.isUsableFolder(file))
        #expect(!SaveFolderValidation.isUsableFolder(dir.appending(path: "missing", directoryHint: .isDirectory)))
        #expect(!SaveFolderValidation.isUsableFolder(URL(string: "https://example.com/folder/")!))
    }

    // MARK: - Settings → Recording

    @Test("Recording pop-up titles and the fade-delay value")
    func recordingTitles() {
        #expect(RecordingCountdown.allCases.map(RecordingSettingsText.countdown)
            == ["Off", "1 second", "2 seconds", "3 seconds", "5 seconds"])
        #expect(RecordingFrameRate.allCases.map(RecordingSettingsText.frameRate) == ["30 fps", "60 fps"])
        #expect(RecordingQuality.allCases.map(RecordingSettingsText.quality) == ["Standard", "High"])
        #expect(RecordingSettingsText.seconds(1) == "1 second")
        #expect(RecordingSettingsText.seconds(10) == "10 seconds")
        #expect(InkColorPreset.allCases.map(\.title) == ["Red", "Yellow", "Green", "Blue", "White"])
        #expect(InkWidth.allCases.map(\.title) == ["Thin", "Medium", "Thick"])
    }

    @Test("Draw-mode default displays as ⌃⌥D, and only letters and digits have a key name")
    func drawModeDisplay() {
        #expect(HotKeyCombo.defaultDrawMode.displayString == "⌃⌥D")
        #expect(HotKeyCombo.defaultDrawMode.hasKeyName)
        #expect(HotKeyCombo(keyCode: UInt32(kVK_ANSI_7), carbonModifiers: UInt32(cmdKey)).hasKeyName)
        #expect(!HotKeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: UInt32(cmdKey)).hasKeyName)
        #expect(!HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey)).hasKeyName)
        #expect(HotKeyCombo.modifierSymbols(UInt32(cmdKey | controlKey)) == "⌃⌘")
        #expect(HotKeyCombo.modifierSymbols(0) == "")
    }

    private static let snappyKeys = [
        ReservedHotKey(combo: .defaultCapture, name: "Capture Area"),
        ReservedHotKey(combo: .defaultFullscreen, name: "Capture Entire Screen"),
    ]

    private static func outcome(
        _ keyCode: Int,
        _ flags: NSEvent.ModifierFlags,
        rule: HotKeyModifierRule = .controlOrOption,
        reserved: [ReservedHotKey] = snappyKeys
    ) -> HotKeyRecorderInput.Outcome {
        HotKeyRecorderInput.outcome(keyCode: UInt16(keyCode), flags: flags, rule: rule, reserved: reserved)
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
        #expect(Self.outcome(kVK_ANSI_D, []) == .reject(.needsModifier(.controlOrOption)))
        #expect(Self.outcome(kVK_ANSI_D, .shift) == .reject(.needsModifier(.controlOrOption)))
        #expect(Self.outcome(kVK_ANSI_D, .capsLock) == .reject(.needsModifier(.controlOrOption)))
        #expect(Self.outcome(kVK_Space, []) == .reject(.needsModifier(.controlOrOption)))
        #expect(Self.outcome(kVK_F5, .option) == .reject(.unsupportedKey))
        #expect(Self.outcome(kVK_LeftArrow, [.control, .function]) == .reject(.unsupportedKey))
        #expect(Self.outcome(kVK_ANSI_Slash, .option) == .reject(.unsupportedKey))
        // Snappy's own: refused by name when they hold ⌃ or ⌥ (customised), see
        // `recorderReservedFollowsSettings`; the ⇧⌘ defaults are refused as ⌘-only.
        #expect(Self.outcome(kVK_ANSI_4, [.shift, .command]) == .reject(.commandOnly))
        #expect(Self.outcome(kVK_ANSI_3, [.shift, .command]) == .reject(.commandOnly))
        // Only the exact combo is taken: ⌃⇧⌘4 is free.
        #expect(Self.outcome(kVK_ANSI_4, [.control, .shift, .command])
            == .accept(HotKeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(controlKey | shiftKey | cmdKey))))
    }

    @Test("⌘ and ⇧⌘ shortcuts without ⌃ or ⌥ are refused — they belong to the recorded app")
    func recorderRejectsCommandOnly() {
        for key in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_Z, kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_D, kVK_ANSI_7] {
            #expect(Self.outcome(key, .command) == .reject(.commandOnly))
            #expect(Self.outcome(key, [.shift, .command]) == .reject(.commandOnly))
            #expect(Self.outcome(key, [.command, .capsLock]) == .reject(.commandOnly))
        }
        // The modifier rule comes first, so ⇧⌘4 reads as "⌘ belongs to your apps" too.
        #expect(Self.outcome(kVK_ANSI_4, [.shift, .command]) == .reject(.commandOnly))
        #expect(Self.outcome(kVK_F5, .command) == .reject(.commandOnly))
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
        // ⌘-only Magic Pen combos are refused like draw-mode ones.
        #expect(Self.outcome(kVK_ANSI_P, .command, reserved: forMagic) == .reject(.commandOnly))
    }

    @Test("Shortcut recorders: names, defaults, actions, rules and HIG tooltips")
    func snappyHotKeyNames() {
        #expect(SnappyHotKey.allCases.map(\.name) == ["Capture Area", "Capture Entire Screen", "Draw Mode", "Magic Pen"])
        #expect(SnappyHotKey.allCases.map(\.defaultCombo)
            == [.defaultCapture, .defaultFullscreen, .defaultDrawMode, .defaultMagicPen])
        #expect(SnappyHotKey.allCases.map(\.action)
            == [.captureArea, .captureFullscreen, .toggleDrawMode, .toggleMagicPen])
        #expect(SnappyHotKey.allCases.filter(\.isSessionOnly) == [.drawMode, .magicPen])
        #expect(SnappyHotKey.captureArea.modifierRule == .commandControlOrOption)
        #expect(SnappyHotKey.captureFullscreen.modifierRule == .commandControlOrOption)
        #expect(SnappyHotKey.drawMode.modifierRule == .controlOrOption)
        #expect(SnappyHotKey.magicPen.modifierRule == .controlOrOption)
        #expect(SnappyHotKey.magicPen.recorderToolTip == "Record a new Magic Pen shortcut (Space)")
        #expect(SnappyHotKey.magicPen.resetToolTip == "Reset the Magic Pen shortcut to ⌃⌥P (Space)")
        #expect(SnappyHotKey.drawMode.resetToolTip == "Reset the Draw Mode shortcut to ⌃⌥D (Space)")
        #expect(SnappyHotKey.captureArea.resetToolTip == "Reset the Capture Area shortcut to ⇧⌘4 (Space)")
        #expect(SnappyHotKey.drawMode.recorderAccessibilityLabel == "Draw Mode shortcut")
        #expect(SnappyHotKey.captureFullscreen.recorderAccessibilityLabel == "Capture Entire Screen shortcut")
    }

    @Test("Capture recorders take ⌘, ⌃ or ⌥ (⇧ only on top) and refuse the other Snappy hot keys")
    func captureRecorderRule() {
        let rule = HotKeyModifierRule.commandControlOrOption
        let five = UInt32(kVK_ANSI_5)
        #expect(Self.outcome(kVK_ANSI_5, [.shift, .command], rule: rule, reserved: [])
            == .accept(HotKeyCombo(keyCode: five, carbonModifiers: UInt32(shiftKey | cmdKey))))
        #expect(Self.outcome(kVK_ANSI_5, .command, rule: rule, reserved: [])
            == .accept(HotKeyCombo(keyCode: five, carbonModifiers: UInt32(cmdKey))))
        #expect(Self.outcome(kVK_ANSI_5, .option, rule: rule, reserved: [])
            == .accept(HotKeyCombo(keyCode: five, carbonModifiers: UInt32(optionKey))))
        #expect(Self.outcome(kVK_ANSI_5, .control, rule: rule, reserved: [])
            == .accept(HotKeyCombo(keyCode: five, carbonModifiers: UInt32(controlKey))))
        #expect(Self.outcome(kVK_ANSI_5, [], rule: rule) == .reject(.needsModifier(rule)))
        #expect(Self.outcome(kVK_ANSI_5, .shift, rule: rule) == .reject(.needsModifier(rule)))
        #expect(Self.outcome(kVK_F5, .command, rule: rule) == .reject(.unsupportedKey))
        #expect(Self.outcome(kVK_Escape, .command, rule: rule) == .cancel)
        // Capture Entire Screen may not take Capture Area's ⇧⌘4, nor Draw Mode's ⌃⌥D.
        let forScreen = SnappyHotKey.captureFullscreen.reserved(in: .defaults)
        #expect(forScreen.map(\.name) == ["Capture Area", "Draw Mode", "Magic Pen"])
        #expect(Self.outcome(kVK_ANSI_4, [.shift, .command], rule: rule, reserved: forScreen)
            == .reject(.reserved(forScreen[0])))
        #expect(Self.outcome(kVK_ANSI_D, [.control, .option], rule: rule, reserved: forScreen)
            == .reject(.reserved(forScreen[1])))
        // Its own current combo is no clash.
        #expect(Self.outcome(kVK_ANSI_3, [.shift, .command], rule: rule, reserved: forScreen)
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

    @Test("Menu key equivalent: lowercased key and the combo's modifiers; none for an unnamed key")
    func menuKeyEquivalent() {
        #expect(HotKeyCombo.defaultCapture.menuKeyEquivalent.key == "4")
        #expect(HotKeyCombo.defaultCapture.menuKeyEquivalent.modifiers == [.command, .shift])
        #expect(HotKeyCombo.defaultDrawMode.menuKeyEquivalent.key == "d")
        #expect(HotKeyCombo.defaultDrawMode.menuKeyEquivalent.modifiers == [.control, .option])
        let f5 = HotKeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: UInt32(cmdKey))
        #expect(f5.menuKeyEquivalent.key == "")
        #expect(f5.menuKeyEquivalent.modifiers == [])
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
        #expect(HotKeyRecorderInput.Rejection.needsModifier(.controlOrOption).message
            == "Include ⌃ or ⌥ in the shortcut.")
        #expect(HotKeyRecorderInput.Rejection.needsModifier(.commandControlOrOption).message
            == "Include ⌘, ⌃ or ⌥ in the shortcut.")
        #expect(HotKeyRecorderInput.Rejection.unavailable(.defaultCapture).message
            == "⇧⌘4 is already taken by macOS or another app — choose another shortcut.")
        #expect(HotKeyRecorderInput.Rejection.commandOnly.message
            == "Include ⌃ or ⌥ — ⌘ shortcuts belong to your apps.")
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

    // MARK: - Pane fit (review round 1, #1)

    @Test("A pane that fits keeps its natural size and never scrolls")
    func paneFits() {
        let pane = CGSize(width: 460, height: 802)
        // 1470×956 MacBook Air: 919 pt visible under the menu bar, 28 pt title bar.
        #expect(SettingsPaneFit.fit(content: pane, visibleHeight: 919, chromeHeight: 28, scrollerWidth: 15)
            == .init(contentSize: pane, scrolls: false))
        // Exactly fitting is still a fit.
        #expect(SettingsPaneFit.fit(content: pane, visibleHeight: 830, chromeHeight: 28, scrollerWidth: 0)
            == .init(contentSize: pane, scrolls: false))
    }

    @Test("A pane taller than the visible frame is clamped and scrolls; a legacy scroller widens it")
    func paneScrolls() {
        let pane = CGSize(width: 460, height: 802)
        // 1280×800 with the menu bar and a bottom Dock: ~700 pt visible.
        #expect(SettingsPaneFit.fit(content: pane, visibleHeight: 700.5, chromeHeight: 28, scrollerWidth: 0)
            == .init(contentSize: CGSize(width: 460, height: 672), scrolls: true))
        #expect(SettingsPaneFit.fit(content: pane, visibleHeight: 700, chromeHeight: 28, scrollerWidth: 15)
            == .init(contentSize: CGSize(width: 475, height: 672), scrolls: true))
        // One point too tall already scrolls.
        #expect(SettingsPaneFit.fit(content: pane, visibleHeight: 829, chromeHeight: 28, scrollerWidth: 0).scrolls)
    }

    @Test("The clamp never goes below the minimum height")
    func paneMinimumHeight() {
        let fit = SettingsPaneFit.fit(
            content: CGSize(width: 460, height: 802), visibleHeight: 120, chromeHeight: 28, scrollerWidth: 0
        )
        #expect(fit == .init(contentSize: CGSize(width: 460, height: SettingsPaneFit.minimumContentHeight), scrolls: true))
        let small = CGSize(width: 300, height: 150)
        #expect(SettingsPaneFit.fit(content: small, visibleHeight: 120, chromeHeight: 28, scrollerWidth: 0)
            == .init(contentSize: small, scrolls: false))
    }

    @Test("Placement slides the window into the visible frame vertically, top edge first")
    func panePlacement() {
        let visible = CGRect(x: 0, y: 70, width: 1280, height: 700) // Dock below, menu bar above
        let inside = CGRect(x: 100, y: 200, width: 460, height: 400)
        #expect(SettingsPaneFit.placed(inside, in: visible) == inside)
        // Grown downwards past the Dock → slides up.
        #expect(SettingsPaneFit.placed(CGRect(x: 100, y: 20, width: 460, height: 700), in: visible)
            == CGRect(x: 100, y: 70, width: 460, height: 700))
        // Top above the visible frame → slides down; x untouched.
        #expect(SettingsPaneFit.placed(CGRect(x: -40, y: 500, width: 460, height: 400), in: visible)
            == CGRect(x: -40, y: 370, width: 460, height: 400))
        // Taller than the visible frame → the top (title bar) wins.
        #expect(SettingsPaneFit.placed(CGRect(x: 0, y: 0, width: 460, height: 900), in: visible).maxY == visible.maxY)
    }

    @Test("Refit keeps the top edge, then places — the closed → Dock change → reopen case lands inside")
    func paneRefitFrame() {
        // Review round 2: saved top 750, new visible frame y 70 / height 700, clamped height 700.
        let saved = CGRect(x: 300, y: 0, width: 453, height: 750)
        let visible = CGRect(x: 0, y: 70, width: 1280, height: 700)
        #expect(SettingsPaneFit.windowFrame(size: CGSize(width: 453, height: 700), keepingTopOf: saved, in: visible)
            == CGRect(x: 300, y: 70, width: 453, height: 700))
        // Fits with room to spare: top edge kept, nothing moves.
        let roomy = CGRect(x: 0, y: 0, width: 1470, height: 919)
        let shown = CGRect(x: 500, y: 100, width: 453, height: 784)
        #expect(SettingsPaneFit.windowFrame(size: shown.size, keepingTopOf: shown, in: roomy) == shown)
        // Grows downwards from a kept top edge past the visible bottom → slides up.
        #expect(SettingsPaneFit.windowFrame(
            size: CGSize(width: 453, height: 784), keepingTopOf: CGRect(x: 500, y: 300, width: 453, height: 300), in: roomy
        ) == CGRect(x: 500, y: 0, width: 453, height: 784))
    }
}

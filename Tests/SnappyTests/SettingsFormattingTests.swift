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

    @Test("Key legends: US fallback names, typed characters as labels, a non-US layout's legend")
    @MainActor
    func keyLegends() {
        #expect(KeyLegend.usName(for: UInt32(kVK_ANSI_Q)) == "Q")
        #expect(KeyLegend.usName(for: UInt32(kVK_ANSI_4)) == "4")
        #expect(KeyLegend.usName(for: UInt32(kVK_F1)) == nil)
        #expect(KeyLegend.usName(for: UInt32(kVK_ANSI_Semicolon)) == nil)
        #expect(KeyLegend.legend(fromTyped: "a") == "A")
        #expect(KeyLegend.legend(fromTyped: "4") == "4")
        #expect(KeyLegend.legend(fromTyped: "é") == nil, "AZERTY's unshifted 2 — the shifted digit is asked next")
        #expect(KeyLegend.legend(fromTyped: "&") == nil)
        #expect(KeyLegend.legend(fromTyped: "д") == nil, "non-Latin layouts fall back to US")
        #expect(KeyLegend.legend(fromTyped: "ab") == nil)
        #expect(KeyLegend.legend(fromTyped: "") == nil)
        // A stand-in AZERTY: the key at kVK_ANSI_Q is labelled A; the key
        // code — what Carbon binds — is unchanged.
        let azerty: (UInt32) -> String? = { $0 == UInt32(kVK_ANSI_Q) ? "A" : KeyLegend.usName(for: $0) }
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(cmdKey | shiftKey))
        #expect(combo.displayString(keyName: azerty) == "⇧⌘A")
        #expect(combo.displayString(keyName: KeyLegend.usName) == "⇧⌘Q")
        #expect(combo.menuKeyEquivalent(keyName: azerty).key == "a")
        #expect(combo.menuKeyEquivalent(keyName: azerty).modifiers == [.command, .shift])
        // Live: the current layout names every letter and digit key.
        for keyCode in [kVK_ANSI_A, kVK_ANSI_Q, kVK_ANSI_4, kVK_ANSI_0] {
            #expect(KeyLegend.name(for: UInt32(keyCode)) != nil)
        }
        KeyLegend.invalidate()
        #expect(KeyLegend.name(for: UInt32(kVK_ANSI_4)) == "4", "digits read as digits on every Latin layout")
        #expect(KeyLegend.name(for: UInt32(kVK_F1)) == nil)
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
        // Top above the visible frame → slides down.
        #expect(SettingsPaneFit.placed(CGRect(x: 100, y: 500, width: 460, height: 400), in: visible)
            == CGRect(x: 100, y: 370, width: 460, height: 400))
        // Taller than the visible frame → the top (title bar) wins.
        #expect(SettingsPaneFit.placed(CGRect(x: 0, y: 0, width: 460, height: 900), in: visible).maxY == visible.maxY)
    }

    @Test("Placement slides the window into the visible frame horizontally, left edge first")
    func panePlacementHorizontal() {
        let visible = CGRect(x: 0, y: 70, width: 1280, height: 700)
        // Off the left edge → slides right.
        #expect(SettingsPaneFit.placed(CGRect(x: -40, y: 200, width: 460, height: 400), in: visible)
            == CGRect(x: 0, y: 200, width: 460, height: 400))
        // Off the right edge (e.g. after a resolution drop) → slides left.
        #expect(SettingsPaneFit.placed(CGRect(x: 1100, y: 200, width: 460, height: 400), in: visible)
            == CGRect(x: 820, y: 200, width: 460, height: 400))
        // Wider than the visible frame → the left edge wins.
        #expect(SettingsPaneFit.placed(CGRect(x: 300, y: 200, width: 1500, height: 400), in: visible).minX == 0)
        // Both axes at once, on a secondary display left of the main one.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1050)
        #expect(SettingsPaneFit.placed(CGRect(x: -2000, y: 900, width: 460, height: 400), in: left)
            == CGRect(x: -1920, y: 650, width: 460, height: 400))
    }

    @Test("The visible frame comes from the screen the window overlaps most, else the fallback")
    func paneScreenChoice() {
        let main = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 70, width: 1440, height: 805))
        let side = (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        let fallback = CGRect(x: 0, y: 1, width: 2, height: 3)
        // Mostly on the side display.
        #expect(SettingsPaneFit.visibleFrame(
            for: CGRect(x: 1300, y: 200, width: 460, height: 400), screens: [main, side], fallback: fallback
        ) == side.visible)
        // Mostly on the main display.
        #expect(SettingsPaneFit.visibleFrame(
            for: CGRect(x: 1100, y: 200, width: 460, height: 400), screens: [main, side], fallback: fallback
        ) == main.visible)
        // On no display (its display was unplugged) → fallback.
        #expect(SettingsPaneFit.visibleFrame(
            for: CGRect(x: 5000, y: 200, width: 460, height: 400), screens: [main, side], fallback: fallback
        ) == fallback)
        #expect(SettingsPaneFit.visibleFrame(for: .zero, screens: [], fallback: fallback) == fallback)
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

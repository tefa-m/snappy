import AppKit
import Carbon.HIToolbox
import Testing

@testable import Snappy

@Suite("StatusMenuCommand")
struct StatusMenuCommandTests {
    @Test("Order: the three captures, the recording items + Magic Pen Thickness, then Settings, then Quit")
    func order() {
        #expect(StatusMenuCommand.allCases == [
            .captureArea, .captureWindow, .captureEntireScreen,
            .recordArea, .reopenLastRecording, .magicPenThickness,
            .settings, .quit,
        ])
        #expect(StatusMenuCommand.allCases.filter(\.hasSubmenu) == [.magicPenThickness])
        #expect(StatusMenuCommand.allCases.filter(\.startsGroup) == [.recordArea, .settings, .quit])
    }

    @Test("Recording items: titles from the feature doc")
    func recordingTitles() {
        #expect(StatusMenuCommand.recordArea.title == "Record Area…")
        #expect(StatusMenuCommand.reopenLastRecording.title == "Reopen Last Recording")
        #expect(StatusMenuCommand.magicPenThickness.title == "Magic Pen Thickness")
    }

    @Test("Ellipsis exactly on the commands that need more input")
    func ellipses() {
        let withEllipsis = StatusMenuCommand.allCases.filter { $0.title.hasSuffix("…") }
        #expect(withEllipsis == [.captureArea, .captureWindow, .recordArea, .settings])
        #expect(!StatusMenuCommand.captureEntireScreen.title.lowercased().contains("fullscreen"))
    }

    @Test("Icons are uniform within each group")
    func iconsPerGroup() {
        let captures: [StatusMenuCommand] = [.captureArea, .captureWindow, .captureEntireScreen]
        #expect(captures.allSatisfy { $0.symbolName != nil })
        let recording: [StatusMenuCommand] = [.recordArea, .reopenLastRecording, .magicPenThickness]
        #expect(recording.allSatisfy { $0.symbolName != nil })
        for command in StatusMenuCommand.allCases {
            if let name = command.symbolName {
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
        }
    }

    @Test("Key equivalents: the default ⇧⌘4 and ⇧⌘3, none, ⌘, and ⌘Q")
    func keyEquivalents() {
        #expect(StatusMenuCommand.captureArea.keyEquivalent().key == "4")
        #expect(StatusMenuCommand.captureArea.keyEquivalent().modifiers == [.command, .shift])
        #expect(StatusMenuCommand.captureWindow.keyEquivalent().key == "")
        #expect(StatusMenuCommand.captureEntireScreen.keyEquivalent().key == "3")
        #expect(StatusMenuCommand.captureEntireScreen.keyEquivalent().modifiers == [.command, .shift])
        #expect(StatusMenuCommand.recordArea.keyEquivalent().key == "")
        #expect(StatusMenuCommand.reopenLastRecording.keyEquivalent().key == "")
        #expect(StatusMenuCommand.magicPenThickness.keyEquivalent().key == "")
        #expect(StatusMenuCommand.settings.keyEquivalent().key == ",")
        #expect(StatusMenuCommand.quit.keyEquivalent().key == "q")
    }

    @Test("The capture items show the configured hot keys")
    func keyEquivalentsFollowBindings() {
        var bindings = HotKeyBindings.defaults
        bindings.captureArea = HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | optionKey))
        bindings.captureFullscreen = HotKeyCombo(keyCode: UInt32(kVK_ANSI_9), carbonModifiers: UInt32(cmdKey))
        #expect(StatusMenuCommand.captureArea.keyEquivalent(in: bindings).key == "a")
        #expect(StatusMenuCommand.captureArea.keyEquivalent(in: bindings).modifiers == [.control, .option])
        #expect(StatusMenuCommand.captureEntireScreen.keyEquivalent(in: bindings).key == "9")
        #expect(StatusMenuCommand.captureEntireScreen.keyEquivalent(in: bindings).modifiers == [.command])
        #expect(StatusMenuCommand.settings.keyEquivalent(in: bindings).key == ",")
    }
}

@Suite("Magic Pen menus")
struct MagicPenMenuTests {
    @Test("Thickness submenu: Thin · Medium · Thick, checkmark on the current one only")
    func thicknessItems() {
        for current in InkWidth.allCases {
            let items = MagicPenThicknessMenu.items(current: current)
            #expect(items.map(\.title) == ["Thin", "Medium", "Thick"])
            #expect(items.map(\.width) == InkWidth.allCases)
            #expect(items.filter(\.isChecked).map(\.width) == [current])
        }
        #expect(MagicPenThicknessMenu.title == "Magic Pen Thickness")
        #expect(!MagicPenThicknessMenu.title.hasSuffix("…"), "a submenu, not a command needing input")
    }

    @Test("A plain click on the recording ● stops (2026-10-09); right-, ⌃- or ⌥-click opens the menu")
    func clicks() {
        #expect(RecordingStatusClick.action(isRightClick: false, modifiers: []) == .stop)
        #expect(RecordingStatusClick.action(isRightClick: false, modifiers: [.capsLock]) == .stop)
        #expect(RecordingStatusClick.action(isRightClick: false, modifiers: [.shift]) == .stop)
        #expect(RecordingStatusClick.action(isRightClick: false, modifiers: [.command]) == .stop)
        #expect(RecordingStatusClick.action(isRightClick: true, modifiers: []) == .showMenu)
        #expect(RecordingStatusClick.action(isRightClick: false, modifiers: [.option]) == .showMenu)
        #expect(RecordingStatusClick.action(isRightClick: false, modifiers: [.control]) == .showMenu)
    }

    @Test("Recording menu: a Magic Pen Thickness section, then Stop")
    func recordingMenu() {
        let entries = RecordingStatusMenu.entries(magicPenWidth: .thick)
        #expect(entries == [
            .header("Magic Pen Thickness"),
            .thickness(.init(width: .thin, title: "Thin", isChecked: false)),
            .thickness(.init(width: .medium, title: "Medium", isChecked: false)),
            .thickness(.init(width: .thick, title: "Thick", isChecked: true)),
            .separator,
            .stop,
        ])
        #expect(RecordingStatusMenu.stopTitle == "Stop Recording")
    }

    @Test("The symbol exists")
    func symbol() {
        #expect(NSImage(systemSymbolName: MagicPenThicknessMenu.symbolName, accessibilityDescription: nil) != nil)
    }
}

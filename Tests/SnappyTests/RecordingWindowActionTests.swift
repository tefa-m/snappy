import AppKit
import Testing
@testable import Snappy

@Suite("RecordingWindowAction")
struct RecordingWindowActionTests {
    private func action(_ keyCode: UInt16 = 0, _ characters: String?, _ modifiers: NSEvent.ModifierFlags = [])
        -> RecordingWindowAction? {
        RecordingWindowAction.action(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    @Test("Buttons: Retake leads, Save then Copy at the trailing edge")
    func buttons() {
        #expect(RecordingWindowAction.buttons == [.retake, .save, .copy])
    }

    @Test("Tooltips lead with a verb phrase and end with the advertised key")
    func tooltipFormat() {
        for action in RecordingWindowAction.allCases {
            let tip = action.toolTip(saveFolderName: "Desktop")
            #expect(tip.hasSuffix(" (\(action.keyLabel))"))
            #expect(!tip.hasPrefix("\(action.title) ("))
        }
        #expect(RecordingWindowAction.retake.toolTip(saveFolderName: "Desktop") == "Record this area again (R)")
        #expect(RecordingWindowAction.save.toolTip(saveFolderName: "Movies") == "Save MP4 to Movies (⌘S)")
        #expect(RecordingWindowAction.copy.toolTip(saveFolderName: "Desktop")
            == "Copy video file and close (⇧⌘C)")
        #expect(RecordingWindowAction.close.toolTip(saveFolderName: "Desktop") == "Close without saving (Esc)")
        #expect(RecordingWindowAction.playPause.toolTip(saveFolderName: "Desktop")
            == "Play or pause recording (Space)")
    }

    @Test("Every symbol exists; Save and Copy match the screenshot panel and the editor")
    func symbols() {
        for action in RecordingWindowAction.allCases {
            #expect(NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil) != nil, "\(action)")
        }
        #expect(RecordingWindowAction.save.symbolName == PreviewAction.save.symbolName)
        #expect(RecordingWindowAction.copy.symbolName == PreviewAction.copy.symbolName)
        #expect(RecordingWindowAction.save.symbolName == EditorAction.save.symbolName)
        #expect(RecordingWindowAction.copy.symbolName == EditorAction.copy.symbolName)
    }

    @Test("Bare keys: Space plays/pauses, R retakes, Esc and Q close (Shift/Caps Lock tolerated)")
    func bareKeys() {
        #expect(action(49, " ") == .playPause)
        #expect(action(15, "r") == .retake)
        #expect(action(15, "R", .shift) == .retake)
        #expect(action(15, "r", .capsLock) == .retake)
        #expect(action(53, "\u{1b}") == .close)
        #expect(action(12, "q") == .close)
    }

    @Test("[ and ] step the export size; with ⌘ they do nothing")
    func exportSizeKeys() {
        #expect(action(33, "[") == .smallerExport)
        #expect(action(30, "]") == .largerExport)
        #expect(action(33, "[", .capsLock) == .smallerExport)
        #expect(action(33, "[", .command) == nil)
        #expect(action(30, "]", [.command, .option]) == nil)
        #expect(RecordingWindowAction.smallerExport.toolTip(saveFolderName: "Desktop") == "Smaller export ([)")
        #expect(RecordingWindowAction.largerExport.toolTip(saveFolderName: "Desktop") == "Larger export (])")
        // Not toolbar buttons: the status capsule's slider is their control.
        #expect(!RecordingWindowAction.buttons.contains(.smallerExport))
        #expect(!RecordingWindowAction.buttons.contains(.largerExport))
    }

    @Test("⌘S saves, ⇧⌘C (and ⌘C) copies, ⌘W closes")
    func commandKeys() {
        #expect(action(1, "s", .command) == .save)
        #expect(action(8, "C", [.command, .shift]) == .copy)
        #expect(action(8, "c", [.command, .shift]) == .copy)
        #expect(action(8, "c", .command) == .copy)
        #expect(action(13, "w", .command) == .close)
        // Caps Lock never disables a shortcut.
        #expect(action(1, "s", [.command, .capsLock]) == .save)
    }

    @Test("Plain C and S do nothing (Q24); neither do other letters or extra modifiers")
    func ignoredKeys() {
        #expect(action(8, "c") == nil)
        #expect(action(1, "s") == nil)
        #expect(action(1, "S", .shift) == nil)
        #expect(action(14, "e") == nil)
        #expect(action(35, "p") == nil)
        #expect(action(1, "s", [.command, .shift]) == nil)
        #expect(action(1, "s", [.command, .option]) == nil)
        #expect(action(8, "c", [.command, .control]) == nil)
        #expect(action(15, "r", .command) == nil)
        #expect(action(12, "q", .command) == nil) // ⌘Q is not ours to take
        #expect(action(49, " ", .command) == nil)
        #expect(action(0, nil) == nil)
    }
}

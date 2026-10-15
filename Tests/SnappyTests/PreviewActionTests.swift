import AppKit
import Testing

@testable import Snappy

@Suite("PreviewAction")
struct PreviewActionTests {
    @Test("Tooltips lead with a verb phrase and end with the uppercase key")
    func tooltipFormat() {
        for action in PreviewAction.allCases {
            let tip = action.toolTip(saveFolderName: "Desktop")
            #expect(tip.hasSuffix(" (\(action.shortcutKey.uppercased()))"))
            // HIG: don't just repeat the button's name in its tooltip.
            #expect(!tip.hasPrefix("\(action.title) ("))
        }
    }

    @Test("Order: the five screenshot actions keep their places, Record comes last")
    func order() {
        #expect(PreviewAction.allCases == [.edit, .copy, .save, .ocr, .pin, .record])
    }

    @Test("Shortcut keys are unique, and R records")
    func keys() {
        let keys = PreviewAction.allCases.map(\.shortcutKey)
        #expect(Set(keys).count == keys.count)
        #expect(keys == ["e", "c", "s", "o", "p", "r"])
    }

    @Test("Record: record.circle, \"Record this area (R)\"")
    func record() {
        #expect(PreviewAction.record.symbolName == "record.circle")
        #expect(PreviewAction.record.toolTip(saveFolderName: "Desktop") == "Record this area (R)")
        for action in PreviewAction.allCases {
            #expect(NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil) != nil, "\(action)")
        }
    }

    @Test("Save tooltip names the destination folder")
    func saveTooltipNamesFolder() {
        #expect(PreviewAction.save.toolTip(saveFolderName: "Screenshots") == "Save PNG to Screenshots (S)")
    }
}

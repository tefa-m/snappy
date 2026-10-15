import Testing

@testable import Snappy

@Suite("PinAction")
struct PinActionTests {
    @Test("Toolbar order is Close, Edit, Copy")
    func order() {
        #expect(PinAction.allCases == [.close, .edit, .copy])
    }

    @Test("Tooltips lead with a verb phrase and end with the uppercase key")
    func tooltipFormat() {
        for action in PinAction.allCases {
            #expect(action.toolTip.hasSuffix(" (\(action.shortcutKey.uppercased()))"))
            // HIG: don't just repeat the button's name in its tooltip.
            #expect(!action.toolTip.hasPrefix("\(action.title) ("))
        }
    }

    @Test("Edit and Copy tooltips match the preview panel's wording")
    func tooltipsMatchPanel() {
        #expect(PinAction.edit.toolTip == PreviewAction.edit.toolTip(saveFolderName: "Desktop"))
        #expect(PinAction.copy.toolTip == PreviewAction.copy.toolTip(saveFolderName: "Desktop"))
        #expect(PinAction.close.toolTip == "Close this pin (Q)")
    }

    @Test("Keys are the pin's existing bindings: Q, E, C")
    func keys() {
        #expect(PinAction.allCases.map(\.shortcutKey) == ["q", "e", "c"])
    }

    @Test("VoiceOver labels are the short names, without the key suffix")
    func accessibilityLabels() {
        #expect(PinAction.allCases.map(\.title) == ["Close", "Edit", "Copy"])
    }

    @Test("Context menu: Edit and Copy, then Close last; every action reachable")
    func contextMenu() {
        #expect(PinAction.contextMenuGroups == [[.edit, .copy], [.close]])
        #expect(Set(PinAction.contextMenuGroups.joined()) == Set(PinAction.allCases))
        #expect(PinAction.close.menuSymbolName == "xmark")
        #expect(PinAction.copy.menuSymbolName == PinAction.copy.symbolName)
    }

    @Test("Hover makes the pin subtly translucent")
    func hoverAlpha() {
        #expect(PinHover.windowAlpha(hovering: true, reduceTransparency: false) == 0.9)
        #expect(PinHover.windowAlpha(hovering: false, reduceTransparency: false) == 1)
    }

    @Test("Reduce Transparency keeps the pin opaque while hovered")
    func hoverAlphaReduceTransparency() {
        #expect(PinHover.windowAlpha(hovering: true, reduceTransparency: true) == 1)
        #expect(PinHover.windowAlpha(hovering: false, reduceTransparency: true) == 1)
    }
}

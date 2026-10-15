import AppKit
import Testing

@testable import Snappy

@Suite("Editor toolbar")
@MainActor
struct EditorToolbarTests {
    /// HIG Offering help: a verb phrase, sentence case, ≤ 75 characters, and
    /// not just the control's name.
    private func expectHelpStyle(_ tip: String, label: String, key: String) {
        #expect(tip.hasSuffix(" (\(key))"))
        #expect(!tip.hasPrefix("\(label) ("))
        #expect(tip.count <= 75)
        #expect(tip.first?.isUppercase == true)
    }

    @Test("Tool tooltips lead with a verb phrase and end with the uppercase key")
    func toolTooltips() {
        for spec in EditorWindowController.toolSpecs {
            #expect(spec.key == spec.key.uppercased())
            #expect(spec.key.count == 1)
            expectHelpStyle(spec.toolTip, label: spec.label, key: spec.key)
        }
    }

    @Test("Tool shortcuts are unique and match the canvas bindings")
    func toolKeys() {
        let keys = EditorWindowController.toolSpecs.map(\.key)
        #expect(Set(keys).count == keys.count)
        // The bindings themselves live in AnnotationCanvasView.keyDown.
        #expect(Set(keys) == ["V", "R", "O", "A", "L", "P", "T", "N", "B", "X", "C"])
    }

    @Test("Action tooltips use the app-wide form")
    func actionTooltips() {
        for action in EditorAction.allCases {
            expectHelpStyle(
                action.toolTip(saveFolderName: "Desktop"), label: action.label, key: action.shortcut
            )
        }
        #expect(EditorAction.copy.toolTip(saveFolderName: "Desktop") == "Copy and close (⇧⌘C)")
    }

    @Test("Save tooltip names the destination folder")
    func saveTooltipNamesFolder() {
        #expect(EditorAction.save.toolTip(saveFolderName: "Screenshots") == "Save PNG to Screenshots (⌘S)")
    }

    @Test("Style-control tooltips are verb phrases without a key")
    func styleTooltips() {
        for tip in [
            EditorWindowController.colorToolTip,
            EditorWindowController.sizeToolTip,
            EditorWindowController.fillToolTip,
        ] {
            #expect(!tip.contains("("))
            #expect(tip.count <= 75)
            #expect(tip.first?.isUppercase == true)
        }
    }

    @Test("The colour well round-trips the model's red exactly (not systemRed)")
    func wellColorRoundTrip() {
        let well = EditorWindowController.wellColor(for: .red)
        #expect(EditorWindowController.annotationColor(from: well) == .red)
        let translucent = AnnotationColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 0.5)
        let back = EditorWindowController.annotationColor(
            from: EditorWindowController.wellColor(for: translucent)
        )
        #expect(abs(back.red - translucent.red) < 1e-6)
        #expect(abs(back.green - translucent.green) < 1e-6)
        #expect(abs(back.blue - translucent.blue) < 1e-6)
        #expect(abs(back.alpha - translucent.alpha) < 1e-6)
    }

    @Test("Tahoe Glass order: Undo·Redo lead, tools then style, Copy ends the bar")
    func toolbarOrder() {
        let order = EditorWindowController.toolbarOrder
        #expect(Array(order.prefix(2)) == [.editorUndo, .editorRedo])
        #expect(Array(order.suffix(3)) == [.editorSave, .editorPin, .editorCopy])
        let tools = EditorWindowController.toolSpecs.map(\.id)
        let firstTool = order.firstIndex(of: tools[0])!
        #expect(Array(order[firstTool..<firstTool + tools.count]) == tools)
        #expect(order.firstIndex(of: .editorColor)! > firstTool + tools.count - 1)
    }

    @Test("Window title names the capture, not the app")
    func windowTitle() {
        let title = EditorWindowController.windowTitle(pointSize: CGSize(width: 1440, height: 899.6))
        #expect(title == "Shot 1440 × 900")
        #expect(!title.contains("Snappy"))
    }
}

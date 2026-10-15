import CoreGraphics
import Foundation
import Testing
@testable import Snappy

@Suite struct AnnotationColorTests {
    private static func color(_ hex: UInt32) -> AnnotationColor {
        AnnotationColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255
        )
    }

    @Test func luminanceAndContrastMatchWCAG() {
        #expect(AnnotationColor.white.relativeLuminance == 1)
        #expect(AnnotationColor.black.relativeLuminance == 0)
        #expect(AnnotationColor.white.contrastRatio(with: .black) == 21)
        #expect(AnnotationColor.black.contrastRatio(with: .white) == 21) // symmetric
        // The default red against white: 3.55:1 (measured, see editor-canvas review).
        let red = AnnotationColor.red.contrastRatio(with: .white)
        #expect(abs(red - 3.55) < 0.01)
    }

    @Test func badgeDigitsStayWhiteOnDarkFills() {
        #expect(AnnotationColor.red.badgeLabelColor == .white)
        #expect(Self.color(0x0088FF).badgeLabelColor == .white) // systemBlue, 3.52:1
        #expect(AnnotationColor.black.badgeLabelColor == .white)
    }

    @Test func badgeDigitsTurnBlackOnLightFills() {
        #expect(Self.color(0xFFCC00).badgeLabelColor == .black) // systemYellow, 1.51:1 with white
        #expect(Self.color(0x34C759).badgeLabelColor == .black) // systemGreen, 2.22:1
        #expect(Self.color(0xFF8D28).badgeLabelColor == .black) // systemOrange, 2.31:1
        #expect(AnnotationColor.white.badgeLabelColor == .black)
    }
}

@Suite struct AnnotationDiffTests {
    private static let style = AnnotationStyle(strokeColor: .red, strokeWidth: 3, hasFill: false)

    private static func badge(_ x: CGFloat, id: UUID = UUID()) -> Annotation {
        .counter(CounterAnnotation(id: id, center: CGPoint(x: x, y: 0), style: style))
    }

    @Test func nothingChangedIsNil() {
        let list = [Self.badge(1), Self.badge(2)]
        #expect(AnnotationDiff.soleChangedID(from: list, to: list) == nil)
    }

    @Test func oneRestoredAnnotationIsFound() {
        let a = Self.badge(1), b = Self.badge(2)
        #expect(AnnotationDiff.soleChangedID(from: [a], to: [a, b]) == b.id)
    }

    @Test func oneChangedAnnotationIsFound() {
        let id = UUID()
        let before = [Self.badge(1), Self.badge(2, id: id)]
        let after = [before[0], Self.badge(9, id: id)]
        #expect(AnnotationDiff.soleChangedID(from: before, to: after) == id)
    }

    @Test func severalChangesAreNil() {
        let before = [Self.badge(1), Self.badge(2)]
        let after = before.map { $0.offset(by: CGVector(dx: 5, dy: 0)) } // e.g. undoing a crop
        #expect(AnnotationDiff.soleChangedID(from: before, to: after) == nil)
    }

    @Test func removalsDoNotCount() {
        let a = Self.badge(1), b = Self.badge(2)
        #expect(AnnotationDiff.soleChangedID(from: [a, b], to: [a]) == nil)
    }

    @Test func cropUndoSelectsNothingEvenWithOneAnnotation() {
        let a = Self.badge(1)
        let offset = a.offset(by: CGVector(dx: -5, dy: 0))
        #expect(AnnotationDiff.selectionAfterUndo(from: [a], to: [offset], imageChanged: true) == nil)
        #expect(AnnotationDiff.selectionAfterUndo(from: [a], to: [offset], imageChanged: false) == a.id)
    }
}

/// The canvas's undo selection, end to end through a real document.
@MainActor @Suite struct CanvasUndoSelectionTests {
    private static func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        return context.makeImage()!
    }

    private func makeCanvas() -> (AnnotationDocument, AnnotationCanvasView) {
        let document = AnnotationDocument(image: Self.image(), scale: 1)
        let defaults = UserDefaults(suiteName: "CanvasUndoSelectionTests-\(UUID())")!
        let canvas = AnnotationCanvasView(
            document: document, style: .defaultStyle(scale: 1), settings: SettingsStore(defaults: defaults)
        )
        document.onChange = { canvas.documentDidChange() }
        return (document, canvas)
    }

    private func badge(at x: CGFloat, width: CGFloat = 3) -> CounterAnnotation {
        CounterAnnotation(
            id: UUID(), center: CGPoint(x: x, y: 20),
            style: AnnotationStyle(strokeColor: .red, strokeWidth: width, hasFill: false)
        )
    }

    @Test func undoOfARestyleSelectsTheAnnotation() {
        let (document, canvas) = makeCanvas()
        var badge = badge(at: 20)
        document.add(.counter(badge))
        badge.style.strokeWidth = 5
        document.replace(id: badge.id, with: .counter(badge))
        #expect(canvas.selectedID == nil)
        document.undoManager.undo()
        #expect(canvas.selectedID == badge.id)
    }

    @Test func undoOfACropClearsTheSelection() {
        let (document, canvas) = makeCanvas()
        var badge = badge(at: 20)
        document.add(.counter(badge))
        badge.style.strokeWidth = 5
        document.replace(id: badge.id, with: .counter(badge))
        document.undoManager.undo() // selects the badge
        #expect(canvas.selectedID == badge.id)
        document.crop(to: CGRect(x: 0, y: 0, width: 60, height: 60)) // keeps the one badge
        document.undoManager.undo()
        #expect(canvas.selectedID == nil) // not the lone surviving badge
        document.undoManager.redo()
        #expect(canvas.selectedID == nil)
    }

    @Test func undoOfAnAddClearsAnUnrelatedSelection() {
        let (document, canvas) = makeCanvas()
        var first = badge(at: 20)
        document.add(.counter(first))
        first.style.strokeWidth = 5
        document.replace(id: first.id, with: .counter(first))
        document.undoManager.undo() // selects `first`
        document.add(.counter(badge(at: 60)))
        document.undoManager.undo() // removes the second badge: nothing to show
        #expect(canvas.selectedID == nil)
    }
}


import CoreGraphics
import Foundation
import Testing
@testable import Snappy

@Suite @MainActor struct AnnotationDocumentTests {
    private static func makeImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private static func makeShape(rect: CGRect = CGRect(x: 1, y: 1, width: 2, height: 2)) -> ShapeAnnotation {
        ShapeAnnotation(id: UUID(), kind: .rectangle, rect: rect, style: .defaultStyle(scale: 1))
    }

    private let document = AnnotationDocument(image: makeImage(), scale: 2)

    @Test func addRemoveReplaceMutateTheModel() {
        let shape = Self.makeShape()
        document.add(.shape(shape))
        #expect(document.annotations == [.shape(shape)])
        #expect(document.annotation(id: shape.id) == .shape(shape))

        var moved = shape
        moved.rect = moved.rect.offsetBy(dx: 1, dy: 0)
        document.replace(id: shape.id, with: .shape(moved))
        #expect(document.annotations == [.shape(moved)])

        document.remove(id: shape.id)
        #expect(document.annotations.isEmpty)
    }

    @Test func replaceAndRemoveUnknownIDAreNoOps() {
        let shape = Self.makeShape()
        document.add(.shape(shape))
        document.replace(id: UUID(), with: .shape(Self.makeShape()))
        document.remove(id: UUID())
        #expect(document.annotations == [.shape(shape)])
        #expect(document.undoManager.canUndo)
    }

    @Test func replaceWithEqualValueRegistersNoUndoStep() {
        let shape = Self.makeShape()
        document.add(.shape(shape))
        document.undoManager.removeAllActions()
        document.replace(id: shape.id, with: .shape(shape))
        #expect(!document.undoManager.canUndo)
    }

    // The full M4 requirement: add → move → resize → delete, then undo each
    // step restores the exact prior state, and redo replays it.
    @Test func undoRedoWalksExactStates() {
        let shape = Self.makeShape(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        var moved = shape
        moved.rect = CGRect(x: 2, y: 2, width: 1, height: 1)
        var resized = moved
        resized.rect = CGRect(x: 2, y: 2, width: 2, height: 1.5)

        document.add(.shape(shape))
        document.replace(id: shape.id, with: .shape(moved))
        document.replace(id: shape.id, with: .shape(resized))
        document.remove(id: shape.id)

        let states: [[Annotation]] = [
            [],
            [.shape(shape)],
            [.shape(moved)],
            [.shape(resized)],
            [],
        ]

        #expect(document.annotations == states[4])
        for expected in states.dropLast().reversed() {
            document.undoManager.undo()
            #expect(document.annotations == expected)
        }
        #expect(!document.undoManager.canUndo)

        for expected in states.dropFirst() {
            document.undoManager.redo()
            #expect(document.annotations == expected)
        }
        #expect(!document.undoManager.canRedo)
    }

    @Test func undoingAMiddleRemovalRestoresZOrder() {
        let a = Self.makeShape(), b = Self.makeShape(), c = Self.makeShape()
        document.add(.shape(a))
        document.add(.shape(b))
        document.add(.shape(c))

        document.remove(id: b.id)
        #expect(document.annotations == [.shape(a), .shape(c)])

        document.undoManager.undo()
        #expect(document.annotations == [.shape(a), .shape(b), .shape(c)])
    }

    // M6 crop: annotations keep their position relative to the image content,
    // and one undo step restores both the image and the annotations.
    @Test func cropRemapsAnnotationsAndUndoRestoresEverything() {
        let shape = Self.makeShape(rect: CGRect(x: 1, y: 1, width: 2, height: 2))
        let arrow = ArrowAnnotation(
            id: UUID(),
            tail: CGPoint(x: 1, y: 1),
            head: CGPoint(x: 3, y: 3),
            style: .defaultStyle(scale: 1)
        )
        document.add(.shape(shape))
        document.add(.arrow(arrow))

        document.crop(to: CGRect(x: 1, y: 1, width: 2, height: 2))
        #expect(document.image.width == 2)
        #expect(document.image.height == 2)

        var croppedShape = shape
        croppedShape.rect = CGRect(x: 0, y: 0, width: 2, height: 2)
        var croppedArrow = arrow
        croppedArrow.tail = CGPoint(x: 0, y: 0)
        croppedArrow.head = CGPoint(x: 2, y: 2)
        #expect(document.annotations == [.shape(croppedShape), .arrow(croppedArrow)])

        document.undoManager.undo()
        #expect(document.image.width == 4)
        #expect(document.annotations == [.shape(shape), .arrow(arrow)])

        document.undoManager.redo()
        #expect(document.image.width == 2)
        #expect(document.annotations == [.shape(croppedShape), .arrow(croppedArrow)])
    }

    // The canvas is derived from annotation bounds, so an annotation left
    // outside a crop would re-expand it over the area just cropped away.
    @Test func cropDropsWhollyOutsideAnnotationsSoTheCanvasStaysTight() {
        let thin = AnnotationStyle(strokeColor: .red, strokeWidth: 0, hasFill: false)
        let outside = ShapeAnnotation(
            id: UUID(), kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 1, height: 1), style: thin
        )
        let inside = ShapeAnnotation(
            id: UUID(), kind: .rectangle, rect: CGRect(x: 2, y: 2, width: 1.5, height: 1.5), style: thin
        )
        document.add(.shape(outside))
        document.add(.shape(inside))

        document.crop(to: CGRect(x: 2, y: 2, width: 2, height: 2))
        #expect(document.annotations.count == 1)
        #expect(document.annotations.first?.id == inside.id)
        #expect(document.canvasRect(padding: 8) == document.imageBounds)

        document.undoManager.undo()
        #expect(document.image.width == 4)
        #expect(document.annotations == [.shape(outside), .shape(inside)])
    }

    @Test func cropKeepsPartiallyOverlappingAnnotationsIntact() {
        let thin = AnnotationStyle(strokeColor: .red, strokeWidth: 0, hasFill: false)
        let straddling = ShapeAnnotation(
            id: UUID(), kind: .rectangle, rect: CGRect(x: 1, y: 1, width: 2, height: 2), style: thin
        )
        document.add(.shape(straddling))
        // Crop to the right half of the straddling rect's x range.
        document.crop(to: CGRect(x: 2, y: 0, width: 2, height: 4))
        var shifted = straddling
        shifted.rect = CGRect(x: -1, y: 1, width: 2, height: 2)
        #expect(document.annotations == [.shape(shifted)])
        // It pokes out the left side, so the canvas expands there — accepted.
        #expect(document.canvasRect(padding: 0).minX == -1)
    }

    @Test func degenerateOrFullImageCropsAreNoOps() {
        document.crop(to: CGRect(x: 0, y: 0, width: 0.4, height: 0.4))
        #expect(document.image.width == 4)
        #expect(!document.undoManager.canUndo)

        document.crop(to: document.imageBounds)
        #expect(document.image.width == 4)
        #expect(!document.undoManager.canUndo)

        document.crop(to: CGRect(x: 10, y: 10, width: 5, height: 5)) // fully outside
        #expect(document.image.width == 4)
        #expect(!document.undoManager.canUndo)
    }

    @Test func onChangeFiresForMutationsAndUndo() {
        var changes = 0
        document.onChange = { changes += 1 }
        let shape = Self.makeShape()
        document.add(.shape(shape))
        document.remove(id: shape.id)
        document.undoManager.undo()
        #expect(changes == 3)
    }

    // MARK: - Auto-expanding canvas (M-F)

    @Test func canvasRectIsImageBoundsWithoutOverflow() {
        // strokeWidth 0 so expandedBounds is the plain rect, fully inside 4×4.
        let style = AnnotationStyle(strokeColor: .red, strokeWidth: 0, hasFill: false)
        document.add(.shape(ShapeAnnotation(
            id: UUID(), kind: .rectangle, rect: CGRect(x: 1, y: 1, width: 2, height: 2), style: style
        )))
        #expect(document.canvasRect(padding: 5) == document.imageBounds)
    }

    @Test func canvasRectExpandsForAnnotationsPastTheEdge() {
        // 4×4 image; a rectangle spilling off the right/top with strokeWidth 0
        // so expandedBounds is the plain rect.
        let style = AnnotationStyle(strokeColor: .red, strokeWidth: 0, hasFill: false)
        document.add(.shape(ShapeAnnotation(
            id: UUID(), kind: .rectangle,
            rect: CGRect(x: 2, y: 2, width: 6, height: 6), style: style // maxX/maxY = 8
        )))
        // Right and top overflow by padding; left/bottom stay flush.
        #expect(document.canvasRect(padding: 3) == CGRect(x: 0, y: 0, width: 11, height: 11))
    }

    @Test func canvasBackgroundRebuildsAfterCrop() {
        let first = document.canvasBackground
        #expect(first != nil)
        // Same image → cached instance's bounds unchanged.
        #expect(document.canvasBackground?.imageBounds == CGRect(x: 0, y: 0, width: 4, height: 4))
        document.crop(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        // After crop the cache is rebuilt for the new (smaller) image.
        #expect(document.canvasBackground?.imageBounds == CGRect(x: 0, y: 0, width: 2, height: 2))
    }
}

import CoreGraphics
import Foundation

/// The editor's model: base image + ordered annotations (array order =
/// z-order, last on top). Every public mutation is exactly one undo step:
/// `groupsByEvent = false` with an explicit group per mutation, so undo
/// behaves identically in the app and in tests (which have no run loop).
///
/// Interactive gestures (move/resize drags) must NOT call `replace` per mouse
/// event — the canvas keeps a draft during the gesture and commits one
/// `replace` on mouse-up.
@MainActor
final class AnnotationDocument {
    /// Mutable since M6: crop replaces it (undoably). Everything reading the
    /// image (canvas fitting, export) re-derives from it on each use.
    private(set) var image: CGImage
    /// Backing scale of the capture (image pixels per screen point).
    let scale: CGFloat
    let undoManager = UndoManager()

    private(set) var annotations: [Annotation] = []

    /// Called after every model mutation, including those from undo/redo.
    var onChange: (() -> Void)?

    /// Image bounds in image-pixel coordinates — the base image always sits
    /// here; annotations may extend beyond it (M-F auto-expanding canvas).
    var imageBounds: CGRect {
        CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    /// Edge-derived background for expanded canvas area, built lazily from the
    /// current image and cached (invalidated on crop). nil only if sampling the
    /// image fails.
    private var _canvasBackground: CanvasBackground??
    var canvasBackground: CanvasBackground? {
        if let cached = _canvasBackground { return cached }
        let background = CanvasBackground(image: image)
        _canvasBackground = .some(background)
        return background
    }

    /// The derived canvas rect (M-F) for the committed annotations: image
    /// bounds expanded per-side to contain every annotation plus `padding`
    /// (image px). No stored state, nothing in undo — purely a function of the
    /// current annotations.
    func canvasRect(padding: CGFloat) -> CGRect {
        CanvasGeometry.canvasRect(
            imageBounds: imageBounds,
            annotationRects: annotations.map(\.expandedBounds),
            padding: padding
        )
    }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        undoManager.groupsByEvent = false
    }

    func annotation(id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    func add(_ annotation: Annotation) {
        insert(annotation, at: annotations.count)
    }

    func insert(_ annotation: Annotation, at index: Int) {
        withUndoGroup {
            annotations.insert(annotation, at: min(index, annotations.count))
            let id = annotation.id
            undoManager.registerUndo(withTarget: self) { document in
                MainActor.assumeIsolated { document.remove(id: id) }
            }
        }
        onChange?()
    }

    func remove(id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let removed = annotations[index]
        withUndoGroup {
            annotations.remove(at: index)
            undoManager.registerUndo(withTarget: self) { document in
                MainActor.assumeIsolated { document.insert(removed, at: index) }
            }
        }
        onChange?()
    }

    /// Replaces an annotation's value (move / resize / restyle) as one undo
    /// step. No-op when the id is unknown or the value is unchanged.
    func replace(id: UUID, with new: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let old = annotations[index]
        guard old != new else { return }
        withUndoGroup {
            annotations[index] = new
            undoManager.registerUndo(withTarget: self) { document in
                MainActor.assumeIsolated { document.replace(id: new.id, with: old) }
            }
        }
        onChange?()
    }

    /// Crops the document to `rect` (image pixels, bottom-left origin) as one
    /// undo step. Annotations are offset so they keep their position relative
    /// to the image content. Ones wholly outside the new bounds are dropped —
    /// the canvas is derived from annotation bounds, so keeping them would
    /// re-expand it over the area just cropped away. Partially overlapping ones
    /// are kept intact (they may extend the canvas slightly). Undo restores
    /// both the image and every dropped annotation.
    func crop(to rect: CGRect) {
        // Sub-pixel rects are degenerate — check before .integral rounds them up.
        guard rect.width >= 1, rect.height >= 1 else { return }
        let target = rect.integral.intersection(imageBounds)
        guard target.width >= 1, target.height >= 1, target != imageBounds else { return }
        // CGImage.cropping expects a top-left-origin rect; the model is
        // bottom-left. This is the y-flip — keep it here, nowhere else.
        let flipped = CGRect(
            x: target.minX,
            y: CGFloat(image.height) - target.maxY,
            width: target.width,
            height: target.height
        )
        guard let cropped = image.cropping(to: flipped) else { return }
        let delta = CGVector(dx: -target.minX, dy: -target.minY)
        let kept = annotations.filter { $0.expandedBounds.intersects(target) }
        setContents(image: cropped, annotations: kept.map { $0.offset(by: delta) })
    }

    /// Swaps image + annotations wholesale (crop and its undo/redo).
    private func setContents(image newImage: CGImage, annotations newAnnotations: [Annotation]) {
        let oldImage = image
        let oldAnnotations = annotations
        withUndoGroup {
            image = newImage
            annotations = newAnnotations
            _canvasBackground = nil // edge colors belong to the old image
            EffectRenderer.clearCache() // so do cached blur/pixelate results
            undoManager.registerUndo(withTarget: self) { document in
                MainActor.assumeIsolated {
                    document.setContents(image: oldImage, annotations: oldAnnotations)
                }
            }
        }
        onChange?()
    }

    /// Opens an explicit top-level undo group around a mutation — except while
    /// undoing/redoing, where the undo manager groups re-registrations itself.
    private func withUndoGroup(_ body: () -> Void) {
        let manageGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if manageGroup { undoManager.beginUndoGrouping() }
        body()
        if manageGroup { undoManager.endUndoGrouping() }
    }
}

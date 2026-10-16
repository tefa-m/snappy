import AppKit

/// What the canvas draws with.
enum EditorTool: Equatable {
    case select
    case shape(ShapeKind)
    case arrow
    case line
    case text
    case freehand
    case effect(EffectKind)
    case counter
    case crop
}

/// Commands the canvas raises for its window controller (shortcuts the
/// controller must reflect in its toolbar UI).
enum EditorCanvasCommand {
    case copy, save, pin, close
    case selectTool(EditorTool)
}

/// The annotation canvas: draws the capture aspect-fit, annotations on top in
/// image-pixel space (shared code path with export via AnnotationRenderer),
/// and selection handles in view space. Handles draw / select / move / resize
/// / delete, in-place text editing (NSTextField overlay), and the crop
/// gesture. All geometry goes through the pure geometry types; drags mutate a
/// local draft and commit one undoable document mutation on mouse-up.
@MainActor
final class AnnotationCanvasView: NSView {
    private let document: AnnotationDocument
    private let settings: SettingsStore
    private let cursorFactory = ToolCursorFactory()

    var tool: EditorTool = .shape(.rectangle) {
        didSet {
            // Only the disabled fallback uses cursor rects. Invalidating them
            // while the tool-aware cursor is on makes AppKit reset the pointer
            // to the arrow AFTER refreshCursor has set the crosshair (and the
            // kind cache then suppresses the re-set on the next mouseMoved).
            if !settings.toolAwareCursorEnabled {
                window?.invalidateCursorRects(for: self)
            }
            guard tool != oldValue else { return }
            refreshCursorAtMouseLocation()
            flashToolName()
            announceTool()
        }
    }
    /// Style used for newly drawn shapes.
    private(set) var currentStyle: AnnotationStyle

    private(set) var selectedID: UUID?
    var onSelectionChange: ((Annotation?) -> Void)?
    var onCommand: ((EditorCanvasCommand) -> Void)?
    /// Fired when the on-screen fit can change (window resize, and the re-fit
    /// when a gesture releases its frozen transform), so the controller can
    /// refresh the zoom in its status capsule.
    var onViewportChange: (() -> Void)?

    /// Height kept clear at the bottom for the glass status capsule (Tahoe
    /// Glass) — the capture is fitted above it, the backdrop runs under it.
    var bottomInset: CGFloat = 0 {
        didSet { if bottomInset != oldValue { needsDisplay = true } }
    }

    private enum DragState {
        case none
        case drawing(anchor: CGPoint, id: UUID) // anchor in image space
        case drawingArrow(anchor: CGPoint, id: UUID, kind: ArrowKind) // anchor = tail
        case drawingFreehand(id: UUID)
        case drawingEffect(anchor: CGPoint, id: UUID, kind: EffectKind)
        case placingCounter(id: UUID)
        case cropping(anchor: CGPoint) // image space
        case moving(original: Annotation, start: CGPoint) // start in view space
        case resizing(original: Annotation, handle: AnnotationGeometry.ResizeHandle, start: CGPoint)
        case movingHandle(original: ArrowAnnotation, handle: ArrowHandle)
    }
    private var drag: DragState = .none
    /// Live in-gesture value of the manipulated annotation (uncommitted).
    private var draft: Annotation?
    /// Live crop rect (image space) while the crop tool drags.
    private var cropDraft: CGRect?

    // In-place text editing (M6).
    private var textField: NSTextField?
    private var editingTextID: UUID? // set while re-editing an existing label
    private var editingTextStyle: AnnotationStyle?
    /// Image point the user clicked to start a NEW label — becomes the
    /// text bounds' top-left (people type "below" where they clicked).
    private var pendingTextAnchor: CGPoint?
    /// Where the overlay field sits, in image space, so it can be re-laid-out
    /// whenever the view→image transform changes (window resize, style change).
    /// `isTopLeft`: a new label hangs below the click; an existing one starts
    /// at its own bottom-left origin.
    private var textFieldAnchor: (point: CGPoint, isTopLeft: Bool)?

    private static let canvasMargin: CGFloat = 12

    /// Tahoe Glass backdrop behind the capture: a soft vertical wash, light
    /// in Light mode and graphite in Dark mode. Dynamic colours resolve while
    /// `draw` runs under the view's effective appearance.
    private static let backdropTop = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.165, green: 0.169, blue: 0.184, alpha: 1)  // #2A2B2F
            : NSColor(srgbRed: 0.969, green: 0.973, blue: 0.984, alpha: 1)  // #F7F8FB
    }
    private static let backdropBottom = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.106, green: 0.110, blue: 0.122, alpha: 1)  // #1B1C1F
            : NSColor(srgbRed: 0.890, green: 0.902, blue: 0.925, alpha: 1)  // #E3E6EC
    }
    /// The capture's drop shadow: deeper in Dark mode so it still separates.
    private static let captureShadow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.55)
            : NSColor(srgbRed: 0.08, green: 0.12, blue: 0.24, alpha: 0.28)
    }

    /// Where the capture is fitted: the canvas runs under the glass toolbar
    /// (full-size content view), so only the unobscured content-layout area
    /// above the status capsule counts.
    private var fitBounds: CGRect {
        AnnotationGeometry.fitArea(
            bounds: bounds,
            unobscured: window.map { convert($0.contentLayoutRect, from: nil) },
            bottomInset: bottomInset
        )
    }

    /// Current zoom in percent (100 % = the capture's original point size).
    var zoomPercent: Int {
        EditorStatus.zoomPercent(
            viewWidth: fittedFrame.width, canvasPixelWidth: canvasRect.width, scale: document.scale
        )
    }
    /// Handle targets: 10 pt radius (a 20 pt region, the HIG's macOS minimum
    /// control size) wherever the point is NOT on an annotation body; on a
    /// body only the old 7 pt core grabs the handle, so a small selection
    /// keeps a body to move (an 18 pt effect is all handle at 10 pt). See
    /// `AnnotationGeometry.arbitrateHandle`. Overlapping handles resolve to
    /// the nearest one. Canvas handles stay under the 28 pt control-size default
    /// on purpose: at 28 pt, anything under ~56 pt would be all handle.
    private static let handleHitRadius: CGFloat = 10
    private static let handleCoreHitRadius: CGFloat = 7
    private static let handleDrawSize: CGFloat = 8
    private static let hitTolerance: CGFloat = 5 // view points
    private static let clickDragThreshold: CGFloat = 3 // view points
    private static let minShapeSize: CGFloat = 4 // image pixels
    private static let minArrowLength: CGFloat = 8 // image pixels
    private static let minCropSize: CGFloat = 8 // image pixels

    init(document: AnnotationDocument, style: AnnotationStyle, settings: SettingsStore) {
        self.document = document
        self.currentStyle = style
        self.settings = settings
        lastSeenAnnotations = document.annotations
        lastSeenImage = document.image
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { document.undoManager }

    // MARK: - Document / selection

    /// The document's annotations and image as of the last change, to see
    /// what an undo/redo step touched.
    private var lastSeenAnnotations: [Annotation] = []
    private var lastSeenImage: CGImage?

    /// Called by the controller after every document change: redraw and drop a
    /// selection whose annotation no longer exists (e.g. undo of an add).
    /// After an undo/redo the selection shows what the step did: exactly one
    /// annotation brought back or changed → it is selected (its handles mark
    /// even a 1 pt width change — HIG: show the results of undo); a crop or a
    /// step touching none or several → nothing is selected
    /// (`AnnotationDiff.selectionAfterUndo`). Never while a label is typed.
    func documentDidChange() {
        let previous = lastSeenAnnotations
        let imageChanged = lastSeenImage.map { $0 !== document.image } ?? false
        lastSeenAnnotations = document.annotations
        lastSeenImage = document.image
        if textField == nil,
           document.undoManager.isUndoing || document.undoManager.isRedoing {
            select(AnnotationDiff.selectionAfterUndo(
                from: previous, to: document.annotations, imageChanged: imageChanged
            ))
        }
        if let selectedID {
            if document.annotation(id: selectedID) == nil {
                select(nil)
            } else {
                // Same id, possibly a different value (undo/redo of a restyle):
                // keep the style controls honest.
                onSelectionChange?(selectedAnnotation())
            }
        }
        needsDisplay = true
    }

    /// Applies a style to the current selection (one undo step) and makes it
    /// the default for new shapes. While a label is being typed (nothing is
    /// selected then) the style goes to that label, live.
    func apply(style: AnnotationStyle) {
        currentStyle = style
        if textField != nil {
            editingTextStyle = style
            layoutTextField()
        }
        if let selected = selectedAnnotation() {
            document.replace(id: selected.id, with: selected.withStyle(style))
        }
    }

    /// Flushes anything held outside the document — today only a label still
    /// being typed — into it. Idempotent; call before reading the document for
    /// export.
    func commitPendingEdits() {
        commitTextEditing()
    }

    private func select(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        needsDisplay = true
        onSelectionChange?(selectedAnnotation())
    }

    private func selectedAnnotation() -> Annotation? {
        guard let selectedID else { return nil }
        if let draft, draft.id == selectedID { return draft }
        return document.annotation(id: selectedID)
    }

    // MARK: - Geometry helpers

    private var imageSize: CGSize {
        CGSize(width: document.image.width, height: document.image.height)
    }

    /// Ratchet floor for the canvas rect during a gesture: the derived rect at
    /// mouse-down. While a drag is in progress the effective canvas rect is the
    /// union of this and the live derived rect, so it only GROWS mid-gesture
    /// (killing scale oscillation); it shrinks back on mouse-up when this is
    /// cleared. See docs/ARCHITECTURE.md (M-F).
    private var gestureCanvasFloor: CGRect?

    /// Frozen on-screen transform for the duration of a drag: the image→view
    /// `scale` (screen px per image px) and the view-space position of image
    /// origin `(0, 0)`, both captured at mouse-down. While set, `fittedFrame`
    /// keeps the base image fixed in size and place and lets the growing canvas
    /// extend around it (clipped to the window) instead of live-refitting.
    /// Without this the view zooms out as the canvas grows, and because the
    /// mouse→image mapping uses that same shrinking scale, each drag step maps
    /// further out — a feedback loop that made expansion accelerate away and
    /// shrink the original image to nothing. Released on mouse-up, when the view
    /// re-fits the final canvas once. See docs/ARCHITECTURE.md (M-F).
    private var gestureViewTransform: (scale: CGFloat, imageOrigin: CGPoint)?

    /// Canvas rect (M-F) for a given annotation set — image bounds expanded to
    /// contain them, plus the configured padding.
    private func derivedCanvasRect(_ annotations: [Annotation]) -> CGRect {
        CanvasGeometry.canvasRect(
            imageBounds: document.imageBounds,
            annotationRects: annotations.map(\.expandedBounds),
            padding: settings.canvasPadding * document.scale
        )
    }

    /// The canvas rect and the view frame it is fitted into.
    private struct CanvasLayout {
        let canvas: CGRect
        let frame: CGRect
    }

    /// Per-draw / per-input-event snapshot of the layout. NOT a persistent
    /// cache: it is set at the top of one `draw`, `mouseDown`, `mouseDragged`
    /// or cursor refresh and cleared when that call returns, so nothing can go
    /// stale across a document, draft, bounds or settings change. Without it
    /// every helper recomputes the canvas rect (a map over all annotations,
    /// with CoreText measuring for labels) — 10–20× per event.
    private var layoutSnapshot: CanvasLayout?

    private func currentLayout() -> CanvasLayout {
        let canvas = liveCanvasRect()
        return CanvasLayout(canvas: canvas, frame: fitted(canvas))
    }

    /// The live canvas rect: derived from the document plus the in-gesture
    /// draft, ratcheted up by the gesture floor. Deliberately includes the label
    /// being edited (it is only hidden from painting), so editing an
    /// out-of-image label does not shrink and refit the canvas under its field.
    private func liveCanvasRect() -> CGRect {
        let derived = derivedCanvasRect(layoutAnnotations())
        guard let gestureCanvasFloor else { return derived }
        return derived.union(gestureCanvasFloor)
    }

    private var canvasRect: CGRect {
        layoutSnapshot?.canvas ?? liveCanvasRect()
    }

    private var fittedFrame: CGRect {
        layoutSnapshot?.frame ?? fitted(canvasRect)
    }

    private func fitted(_ canvas: CGRect) -> CGRect {
        // During a drag the transform is frozen: the base image keeps its
        // mouse-down size/position and the canvas grows around it (extending
        // past the window, clipped) rather than the view zooming out live.
        if let t = gestureViewTransform, canvas.width > 0, canvas.height > 0 {
            return CGRect(
                x: t.imageOrigin.x + canvas.minX * t.scale,
                y: t.imageOrigin.y + canvas.minY * t.scale,
                width: canvas.width * t.scale,
                height: canvas.height * t.scale
            )
        }
        return AnnotationGeometry.fittedFrame(contentRect: canvas, in: fitBounds, margin: Self.canvasMargin)
    }

    /// View → image-space point. NOT clamped to the image (M-F: annotations may
    /// be placed outside it); tools that must stay inside the image (crop)
    /// clamp locally.
    private func imagePoint(fromViewPoint point: CGPoint) -> CGPoint {
        AnnotationGeometry.imagePoint(
            fromViewPoint: point, contentRect: canvasRect, fittedFrame: fittedFrame
        )
    }

    /// Clamps an image-space point to the base image bounds (crop tool only).
    private func clampedToImage(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), imageSize.width),
            y: min(max(point.y, 0), imageSize.height)
        )
    }

    private func viewRect(fromImageRect rect: CGRect) -> CGRect {
        AnnotationGeometry.viewRect(
            fromImageRect: rect, contentRect: canvasRect, fittedFrame: fittedFrame
        )
    }

    private func imageDelta(fromViewStart start: CGPoint, to end: CGPoint) -> CGVector {
        let scale = canvasRect.width / max(fittedFrame.width, 1)
        return CGVector(dx: (end.x - start.x) * scale, dy: (end.y - start.y) * scale)
    }

    private func selectionViewRect() -> CGRect? {
        guard let selected = selectedAnnotation() else { return nil }
        return viewRect(fromImageRect: selected.boundingRect)
    }

    private func annotation(at viewPoint: CGPoint) -> Annotation? {
        let point = imagePoint(fromViewPoint: viewPoint)
        let tolerance = AnnotationGeometry.imageLength(
            fromViewLength: Self.hitTolerance, contentRect: canvasRect, fittedFrame: fittedFrame
        )
        for annotation in document.annotations.reversed() {
            let hit: Bool
            switch annotation {
            case .shape(let shape):
                hit = AnnotationGeometry.shapeHit(
                    at: point, kind: shape.kind, rect: shape.rect,
                    tolerance: tolerance + shape.style.strokeWidth / 2
                ) != nil
            case .arrow(let arrow) where arrow.kind == .line:
                hit = ArrowGeometry.segmentDistance(from: point, to: arrow.tail, arrow.head)
                    <= tolerance + arrow.style.strokeWidth / 2
            case .arrow(let arrow):
                hit = ArrowGeometry.hits(
                    point, tail: arrow.tail, head: arrow.head, bow: arrow.bow,
                    strokeWidth: arrow.style.strokeWidth, tolerance: tolerance
                )
            case .text(let text):
                hit = text.boundingRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            case .freehand(let stroke):
                hit = FreehandGeometry.hits(
                    point, points: stroke.points,
                    strokeWidth: stroke.style.strokeWidth, tolerance: tolerance
                )
            case .effect(let effect):
                hit = AnnotationGeometry.shapeHit(
                    at: point, kind: .rectangle, rect: effect.rect, tolerance: tolerance
                ) != nil
            case .counter(let badge):
                hit = CounterGeometry.hits(
                    point, center: badge.center, radius: badge.radius, tolerance: tolerance
                )
            }
            if hit { return annotation }
        }
        return nil
    }

    private func viewPoint(fromImagePoint point: CGPoint) -> CGPoint {
        AnnotationGeometry.viewPoint(
            fromImagePoint: point, contentRect: canvasRect, fittedFrame: fittedFrame
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSGradient(starting: Self.backdropTop, ending: Self.backdropBottom)?
            .draw(in: bounds, angle: -90)

        layoutSnapshot = currentLayout()
        defer { layoutSnapshot = nil }
        guard let layout = layoutSnapshot else { return }
        let canvas = layout.canvas
        let frame = layout.frame
        guard frame.width > 0, frame.height > 0 else { return }

        drawCaptureShadow(around: frame, in: context)

        context.saveGState()
        context.interpolationQuality = .high
        // M-F: when the canvas has expanded past the image, fill the exposed
        // area with the single detected background color first (a plain fill —
        // no intermediate bitmap), then draw the base image at its position.
        if canvas != document.imageBounds, let background = document.canvasBackground {
            context.setFillColor(background.fillColor.cgColor)
            context.fill(frame)
        }
        context.draw(document.image, in: viewRect(fromImageRect: document.imageBounds))
        // Annotations render in image-pixel space through the shared renderer,
        // so the canvas is the export, just scaled — with the canvas origin
        // subtracted so a negative-origin canvas still lands correctly.
        context.translateBy(x: frame.minX, y: frame.minY)
        let scale = frame.width / canvas.width
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -canvas.minX, y: -canvas.minY)
        AnnotationRenderer.draw(renderedAnnotations(), in: context, base: document.image)
        context.restoreGState()

        drawCropOverlay(in: context)
        drawSelectionHandles(in: context)
    }

    /// The layout set: document annotations with the in-gesture draft
    /// substituted in (or appended, while drawing a new shape). Everything that
    /// decides the canvas rect reads this — including a label being edited.
    private func layoutAnnotations() -> [Annotation] {
        var annotations = document.annotations
        guard let draft else { return annotations }
        if let index = annotations.firstIndex(where: { $0.id == draft.id }) {
            annotations[index] = draft
            return annotations
        }
        return annotations + [draft]
    }

    /// The paint set: the layout set minus any label currently being edited in
    /// the overlay text field.
    private func renderedAnnotations() -> [Annotation] {
        var annotations = layoutAnnotations()
        if let editingTextID {
            annotations.removeAll { $0.id == editingTextID }
        }
        return annotations
    }

    /// A soft shadow lifting the capture off the backdrop. Cast by the frame
    /// rect but clipped to the area *outside* it, so it never shows through
    /// transparent pixels (a window capture's rounded corners) and costs no
    /// transparency layer per redraw.
    private func drawCaptureShadow(around frame: CGRect, in context: CGContext) {
        context.saveGState()
        context.addRect(bounds)
        context.addRect(frame)
        context.clip(using: .evenOdd)
        context.setShadow(
            offset: CGSize(width: 0, height: -8), blur: 28,
            color: Self.captureShadow.cgColor
        )
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(frame)
        context.restoreGState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func drawCropOverlay(in context: CGContext) {
        guard let cropDraft else { return }
        let viewRect = viewRect(fromImageRect: cropDraft)
        context.saveGState()
        // Dim everything outside the prospective crop, like the area overlay.
        context.setFillColor(CGColor(gray: 0, alpha: 0.45))
        context.beginPath()
        context.addRect(fittedFrame)
        context.addRect(viewRect)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(viewRect)
        context.restoreGState()
    }

    private func drawSelectionHandles(in context: CGContext) {
        guard let selected = selectedAnnotation() else { return }
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        let size = Self.handleDrawSize

        switch selected {
        case .shape, .effect:
            guard let viewRect = selectionViewRect() else { return }
            for handle in AnnotationGeometry.ResizeHandle.allCases {
                let p = AnnotationGeometry.handlePoint(handle, in: viewRect)
                let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                context.fill(rect)
                context.stroke(rect)
            }
        case .arrow(let arrow):
            // Arrows/lines get round endpoint handles instead of rect handles;
            // arrows add a third, visually distinct bend handle (accent-filled)
            // at the curve midpoint.
            for endpoint in [arrow.tail, arrow.head] {
                let p = viewPoint(fromImagePoint: endpoint)
                let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                context.fillEllipse(in: rect)
                context.strokeEllipse(in: rect)
            }
            if arrow.kind == .arrow {
                let p = viewPoint(fromImagePoint: ArrowGeometry.point(
                    onCurve: 0.5, tail: arrow.tail, head: arrow.head, bow: arrow.bow
                ))
                let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                context.saveGState()
                context.setFillColor(NSColor.controlAccentColor.cgColor)
                context.setStrokeColor(NSColor.white.cgColor)
                context.fillEllipse(in: rect)
                context.strokeEllipse(in: rect)
                context.restoreGState()
            }
        case .text, .freehand, .counter:
            // No resize affordance — a dashed outline marks the selection.
            // Accent dashes over a solid white line, so the outline reads on
            // any capture: the dashes on light content, the white gaps on dark
            // or accent-coloured content (accent alone was 1:1 on blue).
            guard let viewRect = selectionViewRect() else { return }
            let outline = viewRect.insetBy(dx: -3, dy: -3)
            context.saveGState()
            context.setStrokeColor(NSColor.white.cgColor)
            context.stroke(outline)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(outline)
            context.restoreGState()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The view→image transform just changed; keep an active label field on
        // the spot it edits.
        layoutTextField()
        needsDisplay = true
        onViewportChange?()
    }

    /// Fallback for the "tool-aware cursor" setting being OFF. When it is on,
    /// mouseMoved owns the cursor and no rects are registered — two systems
    /// setting the cursor for the same area flicker.
    override func resetCursorRects() {
        guard !settings.toolAwareCursorEnabled else { return }
        switch tool {
        case .shape, .arrow, .line, .freehand, .effect, .counter, .crop:
            addCursorRect(fittedFrame, cursor: .crosshair)
        case .text:
            addCursorRect(fittedFrame, cursor: .iBeam)
        case .select:
            break
        }
    }

    // MARK: - Tool-aware cursor

    private var currentCursorKind: CursorGeometry.CanvasCursorKind?
    private var cursorTrackingArea: NSTrackingArea?
    private var toolFlashLabel: NSTextField?
    private var toolFlashToken = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited,
                .cursorUpdate, .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        refreshCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        refreshCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard currentCursorKind != nil else { return }
        currentCursorKind = nil
        NSCursor.arrow.set()
    }

    /// AppKit re-evaluates the cursor whenever the view hierarchy or window
    /// chrome changes (toolbar redraw, flash label subview, rect
    /// invalidation) — with no cursor rects registered it would land on the
    /// arrow. Participating via `.cursorUpdate` lets us re-assert the right
    /// cursor instead; the kind cache is dropped so the set() is
    /// unconditional. When the feature is OFF, super handles the fallback
    /// cursor rects.
    override func cursorUpdate(with event: NSEvent) {
        guard settings.toolAwareCursorEnabled else {
            super.cursorUpdate(with: event)
            return
        }
        currentCursorKind = nil
        refreshCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Press feedback: the cursor a drag shows from mouse-down on (the open
    /// hand closes while an annotation is moved). Drags never recompute the
    /// cursor, so this sticks until mouse-up refreshes it.
    private func setPressedCursor(for kind: CursorGeometry.CanvasCursorKind) {
        guard settings.toolAwareCursorEnabled else { return }
        let pressed = CursorGeometry.pressed(kind)
        guard pressed != currentCursorKind else { return }
        currentCursorKind = pressed
        cursorFactory.cursor(for: pressed).set()
    }

    private func refreshCursorAtMouseLocation() {
        guard let window else { return }
        currentCursorKind = nil
        refreshCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Single owner of the pointer while the feature is enabled: decision in
    /// CursorGeometry, NSCursor construction in ToolCursorFactory, and a set()
    /// only when the kind actually changed. Not called during drags (the
    /// cursor persists) or while a label is being typed (the field editor
    /// owns the pointer).
    private func refreshCursor(at point: CGPoint) {
        guard case .none = drag else { return }
        guard textField == nil else { return }
        layoutSnapshot = currentLayout()
        defer { layoutSnapshot = nil }
        guard settings.toolAwareCursorEnabled else {
            // Turned off mid-session: hand the cursor back to cursor rects.
            if currentCursorKind != nil {
                currentCursorKind = nil
                NSCursor.arrow.set()
                window?.invalidateCursorRects(for: self)
            }
            return
        }
        let kind = CursorGeometry.cursor(
            tool: tool,
            isInsideCanvas: fittedFrame.contains(point),
            enabled: true,
            hover: hover(at: point)
        )
        guard kind != currentCursorKind else { return }
        currentCursorKind = kind
        cursorFactory.cursor(for: kind).set()
    }

    /// Hover for the select tool, mirroring mouseDown's priority: handles of
    /// the current selection win over annotation bodies.
    private func hover(at point: CGPoint) -> CursorGeometry.Hover {
        guard tool == .select else { return .none }
        switch selectionHandle(at: point) {
        case .resize(_, let handle): return .resizeHandle(handle)
        case .arrow: return .arrowHandle
        case nil: return annotation(at: point) != nil ? .annotation : .none
        }
    }

    /// A handle of the current selection under `point`, if any.
    private enum SelectionHandleHit {
        case resize(Annotation, AnnotationGeometry.ResizeHandle)
        case arrow(ArrowAnnotation, ArrowHandle)
    }

    /// The single handle hit-test for hover AND mouse-down, so the cursor
    /// always promises what a press will do: the 7 pt core always grabs the
    /// handle; the 7–10 pt ring only where it doesn't cover an annotation body.
    private func selectionHandle(at point: CGPoint) -> SelectionHandleHit? {
        func pick<H>(_ hit: (CGFloat) -> H?) -> H? {
            AnnotationGeometry.arbitrateHandle(
                core: hit(Self.handleCoreHitRadius),
                full: hit(Self.handleHitRadius),
                pointIsOnABody: annotation(at: point) != nil
            )
        }
        switch selectedAnnotation() {
        case let selected? where selected.isRectResizable:
            guard let viewRect = selectionViewRect() else { return nil }
            return pick { AnnotationGeometry.handleHit(at: point, rect: viewRect, radius: $0) }
                .map { .resize(selected, $0) }
        case .arrow(let arrow):
            let bend: CGPoint? = arrow.kind == .arrow
                ? viewPoint(fromImagePoint: ArrowGeometry.point(
                    onCurve: 0.5, tail: arrow.tail, head: arrow.head, bow: arrow.bow
                ))
                : nil
            let tail = viewPoint(fromImagePoint: arrow.tail)
            let head = viewPoint(fromImagePoint: arrow.head)
            return pick {
                ArrowGeometry.handleHit(at: point, tail: tail, head: head, bend: bend, radius: $0)
            }.map { .arrow(arrow, $0) }
        default:
            return nil
        }
    }

    /// Speaks the new tool's name for VoiceOver on a real tool switch — the
    /// flash is visual only, and only appears with the pointer over the image.
    private func announceTool() {
        guard let spec = EditorWindowController.toolSpec(for: tool) else { return }
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: spec.label,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// Briefly shows the new tool's name beside the cursor on a real tool
    /// switch (toolbar click or letter key), then fades it out.
    private func flashToolName() {
        guard settings.toolAwareCursorEnabled, let window,
              let spec = EditorWindowController.toolSpec(for: tool) else { return }
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard fittedFrame.contains(mouse) else { return }

        toolFlashLabel?.removeFromSuperview()
        let label = NSTextField(labelWithString: spec.label)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.85).cgColor
        label.layer?.cornerRadius = 4
        label.sizeToFit()
        var frame = label.frame.insetBy(dx: -6, dy: -2)
        frame.origin = CGPoint(x: mouse.x + 14, y: mouse.y - 20)
        frame.origin.x = min(frame.origin.x, bounds.maxX - frame.width - 4)
        frame.origin.y = max(frame.origin.y, 4)
        label.frame = frame
        addSubview(label)
        toolFlashLabel = label

        toolFlashToken += 1
        let token = toolFlashToken
        Task { @MainActor [weak self, weak label] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, let label, self.toolFlashToken == token else { return }
            // In an async context this resolves to the async overload, which
            // returns once the fade has completed.
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                label.animator().alphaValue = 0
            }
            label.removeFromSuperview()
            if self.toolFlashLabel === label { self.toolFlashLabel = nil }
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditing() // click-away commits an in-progress label
        let point = convert(event.locationInWindow, from: nil)
        // After the commit (it may change the document), before any geometry.
        layoutSnapshot = currentLayout()
        defer { layoutSnapshot = nil }

        // M-F gesture ratchet: freeze the pre-gesture canvas rect as the floor
        // so the canvas can only grow (never oscillate) while dragging, and
        // freeze the on-screen transform so the image stays put while the canvas
        // grows around it (no live zoom-out feedback — see gestureViewTransform).
        defer {
            if case .none = drag {
                gestureCanvasFloor = nil
                gestureViewTransform = nil
            } else {
                let floor = derivedCanvasRect(document.annotations)
                gestureCanvasFloor = floor
                let frame = AnnotationGeometry.fittedFrame(
                    contentRect: floor, in: fitBounds, margin: Self.canvasMargin
                )
                let scale = frame.width / max(floor.width, 1)
                gestureViewTransform = (
                    scale: scale,
                    imageOrigin: CGPoint(
                        x: frame.minX - floor.minX * scale,
                        y: frame.minY - floor.minY * scale
                    )
                )
            }
        }

        // Handles of the current selection win in every tool: rect handles
        // for shapes/effects, endpoint handles for arrows/lines.
        switch selectionHandle(at: point) {
        case .resize(let selected, let handle):
            drag = .resizing(original: selected, handle: handle, start: point)
            return
        case .arrow(let arrow, let handle):
            drag = .movingHandle(original: arrow, handle: handle)
            return
        case nil:
            break
        }

        switch tool {
        case .select:
            if let hit = annotation(at: point) {
                // Double-click re-opens a label for in-place editing.
                if event.clickCount == 2, case .text(let text) = hit {
                    beginTextEditing(existing: text, clickImagePoint: text.origin)
                    return
                }
                select(hit.id)
                drag = .moving(original: hit, start: point)
                setPressedCursor(for: .move)
            } else {
                select(nil)
            }
        case .shape:
            drag = .drawing(anchor: imagePoint(fromViewPoint: point), id: UUID())
        case .arrow:
            drag = .drawingArrow(anchor: imagePoint(fromViewPoint: point), id: UUID(), kind: .arrow)
        case .line:
            drag = .drawingArrow(anchor: imagePoint(fromViewPoint: point), id: UUID(), kind: .line)
        case .text:
            // Clicking an existing label edits it; empty canvas starts a new one.
            if case .text(let text)? = annotation(at: point) {
                beginTextEditing(existing: text, clickImagePoint: text.origin)
            } else {
                beginTextEditing(existing: nil, clickImagePoint: imagePoint(fromViewPoint: point))
            }
        case .freehand:
            let id = UUID()
            drag = .drawingFreehand(id: id)
            draft = .freehand(FreehandAnnotation(
                id: id, points: [imagePoint(fromViewPoint: point)], style: currentStyle
            ))
        case .effect(let kind):
            drag = .drawingEffect(anchor: imagePoint(fromViewPoint: point), id: UUID(), kind: kind)
        case .counter:
            let id = UUID()
            drag = .placingCounter(id: id)
            draft = .counter(CounterAnnotation(
                id: id, center: imagePoint(fromViewPoint: point), style: currentStyle
            ))
            needsDisplay = true
        case .crop:
            // Crop stays inside the base image (no cropping into generated
            // background); clamp the anchor.
            drag = .cropping(anchor: clampedToImage(imagePoint(fromViewPoint: point)))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The draft only changes at the end of each case, so one layout serves
        // every conversion in this event.
        layoutSnapshot = currentLayout()
        defer { layoutSnapshot = nil }

        switch drag {
        case .none:
            return

        case .drawing(let anchor, let id):
            guard case .shape(let kind) = tool else { return }
            let current = imagePoint(fromViewPoint: point)
            draft = .shape(ShapeAnnotation(
                id: id, kind: kind, rect: rect(from: anchor, to: current), style: currentStyle
            ))

        case .drawingArrow(let anchor, let id, let kind):
            draft = .arrow(ArrowAnnotation(
                id: id, tail: anchor, head: imagePoint(fromViewPoint: point),
                style: currentStyle, kind: kind
            ))

        case .drawingFreehand:
            guard case .freehand(var stroke)? = draft else { return }
            let current = imagePoint(fromViewPoint: point)
            let minDistance = AnnotationGeometry.imageLength(
                fromViewLength: FreehandGeometry.minSampleDistanceInView,
                contentRect: canvasRect, fittedFrame: fittedFrame
            )
            if let last = stroke.points.last,
               hypot(current.x - last.x, current.y - last.y) < minDistance {
                return
            }
            stroke.points.append(current)
            draft = .freehand(stroke)

        case .drawingEffect(let anchor, let id, let kind):
            let current = imagePoint(fromViewPoint: point)
            draft = .effect(EffectAnnotation(
                id: id, kind: kind, rect: rect(from: anchor, to: current), style: currentStyle
            ))

        case .placingCounter:
            guard case .counter(var badge)? = draft else { return }
            badge.center = imagePoint(fromViewPoint: point)
            draft = .counter(badge)

        case .cropping(let anchor):
            cropDraft = rect(from: anchor, to: clampedToImage(imagePoint(fromViewPoint: point)))

        case .movingHandle(let original, let handle):
            let p = imagePoint(fromViewPoint: point)
            switch handle {
            case .tail, .head:
                draft = .arrow(original.movingEndpoint(handle, to: p))
            case .bend:
                // Perpendicular projection only (1 DOF) with a snap-to-straight
                // zone — see ArrowGeometry.snappedBow.
                draft = .arrow(original.withBow(
                    ArrowGeometry.snappedBow(forDragPoint: p, tail: original.tail, head: original.head)
                ))
            }

        case .moving(let original, let start):
            // M-F: unclamped — annotations may be moved outside the image; the
            // canvas expands to follow.
            let delta = imageDelta(fromViewStart: start, to: point)
            draft = original.offset(by: delta)

        case .resizing(let original, let handle, let start):
            // M-F: no image-bounds intersection — a shape/effect can be resized
            // past the image edge (keep the non-empty guard).
            let delta = imageDelta(fromViewStart: start, to: point)
            let resized = AnnotationGeometry.resized(
                original.boundingRect, dragging: handle, by: delta
            )
            guard !resized.isEmpty else { return }
            draft = original.withRect(resized)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            drag = .none
            draft = nil
            cropDraft = nil
            gestureCanvasFloor = nil // release the ratchet: canvas may shrink now
            gestureViewTransform = nil // re-fit the final canvas once
            needsDisplay = true
            // The document change inside this handler read the still-frozen
            // transform; the zoom readout must follow the re-fit.
            onViewportChange?()
            // Drop the pressed cursor and match what is under the pointer now
            // (a new selection's handles, the re-fitted canvas).
            refreshCursorAtMouseLocation()
        }

        switch drag {
        case .none:
            break

        case .drawing:
            if case .shape(let shape)? = draft,
               shape.rect.width >= Self.minShapeSize, shape.rect.height >= Self.minShapeSize {
                document.add(.shape(shape))
                select(shape.id)
            } else {
                // Tiny drag = a click: select whatever is under the cursor.
                select(annotation(at: point)?.id)
            }

        case .drawingArrow:
            if case .arrow(let arrow)? = draft,
               hypot(arrow.head.x - arrow.tail.x, arrow.head.y - arrow.tail.y) >= Self.minArrowLength {
                document.add(.arrow(arrow))
                select(arrow.id)
            } else {
                select(annotation(at: point)?.id)
            }

        case .drawingFreehand:
            if case .freehand(let stroke)? = draft, stroke.points.count >= 2 {
                document.add(.freehand(stroke))
                select(stroke.id)
            } else {
                select(annotation(at: point)?.id)
            }

        case .drawingEffect:
            if case .effect(let effect)? = draft,
               effect.rect.width >= Self.minShapeSize, effect.rect.height >= Self.minShapeSize {
                document.add(.effect(effect))
                select(effect.id)
            } else {
                select(annotation(at: point)?.id)
            }

        case .placingCounter:
            if case .counter(let badge)? = draft {
                document.add(.counter(badge))
                select(badge.id)
            }

        case .cropping:
            if let cropDraft,
               cropDraft.width >= Self.minCropSize, cropDraft.height >= Self.minCropSize {
                select(nil)
                document.crop(to: cropDraft)
                onCommand?(.selectTool(.select))
            }

        case .moving(let original, let start):
            guard hypot(point.x - start.x, point.y - start.y) >= Self.clickDragThreshold,
                  let draft else { break }
            document.replace(id: original.id, with: draft)

        case .resizing(let original, _, _):
            guard let draft else { break }
            document.replace(id: original.id, with: draft)

        case .movingHandle(let original, _):
            guard let draft else { break }
            document.replace(id: original.id, with: draft)
        }
    }

    private func rect(from anchor: CGPoint, to point: CGPoint) -> CGRect {
        CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
    }

    // MARK: - In-place text editing (M6)

    private func beginTextEditing(existing: TextAnnotation?, clickImagePoint: CGPoint) {
        commitTextEditing()
        select(nil)
        // The controls follow the label being edited (select(nil) just reset
        // them to the creation style).
        if let existing { onSelectionChange?(.text(existing)) }

        let style = existing?.style ?? currentStyle
        let field = NSTextField(string: existing?.text ?? "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .exterior
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldCommitted)

        addSubview(field)
        textField = field
        editingTextID = existing?.id
        editingTextStyle = style
        pendingTextAnchor = existing == nil ? clickImagePoint : nil
        textFieldAnchor = existing.map { ($0.origin, false) } ?? (clickImagePoint, true)
        layoutTextField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// Font, colour and frame of the overlay field from the current editing
    /// style and view transform. No-op without an active field.
    private func layoutTextField() {
        guard let field = textField, let anchor = textFieldAnchor else { return }
        let style = editingTextStyle ?? currentStyle
        let layout = layoutSnapshot ?? currentLayout()
        let viewScale = layout.frame.width / max(layout.canvas.width, 1)
        let viewFontSize = max(9, TextGeometry.fontSize(strokeWidth: style.strokeWidth) * viewScale)
        let font = NSFont.systemFont(ofSize: viewFontSize)
        field.font = font
        let c = style.strokeColor
        field.textColor = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)

        let height = ceil(font.ascender - font.descender) + 4
        let p = AnnotationGeometry.viewPoint(
            fromImagePoint: anchor.point, contentRect: layout.canvas, fittedFrame: layout.frame
        )
        let originView = anchor.isTopLeft ? CGPoint(x: p.x, y: p.y - height) : p
        field.frame = CGRect(
            x: originView.x - 2,
            y: originView.y - 2,
            width: max(120, layout.frame.maxX - originView.x + 2),
            height: height
        )
    }

    /// Commits the overlay field into the document: one undo step for a new
    /// or changed label, removal when an existing label is emptied. Idempotent.
    private func commitTextEditing() {
        guard let field = textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedID = editingTextID
        let style = editingTextStyle ?? currentStyle
        let anchor = pendingTextAnchor
        endTextEditing()

        if let editedID {
            guard case .text(var existing)? = document.annotation(id: editedID) else { return }
            if text.isEmpty {
                document.remove(id: editedID)
            } else if text != existing.text || style != existing.style {
                existing.text = text
                existing.style = style // picked up from a mid-typing style change
                document.replace(id: editedID, with: .text(existing))
                select(editedID)
            } else {
                select(editedID)
            }
        } else if !text.isEmpty, let anchor {
            let fontSize = TextGeometry.fontSize(strokeWidth: style.strokeWidth)
            let height = TextGeometry.measure(text, fontSize: fontSize).size.height
            let annotation = TextAnnotation(
                id: UUID(),
                origin: CGPoint(x: anchor.x, y: anchor.y - height),
                text: text,
                style: style
            )
            document.add(.text(annotation))
            select(annotation.id)
        }
    }

    private func cancelTextEditing() {
        guard textField != nil else { return }
        endTextEditing()
    }

    private func endTextEditing() {
        guard let field = textField else { return }
        textField = nil
        editingTextID = nil
        editingTextStyle = nil
        pendingTextAnchor = nil
        textFieldAnchor = nil
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        // Editing over: controls describe the selection again, or — with none —
        // the style the next annotation will get.
        onSelectionChange?(selectedAnnotation())
        needsDisplay = true
    }

    @objc private func textFieldCommitted() {
        commitTextEditing()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            if let selectedID {
                let id = selectedID
                select(nil)
                document.remove(id: id)
            }
        case 53: // Esc deselects; with nothing selected it closes the editor
            if selectedID != nil {
                select(nil)
            } else {
                onCommand?(.close)
            }
        default:
            // Single-letter shortcuts (no modifiers): tools, Q closes.
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if ShortcutKeys.isBareKey(event.modifierFlags), let tool = Self.toolShortcuts[key] {
                onCommand?(.selectTool(tool))
            } else if ShortcutKeys.isBareKey(event.modifierFlags), key == "q" {
                onCommand?(.close)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Tool shortcuts, advertised (uppercase) in the toolbar tooltips.
    private static let toolShortcuts: [String: EditorTool] = [
        "v": .select,
        "r": .shape(.rectangle),
        "o": .shape(.oval),
        "a": .arrow,
        "l": .line,
        "p": .freehand,
        "t": .text,
        "b": .effect(.blur),
        "x": .effect(.pixelate),
        "n": .counter,
        "c": .crop,
    ]

    // The app has no main menu (LSUIElement), so ⌘-shortcuts arrive here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While a label is being typed, leave every key to the field editor.
        guard textField == nil else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch (event.charactersIgnoringModifiers?.lowercased(), flags.contains(.shift)) {
        case ("z", false):
            document.undoManager.undo()
            return true
        case ("z", true):
            document.undoManager.redo()
            return true
        case ("c", _): // ⇧⌘C is the advertised Copy shortcut; plain ⌘C also works
            onCommand?(.copy)
            return true
        case ("s", false):
            onCommand?(.save)
            return true
        case ("p", false):
            onCommand?(.pin)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - Text field delegate (in-place label editing)

extension AnnotationCanvasView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        // Fires on Enter and on click-away — commit either way (idempotent).
        commitTextEditing()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }
}

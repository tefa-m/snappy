import CoreGraphics
import Foundation

/// What a stroke's points are relative to (`features/recording.md`, Q13/Q16).
enum InkAnchor: Equatable, Sendable {
    /// AppKit-global points. Stays at its screen position when the rect changes.
    case screen
    /// Offsets from the window's top-left corner (AppKit y-up: `minX`, `maxY`),
    /// so the stroke follows the window as it moves — and keeps its place
    /// against the window's content when its bottom-right corner is dragged.
    case window(CGWindowID)
}

/// One live annotation — PURE value. Points are in its anchor's space; pen and
/// highlighter keep every (thinned) drag point, the other tools keep exactly
/// two: where the drag started and where it is now (arrow tail → head, shape
/// corner → corner).
struct InkStroke: Equatable, Identifiable, Sendable {
    let id: UUID
    let tool: InkTool
    var points: [CGPoint]
    let color: InkColorPreset
    let width: InkWidth
    let anchor: InkAnchor
    /// Drawn in Setup (or the countdown): permanent, kept for Retake (Q16/Q19).
    let isSetup: Bool
    /// Fades after the fade delay: a recorded stroke drawn with fading on.
    let fades: Bool
    /// Host-clock seconds (`CACurrentMediaTime`, the SCK clock) the stroke was
    /// **finished** — the fade delay counts from mouse-up, so a long pen
    /// stroke doesn't start fading while it is still being drawn. The draft
    /// has none.
    var createdAt: TimeInterval?
    /// A Magic Pen stroke: a pen stroke drawn in `MagicPenLook` at
    /// `width.magicPenPoints`; always recorded, always fading (`color` is
    /// kept but not drawn).
    var isMagicPen = false
}

/// Setup ink handed back on Retake (Q19): the setup strokes as they were when
/// recording started, plus the window frames their anchors need.
struct InkSetupSnapshot: LiveInkSetupSnapshot, Equatable {
    let strokes: [InkStroke]
    let windowFrames: [CGWindowID: CGRect]
}

/// The live-ink model of one recording session — PURE, unit-tested. Owned by
/// `LiveInkPanel` on the main actor; the view and the compositor only ever
/// read its immutable `scene`.
///
/// - **Setup vs recorded** (Q16): strokes begun before capture are permanent
///   setup annotations; strokes begun while capturing fade when the style says
///   so (`fades`, fixed per stroke).
/// - **Anchoring:** a stroke drawn while the target is a window is anchored
///   to that window (W mode, window coordinates); otherwise to the screen.
///   Window frames are learned from the target as it moves (T2's
///   `onWindowFrameChange` arrives through `session.target`).
/// - **Clipping:** nothing is deleted when the rect changes; strokes outside
///   the target are just not rendered (`InkScene.renderItems`) — for W +
///   part, outside the part, though they stay anchored to its window (Q42).
/// - **Undo/redo:** whole-list snapshots, one step per stroke or clear.
///   Expired (fully faded) strokes are pruned from the list *and* the history
///   (also before every content command), so ⌘Z never "undoes" something invisible.
struct LiveInk: Equatable, Sendable {
    private(set) var strokes: [InkStroke]
    private(set) var draft: InkStroke?
    /// Last known AppKit-global frame per window an anchor refers to.
    private(set) var windowFrames: [CGWindowID: CGRect]
    /// The window the current target records, if any.
    private(set) var targetWindowID: CGWindowID?
    /// Seconds a fading stroke stays fully visible (Settings → Fade delay).
    let fadeDelay: TimeInterval
    /// The setup strokes at the first capture — what Retake restores.
    private var setupAtCapture: [InkStroke]?
    private var undoStack: [[InkStroke]] = []
    private var redoStack: [[InkStroke]] = []

    /// After the fade delay a fading stroke fades out over this long.
    static let fadeDuration: TimeInterval = 0.6
    /// The highlighter's fixed opacity (Q25) — it also ignores the width.
    static let highlighterAlpha: CGFloat = 0.4
    /// Pen/highlighter thinning: minimum distance between kept points (pt),
    /// the editor's `FreehandGeometry` sampling distance.
    static let minSampleDistance = FreehandGeometry.minSampleDistanceInView
    /// Strokes smaller than this (pt) are a click, not a drawing: discarded.
    static let minExtent: CGFloat = 3

    init(fadeDelay: TimeInterval, restoring snapshot: InkSetupSnapshot? = nil) {
        self.fadeDelay = fadeDelay
        strokes = snapshot?.strokes ?? []
        windowFrames = snapshot?.windowFrames ?? [:]
    }

    // MARK: - Fading

    /// Opacity of a fading stroke `age` seconds after it was finished: 1 for
    /// the fade delay, then linear down to 0 over `fadeDuration`.
    static func fadeAlpha(age: TimeInterval, delay: TimeInterval) -> CGFloat {
        let remaining = delay + fadeDuration - age
        return CGFloat(min(1, max(0, remaining / fadeDuration)))
    }

    /// Opacity of `stroke` at host time `now` (before any highlighter alpha).
    static func alpha(of stroke: InkStroke, at now: TimeInterval, fadeDelay: TimeInterval) -> CGFloat {
        guard stroke.fades, let createdAt = stroke.createdAt else { return 1 }
        return fadeAlpha(age: now - createdAt, delay: fadeDelay)
    }

    func alpha(of stroke: InkStroke, at now: TimeInterval) -> CGFloat {
        Self.alpha(of: stroke, at: now, fadeDelay: fadeDelay)
    }

    /// When the on-screen ink next needs a fade redraw: 0 while a stroke is
    /// fading (or has expired and awaits `pruneExpired`), else the seconds
    /// until the first fade starts; nil when nothing fades — the panel's fade
    /// timer sleeps through the hold and stops once everything has faded.
    func nextFadeRedraw(at now: TimeInterval) -> TimeInterval? {
        strokes.compactMap { stroke -> TimeInterval? in
            guard stroke.fades, let createdAt = stroke.createdAt else { return nil }
            return max(0, createdAt + fadeDelay - now)
        }.min()
    }

    /// Drops fully faded strokes from the list **and** the undo/redo history —
    /// including strokes that only live in a history step (cleared or undone
    /// before they faded) — then collapses steps that no longer change
    /// anything. Runs on every fade tick and before every content command, so
    /// ⌘Z/⇧⌘Z never restore something invisible even after the fade timer has
    /// stopped. Returns whether anything changed.
    @discardableResult
    mutating func pruneExpired(at now: TimeInterval) -> Bool {
        let all = strokes + undoStack.joined() + redoStack.joined()
        let expired = Set(all.filter { $0.fades && alpha(of: $0, at: now) <= 0 }.map(\.id))
        guard !expired.isEmpty else { return false }
        func keep(_ list: [InkStroke]) -> [InkStroke] { list.filter { !expired.contains($0.id) } }
        strokes = keep(strokes)
        undoStack = Self.collapsed(undoStack.map(keep), above: strokes)
        redoStack = Self.collapsed(redoStack.map(keep), above: strokes)
        return true
    }

    /// Removes history steps that no longer change anything: entries equal to
    /// their neighbour towards `current` (the top of the stack is nearest).
    private static func collapsed(_ stack: [[InkStroke]], above current: [InkStroke]) -> [[InkStroke]] {
        var result: [[InkStroke]] = []
        var next = current
        for entry in stack.reversed() where entry != next {
            result.append(entry)
            next = entry
        }
        return result.reversed()
    }

    // MARK: - Target

    /// Follows the session's target: remembers a window's frame (anchors
    /// resolve against it) and whether new strokes anchor to a window.
    mutating func setTarget(_ target: RecordingTarget) {
        targetWindowID = target.windowID
        // The window's frame, also for a window part (Q42: ink is anchored
        // to the window, never to the part).
        if let id = target.windowID { windowFrames[id] = target.windowFrame ?? target.frame }
    }

    /// The anchor a stroke begun now gets.
    var currentAnchor: InkAnchor {
        targetWindowID.map(InkAnchor.window) ?? .screen
    }

    /// Anchor space → AppKit global, for a window anchor at `windowFrame`.
    static func globalPoint(_ point: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x + windowFrame.minX, y: point.y + windowFrame.maxY)
    }

    /// AppKit global → the space of `anchor` at the current window frame.
    private func localPoint(_ point: CGPoint, anchor: InkAnchor) -> CGPoint {
        guard case .window(let id) = anchor, let frame = windowFrames[id] else { return point }
        return CGPoint(x: point.x - frame.minX, y: point.y - frame.maxY)
    }

    // MARK: - Drawing

    /// Starts the draft at a global point. `isCapturing` decides setup vs
    /// recorded; a recorded stroke fades when `style.fading` is on.
    mutating func beginStroke(tool: InkTool, at point: CGPoint, style: InkStyle, isCapturing: Bool) {
        let anchor = currentAnchor
        draft = InkStroke(
            id: UUID(), tool: tool, points: [localPoint(point, anchor: anchor)],
            color: style.color, width: style.width, anchor: anchor,
            isSetup: !isCapturing, fades: isCapturing && style.fading, createdAt: nil
        )
    }

    /// Starts a Magic Pen draft (Magic Pen mode, only while recording): a
    /// pen stroke that always fades, never a setup annotation, whatever
    /// `style.fading` says. Its width is `style.magicPenWidth`.
    mutating func beginMagicPenStroke(at point: CGPoint, style: InkStyle) {
        let anchor = currentAnchor
        draft = InkStroke(
            id: UUID(), tool: .pen, points: [localPoint(point, anchor: anchor)],
            color: style.color, width: style.magicPenWidth, anchor: anchor,
            isSetup: false, fades: true, createdAt: nil, isMagicPen: true
        )
    }

    /// Extends the draft to a global point: pen/highlighter append (thinned),
    /// the two-point tools move their end.
    mutating func extendStroke(to point: CGPoint) {
        guard var stroke = draft else { return }
        let local = localPoint(point, anchor: stroke.anchor)
        switch stroke.tool {
        case .pen, .highlighter:
            let spacing = stroke.isMagicPen ? MagicPenLook.minSampleDistance : Self.minSampleDistance
            if let last = stroke.points.last,
               hypot(local.x - last.x, local.y - last.y) < spacing { return }
            stroke.points.append(local)
        case .arrow, .oval, .box:
            stroke.points = [stroke.points[0], local]
        }
        draft = stroke
    }

    /// Commits the draft as one undo step, stamped with `now`. A click without
    /// a real drag is discarded. Returns whether a stroke was added.
    @discardableResult
    mutating func endStroke(at now: TimeInterval) -> Bool {
        guard var stroke = draft else { return false }
        draft = nil
        guard Self.isDrawn(stroke) else { return false }
        stroke.createdAt = now
        record()
        strokes.append(stroke)
        return true
    }

    mutating func cancelStroke() {
        draft = nil
    }

    /// Whether a finished drag drew something visible.
    static func isDrawn(_ stroke: InkStroke) -> Bool {
        guard let first = stroke.points.first, let last = stroke.points.last, stroke.points.count >= 2 else {
            return false
        }
        switch stroke.tool {
        case .pen, .highlighter:
            let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
            return max(xs.max()! - xs.min()!, ys.max()! - ys.min()!) >= minExtent
        case .arrow:
            return hypot(last.x - first.x, last.y - first.y) >= minExtent
        case .oval, .box:
            return abs(last.x - first.x) >= minExtent && abs(last.y - first.y) >= minExtent
        }
    }

    // MARK: - Content commands

    /// ⌫ — removes setup and recorded strokes alike (one undo step).
    /// Content commands take the host time so expired strokes are pruned
    /// first (`pruneExpired`).
    @discardableResult
    mutating func clear(at now: TimeInterval) -> Bool {
        draft = nil
        pruneExpired(at: now)
        guard !strokes.isEmpty else { return false }
        record()
        strokes = []
        return true
    }

    @discardableResult
    mutating func undo(at now: TimeInterval) -> Bool {
        pruneExpired(at: now)
        guard let previous = undoStack.popLast() else { return false }
        draft = nil
        redoStack.append(strokes)
        strokes = previous
        return true
    }

    @discardableResult
    mutating func redo(at now: TimeInterval) -> Bool {
        pruneExpired(at: now)
        guard let next = redoStack.popLast() else { return false }
        draft = nil
        undoStack.append(strokes)
        strokes = next
        return true
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private mutating func record() {
        undoStack.append(strokes)
        redoStack.removeAll()
    }

    // MARK: - Retake

    /// Call when the session starts capturing: freezes the setup strokes Retake
    /// restores, so clearing during the take doesn't lose them. Only the first
    /// call counts.
    mutating func captureDidBegin() {
        if setupAtCapture == nil { setupAtCapture = strokes.filter(\.isSetup) }
    }

    /// The setup ink for Retake: as it was when capture began, or the current
    /// setup strokes if it never did.
    var setupSnapshot: InkSetupSnapshot {
        let setup = setupAtCapture ?? strokes.filter(\.isSetup)
        var frames: [CGWindowID: CGRect] = [:]
        for case .window(let id) in setup.map(\.anchor) { frames[id] = windowFrames[id] }
        return InkSetupSnapshot(strokes: setup, windowFrames: frames)
    }

    // MARK: - Rendering input

    /// The immutable value the view and the compositor draw.
    var scene: InkScene {
        InkScene(
            strokes: draft.map { strokes + [$0] } ?? strokes,
            windowFrames: windowFrames, targetWindowID: targetWindowID, fadeDelay: fadeDelay
        )
    }
}

/// One drawable stroke, resolved to AppKit-global points as an editor
/// `Annotation` (so `AnnotationRenderer` draws it) plus its opacity.
struct InkRenderItem: Equatable, Sendable {
    let annotation: Annotation
    /// Fade × highlighter / Magic Pen opacity, 0…1.
    let alpha: CGFloat
    /// Drawn first, under `annotation`, in the same transparency layer —
    /// the Magic Pen's soft halo; nil for every other stroke.
    var underlay: Annotation?

    /// What the item paints: the stroke and its halo.
    var paintedBounds: CGRect {
        underlay.map { annotation.expandedBounds.union($0.expandedBounds) } ?? annotation.expandedBounds
    }
}

/// Immutable render input — PURE, `Sendable`: the main actor builds it from
/// `LiveInk`, the compositor reads it on the capture queue. Both draw it with
/// `InkRenderer`, so the canvas and the video are one code path.
struct InkScene: Equatable, Sendable {
    var strokes: [InkStroke] = []
    var windowFrames: [CGWindowID: CGRect] = [:]
    var targetWindowID: CGWindowID?
    var fadeDelay: TimeInterval = 3

    static let empty = InkScene()

    /// What to draw at host time `time` for a target at `targetFrame` (AppKit
    /// global): strokes anchored to the target's window follow `windowFrame`
    /// — the window of *this* video frame, which may be newer than the
    /// model's; `targetFrame` itself when nil (W: the target is the window) —
    /// other window anchors use their last known frame. For W + part,
    /// `targetFrame` is the part and `windowFrame` its window: the ink stays
    /// on the window's content (Q42). Fully faded strokes and strokes wholly
    /// outside the target are left out — hidden, not deleted.
    func renderItems(time: TimeInterval, targetFrame: CGRect, windowFrame: CGRect? = nil) -> [InkRenderItem] {
        strokes.compactMap { stroke in
            var alpha = LiveInk.alpha(of: stroke, at: time, fadeDelay: fadeDelay)
            if stroke.isMagicPen {
                alpha *= MagicPenLook.alpha
            } else if stroke.tool == .highlighter {
                alpha *= LiveInk.highlighterAlpha
            }
            guard alpha > 0 else { return nil }
            var points = stroke.points
            if case .window(let id) = stroke.anchor {
                let targetWindow = windowFrame ?? targetFrame
                guard let frame = id == targetWindowID ? targetWindow : windowFrames[id] else { return nil }
                points = points.map { LiveInk.globalPoint($0, windowFrame: frame) }
            }
            guard let annotation = Self.annotation(for: stroke, points: points) else { return nil }
            let item = InkRenderItem(
                annotation: annotation, alpha: alpha,
                underlay: stroke.isMagicPen ? Self.magicPenHalo(for: stroke, points: points) : nil
            )
            guard item.paintedBounds.intersects(targetFrame) else { return nil }
            return item
        }
    }

    /// The Magic Pen's soft halo: the same smoothed path, wider and dark.
    static func magicPenHalo(for stroke: InkStroke, points: [CGPoint]) -> Annotation {
        let style = AnnotationStyle(
            strokeColor: MagicPenLook.haloColor,
            strokeWidth: stroke.width.magicPenPoints + MagicPenLook.haloExtraWidth, hasFill: false
        )
        return .freehand(FreehandAnnotation(id: stroke.id, points: points, style: style))
    }

    /// Maps a stroke (already in global points) to the editor annotation that
    /// draws it: pen/highlighter → freehand, arrow → tapered arrow, oval →
    /// oval, box → rectangle. Widths are points; the caller's CTM scales them.
    static func annotation(for stroke: InkStroke, points: [CGPoint]) -> Annotation? {
        guard let first = points.first, let last = points.last else { return nil }
        let width: CGFloat
        if stroke.isMagicPen {
            width = stroke.width.magicPenPoints
        } else {
            width = stroke.tool == .highlighter ? InkWidth.thick.points : stroke.width.points
        }
        let color = stroke.isMagicPen ? MagicPenLook.color : stroke.color.color
        let style = AnnotationStyle(strokeColor: color, strokeWidth: width, hasFill: false)
        let rect = CGRect(x: first.x, y: first.y, width: last.x - first.x, height: last.y - first.y).standardized
        switch stroke.tool {
        case .pen, .highlighter:
            return .freehand(FreehandAnnotation(id: stroke.id, points: points, style: style))
        case .arrow:
            return .arrow(ArrowAnnotation(id: stroke.id, tail: first, head: last, style: style))
        case .oval:
            return .shape(ShapeAnnotation(id: stroke.id, kind: .oval, rect: rect, style: style))
        case .box:
            return .shape(ShapeAnnotation(id: stroke.id, kind: .rectangle, rect: rect, style: style))
        }
    }
}

/// PURE mouse/keyboard policy of the ink panel — tested.
enum LiveInkFocus {
    enum Change: Equatable {
        /// Become key (entering draw mode).
        case take
        /// Give the keyboard back to the user's app if key.
        case resign
        case keep
    }

    /// The panel takes the mouse only with a tool picked; otherwise clicks go
    /// through to the Setup overlay (pointer) or the user's app (interact).
    static func takesMouse(_ mode: InkMode) -> Bool {
        switch mode {
        case .tool, .magicPen: true
        case .pointer, .interact: false
        }
    }

    /// Key status on a phase change: take it on entering draw mode or Magic
    /// Pen (keep it between the two); give it up in every phase whose key
    /// table is empty (interact, stopping, ended), so typing reaches the
    /// user's app (Q2/Q15); otherwise leave it alone.
    static func change(from previous: RecordingPhase?, to phase: RecordingPhase) -> Change {
        switch phase {
        case .recording(.draw), .recording(.magicPen):
            if case .recording(let mode) = previous, mode.isDrawing { return .keep }
            return .take
        case .recording(.interact), .stopping, .finished, .cancelled:
            return .resign
        case .setup, .snapping, .countdown:
            return .keep
        }
    }
}

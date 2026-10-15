import CoreGraphics

/// PURE geometry of a W + part recording (v2 V3, Q37) — unit-tested.
///
/// The window's own stream (`SCContentFilter(desktopIndependentWindow:)`) is
/// cropped to the part by ScreenCaptureKit itself: `SCStreamConfiguration
/// .sourceRect` on a window filter is in **window-local points, origin
/// top-left, y down**, and `SCStream.updateConfiguration` moves it live
/// (verified on macOS 26, see `docs/ARCHITECTURE.md` › Recording). So the
/// crop is a rect *in the window*: a moving window needs no update, only the
/// part changing inside it does.
enum PartCropGeometry {
    /// `part` (AppKit global) in the window at `window` (AppKit global) →
    /// window-local, top-left origin — `sourceRect` space.
    static func local(_ part: CGRect, in window: CGRect) -> CGRect {
        CGRect(x: part.minX - window.minX, y: window.maxY - part.maxY, width: part.width, height: part.height)
    }

    /// The inverse of `local`: a window-local rect back in AppKit global
    /// points, for the window at `window`.
    static func global(_ local: CGRect, in window: CGRect) -> CGRect {
        CGRect(x: window.minX + local.minX, y: window.maxY - local.maxY, width: local.width, height: local.height)
    }

    /// What ScreenCaptureKit records of a window of `windowSize` (points) for
    /// the part at `local`: clamped to the window — a source rect reaching
    /// outside it is clipped by SCK and the rest *stretched* into the frame,
    /// which would put the ink off — then on the pixel grid with even pixel
    /// sides (the odd pixel trimmed at the far edge, like an area's
    /// `sourceRect`), so a part of its starting size fills the video exactly
    /// at 1:1. The whole window when nothing of the part lies inside it.
    static func sourceRect(_ local: CGRect, windowSize: CGSize, scale: CGFloat) -> CGRect {
        let bounds = CGRect(origin: .zero, size: windowSize)
        var clamped = local.standardized.intersection(bounds)
        if clamped.isNull || clamped.width <= 0 || clamped.height <= 0 { clamped = bounds }
        let scale = scale > 0 ? scale : 1
        let x = OutputGeometry.evenSpan(from: clamped.minX * scale, to: clamped.maxX * scale, limit: windowSize.width * scale)
        let y = OutputGeometry.evenSpan(from: clamped.minY * scale, to: clamped.maxY * scale, limit: windowSize.height * scale)
        return CGRect(
            x: CGFloat(x.start) / scale, y: CGFloat(y.start) / scale,
            width: CGFloat(x.length) / scale, height: CGFloat(y.length) / scale
        )
    }
}

/// PURE live tracking of a W + part crop — unit-tested. The pipeline feeds it
/// the window's tracked frame (`WindowTracker`, 30 Hz) and the part's polled
/// Accessibility frame (~10 Hz); it answers what `sourceRect` SCK should
/// record now.
///
/// **One sample = the part's frame plus the window's frame around it.** Both
/// are AppKit global, but they come from two sources at slightly different
/// moments (an AX read on its executor, a window-server lookup). While the
/// window is being dragged, the difference would read as the part moving
/// inside it and make the crop jitter. So a sample counts only when the
/// window was on screen **at the same frame just before and just after** the
/// AX read; otherwise it is dropped, and the crop — window-local — simply
/// rides along with the window until it is at rest again.
///
/// - **Part gone** (nil frame: tab closed, navigated, or the app doesn't
///   answer): the **last rect** is kept (Q37).
/// - **Window off screen** (minimised, other Space, hidden): samples are
///   dropped; the recording holds its last frame like W (Q44).
/// - **Window resized**: the part's rect is kept until a sample says
///   otherwise, but re-clamped to the new size at once.
struct PartCropTracker: Equatable, Sendable {
    /// The display's backing scale at the start — the pixel grid of the crop.
    let scale: CGFloat
    /// The part as last seen, window-local, **unclamped** (a window that
    /// shrinks and grows back gets the same crop back).
    private(set) var part: CGRect
    /// The window's size as last tracked, points.
    private(set) var windowSize: CGSize

    /// `part` and `window` are AppKit global, from the same moment (the
    /// target's part and window frames).
    init(part: CGRect, window: CGRect, scale: CGFloat) {
        self.scale = scale
        self.part = PartCropGeometry.local(part.standardized, in: window.standardized)
        windowSize = window.standardized.size
    }

    /// What SCK records now: window-local, top-left origin, points.
    var sourceRect: CGRect {
        PartCropGeometry.sourceRect(part, windowSize: windowSize, scale: scale)
    }

    /// One poll: the part's AX frame (nil = gone or no answer) between two
    /// looks at its window. True when `sourceRect` changed.
    @discardableResult
    mutating func observe(part frame: CGRect?, windowBefore: WindowObservation, windowAfter: WindowObservation) -> Bool {
        guard
            case .onScreen(let window) = windowBefore, windowAfter == windowBefore,
            let frame = frame?.standardized, frame.width >= 1, frame.height >= 1
        else { return false }
        let before = sourceRect
        part = PartCropGeometry.local(frame, in: window)
        windowSize = window.size
        return sourceRect != before
    }

    /// The tracked window moved or resized. True when `sourceRect` changed —
    /// a move never changes it (it is window-local); a resize may re-clamp it.
    @discardableResult
    mutating func windowChanged(_ frame: CGRect) -> Bool {
        let before = sourceRect
        windowSize = frame.standardized.size
        return sourceRect != before
    }
}

/// What one composed video frame shows, AppKit global: the rect the frame's
/// content stands for (`frame`, mapped onto the decorator's `outputRect`)
/// and, for a window target, the window that window-anchored ink resolves
/// against. Kept current by the main actor under the writer's lock; each
/// frame reads one consistent value — PURE, tested.
enum DecorationTarget: Equatable, Sendable {
    /// A fixed screen region (free rect, S, S + part).
    case area(CGRect)
    /// A window itself (W): the content is the whole window.
    case window(CGRect)
    /// W + part: the window at `window`, recorded through `sourceRect`
    /// (window-local, top-left origin, points — what SCK crops to).
    case part(window: CGRect, sourceRect: CGRect)

    /// The region the frame's content shows.
    var frame: CGRect {
        switch self {
        case .area(let rect), .window(let rect): rect
        case .part(let window, let source): PartCropGeometry.global(source, in: window)
        }
    }

    /// The recorded window's frame; nil for an area.
    var windowFrame: CGRect? {
        switch self {
        case .area: nil
        case .window(let frame), .part(let frame, _): frame
        }
    }

    /// The window moved or resized; an area stays put. A part keeps its
    /// window-local crop — so ink and content move together exactly.
    func withWindowFrame(_ frame: CGRect) -> DecorationTarget {
        switch self {
        case .area: self
        case .window: .window(frame)
        case .part(_, let source): .part(window: frame, sourceRect: source)
        }
    }

    /// SCK applied a new crop (a part target only).
    func withSourceRect(_ source: CGRect) -> DecorationTarget {
        guard case .part(let window, _) = self else { return self }
        return .part(window: window, sourceRect: source)
    }
}

/// Which crop a captured W + part frame has — PURE, tested (review V3
/// finding 3).
///
/// A frame doesn't say which `sourceRect` SCK cropped it to, and SCK takes a
/// new one some time during `updateConfiguration` (measured: never before
/// the call, a few ms before it returns). So each change is kept as a span
/// of **presentation time** (host clock, as SCK stamps frames):
/// - presented before the request, less `margin` (the frame SCK may still be
///   cropping when the update arrives) → the crop before it;
/// - presented after the update returned → the new crop;
/// - in between → **uncertain**: the writer holds it back (`FrameWriter`)
///   rather than draw ink on a guessed crop.
///
/// Content and ink therefore share one crop whatever order frames reach the
/// writer in (a backlog behind a slow composition) and however late the
/// main actor hears of the completion — the completion is stamped on SCK's
/// own callback. Frames reach the writer in presentation order, so a change
/// older than a frame already placed folds into `base`. At most one change
/// is unapplied at a time (`PartCropUpdater` sends one at a time).
struct PartCropTimeline: Equatable, Sendable {
    enum Crop: Equatable, Sendable {
        case known(CGRect)
        case uncertain
    }

    private struct Change: Equatable, Sendable {
        let source: CGRect
        let requestedAt: Double
        var appliedAt: Double?
    }

    /// The crop of every frame presented before the first change kept.
    private(set) var base: CGRect
    private var changes: [Change] = []
    /// How long before a request a frame may already have the new crop.
    let margin: Double
    /// How long after a change returned a held frame waits for a later one
    /// (`settledCrop`).
    let grace: Double

    init(source: CGRect, margin: Double, grace: Double) {
        base = source
        self.margin = margin
        self.grace = grace
    }

    /// Changes requested and not yet folded into `base` (tests).
    var pendingChanges: Int { changes.count }

    /// The crop of a frame presented at `time`.
    func crop(at time: Double) -> Crop {
        var source = base
        for change in changes {
            if time < change.requestedAt - margin { return .known(source) }
            guard let applied = change.appliedAt, time > applied else { return .uncertain }
            source = change.source
        }
        return .known(source)
    }

    /// The crop of a held (uncertain) frame presented at `time`, asked again
    /// at `now`: known by now (a failed update dropped its change), or —
    /// once its change has returned `grace` ago and no later frame came —
    /// the **new** crop. SCK sends a frame for a crop it has taken, so the
    /// last frame of the span is that frame when nothing follows it (a still
    /// window, measured: the new crop reaches the video). Nil: keep holding.
    func settledCrop(forHeldFrameAt time: Double, now: Double) -> CGRect? {
        if case .known(let source) = crop(at: time) { return source }
        // The change whose span holds the frame (`crop(at:)`'s stop).
        let spanning = changes.first { change in
            time >= change.requestedAt - margin && !(change.appliedAt.map { time > $0 } ?? false)
        }
        guard let change = spanning, let applied = change.appliedAt, now >= applied + grace
        else { return nil }
        return change.source
    }

    /// A frame presented at `time` was placed: every change it is past
    /// becomes `base` (a later frame can't be older).
    mutating func framePlaced(at time: Double) {
        while let first = changes.first, let applied = first.appliedAt, time > applied {
            base = first.source
            changes.removeFirst()
        }
    }

    /// `updateConfiguration` is about to be called with `source`.
    mutating func requested(_ source: CGRect, at time: Double) {
        changes.append(Change(source: source, requestedAt: time))
    }

    /// The newest request's update returned successfully at `time`.
    mutating func applied(at time: Double) {
        guard let last = changes.indices.last, changes[last].appliedAt == nil else { return }
        changes[last].appliedAt = time
    }

    /// The newest request's update failed: SCK kept the crop before it.
    mutating func failed() {
        guard let last = changes.last, last.appliedAt == nil else { return }
        changes.removeLast()
    }
}

/// The crop a frame was placed with: none for an area or W (the frame shows
/// the whole target), a W + part's source rect, or not known yet.
enum FrameCrop: Equatable, Sendable {
    case none
    case source(CGRect)
    case uncertain
}

/// What the writer decorates frames with — the target (its window frame
/// kept current by the main actor) and, for W + part, the crop timeline
/// (kept by SCK's update callbacks). One value under the writer's lock —
/// PURE, tested.
struct FrameDecorationState: Equatable, Sendable {
    /// For a part, the window frame is live; the crop is each frame's own.
    private(set) var target: DecorationTarget
    private(set) var crops: PartCropTimeline?

    init(target: DecorationTarget, frameInterval: Double) {
        self.target = target
        if case .part(_, let source) = target {
            crops = PartCropTimeline(source: source, margin: frameInterval, grace: 2 * frameInterval)
        }
    }

    mutating func windowMoved(to frame: CGRect) {
        target = target.withWindowFrame(frame)
    }

    mutating func cropRequested(_ source: CGRect, at time: Double) { crops?.requested(source, at: time) }
    mutating func cropApplied(at time: Double) { crops?.applied(at: time) }
    mutating func cropFailed() { crops?.failed() }

    /// The crop of a frame presented at `time`; a placed one folds what it
    /// is past (`PartCropTimeline.framePlaced`).
    mutating func place(frameAt time: Double) -> FrameCrop {
        guard var crops else { return .none }
        defer { self.crops = crops }
        guard case .known(let source) = crops.crop(at: time) else { return .uncertain }
        crops.framePlaced(at: time)
        return .source(source)
    }

    /// A held frame's crop once it is settled (`settledCrop`), else nil.
    func settledCrop(forHeldFrameAt time: Double, now: Double) -> FrameCrop? {
        guard let crops else { return FrameCrop.none }
        return crops.settledCrop(forHeldFrameAt: time, now: now).map(FrameCrop.source)
    }

    /// What a frame placed with `crop` shows, its window where it is now.
    func target(for crop: FrameCrop) -> DecorationTarget {
        guard case .source(let source) = crop else { return target }
        return target.withSourceRect(source)
    }
}

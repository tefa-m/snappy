import AppKit

// The seams between the recording pieces (features/recording.md). T0 owns this
// file; wave-1 tasks implement the protocols in their own files and never edit
// it. `RecordingCoordinator` is the only caller of every protocol below and
// talks to the pieces through them alone — the implementations are injected via
// `RecordingComponents` (`.current` builds the real ones; tests inject fakes).
//
// Shared rules for every @MainActor component:
// - Lifetime: the coordinator creates one instance per session from the
//   factory, calls `show` once, `apply` on every change, `close` exactly once at
//   session end, then drops it. `close` must be idempotent and must order every
//   window out. Components never outlive the session or keep the coordinator
//   alive: `onEvent` is set by the coordinator with a weak capture, scoped to
//   its session (events from an ended session are dropped), and set back to
//   nil before `close()`. The one thing that may outlive `close()` is the ink's
//   `frameDecorator` — see `FrameDecorating`.
// - Input: components report user input only as `RecordingEvent`s through
//   `onEvent`; they never change session state themselves. Keys are translated
//   with `RecordingKeyMap` against the phase they were last given.
// - Coordinates: AppKit global points everywhere (see `RecordingTarget`).

// MARK: - Live-ink vocabulary (shared by the key map, settings, ink, chrome)

/// The recording view's drawing tools (Q6/Q14). Box is B here; the snapshot
/// editor keeps R = Rectangle.
enum InkTool: CaseIterable, Equatable, Sendable {
    case pen, highlighter, arrow, oval, box
}

/// What the ink panel does with the mouse (`RecordingSession.inkMode`).
enum InkMode: Equatable, Sendable {
    /// Setup Pointer mode, snapping, countdown: click-through; the Setup
    /// overlay owns the mouse.
    case pointer
    /// Draws with this tool: Setup with a tool picked, or draw mode.
    case tool(InkTool)
    /// Magic Pen mode while recording: draws fading Magic Pen strokes
    /// (`MagicPenLook`), whatever the picked tool and style say.
    case magicPen
    /// Recording in interact mode: click-through, keys belong to the user's app.
    case interact
}

/// Colour presets 1–5 (Q25). Fixed sRGB values, like the editor's red: ink is
/// exported content and must not follow the appearance.
enum InkColorPreset: Int, CaseIterable, Equatable, Sendable {
    case red = 1, yellow, green, blue, white

    var color: AnnotationColor {
        switch self {
        case .red: .red // #FF3B30, the editor's default
        case .yellow: AnnotationColor(red: 1, green: 0.8, blue: 0) // #FFCC00
        case .green: AnnotationColor(red: 0.2, green: 0.78, blue: 0.35) // #34C759
        case .blue: AnnotationColor(red: 0, green: 0.48, blue: 1) // #007AFF
        case .white: .white
        }
    }

    /// The digit key that selects it.
    var key: String { String(rawValue) }

    var title: String {
        switch self {
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .white: "White"
        }
    }
}

/// Line widths, stepped with [ and ] (Q25). The highlighter ignores this and
/// is always thick at 40 % opacity.
enum InkWidth: Int, CaseIterable, Comparable, Sendable {
    case thin, medium, thick

    /// Stroke width in screen points (× backing scale for pixels).
    var points: CGFloat {
        switch self {
        case .thin: 2
        case .medium: 4
        case .thick: 8
        }
    }

    var title: String {
        switch self {
        case .thin: "Thin"
        case .medium: "Medium"
        case .thick: "Thick"
        }
    }

    /// Magic Pen stroke width in screen points: a step bolder than the
    /// normal pen, so the fading ink is easy to see (design decision).
    var magicPenPoints: CGFloat {
        switch self {
        case .thin: 4
        case .medium: 6
        case .thick: 10
        }
    }

    /// One step thinner/thicker, clamped at the ends.
    var thinner: InkWidth { InkWidth(rawValue: rawValue - 1) ?? self }
    var thicker: InkWidth { InkWidth(rawValue: rawValue + 1) ?? self }

    static func < (lhs: InkWidth, rhs: InkWidth) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Live-ink commands that don't change the session's phase.
enum InkCommand: Equatable, Sendable {
    /// 1–5
    case color(InkColorPreset)
    /// [ and ]
    case thinner, thicker
    /// F
    case toggleFading
    /// ⌫ — clears setup annotations and recorded strokes alike.
    case clear
    /// ⌘Z / ⇧⌘Z
    case undo, redo
    /// [ and ] in Magic Pen mode: one Magic Pen thickness step.
    case magicPenThinner, magicPenThicker
    /// A Magic Pen thickness picked from a menu (menu bar, toolbar).
    case magicPenWidth(InkWidth)

    /// Style commands change `InkStyle` (owned by the coordinator, pushed to
    /// ink and chrome); the rest act on the ink's content (`LiveInkHosting.perform`).
    var isStyle: Bool {
        switch self {
        case .color, .thinner, .thicker, .toggleFading, .magicPenThinner, .magicPenThicker, .magicPenWidth: true
        case .clear, .undo, .redo: false
        }
    }

    /// Changes the Magic Pen thickness — persisted, since it is a setting
    /// shared with the menu bar and Settings → Recording.
    var changesMagicPenWidth: Bool {
        switch self {
        case .magicPenThinner, .magicPenThicker, .magicPenWidth: true
        default: false
        }
    }
}

/// The Magic Pen's fixed look (design decision, not yet confirmed) — PURE,
/// tested. Smooth, slightly transparent, vivid, with a soft dark halo that
/// keeps it visible on light content. Everything here is drawn through
/// `InkRenderer`, so the screen and the video show the same pixels.
enum MagicPenLook {
    /// #FF451A, a vivid red-orange: high chroma on light and dark content,
    /// a shade warmer than the default red ink (#FF3B30). Fixed sRGB, like
    /// every ink colour — it is exported content.
    static let color = AnnotationColor(red: 1, green: 0.27, blue: 0.1)
    /// Slightly transparent (the highlighter stays 40 %).
    static let alpha: CGFloat = 0.85
    /// The halo under the stroke: this much wider than the stroke (points,
    /// split over both sides) …
    static let haloExtraWidth: CGFloat = 4
    /// … in black at this opacity (inside the stroke's transparency layer,
    /// so it only shows around the stroke).
    static let haloColor = AnnotationColor(red: 0, green: 0, blue: 0, alpha: 0.28)
    /// Pointer samples closer than this (points) are dropped — light
    /// thinning on top of the midpoint-quad smoothing (pen: 2 pt).
    static let minSampleDistance: CGFloat = 3
}

/// The style the next stroke uses. The coordinator owns the one current value
/// (seeded from `RecordingSettings`) and pushes it to the ink and the toolbar,
/// so T3 and T4 never need to talk to each other.
struct InkStyle: Equatable, Sendable {
    var color: InkColorPreset
    var width: InkWidth
    /// Fading ink: strokes drawn *while recording* fade after the fade delay.
    /// Setup annotations never fade (Q16). Magic Pen strokes always fade.
    var fading: Bool
    /// The Magic Pen's thickness — its own setting, separate from `width`
    /// (Settings → Recording, the menu bar, [ ] in Magic Pen mode).
    var magicPenWidth: InkWidth

    init(color: InkColorPreset, width: InkWidth, fading: Bool, magicPenWidth: InkWidth = .medium) {
        self.color = color
        self.width = width
        self.fading = fading
        self.magicPenWidth = magicPenWidth
    }

    init(settings: RecordingSettings) {
        self.init(
            color: settings.defaultColor, width: settings.defaultWidth, fading: settings.fadingInkAtStart,
            magicPenWidth: settings.magicPenWidth
        )
    }

    /// The style after a style command; content commands leave it unchanged.
    func applying(_ command: InkCommand) -> InkStyle {
        var style = self
        switch command {
        case .color(let preset): style.color = preset
        case .thinner: style.width = width.thinner
        case .thicker: style.width = width.thicker
        case .toggleFading: style.fading.toggle()
        case .magicPenThinner: style.magicPenWidth = magicPenWidth.thinner
        case .magicPenThicker: style.magicPenWidth = magicPenWidth.thicker
        case .magicPenWidth(let width): style.magicPenWidth = width
        case .clear, .undo, .redo: break
        }
        return style
    }
}

/// Opaque Setup-annotation state handed back on Retake (Q19): the target and
/// the setup annotations come back, recorded strokes don't. T3's concrete type
/// conforms; the coordinator only stores and returns it.
protocol LiveInkSetupSnapshot: Sendable {}

// MARK: - Window z-order

/// Recording windows, bottom to top: Setup overlay (dimming, handles, snap
/// highlight) < live ink < chrome (border, toolbar, countdown). Above normal
/// and floating windows (the user's app, the screenshot preview panel) and the
/// Dock, below pop-up menus and the area-capture overlay (`.screenSaver`).
/// Every recording window must use exactly one of these.
enum RecordingWindowLevel {
    static let setup = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue)
    static let ink = NSWindow.Level(rawValue: setup.rawValue + 1)
    static let chrome = NSWindow.Level(rawValue: setup.rawValue + 2)
}

// MARK: - Frame decoration (capture queue)

/// Draws the live ink into a recorded frame (T3's `RecordingCompositor`).
///
/// **Threading:** called on the pipeline's capture queue, never the main
/// actor, once per appended frame (including the re-appended idle frames). It
/// must therefore only read an **immutable snapshot** of the ink that the main
/// actor swaps in under a lock (`OSAllocatedUnfairLock` / `Mutex`) whenever the
/// ink changes — never the live model. It must not block on the main actor.
///
/// **Coordinates:** `context` is a bitmap context over the frame's BGRA pixel
/// buffer, CG convention (origin bottom-left, y up, pixels). The target's
/// content occupies `outputRect` in it (smaller than the buffer when a resized
/// window is letterboxed). `targetFrame` is the AppKit-global region this
/// frame shows (points) — a window part's own rect for W + part; map with
/// `FrameDecoratingGeometry.transform`. `windowFrame` is the recorded
/// window's frame for this frame (W, W + part; nil for an area): what
/// window-anchored ink resolves against, so ink stays on the window's
/// content while only the part is shown (Q42). AppKit and CG are both y-up,
/// so there is no flip.
///
/// **Lifetime:** valid from `LiveInkHosting.show` until the pipeline's
/// `stop()` has returned — which can be **after** `LiveInkHosting.close()`:
/// on Cancel or a failure the coordinator orders every window out at once
/// while the stream drains. The coordinator retains the decorator until the
/// run is drained; after `close()` it must keep drawing its last snapshot (or
/// nothing) and must never touch released UI.
///
/// **Time:** `hostTime` is host-clock seconds — the same clock as
/// `CACurrentMediaTime()` and SCK sample presentation times — so fade alpha
/// is computed against the stroke's `createdAt` taken with `CACurrentMediaTime()`.
protocol FrameDecorating: Sendable {
    func draw(
        in context: CGContext, outputRect: CGRect, targetFrame: CGRect, windowFrame: CGRect?, hostTime: TimeInterval
    )
}

extension FrameDecorating {
    /// A frame whose window (if any) is the target itself — an area or W.
    func draw(in context: CGContext, outputRect: CGRect, targetFrame: CGRect, hostTime: TimeInterval) {
        draw(in: context, outputRect: outputRect, targetFrame: targetFrame, windowFrame: nil, hostTime: hostTime)
    }
}

/// Draws nothing — for pipeline tests and fake ink.
struct NullFrameDecorator: FrameDecorating {
    func draw(
        in context: CGContext, outputRect: CGRect, targetFrame: CGRect, windowFrame: CGRect?, hostTime: TimeInterval
    ) {}
}

/// PURE mapping shared by the compositor and anything that tests it — tested.
enum FrameDecoratingGeometry {
    /// AppKit-global points → output-buffer pixels: `targetFrame` lands
    /// exactly on `outputRect` (scaled per axis; both spaces are y-up).
    static func transform(targetFrame: CGRect, outputRect: CGRect) -> CGAffineTransform {
        guard targetFrame.width > 0, targetFrame.height > 0 else { return .identity }
        return CGAffineTransform(translationX: outputRect.minX, y: outputRect.minY)
            .scaledBy(x: outputRect.width / targetFrame.width, y: outputRect.height / targetFrame.height)
            .translatedBy(x: -targetFrame.minX, y: -targetFrame.minY)
    }
}

// MARK: - Components

/// Delivers user input to the coordinator. Always called on the main actor.
typealias RecordingEventHandler = @MainActor (RecordingEvent) -> Void

/// T1 — the live (not frozen) Setup overlay on the target's display: dimming
/// outside the rect, 8 handles, size chip, move/nudge/scroll-resize, drag
/// outside = new rect, and the S/W snap picker.
///
/// - Full UI in `.setup` and `.snapping`. During `.countdown` it draws no
///   dimming or handles and ignores the mouse, but stays ordered in **and key**
///   so Esc/Q returns to Setup. From `.recording` on it orders its windows out
///   (not just transparent) — the user's app gets the keyboard back — and stays
///   alive until `close()`.
/// - Is key from `show` on (non-activating panel, ARCHITECTURE overlay
///   invariants 1–6) and translates keys with `RecordingKeyMap` → `.command`.
/// - Reports rect edits and the hovered snap window as `.targetChanged`, a
///   snap click as `.confirmSnap`. While snapping, the session restores the
///   previous target on Esc itself.
@MainActor
protocol RecordingSetupOverlaying: AnyObject {
    var onEvent: RecordingEventHandler? { get set }
    func show(_ session: RecordingSession)
    func apply(_ session: RecordingSession)
    func close()
}

/// T3 — the on-screen ink canvas over the target plus its compositor.
///
/// - `apply(session)`: mouse behaviour from `session.inkMode` (`ignoresMouseEvents`
///   unless `.tool`), stroke kind from `session.isCapturing` (setup = permanent,
///   recorded = may fade), visibility clipped to `session.target.frame`
///   (hidden, not deleted — a window part's own rect for W + part), window
///   anchoring when the target is `.window` or `.windowPart` (the window's
///   frame arrives here as it moves; a part's ink is anchored to its window,
///   Q42).
/// - In draw mode it is key and translates keys with `RecordingKeyMap` → `.command`.
/// - `frameDecorator` is created once per session, reads the latest snapshot,
///   and stays safe to call **after `close()`** until the pipeline has drained
///   (see `FrameDecorating` › Lifetime).
/// - `setupSnapshot()` is read at session end for Retake; `show(restoring:)`
///   gets it back.
@MainActor
protocol LiveInkHosting: AnyObject {
    var onEvent: RecordingEventHandler? { get set }
    var frameDecorator: any FrameDecorating { get }
    func show(
        _ session: RecordingSession, style: InkStyle, settings: RecordingSettings,
        restoring snapshot: (any LiveInkSetupSnapshot)?
    )
    func apply(_ session: RecordingSession)
    func apply(style: InkStyle)
    /// Content commands only: `.clear`, `.undo`, `.redo`.
    func perform(_ command: InkCommand)
    func setupSnapshot() -> (any LiveInkSetupSnapshot)?
    func close()
}

/// T2 — ScreenCaptureKit stream → compositor → `AVAssetWriter` MP4.
///
/// - `start` returns once the stream is running and the writer is ready; a
///   throw ends the session (the coordinator shows the alert — throw
///   `CaptureError.permissionDenied` for a TCC denial so it gets the
///   permission alert; give other errors a `LocalizedError.errorDescription`).
/// - `stop` finalises the file at `outputURL` and returns it. The coordinator
///   calls it **exactly once per instance, only after `start` has returned or
///   thrown** (also when `start` failed — then it may throw). Until `stop`
///   returns, no new session can start, so nobody else touches `outputURL`.
/// - Callbacks fire on the main actor (the coordinator scopes them to their
///   session and sets them back to nil when it ends — don't cache them):
///   `onWindowFrameChange` with the window
///   target's new AppKit-global frame, `onPartFrameChange` with a W + part
///   target's new part frame (v2 V3: the part moved or resized inside its
///   window; a window move alone is only `onWindowFrameChange`, the part
///   keeping its offset), `onWindowGone` once when it closes or
///   minimises, `onFailure` for an error after a successful start (disk full,
///   writer failure) — the coordinator then stops the session.
/// - `endTracking()`: the session is over — stop following the window and
///   polling the part (no Accessibility read may start after it, because
///   the session's tree-switch restores follow at once). `stop()` may come
///   later (a cancelled or failed run drains).
/// - Owns its capture queue; the only thing it calls there is `decorator`.
@MainActor
protocol RecordingPipelining: AnyObject {
    var onWindowFrameChange: (@MainActor (CGRect) -> Void)? { get set }
    var onPartFrameChange: (@MainActor (CGRect) -> Void)? { get set }
    var onWindowGone: (@MainActor () -> Void)? { get set }
    var onFailure: (@MainActor (any Error) -> Void)? { get set }
    func start(
        target: RecordingTarget, settings: RecordingSettings,
        decorator: any FrameDecorating, outputURL: URL
    ) async throws
    func endTracking()
    func stop() async throws -> URL
}

extension RecordingPipelining {
    /// Fakes that record no window part.
    var onPartFrameChange: (@MainActor (CGRect) -> Void)? {
        get { nil }
        set {}
    }

    func endTracking() {}
}

/// T4 — border (amber in Setup, red while recording, outside the rect,
/// following the target), glass toolbar, countdown disc, timer.
///
/// - `apply(session)` drives everything visible: border colour from the phase,
///   countdown numeral from `.countdown(remaining:)`, ●/■ and the tool /
///   draw-interact state from the phase, placement from `session.target.frame`.
/// - `captureDidStart()` starts the 00:00 timer (the pipeline is writing).
/// - Toolbar buttons report `.command(...)` (Record, Stop, tools, style,
///   Clear, draw/interact toggle, Cancel). Buttons accept first mouse.
@MainActor
protocol RecordingChromeHosting: AnyObject {
    var onEvent: RecordingEventHandler? { get set }
    func show(_ session: RecordingSession, style: InkStyle)
    func apply(_ session: RecordingSession)
    func apply(style: InkStyle)
    func captureDidStart()
    /// The draw-mode hot key as the toolbar may advertise it, or nil when it
    /// couldn't be registered this session (another app owns the combo) —
    /// then no tooltip names it. Called before `show`. (Added in T7.)
    func setDrawModeShortcut(_ shortcut: String?)
    /// The Magic Pen hot key, same rules as `setDrawModeShortcut`.
    func setMagicPenShortcut(_ shortcut: String?)
    func close()
}

extension RecordingChromeHosting {
    /// Fakes that don't care about the advertised shortcut.
    func setDrawModeShortcut(_ shortcut: String?) {}
    func setMagicPenShortcut(_ shortcut: String?) {}
}

/// V1 — one persistent recording window per finished take (v2, Q28–Q32,
/// Q43): the take in a player (autoplay, loop, muted, scrub), Space, R Retake,
/// ⌘S Save (stays open), ⇧⌘C/⌘C Copy (closes), Q/Esc/⌘W/traffic light close.
///
/// - Built per take by `RecordingComponents.makeRecordingWindow`; the
///   coordinator owns every open one (like the editors) and releases it in
///   `onClose`.
/// - The window never deletes its take; the coordinator decides that through
///   `RecordingTakeLedger` when `onClose` fires.
/// - `onRetake` (nil when the take can't be retaken — reopened after a
///   relaunch, without its target and setup ink: no Retake then) only asks
///   for a retake. The coordinator closes the window itself when Setup can
///   actually start, so a refused retake (a session busy) leaves it open.
@MainActor
protocol RecordingWindowHosting: AnyObject {
    /// The take this window shows and owns.
    var take: URL { get }
    /// False from the moment the window starts closing.
    var isOpen: Bool { get }
    /// Fired exactly once, a run-loop turn after the window closed by any route.
    var onClose: (@MainActor () -> Void)? { get set }
    /// Opens the window frontmost with focus, synchronously — the end of the
    /// session is the only moment it may take focus on its own (the take's
    /// size and duration arrive later and never move focus).
    func show()
    /// Reopen Last Recording on a take whose window is open (Q43).
    func bringToFront()
    /// Closes without a prompt (Q32); idempotent.
    func close()
}

/// The factory the coordinator builds each session from. `.current` (in
/// `RecordingCoordinator.swift`) chooses the implementations.
struct RecordingComponents {
    var makeSetupOverlay: @MainActor () -> any RecordingSetupOverlaying
    var makeLiveInk: @MainActor () -> any LiveInkHosting
    var makePipeline: @MainActor () -> any RecordingPipelining
    var makeChrome: @MainActor () -> any RecordingChromeHosting
    /// A window for a finished take: the take, the recorded area (AppKit
    /// global — picks the screen and the first size; a reopened take gets the
    /// main screen's visible frame), the retake request and what the
    /// coordinator shares with every window.
    var makeRecordingWindow: @MainActor (
        _ take: URL, _ anchorRect: CGRect, _ onRetake: (@MainActor () -> Void)?, _ context: RecordingWindowContext
    ) -> any RecordingWindowHosting
}

/// What the coordinator gives every recording window (fix round 1).
struct RecordingWindowContext {
    /// Where takes were saved — per take, so it survives the window.
    let savedFiles: RecordingSavedFiles
    /// False while a newer operation runs (a recording session, or a
    /// screenshot capture in flight): a focus request the window is still
    /// waiting on (activation can arrive late) is then dropped, so it never
    /// takes the keyboard from the recorded app or the capture overlay.
    let mayTakeFocus: @MainActor () -> Bool
}

import Foundation

/// Setup sub-mode: Pointer (move/resize the rect) or a drawing tool picked.
enum SetupMode: Equatable, Sendable {
    case pointer
    case tool(InkTool)
}

/// S = snap to the window's *area*; W = record the window *itself*.
enum SnapKind: Equatable, Sendable {
    case area, window
}

/// Interact (default): the overlay is click-through and every key goes to the
/// user's app. Draw: Snappy takes mouse + keys and draws with `tool`.
/// Magic Pen: like draw mode, but every stroke is a fading Magic Pen stroke
/// (`features/recording.md` › Magic Pen); `resume` is the draw tool it was
/// entered from (nil = from interact), where toggling it off goes back to.
enum RecordingMode: Equatable, Sendable {
    case interact
    case draw(InkTool)
    case magicPen(resume: InkTool?)

    /// Snappy takes the mouse and the keyboard (draw mode or Magic Pen).
    var isDrawing: Bool { self != .interact }
}

/// The session's state (`features/recording.md`, Flow & states).
enum RecordingPhase: Equatable, Sendable {
    case setup(SetupMode)
    /// Hovering windows to snap to. `previous` is the target to restore on Esc;
    /// `returnTo` the Setup mode to go back to afterwards. While snapping, the
    /// session's target follows the hovered window live (`.targetChanged`).
    case snapping(SnapKind, previous: RecordingTarget, returnTo: SetupMode)
    /// Seconds still to show; the next tick at 1 starts recording.
    case countdown(remaining: Int)
    case recording(RecordingMode)
    /// Stop requested; waiting for the pipeline to finalise the file. Not in
    /// the design's state list — it exists so a second ⇧⌘4 or a window closing
    /// during finalisation is ignored instead of stopping twice.
    case stopping
    case finished(URL)
    case cancelled

    /// Finished and cancelled end the session.
    var isTerminal: Bool {
        switch self {
        case .finished, .cancelled: true
        default: false
        }
    }

    /// Before the first frame: Setup, snapping and the countdown.
    var isPreRecording: Bool {
        switch self {
        case .setup, .snapping, .countdown: true
        default: false
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// Something the user asked for — from a key (`RecordingKeyMap`), a toolbar
/// button (T4) or the session-only ⌃⌥D hot key.
enum RecordingCommand: Equatable, Sendable {
    /// R in Setup — start (countdown, then recording). A no-op while recording.
    case record
    /// S / W — enter snap mode, switch snap mode, or confirm (same key again).
    case snap(SnapKind)
    /// V — Pointer in Setup; back to interact mode while recording.
    case pointer
    /// P H A O B — pick a tool (enters draw mode when picked while recording).
    case tool(InkTool)
    /// Style and content commands for the live ink (1–5, [ ], F, ⌫, ⌘Z, ⇧⌘Z).
    case ink(InkCommand)
    /// Esc / Q — one level back: snap → previous target · tool → Pointer ·
    /// Pointer → cancel · countdown → Setup · draw → interact.
    case stepBack
    /// ⌃⌥D or the toolbar toggle.
    case toggleDrawMode
    /// ⌃⌥P or the toolbar's Magic Pen toggle.
    case toggleMagicPen
    /// ⇧⌘4, the toolbar ■, the menu bar ■. Never a bare letter (Q15).
    case stop
    /// Toolbar Cancel: ends the session without a take, from any phase.
    case cancel
}

/// Inputs to the state machine.
enum RecordingEvent: Equatable, Sendable {
    case command(RecordingCommand)
    /// The Setup overlay moved/resized/re-selected the rect, the snap picker
    /// hovered a window, or a window target moved (T2's `onWindowFrameChange`).
    case targetChanged(RecordingTarget)
    /// A click on the hovered window while snapping.
    case confirmSnap
    /// One countdown second elapsed.
    case countdownTick
    /// A window target closed or minimised.
    case windowGone
    /// The pipeline finalised the take.
    case captureFinished(URL)
    /// The pipeline failed to start, or failed while recording / stopping.
    case captureFailed
}

/// What `RecordingSession.handle` did, so the coordinator knows what to push
/// where without diffing.
enum RecordingOutcome: Equatable, Sendable {
    /// Not applicable in this phase; nothing changed.
    case ignored
    /// Phase and/or target changed. `from` is the phase before the event (equal
    /// to the current phase for a pure target change).
    case changed(from: RecordingPhase)
    /// Valid here, but the state lives in the live ink, not the session.
    case ink(InkCommand)
}

/// The recording session's state machine — PURE, every transition unit-tested.
/// One value per session, owned by `RecordingCoordinator`; components only ever
/// see copies (`apply(_:)`).
struct RecordingSession: Equatable, Sendable {
    private(set) var phase: RecordingPhase
    private(set) var target: RecordingTarget
    /// The tool draw mode uses when entered with ⌃⌥D: the last one picked
    /// (Pen until then).
    private(set) var lastTool: InkTool = .pen
    /// Settings → Countdown, fixed for the session (0 = straight to recording).
    let countdownSeconds: Int

    init(target: RecordingTarget, countdownSeconds: Int) {
        self.target = target
        self.countdownSeconds = max(0, countdownSeconds)
        phase = .setup(.pointer)
    }

    // MARK: - Derived state

    /// What the live ink panel does with the mouse: draw with a tool, or let
    /// clicks through (pointer: the Setup overlay handles them; interact: the
    /// user's app does).
    var inkMode: InkMode {
        switch phase {
        case .setup(.tool(let tool)), .recording(.draw(let tool)): .tool(tool)
        case .recording(.magicPen): .magicPen
        case .setup(.pointer), .snapping, .countdown: .pointer
        case .recording(.interact), .stopping, .finished, .cancelled: .interact
        }
    }

    /// True while strokes are recorded strokes (they may fade); before that
    /// they are permanent setup annotations (Q16).
    var isCapturing: Bool {
        phase.isRecording || phase == .stopping
    }

    // MARK: - Transitions

    @discardableResult
    mutating func handle(_ event: RecordingEvent) -> RecordingOutcome {
        let before = phase
        switch (phase, event) {
        case (.finished, _), (.cancelled, _):
            return .ignored

        // Too late to cancel once the file is being finalised.
        case (.stopping, .command):
            return .ignored

        // Any other live phase: the toolbar's Cancel ends the session.
        case (_, .command(.cancel)):
            phase = .cancelled

        // A window target moved, or the overlay/picker changed the rect.
        case (.setup, .targetChanged(let new)), (.snapping, .targetChanged(let new)),
             (.countdown, .targetChanged(let new)), (.recording, .targetChanged(let new)):
            guard new != target else { return .ignored }
            target = new

        case (.setup(let mode), .command(let command)):
            return handleSetup(mode, command)

        case (.snapping(let kind, let previous, let returnTo), _):
            return handleSnapping(kind, previous: previous, returnTo: returnTo, event)

        case (.countdown(let remaining), .countdownTick):
            phase = remaining > 1 ? .countdown(remaining: remaining - 1) : .recording(.interact)
        case (.countdown, .command(.stepBack)):
            phase = .setup(.pointer)

        case (.recording(let mode), .command(let command)):
            return handleRecording(mode, command)
        case (.recording, .windowGone):
            phase = .stopping

        // The chosen window closed before recording: keep its region as an
        // area so the session never points at a dead window.
        case (.setup, .windowGone), (.countdown, .windowGone):
            guard target.isWindow else { return .ignored }
            target = target.asArea
            if case .countdown = phase { phase = .setup(.pointer) }

        case (.recording, .captureFailed), (.stopping, .captureFailed):
            phase = .cancelled
        case (.stopping, .captureFinished(let url)):
            phase = .finished(url)

        default:
            return .ignored
        }
        return .changed(from: before)
    }

    private mutating func handleSetup(_ mode: SetupMode, _ command: RecordingCommand) -> RecordingOutcome {
        let before = phase
        switch command {
        case .record:
            phase = countdownSeconds > 0 ? .countdown(remaining: countdownSeconds) : .recording(.interact)
        case .snap(let kind):
            phase = .snapping(kind, previous: target, returnTo: mode)
        case .pointer:
            guard mode != .pointer else { return .ignored }
            phase = .setup(.pointer)
        case .tool(let tool):
            lastTool = tool
            guard mode != .tool(tool) else { return .ignored }
            phase = .setup(.tool(tool))
        case .stepBack:
            phase = mode == .pointer ? .cancelled : .setup(.pointer)
        case .ink(let ink):
            return .ink(ink)
        case .toggleDrawMode, .toggleMagicPen, .stop, .cancel:
            // ⇧⌘4, ⌃⌥D and ⌃⌥P are ignored in Setup (Cancel is handled above).
            return .ignored
        }
        return .changed(from: before)
    }

    private mutating func handleSnapping(
        _ kind: SnapKind, previous: RecordingTarget, returnTo: SetupMode, _ event: RecordingEvent
    ) -> RecordingOutcome {
        let before = phase
        switch event {
        case .command(.snap(let other)) where other != kind:
            // The other key switches mode and keeps the original target to restore.
            phase = .snapping(other, previous: previous, returnTo: returnTo)
        case .command(.snap), .confirmSnap:
            // Same key again or a click: keep the hovered target.
            phase = .setup(returnTo)
        case .command(.stepBack):
            target = previous
            phase = .setup(returnTo)
        default:
            return .ignored
        }
        return .changed(from: before)
    }

    private mutating func handleRecording(_ mode: RecordingMode, _ command: RecordingCommand) -> RecordingOutcome {
        let before = phase
        switch (mode, command) {
        case (_, .stop):
            phase = .stopping
        case (.interact, .toggleDrawMode):
            phase = .recording(.draw(lastTool))
        case (.draw, .toggleDrawMode), (.draw, .pointer), (.draw, .stepBack):
            phase = .recording(.interact)

        // Magic Pen (leader decision, Tefa to confirm): ⌃⌥P toggles it on
        // from interact or draw mode and off again — back to where it came
        // from; Esc / Q do the same. V always hands the mouse back to the
        // user's app, and ⌃⌥D (whose toolbar toggle shows off here) switches
        // to normal drawing with the last tool.
        case (.interact, .toggleMagicPen):
            phase = .recording(.magicPen(resume: nil))
        case (.draw(let tool), .toggleMagicPen):
            phase = .recording(.magicPen(resume: tool))
        case (.magicPen(let resume), .toggleMagicPen), (.magicPen(let resume), .stepBack):
            phase = .recording(resume.map(RecordingMode.draw) ?? .interact)
        case (.magicPen, .pointer):
            phase = .recording(.interact)
        case (.magicPen, .toggleDrawMode):
            phase = .recording(.draw(lastTool))

        case (_, .tool(let tool)):
            // A key in draw mode, or a toolbar tool in interact mode — both draw.
            lastTool = tool
            guard mode != .draw(tool) else { return .ignored }
            phase = .recording(.draw(tool))
        case (_, .ink(let ink)):
            // Toolbar style buttons work in interact mode too; keys only reach
            // here in draw mode (`RecordingKeyMap`).
            return .ink(ink)
        case (_, .record), (_, .snap), (.interact, .pointer), (.interact, .stepBack), (_, .cancel):
            // R does nothing while recording (Q15); S/W only exist in Setup.
            return .ignored
        }
        return .changed(from: before)
    }
}

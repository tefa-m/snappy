import AppKit
import QuartzCore

/// T3 — the live ink of one recording session (`LiveInkHosting`): a
/// transparent panel over the target at `RecordingWindowLevel.ink`, the PURE
/// `LiveInk` model, and the `RecordingCompositor` that puts the same ink into
/// the video.
///
/// - **Mouse:** click-through (`ignoresMouseEvents`) unless the session's
///   `inkMode` is `.tool` (Setup with a tool picked, or draw mode) or
///   `.magicPen` (Magic Pen strokes, `LiveInk.beginMagicPenStroke`).
/// - **Keys:** takes key status on entering draw mode or Magic Pen — without activating
///   Snappy (non-activating panel), so pins/editors never jump over the user's
///   app — and gives it back when the session leaves draw mode, so no letter
///   reaches Snappy in interact mode (Q2/Q15). Keys go through `RecordingKeyMap`
///   against the last phase it was given → `onEvent`.
/// - **Fading:** a main-actor task redraws the view while something fades and
///   prunes expired strokes; the video evaluates fades at each frame's host time.
/// - **Lifetime:** after `close()` the panel is gone and every call is a no-op,
///   but `frameDecorator` keeps drawing the last published scene until the
///   pipeline drains (`FrameDecorating` › Lifetime).
@MainActor
final class LiveInkPanel: LiveInkHosting {
    var onEvent: RecordingEventHandler?
    var frameDecorator: any FrameDecorating { compositor }

    private let compositor = RecordingCompositor()
    private let panel = InkPanelWindow()
    private let view = LiveInkView()
    private let clock: () -> TimeInterval
    private var ink = LiveInk(fadeDelay: TimeInterval(RecordingSettings().fadeDelay))
    private var style = InkStyle(settings: RecordingSettings())
    private var session: RecordingSession?
    private var fadeTask: Task<Void, Never>?
    private var closed = false

    init(clock: @escaping () -> TimeInterval = CACurrentMediaTime) {
        self.clock = clock
        view.clock = clock
        panel.contentView = view
        panel.initialFirstResponder = view
        view.onMouseDown = { [weak self] point in self?.mouseDown(at: point) }
        view.onMouseDragged = { [weak self] point in self?.mouseDragged(to: point) }
        view.onMouseUp = { [weak self] point in self?.mouseUp(at: point) }
        view.onKeyDown = { [weak self] event in self?.keyDown(event) ?? false }
    }

    // MARK: - LiveInkHosting

    func show(
        _ session: RecordingSession, style: InkStyle, settings: RecordingSettings,
        restoring snapshot: (any LiveInkSetupSnapshot)?
    ) {
        guard !closed else { return }
        ink = LiveInk(fadeDelay: TimeInterval(settings.fadeDelay), restoring: snapshot as? InkSetupSnapshot)
        self.style = style
        apply(session)
        panel.orderFrontRegardless()
    }

    func apply(_ session: RecordingSession) {
        guard !closed else { return }
        let previous = self.session
        self.session = session

        // A drag the new mode no longer allows (tool switch, draw → interact,
        // Stop) is kept as drawn so far.
        if ink.draft != nil, previous?.inkMode != session.inkMode {
            ink.endStroke(at: clock())
        }
        ink.setTarget(session.target)
        if session.isCapturing { ink.captureDidBegin() }

        // The panel covers the target — a W + part's part, like the video
        // (V3) — so ink outside it is hidden on screen too; the ink itself
        // stays anchored to the part's window (Q42), resolved against the
        // window's frame exactly as the compositor does.
        let frame = session.target.frame
        if frame.width > 0, frame.height > 0, panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        view.targetFrame = frame
        view.windowFrame = session.target.windowFrame
        let drawing = LiveInkFocus.takesMouse(session.inkMode)
        panel.ignoresMouseEvents = !drawing
        view.drawsWithTool = drawing
        updateKeyStatus(from: previous?.phase, to: session.phase)
        publish()
    }

    func apply(style: InkStyle) {
        self.style = style
    }

    func perform(_ command: InkCommand) {
        guard !closed else { return }
        switch command {
        case .clear: ink.clear(at: clock())
        case .undo: ink.undo(at: clock())
        case .redo: ink.redo(at: clock())
        case .color, .thinner, .thicker, .toggleFading, .magicPenThinner, .magicPenThicker, .magicPenWidth: return
        }
        publish()
    }

    func setupSnapshot() -> (any LiveInkSetupSnapshot)? {
        ink.setupSnapshot
    }

    func close() {
        guard !closed else { return }
        closed = true
        fadeTask?.cancel()
        fadeTask = nil
        panel.orderOut(nil)
    }

    // MARK: - Input

    private func mouseDown(at point: CGPoint) {
        guard let session else { return }
        switch session.inkMode {
        case .tool(let tool):
            ink.beginStroke(tool: tool, at: point, style: style, isCapturing: session.isCapturing)
        case .magicPen:
            ink.beginMagicPenStroke(at: point, style: style)
        case .pointer, .interact:
            return
        }
        publish()
    }

    private func mouseDragged(to point: CGPoint) {
        guard ink.draft != nil else { return }
        ink.extendStroke(to: point)
        publish()
    }

    private func mouseUp(at point: CGPoint) {
        guard ink.draft != nil else { return }
        ink.extendStroke(to: point)
        ink.endStroke(at: clock())
        publish()
    }

    private func keyDown(_ event: NSEvent) -> Bool {
        guard let phase = session?.phase,
              let command = RecordingKeyMap.command(for: event, phase: phase)
        else { return false }
        onEvent?(.command(command))
        return true
    }

    /// Draw mode takes the keyboard; leaving it for a phase without keys
    /// (interact, stopping) hands it back. Setup, snapping and the countdown
    /// leave key status alone — the Setup overlay owns it there, and if a
    /// click made this panel key, keys still map against the Setup table.
    private func updateKeyStatus(from previous: RecordingPhase?, to phase: RecordingPhase) {
        switch LiveInkFocus.change(from: previous, to: phase) {
        case .take:
            panel.makeKey()
            panel.makeFirstResponder(view)
        case .resign where panel.isKeyWindow:
            // An NSWindow can't resign key on its own; ordering it out and
            // straight back in drops key status without a visible flash.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        case .resign, .keep:
            break
        }
    }

    // MARK: - Publishing

    /// Pushes the model's scene to the view and the compositor, and runs the
    /// fade timer only while something fades.
    private func publish() {
        let scene = ink.scene
        compositor.update(scene)
        view.scene = scene
        updateFadeTimer()
    }

    /// Restarted on every publish (a redo can bring back a stroke that is
    /// due now): sleeps until the first fade starts, then redraws every frame
    /// until the last fading stroke is pruned.
    private func updateFadeTimer() {
        fadeTask?.cancel()
        fadeTask = nil
        guard ink.nextFadeRedraw(at: clock()) != nil else { return }
        fadeTask = Task { [weak self] in
            while !Task.isCancelled, let wait = self?.nextFadeWait() {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.fadeTick()
            }
        }
    }

    private func nextFadeWait() -> TimeInterval? {
        ink.nextFadeRedraw(at: clock()).map { max(Self.fadeFrameInterval, $0) }
    }

    private func fadeTick() {
        if ink.pruneExpired(at: clock()) {
            publish() // restarts the timer for whatever still fades
        } else {
            view.needsDisplay = true
        }
    }

    private static let fadeFrameInterval: TimeInterval = 1.0 / 60
}

/// Borderless, transparent, non-activating panel over the target: takes key
/// status without activating Snappy (ARCHITECTURE overlay invariants 1/4),
/// no fade animation (invariant 4), on every Space.
@MainActor
private final class InkPanelWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = RecordingWindowLevel.ink
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
}

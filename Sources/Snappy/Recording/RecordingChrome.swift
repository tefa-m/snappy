import AppKit

/// T4 — the recording chrome (`RecordingChromeHosting`): the border around the
/// target (amber in Setup, red while recording, outside the rect), the glass
/// toolbar under it, the countdown disc and the elapsed-time readout.
///
/// Three panels at `RecordingWindowLevel.chrome`, none of which ever becomes
/// key: the border and the countdown are click-through, and the toolbar takes
/// clicks without taking the keyboard — the Setup overlay (T1), the ink panel
/// in draw mode (T3) or the user's app (interact mode) keeps it. Nothing here
/// reaches the video: ScreenCaptureKit excludes Snappy by application, so no
/// chrome is drawn into frames.
///
/// Everything visible derives from the last `apply(session)`: the border colour
/// from `isCapturing`, the toolbar from the phase (`RecordingToolbarState`),
/// the numeral from `.countdown(remaining:)`, and the placement from
/// `session.target.frame` — which follows a moving window target.
@MainActor
final class RecordingChrome: RecordingChromeHosting {
    var onEvent: RecordingEventHandler?

    /// One per display the ring reaches (`ChromeLayout.BorderGeometry`), grown
    /// on demand; the unused ones are ordered out.
    private var borderPanels: [(panel: ChromePanel, view: RecordingBorderView)] = []
    private let toolbarPanel = ChromePanel(clickThrough: false)
    private let toolbar: RecordingToolbarView
    private let countdownPanel = ChromePanel(clickThrough: true)
    private let countdownView = CountdownView()

    private var session: RecordingSession?
    private var shownNumeral: Int?
    private var captureStart: ContinuousClock.Instant?
    private var timerTask: Task<Void, Never>?
    private var closed = false

    /// `drawModeKey`: the draw-mode hot key as the toolbar advertises it —
    /// the combo the coordinator registers for this session (read from the
    /// same settings at session start).
    init(drawModeKey: String, magicPenKey: String? = nil) {
        toolbar = RecordingToolbarView(drawModeKey: drawModeKey, magicPenKey: magicPenKey)
        countdownPanel.contentView = countdownView
        toolbarPanel.contentView = toolbar
        toolbar.onCommand = { [weak self] command in
            self?.onEvent?(.command(command))
        }
        // The readout widens at one hour (and at ten): re-fit the panel then,
        // not only on the next session change.
        toolbar.onFittingSizeChange = { [weak self] in
            guard let self, let session = self.session else { return }
            self.layout(for: session)
        }
    }

    /// The factory's no-argument form (`RecordingComponents.makeChrome`).
    convenience init() {
        self.init(
            drawModeKey: SettingsStore.shared.recordingDrawModeHotKey.displayString,
            magicPenKey: SettingsStore.shared.recordingMagicPenHotKey.displayString
        )
    }

    // MARK: - RecordingChromeHosting

    func setDrawModeShortcut(_ shortcut: String?) {
        guard !closed else { return }
        toolbar.setDrawModeKey(shortcut)
    }

    func setMagicPenShortcut(_ shortcut: String?) {
        guard !closed else { return }
        toolbar.setMagicPenKey(shortcut)
    }

    func setStopShortcut(_ shortcut: String?) {
        guard !closed else { return }
        toolbar.setStopKey(shortcut)
    }

    func show(_ session: RecordingSession, style: InkStyle) {
        guard !closed else { return }
        toolbar.apply(style: style)
        apply(session)
        toolbarPanel.orderFrontRegardless()
    }

    func apply(_ session: RecordingSession) {
        guard !closed else { return }
        self.session = session
        toolbar.apply(RecordingToolbarState(phase: session.phase))
        if session.phase == .stopping {
            freezeTimer()
        }
        layout(for: session)
        updateCountdown(session)
    }

    func apply(style: InkStyle) {
        guard !closed else { return }
        toolbar.apply(style: style)
    }

    func captureDidStart() {
        guard !closed, captureStart == nil else { return }
        let start = ContinuousClock.now
        captureStart = start
        toolbar.showElapsed(0, running: true)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                // Four updates a second: the readout turns within a quarter
                // second of the true time, and stays cheap.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.showElapsed(Self.seconds(since: start))
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        timerTask?.cancel()
        timerTask = nil
        toolbar.onCommand = nil
        toolbar.onFittingSizeChange = nil
        for border in borderPanels {
            border.panel.orderOut(nil)
        }
        toolbarPanel.orderOut(nil)
        countdownPanel.orderOut(nil)
    }

    // MARK: - Layout

    /// The toolbar panel's frame — for tests.
    var toolbarFrame: CGRect { toolbarPanel.frame }

    private func layout(for session: RecordingSession) {
        let target = session.target.frame
        let screens = NSScreen.screens
        let screenFrames = screens.map(\.frame)
        let screen = ChromeLayout.screenIndex(for: target, screenFrames: screenFrames)
            .map { screens[$0] } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? target

        layoutBorder(ChromeLayout.border(
            around: target, foldsAtScreenEdges: !session.target.isWindow, screenFrames: screenFrames
        ), capturing: session.isCapturing)
        let toolbarFrame = ChromeLayout.toolbarFrame(
            size: toolbar.fittingSize, target: target, visibleFrame: visibleFrame
        )
        if toolbarPanel.frame != toolbarFrame {
            toolbarPanel.setFrame(toolbarFrame, display: true)
        }
    }

    /// One click-through panel per display segment, each drawing the same
    /// global ring clipped to its own frame.
    private func layoutBorder(_ geometry: ChromeLayout.BorderGeometry, capturing: Bool) {
        while borderPanels.count < geometry.windowFrames.count {
            let panel = ChromePanel(clickThrough: true)
            let view = RecordingBorderView()
            panel.contentView = view
            borderPanels.append((panel, view))
        }
        for (index, border) in borderPanels.enumerated() {
            guard index < geometry.windowFrames.count else {
                border.panel.orderOut(nil)
                continue
            }
            let frame = geometry.windowFrames[index]
            if border.panel.frame != frame {
                border.panel.setFrame(frame, display: true)
            }
            border.view.isCapturing = capturing
            border.view.ring = geometry.outer.offsetBy(dx: -frame.minX, dy: -frame.minY)
            if !border.panel.isVisible {
                border.panel.orderFrontRegardless()
            }
        }
    }

    private func updateCountdown(_ session: RecordingSession) {
        guard let numeral = CountdownSequence.numeral(for: session.phase) else {
            shownNumeral = nil
            countdownPanel.orderOut(nil)
            return
        }
        let disc = ChromeLayout.countdownDiscFrame(in: session.target.frame)
        countdownView.show(numeral, diameter: disc.width)
        if countdownPanel.frame != disc {
            countdownPanel.setFrame(disc, display: true)
        }
        if shownNumeral == nil {
            countdownPanel.orderFrontRegardless()
        }
        if shownNumeral != numeral {
            shownNumeral = numeral
            announce(CountdownSequence.announcement(numeral: numeral, total: session.countdownSeconds))
        }
    }

    // MARK: - Timer

    /// One timer step (the task's tick; tests call it with a chosen time).
    func showElapsed(_ elapsed: TimeInterval) {
        guard !closed else { return }
        toolbar.showElapsed(elapsed, running: true)
    }

    /// Finalising: the readout keeps the final time, dimmed.
    private func freezeTimer() {
        timerTask?.cancel()
        timerTask = nil
        guard let start = captureStart else { return }
        toolbar.showElapsed(Self.seconds(since: start), running: false)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        (ContinuousClock.now - start) / .seconds(1)
    }

    /// The countdown is visual only; VoiceOver users hear it too.
    private func announce(_ text: String) {
        NSAccessibility.post(
            element: countdownView,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

// MARK: - Border

/// The border ring: a 1 pt dark hairline on the outside, then the 3 pt colour
/// band (`ChromeLayout`). `ring` is the ring's outer edge in this view's
/// coordinates — it may reach past the bounds when the ring spans displays or
/// leaves the screen, and is then clipped, never redrawn along the cut.
@MainActor
private final class RecordingBorderView: NSView {
    var isCapturing = false {
        didSet { if isCapturing != oldValue { needsDisplay = true } }
    }

    var ring: CGRect = .zero {
        didSet { if ring != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let hairline = ChromeLayout.borderHairlineWidth
        let thickness = ChromeLayout.borderThickness
        // Black @ 0.45 over white is #8C8C8C, 3.4:1; Increase Contrast makes
        // it near-solid. On dark content the band itself carries the edge.
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.black.withAlphaComponent(increaseContrast ? 0.85 : 0.45).setFill()
        ring(outer: ring, inner: ring.insetBy(dx: hairline, dy: hairline)).fill()
        // System colours, not fixed values (HIG Color): they adapt to
        // Increase Contrast. Amber = systemOrange (Setup), systemRed while
        // recording — and the state is never colour alone: the toolbar shows
        // ● / ■, the running timer and the menu bar ■.
        (isCapturing ? NSColor.systemRed : NSColor.systemOrange).setFill()
        ring(
            outer: ring.insetBy(dx: hairline, dy: hairline),
            inner: ring.insetBy(dx: thickness, dy: thickness)
        ).fill()
    }

    private func ring(outer: NSRect, inner: NSRect) -> NSBezierPath {
        let path = NSBezierPath(rect: outer)
        if inner.width > 0, inner.height > 0 {
            path.appendRect(inner)
        }
        path.windingRule = .evenOdd
        return path
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Panel

/// Borderless, transparent, non-activating panel that **never becomes key**:
/// a toolbar click must not take the keyboard from the Setup overlay, the ink
/// panel or the user's app. Overlay rules from ARCHITECTURE: `.nonactivatingPanel`,
/// `hidesOnDeactivate = false`, `animationBehavior = .none` (an `NSPanel`
/// would otherwise fade in and out), all Spaces, over full-screen apps.
@MainActor
private final class ChromePanel: NSPanel {
    init(clickThrough: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = RecordingWindowLevel.chrome
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = !clickThrough
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = clickThrough
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

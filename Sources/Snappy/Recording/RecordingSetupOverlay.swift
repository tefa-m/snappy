import AppKit

/// T1 — the recording Setup overlay (`RecordingSetupOverlaying`): one
/// transparent, **live** (not frozen) panel over the target's display that
/// dims everything outside the rect and edits it.
///
/// - Pointer mode: drag inside = move · 8 handles = resize · arrow keys nudge
///   1 pt (⇧ 10 pt) · ⌥-arrows move the right/top edge (⇧⌥ 10 pt) · scroll =
///   resize around the centre, aspect kept · drag outside = new free rect.
///   Always clamped to the display, never below
///   `SetupGeometry.minSize`. A window target (W) has no handles and doesn't
///   move — its rect is the window's; drag outside replaces it.
/// - Tool mode: rect frozen, no handles; the ink panel above (T3) draws.
/// - S / W snapping: hovering a window on this display makes it — or the
///   part of it under the pointer (`WindowPartModel`, Q35) — the target live
///   (`WindowSnapPicker`); the highlight glides between picks with a name +
///   size chip (Q36). ↑ / ↓ or scrolling widen / narrow the part; a click or
///   Return confirms (Q33). S/W/Esc are the session's.
/// - Countdown: draws nothing and lets the mouse through, but stays key so
///   Esc/Q returns to Setup. From `.recording` on: ordered out.
///
/// Draws no border — the amber/red border is the chrome's (T4). Reports every
/// change as a `RecordingEvent` and never mutates the session; the session
/// it was last given is the single source of truth for the rect.
///
/// Overlay invariants (ARCHITECTURE): a non-activating `NSPanel` that takes key
/// status without activating the app, `hidesOnDeactivate = false`,
/// `becomesKeyOnlyIfNeeded = false`, `animationBehavior = .none`; first mouse
/// accepted; an `.activeAlways` pointer tracking area (cursor updates in their
/// own key-window area); a local key monitor as the Esc fallback; `close()`
/// idempotent.
@MainActor
final class RecordingSetupOverlay: RecordingSetupOverlaying {
    var onEvent: RecordingEventHandler?

    private var panel: SetupOverlayPanel?
    /// Session, display and hovered window, plus every report the overlay
    /// makes on its own initiative (normalising the target, S ↔ W).
    private lazy var sync = SetupTargetSync { [weak self] event in self?.onEvent?(event) }
    private var session: RecordingSession? { sync.session }
    /// The target display's AppKit-global frame; every rect is clamped to it.
    private var display: CGRect { sync.display?.frame ?? .zero }
    private let picker = WindowSnapPicker()
    /// The part picker of the current snap visit (whole windows without
    /// Accessibility access).
    private var parts = WindowPartModel(tree: nil)
    private var gesture: SetupGeometry.Gesture?
    /// The aspect the current scroll-resize keeps and the rect it last made.
    /// Any other change of the target starts a fresh scroll gesture.
    private var scroll: (aspect: CGFloat, rect: CGRect)?
    private var keyMonitor: Any?
    private var screenObserver: (any NSObjectProtocol)?
    private var closed = false

    init() {}

    // MARK: - RecordingSetupOverlaying

    func show(_ session: RecordingSession) {
        guard !closed, panel == nil else { return }
        sync.display = Self.resolveDisplay(for: session.target)
        let panel = SetupOverlayPanel(frame: display)
        panel.overlayView.owner = self
        self.panel = panel
        installMonitors()
        apply(session)
    }

    /// Called from inside the coordinator's broadcast, so it never reports
    /// anything synchronously: a nested report would be overwritten in the
    /// peers by the rest of that broadcast. Corrections go through
    /// `sync.update`, which delivers them on the next main-queue turn.
    func apply(_ session: RecordingSession) {
        guard !closed, let panel else { return }
        let previousPhase = self.session?.phase
        sync.update(session)
        let phase = session.phase

        if phase != .setup(.pointer) { gesture = nil }
        updateSnapping(from: previousPhase, to: phase)

        switch phase {
        case .setup, .snapping, .countdown:
            // Countdown: nothing to click, so clicks reach the user's app —
            // but the panel stays key so Esc/Q still return to Setup.
            panel.ignoresMouseEvents = phase.isCountdown
            if !panel.isVisible { panel.orderFrontRegardless() }
            if phase != previousPhase { panel.makeKey() }
        case .recording, .stopping, .finished, .cancelled:
            panel.orderOut(nil)
        }
        render()
    }

    func close() {
        guard !closed else { return }
        closed = true
        sync.close()
        picker.cancel()
        parts = WindowPartModel(tree: nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Snapping

    /// Starts / stops the picker as snap mode is entered / left. (An S ↔ W
    /// switch over a hovered window is converted by `sync`.)
    private func updateSnapping(from previous: RecordingPhase?, to phase: RecordingPhase) {
        let wasSnapping = previous?.snapKind != nil
        switch (wasSnapping, phase.snapKind != nil) {
        case (false, true): loadSnapCandidates()
        case (true, false):
            picker.cancel()
            parts = WindowPartModel(tree: nil)
            sync.hovered = nil
            sync.hoveredPart = nil
        default: break
        }
    }

    /// Fresh list per visit (windows move between visits), and again when
    /// the display changes under it. Each visit gets its own part tree, so
    /// access granted since the last visit takes effect here.
    private func loadSnapCandidates() {
        sync.hovered = nil
        sync.hoveredPart = nil
        let tree = WindowPartAccess.shared.makeTree()
        tree?.onTreeChange = { [weak self] in self?.updateHover(at: NSEvent.mouseLocation) }
        parts = WindowPartModel(tree: tree)
        // The tree answers later (off the main thread): show its pick then.
        parts.onChange = { [weak self] in
            guard let self, session?.phase.snapKind != nil else { return }
            showPick(window: sync.hovered)
        }
        picker.load(screenFrame: display) { [weak self] in
            self?.updateHover(at: NSEvent.mouseLocation)
        }
    }

    /// From the mouse, the picker's load or the part tree — never inside a
    /// broadcast, so the hovered window and part are reported at once.
    private func updateHover(at point: CGPoint) {
        guard session?.phase.snapKind != nil, display.contains(point) else { return }
        let window = picker.window(at: point)
        parts.pointerMoved(to: point, over: window)
        showPick(window: window)
    }

    /// ↑ / ↓ or a scroll step changed the part (Q35).
    private func stepPart(_ step: WindowPartStep) {
        if parts.step(step, at: NSEvent.mouseLocation) { showPick(window: sync.hovered) }
    }

    private func showPick(window: SnapWindow?) {
        let part = window == nil ? nil : parts.part
        guard window != sync.hovered || part != sync.hoveredPart else { return }
        sync.hovered = window
        sync.hoveredPart = part
        // Report first: the broadcast renders the new target and the new
        // chip together, so highlight and chip glide as one (Q36). The
        // render after it only matters when the target didn't change.
        sync.reconcileNow()
        render()
    }

    // MARK: - Drawing

    private func render() {
        guard let session, let view = panel?.overlayView else { return }
        let target = session.target
        let local = SetupGeometry.localRect(of: target.frame, display: display)
        let hovered = sync.hovered
        switch session.phase {
        case .setup(let mode):
            view.content = SetupOverlayContent(
                rect: local,
                showsHandles: mode == .pointer && !target.isWindow,
                sizeText: SetupGeometry.sizeReadout(target.frame.size)
            )
        case .snapping:
            // The chip names the pick and sits on its frame (the window's or
            // the part's), whatever S clamps the target to.
            let level = hovered == nil ? nil : parts.current
            view.content = SetupOverlayContent(
                rect: local,
                highlightsWindow: hovered != nil,
                windowFrame: level.map { $0.frame.offsetBy(dx: -display.minX, dy: -display.minY) },
                title: level.map { WindowPartSelection.chipText(for: $0, appName: hovered?.appName) },
                isSnapping: true
            )
        default:
            view.content = .empty
        }
    }

    // MARK: - Mouse (AppKit global points, from the view)

    fileprivate func mouseDown(at point: CGPoint) {
        // Input never arrives inside a broadcast: settle a pending
        // correction first, so the gesture starts from the reported rect.
        sync.reconcileNow()
        guard let session, session.phase == .setup(.pointer) else { return }
        gesture = SetupGeometry.gesture(at: point, rect: session.target.frame, editable: !session.target.isWindow)
        if case .move = gesture { NSCursor.closedHand.set() }
    }

    fileprivate func mouseDragged(to point: CGPoint) {
        guard let session, let gesture, let id = sync.display?.id,
              let rect = SetupGeometry.rect(for: gesture, at: point, within: display)
        else { return }
        let target: RecordingTarget = if case .reselect = gesture {
            .area(globalRect: rect, displayID: id)
        } else {
            session.target.withFrame(rect)
        }
        report(target)
    }

    fileprivate func mouseUp(at point: CGPoint) {
        gesture = nil
        if session?.phase.snapKind != nil {
            // Make sure the target is the window clicked, then keep it.
            updateHover(at: point)
            if sync.hovered != nil { onEvent?(.confirmSnap) }
        }
        updateCursor(at: point)
    }

    fileprivate func mouseMoved(to point: CGPoint) {
        // Keys follow the pointer back to the overlay (invariant 3).
        if let panel, !panel.isKeyWindow, session?.phase.isPreRecording == true { panel.makeKey() }
        updateHover(at: point)
        updateCursor(at: point)
    }

    fileprivate func scrolled(deltaY: CGFloat, isPrecise: Bool, isMomentum: Bool) {
        sync.reconcileNow()
        if session?.phase.snapKind != nil {
            // Snapping: scrolling widens / narrows the part (Q35).
            if parts.scrolled(deltaY: deltaY, isPrecise: isPrecise, isMomentum: isMomentum, at: NSEvent.mouseLocation) {
                showPick(window: sync.hovered)
            }
            return
        }
        guard let session, session.phase == .setup(.pointer), !session.target.isWindow, gesture == nil,
              deltaY != 0
        else { return }
        let rect = session.target.frame
        let aspect = scroll.flatMap { $0.rect == rect ? $0.aspect : nil } ?? rect.width / rect.height
        let resized = SetupGeometry.scrollResized(
            rect, factor: SetupGeometry.scrollFactor(deltaY: deltaY), aspect: aspect, within: display
        )
        scroll = (aspect, resized)
        report(session.target.withFrame(resized))
    }

    private func report(_ target: RecordingTarget) {
        guard let session, target != session.target else { return }
        onEvent?(.targetChanged(target))
    }

    fileprivate func updateCursor(at point: CGPoint) {
        guard let session else { return }
        guard gesture == nil else { return } // the pressed cursor holds for the drag
        cursor(for: session, at: point).set()
    }

    private func cursor(for session: RecordingSession, at point: CGPoint) -> NSCursor {
        guard session.phase == .setup(.pointer) else { return .arrow }
        let editable = !session.target.isWindow
        switch SetupGeometry.hit(at: point, rect: session.target.frame, handles: editable) {
        case .handle(let handle):
            return NSCursor.frameResize(position: CursorGeometry.resizePosition(for: handle), directions: .all)
        case .inside:
            return editable ? .openHand : .arrow
        case .outside:
            return .crosshair
        }
    }

    // MARK: - Keys

    /// ↑ / ↓ part steps (snapping), arrow nudge / ⌥-arrow resize (Pointer
    /// mode, area target), then the recording key map. True when handled.
    fileprivate func keyDown(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        // R right after the overlay appeared must record the corrected rect.
        sync.reconcileNow()
        guard let session else { return false }
        if session.phase.snapKind != nil, let step = WindowPartStep(keyCode: keyCode, modifiers: modifiers) {
            stepPart(step)
            return true
        }
        if let edit = SetupGeometry.arrowEdit(keyCode: keyCode, modifiers: modifiers) {
            guard session.phase == .setup(.pointer), !session.target.isWindow else { return false }
            report(session.target.withFrame(SetupGeometry.applying(edit, to: session.target.frame, within: display)))
            return true
        }
        guard let command = RecordingKeyMap.command(
            phase: session.phase, keyCode: keyCode, characters: characters, modifiers: modifiers
        ) else { return false }
        if case .snapping(let kind, _, _) = session.phase, command == .snap(kind) {
            // Return / Enter confirm like a click: the pick under the pointer,
            // and nothing when no window is hovered.
            updateHover(at: NSEvent.mouseLocation)
            guard sync.hovered != nil else { return true }
        }
        onEvent?(.command(command))
        return true
    }

    /// Fallback for keys that reach another recording window first (the ink
    /// or chrome panel after a click) before recording starts: they are
    /// still Setup keys, and the overlay is the one place that maps them.
    /// Windows outside the recording levels (an editor, the screenshot panel)
    /// keep their own keys.
    private func monitoredKey(
        windowNumber: Int, keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard let panel, session?.phase.isPreRecording == true, windowNumber != panel.windowNumber,
              let window = NSApp.window(withWindowNumber: windowNumber),
              Self.recordingLevels.contains(window.level)
        else { return false }
        return keyDown(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    private static let recordingLevels = [RecordingWindowLevel.setup, RecordingWindowLevel.ink, RecordingWindowLevel.chrome]

    // MARK: - Monitors

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Read the event here: NSEvent is non-Sendable.
            let windowNumber = event.windowNumber
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers
            let modifiers = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                self?.monitoredKey(
                    windowNumber: windowNumber, keyCode: keyCode, characters: characters, modifiers: modifiers
                ) ?? false
            }
            return handled ? nil : event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// A resolution change, a display arranged elsewhere or unplugged: follow
    /// the (possibly fallback) display, reload the snap list for it, and let
    /// `sync` move an area target onto it under that display's ID.
    private func screensChanged() {
        guard let session, let panel else { return }
        sync.display = Self.resolveDisplay(for: session.target)
        panel.setFrame(display, display: false)
        if session.phase.snapKind != nil { loadSnapCandidates() }
        render()
        sync.reconcileNow() // a notification, not a broadcast
    }

    /// The target's display among the attached screens, ID and frame
    /// together (`SetupGeometry.display`).
    private static func resolveDisplay(for target: RecordingTarget) -> SetupGeometry.Display {
        let screens = NSScreen.screens.compactMap { screen in
            CaptureEngine.displayID(for: screen).map { SetupGeometry.Display(id: $0, frame: screen.frame) }
        }
        return SetupGeometry.display(for: target, among: screens)
            ?? SetupGeometry.Display(id: target.displayID, frame: NSScreen.main?.frame ?? target.frame)
    }
}

/// When and what the Setup overlay reports **on its own initiative** — the
/// target corrections no user gesture asked for (UI-free, so it is tested
/// against the real coordinator):
/// - the incoming target normalised onto its display (`SetupGeometry.desiredTarget`);
/// - S ↔ W switched over a hovered window, which changes the target's kind.
///
/// Both are discovered in `apply`, i.e. **inside** the coordinator's
/// broadcast. Reporting there would re-enter it: the nested broadcast would
/// update the peers, then the outer one would resume and overwrite them with
/// the older target. So `update` only schedules (`schedule`, the main queue
/// by default); the scheduled pass recomputes from the state *at delivery*
/// (so a stale or superseded correction reports nothing) and is dropped
/// after `close()`. Input handlers call `reconcileNow` first — they never
/// run inside a broadcast — so a key right after `show` (R!) already acts on
/// the corrected target.
@MainActor
final class SetupTargetSync {
    typealias Schedule = @MainActor (@escaping @MainActor () -> Void) -> Void

    private(set) var session: RecordingSession?
    var display: SetupGeometry.Display?
    /// The window under the mouse while snapping (nil: none / still loading).
    var hovered: SnapWindow?
    /// The part of it the part picker chose (nil: the whole window).
    var hoveredPart: SnapPart?

    private let report: RecordingEventHandler
    private let schedule: Schedule
    private var isScheduled = false
    private var isClosed = false

    static let mainQueue: Schedule = { work in
        DispatchQueue.main.async { work() }
    }

    init(schedule: @escaping Schedule = SetupTargetSync.mainQueue, report: @escaping RecordingEventHandler) {
        self.schedule = schedule
        self.report = report
    }

    /// From `apply` (inside the broadcast): remember, report later.
    func update(_ session: RecordingSession) {
        self.session = session
        guard !isScheduled, !isClosed else { return }
        isScheduled = true
        schedule { [weak self] in
            guard let self else { return }
            isScheduled = false
            reconcileNow()
        }
    }

    /// Reports the desired target if it differs. Only outside a broadcast:
    /// from input, a callback, a notification or the scheduled pass.
    func reconcileNow() {
        guard !isClosed, let session, let display,
              let desired = SetupGeometry.desiredTarget(
                  for: session, hovered: hovered, part: hoveredPart, display: display
              ),
              desired != session.target
        else { return }
        report(.targetChanged(desired))
    }

    func close() {
        isClosed = true
    }
}

private extension RecordingPhase {
    var snapKind: SnapKind? {
        if case .snapping(let kind, _, _) = self { return kind }
        return nil
    }

    var isCountdown: Bool {
        if case .countdown = self { return true }
        return false
    }
}

// MARK: - Panel

/// Borderless, transparent, non-activating panel covering the target display.
@MainActor
private final class SetupOverlayPanel: NSPanel {
    let overlayView = SetupOverlayView()

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = RecordingWindowLevel.setup
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        // NSPanel hides itself when the app deactivates; the overlay must not.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        // `.default` makes AppKit infer `.utilityWindow` for an NSPanel and
        // fade it in and out (overlay invariant 4).
        animationBehavior = .none
        // Never shown (borderless); VoiceOver announces it. Same name as the
        // menu item that starts the flow.
        title = "Record Area"
        contentView = overlayView
        makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - View

/// What the view draws, in its own coordinates.
struct SetupOverlayContent: Equatable {
    /// The undimmed rect (nil: none on this display — everything dimmed).
    var rect: CGRect?
    var dims = true
    var showsHandles = false
    var sizeText: String?
    /// Snapping: tint the hovered pick, name it above its frame (the chip
    /// glides with the highlight).
    var highlightsWindow = false
    var windowFrame: CGRect?
    var title: String?
    /// Snap mode (VoiceOver help changes with it).
    var isSnapping = false

    /// Countdown: nothing at all.
    static let empty = SetupOverlayContent(rect: nil, dims: false)
}

@MainActor
private final class SetupOverlayView: NSView {
    weak var owner: RecordingSetupOverlay?

    var content = SetupOverlayContent.empty {
        didSet {
            guard content != oldValue else { return }
            glide(from: oldValue)
            needsDisplay = true
            // VoiceOver reads the size the way the chip shows it.
            setAccessibilityValue(content.sizeText ?? content.title)
            if content.isSnapping != oldValue.isSnapping {
                setAccessibilityHelp(content.isSnapping ? Self.snappingHelp : Self.setupHelp)
            }
        }
    }

    /// The highlight's glide between picks (Q36): where it started, the
    /// chip's anchor then, and when. Nil when it rests on `content`.
    private var glideStart: (rect: CGRect, anchor: CGRect, time: CFTimeInterval)?
    private var glideLink: CADisplayLink?

    private static let setupHelp =
        "Drag inside to move the area, drag a handle to resize it, or drag outside to select a new one. "
            + "Arrow keys nudge it; Option-arrow keys or scrolling resize it. Press R to record, "
            + "S or W to snap to a window, "
            + "Escape or Q to cancel."

    private static let snappingHelp =
        "Point at a window or a part of it, such as a browser's page area. Up and Down arrow keys or scrolling "
            + "widen or narrow the part. Click or press Return to choose it; press the same snap key again, "
            + "Escape or Q to go back."

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Recording area")
        setAccessibilityHelp(Self.setupHelp)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    /// The first click already moves / resizes — no "click to focus first".
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // Pointer tracking must be .activeAlways (the app may be inactive);
        // cursor updates get their own key-window area — never .cursorUpdate
        // with .activeAlways (invariant 3).
        for options in [OverlayTracking.pointer, OverlayTracking.cursor] {
            addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
        }
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func cursorUpdate(with event: NSEvent) {
        owner?.updateCursor(at: globalPoint(event))
    }

    override func mouseMoved(with event: NSEvent) {
        owner?.mouseMoved(to: globalPoint(event))
    }

    override func mouseDown(with event: NSEvent) {
        owner?.mouseDown(at: globalPoint(event))
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.mouseDragged(to: globalPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        owner?.mouseUp(at: globalPoint(event))
    }

    override func scrollWheel(with event: NSEvent) {
        owner?.scrolled(
            deltaY: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas,
            isMomentum: !event.momentumPhase.isEmpty
        )
    }

    override func keyDown(with event: NSEvent) {
        let handled = owner?.keyDown(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags
        ) ?? false
        if !handled { super.keyDown(with: event) }
    }

    // MARK: Glide

    /// Starts a glide when the highlighted pick moves (Q36) — from wherever
    /// the highlight is drawn right now, so a quick sweep never jumps. A new
    /// or vanished pick, or Reduce Motion, shows the new rect at once.
    private func glide(from old: SetupOverlayContent) {
        guard old.highlightsWindow, content.highlightsWindow, let target = content.rect,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let shown = shownRects(for: old).rect, shown != target
        else {
            stopGlide()
            return
        }
        let anchor = shownRects(for: old).anchor ?? shown
        glideStart = (shown, anchor, CACurrentMediaTime())
        if glideLink == nil {
            let link = displayLink(target: self, selector: #selector(glideStep))
            link.add(to: .main, forMode: .common)
            glideLink = link
        }
    }

    /// The highlight and chip anchor as drawn now, for `content`.
    private func shownRects(for content: SetupOverlayContent) -> (rect: CGRect?, anchor: CGRect?) {
        guard let glideStart, let target = content.rect else { return (content.rect, content.windowFrame) }
        let progress = glideProgress(since: glideStart.time)
        return (
            WindowPartGlide.rect(from: glideStart.rect, to: target, progress: progress),
            WindowPartGlide.rect(from: glideStart.anchor, to: content.windowFrame ?? target, progress: progress)
        )
    }

    private func glideProgress(since start: CFTimeInterval) -> CGFloat {
        WindowPartGlide.progress(elapsed: CACurrentMediaTime() - start, reduceMotion: false)
    }

    @objc private func glideStep(_ link: CADisplayLink) {
        needsDisplay = true
        if let glideStart, glideProgress(since: glideStart.time) >= 1 { stopGlide() }
    }

    private func stopGlide() {
        glideStart = nil
        glideLink?.invalidate()
        glideLink = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopGlide() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        var content = content
        // Mid-glide the highlight and its chip are drawn where they are now.
        let shown = shownRects(for: content)
        content.rect = shown.rect
        content.windowFrame = shown.anchor
        // Read per draw, like the chips' Reduce Transparency check.
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if content.dims {
            // Even-odd: the rect stays a hole in the dimming. No `.copy`
            // punch-out, no transparency layer.
            let dimming = NSBezierPath(rect: bounds)
            if let rect = content.rect { dimming.append(NSBezierPath(rect: rect)) }
            dimming.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(SetupGeometry.dimmingAlpha(increaseContrast: increaseContrast)).setFill()
            dimming.fill()
        }
        guard let rect = content.rect else { return }

        if content.highlightsWindow {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            rect.fill()
        }
        if content.showsHandles {
            drawHandles(around: rect, increaseContrast: increaseContrast)
        }
        if let text = content.sizeText {
            OverlayChrome.drawChip(
                text,
                attributes: Self.sizeChipAttributes,
                frame: SetupGeometry.sizeChipFrame(
                    textSize: text.size(withAttributes: Self.sizeChipAttributes), rect: rect, bounds: bounds
                ),
                padding: OverlayGeometry.sizeChipPadding
            )
        }
        if let title = content.title,
           let chip = OverlayGeometry.titleChipFrame(
               textSize: title.size(withAttributes: Self.titleChipAttributes),
               window: content.windowFrame ?? rect,
               bounds: bounds
           ) {
            OverlayChrome.drawChip(
                title, attributes: Self.titleChipAttributes, frame: chip, padding: OverlayGeometry.titleChipPadding
            )
        }
    }

    /// Round white handles (like the system's own screen-recording
    /// selection) with the overlay edge's dark shade around them: fixed
    /// white/black, like all overlay chrome, because they sit on arbitrary
    /// screen content rather than app chrome — ≥ 5.7:1 on white, 21:1 on black.
    private func drawHandles(around rect: CGRect, increaseContrast: Bool) {
        NSColor.white.setFill()
        NSColor.black.withAlphaComponent(SetupGeometry.handleOutlineAlpha(increaseContrast: increaseContrast)).setStroke()
        for handle in SetupGeometry.handleRects(for: rect) {
            let path = NSBezierPath(ovalIn: handle)
            path.lineWidth = 1
            path.fill()
            path.stroke()
        }
    }

    private static let sizeChipAttributes: [NSAttributedString.Key: Any] = [
        // Monospaced digits: the chip doesn't jitter while the numbers change.
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private static let titleChipAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
}

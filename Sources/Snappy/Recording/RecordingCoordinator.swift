import AppKit

/// Owns at most one recording session (the `RecordingSession` state machine)
/// and wires the pieces together — Setup overlay (T1), pipeline (T2), live ink
/// (T3), chrome (T4), recording windows (v2 V1) — **only through the
/// protocols** in `RecordingContracts.swift`, built from the injected
/// `RecordingComponents`.
///
/// Every input, from any piece, the hot keys or the menu bar, becomes a
/// `RecordingEvent` and goes through `handle(_:)`: the session decides, the
/// coordinator pushes the result to every piece and runs the side effects
/// (countdown timer, pipeline start/stop, recording window). Pieces never
/// call each other.
///
/// Session lifecycle: `beginSession` (from `CaptureCoordinator`: the screenshot
/// panel's Record, "Record Area…"; or Retake) → Setup ↔ snapping → countdown →
/// recording → stopping → finished (recording window) | cancelled. The session
/// ends at finished/cancelled: every per-session piece is closed and dropped
/// and the session-only ⌃⌥D / ⌃⌥P hot keys are unregistered. Settings may
/// rebind them mid-session (`rebindSessionHotKey`).
///
/// **Session scoping.** Every sink, pipeline callback and asynchronous
/// start/stop result carries the id of the session that created it and is
/// dropped once that session has ended — a late callback from an old pipeline
/// can never move, stop or alert over a newer session.
///
/// **Draining.** A session that ends while its pipeline is still starting or
/// running (Cancel, a failure) orders its windows out at once, but the
/// coordinator stays *busy* until that pipeline's single `stop()` has returned:
/// no capture or recording can start meanwhile, so a new take never deletes a
/// file the old writer still owns, and the old decorator stays alive for as
/// long as the old stream may call it.
///
/// **Recording windows (v2, Q28–Q32, Q43).** Every finished take opens its
/// own persistent window; the coordinator owns all open ones (`windows`, like
/// the capture coordinator's `editors`) and releases each in its `onClose`.
/// They outlive sessions: a new recording neither closes nor deletes them.
/// Which takes stay on disk is `RecordingTakeLedger`'s call (open windows +
/// the latest take); the coordinator deletes what it releases.
@MainActor
final class RecordingCoordinator {
    /// The capture hot key center, for the session-only draw-mode toggle. Set
    /// by `AppDelegate` once the center exists (tests inject a fake).
    weak var hotKeys: (any SessionHotKeyRegistering)?

    /// Tells the person something they need to know without stopping them —
    /// the draw-mode or Magic Pen hot key couldn't be registered (one banner
    /// each, so both can show). Injectable for tests.
    var notify: @MainActor (BannerText) -> Void = { banner in
        UserNotifier.shared.post(
            banner, identifier: "snappy.recording.hotKey.\(banner.title)", alertIfUndelivered: true
        )
    }

    /// Overlap guard: false while any screenshot capture is in flight
    /// (`CaptureActivity.blocksRecording`). Installed by `CaptureCoordinator`,
    /// so capture and recording sessions block each other both ways.
    var canBeginSession: @MainActor () -> Bool = { true }

    /// Shows a recording failure (installed by `CaptureCoordinator`, which owns
    /// the app's alerts, including the Screen Recording permission alert).
    var onError: (@MainActor (any Error) -> Void)?

    /// The session phase after every phase change; nil once the session ended.
    /// `StatusItemController` listens (the red ● while recording).
    var onPhaseChange: (@MainActor (RecordingPhase?) -> Void)?

    /// The instant the pipeline started writing — the toolbar timer starts in
    /// the same main-actor turn, so the menu bar's `● 0:42` counts from the
    /// same moment. `StatusItemController` listens.
    var onCaptureStart: (@MainActor (ContinuousClock.Instant) -> Void)?

    /// The saved Magic Pen thickness after it changed — from the menu bar,
    /// Settings, [ ] or the toolbar's Width menu. `StatusItemController`
    /// listens (an open Settings window refreshes its pop-up).
    var onMagicPenWidthChange: (@MainActor (InkWidth) -> Void)?

    /// Hands the keyboard back to the user's app (`docs/ARCHITECTURE.md`
    /// › Recording). Called on every transition **into** interact mode — the
    /// record start and each draw → interact switch — and nowhere else.
    /// Injectable for tests. Activation is cooperative (ARCHITECTURE overlay
    /// invariant 1): Snappy is usually active here (the ⇧⌘4 drag activated
    /// it), so it explicitly yields to the user's app before asking it to
    /// activate; when Snappy isn't active the yield is a no-op.
    var activateUserApp: @MainActor (NSRunningApplication?) -> Void = { app in
        guard let app, app != NSRunningApplication.current, !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    /// Asks for Snappy's activation at the moment a recording starts to stop
    /// — inside the stop's own interaction (⇧⌘4, the toolbar ■, the menu bar
    /// ●), before the asynchronous finalisation, so the recording window can
    /// open with focus (Q44; window-pick pattern, ARCHITECTURE overlay
    /// invariant 1). A W-window auto-stop asks too, but has no interaction
    /// behind it, so macOS may decline. Injectable for tests.
    var activateSnappy: @MainActor () -> Void = { NSApplication.shared.activate() }

    /// Window parts (v2): the one-time Accessibility prompt on entering S/W
    /// snap mode (Q39), and the Chromium/Electron tree switches restored when
    /// the session ends or Snappy quits (Q40). Injectable for tests.
    var windowParts: any WindowPartSessionHooking = WindowPartAccess.shared

    /// The window server's look at a window — where a Retake's window target
    /// is now (Q41). Injectable for tests.
    var observeWindow: @MainActor (CGWindowID) -> WindowObservation = { WindowTracker.systemObservation(of: $0) }

    private let components: RecordingComponents
    private let settings: SettingsStore
    private let tempStore: RecordingTempStore

    private(set) var session: RecordingSession?
    /// Bumped by every `beginSession`; what scoped callbacks compare against.
    private var sessionID = 0
    private var sessionSettings = RecordingSettings()
    private var style = InkStyle(settings: RecordingSettings())

    // Per-session pieces (nil without a session).
    private var overlay: (any RecordingSetupOverlaying)?
    private var ink: (any LiveInkHosting)?
    private var chrome: (any RecordingChromeHosting)?
    /// The current session's pipeline run, from `prepareNewTake` on.
    private var run: CaptureRun?
    /// A run whose session ended before it stopped (see Draining).
    private var drainingRun: CaptureRun?
    /// Set when a capture failure (not the user) ends the session.
    private var endedByFailure = false

    /// Every open recording window — their only strong owner (released in
    /// `onClose`).
    private var windows: [any RecordingWindowHosting] = []
    /// Which takes stay on disk: open windows + the latest (Q30).
    private var ledger: RecordingTakeLedger
    /// Where each take was saved — outlives the windows (Reopen → Copy).
    private let savedFiles = RecordingSavedFiles()

    private var countdownTask: Task<Void, Never>?
    /// A Retake's look-up of its target (Q41); cancelled when the session ends.
    private var retakeRefresh: Task<Void, Never>?

    /// The app that was frontmost when the session's capture began. Keystrokes
    /// belong to it while recording (`docs/ARCHITECTURE.md` › Recording).
    private var userApp: NSRunningApplication?

    /// What Retake needs from a finished session (Q19). Each window's Retake
    /// carries its own; the latest one is kept for Reopen.
    private struct RetakeContext {
        let take: URL
        let target: RecordingTarget
        let userApp: NSRunningApplication?
        let setupInk: (any LiveInkSetupSnapshot)?
        let style: InkStyle
    }
    private var latestRetake: RetakeContext?

    /// What happens to a take whose capture failed mid-recording (disk full,
    /// writer error): **discarded**, and the error alert shows
    /// (2026-10-09 — final). `.salvage` would present whatever `stop()` still
    /// returns; the pipeline supports it, the product doesn't want it.
    private enum FailedTakeHandling { case discard, salvage }
    private static let failedTakeHandling = FailedTakeHandling.discard

    init(
        components: RecordingComponents = .current,
        settings: SettingsStore = .shared,
        tempStore: RecordingTempStore = RecordingTempStore()
    ) {
        self.components = components
        self.settings = settings
        self.tempStore = tempStore
        // After a relaunch, the newest take on disk is the one to reopen.
        ledger = RecordingTakeLedger(latest: tempStore.lastTake)
    }

    // MARK: - State

    var phase: RecordingPhase? { session?.phase }

    var isSessionActive: Bool { session != nil }

    /// A session is running, or an ended one's capture is still draining. No
    /// capture or recording may start while this is true.
    var isBusy: Bool { session != nil || drainingRun != nil }

    /// Enables the menu bar's "Reopen Last Recording": the latest take is on
    /// disk and no session is running or draining.
    var canReopenLastRecording: Bool {
        !isBusy && reopenableTake != nil
    }

    /// The latest take, while its file still exists (Caches can be purged).
    private var reopenableTake: URL? {
        guard let latest = ledger.latest,
              FileManager.default.fileExists(atPath: latest.path(percentEncoded: false)) else { return nil }
        return latest
    }

    /// The open window showing `take`, if any.
    private func openWindow(for take: URL) -> (any RecordingWindowHosting)? {
        windows.first { $0.isOpen && $0.take.standardizedFileURL == take.standardizedFileURL }
    }

    // MARK: - Entry points

    /// Starts a session in Setup on `target`. Returns false (with a beep) when
    /// a capture or recording session is already running or still draining.
    @discardableResult
    func beginSession(target: RecordingTarget, userApp: NSRunningApplication?) -> Bool {
        beginSession(target: target, userApp: userApp, retake: nil)
    }

    /// ⇧⌘4 while recording (`CaptureHotKeyRoute`), and the menu bar ■ (T4).
    func stop() {
        handle(.command(.stop))
    }

    /// Menu bar → "Reopen Last Recording": fronts the latest take's window
    /// when it is open — never a second copy (Q43) — else opens one.
    func reopenLastRecording() {
        guard !isBusy, let take = reopenableTake else {
            NSSound.beep()
            return
        }
        if let window = openWindow(for: take) {
            window.bringToFront()
            return
        }
        // Retake needs the session's target and setup ink, which only exist
        // for the take this run of the app recorded.
        let context = latestRetake?.take.standardizedFileURL == take.standardizedFileURL ? latestRetake : nil
        let anchor = context?.target.frame ?? NSScreen.main?.visibleFrame ?? .zero
        presentWindow(take: take, anchorRect: anchor, retake: context)
    }

    /// A window's Retake. Setup starts only when no session is busy; then the
    /// window closes first (its take is released unless it is the latest).
    /// Otherwise a beep, and the window stays.
    private func retake(_ context: RetakeContext) {
        guard !isBusy, canBeginSession() else {
            NSSound.beep()
            return
        }
        openWindow(for: context.take)?.close()
        beginSession(target: context.target, userApp: context.userApp, retake: context)
    }

    @discardableResult
    private func beginSession(
        target: RecordingTarget, userApp: NSRunningApplication?, retake: RetakeContext?
    ) -> Bool {
        guard !isBusy, canBeginSession() else {
            NSSound.beep()
            return false
        }
        // Recording windows stay open: they own their takes (Q30).

        sessionID += 1
        let id = sessionID
        let settingsValue = settings.recordingSettings
        sessionSettings = settingsValue
        style = retake?.style ?? InkStyle(settings: settingsValue)
        // The Magic Pen thickness is a setting, not part of a take's style.
        style.magicPenWidth = settingsValue.magicPenWidth
        endedByFailure = false
        self.userApp = userApp
        let session = RecordingSession(target: target, countdownSeconds: settingsValue.countdown.seconds)
        self.session = session
        windowParts.sessionBegan(target: target)

        let overlay = components.makeSetupOverlay()
        let ink = components.makeLiveInk()
        let chrome = components.makeChrome()
        let sink: RecordingEventHandler = { [weak self] event in self?.handle(event, session: id) }
        overlay.onEvent = sink
        ink.onEvent = sink
        chrome.onEvent = sink
        self.overlay = overlay
        self.ink = ink
        self.chrome = chrome

        // Session-only; another app may own the combo. Then the toolbar
        // doesn't advertise it and the person is told (the toggle still works).
        let combo = settingsValue.drawModeHotKey
        let registered = registerSessionHotKey(.drawMode, combo: combo, session: id)
        chrome.setDrawModeShortcut(registered ? combo.displayString : nil)
        // The Magic Pen toggle likewise. A combo equal to the draw-mode one
        // (possible with a hand-edited or pre-Magic-Pen draw-mode setting —
        // the Settings recorders refuse it) is not registered twice.
        let magicCombo = settingsValue.magicPenHotKey
        let magicRegistered = magicCombo != combo && registerSessionHotKey(.magicPen, combo: magicCombo, session: id)
        chrome.setMagicPenShortcut(magicRegistered ? magicCombo.displayString : nil)
        // Stop's tooltip names the configured Capture Area combo (⇧⌘4 stops)
        // — only while it is live.
        chrome.setStopShortcut(stopShortcut(settings.captureHotKey))

        // Window levels, not call order, stack them (`RecordingWindowLevel`).
        overlay.show(session)
        ink.show(session, style: style, settings: settingsValue, restoring: retake?.setupInk)
        chrome.show(session, style: style)

        if hotKeys != nil, !registered {
            notify(UserFacingText.drawModeHotKeyUnavailable(combo.displayString))
        }
        if hotKeys != nil, !magicRegistered {
            notify(UserFacingText.magicPenHotKeyUnavailable(magicCombo.displayString))
        }
        onPhaseChange?(session.phase)
        if retake != nil { refreshRetakeTarget(target, session: id) }
        return true
    }

    /// Registers a session hot key whose press goes to session `id`; false
    /// when the system refuses the combo (or there is no center).
    private func registerSessionHotKey(_ hotKey: SnappyHotKey, combo: HotKeyCombo, session id: Int) -> Bool {
        let command: RecordingCommand = hotKey == .magicPen ? .toggleMagicPen : .toggleDrawMode
        return hotKeys?.register(hotKey.action, combo: combo) { [weak self] in
            self?.handle(.command(command), session: id)
        } ?? false
    }

    /// Settings changed a session hot key (`GlobalHotKeys.set`): nil when no
    /// session holds the session hot keys (the next one reads the setting),
    /// else whether `combo` took. A refused combo leaves the old binding —
    /// and the toolbar's tooltip — as they were; one that took is advertised
    /// at once, also for a hot key the system had refused at session start.
    func rebindSessionHotKey(_ hotKey: SnappyHotKey, to combo: HotKeyCombo) -> Bool? {
        guard hotKey.isSessionOnly, let chrome, session != nil, let hotKeys else { return nil }
        // Registered (live, paused, or refused and waiting for a retry):
        // rebind — the new combo is held before the old is let go.
        let bound = if hotKeys.combo(for: hotKey.action) != nil {
            hotKeys.replace(hotKey.action, with: combo)
        } else {
            registerSessionHotKey(hotKey, combo: combo, session: sessionID)
        }
        guard bound else { return false }
        if hotKey == .magicPen {
            chrome.setMagicPenShortcut(combo.displayString)
        } else {
            chrome.setDrawModeShortcut(combo.displayString)
        }
        return true
    }

    /// Settings changed the Capture Area hot key — the open toolbar's Stop
    /// tooltip names the new combo at once.
    func captureHotKeyDidChange(_ combo: HotKeyCombo) {
        chrome?.setStopShortcut(stopShortcut(combo))
    }

    /// Stop's advertised shortcut: the Capture Area combo, or nil while the
    /// center holds it registered but unbound (refused at launch, or taken by
    /// another app while a Settings recorder paused the hot keys) — a dead
    /// combo is never promised. No center (tests): always advertised.
    private func stopShortcut(_ combo: HotKeyCombo) -> String? {
        if let hotKeys, hotKeys.combo(for: .captureArea) != nil, !hotKeys.isRegistered(.captureArea) { return nil }
        return combo.displayString
    }

    /// The keyboard layout changed, or a hot key went live / was lost (a
    /// resume, a retry): the open toolbar re-labels its tooltips, advertising
    /// only a live hot key — Stop's Capture Area combo included.
    func refreshHotKeyLabels() {
        guard let chrome, session != nil else { return }
        chrome.setStopShortcut(stopShortcut(settings.captureHotKey))
        guard let hotKeys else { return }
        let draw = hotKeys.combo(for: .toggleDrawMode)
        chrome.setDrawModeShortcut(hotKeys.isRegistered(.toggleDrawMode) ? draw?.displayString : nil)
        let magic = hotKeys.combo(for: .toggleMagicPen)
        chrome.setMagicPenShortcut(hotKeys.isRegistered(.toggleMagicPen) ? magic?.displayString : nil)
    }

    /// Retake (Q41): Setup opens at once on the take's target, then looks it
    /// up again — the window where it is now, a W + part's part at its live
    /// frame, or its whole window when the part is gone — inside the new
    /// session, so the Accessibility read counts as that session's use of
    /// the app (`WindowPartAccess`). Dropped once the person has changed the
    /// target or left Setup.
    private func refreshRetakeTarget(_ target: RecordingTarget, session id: Int) {
        guard let windowID = target.windowID else { return }
        var element: WindowPartElement?
        if case .windowPart(let part, _) = target { element = part.element }
        retakeRefresh = Task { [weak self] in
            // Checked **before** the read too: a Retake cancelled before this
            // task ran must not message the app — its session's restores are
            // already posted (review V3 finding 2). The read is enqueued on
            // the AX executor right here, on the main actor, so it precedes
            // any session end posted later.
            guard let self, self.isRetakeRefreshWanted(target, session: id) else { return }
            let livePartFrame = await element?.currentFrame()
            guard self.isRetakeRefreshWanted(target, session: id) else { return }
            let refreshed = target.refreshedForRetake(livePartFrame: livePartFrame, window: self.observeWindow(windowID))
            guard refreshed != target else { return }
            self.handle(.targetChanged(refreshed), session: id)
        }
    }

    /// The Retake's session is still in Setup on the take's target.
    private func isRetakeRefreshWanted(_ target: RecordingTarget, session id: Int) -> Bool {
        guard !Task.isCancelled, isCurrent(id), let session, session.target == target, case .setup = session.phase
        else { return false }
        return true
    }

    // MARK: - Magic Pen thickness

    /// The Magic Pen thickness the menu bar shows (its own setting).
    var magicPenWidth: InkWidth { settings.recordingMagicPenWidth }

    /// The Magic Pen Thickness chosen in the menu bar or Settings — the one
    /// path for both: persisted, and — during a session, in any phase —
    /// applied live to the next stroke (`features/recording.md` › Magic Pen).
    func setMagicPenWidth(_ width: InkWidth) {
        saveMagicPenWidth(width)
        guard session != nil, style.magicPenWidth != width else { return }
        style.magicPenWidth = width
        ink?.apply(style: style)
        chrome?.apply(style: style)
    }

    /// Persists the thickness and tells `onMagicPenWidthChange` if it changed.
    private func saveMagicPenWidth(_ width: InkWidth) {
        guard settings.recordingMagicPenWidth != width else { return }
        settings.recordingMagicPenWidth = width
        onMagicPenWidthChange?(width)
    }

    // MARK: - Events

    /// Input for the current session (hot keys, menu bar, tests).
    func handle(_ event: RecordingEvent) {
        handle(event, session: sessionID)
    }

    /// The single entry for every input. Events from a session that has ended
    /// are dropped.
    private func handle(_ event: RecordingEvent, session id: Int) {
        guard isCurrent(id), var current = session else { return }
        let outcome = current.handle(event)
        session = current

        switch outcome {
        case .ignored:
            return
        case .ink(let command):
            if command.isStyle {
                style = style.applying(command)
                if command.changesMagicPenWidth { saveMagicPenWidth(style.magicPenWidth) }
                ink?.apply(style: style)
                chrome?.apply(style: style)
            } else {
                ink?.perform(command)
            }
        case .changed(let from):
            didChange(from: from, to: current)
        }
    }

    private func isCurrent(_ id: Int) -> Bool {
        session != nil && sessionID == id
    }

    private func didChange(from previous: RecordingPhase, to session: RecordingSession) {
        let phase = session.phase
        if phase.isTerminal {
            end(session)
            return
        }
        if case .snapping = phase {
            if case .snapping = previous {} else { windowParts.snapModeEntered() }
        }
        overlay?.apply(session)
        ink?.apply(session)
        chrome?.apply(session)
        if phase != previous { onPhaseChange?(phase) }

        if case .countdown = phase {
            if case .countdown = previous {} else { startCountdown() }
        } else {
            stopCountdown()
        }
        if phase == .recording(.interact), previous != phase {
            activateUserApp(userApp)
        }
        if phase == .stopping, previous != .stopping {
            activateSnappy()
        }
        switch (previous, phase) {
        case (_, .recording) where !previous.isRecording:
            startCapture(session)
        case (_, .stopping) where previous != .stopping:
            stopCapture()
        default:
            break
        }
    }

    // MARK: - Countdown

    private func startCountdown() {
        countdownTask?.cancel()
        let id = sessionID
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, case .countdown = self.session?.phase else { return }
                self.handle(.countdownTick, session: id)
            }
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
    }

    // MARK: - Pipeline

    private func startCapture(_ session: RecordingSession) {
        let id = sessionID
        let url: URL
        do {
            // Deletes nothing: open windows and the latest take keep theirs.
            url = try tempStore.prepareNewTake()
        } catch {
            captureFailed(error, session: id)
            return
        }
        let pipeline = components.makePipeline()
        let decorator = ink?.frameDecorator ?? NullFrameDecorator()
        let run = CaptureRun(pipeline: pipeline, url: url, targetFrame: session.target.frame, decorator: decorator)
        self.run = run

        pipeline.onWindowFrameChange = { [weak self] frame in
            guard let self, self.isCurrent(id), let target = self.session?.target else { return }
            self.handle(.targetChanged(target.withWindowFrame(frame)), session: id)
        }
        // W + part: the part moved or resized inside its window (Q37/Q42 —
        // the border, toolbar and ink panel follow it).
        pipeline.onPartFrameChange = { [weak self] frame in
            guard let self, self.isCurrent(id), let target = self.session?.target,
                  case .windowPart = target else { return }
            self.handle(.targetChanged(target.withFrame(frame)), session: id)
        }
        pipeline.onWindowGone = { [weak self] in self?.handle(.windowGone, session: id) }
        pipeline.onFailure = { [weak self] error in self?.captureFailed(error, session: id) }

        let target = session.target
        let settingsValue = sessionSettings
        run.startTask = Task { [weak self] in
            do {
                try await pipeline.start(target: target, settings: settingsValue, decorator: decorator, outputURL: url)
            } catch {
                self?.captureFailed(error, session: id)
                throw error
            }
            // Only a session still recording starts its timer — not one that
            // was stopped or cancelled while the stream was being set up.
            guard let self, self.isCurrent(id), self.session?.phase.isRecording == true else { return }
            self.onCaptureStart?(.now)
            self.chrome?.captureDidStart()
        }
    }

    private func stopCapture() {
        let id = sessionID
        guard let run else {
            captureFailed(nil, session: id)
            return
        }
        let stop = run.stop()
        Task { [weak self] in
            do {
                let url = try await stop.value
                self?.handle(.captureFinished(url), session: id)
            } catch {
                self?.captureFailed(error, session: id)
            }
        }
    }

    /// Ends the session first, so the alert isn't under the recording windows.
    /// A failure from an ended session (draining after Cancel) is dropped.
    private func captureFailed(_ error: (any Error)?, session id: Int) {
        guard isCurrent(id) else { return }
        endedByFailure = true
        handle(.captureFailed, session: id)
        if let error { onError?(error) }
    }

    // MARK: - Session end

    /// Snappy is quitting (`AppDelegate`): `end` never runs on a quit, so the
    /// window-part tree switches are put back here (Q40). Idempotent with a
    /// later `end`.
    func applicationWillTerminate() {
        windowParts.applicationWillTerminate()
    }

    private func end(_ session: RecordingSession) {
        stopCountdown()
        retakeRefresh?.cancel()
        retakeRefresh = nil
        let setupInk = ink?.setupSnapshot()
        // Order everything out now; a still-running stream keeps only the
        // decorator, which the run retains until it is drained.
        overlay?.onEvent = nil
        ink?.onEvent = nil
        chrome?.onEvent = nil
        overlay?.close()
        ink?.close()
        chrome?.close()
        overlay = nil
        ink = nil
        chrome = nil
        hotKeys?.unregister(.toggleDrawMode)
        hotKeys?.unregister(.toggleMagicPen)

        let run = self.run
        self.run = nil
        // Before the AX restores: a still-draining run must not read a
        // part's frame after them (it would re-own a restored app's switch).
        run?.detachCallbacks()
        windowParts.sessionEnded()
        let failed = endedByFailure
        endedByFailure = false
        self.session = nil
        onPhaseChange?(nil)

        switch session.phase {
        case .finished(let url):
            // The run's stop() already returned: nothing left to drain.
            let context = RetakeContext(
                take: url, target: session.target, userApp: userApp, setupInk: setupInk, style: style
            )
            latestRetake = context
            takeFinished(url, anchorRect: session.target.frame, retake: context)
        default:
            // Cancelled, or failed. With no run, nothing was ever written and
            // the previous take is untouched (Q18).
            guard let run else { return }
            drain(run, keepTake: failed && Self.failedTakeHandling == .salvage)
        }
    }

    // MARK: - Recording windows

    /// A new take: it becomes the latest, every take the ledger no longer
    /// keeps is deleted (the previous latest with its window closed, and
    /// leftovers from an earlier run of the app), and its window opens.
    /// Only called once the take's run has stopped — no capture is writing.
    private func takeFinished(_ take: URL, anchorRect: CGRect, retake context: RetakeContext?) {
        _ = ledger.finished(take)
        tempStore.prune(keeping: ledger.kept)
        savedFiles.retain(only: ledger.kept)
        presentWindow(take: take, anchorRect: anchorRect, retake: context)
    }

    private func presentWindow(take: URL, anchorRect: CGRect, retake context: RetakeContext?) {
        var onRetake: (@MainActor () -> Void)?
        if let context {
            onRetake = { [weak self] in self?.retake(context) }
        }
        let window = components.makeRecordingWindow(take, anchorRect, onRetake, RecordingWindowContext(
            savedFiles: savedFiles,
            mayTakeFocus: { [weak self] in self.map { !$0.isBusy && $0.canBeginSession() } ?? false }
        ))
        ledger.opened(take)
        windows.append(window)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.windowClosed(window)
        }
        window.show()
    }

    /// Releases a closed window and deletes its take unless the ledger still
    /// keeps it (the latest, or shown by another window). Safe while a
    /// session records: the take being written is never in the ledger.
    private func windowClosed(_ window: any RecordingWindowHosting) {
        windows.removeAll { $0 === window }
        for take in ledger.closed(window.take) {
            tempStore.discard(take)
        }
        savedFiles.retain(only: ledger.kept)
    }

    /// Waits for the run's single `stop()`, then disposes of its take and
    /// releases the busy state.
    private func drain(_ run: CaptureRun, keepTake: Bool) {
        drainingRun = run
        let stop = run.stop()
        Task { [weak self] in
            let result = await stop.result
            guard let self else { return }
            if keepTake, case .success(let url) = result {
                self.takeFinished(url, anchorRect: run.targetFrame, retake: nil)
            } else {
                self.tempStore.discard(run.url)
            }
            if self.drainingRun === run { self.drainingRun = nil }
        }
    }
}

/// The session-only hot key registration the coordinator needs —
/// `HotKeyCenter` in the app, a fake in tests.
@MainActor
protocol SessionHotKeyRegistering: AnyObject {
    /// False when the system refused the combo (another app owns it).
    func register(_ action: HotKeyAction, combo: HotKeyCombo, handler: @escaping @MainActor () -> Void) -> Bool
    func unregister(_ action: HotKeyAction)
    /// True while a live binding backs the action.
    func isRegistered(_ action: HotKeyAction) -> Bool
    /// The registered combo, live or not; nil when not registered.
    func combo(for action: HotKeyAction) -> HotKeyCombo?
    /// Rebinds a registered action; false (old combo kept) when refused.
    func replace(_ action: HotKeyAction, with combo: HotKeyCombo) -> Bool
}

extension HotKeyCenter: SessionHotKeyRegistering {}

/// One pipeline run: from `prepareNewTake` to its **single** `stop()`.
@MainActor
private final class CaptureRun {
    let pipeline: any RecordingPipelining
    let url: URL
    let targetFrame: CGRect
    /// Retained until the run is drained: the stream may call it until
    /// `stop()` returns, even after the ink panel has closed.
    let decorator: any FrameDecorating
    var startTask: Task<Void, any Error>?
    private var stopTask: Task<URL, any Error>?

    init(pipeline: any RecordingPipelining, url: URL, targetFrame: CGRect, decorator: any FrameDecorating) {
        self.pipeline = pipeline
        self.url = url
        self.targetFrame = targetFrame
        self.decorator = decorator
    }

    /// Exactly one `pipeline.stop()` per run, after `start` has settled —
    /// every caller (Stop, Cancel, a failure) shares the same task.
    func stop() -> Task<URL, any Error> {
        if let stopTask { return stopTask }
        let start = startTask
        let pipeline = self.pipeline
        let task = Task {
            _ = try? await start?.value
            return try await pipeline.stop()
        }
        stopTask = task
        return task
    }

    /// The session ended: no callback reaches it any more, and the pipeline
    /// stops following the window and polling the part.
    func detachCallbacks() {
        pipeline.onWindowFrameChange = nil
        pipeline.onPartFrameChange = nil
        pipeline.onWindowGone = nil
        pipeline.onFailure = nil
        pipeline.endTracking()
    }
}

extension RecordingComponents {
    /// The implementations every session is built from (tests inject fakes).
    static var current: RecordingComponents {
        RecordingComponents(
            makeSetupOverlay: { RecordingSetupOverlay() },
            makeLiveInk: { LiveInkPanel() },
            makePipeline: { RecordingPipeline() },
            makeChrome: { RecordingChrome() },
            makeRecordingWindow: { RecordingWindowController(take: $0, anchorRect: $1, onRetake: $2, context: $3) }
        )
    }
}

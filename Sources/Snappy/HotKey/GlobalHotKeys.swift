import Foundation

/// What `GlobalHotKeys` needs from the hot key center — `HotKeyCenter` in
/// the app, a fake in tests.
@MainActor
protocol HotKeyRebinding: AnyObject {
    /// Binds `combo` to `action`; false when the system refuses it (the
    /// registration is kept, unbound, for a retry).
    @discardableResult
    func register(_ action: HotKeyAction, combo: HotKeyCombo, handler: @escaping @MainActor () -> Void) -> Bool
    /// Removes a registration and its Carbon hot key; a no-op when absent.
    func unregister(_ action: HotKeyAction)
    /// False when the system refuses `combo`; the action keeps its old one.
    /// The same combo again retries it when it isn't live.
    func replace(_ action: HotKeyAction, with combo: HotKeyCombo) -> Bool
    /// True when the system would register `combo` now.
    func isAvailable(_ combo: HotKeyCombo) -> Bool
    /// Releases (true) or re-binds (false) every Carbon hot key; one the
    /// system refuses on resume stays registered, unbound.
    func setSuspended(_ suspended: Bool)
    /// True while a live Carbon hot key backs the action.
    func isRegistered(_ action: HotKeyAction) -> Bool
    /// The action's registered combo (live or not); nil when not registered.
    func combo(for action: HotKeyAction) -> HotKeyCombo?
    /// Binds every unbound registration again; returns what still isn't.
    @discardableResult
    func retryUnbound() -> [HotKeyAction]
}

extension HotKeyCenter: HotKeyRebinding {}

/// The live side of the four remappable hot keys (`SnappyHotKey`) — the only
/// owner of the hot key center. Settings changes a combo only through `set` /
/// `reset`, which validate it, bind it at once and persist it only when it
/// took — so `SettingsStore` never holds a combo the system refused, and a
/// refused change leaves the old one working.
///
/// - Capture Area / Entire Screen are registered for the app's lifetime
///   (`installCaptureKeys`): rebound in place (`HotKeyCenter.replace`, which
///   acquires the new combo before releasing the old, so a refusal never
///   touches the old binding).
/// - Draw Mode / Magic Pen are session keys (`beginSession` / `endSession`):
///   while a session holds them they are rebound live; otherwise the combo
///   is probed (`isAvailable`) so a taken one is refused now, not at the next
///   session start.
@MainActor
final class GlobalHotKeys {
    private let settings: SettingsStore
    private let center: (any HotKeyRebinding)?

    /// The session keys' press handlers while a recording session holds
    /// them (`beginSession`); nil outside a session.
    private var sessionHandlers: [SnappyHotKey: @MainActor () -> Void]?

    private var labelObservers: [@MainActor () -> Void] = []

    /// `center` nil (tests, or no Carbon): combos are only validated and saved.
    init(settings: SettingsStore = .shared, center: (any HotKeyRebinding)?) {
        self.settings = settings
        self.center = center
    }

    /// The app's: the one Carbon `HotKeyCenter` — a second would break the
    /// routing (see `HotKeyCenter`).
    convenience init(settings: SettingsStore = .shared) {
        self.init(settings: settings, center: HotKeyCenter())
    }

    var bindings: HotKeyBindings { settings.hotKeyBindings }

    /// Registers Capture Area and Capture Entire Screen for the app's
    /// lifetime, with their stored combos. Capture Area is context-sensitive
    /// (`CaptureHotKeyRoute`): `phase` is the active recording session's
    /// phase (nil without one) — no session → `onCaptureArea`, recording →
    /// `onStopRecording`, the rest of a session → ignored.
    func installCaptureKeys(
        phase: @escaping @MainActor () -> RecordingPhase?,
        onCaptureArea: @escaping @MainActor () -> Void,
        onStopRecording: @escaping @MainActor () -> Void,
        onCaptureFullscreen: @escaping @MainActor () -> Void
    ) {
        guard let center else { return }
        center.register(.captureArea, combo: bindings.captureArea) {
            switch CaptureHotKeyRoute.route(for: phase()) {
            case .captureArea: onCaptureArea()
            case .stopRecording: onStopRecording()
            case .ignore: break
            }
        }
        center.register(.captureFullscreen, combo: bindings.captureFullscreen, handler: onCaptureFullscreen)
    }

    /// The Capture Area combo — what stops a recording — while it is live;
    /// nil when the system refused it, so no Stop label promises it.
    var liveStopCombo: HotKeyCombo? { isLive(.captureArea) ? bindings.captureArea : nil }

    /// A recording session starts: registers Draw Mode and Magic Pen with
    /// their stored combos, presses going to the handlers, and returns those
    /// the system refused (another app owns the combo) — each keeps its
    /// registration, unbound, for a retry. A Magic Pen combo equal to the
    /// Draw Mode one (a hand-edited setting — the recorders refuse it) is not
    /// registered twice and counts as refused.
    @discardableResult
    func beginSession(
        onDrawMode: @escaping @MainActor () -> Void,
        onMagicPen: @escaping @MainActor () -> Void
    ) -> [SnappyHotKey] {
        sessionHandlers = [.drawMode: onDrawMode, .magicPen: onMagicPen]
        guard let center else { return [] }
        var refused: [SnappyHotKey] = []
        let draw = bindings.drawMode
        if !center.register(.toggleDrawMode, combo: draw, handler: onDrawMode) { refused.append(.drawMode) }
        let magic = bindings.magicPen
        if magic == draw || !center.register(.toggleMagicPen, combo: magic, handler: onMagicPen) {
            refused.append(.magicPen)
        }
        return refused
    }

    /// The session ended: the session keys are released, so their combos
    /// reach other apps again.
    func endSession() {
        sessionHandlers = nil
        center?.unregister(.toggleDrawMode)
        center?.unregister(.toggleMagicPen)
    }

    /// The shortcut text to advertise for `hotKey` (tooltips, the menu bar
    /// ●), or nil while it isn't live — no label promises a dead shortcut.
    /// During a session a session key is advertised only while a live Carbon
    /// hot key backs it. No center (tests): always advertised.
    func label(for hotKey: SnappyHotKey) -> String? {
        guard let center else { return bindings[hotKey].displayString }
        if hotKey.isSessionOnly, sessionHandlers != nil {
            guard center.isRegistered(hotKey.action) else { return nil }
            return center.combo(for: hotKey.action)?.displayString
        }
        return isLive(hotKey) ? bindings[hotKey].displayString : nil
    }

    /// Calls `observer` whenever a `label(for:)` may have changed: a combo
    /// was bound and saved, the keyboard layout changed, or which hot keys
    /// are live did (a resume, a retry). Observers re-read what they show.
    func observeLabels(_ observer: @escaping @MainActor () -> Void) {
        labelObservers.append(observer)
    }

    /// Binds `combo` to `hotKey` and saves it; nil on success, else why it
    /// was refused (the old combo stays, bound and saved). The stored combo
    /// again is a retry: bound now if the system refused it before (at
    /// launch, or after a recorder's pause), with the real answer.
    @discardableResult
    func set(_ hotKey: SnappyHotKey, to combo: HotKeyCombo) -> HotKeyRecorderInput.Rejection? {
        var bindings = self.bindings
        let unchanged = bindings[hotKey] == combo
        if !unchanged, let conflict = bindings.conflict(for: hotKey, combo: combo) { return conflict }
        let wasLive = isLive(hotKey)
        guard bind(hotKey, to: combo) else { return .unavailable(combo) }
        if unchanged {
            if !wasLive { notifyLabels() }
            return nil
        }
        bindings[hotKey] = combo
        settings.hotKeyBindings = bindings
        notifyLabels()
        return nil
    }

    /// False while `hotKey` is registered but the system refuses its combo
    /// (another app took it) — Settings says so under the field. A session
    /// hot key outside a session isn't registered, so reads as live.
    func isLive(_ hotKey: SnappyHotKey) -> Bool {
        guard let center, center.combo(for: hotKey.action) != nil else { return true }
        return center.isRegistered(hotKey.action)
    }

    /// Tries every hot key the system refused again (Settings becoming key,
    /// the app becoming active).
    func retryUnbound() {
        guard let center else { return }
        center.retryUnbound()
        notifyLabels()
    }

    /// The keyboard layout changed: every combo keeps its key code (what
    /// Carbon binds) but may now read differently — every label is re-read.
    func keyboardLayoutDidChange() {
        KeyLegend.invalidate()
        notifyLabels()
    }

    /// Back to the default — refused like a typed combo.
    @discardableResult
    func reset(_ hotKey: SnappyHotKey) -> HotKeyRecorderInput.Rejection? {
        set(hotKey, to: hotKey.defaultCombo)
    }

    /// A Settings recorder is (true) / is no longer (false) waiting for a key:
    /// meanwhile no hot key swallows its combo, so ⇧⌘4 reaches the recorder
    /// (and is refused as already Snappy's) instead of starting a capture.
    /// Resuming may find a combo taken meanwhile: it stays registered,
    /// unbound, and the observers are told (`observeLabels`).
    func setRecorderActive(_ active: Bool) {
        center?.setSuspended(active)
        if !active { notifyLabels() }
    }

    private func notifyLabels() {
        for observer in labelObservers { observer() }
    }

    private func bind(_ hotKey: SnappyHotKey, to combo: HotKeyCombo) -> Bool {
        guard let center else { return true }
        if hotKey.isSessionOnly {
            guard let handler = sessionHandlers?[hotKey] else { return center.isAvailable(combo) }
            // Registered (live, paused, or refused and waiting for a retry):
            // rebind — the new combo is held before the old is let go.
            if center.combo(for: hotKey.action) != nil { return center.replace(hotKey.action, with: combo) }
            return center.register(hotKey.action, combo: combo, handler: handler)
        }
        return center.replace(hotKey.action, with: combo)
    }
}

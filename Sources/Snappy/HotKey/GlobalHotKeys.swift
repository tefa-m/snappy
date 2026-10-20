import Foundation

/// What `GlobalHotKeys` needs from the hot key center — `HotKeyCenter` in
/// the app, a fake in tests.
@MainActor
protocol HotKeyRebinding: AnyObject {
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

/// The live side of the four remappable hot keys (`SnappyHotKey`): Settings
/// changes a combo only through `set` / `reset`, which validate it, bind it
/// at once and persist it only when it took — so `SettingsStore` never holds
/// a combo the system refused, and a refused change leaves the old one
/// working.
///
/// - Capture Area / Entire Screen are registered for the app's lifetime:
///   rebound in place (`HotKeyCenter.replace`, which acquires the new combo
///   before releasing the old, so a refusal never touches the old binding).
/// - Draw Mode / Magic Pen are session-only: while a session holds them the
///   coordinator rebinds them live (`rebindSession`); otherwise the combo is
///   probed (`isAvailable`) so a taken one is refused now, not at the next
///   session start.
@MainActor
final class GlobalHotKeys {
    private let settings: SettingsStore
    private let center: (any HotKeyRebinding)?

    /// `RecordingCoordinator.rebindSessionHotKey`: nil when no session holds
    /// the session hot keys, else whether the new combo took.
    var rebindSession: @MainActor (SnappyHotKey, HotKeyCombo) -> Bool? = { _, _ in nil }

    /// A combo changed (after it was bound and saved), or its label did (the
    /// keyboard layout changed — `keyboardLayoutDidChange`) — the menu bar
    /// item's and the recording toolbar's Stop tooltips and the Settings
    /// fields follow.
    var onChange: [@MainActor (SnappyHotKey, HotKeyCombo) -> Void] = []

    /// Which hot keys are live may have changed (a resume, a retry) — the
    /// Settings fields re-check `isLive`.
    var onStatusChange: [@MainActor () -> Void] = []

    /// `center` nil (tests, or no Carbon): combos are only validated and saved.
    init(settings: SettingsStore = .shared, center: (any HotKeyRebinding)?) {
        self.settings = settings
        self.center = center
    }

    var bindings: HotKeyBindings { settings.hotKeyBindings }

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
            if !wasLive { notifyStatusChange() }
            return nil
        }
        bindings[hotKey] = combo
        settings.hotKeyBindings = bindings
        for listener in onChange { listener(hotKey, combo) }
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
        notifyStatusChange()
    }

    /// The keyboard layout changed: every combo keeps its key code (what
    /// Carbon binds) but may now read differently — re-announce all four.
    func keyboardLayoutDidChange() {
        KeyLegend.invalidate()
        for hotKey in SnappyHotKey.allCases {
            for listener in onChange { listener(hotKey, bindings[hotKey]) }
        }
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
    /// unbound, and the fields are told (`onStatusChange`).
    func setRecorderActive(_ active: Bool) {
        center?.setSuspended(active)
        if !active { notifyStatusChange() }
    }

    private func notifyStatusChange() {
        for listener in onStatusChange { listener() }
    }

    private func bind(_ hotKey: SnappyHotKey, to combo: HotKeyCombo) -> Bool {
        guard let center else { return true }
        if hotKey.isSessionOnly {
            return rebindSession(hotKey, combo) ?? center.isAvailable(combo)
        }
        return center.replace(hotKey.action, with: combo)
    }
}

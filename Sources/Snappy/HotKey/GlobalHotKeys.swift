import Foundation

/// What `GlobalHotKeys` needs from the hot key center — `HotKeyCenter` in
/// the app, a fake in tests.
@MainActor
protocol HotKeyRebinding: AnyObject {
    /// False when the system refuses `combo`; the action keeps its old one.
    func replace(_ action: HotKeyAction, with combo: HotKeyCombo) -> Bool
    /// True when the system would register `combo` now.
    func isAvailable(_ combo: HotKeyCombo) -> Bool
    /// Releases (true) or re-binds (false) every Carbon hot key.
    func setSuspended(_ suspended: Bool)
}

extension HotKeyCenter: HotKeyRebinding {}

/// The live side of the four remappable hot keys (`SnappyHotKey`): Settings
/// changes a combo only through `set` / `reset`, which validate it, bind it
/// at once and persist it only when it took — so `SettingsStore` never holds
/// a combo the system refused, and a refused change leaves the old one
/// working.
///
/// - Capture Area / Entire Screen are registered for the app's lifetime:
///   rebound in place (`HotKeyCenter.replace`, which restores the old combo
///   on failure).
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

    /// A combo changed (after it was bound and saved) — the menu, the
    /// recording toolbar's Stop tooltip and the Settings fields follow.
    var onChange: [@MainActor (SnappyHotKey, HotKeyCombo) -> Void] = []

    /// `center` nil (tests, or no Carbon): combos are only validated and saved.
    init(settings: SettingsStore = .shared, center: (any HotKeyRebinding)?) {
        self.settings = settings
        self.center = center
    }

    var bindings: HotKeyBindings { settings.hotKeyBindings }

    /// Binds `combo` to `hotKey` and saves it; nil on success, else why it
    /// was refused (the old combo stays, bound and saved).
    @discardableResult
    func set(_ hotKey: SnappyHotKey, to combo: HotKeyCombo) -> HotKeyRecorderInput.Rejection? {
        var bindings = self.bindings
        guard bindings[hotKey] != combo else { return nil }
        if let conflict = bindings.conflict(for: hotKey, combo: combo) { return conflict }
        guard bind(hotKey, to: combo) else { return .unavailable(combo) }
        bindings[hotKey] = combo
        settings.hotKeyBindings = bindings
        for listener in onChange { listener(hotKey, combo) }
        return nil
    }

    /// Back to the default — refused like a typed combo.
    @discardableResult
    func reset(_ hotKey: SnappyHotKey) -> HotKeyRecorderInput.Rejection? {
        set(hotKey, to: hotKey.defaultCombo)
    }

    /// A Settings recorder is (true) / is no longer (false) waiting for a key:
    /// meanwhile no hot key swallows its combo, so ⇧⌘4 reaches the recorder
    /// (and is refused as already Snappy's) instead of starting a capture.
    func setRecorderActive(_ active: Bool) {
        center?.setSuspended(active)
    }

    private func bind(_ hotKey: SnappyHotKey, to combo: HotKeyCombo) -> Bool {
        guard let center else { return true }
        if hotKey.isSessionOnly {
            return rebindSession(hotKey, combo) ?? center.isAvailable(combo)
        }
        return center.replace(hotKey.action, with: combo)
    }
}

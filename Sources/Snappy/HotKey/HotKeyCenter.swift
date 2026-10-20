import AppKit
import Carbon.HIToolbox

/// Stable ids for the app's global shortcuts. The Carbon handler is installed
/// **once** on the process-wide dispatcher target and receives *every* hot-key
/// event, so each registration needs its own id to be routed correctly.
/// Never reuse or reorder these values — append only.
enum HotKeyAction: UInt32, CaseIterable {
    case captureArea = 1
    case captureFullscreen = 2
    /// ⌃⌥D by default. Registered only while a recording session is active, so
    /// it never shadows the combo for other apps (`features/recording.md`).
    case toggleDrawMode = 3
    /// ⌃⌥P by default. Session-only like `toggleDrawMode` (Magic Pen).
    case toggleMagicPen = 4
    /// Never stays registered: `isAvailable` binds a combo under this id and
    /// releases it at once, to learn whether the system would accept it.
    case availabilityProbe = 5
}

/// Where ⇧⌘4 goes — PURE, tested. The capture hot key is context-sensitive
/// (`features/recording.md`): no recording session → area capture; recording
/// → stop; any other session phase (Setup, snapping, countdown, finalising)
/// → ignored, so a reflexive ⇧⌘4 never starts a capture over the session.
enum CaptureHotKeyRoute: Equatable {
    case captureArea
    case stopRecording
    case ignore

    /// `phase` is the active recording session's phase, nil without one.
    static func route(for phase: RecordingPhase?) -> CaptureHotKeyRoute {
        guard let phase, !phase.isTerminal else { return .captureArea }
        return phase.isRecording ? .stopRecording : .ignore
    }
}

/// Registers the app's system-wide hot keys via Carbon's `RegisterEventHotKey`
/// — the only way to get a global shortcut without the Accessibility
/// permission. A registered combo swallows the key event system-wide, which is
/// what lets Snappy's ⇧⌘4 / ⇧⌘3 replace the system screenshot shortcuts once
/// those are disabled in System Settings.
///
/// **One center owns every binding.** `InstallEventHandler` targets the
/// process-wide dispatcher, so a second center would install a second handler
/// on the same target; Carbon calls the most recently installed one first and
/// stops as soon as it returns `noErr`. Two centers would therefore route both
/// hot keys to whichever registered last. Hence: one handler, and the event's
/// `EventHotKeyID` decides which action fires.
@MainActor
final class HotKeyCenter {
    private struct Registration {
        var ref: EventHotKeyRef?
        var combo: HotKeyCombo
        let handler: @MainActor () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    /// While true every Carbon ref is released (the registrations stay) —
    /// see `setSuspended` — except one `replace` / `retry` bound since.
    private(set) var isSuspended = false
    private var eventHandlerRef: EventHandlerRef?

    /// Not `private static` on purpose: the C callback is nonisolated and
    /// cannot touch a `@MainActor`-isolated static.
    nonisolated static let signature: OSType = 0x534E_5059 // "SNPY"

    init() {
        installEventHandler()
    }

    /// Unregisters every hot key and the Carbon handler. The handler holds an
    /// unretained pointer to `self`, so it must not outlive the center.
    isolated deinit {
        for registration in registrations.values {
            if let ref = registration.ref { UnregisterEventHotKey(ref) }
        }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    /// Binds `combo` to `action`. Returns false when the system refuses it
    /// (typically: another app already owns the combo); the registration is
    /// kept anyway, unbound (`isRegistered` false), so `retryUnbound` and
    /// every resume try again — a refused combo is never silently forgotten.
    /// Registered while suspended, the combo is bound at once all the same:
    /// the answer is real, not a guess deferred to the resume.
    @discardableResult
    func register(_ action: HotKeyAction, combo: HotKeyCombo, handler: @escaping @MainActor () -> Void) -> Bool {
        // Registering an action twice must not leak the first Carbon hot key.
        if let existing = registrations[action.rawValue]?.ref {
            UnregisterEventHotKey(existing)
        }
        registrations[action.rawValue] = Registration(ref: acquire(action, combo), combo: combo, handler: handler)
        return isRegistered(action)
    }

    /// Removes a binding and its Carbon hot key, so the combo reaches other
    /// apps again. A no-op for an action that isn't registered. Used for the
    /// session-only draw-mode toggle; the capture hot keys stay for the app's
    /// lifetime.
    func unregister(_ action: HotKeyAction) {
        guard let registration = registrations.removeValue(forKey: action.rawValue) else { return }
        if let ref = registration.ref { UnregisterEventHotKey(ref) }
    }

    /// True only while a live Carbon hot key backs the action.
    func isRegistered(_ action: HotKeyAction) -> Bool {
        registrations[action.rawValue]?.ref != nil
    }

    /// The combo an action is registered with — live, suspended, or waiting
    /// for a retry after the system refused it.
    func combo(for action: HotKeyAction) -> HotKeyCombo? {
        registrations[action.rawValue]?.combo
    }

    /// Registered actions the system currently refuses (another app took the
    /// combo, e.g. while a Settings recorder had them released). Empty while
    /// suspended: nothing is meant to be live then.
    var unboundActions: [HotKeyAction] {
        guard !isSuspended else { return [] }
        return registrations.filter { $0.value.ref == nil }.keys.sorted().compactMap(HotKeyAction.init(rawValue:))
    }

    /// Rebinds a registered action to `combo` (Settings → Shortcuts). The new
    /// combo is acquired **before** the old one is let go, so a refusal
    /// leaves the old binding exactly as it was — no rollback that could
    /// itself fail. The same combo again is a retry: bound now if it isn't
    /// live. Also while suspended (a recorder just took a key): the answer
    /// is the real bind, so the resume never has to guess. False when the
    /// system refuses `combo` or the action isn't registered.
    @discardableResult
    func replace(_ action: HotKeyAction, with combo: HotKeyCombo) -> Bool {
        guard let registration = registrations[action.rawValue] else { return false }
        guard registration.combo != combo else { return registration.ref != nil || retry(action) }
        guard let ref = acquire(action, combo) else { return false }
        if let old = registration.ref { UnregisterEventHotKey(old) }
        registrations[action.rawValue]?.ref = ref
        registrations[action.rawValue]?.combo = combo
        return true
    }

    /// Binds an action's stored combo if no live hot key backs it — also
    /// while suspended (it is the action being recorded). True when it is
    /// live afterwards.
    @discardableResult
    func retry(_ action: HotKeyAction) -> Bool {
        guard let registration = registrations[action.rawValue] else { return false }
        if registration.ref == nil { registrations[action.rawValue]?.ref = acquire(action, registration.combo) }
        return isRegistered(action)
    }

    /// Tries every unbound registration again (Settings opening, the app
    /// becoming active); a no-op while suspended. Returns what is still
    /// unbound.
    @discardableResult
    func retryUnbound() -> [HotKeyAction] {
        guard !isSuspended else { return [] }
        for action in unboundActions { retry(action) }
        return unboundActions
    }

    /// True when the system would register `combo` now — bound under
    /// `.availabilityProbe` and released at once. A combo one of Snappy's own
    /// live bindings holds reads as unavailable (the recorders refuse those
    /// before asking).
    func isAvailable(_ combo: HotKeyCombo) -> Bool {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: HotKeyAction.availabilityProbe.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref
        )
        guard status == noErr else { return false }
        if let ref { UnregisterEventHotKey(ref) }
        return true
    }

    /// Suspended, no binding swallows its combo, so a Settings recorder can
    /// receive Snappy's own hot keys as ordinary key presses (and refuse
    /// them) instead of ⇧⌘4 starting a capture. Resuming re-binds every
    /// registration that isn't live (one bound by `replace` / `retry` while
    /// suspended already is). One the system now refuses — another app took
    /// the combo during the pause — **keeps its registration and combo**,
    /// unbound, and is listed by `unboundActions` for the UI to report and
    /// `retryUnbound` to try again.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        for (id, registration) in registrations {
            guard let action = HotKeyAction(rawValue: id) else { continue }
            if suspended {
                if let ref = registration.ref { UnregisterEventHotKey(ref) }
                registrations[id]?.ref = nil
            } else if registration.ref == nil {
                registrations[id]?.ref = acquire(action, registration.combo)
            }
        }
    }

    /// A Carbon hot key for `combo` under `action`'s id, or nil when the
    /// system refuses it. Carbon allows two refs with the same id, which is
    /// what lets `replace` hold the new combo before releasing the old.
    private func acquire(_ action: HotKeyAction, _ combo: HotKeyCombo) -> EventHotKeyRef? {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status != noErr {
            NSLog("Snappy: RegisterEventHotKey failed for %u (%d)", action.rawValue, status)
            return nil
        }
        return ref
    }

    fileprivate func handle(id: UInt32) {
        registrations[id]?.handler()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C callback: no captures allowed; `self` travels through userData.
        // Hot-key events are dispatched on the main thread's event loop.
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return noErr }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                let id = hotKeyID.id
                MainActor.assumeIsolated {
                    center.handle(id: id)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }
}

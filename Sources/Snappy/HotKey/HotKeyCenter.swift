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
        let handler: @MainActor () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
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

    /// Binds `combo` to `action`. Returns false — and keeps no binding —
    /// when the system refuses it (typically: another app already owns the
    /// combo).
    @discardableResult
    func register(_ action: HotKeyAction, combo: HotKeyCombo, handler: @escaping @MainActor () -> Void) -> Bool {
        // Registering an action twice must not leak the first Carbon hot key.
        if let existing = registrations[action.rawValue]?.ref {
            UnregisterEventHotKey(existing)
        }
        registrations[action.rawValue] = Registration(ref: nil, handler: handler)
        guard bind(action, to: combo) else {
            registrations[action.rawValue] = nil
            return false
        }
        return true
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

    /// Rebinds an already-registered action (for a future settings UI).
    func replace(_ action: HotKeyAction, with combo: HotKeyCombo) {
        guard var registration = registrations[action.rawValue] else { return }
        if let ref = registration.ref {
            UnregisterEventHotKey(ref)
            registration.ref = nil
            registrations[action.rawValue] = registration
        }
        bind(action, to: combo)
    }

    @discardableResult
    private func bind(_ action: HotKeyAction, to combo: HotKeyCombo) -> Bool {
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
            return false
        }
        registrations[action.rawValue]?.ref = ref
        return true
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

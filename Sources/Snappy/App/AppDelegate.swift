import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var captureCoordinator: CaptureCoordinator?
    private var recordingCoordinator: RecordingCoordinator?
    private var statusItemController: StatusItemController?
    private var globalHotKeys: GlobalHotKeys?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon, no app menu. LSUIElement covers the
        // bundled app; this also hides the Dock icon under `swift run`.
        NSApp.setActivationPolicy(.accessory)

        let recording = RecordingCoordinator()
        recordingCoordinator = recording
        let coordinator = CaptureCoordinator(recording: recording)
        captureCoordinator = coordinator
        // ⇧⌘4 → area capture, ⇧⌘3 → fullscreen by default (see
        // features/preview-panel.md: the system's own ⇧⌘4 / ⇧⌘3 must be
        // disabled in System Settings). One center owns every binding — see
        // HotKeyCenter for why a second would break the routing.
        let center = HotKeyCenter()
        // The session-only draw-mode / Magic Pen toggles register through it too.
        recording.hotKeys = center
        // `GlobalHotKeys` registers the capture keys (⇧⌘4 stops a recording
        // and is ignored during the rest of a session) and rebinds all four
        // live; a session's hot keys through the coordinator, which also
        // re-labels Stop.
        let hotKeys = GlobalHotKeys(center: center)
        hotKeys.installCaptureKeys(
            phase: { recording.phase },
            onCaptureArea: { coordinator.captureArea(trigger: .hotKey) },
            onStopRecording: { recording.stop() },
            onCaptureFullscreen: { coordinator.captureFullscreen(trigger: .hotKey) }
        )
        hotKeys.rebindSession = { hotKey, combo in recording.rebindSessionHotKey(hotKey, to: combo) }
        hotKeys.onChange.append { hotKey, combo in
            if hotKey == .captureArea { recording.captureHotKeyDidChange(combo) }
        }
        hotKeys.onStatusChange.append { recording.refreshHotKeyLabels() }
        globalHotKeys = hotKeys
        // Labels follow the keyboard layout (`KeyLegend`); the key codes —
        // what Carbon binds — don't change.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(keyboardLayoutDidChange),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil
        )
        // Coming back to Snappy retries a combo another app had taken.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        statusItemController = StatusItemController(
            captureCoordinator: coordinator, recordingCoordinator: recording, globalHotKeys: hotKeys
        )

        // Warm the shareable-content cache so the first ⇧⌘4 of the session is
        // as fast as the rest. A no-op until a capture has succeeded once —
        // otherwise this would trigger the Screen Recording prompt at login.
        CaptureEngine.primeShareableContentCache()
    }

    @objc private func keyboardLayoutDidChange() {
        globalHotKeys?.keyboardLayoutDidChange()
        recordingCoordinator?.refreshHotKeyLabels()
    }

    @objc private func applicationDidBecomeActive() {
        globalHotKeys?.retryUnbound()
    }

    /// Quit Snappy (menu or system): put back what a recording session
    /// changed in other apps — the window-part tree switches (Q40).
    func applicationWillTerminate(_ notification: Notification) {
        recordingCoordinator?.applicationWillTerminate()
    }
}

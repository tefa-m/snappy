import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var captureCoordinator: CaptureCoordinator?
    private var recordingCoordinator: RecordingCoordinator?
    private var statusItemController: StatusItemController?
    private var hotKeyCenter: HotKeyCenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon, no app menu. LSUIElement covers the
        // bundled app; this also hides the Dock icon under `swift run`.
        NSApp.setActivationPolicy(.accessory)

        let recording = RecordingCoordinator()
        recordingCoordinator = recording
        let coordinator = CaptureCoordinator(recording: recording)
        captureCoordinator = coordinator
        statusItemController = StatusItemController(captureCoordinator: coordinator, recordingCoordinator: recording)
        // ⇧⌘4 → area capture, ⇧⌘3 → fullscreen (see features/preview-panel.md:
        // the system's own ⇧⌘4 / ⇧⌘3 must be disabled in System Settings).
        // One center owns every binding — see HotKeyCenter for why a second
        // would break the routing. ⇧⌘4 is context-sensitive: it stops a
        // recording and is ignored during the rest of a recording session.
        let center = HotKeyCenter()
        center.register(.captureArea, combo: SettingsStore.shared.captureHotKey) {
            switch CaptureHotKeyRoute.route(for: recording.phase) {
            case .captureArea: coordinator.captureArea(trigger: .hotKey)
            case .stopRecording: recording.stop()
            case .ignore: break
            }
        }
        center.register(.captureFullscreen, combo: SettingsStore.shared.fullscreenHotKey) {
            coordinator.captureFullscreen(trigger: .hotKey)
        }
        hotKeyCenter = center
        // The session-only draw-mode toggle (⌃⌥D) registers through it too.
        recording.hotKeys = center

        // Warm the shareable-content cache so the first ⇧⌘4 of the session is
        // as fast as the rest. A no-op until a capture has succeeded once —
        // otherwise this would trigger the Screen Recording prompt at login.
        CaptureEngine.primeShareableContentCache()
    }

    /// Quit Snappy (menu or system): put back what a recording session
    /// changed in other apps — the window-part tree switches (Q40).
    func applicationWillTerminate(_ notification: Notification) {
        recordingCoordinator?.applicationWillTerminate()
    }
}

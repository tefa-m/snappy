import AppKit

/// What started a capture. The paths differ in one thing only: whether Snappy's
/// own status-bar menu needs time to fade before the shutter.
enum CaptureTrigger {
    case hotKey
    case menu

    /// nil for the hot key — waiting there would let a *foreign* menu or
    /// tooltip vanish, which is exactly what the frozen capture exists to keep.
    var menuFadeDelay: Duration? {
        self == .menu ? .milliseconds(250) : nil
    }
}

/// What the capture flows are doing right now — PURE, tested. Two gates come
/// out of it: the screenshot entry points keep their pre-recording behaviour
/// (`blocksCapture`, plus a busy recording), while a recording session waits
/// for *every* capture whose result hasn't been delivered yet
/// (`blocksRecording`) — a fullscreen snapshot or the window screenshot taken
/// after a pick would otherwise present its panel over Setup and steal key.
///
/// One rule for results (`dropsCaptureResult`): **an area selection or a window
/// pick supersedes every capture result not yet delivered**, just as starting
/// one closes a panel that is already up. A fullscreen snapshot or a post-pick
/// window screenshot still running when ⇧⌘4 or a window pick starts never
/// presents — not over the overlay, and not after it either (it would replace
/// the panel of the capture the user chose last).
struct CaptureActivity: Equatable {
    var areaCaptureInFlight = false
    var areaSelectionOpen = false
    var windowPickInFlight = false
    var windowPickOpen = false
    /// After a pick: the picker is gone, the 100 ms wait + screenshot are not.
    var windowCaptureInFlight = false
    /// From ⇧⌘3 / the menu item until the panel is shown (or the error).
    var fullscreenCaptureInFlight = false
    /// A recording session is running or draining (`RecordingCoordinator.isBusy`).
    var recordingBusy = false

    /// An area selection or window pick is open, or about to open (its freeze
    /// or content fetch is in flight).
    var interactiveSessionActive: Bool {
        areaCaptureInFlight || areaSelectionOpen || windowPickInFlight || windowPickOpen
    }

    /// Gates the screenshot entry points.
    var blocksCapture: Bool {
        interactiveSessionActive || recordingBusy
    }

    /// Gates `RecordingCoordinator.beginSession`.
    var blocksRecording: Bool {
        blocksCapture || windowCaptureInFlight || fullscreenCaptureInFlight
    }

    /// Whether a finished capture's result (its panel, or its error) is
    /// dropped. `superseded`: an area selection or window pick started after
    /// the request did (`PendingCaptures.supersedeAll`). A result never
    /// presents over a recording session or an interactive one either — the
    /// gates and `superseded` make those unreachable; they are the last line
    /// of defence.
    func dropsCaptureResult(superseded: Bool) -> Bool {
        superseded || interactiveSessionActive || recordingBusy
    }
}

/// Capture requests whose result hasn't been delivered yet, one token per
/// request — tested. The screenshot gates deliberately let a second fullscreen
/// capture (or a second post-pick window capture) start before the first
/// finishes, so a per-kind Boolean would be cleared by the *first* completion
/// while the second is still running. The recording gate asks whether *any*
/// token of a kind remains.
@MainActor
final class PendingCaptures {
    enum Kind: Hashable {
        /// From ⇧⌘3 / the menu item until the panel (or the error) is delivered.
        case fullscreen
        /// After a pick: the 100 ms wait + window screenshot.
        case window
    }

    struct Token: Hashable {
        fileprivate let id: Int
        let kind: Kind
    }

    private var tokens: Set<Token> = []
    /// Pending requests an area selection or window pick has superseded:
    /// still running (the recording gate waits for them), but their result
    /// is dropped.
    private var superseded: Set<Token> = []
    private var nextID = 0

    /// Call synchronously, before the request's first `await`.
    func begin(_ kind: Kind) -> Token {
        nextID += 1
        let token = Token(id: nextID, kind: kind)
        tokens.insert(token)
        return token
    }

    /// Idempotent: ending a token twice is a no-op.
    func end(_ token: Token) {
        tokens.remove(token)
        superseded.remove(token)
    }

    /// An area selection or window pick is starting: no request pending now
    /// may deliver its result. Requests begun later are unaffected.
    func supersedeAll() {
        superseded.formUnion(tokens)
    }

    func isSuperseded(_ token: Token) -> Bool {
        superseded.contains(token)
    }

    func isPending(_ kind: Kind) -> Bool {
        tokens.contains { $0.kind == kind }
    }

    var isEmpty: Bool { tokens.isEmpty }

    /// Runs the request's work and ends its token on **every** exit — return,
    /// early return or throw.
    func finishing<T>(_ token: Token, _ work: () async throws -> T) async rethrows -> T {
        defer { end(token) }
        return try await work()
    }
}

/// What an area selection is for. The screenshot path is the default and is
/// unchanged; "Record Area…" runs the same frozen drag and hands the rect to
/// recording Setup instead of the preview panel.
private enum AreaCapturePurpose {
    case screenshot
    case recording
}

/// Drives the three capture flows end to end: interactive selection → engine →
/// preview panel (Edit·Copy·Save·OCR·Pin·Record). Also owns the pin windows and
/// the editor spawned from the panel, and hands Record off to the
/// `RecordingCoordinator`.
@MainActor
final class CaptureCoordinator {
    private var areaSelection: AreaSelectionController?
    private var windowPick: WindowPickController?
    private var previewPanel: PreviewPanelController?
    private var pins: [PinWindowController] = []
    /// Every open editor, like `pins`: a controller is its window's only strong
    /// owner, so dropping the reference kills (or orphans) the session. Removed
    /// from `EditorWindowController.onClose` — i.e. on every way a window closes.
    private var editors: [EditorWindowController] = []
    /// The overlay only exists once the freeze returns, so `areaSelection` is
    /// nil for the first few tens of ms — this stops a double ⇧⌘4 from starting
    /// two freezes.
    private var areaCaptureInFlight = false
    /// Same idea for window capture: set synchronously, before the content
    /// fetch, so the picker does not exist yet but the session is already taken.
    private var windowPickInFlight = false
    /// Fullscreen captures and post-pick window screenshots still running —
    /// several of each kind may be pending at once.
    private let pendingCaptures = PendingCaptures()

    private var activity: CaptureActivity {
        CaptureActivity(
            areaCaptureInFlight: areaCaptureInFlight,
            areaSelectionOpen: areaSelection != nil,
            windowPickInFlight: windowPickInFlight,
            windowPickOpen: windowPick != nil,
            windowCaptureInFlight: pendingCaptures.isPending(.window),
            fullscreenCaptureInFlight: pendingCaptures.isPending(.fullscreen),
            recordingBusy: recording.isBusy
        )
    }

    /// True while any capture session (area freeze/selection, window fetch/pick)
    /// or a recording session (running or draining) owns the screen. Entry
    /// points bail rather than overlap.
    private var captureSessionActive: Bool { activity.blocksCapture }

    /// The app that was frontmost when the latest capture began — read before
    /// anything of ours activates. A recording started from that capture hands
    /// the keyboard back to it.
    private var userAppAtCapture: NSRunningApplication?

    private let settings: SettingsStore
    private let recording: RecordingCoordinator

    init(settings: SettingsStore = .shared, recording: RecordingCoordinator) {
        self.settings = settings
        self.recording = recording
        recording.canBeginSession = { [weak self] in
            guard let self else { return false }
            return !self.activity.blocksRecording
        }
        recording.onError = { [weak self] error in self?.handleRecordingError(error) }
    }

    // MARK: - Entry points

    /// Freezes every display, *then* activates and shows the selection overlay.
    ///
    /// Order matters twice over, and **nothing of ours may reach the screen
    /// before the snapshot**: activating first would dismiss the very context
    /// menu, menu-bar menu or tooltip the user is trying to capture, and so
    /// would merely ordering a panel front and making it key. Putting the
    /// overlay up early for an instant crosshair was tried and reverted — see
    /// the rejection note in `features/capture.md`.
    func captureArea(trigger: CaptureTrigger) {
        captureArea(trigger: trigger, purpose: .screenshot)
    }

    /// Menu bar → "Record Area…": the normal frozen ⇧⌘4 drag, then straight
    /// into recording Setup with that rect (no screenshot panel in between).
    func recordArea() {
        captureArea(trigger: .menu, purpose: .recording)
    }

    private func captureArea(trigger: CaptureTrigger, purpose: AreaCapturePurpose) {
        guard !captureSessionActive else { return }
        // Only reads state — nothing reaches the screen before the freeze.
        noteUserApp()
        // A panel would sit on top of the overlay — replace it, and any
        // result still on its way (`CaptureActivity.dropsCaptureResult`).
        dismissPreviewPanel()
        pendingCaptures.supersedeAll()
        areaCaptureInFlight = true

        Task {
            defer { areaCaptureInFlight = false }
            do {
                if let delay = trigger.menuFadeDelay {
                    try? await Task.sleep(for: delay)
                }
                let snapshots = try await CaptureEngine.snapshotAllScreens()
                guard areaSelection == nil, windowPick == nil, !windowPickInFlight else { return }
                beginAreaSelection(with: snapshots, purpose: purpose)
            } catch {
                handle(error)
            }
        }
    }

    private func beginAreaSelection(with snapshots: [FrozenScreen], purpose: AreaCapturePurpose) {
        let controller = AreaSelectionController(snapshots: snapshots) { [weak self] result in
            guard let self else { return }
            self.areaSelection = nil
            CaptureEngine.primeShareableContentCache()
            guard let result else { return }
            switch purpose {
            case .screenshot:
                self.finishAreaCapture(result)
            case .recording:
                self.beginRecording(rect: result.globalRect, screen: result.screen, screenFrame: result.frozen.frame)
            }
        }
        areaSelection = controller
        controller.begin()
    }

    func captureWindow() {
        guard !captureSessionActive else { return }
        noteUserApp()
        windowPickInFlight = true
        dismissPreviewPanel()
        pendingCaptures.supersedeAll()
        // Activate before the async content fetch, while the user interaction
        // still counts for cooperative activation.
        NSApp.activate()
        Task {
            defer { windowPickInFlight = false }
            do {
                let content = try await CaptureEngine.shareableContent()
                // An area capture can't start while we hold the flag, but be
                // defensive about anything that installed a session meanwhile.
                guard areaSelection == nil, windowPick == nil else { return }
                windowPick = WindowPickController(content: content) { [weak self] selection in
                    guard let self else { return }
                    self.windowPick = nil
                    guard let selection else { return }
                    let token = self.pendingCaptures.begin(.window)
                    Task {
                        await self.pendingCaptures.finishing(token) {
                            await self.performWindowCapture(selection, request: token)
                        }
                    }
                }
                windowPick?.begin()
            } catch {
                handle(error)
            }
        }
    }

    /// Never activates: the preview panel is a non-activating `NSPanel`, so the
    /// frontmost app keeps focus and its transient UI survives into the shot.
    func captureFullscreen(trigger: CaptureTrigger) {
        // A preview opened under an active selection overlay would be invisible
        // and would steal key status from it.
        guard !captureSessionActive else {
            NSSound.beep()
            return
        }
        noteUserApp()
        dismissPreviewPanel()
        let token = pendingCaptures.begin(.fullscreen)
        Task {
            await pendingCaptures.finishing(token) {
                await performFullscreenCapture(trigger: trigger, request: token)
            }
        }
    }

    private func performFullscreenCapture(trigger: CaptureTrigger, request: PendingCaptures.Token) async {
        // Only the menu path waits — for Snappy's *own* menu to fade.
        if let delay = trigger.menuFadeDelay {
            try? await Task.sleep(for: delay)
        }
        guard let screen = screenUnderMouse() else { return }
        do {
            let frozen = try await CaptureEngine.snapshot(of: screen)
            handle(frozen.image, anchorRect: frozen.frame, screen: frozen.screen, scale: frozen.scale, request: request)
            CaptureEngine.primeShareableContentCache()
        } catch {
            guard !dropsResult(of: request) else { return }
            handle(error)
        }
    }

    // MARK: - Capture steps

    /// Synchronous: the pixels were frozen at hot-key time, so this is a crop,
    /// not a capture. No compositor sleep either — the snapshot was taken before
    /// any overlay window existed.
    private func finishAreaCapture(_ selection: AreaSelectionResult) {
        let frozen = selection.frozen
        let pixelRect = CaptureGeometry.imagePixelRect(
            fromAppKitGlobal: selection.globalRect,
            screenFrame: frozen.frame,
            scale: frozen.scale,
            imagePixelSize: frozen.pixelSize
        )
        guard let image = CaptureEngine.crop(frozen.image, to: pixelRect) else {
            handle(CaptureError.noImage)
            return
        }
        handle(image, anchorRect: selection.globalRect, screen: frozen.screen, scale: frozen.scale)
    }

    private func performWindowCapture(_ selection: SCWindowSelection, request: PendingCaptures.Token) async {
        try? await Task.sleep(for: .milliseconds(100))
        do {
            let image = try await CaptureEngine.captureWindow(selection.window, scale: selection.scale)
            let screen = selection.screen ?? screenUnderMouse() ?? NSScreen.main
            guard let screen else { return }
            handle(image, anchorRect: selection.appKitFrame, screen: screen, scale: selection.scale, request: request)
        } catch {
            guard !dropsResult(of: request) else { return }
            handle(error)
        }
    }

    // MARK: - Result handling: the preview panel

    /// `scale` is the image's own pixels-per-point — for frozen captures that is
    /// the snapshot's derived scale, which can differ from the screen's backing
    /// scale by a rounding step. Pins size 1:1 from it. `request`: the pending
    /// fullscreen or window capture this result belongs to (nil for an area
    /// crop, delivered synchronously as its selection closes).
    private func handle(
        _ image: CGImage, anchorRect: CGRect, screen: NSScreen, scale: CGFloat, request: PendingCaptures.Token? = nil
    ) {
        guard !dropsResult(of: request) else { return }
        dismissPreviewPanel()
        let panel = PreviewPanelController(
            image: image,
            scale: scale,
            anchorRect: anchorRect,
            onAction: { [weak self] action in self?.performPanelAction(action) },
            onDismiss: { [weak self] in self?.previewPanel = nil }
        )
        previewPanel = panel
        panel.show(on: screen)
    }

    /// `CaptureActivity.dropsCaptureResult` for one request's result.
    private func dropsResult(of request: PendingCaptures.Token?) -> Bool {
        activity.dropsCaptureResult(superseded: request.map(pendingCaptures.isSuperseded) ?? false)
    }

    private func dismissPreviewPanel() {
        previewPanel?.close()
        previewPanel = nil
    }

    private func performPanelAction(_ action: PreviewAction) {
        guard let panel = previewPanel else { return }

        switch action {
        case .edit:
            dismissPreviewPanel()
            openEditor(image: panel.image, scale: panel.scale)

        case .copy:
            dismissPreviewPanel()
            Clipboard.copy(panel.image, scale: panel.scale)

        case .save:
            dismissPreviewPanel()
            do {
                try ScreenshotSaver.save(panel.image, scale: panel.scale, to: settings.saveDirectory)
            } catch {
                let folderName = FileManager.default.displayName(atPath: settings.saveDirectory.path)
                showAlert(UserFacingText.saveFailed(error, folderName: folderName))
            }

        case .ocr:
            dismissPreviewPanel()
            Task { await self.performOCR(on: panel.image) }

        case .pin:
            dismissPreviewPanel()
            // Pin appears exactly where the capture was taken, at 1:1 —
            // top-left aligned with the captured area.
            let size = panel.imagePointSize
            let frame = CGRect(
                x: panel.anchorRect.minX,
                y: panel.anchorRect.maxY - size.height,
                width: size.width,
                height: size.height
            )
            pin(image: panel.image, scale: panel.scale, frame: frame)

        case .record:
            dismissPreviewPanel()
            guard let screen = panel.screen else { return }
            beginRecording(rect: panel.anchorRect, screen: screen, screenFrame: screen.frame)
        }
    }

    // MARK: - Recording handoff

    /// Starts recording Setup on `rect`, clamped to its display (one display
    /// per recording). Beeps when the rect is off that display or a session is
    /// already running.
    private func beginRecording(rect: CGRect, screen: NSScreen, screenFrame: CGRect) {
        guard let displayID = CaptureEngine.displayID(for: screen),
              let target = RecordingTarget.area(rect, clampedTo: screenFrame, displayID: displayID)
        else {
            NSSound.beep()
            return
        }
        recording.beginSession(target: target, userApp: userAppAtCapture)
    }

    /// Snappy itself is frontmost after an area capture activated it; the
    /// last foreign app is still the one the user works in, so keep it then.
    private func noteUserApp() {
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != NSRunningApplication.current {
            userAppAtCapture = frontmost
        }
    }

    /// Shared by the panel's Edit action and a pin's Edit button (which closes
    /// the pin and reopens its image in the annotation editor).
    private func openEditor(image: CGImage, scale: CGFloat) {
        let editor = EditorWindowController(
            image: image,
            scale: scale,
            settings: settings,
            onPin: { [weak self] image, scale, frame in
                self?.pin(image: image, scale: scale, frame: frame)
            },
            onClose: { [weak self] editor in self?.editors.removeAll { $0 === editor } }
        )
        editors.append(editor)
        editor.show()
    }

    /// Shared by the panel's Pin action and the editor's Pin button (which
    /// pins the annotated result centered over the editor window).
    private func pin(image: CGImage, scale: CGFloat, frame: CGRect) {
        let pin = PinWindowController(
            image: image,
            scale: scale,
            frame: frame,
            onClose: { [weak self] pin in self?.pins.removeAll { $0 === pin } },
            onEdit: { [weak self] image, scale, _ in self?.openEditor(image: image, scale: scale) },
            onCopy: { Clipboard.copy($0, scale: $1) } // Copy keeps the pin open.
        )
        pins.append(pin)
        pin.show()
    }

    // MARK: - OCR (M3)

    /// One identifier for every OCR banner: each result replaces the last, so
    /// Notification Center never holds a backlog of recognized text.
    private static let ocrBannerID = "snappy.ocr-result"

    private func performOCR(on image: CGImage) async {
        do {
            let text = try await TextRecognizer.recognizeText(in: image)
            guard !text.isEmpty else {
                // Beeps + VoiceOver announcement when the banner can't be
                // shown: with the clipboard untouched, silence reads as success.
                UserNotifier.shared.post(
                    UserFacingText.noTextFound, identifier: Self.ocrBannerID, alertIfUndelivered: true
                )
                return
            }
            Clipboard.copy(text)
            UserNotifier.shared.post(UserFacingText.textCopied(text), identifier: Self.ocrBannerID)
        } catch {
            showAlert(UserFacingText.textRecognitionFailed(error))
        }
    }

    // MARK: - Errors

    private func handleRecordingError(_ error: Error) {
        if case CaptureError.permissionDenied = error {
            showPermissionAlert()
            return
        }
        showAlert(UserFacingText.recordingFailed(error))
    }

    private func handle(_ error: Error) {
        if case CaptureError.permissionDenied = error {
            showPermissionAlert()
            return
        }
        showAlert(UserFacingText.captureFailed(error))
    }

    /// Copy comes from `UserFacingText` — never `String(describing: error)`.
    private func showAlert(_ text: AlertText) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.runModal()
    }

    private func showPermissionAlert() {
        NSApp.activate()
        let alert = NSAlert()
        let text = UserFacingText.screenRecordingPermission
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: UserFacingText.openSystemSettingsButton)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}

import AppKit
import AVFoundation
import AVKit

/// V1 — the recording window (v2, Q28–Q32): a persistent, titled window for
/// one finished take, in the editor's Tahoe Glass look. The take plays in an
/// `AVPlayerView` (autoplay, loop, muted, scrub bar) that is the canvas under
/// a glass toolbar — Retake · Save · prominent Copy — with a glass status
/// capsule "W × H · 0:42 · [export size slider] 50 % · ≤ 4.6 MB" at the
/// bottom.
///
/// - Opens frontmost with focus (the deliberate end of the session), like the
///   editor, and survives click-away and app switches. It opens
///   **synchronously**, sized from the recorded area; the take's real size
///   and duration arrive later and only update the window, never focus.
/// - Activation is cooperative (`NSApplication.h`: `activate` may happen
///   later, or not at all). A declined request leaves the window front; it
///   takes key if Snappy becomes active within `focusGrace` — unless a newer
///   operation runs by then (`RecordingWindowContext.mayTakeFocus`).
/// - Space plays/pauses, R retakes, ⌘S saves (stays open), ⇧⌘C/⌘C copies
///   and closes, `[` / `]` step the export size, Q / Esc / ⌘W / the traffic
///   light close without a prompt — Q / Esc / ⌘W during a re-encode cancel
///   only the re-encode.
/// - **Export size** (`ExportScale`): Save and Copy export at the slider's
///   stop. 100 % is the take as is; a smaller stop re-encodes it into a
///   separate file first (`RecordingTranscoder`, kept in `exportCache`), with
///   progress on the pressed button. A failed re-encode exports nothing — it
///   never falls back to the full-size take.
/// - The window is this controller's, and the controller is the
///   coordinator's (an array, like the editors): `onClose` fires a run-loop
///   turn after any close, and the coordinator releases it there.
/// - **Never deletes its take** — the coordinator decides through
///   `RecordingTakeLedger` when `onClose` fires. Save stages a hard link
///   before it yields, so a take released meanwhile still saves.
@MainActor
final class RecordingWindowController: NSObject, RecordingWindowHosting {
    let take: URL
    private(set) var isOpen = true
    var onClose: (@MainActor () -> Void)?

    private let anchorRect: CGRect
    private let onRetake: (@MainActor () -> Void)?
    private let settings: SettingsStore
    private let window: RecordingWindow
    private let canvas: RecordingCanvasView
    private let player = AVQueuePlayer()
    /// Owns the re-queuing for the loop; lives as long as the playback.
    private var looper: AVPlayerLooper?
    private let toolbar: NSToolbar
    // The status capsule: "W × H · 0:42 · [slider] 50 % · 18.4 MB".
    private let infoLabel = NSTextField(labelWithString: "")
    private let infoSeparator = NSTextField(labelWithString: "·")
    private let scaleSlider = NSSlider()
    private let scaleLabel = NSTextField(labelWithString: "")
    private let sizeSeparator = NSTextField(labelWithString: "·")
    private let sizeLabel = NSTextField(labelWithString: "")
    /// The take's size, duration and frame rate once read (`apply`).
    private var info: RecordingVideoInfo?
    /// The take file's byte count, read when the window opens.
    private var takeBytes: Int64?
    /// The current export-size stop: Settings' default at open, then the
    /// slider's — never written back.
    private(set) var exportScale: ExportScale
    /// This window's re-encodes (one at a time, removed on close).
    private let exportCache = RecordingExportCache()
    /// The re-encode running for a Save or Copy, if any.
    private var encode: ExportEncode?
    /// The last re-encode failed — shown in place of the size until the stop
    /// changes or the next export starts.
    private var exportFailure: ExportScale?
    /// The capsule's stack, for its narrow-window behaviour (test hook).
    private var statusStack: NSStackView?
    private var loadTask: Task<Void, Never>?
    private let loadVideoInfo: @Sendable (URL) async -> RecordingVideoInfo
    /// Set once the window is on screen.
    private var isShown = false
    /// The frame `show` gave the window: the take's real size may still
    /// replace it, unless the person moved or resized the window meanwhile.
    private var initialFrame: CGRect?
    /// Where Save put a take — per take, so a reopened window still knows.
    private let savedFiles: RecordingSavedFiles
    private let context: RecordingWindowContext
    private let focus: RecordingWindowFocus
    /// A focus request still waiting for activation (see `takeFocus`).
    private var pendingFocus: PendingFocus?

    /// How long a declined or late activation may still make this window key.
    static let focusGrace: Duration = .seconds(1)
    /// One deferred activation retry, as for the area overlay (ARCHITECTURE
    /// overlay invariant 1).
    static let focusRetry: Duration = .milliseconds(150)

    /// `anchorRect`: the recorded area (AppKit global) — the window opens on
    /// the screen showing most of it, sized from it until the take's real
    /// size is known. `onRetake` nil hides Retake.
    init(
        take: URL, anchorRect: CGRect, onRetake: (@MainActor () -> Void)?, context: RecordingWindowContext,
        settings: SettingsStore = .shared,
        focus: RecordingWindowFocus = RecordingWindowFocus(),
        loadVideoInfo: @escaping @Sendable (URL) async -> RecordingVideoInfo = RecordingWindowController.videoInfo(of:)
    ) {
        self.take = take
        self.anchorRect = anchorRect
        self.onRetake = onRetake
        self.context = context
        savedFiles = context.savedFiles
        self.settings = settings
        self.focus = focus
        self.loadVideoInfo = loadVideoInfo
        exportScale = settings.recordingExportScale
        canvas = RecordingCanvasView(player: player)
        // Shared toolbar identifiers sync their items between windows, so the
        // two layouts (with and without Retake) need their own.
        toolbar = NSToolbar(identifier: onRetake == nil ? "SnappyRecordingToolbarNoRetake" : "SnappyRecordingToolbar")
        window = RecordingWindow(contentRect: CGRect(origin: .zero, size: RecordingWindowLayout.minWindowSize))
        super.init()

        window.delegate = self
        window.onAction = { [weak self] action in self?.perform(action) }
        window.title = RecordingWindowStatus.title(videoSize: nil)

        let container = NSView(frame: CGRect(origin: .zero, size: RecordingWindowLayout.minWindowSize))
        canvas.frame = container.bounds
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        installStatusCapsule(in: container)
        window.contentView = container

        // One unified header as in the editor: traffic lights and actions
        // share the transparent titlebar, the player runs underneath.
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = toolbar

        player.isMuted = true
    }

    // MARK: RecordingWindowHosting

    func show() {
        guard isOpen, !isShown else { return }
        present()
        loadTask = Task { [weak self, take, loadVideoInfo] in
            let info = await loadVideoInfo(take)
            guard let self, self.isOpen, !Task.isCancelled else { return }
            self.apply(info)
        }
    }

    func bringToFront() {
        guard isOpen, isShown else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        takeFocus()
    }

    func close() {
        guard isOpen else { return }
        if isShown {
            window.close() // → windowWillClose → finish()
        } else {
            finish()
        }
    }

    // MARK: Showing

    /// On screen at once, inside the end of the session — the recorded area's
    /// shape stands in for the video's until `apply` (review fix round 1,
    /// finding 1: a deferred presentation could take focus during a newer
    /// recording or screenshot capture).
    private func present() {
        takeBytes = Self.fileSize(take)
        refreshStatus()
        layOut(videoPoints: anchorRect.size)
        initialFrame = window.frame
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: take))
        isShown = true
        takeFocus()
        player.play()
    }

    /// The take's real size and duration: title, capsule and player aspect;
    /// the window's size too, unless the person already moved or resized it.
    /// **Never touches focus** — a newer operation may be running by now.
    private func apply(_ info: RecordingVideoInfo) {
        // Hidden in the titlebar, but VoiceOver, Mission Control and window
        // lists read it — and several recording windows can be open at once.
        window.title = RecordingWindowStatus.title(videoSize: info.size)
        self.info = info
        refreshStatus()
        guard let size = info.size else { return } // no readable track: keep the area's shape
        let videoPoints = RecordingWindowLayout.pointSize(
            videoPixels: size, scale: Self.screen(for: anchorRect)?.backingScaleFactor ?? 2
        )
        if window.frame == initialFrame {
            layOut(videoPoints: videoPoints)
            initialFrame = window.frame
        } else {
            canvas.videoSize = videoPoints
        }
    }

    /// Sizes the window for `videoPoints` and places it on the recorded
    /// area's screen, cascading off other recording windows.
    private func layOut(videoPoints: CGSize) {
        let visible = Self.screen(for: anchorRect)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        canvas.videoSize = videoPoints
        window.setContentSize(RecordingWindowLayout.contentSize(videoPoints: videoPoints, visible: visible.size))
        let occupied = NSApp.windows
            .filter { $0 is RecordingWindow && $0 !== window && $0.isVisible }
            .map(\.frame.origin)
        window.setFrameOrigin(RecordingWindowLayout.origin(
            windowSize: window.frame.size, visible: visible, occupied: occupied
        ))
        canvas.needsLayout = true
    }

    /// Frontmost with focus, like the editor (Q44) — only when the session
    /// ends (`show`) or on Reopen (`bringToFront`), both moments with an
    /// activation grant: the user-driven stops (⇧⌘4, toolbar ■, menu bar ●)
    /// already asked for activation when they were pressed
    /// (`RecordingCoordinator.activateSnappy`).
    ///
    /// Activation is cooperative and may arrive late or never (a W-window
    /// auto-stop has no user interaction). The window is then ordered front
    /// regardless; one retry follows after `focusRetry`, and an activation
    /// arriving within `focusGrace` makes it key — both only while no newer
    /// operation runs. After the grace, it takes key when clicked.
    private func takeFocus() {
        endPendingFocus()
        focusRequests += 1
        focus.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        guard !focus.isActive() else { return }
        awaitActivation()
    }

    private func awaitActivation() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationArrived() }
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.focusRetry)
            guard !Task.isCancelled, let self else { return }
            if !self.focus.isActive(), self.context.mayTakeFocus() { self.focus.activate() }
            try? await Task.sleep(for: Self.focusGrace - Self.focusRetry)
            guard !Task.isCancelled else { return }
            self.endPendingFocus()
        }
        pendingFocus = PendingFocus(observer: observer, timer: timer)
    }

    /// Snappy became active while this window was waiting for it.
    func activationArrived() {
        guard pendingFocus != nil else { return }
        endPendingFocus()
        guard isOpen, isShown, context.mayTakeFocus() else { return }
        // Another Snappy window that took key meanwhile keeps it.
        if let key = NSApp.keyWindow, key !== window { return }
        window.makeKeyAndOrderFront(nil)
        lateKeyGrants += 1
    }

    private func endPendingFocus() {
        guard let pendingFocus else { return }
        NotificationCenter.default.removeObserver(pendingFocus.observer)
        pendingFocus.timer.cancel()
        self.pendingFocus = nil
    }

    // Test hooks: how often this window asked for focus, and how often a late
    // activation made it key.
    private(set) var focusRequests = 0
    private(set) var lateKeyGrants = 0
    var isAwaitingActivation: Bool { pendingFocus != nil }
    var windowTitle: String { window.title }

    /// Every close path ends here, once: playback stops, then — a turn
    /// later, because closing is often triggered from this controller's own
    /// methods (Copy) and AppKit still talks to the delegate — `onClose`.
    private func finish() {
        guard isOpen else { return }
        isOpen = false
        loadTask?.cancel()
        encode?.job.cancel()
        encode = nil
        exportCache.discard()
        endPendingFocus()
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        canvas.detachPlayer()
        Task { @MainActor [self] in onClose?() }
    }

    /// The bottom status capsule: the readout plus the export-size slider,
    /// so — unlike the editor's — it takes the mouse.
    private func installStatusCapsule(in container: NSView) {
        for label in [infoLabel, infoSeparator, scaleLabel, sizeSeparator, sizeLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        infoSeparator.setAccessibilityElement(false)
        sizeSeparator.setAccessibilityElement(false)

        // Four stops, snapping, 25 % at the left: [ and ] step it too.
        scaleSlider.minValue = 0
        scaleSlider.maxValue = Double(ExportScale.allCases.count - 1)
        scaleSlider.numberOfTickMarks = ExportScale.allCases.count
        scaleSlider.allowsTickMarkValuesOnly = true
        scaleSlider.controlSize = .small
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleSliderChanged)
        scaleSlider.toolTip = "Change export size ([ ])"
        scaleSlider.setAccessibilityLabel("Export size")
        scaleSlider.translatesAutoresizingMaskIntoConstraints = false
        // Wide enough for "100 %", so the size readout never shifts.
        scaleLabel.alignment = .right
        let widest = (ExportScale.full.title as NSString).size(withAttributes: [.font: scaleLabel.font as Any]).width
        scaleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(widest) + 2).isActive = true
        scaleLabel.setAccessibilityElement(false) // the slider's value says it

        let stack = NSStackView(views: [infoLabel, infoSeparator, scaleSlider, scaleLabel, sizeSeparator, sizeLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(2, after: scaleSlider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Too narrow for everything (four-digit sides, a long take, "Export
        // failed" at the 440 pt minimum): the dimensions · duration readout
        // goes first — the title still names the take's size — so the
        // slider and the size always stay whole.
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: infoLabel)
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: infoSeparator)
        statusStack = stack

        let glass = NSGlassEffectView()
        glass.cornerRadius = RecordingWindowLayout.statusCapsuleHeight / 2
        let inner = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(stack)
        glass.contentView = inner
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            // ≥ 28 pt hit target for the slider (Design direction).
            scaleSlider.widthAnchor.constraint(equalToConstant: 96),
            scaleSlider.heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
            inner.topAnchor.constraint(equalTo: glass.topAnchor),
            inner.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            glass.heightAnchor.constraint(equalToConstant: RecordingWindowLayout.statusCapsuleHeight),
            glass.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            glass.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 10),
            glass.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
    }

    /// The capsule for the current stop: the export's pixel size and the
    /// duration, the slider, and the size — the real file's when one exists
    /// at this stop, else the "≤" estimate; a failed re-encode's message in
    /// its place.
    private func refreshStatus() {
        let source = ExportSizing.videoSize(pixels: info?.size)
        let output = source.map { ExportSizing.videoSize(source: $0, scale: exportScale) }
        infoLabel.stringValue = ExportSizeText.dimensionsAndDuration(videoSize: output, duration: info?.duration)
        infoSeparator.isHidden = infoLabel.stringValue.isEmpty
        scaleSlider.integerValue = exportScale.index
        scaleSlider.setAccessibilityValueDescription(exportScale.title)
        scaleLabel.stringValue = exportScale.title

        if let exportFailure, exportFailure == exportScale {
            sizeLabel.stringValue = ExportSizeText.failure
            sizeLabel.textColor = .systemRed
        } else {
            let estimate = output.flatMap { size in
                info?.duration.map { duration in
                    ExportSizing.estimatedBytes(
                        videoSize: size, framesPerSecond: ExportSizing.framesPerSecond(nominal: info?.framesPerSecond ?? 0),
                        quality: settings.recordingQuality, duration: duration
                    )
                }
            }
            sizeLabel.stringValue = ExportSizeText.size(actual: actualBytes(at: exportScale), estimate: estimate)
            sizeLabel.textColor = .secondaryLabelColor
        }
        sizeSeparator.isHidden = sizeLabel.stringValue.isEmpty
    }

    /// The real export's byte count at `scale`: the take at 100 %, else a
    /// finished re-encode or a file saved at that stop.
    private func actualBytes(at scale: ExportScale) -> Int64? {
        if scale == .full { return takeBytes }
        let file = exportCache.file(at: scale) ?? savedFiles.savedFile(for: take, scale: scale)
        return file.flatMap(Self.fileSize)
    }

    /// Moves the slider's stop — a per-take choice, never saved to Settings.
    private func setExportScale(_ scale: ExportScale) {
        guard scale != exportScale else {
            scaleSlider.integerValue = exportScale.index
            return
        }
        exportScale = scale
        exportFailure = nil
        refreshStatus()
    }

    @objc private func scaleSliderChanged() {
        setExportScale(ExportScale(index: Int(scaleSlider.doubleValue.rounded())))
    }

    // Test hooks: the capsule's readouts.
    var statusInfoText: String { infoLabel.stringValue }
    var statusSizeText: String { sizeLabel.stringValue }
    var exportScaleTitleForTesting: String { scaleLabel.stringValue }

    /// Test hook: shows `info` (and a failed re-encode at the current stop)
    /// without reading a take.
    func showStatusForTesting(_ info: RecordingVideoInfo, failed: Bool) {
        apply(info)
        exportFailure = failed ? exportScale : nil
        refreshStatus()
    }

    /// Test hook: the window at `width` points — even below its minimum
    /// (content wider than the window, e.g. at a larger text size).
    func resizeForTesting(width: CGFloat) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: false)
    }

    /// Test hook: the capsule's labels that are on screen, each with whether
    /// it shows its whole text inside the window's content.
    func statusLabelsFitForTesting() -> [(text: String, fits: Bool)] {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let stack = statusStack, let content = window.contentView else { return [] }
        return [infoLabel, scaleLabel, sizeLabel].filter { stack.views.contains($0) && !$0.isHidden }.map { label in
            let frame = label.convert(label.bounds, to: content)
            let whole = frame.width + 0.5 >= ceil(label.intrinsicContentSize.width)
            return (label.stringValue, whole && content.bounds.contains(frame))
        }
    }

    private var saveFolderName: String {
        FileManager.default.displayName(atPath: settings.saveDirectory.path)
    }

    /// The Save tooltip names the folder Save will actually write to; the
    /// folder can change in Settings while the window stays open.
    private func refreshSaveToolTip() {
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == .recordingSave }) else { return }
        item.toolTip = RecordingWindowAction.save.toolTip(saveFolderName: saveFolderName)
    }

    // MARK: Actions

    // Internal (not private) only so tests can drive the actions.
    func perform(_ action: RecordingWindowAction) {
        guard isOpen, isShown else { return }
        switch action {
        case .playPause:
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        case .retake:
            // Only a request: the coordinator closes this window when Setup
            // can start, and beeps (window kept) when a session is busy.
            guard let onRetake else {
                NSSound.beep()
                return
            }
            onRetake()
        case .save:
            saveTake()
        case .copy:
            copyTake()
        case .close:
            // During a re-encode, Q / Esc / ⌘W cancel only the re-encode.
            if encode != nil { cancelEncode() } else { close() }
        case .smallerExport:
            setExportScale(exportScale.stepped(by: -1))
        case .largerExport:
            setExportScale(exportScale.stepped(by: 1))
        }
    }

    @objc private func retakeTapped() { perform(.retake) }
    @objc private func saveTapped() { perform(.save) }
    @objc private func copyTapped() { perform(.copy) }

    /// A ring filling clockwise from the top — a template image, so it tints
    /// like the symbol it stands in for (white on the prominent Copy).
    private static func progressImage(_ fraction: Double) -> NSImage {
        let fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: rect.width / 2 - 2,
                startAngle: 90, endAngle: 90 - 360 * max(0.02, fraction), clockwise: true
            )
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func symbolImage(for action: RecordingWindowAction) -> NSImage {
        let image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? image
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// Save keeps the window open (Q31). The take is secured *before*
    /// anything can yield — a closing window or a newer take may release it
    /// before the off-main copy runs (review round 1).
    private func saveTake() {
        guard encode == nil else {
            NSSound.beep() // one export at a time
            return
        }
        exportFailure = nil
        switch RecordingExportSource.forSave(scale: exportScale, encoded: exportCache.file(at: exportScale)) {
        case .take: save(take, scale: .full)
        case .encoded(let file): save(file, scale: exportScale)
        case .needsEncode, .saved: startEncode(for: .save, scale: exportScale)
        }
    }

    /// Saves `file` — the take at 100 %, else its re-encode at `scale` — as
    /// a new `Recording … .mp4` and records it for the take at that stop.
    private func save(_ file: URL, scale: ExportScale) {
        let directory = settings.saveDirectory
        let folderName = saveFolderName
        let date = RecordingExport.recordedDate(of: take)
        let staged: URL
        do {
            staged = try RecordingExport.stage(file)
        } catch {
            showAlert(UserFacingText.recordingSaveFailed(error, folderName: folderName))
            return
        }
        // A cross-volume copy of a long take can take a while — off the main
        // actor. The result goes to the take, not this window (which may
        // have closed by then).
        Task { [weak self, take, savedFiles] in
            let result = await Task.detached {
                Result { try RecordingExport.save(staged: staged, to: directory, date: date) }
            }.value
            switch result {
            case .success(let saved):
                savedFiles.record(saved, for: take, scale: scale)
                self?.refreshStatus()
            case .failure(let error):
                if let self {
                    self.showAlert(UserFacingText.recordingSaveFailed(error, folderName: folderName))
                } else {
                    Self.runAlert(UserFacingText.recordingSaveFailed(error, folderName: folderName))
                }
            }
        }
    }

    /// Copy is the "done" action: the file goes on the pasteboard and the
    /// window closes — the saved file when this take was saved, else a
    /// `Recording … .mp4` clone, which outlives the take. If the clone can't
    /// be made, the window stays open (its take may be deleted on close, so
    /// the take itself is never put on the pasteboard).
    private func copyTake() {
        guard encode == nil else {
            NSSound.beep() // one export at a time
            return
        }
        exportFailure = nil
        let source = copySource
        guard source != .needsEncode else {
            startEncode(for: .copy, scale: exportScale)
            return
        }
        copy(source)
    }

    private func copy(_ source: RecordingExportSource) {
        let file: URL
        do {
            file = try fileToCopy(source)
        } catch {
            showAlert(UserFacingText.recordingCopyFailed(error))
            return
        }
        RecordingExport.copyToPasteboard(file)
        close()
    }

    /// What Copy pastes at the current stop: a file saved at this stop (by
    /// any of the take's windows), else the take or its re-encode.
    private var copySource: RecordingExportSource {
        RecordingExportSource.forCopy(
            scale: exportScale, saved: savedFiles.savedFile(for: take, scale: exportScale),
            encoded: exportCache.file(at: exportScale)
        )
    }

    /// The saved file as is, else a fresh `Recording … .mp4` clone of the
    /// take or its re-encode. Internal (not private) only for tests.
    func fileToCopy(_ source: RecordingExportSource? = nil) throws -> URL {
        let date = RecordingExport.recordedDate(of: take)
        switch source ?? copySource {
        case .saved(let file):
            return file
        case .take:
            return try RecordingExport.clipboardFile(for: take, in: RecordingExport.clipboardDirectory, date: date)
        case .encoded(let file):
            return try RecordingExport.clipboardFile(for: file, in: RecordingExport.clipboardDirectory, date: date)
        case .needsEncode:
            throw CocoaError(.fileReadNoSuchFile)
        }
    }

    // MARK: Re-encoding

    /// Re-encodes the take at `scale` for a Save or Copy, off the main actor;
    /// the pressed button shows the progress. The window stays usable: the
    /// slider may move meanwhile — the export keeps the stop it was pressed
    /// at — and Q / Esc / ⌘W cancel it.
    private func startEncode(for action: RecordingWindowAction, scale: ExportScale) {
        let output: URL
        do {
            output = try exportCache.prepare(scale)
        } catch {
            showExportFailure(scale)
            return
        }
        let id = UUID()
        let quality = settings.recordingQuality
        let report = { @MainActor [weak self] (fraction: Double) in self?.encodeProgressed(id, fraction) }
        let job = Task.detached(priority: .userInitiated) { [take] in
            try await RecordingTranscoder.encode(take, to: output, scale: scale, quality: quality) { fraction in
                Task { await report(fraction) }
            }
        }
        encode = ExportEncode(id: id, action: action, scale: scale, job: job)
        exportFailure = nil
        refreshStatus()
        showEncodeProgress(0, on: action)
        Task { [weak self] in
            let result = await job.result
            if let self {
                self.encodeFinished(id, result)
            } else if case .success(let file) = result {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func encodeProgressed(_ id: UUID, _ fraction: Double) {
        guard let encode, encode.id == id else { return }
        showEncodeProgress(fraction, on: encode.action)
    }

    private func encodeFinished(_ id: UUID, _ result: Result<URL, any Error>) {
        guard let encode, encode.id == id, isOpen else {
            // Cancelled (or the window closed) while it finished: discard.
            if case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
            return
        }
        self.encode = nil
        restoreButton(encode.action)
        switch result {
        case .success(let file):
            exportCache.store(file, scale: encode.scale)
            refreshStatus()
            if encode.action == .save {
                save(file, scale: encode.scale)
            } else {
                copy(.encoded(file))
            }
        case .failure(let error):
            if error is CancellationError { return }
            showExportFailure(encode.scale)
        }
    }

    /// Esc / Q / ⌘W during a re-encode: it stops (its partial file goes),
    /// nothing is saved or copied, the window stays.
    private func cancelEncode() {
        guard let encode else { return }
        encode.job.cancel()
        self.encode = nil
        restoreButton(encode.action)
        refreshStatus()
    }

    /// A short inline message in the capsule — nothing was saved or copied.
    private func showExportFailure(_ scale: ExportScale) {
        exportFailure = scale
        refreshStatus()
        NSSound.beep()
    }

    private func toolbarItem(for action: RecordingWindowAction) -> NSToolbarItem? {
        let id: NSToolbarItem.Identifier = action == .save ? .recordingSave : .recordingCopy
        return toolbar.items.first { $0.itemIdentifier == id }
    }

    /// The pressed button becomes a progress ring; its label (VoiceOver)
    /// reads the percentage.
    private func showEncodeProgress(_ fraction: Double, on action: RecordingWindowAction) {
        guard let item = toolbarItem(for: action) else { return }
        item.image = Self.progressImage(fraction)
        item.label = "Exporting \(ExportSizeText.progress(fraction))"
        item.toolTip = ExportSizeText.cancelToolTip
    }

    private func restoreButton(_ action: RecordingWindowAction) {
        guard let item = toolbarItem(for: action) else { return }
        item.image = Self.symbolImage(for: action)
        item.label = action.title
        item.toolTip = action.toolTip(saveFolderName: saveFolderName)
    }

    // Test hooks: whether a re-encode runs, and the stop's cached re-encode.
    var isEncoding: Bool { encode != nil }
    func encodedFile(at scale: ExportScale) -> URL? { exportCache.file(at: scale) }

    /// A sheet on this window while it is open, so other windows stay usable
    /// (as in the editor); app-modal once it has closed.
    private func showAlert(_ text: AlertText) {
        guard isOpen, window.isVisible else {
            Self.runAlert(text)
            return
        }
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.beginSheetModal(for: window)
    }

    /// Copy comes from `UserFacingText` — never `String(describing: error)`.
    private static func runAlert(_ text: AlertText) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.runModal()
    }

    // MARK: Helpers

    /// The video track's display size (nil when the file has none, or can't
    /// be read) and the take's duration.
    nonisolated static func videoInfo(of url: URL) async -> RecordingVideoInfo {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        let duration = seconds.flatMap { $0.isFinite ? $0 : nil }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform, rate) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        else { return RecordingVideoInfo(size: nil, duration: duration) }
        let display = size.applying(transform)
        return RecordingVideoInfo(
            size: CGSize(width: abs(display.width), height: abs(display.height)), duration: duration,
            framesPerSecond: rate > 0 ? Double(rate) : nil
        )
    }

    /// The screen showing most of the recorded area, else the main screen.
    private static func screen(for rect: CGRect) -> NSScreen? {
        let best = NSScreen.screens.max { lhs, rhs in
            area(lhs.frame.intersection(rect)) < area(rhs.frame.intersection(rect))
        }
        if let best, area(best.frame.intersection(rect)) > 0 { return best }
        return NSScreen.main
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}

// MARK: - Window lifecycle

extension RecordingWindowController: NSWindowDelegate {
    /// Coming back from Settings makes the window key again. Key by any
    /// route also ends a focus request still waiting for activation.
    func windowDidBecomeKey(_ notification: Notification) {
        if focus.isActive() { endPendingFocus() }
        refreshSaveToolTip()
    }

    /// Q / Esc / ⌘W, the traffic light and Copy all end here — no prompt (Q32).
    func windowWillClose(_ notification: Notification) {
        finish()
    }
}

/// The take's video size (pixels), duration and nominal frame rate, read
/// after the window opened.
struct RecordingVideoInfo: Equatable, Sendable {
    var size: CGSize?
    var duration: TimeInterval?
    var framesPerSecond: Double?
}

/// A re-encode running for a Save or Copy (`startEncode`).
private struct ExportEncode {
    let id: UUID
    let action: RecordingWindowAction
    let scale: ExportScale
    let job: Task<URL, any Error>
}

/// How a recording window asks for activation — the app in production, a
/// recorder in tests.
struct RecordingWindowFocus {
    var activate: @MainActor () -> Void = { NSApplication.shared.activate() }
    var isActive: @MainActor () -> Bool = { NSApplication.shared.isActive }
}

/// A focus request waiting for a late activation (`takeFocus`).
private struct PendingFocus {
    let observer: any NSObjectProtocol
    let timer: Task<Void, Never>
}

// MARK: - Toolbar

extension NSToolbarItem.Identifier {
    static let recordingRetake = Self("recordingRetake")
    static let recordingSave = Self("recordingSave")
    static let recordingCopy = Self("recordingCopy")
}

extension RecordingWindowController: NSToolbarDelegate {
    /// Retake after the traffic lights; Save and the prominent Copy at the
    /// trailing edge — the HIG's place for the "done" action, as in the editor.
    /// Without a Retake (a take reopened after a relaunch) it is left out.
    static func toolbarOrder(hasRetake: Bool) -> [NSToolbarItem.Identifier] {
        (hasRetake ? [.recordingRetake] : []) + [.flexibleSpace, .recordingSave, .recordingCopy]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarOrder(hasRetake: onRetake != nil)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarOrder(hasRetake: onRetake != nil)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .recordingRetake:
            return item(itemIdentifier, for: .retake, action: #selector(retakeTapped))
        case .recordingSave:
            return item(itemIdentifier, for: .save, action: #selector(saveTapped))
        case .recordingCopy:
            // Tinted with the accent colour on its own glass platter.
            let item = item(itemIdentifier, for: .copy, action: #selector(copyTapped))
            item.style = .prominent
            return item
        default:
            return nil
        }
    }

    /// Image-based items, like the editor's: small smooth symbols, bordered
    /// so they sit on the toolbar's glass, with the "<verb phrase> (KEY)"
    /// tooltip.
    private func item(
        _ id: NSToolbarItem.Identifier, for action: RecordingWindowAction, action selector: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = Self.symbolImage(for: action)
        item.label = action.title
        item.toolTip = action.toolTip(saveFolderName: saveFolderName)
        item.target = self
        item.action = selector
        item.isBordered = true
        item.visibilityPriority = .high
        return item
    }
}

// MARK: - Views

/// The canvas: the editor's Tahoe Glass backdrop wash with the player fitted
/// into the unobscured area under the toolbar, above the status band
/// (`AnnotationGeometry.fitArea`, `RecordingWindowLayout.playerFrame`).
@MainActor
private final class RecordingCanvasView: NSView {
    /// The video's size (points; only the aspect matters for the fit).
    var videoSize: CGSize = .zero {
        didSet { needsLayout = true }
    }

    private let playerView = AVPlayerView()
    /// Casts the player's shadow; the player itself clips to its corners.
    private let shadowHost = NSView()

    private static let cornerRadius: CGFloat = 8

    // The editor's backdrop colours (AnnotationCanvasView keeps its own
    // private; `Editor/` is read-only for recording).
    private static let backdropTop = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.165, green: 0.169, blue: 0.184, alpha: 1)  // #2A2B2F
            : NSColor(srgbRed: 0.969, green: 0.973, blue: 0.984, alpha: 1)  // #F7F8FB
    }
    private static let backdropBottom = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.106, green: 0.110, blue: 0.122, alpha: 1)  // #1B1C1F
            : NSColor(srgbRed: 0.890, green: 0.902, blue: 0.925, alpha: 1)  // #E3E6EC
    }
    private static let playerShadow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.55)
            : NSColor(srgbRed: 0.08, green: 0.12, blue: 0.24, alpha: 0.28)
    }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = false
        playerView.allowsPictureInPicturePlayback = false
        // A silent clip looping in a window is not "Now Playing".
        playerView.updatesNowPlayingInfoCenter = false
        playerView.wantsLayer = true
        playerView.layer?.cornerRadius = Self.cornerRadius
        playerView.layer?.cornerCurve = .continuous
        playerView.layer?.masksToBounds = true

        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowOpacity = 1
        shadowHost.layer?.shadowRadius = 14
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -8)
        shadowHost.addSubview(playerView)
        addSubview(shadowHost)
        updateShadowColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func detachPlayer() {
        playerView.player = nil
    }

    override func layout() {
        super.layout()
        let area = AnnotationGeometry.fitArea(
            bounds: bounds,
            unobscured: window.map { convert($0.contentLayoutRect, from: nil) },
            bottomInset: RecordingWindowLayout.statusBand
        )
        let frame = RecordingWindowLayout.playerFrame(video: videoSize, in: area)
        shadowHost.frame = frame
        playerView.frame = shadowHost.bounds
        shadowHost.layer?.shadowPath = CGPath(
            roundedRect: shadowHost.bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius,
            transform: nil
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: Self.backdropTop, ending: Self.backdropBottom)?.draw(in: bounds, angle: -90)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadowColor()
        needsDisplay = true
    }

    private func updateShadowColor() {
        var color = CGColor(gray: 0, alpha: 0.3)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = Self.playerShadow.cgColor
        }
        shadowHost.layer?.shadowColor = color
    }
}

/// The recording window: a normal titled window (resizable, minimisable, in
/// Mission Control). Every key goes through `RecordingWindowAction.action`
/// **before** the player view sees it, so Space and the shortcuts work
/// wherever the focus is inside the window — Space is play/pause even on a
/// keyboard-focused toolbar button. Keys it doesn't map (arrows, J/K/L) still
/// reach the player.
@MainActor
// Internal (not private) only so the window-level key dispatch is testable.
final class RecordingWindow: NSWindow {
    var onAction: ((RecordingWindowAction) -> Void)?

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        minSize = RecordingWindowLayout.minWindowSize
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event) || super.performKeyEquivalent(with: event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let action = RecordingWindowAction.action(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags
        ) else { return false }
        onAction?(action)
        return true
    }
}

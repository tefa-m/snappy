import AVFoundation
import AppKit
import CoreImage
import ScreenCaptureKit
import os

/// Errors the pipeline raises itself. A Screen Recording (TCC) denial is
/// thrown as `CaptureError.permissionDenied` instead, so the coordinator shows
/// the permission alert. Each description is the reason line of
/// `UserFacingText.recordingFailed`, which appends the retry advice.
enum RecordingPipelineError: LocalizedError, Equatable {
    case displayUnavailable
    case windowUnavailable
    case snappyNotListed
    case streamFailed
    case compositionFailed
    case writerFailed
    case diskFull
    case noFrames
    case notStarted

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: "The display to record is no longer connected."
        case .windowUnavailable: "The window to record is no longer available."
        case .snappyNotListed: "Snappy couldn’t keep its own windows out of the recording."
        case .streamFailed: "The screen stopped sending video."
        case .compositionFailed: "The recorded frames couldn’t be prepared for the video."
        case .writerFailed: "The video file couldn’t be written."
        case .diskFull: "There isn’t enough disk space for the recording."
        case .noFrames: "The screen didn’t send any video."
        case .notStarted: "The recording never started."
        }
    }

    /// An `AVAssetWriter` failure, with a full disk recognised (also when it
    /// is only the underlying error) — PURE, tested.
    static func writer(_ error: (any Error)?) -> RecordingPipelineError {
        var next = error.map { $0 as NSError }
        while let error = next {
            switch (error.domain, error.code) {
            case (AVFoundationErrorDomain, AVError.Code.diskFull.rawValue),
                 (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
                 (NSPOSIXErrorDomain, Int(ENOSPC)):
                return .diskFull
            default:
                next = error.userInfo[NSUnderlyingErrorKey] as? NSError
            }
        }
        return .writerFailed
    }
}

/// PURE — when a pipeline failure may reach the coordinator — tested.
///
/// SCK can deliver frames (and so a writer failure) or stop the stream while
/// `start` is still awaiting `startCapture`'s completion. Such a failure is
/// **held** and `start` throws it — the coordinator then never believes a dead
/// pipeline is recording. After a successful start the first failure is
/// delivered through `onFailure`; every later one, and any after the end, is
/// dropped (exactly once).
struct PipelineFailureGate<Failure> {
    enum Phase: Equatable {
        case starting, running, ended
    }

    enum Delivery {
        /// Call `onFailure` with it now.
        case deliver(Failure)
        /// `start` will throw it.
        case held
        case dropped
    }

    private(set) var phase = Phase.starting
    private(set) var held: Failure?
    private var delivered = false

    mutating func report(_ failure: Failure) -> Delivery {
        switch phase {
        case .starting:
            guard held == nil else { return .dropped }
            held = failure
            return .held
        case .running:
            guard !delivered else { return .dropped }
            delivered = true
            return .deliver(failure)
        case .ended:
            return .dropped
        }
    }

    /// `start`'s stream came up: the held failure for `start` to throw (the
    /// gate ends), or nil — now running.
    mutating func startDidComplete() -> Failure? {
        guard phase == .starting else { return nil }
        if let held {
            phase = .ended
            return held
        }
        phase = .running
        return nil
    }

    /// Start threw, or the pipeline is stopping: nothing is reported any more.
    mutating func end() {
        phase = .ended
    }
}

/// T2 — records a `RecordingTarget` to an H.264 MP4 (`RecordingPipelining`).
///
/// ```
/// SCStream (Snappy excluded by application | desktop-independent window,
///           cropped to a W + part's part by a live `sourceRect`)
///   → capture queue: FrameWriter — copy into a writer-pool buffer (letterboxed
///     for a window or part), FrameDecorating.draw, append; idle timer re-appends
///   → AVAssetWriter (MP4, H.264, session starts at the first frame)
/// ```
///
/// **W + part (v2 V3, Q37).** The window's own stream, cropped by SCK to the
/// part: `sourceRect` is window-local on a window filter, so a moving window
/// needs nothing. The part's Accessibility frame is polled ~10 Hz through its
/// `WindowPartElement` (the AX executor's timeouts and back-off apply; nil =
/// keep the last rect), checked against the window's frame around the read
/// (`PartCropTracker`), and a changed crop goes to SCK with
/// `updateConfiguration`, one at a time (`PartCropUpdater`). The video size
/// is fixed at start (the part's pixels); a part of another size is scaled
/// to fit and letterboxed like a resized W window. Each frame is decorated
/// with the crop it was presented under (`PartCropTimeline`); a frame
/// presented while SCK was switching is held back, never guessed.
///
/// **Isolation.** This class is `@MainActor` (it owns the `SCStream`, the
/// `WindowTracker` and the coordinator's callbacks). Everything that touches a
/// frame lives in `FrameWriter`, an actor whose executor *is* the capture
/// queue: SCK delivers samples on that queue, so they enter the actor
/// synchronously (`assumeIsolated`), and the non-Sendable AVFoundation and SCK
/// frame objects never leave it. The two cross-isolation values are Sendable
/// by construction: the ink's `FrameDecorating` (contract) and the tracked
/// window frame (a lock). No `@unchecked Sendable`; the single
/// `nonisolated(unsafe)` is the hand-over of SCK's sample buffer into the
/// writer, justified where it happens (`StreamBridge`).
///
/// **Failures.** A stream or composition failure (display gone, permission
/// revoked, a frame that can't be prepared) leaves the writer healthy, so
/// `stop()` still finalises a playable file of what was recorded; a writer
/// failure (disk full) makes `stop()` throw. A failure during `start` is
/// thrown by `start` (`PipelineFailureGate`). Whether a
/// failed take is kept is the coordinator's single `failedTakeHandling` branch.
@MainActor
final class RecordingPipeline: RecordingPipelining {
    var onWindowFrameChange: (@MainActor (CGRect) -> Void)?
    var onPartFrameChange: (@MainActor (CGRect) -> Void)?
    var onWindowGone: (@MainActor () -> Void)?
    var onFailure: (@MainActor (any Error) -> Void)?

    /// ~10 Hz (Q37): the border follows a part within a tenth of a second,
    /// and an app's tree is asked little enough to cost it nothing.
    static let partPollInterval: Duration = .milliseconds(100)

    private enum Phase {
        case idle, starting, running, stopped
    }

    private var phase = Phase.idle
    private var outputURL: URL?
    private var stream: SCStream?
    /// SCK holds its output and delegate weakly (delegate) or not at all
    /// beyond the stream; keep the bridge alive with the stream.
    private var bridge: StreamBridge?
    private var writer: FrameWriter?
    private var tracker: WindowTracker?
    private var failures = PipelineFailureGate<any Error>()

    /// `endTracking()` ran: a start still awaiting SCK must not begin
    /// tracking or polling when it resumes (the session's AX restores have
    /// been posted).
    private var trackingEnded = false

    // W + part (main actor): what is cropped, and SCK's configuration to
    // update when it changes.
    private var configuration: SCStreamConfiguration?
    private var partCrop: PartCropTracker?
    private var partWindowID: CGWindowID?
    private var partElement: WindowPartElement?
    private var partPollTask: Task<Void, Never>?
    private var partCropUpdater: PartCropUpdater?
    /// The window's last tracked frame (for the chrome's part rect).
    private var windowFrame = CGRect.zero

    init() {}

    // MARK: - RecordingPipelining

    func start(
        target: RecordingTarget, settings: RecordingSettings,
        decorator: any FrameDecorating, outputURL: URL
    ) async throws {
        guard phase == .idle else { throw RecordingPipelineError.notStarted }
        phase = .starting
        self.outputURL = outputURL
        do {
            try await startCapture(target: target, settings: settings, decorator: decorator, outputURL: outputURL)
        } catch let error as SCStreamError where error.code == .userDeclined {
            failures.end()
            throw CaptureError.permissionDenied
        } catch {
            failures.end()
            throw error
        }
        // A writer or stream failure that arrived while the stream came up.
        if let failure = failures.startDidComplete() { throw failure }
        // The coordinator may already have asked for stop() while we awaited.
        guard phase == .starting else { return }
        phase = .running
        // The session may have ended meanwhile (a cancel while starting): it
        // drains, untracked.
        if !trackingEnded {
            tracker?.start()
            startPartPolling()
            // The chrome shows the crop SCK really records (pixel-snapped,
            // clamped to the window), not the picker's rect.
            if let source = partCropUpdater?.applied { showPartCrop(source) }
        }
        await writer?.startIdleFrames()
    }

    func endTracking() {
        trackingEnded = true
        tracker?.stop()
        partPollTask?.cancel()
        partPollTask = nil
        partElement = nil
        partCropUpdater?.stop()
    }

    func stop() async throws -> URL {
        let wasRunning = phase == .running
        phase = .stopped
        failures.end()
        endTracking()
        tracker = nil
        partCropUpdater = nil
        configuration = nil
        if let stream {
            // Ignore a stop error: the stream may already have stopped itself.
            try? await Self.stopCapture(stream)
        }
        stream = nil
        bridge = nil
        let writer = self.writer
        self.writer = nil
        guard let url = outputURL, let writer else { throw RecordingPipelineError.notStarted }
        outputURL = nil
        guard wasRunning else {
            await writer.cancel()
            throw RecordingPipelineError.notStarted
        }
        // Frames SCK already queued run before this on the capture queue.
        try await writer.finish()
        return url
    }

    // MARK: - Start

    private func startCapture(
        target: RecordingTarget, settings: RecordingSettings,
        decorator: any FrameDecorating, outputURL: URL
    ) async throws {
        guard let screen = NSScreen.screens.first(where: { CaptureEngine.displayID(for: $0) == target.displayID })
        else { throw RecordingPipelineError.displayUnavailable }
        let scale = screen.backingScaleFactor
        let profile = VideoColorProfile(wideGamut: screen.canRepresent(.p3))
        let framesPerSecond = settings.frameRate.framesPerSecond

        // A window target needs the live window list; an area target only the
        // display and our own app (warm cache first, refetched if we're missing).
        let content = target.isWindow
            ? try await CaptureEngine.shareableContent(preferCached: false)
            : try await CaptureEngine.contentKeepingPins(Self.contentListingSnappy(
                fetch: { try await CaptureEngine.shareableContent(preferCached: $0) },
                listsSnappy: { Self.ownApplication(in: $0) != nil }
            ))
        guard phase == .starting else { throw RecordingPipelineError.notStarted }

        let configuration = SCStreamConfiguration()
        let filter: SCContentFilter
        let videoSize: VideoSize
        let decoration: DecorationTarget
        switch target {
        case .area(let rect, let displayID):
            guard
                let display = content.displays.first(where: { $0.displayID == displayID }),
                let capture = OutputGeometry.areaCapture(globalRect: rect, screenFrame: screen.frame, scale: scale)
            else { throw RecordingPipelineError.displayUnavailable }
            guard let ownApp = Self.ownApplication(in: content) else { throw RecordingPipelineError.snappyNotListed }
            // Exclude Snappy by **application**, never by window list
            // (ARCHITECTURE › Capturing): chrome, ink and any panel opened
            // later stay out; the ink reaches the video only via the decorator.
            // Open pins are the exception: they are content the user placed.
            filter = SCContentFilter(
                display: display, excludingApplications: [ownApp],
                exceptingWindows: CaptureEngine.pinWindows(in: content)
            )
            configuration.sourceRect = capture.sourceRect
            // The aspect ratios differ by at most a rounding pixel when the
            // size was capped; fill the frame exactly instead of leaving a bar.
            configuration.preservesAspectRatio = false
            videoSize = capture.videoSize
            decoration = .area(capture.capturedFrame)
        case .window(let windowID, let frame, _):
            let window: SCWindow
            (filter, window) = try windowFilter(windowID, frame: frame, in: content, configuration: configuration)
            // Video size is fixed at start; SCK scales a resized window into
            // it (aspect kept) and FrameWriter centres the result.
            videoSize = OutputGeometry.videoSize(
                forPixelSize: CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
            )
            decoration = .window(frame)
        case .windowPart(let part, _):
            (filter, _) = try windowFilter(part.windowID, frame: part.windowFrame, in: content, configuration: configuration)
            // SCK crops the window's stream to the part (window-local
            // `sourceRect`); the video is the part's size at the start, and a
            // part that changes size later is scaled to fit and letterboxed.
            let crop = PartCropTracker(part: part.frame, window: part.windowFrame, scale: scale)
            let source = crop.sourceRect
            configuration.sourceRect = source
            videoSize = OutputGeometry.videoSize(
                forPixelSize: CGSize(width: source.width * scale, height: source.height * scale)
            )
            decoration = .part(window: part.windowFrame, sourceRect: source)
            partCrop = crop
            partWindowID = part.windowID
            partElement = part.element
        }
        configuration.width = videoSize.width
        configuration.height = videoSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = profile.colorSpaceName
        configuration.showsCursor = settings.showsCursor
        configuration.showMouseClicks = settings.showsClicks
        configuration.streamName = "Snappy Recording"

        let writer = try FrameWriter(
            outputURL: outputURL,
            videoSize: videoSize,
            framesPerSecond: framesPerSecond,
            quality: settings.quality,
            profile: profile,
            letterboxes: target.isWindow,
            target: decoration,
            decorator: decorator,
            onFailure: { [weak self] error in
                Task { @MainActor in self?.reportFailure(error) }
            }
        )
        self.writer = writer
        if case .part(_, let source) = decoration {
            let updater = PartCropUpdater(source: source, decoration: writer.decoration) { [weak self] source, done in
                guard let self, let stream = self.stream, let configuration = self.configuration else { return done(false) }
                configuration.sourceRect = source
                stream.updateConfiguration(configuration) { error in done(error == nil) }
            }
            updater.onShow = { [weak self] source in self?.showPartCrop(source) }
            partCropUpdater = updater
        }

        let bridge = StreamBridge(writer: writer, usesContentRect: target.isWindow) { [weak self] error in
            Task { @MainActor in self?.streamStopped(error) }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: bridge)
        try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: writer.queue)
        self.bridge = bridge
        self.stream = stream
        self.configuration = configuration
        try await Self.startCapture(stream)
    }

    /// The filter and settings W and W + part share — the window itself,
    /// followed by a `WindowTracker`. Throws when the window is gone.
    private func windowFilter(
        _ windowID: CGWindowID, frame: CGRect, in content: SCShareableContent, configuration: SCStreamConfiguration
    ) throws -> (SCContentFilter, SCWindow) {
        guard let window = content.windows.first(where: { $0.windowID == windowID })
        else { throw RecordingPipelineError.windowUnavailable }
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        // The content must be the window frame exactly, or the ink
        // (mapped from that frame) would be off by the shadow.
        configuration.ignoreShadowsSingleWindow = true
        // `unowned(unsafe)` in SCK: needs a constant that outlives the stream.
        configuration.backgroundColor = CGColor.black
        windowFrame = frame
        let tracker = WindowTracker(windowID: windowID, frame: frame)
        tracker.onFrameChange = { [weak self] frame in self?.windowFrameChanged(frame) }
        tracker.onGone = { [weak self] in self?.windowGone() }
        self.tracker = tracker
        return (SCContentFilter(desktopIndependentWindow: window), window)
    }

    private static func ownApplication(in content: SCShareableContent) -> SCRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.applications.first { $0.processID == ownPID }
    }

    /// Shareable content that lists Snappy's own application — tested with
    /// fakes. Unlike screenshots there is **no window-list fallback**: a list
    /// is a snapshot, and chrome, ink or a panel opened later would be
    /// recorded. The (possibly cached) content first; if Snappy isn't in it,
    /// one fresh fetch; still missing → `.snappyNotListed`.
    static func contentListingSnappy<Content>(
        fetch: @MainActor (_ preferCached: Bool) async throws -> Content,
        listsSnappy: @MainActor (Content) -> Bool
    ) async throws -> Content {
        let content = try await fetch(true)
        if listsSnappy(content) { return content }
        let fresh = try await fetch(false)
        guard listsSnappy(fresh) else { throw RecordingPipelineError.snappyNotListed }
        return fresh
    }

    // The completion-handler forms: `SCStream` is main-actor state here and
    // not Sendable, so it can't be handed to a nonisolated async method.
    private static func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stream.startCapture { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func stopCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stream.stopCapture { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: - Events (main actor)

    private func windowFrameChanged(_ frame: CGRect) {
        guard phase == .running else { return }
        windowFrame = frame
        writer?.decoration.withLock { $0.windowMoved(to: frame) }
        onWindowFrameChange?(frame)
        // A resized window may cut into the part: re-clamp the crop.
        partCrop?.windowChanged(frame)
        if let source = partCrop?.sourceRect { partCropUpdater?.want(source) }
    }

    // MARK: - W + part

    /// Polls the part's Accessibility frame while running. Without an
    /// element (the picker couldn't keep one) the crop stays where it began.
    private func startPartPolling() {
        guard partPollTask == nil, partElement != nil else { return }
        partPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.partPollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.pollPart()
            }
        }
    }

    /// One sample: the window, the part's AX frame, the window again — kept
    /// only when the window held still around the read (`PartCropTracker`).
    /// An off-screen window isn't asked about at all.
    private func pollPart() async {
        guard phase == .running, let element = partElement, let windowID = partWindowID else { return }
        let before = WindowTracker.systemObservation(of: windowID)
        guard case .onScreen = before else { return }
        let frame = await element.currentFrame()
        // `endTracking` may have run meanwhile: nothing more is applied.
        // (The read itself was enqueued on the AX executor before this
        // suspension, ahead of the session's end — `currentFrame()`.)
        guard phase == .running, partElement != nil else { return }
        let after = WindowTracker.systemObservation(of: windowID)
        partCrop?.observe(part: frame, windowBefore: before, windowAfter: after)
        // Every poll, not only on a change: a failed update is retried.
        if let source = partCrop?.sourceRect { partCropUpdater?.want(source) }
    }

    /// The chrome follows the crop SCK records (or is about to).
    private func showPartCrop(_ source: CGRect) {
        guard phase == .running, !trackingEnded else { return }
        onPartFrameChange?(PartCropGeometry.global(source, in: windowFrame))
    }

    private func windowGone() {
        guard phase == .running else { return }
        onWindowGone?()
    }

    /// SCK stopped the stream on its own. For a window target that is usually
    /// the window closing — let the tracker decide before calling it a failure.
    private func streamStopped(_ error: any Error) {
        if phase == .running, let tracker {
            tracker.poll()
            if tracker.isGone { return }
        }
        if let error = error as? SCStreamError, error.code == .userDeclined {
            reportFailure(CaptureError.permissionDenied)
        } else {
            reportFailure(RecordingPipelineError.streamFailed)
        }
    }

    private func reportFailure(_ error: any Error) {
        guard case .deliver(let failure) = failures.report(error) else { return }
        onFailure?(failure)
    }
}

// MARK: - W + part crop updates

/// Sends a W + part's crop changes to SCK **one at a time** — the policy,
/// with `SCStream.updateConfiguration` behind `apply` (tested with a fake).
/// - The newest wanted crop goes when the update in flight returns; crops
///   wanted meanwhile are skipped.
/// - Each change is stamped into the writer's crop timeline: requested right
///   before `apply`, applied or failed **on SCK's own callback** — not after a
///   main-actor hop, so a busy main actor can't make frames of the new crop
///   look old (`PartCropTimeline`).
/// - The chrome (`onShow`) follows a request at once. A failed update puts it
///   back on the crop SCK still records — so chrome and video agree — and
///   the crop is asked for again `retryDelay` later (at the next `want`;
///   the poll calls it every ~100 ms).
@MainActor
final class PartCropUpdater {
    typealias Apply = @MainActor (_ source: CGRect, _ done: @escaping @Sendable (_ applied: Bool) -> Void) -> Void

    static let retryDelay: Double = 1

    /// Where the chrome shows the recording's crop (window-local source rect).
    var onShow: (@MainActor (CGRect) -> Void)?
    /// The crop SCK records (the last one applied).
    private(set) var applied: CGRect
    /// The update in flight.
    private(set) var inFlight: CGRect?

    private let decoration: OSAllocatedUnfairLock<FrameDecorationState>
    private let now: @Sendable () -> Double
    private let apply: Apply
    private var wanted: CGRect
    private var retryAt = -Double.infinity
    private var isStopped = false

    init(
        source: CGRect, decoration: OSAllocatedUnfairLock<FrameDecorationState>,
        now: @escaping @Sendable () -> Double = { CACurrentMediaTime() }, apply: @escaping Apply
    ) {
        applied = source
        wanted = source
        self.decoration = decoration
        self.now = now
        self.apply = apply
    }

    /// The crop the part needs now (the tracker's `sourceRect`).
    func want(_ source: CGRect) {
        wanted = source
        sendIfDue()
    }

    /// Tracking ended: nothing more is sent or shown.
    func stop() {
        isStopped = true
    }

    private func sendIfDue() {
        guard !isStopped, inFlight == nil, wanted != applied, now() >= retryAt else { return }
        let source = wanted
        inFlight = source
        let decoration = decoration
        let now = now
        decoration.withLock { $0.cropRequested(source, at: now()) }
        onShow?(source)
        apply(source) { [weak self] applied in
            let time = now()
            decoration.withLock { applied ? $0.cropApplied(at: time) : $0.cropFailed() }
            Task { @MainActor in self?.finished(source, applied: applied) }
        }
    }

    private func finished(_ source: CGRect, applied succeeded: Bool) {
        inFlight = nil
        guard !isStopped else { return }
        if succeeded {
            applied = source
        } else {
            retryAt = now() + Self.retryDelay
            onShow?(applied)
        }
        sendIfDue()
    }
}

// MARK: - SCK → capture queue

/// One captured frame, as the writer needs it.
struct CapturedFrame {
    let pixelBuffer: CVPixelBuffer
    /// The content's pixel rect in `pixelBuffer`, origin top-left (a resized
    /// window doesn't fill the buffer); nil = the whole buffer.
    let contentRect: CGRect?
    /// Host-clock seconds (SCK's presentation time = when it was displayed).
    let time: Double
}

/// SCK's sample handler and delegate. Immutable and Sendable: it only
/// forwards — frames into the writer on the capture queue, a stream stop to
/// the main actor.
private final class StreamBridge: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let writer: FrameWriter
    /// Window streams report where the (scaled) window sits in the buffer.
    let usesContentRect: Bool
    let onStop: @Sendable (any Error) -> Void

    init(writer: FrameWriter, usesContentRect: Bool, onStop: @escaping @Sendable (any Error) -> Void) {
        self.writer = writer
        self.usesContentRect = usesContentRect
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let captured = Self.frame(from: sampleBuffer, usesContentRect: usesContentRect)
        else { return }
        // The one isolation opt-out in the pipeline, and why it's safe: SCK
        // hands this sample buffer to us alone, on the capture queue — which
        // is the writer's executor (`assumeIsolated` traps otherwise) — and
        // nothing here touches it after the call. CMSampleBuffer/CVPixelBuffer
        // are non-Sendable, and the compiler can't see that a callback
        // parameter is ours to give away.
        nonisolated(unsafe) let frame = captured
        writer.assumeIsolated { $0.append(frame) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop(error)
    }

    /// Only `.complete` frames carry new pixels; `.idle` ones mean "nothing
    /// changed" and are covered by the writer's own idle re-append.
    private static func frame(from sampleBuffer: CMSampleBuffer, usesContentRect: Bool) -> CapturedFrame? {
        guard
            sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let rawStatus = info[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete,
            let pixelBuffer = sampleBuffer.imageBuffer
        else { return nil }
        var contentRect: CGRect?
        if usesContentRect {
            let points = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            contentRect = OutputGeometry.contentPixelRect(
                contentRect: points,
                scaleFactor: info[.scaleFactor] as? CGFloat,
                bufferSize: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            )
        }
        return CapturedFrame(
            pixelBuffer: pixelBuffer, contentRect: contentRect, time: sampleBuffer.presentationTimeStamp.seconds
        )
    }
}

// MARK: - Writer (capture queue)

/// Composites and writes frames. An actor **on the capture queue** (custom
/// executor), so SCK's sample callbacks and the idle timer run inside its
/// isolation without a hop, and its AVFoundation/CoreImage state is confined
/// to that one serial queue. The main actor reaches it only with `await`
/// (start of idle frames, finish, cancel) and through the `target` lock.
///
/// Per frame: a buffer from the adaptor's pool, `FrameCompositor` fills it
/// (SCK pixels + ink), then it is appended. Encoder backpressure drops the
/// frame (real time); a buffer or composition failure fails the recording
/// (`onFailure`) — never a silent drop, never an undecorated append. The SCK
/// buffer itself is never drawn on: it is kept clean as the source of idle
/// re-appends.
actor FrameWriter {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// What the frames show, for the decorator: fixed for an area, the
    /// window frame updated by the main actor as a recorded window moves,
    /// and a W + part's crop timeline (`PartCropUpdater`). Each frame reads
    /// one consistent value.
    nonisolated let decoration: OSAllocatedUnfairLock<FrameDecorationState>

    private enum State {
        /// Appending.
        case writing
        /// A failure was reported; nothing more is appended. The file can
        /// still be finished if the writer itself is healthy (salvage).
        case failed
        case finishing, done
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let compositor: FrameCompositor
    private let now: @Sendable () -> Double
    private let onFailure: @Sendable (any Error) -> Void

    private var state = State.writing
    private var clock: FrameClock
    private var sessionStarted = false
    /// The last captured frame, clean (undecorated) — re-appended while
    /// idle — and the crop it was presented under (W + part).
    private var lastFrame: CapturedFrame?
    private var lastCrop = FrameCrop.none
    /// The latest W + part frame presented while SCK was switching crops
    /// (`PartCropTimeline`): not appended until its crop is known.
    private var heldFrame: CapturedFrame?
    private var idleTimer: (any DispatchSourceTimer)?

    /// Frames appended / dropped because the encoder was busy (diagnostics, tests).
    private(set) var appendedFrames = 0
    private(set) var droppedFrames = 0
    /// Captured frames not appended because their grid slot was already filled.
    private(set) var skippedFrames = 0
    /// W + part frames held back because their crop wasn't known.
    private(set) var heldFrames = 0

    /// Creates the file and starts the writer; the session starts with the
    /// first frame. `now` is the host clock (injectable for tests).
    init(
        outputURL: URL, videoSize: VideoSize, framesPerSecond: Int, quality: RecordingQuality,
        profile: VideoColorProfile, letterboxes: Bool, target: DecorationTarget,
        decorator: any FrameDecorating,
        compositorSeams: FrameCompositor.Seams = .live,
        now: @escaping @Sendable () -> Double = { CACurrentMediaTime() },
        onFailure: @escaping @Sendable (any Error) -> Void
    ) throws {
        queue = DispatchSerialQueue(label: "com.tefa.snappy.recording.capture", qos: .userInteractive)
        decoration = OSAllocatedUnfairLock(
            initialState: FrameDecorationState(target: target, frameInterval: 1 / Double(max(framesPerSecond, 1)))
        )
        compositor = FrameCompositor(
            videoSize: videoSize, letterboxes: letterboxes,
            colorSpace: CGColorSpace(name: profile.colorSpaceName) ?? CGColorSpaceCreateDeviceRGB(),
            decorator: decorator, seams: compositorSeams
        )
        self.now = now
        self.onFailure = onFailure
        clock = FrameClock(framesPerSecond: framesPerSecond)

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw RecordingPipelineError.writer(error)
        }
        // Puts the index first, so a pasted clip starts playing before it is
        // fully downloaded (Slack, Jira).
        writer.shouldOptimizeForNetworkUse = true
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: OutputGeometry.videoSettings(
                videoSize: videoSize, framesPerSecond: framesPerSecond, quality: quality, profile: profile
            )
        )
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoSize.width,
            kCVPixelBufferHeightKey as String: videoSize.height,
            // IOSurface + Metal for the CoreImage copy, CG for the decorator.
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw RecordingPipelineError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw RecordingPipelineError.writer(writer.error) }
    }

    // MARK: Frames

    /// A frame from SCK, stamped on its slot of the frame grid. One whose
    /// slot is already filled is not appended (`FrameClock.slotTimeForCaptured`);
    /// it becomes the content of the next slot, so it is never lost.
    ///
    /// A W + part frame presented while SCK was switching crops is held
    /// instead: the last frame of a known crop stays in the video until a
    /// later frame (or the held one, settled) replaces it — ink is never
    /// drawn on a guessed crop (`PartCropTimeline`).
    func append(_ frame: sending CapturedFrame) {
        guard state == .writing else { return }
        let presented = frame.time
        let crop = decoration.withLock { $0.place(frameAt: presented) }
        guard crop != .uncertain else {
            heldFrame = frame
            heldFrames += 1
            return
        }
        heldFrame = nil
        lastFrame = frame
        lastCrop = crop
        guard let time = clock.slotTimeForCaptured(frame.time) else {
            clock.didSkipCaptured(displayedAt: frame.time)
            skippedFrames += 1
            return
        }
        write(frame, crop: crop, at: time, captured: true)
    }

    /// Re-appends the last frame, re-decorated, when nothing arrived for a
    /// frame interval — SCK sends nothing while the screen is static, and
    /// fading ink and new strokes must still reach the video. A held frame
    /// whose crop has settled becomes the last frame first.
    func idleTick() {
        guard state == .writing else { return }
        settleHeldFrame()
        guard let lastFrame, let time = clock.idleFrameTime(now: now()) else { return }
        write(lastFrame, crop: lastCrop, at: time)
    }

    private func settleHeldFrame() {
        guard let held = heldFrame else { return }
        let presented = held.time
        let now = now()
        guard let crop = decoration.withLock({ $0.settledCrop(forHeldFrameAt: presented, now: now) }) else { return }
        heldFrame = nil
        lastFrame = held
        lastCrop = crop
        // The take's first frame starts the frame grid (idle frames need one).
        if !sessionStarted, let time = clock.slotTimeForCaptured(presented) {
            write(held, crop: crop, at: time, captured: true)
        }
    }

    /// Starts the idle re-append timer: twice per frame interval, so an idle
    /// frame is at most half an interval late.
    func startIdleFrames() {
        guard idleTimer == nil, state == .writing else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let period = clock.interval / 2
        timer.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.idleTick() }
        }
        timer.resume()
        idleTimer = timer
    }

    private func write(_ frame: CapturedFrame, crop: FrameCrop, at time: Double, captured: Bool = false) {
        guard writer.status == .writing else {
            fail(RecordingPipelineError.writer(writer.error))
            return
        }
        // Real time: a busy encoder drops this frame rather than queueing it.
        guard input.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        let output: CVPixelBuffer
        do {
            output = try composite(frame, crop: crop, hostTime: time)
        } catch {
            fail(error)
            return
        }
        let presentationTime = CMTime(seconds: time, preferredTimescale: 1_000_000_000)
        if !sessionStarted {
            writer.startSession(atSourceTime: presentationTime)
            sessionStarted = true
        }
        if adaptor.append(output, withPresentationTime: presentationTime) {
            if captured { clock.didAppendCaptured(at: time) } else { clock.didAppend(at: time) }
            appendedFrames += 1
        } else {
            fail(RecordingPipelineError.writer(writer.error))
        }
    }

    /// A pool buffer filled by the compositor. A missing pool or buffer is
    /// a failure, not backpressure: it would never recover by itself.
    private func composite(
        _ frame: CapturedFrame, crop: FrameCrop, hostTime: Double
    ) throws(RecordingPipelineError) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        guard let output = buffer else { throw .compositionFailed }
        try compositor.composite(frame, into: output, target: decoration.withLock { $0.target(for: crop) }, hostTime: hostTime)
        return output
    }

    /// Reports a failure once; nothing more is appended.
    private func fail(_ error: any Error) {
        guard state == .writing else { return }
        state = .failed
        onFailure(error)
    }

    // MARK: Finish

    /// Finalises the MP4: the session ends at `FrameClock.sessionEnd` (the
    /// stop time, or one interval after the last good frame after a failure);
    /// a closing frame on the last grid slot before the stop refreshes the ink
    /// on the held image. Throws `.noFrames` when nothing was
    /// recorded, a writer error when the file can't be completed. After a
    /// composition failure the frames so far are still finished into a
    /// playable file (salvage — the coordinator decides whether to keep it).
    func finish() async throws {
        idleTimer?.cancel()
        idleTimer = nil
        guard state == .writing || state == .failed else { throw RecordingPipelineError.notStarted }
        let failed = state == .failed
        state = .finishing
        defer { state = .done }
        guard sessionStarted else {
            writer.cancelWriting()
            throw RecordingPipelineError.noFrames
        }
        guard writer.status == .writing else {
            writer.cancelWriting()
            throw RecordingPipelineError.writer(writer.error)
        }
        let stoppedAt = now()
        let sessionEnd = clock.sessionEnd(stoppedAt: stoppedAt, failed: failed)
        if !failed, let lastFrame, let time = clock.finalFrameTime(now: stoppedAt) {
            // The encoder may still be busy with the previous frame; this one
            // sets the length, so it's worth a short wait.
            for _ in 0..<50 where !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if input.isReadyForMoreMediaData, let output = try? composite(lastFrame, crop: lastCrop, hostTime: time),
               adaptor.append(output, withPresentationTime: CMTime(seconds: time, preferredTimescale: 1_000_000_000)) {
                clock.didAppend(at: time)
                appendedFrames += 1
            }
        }
        self.lastFrame = nil
        heldFrame = nil
        input.markAsFinished()
        if let sessionEnd {
            writer.endSession(atSourceTime: CMTime(seconds: sessionEnd, preferredTimescale: 1_000_000_000))
        }
        // The completion-handler form: the writer is non-Sendable actor state.
        let writer = self.writer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw RecordingPipelineError.writer(writer.error) }
    }

    /// Abandons the file (a start that failed after the writer was created).
    func cancel() {
        idleTimer?.cancel()
        idleTimer = nil
        guard state == .writing || state == .failed else { return }
        state = .done
        lastFrame = nil
        heldFrame = nil
        writer.cancelWriting()
    }
}

// MARK: - Compositor (capture queue)

/// Fills one output buffer: the SCK pixels copied in by CoreImage (GPU, no
/// colour conversion) — scaled into the letterbox rect for a window, black
/// bars around it — then the ink drawn over them on the CPU through the
/// decorator. Confined to `FrameWriter` (the capture queue).
///
/// Every step that can fail throws `.compositionFailed`, and the decorator is
/// called **exactly once per composed buffer** — a buffer whose drawing
/// context can't be made is never handed back to be appended.
///
/// Per-frame cost: pixel memory is pooled (the adaptor's pool; SCK's own).
/// What is rebuilt per frame is only object headers that CoreImage and
/// CoreGraphics require per render — a few `CIImage` nodes, the
/// `CIRenderDestination`, a `CGContext` wrapper over the locked buffer — none
/// of them allocates pixels. The CI context, colour space, black background
/// and the placement (crop/letterbox/transform, recomputed only when the
/// content rect changes) are reused.
final class FrameCompositor {
    /// The two system calls that can fail, injectable so tests reach the
    /// failure paths without Metal or an H.264 encoder.
    struct Seams: Sendable {
        /// Renders `image` into the buffer (GPU, synchronous).
        var render: @Sendable (CIContext, CIImage, CVPixelBuffer) throws -> Void
        /// A bitmap context over the buffer, whose base address is locked.
        var makeContext: @Sendable (CVPixelBuffer, CGColorSpace) -> CGContext?

        static let live = Seams(
            render: { context, image, buffer in
                let destination = CIRenderDestination(pixelBuffer: buffer)
                destination.colorSpace = nil
                try context.startTask(toRender: image, to: destination).waitUntilCompleted()
            },
            makeContext: { buffer, colorSpace in
                CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer),
                    width: CVPixelBufferGetWidth(buffer),
                    height: CVPixelBufferGetHeight(buffer),
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                )
            }
        )
    }

    /// Where a frame's content goes; a function of the content rect alone.
    private struct Placement {
        /// Source rect in CoreImage space (bottom-left origin).
        let source: CGRect
        let outputRect: CGRect
        let transform: CGAffineTransform
    }

    private let videoSize: VideoSize
    private let letterboxes: Bool
    private let colorSpace: CGColorSpace
    private let decorator: any FrameDecorating
    private let seams: Seams
    private let imageContext = CIContext(options: [
        // No colour management: the pixels are copied as captured, in the
        // colour space the stream was asked for (`VideoColorProfile`).
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
        .name: "Snappy recording",
    ])
    private let background: CIImage
    /// The content rect (top-left) and buffer height the placement is for.
    private var placementKey: (content: CGRect, bufferHeight: CGFloat)?
    private var placement: Placement?

    init(
        videoSize: VideoSize, letterboxes: Bool, colorSpace: CGColorSpace,
        decorator: any FrameDecorating, seams: Seams = .live
    ) {
        self.videoSize = videoSize
        self.letterboxes = letterboxes
        self.colorSpace = colorSpace
        self.decorator = decorator
        self.seams = seams
        background = CIImage(color: CIColor.black).cropped(to: videoSize.bounds)
    }

    func composite(
        _ frame: CapturedFrame, into output: CVPixelBuffer, target: DecorationTarget, hostTime: Double
    ) throws(RecordingPipelineError) {
        let placement = placement(for: frame)
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer, options: [.colorSpace: NSNull()])
            .cropped(to: placement.source)
            .clampedToExtent() // no soft, darkened edge where a scaled window meets the bars
            .transformed(by: placement.transform)
            .cropped(to: placement.outputRect)
        if placement.outputRect != videoSize.bounds {
            image = image.composited(over: background)
        }
        do {
            try seams.render(imageContext, image, output)
        } catch {
            throw .compositionFailed
        }

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let context = seams.makeContext(output, colorSpace) else { throw .compositionFailed }
        decorator.draw(
            in: context, outputRect: placement.outputRect,
            targetFrame: target.frame, windowFrame: target.windowFrame, hostTime: hostTime
        )
    }

    private func placement(for frame: CapturedFrame) -> Placement {
        let height = CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer))
        let content = frame.contentRect
            ?? CGRect(x: 0, y: 0, width: CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer)), height: height)
        if let placement, let key = placementKey, key.content == content, key.bufferHeight == height {
            return placement
        }
        let source = OutputGeometry.flipped(content, height: height)
        let outputRect = letterboxes
            ? OutputGeometry.letterboxRect(contentSize: source.size, in: videoSize) : videoSize.bounds
        let transform = CGAffineTransform(translationX: outputRect.minX, y: outputRect.minY)
            .scaledBy(x: outputRect.width / source.width, y: outputRect.height / source.height)
            .translatedBy(x: -source.minX, y: -source.minY)
        let placement = Placement(source: source, outputRect: outputRect, transform: transform)
        placementKey = (content, height)
        self.placement = placement
        return placement
    }
}

import AVFoundation
import CoreGraphics

/// A video frame size in pixels: integral, **even** on both sides (H.264
/// encodes 4:2:0, so odd sides are rejected or padded), at least 2 × 2.
struct VideoSize: Equatable, Sendable {
    let width: Int
    let height: Int

    var cgSize: CGSize { CGSize(width: width, height: height) }
    /// The whole frame, pixels, origin bottom-left (CG / CoreImage).
    var bounds: CGRect { CGRect(origin: .zero, size: cgSize) }
}

/// What an area target records: ScreenCaptureKit's `sourceRect` plus the
/// region it really covers — pixel-snapped and even-trimmed, so it can be up
/// to a pixel smaller than the requested rect.
struct AreaCapture: Equatable, Sendable {
    /// `SCStreamConfiguration.sourceRect`: display-local, origin **top-left**,
    /// y down, points.
    let sourceRect: CGRect
    /// `sourceRect` back in AppKit global points — the decorator's
    /// `targetFrame`, so the ink lands on exactly the recorded pixels.
    let capturedFrame: CGRect
    let videoSize: VideoSize
}

/// How the file's colours are tagged. The stream is asked for the same
/// colour space, and the pixels are copied through untouched, so colours are
/// kept as captured — the video equivalent of the editor keeping a Display P3
/// capture P3. Both are Apple's recommended H.264 tag sets (`AVVideoSettings.h`:
/// HD, and wide-gamut HD).
enum VideoColorProfile: Equatable, Sendable {
    case sRGB, displayP3

    /// Display P3 for a wide-gamut display (`NSScreen.canRepresent(.p3)`).
    init(wideGamut: Bool) {
        self = wideGamut ? .displayP3 : .sRGB
    }

    /// `SCStreamConfiguration.colorSpaceName`, and the decorator's context.
    var colorSpaceName: CFString {
        switch self {
        case .sRGB: CGColorSpace.sRGB
        case .displayP3: CGColorSpace.displayP3
        }
    }

    /// `AVVideoColorPropertiesKey`.
    var colorProperties: [String: String] {
        [
            AVVideoColorPrimariesKey: self == .displayP3
                ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }
}

/// PURE output math for the recording pipeline — unit-tested. The pipeline
/// does no coordinate or size arithmetic of its own (ARCHITECTURE: "ALL
/// conversions go through" a pure type).
enum OutputGeometry {
    /// The hardware H.264 encoder's limit per side, measured on an M2 Max
    /// (VideoToolbox refuses 4098 × 2304 and 4352 × 2048 but takes 4096 × 4096).
    /// Larger frames would fall back to the software encoder, which cannot
    /// keep up with 60 fps — so a 5K display records at 4096 × 2304.
    static let maxEncodableSide = 4096

    // MARK: - Sizes

    /// Largest even value ≤ `value`, at least 2.
    static func evenFloor(_ value: Int) -> Int {
        max(2, value - value % 2)
    }

    /// The video size for content of `pixelSize`: scaled down (aspect kept)
    /// until the longer side fits `maxEncodableSide`, then made even.
    static func videoSize(forPixelSize pixelSize: CGSize) -> VideoSize {
        let width = max(1, pixelSize.width.rounded())
        let height = max(1, pixelSize.height.rounded())
        let longest = max(width, height)
        let factor = longest > CGFloat(maxEncodableSide) ? CGFloat(maxEncodableSide) / longest : 1
        return VideoSize(
            width: evenFloor(Int((width * factor).rounded(.down))),
            height: evenFloor(Int((height * factor).rounded(.down)))
        )
    }

    /// An area target's capture: the rect clamped to its display, snapped to
    /// the display's pixel grid (edges rounded independently, like
    /// `CaptureGeometry.imagePixelRect`) and trimmed to even pixel sides, so
    /// SCK delivers exactly the pixels that are encoded — no resampling unless
    /// the size is over the encoder limit. nil when nothing of `globalRect`
    /// lies on the display.
    static func areaCapture(globalRect: CGRect, screenFrame: CGRect, scale: CGFloat) -> AreaCapture? {
        let clamped = globalRect.standardized.intersection(screenFrame)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0, scale > 0 else { return nil }
        let local = CaptureGeometry.displayLocalRect(fromAppKitGlobal: clamped, screenFrame: screenFrame)
        let x = evenSpan(from: local.minX * scale, to: local.maxX * scale, limit: screenFrame.width * scale)
        let y = evenSpan(from: local.minY * scale, to: local.maxY * scale, limit: screenFrame.height * scale)
        let sourceRect = CGRect(
            x: CGFloat(x.start) / scale, y: CGFloat(y.start) / scale,
            width: CGFloat(x.length) / scale, height: CGFloat(y.length) / scale
        )
        let capturedFrame = CGRect(
            x: screenFrame.minX + sourceRect.minX,
            y: screenFrame.maxY - sourceRect.maxY,
            width: sourceRect.width,
            height: sourceRect.height
        )
        return AreaCapture(
            sourceRect: sourceRect,
            capturedFrame: capturedFrame,
            videoSize: videoSize(forPixelSize: CGSize(width: x.length, height: y.length))
        )
    }

    /// One axis of `areaCapture` (and of a window part's `sourceRect`):
    /// rounded pixel edges, even length (the odd pixel is trimmed at the far
    /// edge), shifted back inside `limit` if the 2-pixel minimum would
    /// overhang the display (or window).
    static func evenSpan(from start: CGFloat, to end: CGFloat, limit: CGFloat) -> (start: Int, length: Int) {
        let pixelLimit = Int(limit.rounded())
        var first = Int(start.rounded())
        let length = min(evenFloor(Int(end.rounded()) - first), evenFloor(pixelLimit))
        if first + length > pixelLimit { first = max(0, pixelLimit - length) }
        return (first, length)
    }

    // MARK: - Frame placement

    /// Where content of `contentSize` goes in a frame of `videoSize`: scaled
    /// to fit (aspect kept), centred, on whole pixels; letterbox/pillarbox
    /// bars around it. The whole frame when the aspect ratios match. Pixels,
    /// origin bottom-left — the `outputRect` the decorator gets.
    static func letterboxRect(contentSize: CGSize, in videoSize: VideoSize) -> CGRect {
        let frame = videoSize.bounds
        guard contentSize.width > 0, contentSize.height > 0 else { return frame }
        let scale = min(frame.width / contentSize.width, frame.height / contentSize.height)
        let width = min(frame.width, (contentSize.width * scale).rounded())
        let height = min(frame.height, (contentSize.height * scale).rounded())
        return CGRect(
            x: ((frame.width - width) / 2).rounded(.down),
            y: ((frame.height - height) / 2).rounded(.down),
            width: width,
            height: height
        )
    }

    /// The content's pixel rect inside an SCK buffer, origin **top-left**.
    /// SCK reports `contentRect` in points in the surface and `scaleFactor`
    /// as pixels per point (`SCStreamFrameInfo`), so pixels = points × scale.
    /// Clamped to the buffer; the whole buffer when either is missing or the
    /// result is empty — a frame is never dropped over bad metadata.
    static func contentPixelRect(contentRect: CGRect?, scaleFactor: CGFloat?, bufferSize: CGSize) -> CGRect {
        let whole = CGRect(origin: .zero, size: bufferSize)
        guard let contentRect, let scaleFactor, scaleFactor > 0 else { return whole }
        let minX = (contentRect.minX * scaleFactor).rounded()
        let minY = (contentRect.minY * scaleFactor).rounded()
        let maxX = (contentRect.maxX * scaleFactor).rounded()
        let maxY = (contentRect.maxY * scaleFactor).rounded()
        let clamped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(whole)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return whole }
        return clamped
    }

    /// A rect in a buffer of `height` between top-left (SCK, CVPixelBuffer
    /// rows) and bottom-left (CoreImage, CGContext) origin. Its own inverse.
    static func flipped(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Encoding

    /// Average H.264 bits per pixel per frame for each quality. Screen content
    /// (flat areas, sharp text) needs far less than camera video: High keeps
    /// text crisp at 1080p60 with ~12 Mbit/s; Standard is half of that.
    static func bitsPerPixel(_ quality: RecordingQuality) -> Double {
        switch quality {
        case .standard: 0.05
        case .high: 0.1
        }
    }

    static let minimumBitrate = 1_000_000
    static let maximumBitrate = 80_000_000

    /// `AVVideoAverageBitRateKey` for a recording, bits per second.
    static func bitrate(quality: RecordingQuality, videoSize: VideoSize, framesPerSecond: Int) -> Int {
        let raw = Double(videoSize.width * videoSize.height * max(1, framesPerSecond)) * bitsPerPixel(quality)
        return min(maximumBitrate, max(minimumBitrate, Int(raw.rounded())))
    }

    /// The writer input's output settings: H.264 High, real-time friendly (no
    /// frame reordering), a key frame every 2 s, colour tags from `profile`.
    static func videoSettings(
        videoSize: VideoSize, framesPerSecond: Int, quality: RecordingQuality, profile: VideoColorProfile
    ) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height,
            AVVideoColorPropertiesKey: profile.colorProperties,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate(
                    quality: quality, videoSize: videoSize, framesPerSecond: framesPerSecond
                ),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
    }
}

/// PURE presentation-time bookkeeping for the writer — unit-tested. Times
/// are host-clock seconds (`CACurrentMediaTime()`, the clock of SCK's sample
/// times), so a frame's time is also the decorator's `hostTime`.
///
/// **A fixed slot grid** (T7 review round 2): slot k is at `t0 + k / fps`,
/// `t0` being the first appended frame (the writer session's start). Every
/// frame is stamped on a slot, and every append takes a slot **after** the
/// last one, so the output can never exceed the frame rate — whatever SCK's
/// cadence, delivery latency or timer jitter. A slot nothing fills holds the
/// previous frame (the file is variable-frame-rate).
///
/// Two sources fill slots: SCK (stamped with when the frame was *displayed*,
/// a few ms before it reaches us) and the idle re-append (SCK sends nothing
/// while the screen is static). They meet on the grid:
/// - **A captured frame** belongs to the first slot at or after its display
///   time (give or take `displayTolerance`). If that slot is already
///   filled it is not appended (`slotTimeForCaptured` → nil); the writer keeps
///   it as the content of the next slot, so nothing newer is ever lost.
/// - **An idle frame** takes the next slot once its wait is over, so a
///   jittery tick never skips a slot, and after a stall it resynchronises to
///   the latest due slot instead of bursting to catch up. While SCK is
///   delivering, a slot waits `captureGrace` past its time, so a real frame
///   within normal delivery latency claims it first; once SCK is quiet, the
///   plain idle cadence (`earlyTolerance`) applies.
struct FrameClock: Equatable, Sendable {
    /// Seconds per frame at the configured frame rate.
    let interval: Double
    private let framesPerSecond: Double
    /// When the first frame was appended — the writer session's start, and
    /// slot 0 of the grid.
    private(set) var firstTime: Double?
    private(set) var lastTime: Double?
    /// The slot of `lastTime`.
    private var lastSlot = 0
    /// The (display or slot) time of the latest captured frame, appended or not.
    private var lastCapturedTime: Double?

    init(framesPerSecond: Int) {
        let rate = Double(max(1, framesPerSecond))
        self.framesPerSecond = rate
        interval = 1 / rate
    }

    /// How early (fraction of an interval) a timer tick may come and still
    /// take the next idle frame. The timer ticks at twice the frame rate, so
    /// the tick before the slot is half an interval early — never taken —
    /// and the one at the slot is taken despite jitter.
    static let earlyTolerance = 0.25

    /// How long (fraction of an interval) past its time an idle slot waits
    /// while SCK is delivering, so the real frame for that slot — stamped at
    /// its display time, delivered a few ms later — wins: up to 0.4 interval
    /// of latency for a frame displayed on the slot (6.7 ms at 60 fps, 13 ms
    /// at 30). Deliberately not ½: the timer ticks every half interval, and
    /// a grid-aligned timer would then sit on the boundary, its early ticks
    /// missing the slot while SCK delivers sparsely. The next tick, at most
    /// about half an interval later, takes the slot: the cadence holds.
    static let captureGrace = 0.4

    /// How late (fraction of an interval) after a slot's time a captured
    /// frame may have been displayed and still be that slot's frame: as long
    /// as the idle re-append waits for it (`captureGrace`). A later frame
    /// would arrive after its slot went to an idle copy anyway; mapping it to
    /// the next slot instead leaves no slot unfilled in between.
    static let displayTolerance = captureGrace

    /// How far (intervals) past its time the next idle slot may be and still
    /// be taken in turn: one interval beyond the longest wait. A tick later
    /// than that means the timer stalled.
    static let staleAfter = 1.5

    /// How long (seconds) after the latest captured frame SCK still counts as
    /// delivering. Covers sparse updates — typing, a blinking caret — so each
    /// one still wins its slot over the idle re-append.
    static let captureMemory = 1.0

    /// SCK delivered a frame within `captureMemory` of `now`.
    func isCapturing(at now: Double) -> Bool {
        guard let lastCapturedTime else { return false }
        return now - lastCapturedTime < Self.captureMemory
    }

    /// The time of grid slot `index`. Divides by the rate (not multiplies by
    /// the interval), so whole seconds land exactly.
    private func slotTime(_ index: Int, from first: Double) -> Double {
        first + Double(index) / framesPerSecond
    }

    /// Where `time` lies on the grid, in slots (fractional).
    private func position(of time: Double, from first: Double) -> Double {
        (time - first) * framesPerSecond
    }

    /// The time to append a captured frame at — its slot's — or nil when that
    /// slot is already filled (an idle frame took it first, or SCK delivered
    /// faster than the frame rate). The caller keeps a skipped frame as the
    /// latest content and reports it with `didSkipCaptured(displayedAt:)`.
    /// The first frame of a take is slot 0 at its own time.
    func slotTimeForCaptured(_ time: Double) -> Double? {
        guard let firstTime else { return time }
        let slot = Int((position(of: time, from: firstTime) - Self.displayTolerance).rounded(.up))
        guard slot > lastSlot else { return nil }
        return slotTime(slot, from: firstTime)
    }

    /// The time to re-append the last frame at: the next slot, once its wait
    /// is over (from `earlyTolerance` before it while idle, `captureGrace`
    /// after it while SCK is delivering) — independent of when the timer
    /// actually fires, so jitter can't thin the idle frame rate. A tick more
    /// than `staleAfter` intervals past the next slot (a stalled timer)
    /// resynchronises to the latest due slot instead of bursting to catch up.
    /// nil when not due or before the first frame.
    func idleFrameTime(now: Double) -> Double? {
        guard let firstTime else { return nil }
        let wait = isCapturing(at: now) ? Self.captureGrace : -Self.earlyTolerance
        let next = lastSlot + 1
        let lateness = position(of: now, from: firstTime) - Double(next)
        guard lateness >= wait else { return nil }
        guard lateness > Self.staleAfter else { return slotTime(next, from: firstTime) }
        let latestDue = Int((position(of: now, from: firstTime) - wait).rounded(.down))
        return slotTime(latestDue, from: firstTime)
    }

    /// The closing frame at stop: the last slot at or before `now`, so the
    /// held image is re-decorated as late as the grid allows; the session
    /// still ends at `now` (`sessionEnd`). nil before the first frame or when
    /// that slot is already filled.
    func finalFrameTime(now: Double) -> Double? {
        guard let firstTime else { return nil }
        // A hair of tolerance: a stop exactly on a slot is that slot.
        let slot = Int((position(of: now, from: firstTime) + 1e-6).rounded(.down))
        guard slot > lastSlot else { return nil }
        return slotTime(slot, from: firstTime)
    }

    /// Where the writer session ends — computed *before* the closing frame,
    /// so it doesn't depend on that frame being composed or accepted. Never
    /// at the last frame's own start: a session ends at its end time, so that
    /// would drop the last frame's display interval (a one-frame take would
    /// have no length). A recording that ran to `stop` lasts until `now` (the
    /// last image holds; the closing frame, if appended, refreshes its ink);
    /// one cut short by a failure ends one interval after its last good
    /// frame — what came after it was never recorded. nil before the first frame.
    func sessionEnd(stoppedAt now: Double, failed: Bool) -> Double? {
        guard let lastTime else { return nil }
        let lastFrameEnd = lastTime + interval
        return failed ? lastFrameEnd : max(now, lastFrameEnd)
    }

    /// An idle (or closing) frame was appended at `time` (a time this clock
    /// returned, so on the grid).
    mutating func didAppend(at time: Double) {
        record(time)
    }

    /// A captured frame was appended at `time` (its slot).
    mutating func didAppendCaptured(at time: Double) {
        record(time)
        lastCapturedTime = time
    }

    /// A captured frame arrived but its slot was already filled.
    mutating func didSkipCaptured(displayedAt time: Double) {
        lastCapturedTime = max(lastCapturedTime ?? time, time)
    }

    private mutating func record(_ time: Double) {
        guard let firstTime else {
            firstTime = time
            lastTime = time
            lastSlot = 0
            return
        }
        lastTime = time
        lastSlot = Int(position(of: time, from: firstTime).rounded())
    }
}

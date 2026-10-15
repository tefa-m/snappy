import AVFoundation
import Foundation
import Testing
@testable import Snappy

@Suite("OutputGeometry")
struct OutputGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // MARK: Sizes

    @Test func evenFloorRoundsDownToEvenAtLeastTwo() {
        #expect(OutputGeometry.evenFloor(161) == 160)
        #expect(OutputGeometry.evenFloor(160) == 160)
        #expect(OutputGeometry.evenFloor(1) == 2)
        #expect(OutputGeometry.evenFloor(0) == 2)
    }

    @Test func videoSizeIsEven() {
        #expect(OutputGeometry.videoSize(forPixelSize: CGSize(width: 801, height: 599))
            == VideoSize(width: 800, height: 598))
        #expect(OutputGeometry.videoSize(forPixelSize: CGSize(width: 1, height: 1)) == VideoSize(width: 2, height: 2))
    }

    @Test func videoSizeFitsTheHardwareEncoderPerSide() {
        // A 5K display: scaled to 4096 wide, aspect kept.
        #expect(OutputGeometry.videoSize(forPixelSize: CGSize(width: 5120, height: 2880))
            == VideoSize(width: 4096, height: 2304))
        // Portrait 6K: the longer side is the height.
        let portrait = OutputGeometry.videoSize(forPixelSize: CGSize(width: 3384, height: 6016))
        #expect(portrait.height == 4096 && portrait.width <= 4096 && portrait.width % 2 == 0)
        #expect(abs(Double(portrait.width) / Double(portrait.height) - 3384.0 / 6016.0) < 0.001)
        // Exactly at the limit stays as is.
        #expect(OutputGeometry.videoSize(forPixelSize: CGSize(width: 4096, height: 4096))
            == VideoSize(width: 4096, height: 4096))
    }

    // MARK: Area capture

    @Test func areaCaptureOnARetinaDisplay() throws {
        // AppKit y = 100 from the bottom of a 982 pt display → top-left y = 982 − 400 = 582.
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let capture = try #require(OutputGeometry.areaCapture(globalRect: rect, screenFrame: screen, scale: 2))
        #expect(capture.sourceRect == CGRect(x: 100, y: 582, width: 400, height: 300))
        #expect(capture.capturedFrame == rect)
        #expect(capture.videoSize == VideoSize(width: 800, height: 600))
    }

    @Test func areaCaptureTrimsToEvenPixelsAndReportsWhatIsCaptured() throws {
        // 1× display: 161 × 99 pt = 161 × 99 px → 160 × 98, trimmed at the far
        // (right / bottom) edges.
        let rect = CGRect(x: 10, y: 20, width: 161, height: 99)
        let capture = try #require(OutputGeometry.areaCapture(globalRect: rect, screenFrame: screen, scale: 1))
        #expect(capture.videoSize == VideoSize(width: 160, height: 98))
        #expect(capture.sourceRect == CGRect(x: 10, y: 982 - 119, width: 160, height: 98))
        // Trimming the bottom row raises the AppKit minY by one point.
        #expect(capture.capturedFrame == CGRect(x: 10, y: 21, width: 160, height: 98))
    }

    @Test func areaCaptureSnapsFractionalPointsToThePixelGrid() throws {
        let rect = CGRect(x: 10.3, y: 20.2, width: 100.4, height: 50.1)
        let capture = try #require(OutputGeometry.areaCapture(globalRect: rect, screenFrame: screen, scale: 2))
        // Every edge lands on a whole pixel (half point at 2×).
        for value in [capture.sourceRect.minX, capture.sourceRect.minY, capture.sourceRect.width, capture.sourceRect.height] {
            #expect((value * 2).rounded() == value * 2)
        }
        #expect(capture.videoSize.width == Int(capture.sourceRect.width * 2))
        #expect(capture.videoSize.height == Int(capture.sourceRect.height * 2))
        #expect(abs(capture.capturedFrame.minX - rect.minX) <= 0.5)
        #expect(abs(capture.capturedFrame.maxY - rect.maxY) <= 0.5)
    }

    @Test func areaCaptureOnASecondaryDisplayIsDisplayLocal() throws {
        // A display left of and above the primary: AppKit origin (−1920, 200).
        let left = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let rect = CGRect(x: -1820, y: 280, width: 640, height: 480)
        let capture = try #require(OutputGeometry.areaCapture(globalRect: rect, screenFrame: left, scale: 1))
        // Top-left: x = 100, y = (200 + 1080) − (280 + 480) = 520.
        #expect(capture.sourceRect == CGRect(x: 100, y: 520, width: 640, height: 480))
        #expect(capture.capturedFrame == rect)
    }

    @Test func areaCaptureIsClampedToItsDisplay() throws {
        let overhanging = CGRect(x: 1400, y: -50, width: 300, height: 200)
        let capture = try #require(OutputGeometry.areaCapture(globalRect: overhanging, screenFrame: screen, scale: 2))
        #expect(capture.capturedFrame == CGRect(x: 1400, y: 0, width: 112, height: 150))
        #expect(capture.sourceRect.maxX <= screen.width && capture.sourceRect.maxY <= screen.height)
    }

    @Test func aOnePixelAreaAtTheEdgeStaysOnTheDisplay() throws {
        let sliver = CGRect(x: 1511, y: 0, width: 1, height: 1)
        let capture = try #require(OutputGeometry.areaCapture(globalRect: sliver, screenFrame: screen, scale: 1))
        #expect(capture.videoSize == VideoSize(width: 2, height: 2))
        #expect(capture.sourceRect == CGRect(x: 1510, y: 980, width: 2, height: 2))
    }

    @Test func areaCaptureOfA5KDisplayIsCappedNotCropped() throws {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let capture = try #require(OutputGeometry.areaCapture(globalRect: display, screenFrame: display, scale: 2))
        #expect(capture.sourceRect == CGRect(x: 0, y: 0, width: 2560, height: 1440))
        #expect(capture.videoSize == VideoSize(width: 4096, height: 2304))
    }

    @Test func areaOffTheDisplayIsNil() {
        #expect(OutputGeometry.areaCapture(
            globalRect: CGRect(x: 2000, y: 0, width: 100, height: 100), screenFrame: screen, scale: 2
        ) == nil)
        #expect(OutputGeometry.areaCapture(
            globalRect: CGRect(x: 10, y: 10, width: 100, height: 100), screenFrame: screen, scale: 0
        ) == nil)
    }

    // MARK: Letterbox

    @Test func letterboxFillsTheFrameWhenTheAspectMatches() {
        let video = VideoSize(width: 800, height: 600)
        #expect(OutputGeometry.letterboxRect(contentSize: CGSize(width: 400, height: 300), in: video) == video.bounds)
        #expect(OutputGeometry.letterboxRect(contentSize: CGSize(width: 800, height: 600), in: video) == video.bounds)
    }

    @Test func aWiderWindowGetsBarsTopAndBottom() {
        let rect = OutputGeometry.letterboxRect(
            contentSize: CGSize(width: 1600, height: 600), in: VideoSize(width: 800, height: 600)
        )
        #expect(rect == CGRect(x: 0, y: 150, width: 800, height: 300))
    }

    @Test func aTallerWindowGetsBarsLeftAndRight() {
        let rect = OutputGeometry.letterboxRect(
            contentSize: CGSize(width: 200, height: 200), in: VideoSize(width: 320, height: 240)
        )
        #expect(rect == CGRect(x: 40, y: 0, width: 240, height: 240))
    }

    @Test func letterboxIsOnWholePixelsAndInsideTheFrame() {
        let video = VideoSize(width: 1000, height: 562)
        let rect = OutputGeometry.letterboxRect(contentSize: CGSize(width: 777, height: 333), in: video)
        #expect(rect == rect.integral)
        #expect(video.bounds.contains(rect))
        // Centred to within a pixel.
        #expect(abs(rect.midX - video.bounds.midX) <= 1 && abs(rect.midY - video.bounds.midY) <= 1)
    }

    @Test func letterboxOfEmptyContentIsTheWholeFrame() {
        let video = VideoSize(width: 320, height: 240)
        #expect(OutputGeometry.letterboxRect(contentSize: .zero, in: video) == video.bounds)
    }

    // MARK: Content rect

    @Test func contentRectIsPointsTimesScaleFactor() {
        let rect = OutputGeometry.contentPixelRect(
            contentRect: CGRect(x: 0, y: 50, width: 400, height: 200), scaleFactor: 2,
            bufferSize: CGSize(width: 800, height: 600)
        )
        #expect(rect == CGRect(x: 0, y: 100, width: 800, height: 400))
    }

    @Test func contentRectIsClampedOrFallsBackToTheWholeBuffer() {
        let buffer = CGSize(width: 800, height: 600)
        let whole = CGRect(origin: .zero, size: buffer)
        #expect(OutputGeometry.contentPixelRect(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), scaleFactor: 2, bufferSize: buffer
        ) == whole)
        #expect(OutputGeometry.contentPixelRect(contentRect: nil, scaleFactor: 2, bufferSize: buffer) == whole)
        #expect(OutputGeometry.contentPixelRect(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), scaleFactor: nil, bufferSize: buffer
        ) == whole)
        #expect(OutputGeometry.contentPixelRect(
            contentRect: CGRect(x: 900, y: 0, width: 10, height: 10), scaleFactor: 1, bufferSize: buffer
        ) == whole)
    }

    @Test func flippedSwapsTopLeftAndBottomLeftAndIsItsOwnInverse() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        #expect(OutputGeometry.flipped(rect, height: 600) == CGRect(x: 10, y: 530, width: 100, height: 50))
        #expect(OutputGeometry.flipped(OutputGeometry.flipped(rect, height: 600), height: 600) == rect)
    }

    // MARK: Encoding

    @Test func bitrateTable() {
        let hd = VideoSize(width: 1920, height: 1080)
        #expect(OutputGeometry.bitrate(quality: .high, videoSize: hd, framesPerSecond: 60) == 12_441_600)
        #expect(OutputGeometry.bitrate(quality: .standard, videoSize: hd, framesPerSecond: 60) == 6_220_800)
        #expect(OutputGeometry.bitrate(quality: .high, videoSize: hd, framesPerSecond: 30) == 6_220_800)
    }

    @Test func bitrateIsClamped() {
        #expect(OutputGeometry.bitrate(quality: .standard, videoSize: VideoSize(width: 2, height: 2), framesPerSecond: 30)
            == OutputGeometry.minimumBitrate)
        // A full 4096 × 4096 at 60 fps would ask for 100 Mbit/s.
        #expect(OutputGeometry.bitrate(quality: .high, videoSize: VideoSize(width: 4096, height: 4096), framesPerSecond: 60)
            == OutputGeometry.maximumBitrate)
    }

    @Test func highIsAlwaysAtLeastStandard() {
        for size in [VideoSize(width: 320, height: 240), VideoSize(width: 3024, height: 1964), VideoSize(width: 4096, height: 2304)] {
            for fps in RecordingFrameRate.allCases.map(\.framesPerSecond) {
                #expect(OutputGeometry.bitrate(quality: .high, videoSize: size, framesPerSecond: fps)
                    >= OutputGeometry.bitrate(quality: .standard, videoSize: size, framesPerSecond: fps))
            }
        }
    }

    @Test func videoSettingsAreRealTimeH264() throws {
        let settings = OutputGeometry.videoSettings(
            videoSize: VideoSize(width: 800, height: 600), framesPerSecond: 60, quality: .high, profile: .displayP3
        )
        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == .h264)
        #expect(settings[AVVideoWidthKey] as? Int == 800 && settings[AVVideoHeightKey] as? Int == 600)
        let compression = try #require(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(compression[AVVideoAllowFrameReorderingKey] as? Bool == false)
        #expect(compression[AVVideoMaxKeyFrameIntervalKey] as? Int == 120)
        #expect(compression[AVVideoAverageBitRateKey] as? Int
            == OutputGeometry.bitrate(quality: .high, videoSize: VideoSize(width: 800, height: 600), framesPerSecond: 60))
        #expect(settings[AVVideoColorPropertiesKey] as? [String: String] == VideoColorProfile.displayP3.colorProperties)
    }

    @Test func colourProfiles() {
        #expect(VideoColorProfile(wideGamut: true) == .displayP3)
        #expect(VideoColorProfile(wideGamut: false) == .sRGB)
        #expect(VideoColorProfile.displayP3.colorSpaceName == CGColorSpace.displayP3)
        #expect(VideoColorProfile.sRGB.colorSpaceName == CGColorSpace.sRGB)
        #expect(VideoColorProfile.displayP3.colorProperties[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_P3_D65)
        #expect(VideoColorProfile.sRGB.colorProperties[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_ITU_R_709_2)
        for profile in [VideoColorProfile.sRGB, .displayP3] {
            #expect(profile.colorProperties[AVVideoTransferFunctionKey] == AVVideoTransferFunction_ITU_R_709_2)
            #expect(profile.colorProperties[AVVideoYCbCrMatrixKey] == AVVideoYCbCrMatrix_ITU_R_709_2)
        }
    }
}

@Suite("FrameClock")
struct FrameClockTests {
    @Test func intervalFollowsTheFrameRate() {
        #expect(FrameClock(framesPerSecond: 60).interval == 1.0 / 60)
        #expect(FrameClock(framesPerSecond: 30).interval == 1.0 / 30)
    }

    @Test func nothingIsDueBeforeTheFirstFrame() {
        let clock = FrameClock(framesPerSecond: 60)
        #expect(clock.slotTimeForCaptured(5) == 5) // the first frame starts the grid
        #expect(clock.idleFrameTime(now: 100) == nil)
        #expect(clock.finalFrameTime(now: 100) == nil)
        #expect(clock.firstTime == nil && clock.lastTime == nil)
    }

    @Test func firstAndLastTimesFollowAppends() {
        var clock = FrameClock(framesPerSecond: 60)
        clock.didAppend(at: 10)
        clock.didAppend(at: 10.5)
        #expect(clock.firstTime == 10 && clock.lastTime == 10.5)
    }

    /// T7 review round 2: frames are stamped on the slot grid (t0 + k / fps),
    /// not at their own display time — what caps the output at the frame rate.
    @Test func capturedFramesAreStampedOnTheirSlot() {
        var clock = FrameClock(framesPerSecond: 60)
        clock.didAppendCaptured(at: 10)
        let slot1: Double = 10 + 1.0 / 60, slot2: Double = 10 + 2.0 / 60
        // Displayed up to the capture grace after a slot: that slot.
        #expect(clock.slotTimeForCaptured(slot1 + 0.3 / 60) == slot1)
        // Later than that: the next slot.
        #expect(clock.slotTimeForCaptured(slot1 + 0.5 / 60) == slot2)
        #expect(clock.slotTimeForCaptured(10.5) == 10.5)
    }

    @Test func aCapturedFrameWhoseSlotIsFilledIsNotAppended() {
        var clock = FrameClock(framesPerSecond: 60)
        clock.didAppendCaptured(at: 10)
        let slot3: Double = 10 + 3.0 / 60, slot4: Double = 10 + 4.0 / 60
        clock.didAppend(at: slot3) // an idle frame took slot 3
        // SCK's frames for slot 3, delivered after the idle one: no second frame in it.
        #expect(clock.slotTimeForCaptured(slot3 - 0.1 / 60) == nil)
        #expect(clock.slotTimeForCaptured(slot3 + 0.3 / 60) == nil)
        // Displayed past slot 3's tolerance: slot 4.
        #expect(clock.slotTimeForCaptured(slot3 + 0.5 / 60) == slot4)
    }

    @Test func idleFramesAreDueAfterAWholeInterval() {
        var clock = FrameClock(framesPerSecond: 60)
        clock.didAppend(at: 10)
        let oneIntervalLater: Double = 10 + 1.0 / 60
        #expect(clock.idleFrameTime(now: 10.01) == nil)
        #expect(clock.idleFrameTime(now: oneIntervalLater) == oneIntervalLater)
        #expect(clock.idleFrameTime(now: 12) == 12)
    }

    @Test func aSlightlyEarlyTickTakesTheFrameOnTheCadence() {
        var clock = FrameClock(framesPerSecond: 60)
        clock.didAppend(at: 10)
        let deadline: Double = 10 + 1.0 / 60
        // 0.1 ms early: still stamped on the deadline, not skipped.
        #expect(clock.idleFrameTime(now: deadline - 0.0001) == deadline)
        // Half an interval early (the previous 2× tick): not taken.
        #expect(clock.idleFrameTime(now: 10 + 0.5 / 60) == nil)
        // Late but within the next interval: still the deadline (no drift).
        #expect(clock.idleFrameTime(now: deadline + 0.01) == deadline)
    }

    /// Review round 1 #5: ticks at twice the frame rate with alternating
    /// ±0.1 ms jitter used to yield 44 frames/s at 60 fps and 21 at 30.
    @Test(arguments: [30, 60])
    func sustainedIdleKeepsTheFrameRateDespiteJitter(fps: Int) {
        var clock = FrameClock(framesPerSecond: fps)
        clock.didAppend(at: 0)
        var times: [Double] = []
        for tick in 1...(2 * fps) { // one second of ticks
            let jitter = tick.isMultiple(of: 2) ? 0.0001 : -0.0001
            let now = Double(tick) * clock.interval / 2 + jitter
            if let time = clock.idleFrameTime(now: now) {
                clock.didAppend(at: time)
                times.append(time)
            }
        }
        #expect(times.count >= fps - 1)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - clock.interval) < 1e-9 })
    }

    @Test func aLongStallResynchronisesInsteadOfBursting() {
        var clock = FrameClock(framesPerSecond: 60)
        clock.didAppend(at: 10)
        // The timer stalled for half a second: one frame at now, not 30 catch-up frames.
        #expect(clock.idleFrameTime(now: 10.5) == 10.5)
        clock.didAppend(at: 10.5)
        #expect(clock.idleFrameTime(now: 10.505) == nil)
    }

    @Test func idleTimesAreStrictlyIncreasing() {
        var clock = FrameClock(framesPerSecond: 30)
        clock.didAppend(at: 0)
        var last = 0.0
        var now = 0.0
        for _ in 0..<200 {
            now += 1.0 / 60 // ticks at twice the frame rate
            if let time = clock.idleFrameTime(now: now) {
                #expect(time > last)
                clock.didAppend(at: time)
                last = time
            }
        }
        // ~200 ticks at 2× the frame rate → roughly one frame per interval.
        #expect(last > 3.2)
    }

    /// Review round 2: the session must end after the last frame's start,
    /// or the last frame (a one-frame take: everything) has no length.
    @Test func theSessionEndsAtStopOrOneIntervalAfterTheLastGoodFrame() {
        var clock = FrameClock(framesPerSecond: 60)
        #expect(clock.sessionEnd(stoppedAt: 5, failed: false) == nil)
        clock.didAppend(at: 10)
        let lastFrameEnd: Double = 10 + 1.0 / 60
        // Ran to stop: the last image holds until the stop time.
        #expect(clock.sessionEnd(stoppedAt: 13, failed: false) == 13)
        // Stopped right after a frame: that frame still gets its interval.
        #expect(clock.sessionEnd(stoppedAt: 10.001, failed: false) == lastFrameEnd)
        #expect(clock.sessionEnd(stoppedAt: 10, failed: false) == lastFrameEnd)
        // Cut short by a failure: one interval after the last good frame, not until stop.
        #expect(clock.sessionEnd(stoppedAt: 13, failed: true) == lastFrameEnd)
        for case let end? in [clock.sessionEnd(stoppedAt: 10, failed: false), clock.sessionEnd(stoppedAt: 13, failed: true)] {
            #expect(end > 10)
        }
    }

    @Test func theFinalFrameHoldsTheLastImageUntilStop() {
        var clock = FrameClock(framesPerSecond: 60)
        clock.didAppend(at: 10)
        #expect(clock.finalFrameTime(now: 13) == 13)
        #expect(clock.finalFrameTime(now: 10) == nil)
        #expect(clock.finalFrameTime(now: 10.0005) == nil)
    }
}

@Suite("RecordingPipelineError")
struct RecordingPipelineErrorTests {
    @Test func everyCaseHasAWrittenReason() {
        let cases: [RecordingPipelineError] = [
            .displayUnavailable, .windowUnavailable, .snappyNotListed, .streamFailed, .compositionFailed,
            .writerFailed, .diskFull, .noFrames, .notStarted,
        ]
        for error in cases {
            let reason = error.errorDescription ?? ""
            #expect(reason.count > 10 && reason.hasSuffix("."))
            // It reaches the alert as the reason line, never as a type dump.
            #expect(UserFacingText.recordingFailed(error).message.hasPrefix(reason))
        }
    }

    @Test func aFullDiskIsRecognised() {
        #expect(RecordingPipelineError.writer(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue))
            == .diskFull)
        #expect(RecordingPipelineError.writer(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
            == .diskFull)
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ])
        #expect(RecordingPipelineError.writer(wrapped) == .diskFull)
    }

    @Test func otherWriterErrorsAreGeneric() {
        #expect(RecordingPipelineError.writer(nil) == .writerFailed)
        #expect(RecordingPipelineError.writer(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue))
            == .writerFailed)
    }
}

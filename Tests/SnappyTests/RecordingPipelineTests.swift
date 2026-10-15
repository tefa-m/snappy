import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Testing
import os
@testable import Snappy

/// The writer half of the pipeline, headless: synthetic BGRA frames stand in
/// for ScreenCaptureKit (which needs Screen Recording permission — the live
/// stream is on the manual checklist), the MP4 is read back with AVFoundation.
/// Needs the H.264 encoder, which a sandbox may not offer.
@Suite("FrameWriter")
struct FrameWriterTests {
    // MARK: Helpers

    /// Records every decorator call; optionally paints a green 20 × 20 square
    /// at the output rect's bottom-left corner, like ink would.
    private final class Decorator: FrameDecorating {
        struct Call: Equatable {
            let outputRect: CGRect
            let targetFrame: CGRect
            let windowFrame: CGRect?
            let hostTime: TimeInterval
        }

        let paints: Bool
        private let calls = OSAllocatedUnfairLock(initialState: [Call]())

        init(paints: Bool = false) { self.paints = paints }

        var recorded: [Call] { calls.withLock { $0 } }

        func draw(
            in context: CGContext, outputRect: CGRect, targetFrame: CGRect, windowFrame: CGRect?, hostTime: TimeInterval
        ) {
            calls.withLock {
                $0.append(Call(outputRect: outputRect, targetFrame: targetFrame, windowFrame: windowFrame, hostTime: hostTime))
            }
            guard paints else { return }
            context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: outputRect.minX, y: outputRect.minY, width: 20, height: 20))
        }
    }

    /// A settable host clock.
    private final class Clock: Sendable {
        private let value: OSAllocatedUnfairLock<Double>
        init(_ start: Double) { value = OSAllocatedUnfairLock(initialState: start) }
        var now: Double { value.withLock { $0 } }
        func set(_ time: Double) { value.withLock { $0 = time } }
    }

    private struct Take {
        let url: URL
        let directory: URL
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeTake() throws -> Take {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SnappyPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Take(url: directory.appending(path: "take.mp4"), directory: directory)
    }

    private func makeWriter(
        _ take: Take, size: VideoSize = VideoSize(width: 320, height: 240), letterboxes: Bool = false,
        profile: VideoColorProfile = .sRGB, target: DecorationTarget = .area(CGRect(x: 10, y: 20, width: 160, height: 120)),
        decorator: Decorator, clock: Clock, seams: FrameCompositor.Seams = .live,
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in }
    ) throws -> FrameWriter {
        try FrameWriter(
            outputURL: take.url, videoSize: size, framesPerSecond: 60, quality: .standard, profile: profile,
            letterboxes: letterboxes, target: target, decorator: decorator, compositorSeams: seams,
            now: { clock.now }, onFailure: onFailure
        )
    }

    /// An IOSurface-backed BGRA buffer of one colour, like SCK delivers.
    private func frame(
        width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8, time: Double, contentRect: CGRect? = nil
    ) throws -> CapturedFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * bytesPerRow + x * 4
                pixel[0] = blue; pixel[1] = green; pixel[2] = red; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return CapturedFrame(pixelBuffer: pixelBuffer, contentRect: contentRect, time: time)
    }

    /// Gives the real-time encoder a moment, so a frame isn't dropped as busy.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(30))
    }

    /// RGBA of one decoded pixel, (x, y) from the top-left.
    private func pixel(of image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return bytes
    }

    private func decodedFrame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    // MARK: Tests

    @Test func writesAPlayableMP4FromTheFirstFrameUntilStop() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let decorator = Decorator()
        let clock = Clock(100)
        let writer = try makeWriter(take, profile: .displayP3, decorator: decorator, clock: clock)

        for index in 0..<4 {
            let time = 100 + Double(index) * 0.1
            clock.set(time)
            await writer.append(try frame(width: 320, height: 240, red: 200, green: 30, blue: 30, time: time))
            try await settle()
        }
        clock.set(101) // stopped a while after the last change: the closing frame holds it
        try await writer.finish()

        let asset = AVURLAsset(url: take.url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 1.0) < 0.05)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 240))
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
            as? String == kCMFormatDescriptionColorPrimaries_P3_D65 as String)

        // Every appended frame was decorated, full-frame, at its own time.
        let calls = decorator.recorded
        #expect(calls.count == (await writer.appendedFrames))
        #expect(calls.count == 5) // 4 captured + the closing frame
        #expect(calls.allSatisfy { $0.outputRect == CGRect(x: 0, y: 0, width: 320, height: 240) })
        #expect(calls.allSatisfy { $0.targetFrame == CGRect(x: 10, y: 20, width: 160, height: 120) })
        let captureTimes: [Double] = (0..<4).map { 100 + Double($0) * 0.1 }
        let hostTimes: [Double] = calls.map(\.hostTime)
        #expect(hostTimes == captureTimes + [101])
    }

    @Test func idleTicksReappendTheLastFrameReDecorated() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let decorator = Decorator()
        let clock = Clock(100)
        let writer = try makeWriter(take, decorator: decorator, clock: clock)

        await writer.idleTick() // nothing to re-append before the first frame
        #expect(decorator.recorded.isEmpty)

        await writer.append(try frame(width: 320, height: 240, red: 0, green: 0, blue: 200, time: 100))
        try await settle()
        clock.set(100.005)
        await writer.idleTick() // not a whole interval yet
        #expect(decorator.recorded.count == 1)

        // Every frame is stamped on the grid of slots 100 + k / 60.
        func slot(_ index: Int) -> Double { 100 + Double(index) / 60 }
        // SCK just delivered: slot 1 waits the capture grace (0.4 interval)
        // for SCK's own frame, then is re-appended on the slot.
        clock.set(slot(1) + 0.3 / 60)
        await writer.idleTick()
        #expect(decorator.recorded.count == 1)
        clock.set(slot(1) + 0.5 / 60)
        await writer.idleTick()
        try await settle()
        #expect(decorator.recorded.map(\.hostTime) == [100, slot(1)])

        // A late SCK frame for slot 1: the slot is filled, so it isn't
        // appended next to the idle frame (T7 review r1 #1: those
        // near-duplicates pushed 60 fps takes to 75–81 fps) …
        await writer.append(try frame(width: 320, height: 240, red: 200, green: 0, blue: 0, time: slot(1) + 0.1 / 60))
        #expect(decorator.recorded.count == 2)
        #expect(await writer.skippedFrames == 1)
        // … it is the content of the next slot, after the grace, on the grid.
        clock.set(slot(2) + 0.3 / 60)
        await writer.idleTick()
        #expect(decorator.recorded.count == 2)
        clock.set(slot(2) + 0.6 / 60)
        await writer.idleTick()
        try await settle()
        #expect(decorator.recorded.map(\.hostTime) == [100, slot(1), slot(2)])

        // SCK quiet for over a second and the timer stalled: one frame on the
        // latest due slot (no catch-up burst), then the plain idle cadence.
        clock.set(slot(90))
        await writer.idleTick()
        try await settle()
        clock.set(slot(91) - 0.0001)
        await writer.idleTick()
        try await settle()
        #expect(decorator.recorded.map(\.hostTime) == [100, slot(1), slot(2), slot(90), slot(91)])

        clock.set(102)
        try await writer.finish()
        let duration = try await AVURLAsset(url: take.url).load(.duration)
        #expect(abs(duration.seconds - 2) < 0.05)
        let late = try await decodedFrame(take.url, at: slot(2) - 100 + 0.002)
        #expect(try pixel(of: late, x: 160, y: 120)[0] > 150) // the late frame's red
    }

    @Test func aResizedWindowIsLetterboxedWithTheInkOnTheContent() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let decorator = Decorator(paints: true)
        let clock = Clock(10)
        let window = CGRect(x: 300, y: 200, width: 100, height: 100)
        let writer = try makeWriter(take, letterboxes: true, target: .window(window), decorator: decorator, clock: clock)

        // A square window in a 4:3 video; SCK left it in the buffer's
        // top-left corner (contentRect), the writer centres it.
        await writer.append(try frame(
            width: 320, height: 240, red: 220, green: 20, blue: 20, time: 10,
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 200)
        ))
        try await settle()
        clock.set(10.5)
        try await writer.finish()

        let outputRect = CGRect(x: 40, y: 0, width: 240, height: 240)
        #expect(decorator.recorded.first?.outputRect == outputRect)
        #expect(decorator.recorded.first?.targetFrame == window)
        #expect(decorator.recorded.first?.windowFrame == window)

        let image = try await decodedFrame(take.url, at: 0.1)
        let centre = try pixel(of: image, x: 160, y: 120)
        #expect(centre[0] > 180 && centre[1] < 70 && centre[2] < 70) // red content
        let bar = try pixel(of: image, x: 10, y: 120)
        #expect(bar[0] < 30 && bar[1] < 30 && bar[2] < 30) // black pillarbox bar
        // The ink square at the output rect's bottom-left: x 40…60, rows 220…240 from the top.
        let ink = try pixel(of: image, x: 50, y: 230)
        #expect(ink[1] > 180 && ink[0] < 90)
    }

    @Test func finishWithoutAFrameThrowsNoFrames() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let writer = try makeWriter(take, decorator: Decorator(), clock: Clock(5))
        await #expect(throws: RecordingPipelineError.noFrames) {
            try await writer.finish()
        }
    }

    @Test func nothingIsAppendedAfterFinishOrCancel() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let decorator = Decorator()
        let clock = Clock(1)
        let writer = try makeWriter(take, decorator: decorator, clock: clock)
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 1))
        try await settle()
        clock.set(2)
        try await writer.finish()
        let count = decorator.recorded.count
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 3))
        clock.set(4)
        await writer.idleTick()
        #expect(decorator.recorded.count == count)
        await #expect(throws: RecordingPipelineError.notStarted) {
            try await writer.finish()
        }

        let other = try makeTake()
        defer { other.remove() }
        let cancelled = try makeWriter(other, decorator: decorator, clock: clock)
        await cancelled.cancel()
        await cancelled.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 5))
        #expect(decorator.recorded.count == count)
        await #expect(throws: RecordingPipelineError.notStarted) {
            try await cancelled.finish()
        }
    }

    /// A writer whose CoreImage render can be broken mid-take, collecting failures.
    private func breakableWriter(
        _ take: Take, decorator: Decorator, clock: Clock
    ) throws -> (writer: FrameWriter, breaks: OSAllocatedUnfairLock<Bool>, failures: OSAllocatedUnfairLock<[RecordingPipelineError]>) {
        let breaks = OSAllocatedUnfairLock(initialState: false)
        let failures = OSAllocatedUnfairLock(initialState: [RecordingPipelineError]())
        var seams = FrameCompositor.Seams.live
        let live = seams.render
        seams.render = { context, image, buffer in
            if breaks.withLock({ $0 }) { throw CocoaError(.featureUnsupported) }
            try live(context, image, buffer)
        }
        let writer = try makeWriter(take, decorator: decorator, clock: clock, seams: seams) { error in
            failures.withLock { $0.append(error as? RecordingPipelineError ?? .notStarted) }
        }
        return (writer, breaks, failures)
    }

    /// Duration and one decoded frame's centre pixel (RGBA) of a finished take.
    private func readBack(_ url: URL, frameAt seconds: Double) async throws -> (duration: Double, centre: [UInt8]) {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        let image = try await decodedFrame(url, at: seconds)
        return (duration, try pixel(of: image, x: image.width / 2, y: image.height / 2))
    }

    /// Review round 1 #4 + round 2: a composition failure fails the recording
    /// once (never a silent drop), and the one good frame is still finished
    /// into a playable clip **one frame interval long** — not zero.
    @Test func aCompositionFailureAfterOneFrameStillLeavesAOneFrameClip() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let clock = Clock(50)
        let (writer, breaks, failures) = try breakableWriter(take, decorator: Decorator(), clock: clock)

        await writer.append(try frame(width: 320, height: 240, red: 40, green: 200, blue: 40, time: 50))
        try await settle()
        breaks.withLock { $0 = true }
        clock.set(50.2)
        await writer.append(try frame(width: 320, height: 240, red: 40, green: 200, blue: 40, time: 50.2))
        await writer.append(try frame(width: 320, height: 240, red: 40, green: 200, blue: 40, time: 50.3))
        clock.set(50.4)
        await writer.idleTick()
        #expect(failures.withLock { $0 } == [.compositionFailed])
        #expect(await writer.appendedFrames == 1)
        #expect(await writer.droppedFrames == 0)

        try await writer.finish()
        let clip = try await readBack(take.url, frameAt: 0)
        #expect(abs(clip.duration - 1.0 / 60) < 0.005)
        #expect(clip.centre[1] > 150 && clip.centre[0] < 100) // the green frame decodes
    }

    @Test func aCompositionFailureAfterSeveralFramesKeepsTheLastFramesInterval() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let clock = Clock(70)
        let (writer, breaks, failures) = try breakableWriter(take, decorator: Decorator(), clock: clock)
        for index in 0..<3 {
            let time = 70 + Double(index) * 0.1
            clock.set(time)
            await writer.append(try frame(width: 320, height: 240, red: 200, green: 40, blue: 40, time: time))
            try await settle()
        }
        breaks.withLock { $0 = true }
        clock.set(70.3)
        await writer.append(try frame(width: 320, height: 240, red: 200, green: 40, blue: 40, time: 70.3))
        #expect(failures.withLock { $0 } == [.compositionFailed])
        clock.set(71) // stopped later: the failure, not the stop, bounds the clip
        try await writer.finish()

        let clip = try await readBack(take.url, frameAt: 0.21) // inside the last frame’s interval (0.2 … 0.217)
        #expect(abs(clip.duration - (0.2 + 1.0 / 60)) < 0.01)
        #expect(clip.centre[0] > 150 && clip.centre[1] < 100)
    }

    /// The closing frame can fail (composition) or be refused (busy encoder):
    /// the take still lasts until stop, holding the last good image.
    @Test func aClosingFrameThatCannotBeComposedStillLastsUntilStop() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let clock = Clock(80)
        let (writer, breaks, failures) = try breakableWriter(take, decorator: Decorator(), clock: clock)
        await writer.append(try frame(width: 320, height: 240, red: 40, green: 40, blue: 200, time: 80))
        try await settle()
        clock.set(80.1)
        await writer.append(try frame(width: 320, height: 240, red: 40, green: 40, blue: 200, time: 80.1))
        try await settle()
        breaks.withLock { $0 = true } // only the closing frame hits it
        clock.set(81)
        try await writer.finish()
        #expect(failures.withLock { $0 }.isEmpty)
        #expect(await writer.appendedFrames == 2)

        let clip = try await readBack(take.url, frameAt: 0.9)
        #expect(abs(clip.duration - 1.0) < 0.02)
        #expect(clip.centre[2] > 150 && clip.centre[0] < 100)
    }

    @Test func theWindowFrameLockFeedsTheDecorator() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let decorator = Decorator()
        let clock = Clock(1)
        let writer = try makeWriter(
            take, letterboxes: true, target: .window(CGRect(x: 10, y: 20, width: 160, height: 120)),
            decorator: decorator, clock: clock
        )
        let moved = CGRect(x: 500, y: 400, width: 160, height: 120)
        writer.decoration.withLock { $0.windowMoved(to: moved) } // what the main actor does on a window move
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 1))
        #expect(decorator.recorded.last?.targetFrame == moved)
        #expect(decorator.recorded.last?.windowFrame == moved)
        await writer.cancel()
    }

    /// W + part (V3): the decorator maps the **part** onto the frame and gets
    /// the window for the anchors; a window move carries the part along, a
    /// crop SCK took moves it inside the window.
    @Test func aPartTargetGivesTheDecoratorThePartAndItsWindow() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let decorator = Decorator()
        let clock = Clock(1)
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let source = CGRect(x: 0, y: 80, width: 800, height: 520) // below an 80 pt toolbar
        let writer = try makeWriter(
            take, letterboxes: true, target: .part(window: window, sourceRect: source), decorator: decorator, clock: clock
        )
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 1))
        #expect(decorator.recorded.last?.targetFrame == CGRect(x: 100, y: 100, width: 800, height: 520))
        #expect(decorator.recorded.last?.windowFrame == window)

        writer.decoration.withLock { $0.windowMoved(to: window.offsetBy(dx: 50, dy: -20)) }
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 1.1))
        #expect(decorator.recorded.last?.targetFrame == CGRect(x: 150, y: 80, width: 800, height: 520))

        writer.decoration.withLock { // what `PartCropUpdater` does around SCK's update
            $0.cropRequested(CGRect(x: 200, y: 80, width: 600, height: 520), at: 1.12)
            $0.cropApplied(at: 1.15)
        }
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 1.2))
        #expect(decorator.recorded.last?.targetFrame == CGRect(x: 350, y: 80, width: 600, height: 520))
        #expect(decorator.recorded.last?.windowFrame == window.offsetBy(dx: 50, dy: -20))
        await writer.cancel()
    }

    // MARK: Review V3 finding 3 — each frame keeps the crop it was presented under

    private static let partWindow = CGRect(x: 100, y: 100, width: 800, height: 600)
    private static let cropA = CGRect(x: 0, y: 80, width: 400, height: 300)
    private static let cropB = CGRect(x: 400, y: 80, width: 400, height: 300)
    private static func global(_ crop: CGRect) -> CGRect { PartCropGeometry.global(crop, in: partWindow) }

    /// A backlog behind a slow composition: an old-crop sample reaches the
    /// writer **after** SCK's update returned, and still gets the old crop's
    /// ink; a sample presented while SCK was switching is held, never drawn
    /// on a guess; the first one after the update gets the new crop.
    @Test func queuedSamplesKeepTheCropTheyWerePresentedUnder() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let decorator = Decorator()
        let clock = Clock(2)
        let writer = try makeWriter(
            take, letterboxes: true, target: .part(window: Self.partWindow, sourceRect: Self.cropA),
            decorator: decorator, clock: clock
        )
        writer.decoration.withLock {
            $0.cropRequested(Self.cropB, at: 2.0)
            $0.cropApplied(at: 2.03)
        }
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 1.9))
        #expect(decorator.recorded.map(\.targetFrame) == [Self.global(Self.cropA)])

        try await settle()
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 2.01))
        #expect(decorator.recorded.count == 1, "presented mid-switch: held")
        #expect(await writer.heldFrames == 1)

        try await settle()
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 2.05))
        #expect(decorator.recorded.map(\.targetFrame) == [Self.global(Self.cropA), Self.global(Self.cropB)])
        #expect(decorator.recorded.last?.windowFrame == Self.partWindow)
        await writer.cancel()
    }

    /// The completion comes late (a busy main actor can't delay it — it is
    /// stamped on SCK's callback — but SCK itself may take a while): a
    /// sample presented meanwhile is held while idle frames repeat the last
    /// frame of the old crop with its own ink; once the update has returned
    /// and nothing newer came (a still window), the held frame is shown
    /// with the new crop.
    @Test func aHeldFrameWaitsForTheCompletionThenShowsTheNewCrop() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let decorator = Decorator()
        let clock = Clock(1.9)
        let writer = try makeWriter(
            take, letterboxes: true, target: .part(window: Self.partWindow, sourceRect: Self.cropA),
            decorator: decorator, clock: clock
        )
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 1.9))
        writer.decoration.withLock { $0.cropRequested(Self.cropB, at: 2.0) }
        try await settle()
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 2.02))
        clock.set(2.06)
        await writer.idleTick()
        try await settle()
        #expect(decorator.recorded.count == 2)
        #expect(decorator.recorded.allSatisfy { $0.targetFrame == Self.global(Self.cropA) }, "the idle frame is the old crop's")

        writer.decoration.withLock { $0.cropApplied(at: 2.07) }
        clock.set(2.08) // inside the grace: a later frame may still come
        await writer.idleTick()
        try await settle()
        #expect(decorator.recorded.last?.targetFrame == Self.global(Self.cropA))

        clock.set(2.07 + 2.5 / 60)
        await writer.idleTick()
        try await settle()
        #expect(decorator.recorded.last?.targetFrame == Self.global(Self.cropB))
        await writer.cancel()
    }

    /// A failed update: SCK kept the old crop, so a frame held during it is
    /// shown with the old crop's ink.
    @Test func aFrameHeldDuringAFailedUpdateKeepsTheOldCrop() async throws {
        let take = try makeTake()
        defer { take.remove() }
        let decorator = Decorator()
        let clock = Clock(2)
        let writer = try makeWriter(
            take, letterboxes: true, target: .part(window: Self.partWindow, sourceRect: Self.cropA),
            decorator: decorator, clock: clock
        )
        writer.decoration.withLock { $0.cropRequested(Self.cropB, at: 2.0) }
        await writer.append(try frame(width: 320, height: 240, red: 9, green: 9, blue: 9, time: 2.01))
        #expect(decorator.recorded.isEmpty)
        writer.decoration.withLock { $0.cropFailed() }
        clock.set(2.05)
        await writer.idleTick() // the held frame starts the take, then an idle frame repeats it
        try await settle()
        #expect(!decorator.recorded.isEmpty)
        #expect(decorator.recorded.allSatisfy { $0.targetFrame == Self.global(Self.cropA) })
        await writer.cancel()
    }
}

@MainActor
@Suite("RecordingPipeline")
struct RecordingPipelineTests {
    @Test func stopWithoutStartThrows() async {
        await #expect(throws: RecordingPipelineError.notStarted) {
            _ = try await RecordingPipeline().stop()
        }
    }

    @Test func aTargetOnAMissingDisplayFailsBeforeAnyCapture() async {
        let pipeline = RecordingPipeline()
        let url = FileManager.default.temporaryDirectory.appending(path: "never-\(UUID().uuidString).mp4")
        let target = RecordingTarget.area(globalRect: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 0xDEAD)
        await #expect(throws: RecordingPipelineError.displayUnavailable) {
            try await pipeline.start(target: target, settings: RecordingSettings(), decorator: NullFrameDecorator(), outputURL: url)
        }
        // The coordinator always stops after start returns or throws.
        await #expect(throws: RecordingPipelineError.notStarted) {
            _ = try await pipeline.stop()
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

/// The compositor without Metal or an encoder: the CoreImage render is
/// injected, the bitmap context is real CPU memory.
@Suite("FrameCompositor")
struct FrameCompositorTests {
    private final class Decorator: FrameDecorating {
        private let calls = OSAllocatedUnfairLock(initialState: [CGRect]())
        var outputRects: [CGRect] { calls.withLock { $0 } }
        func draw(
            in context: CGContext, outputRect: CGRect, targetFrame: CGRect, windowFrame: CGRect?, hostTime: TimeInterval
        ) {
            calls.withLock { $0.append(outputRect) }
        }
    }

    private struct RenderFailed: Error {}

    private func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        return try #require(buffer)
    }

    private func compositor(
        letterboxes: Bool, decorator: Decorator, render: @escaping @Sendable (CIContext, CIImage, CVPixelBuffer) throws -> Void = { _, _, _ in },
        makeContext: (@Sendable (CVPixelBuffer, CGColorSpace) -> CGContext?)? = nil
    ) -> FrameCompositor {
        FrameCompositor(
            videoSize: VideoSize(width: 320, height: 240), letterboxes: letterboxes,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, decorator: decorator,
            seams: FrameCompositor.Seams(render: render, makeContext: makeContext ?? FrameCompositor.Seams.live.makeContext)
        )
    }

    @Test func decoratesEachComposedBufferOnceAtThePlacement() throws {
        let decorator = Decorator()
        let compositor = compositor(letterboxes: true, decorator: decorator)
        let square = CapturedFrame(
            pixelBuffer: try buffer(width: 320, height: 240), contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), time: 1
        )
        try compositor.composite(square, into: try buffer(width: 320, height: 240), target: .area(.zero), hostTime: 1)
        try compositor.composite(square, into: try buffer(width: 320, height: 240), target: .area(.zero), hostTime: 2)
        // The window got wider: a new placement, bars top and bottom.
        let wide = CapturedFrame(
            pixelBuffer: try buffer(width: 320, height: 240), contentRect: CGRect(x: 0, y: 0, width: 320, height: 120), time: 3
        )
        try compositor.composite(wide, into: try buffer(width: 320, height: 240), target: .area(.zero), hostTime: 3)
        #expect(decorator.outputRects == [
            CGRect(x: 40, y: 0, width: 240, height: 240),
            CGRect(x: 40, y: 0, width: 240, height: 240),
            CGRect(x: 0, y: 60, width: 320, height: 120),
        ])
    }

    @Test func anAreaFillsTheWholeFrame() throws {
        let decorator = Decorator()
        let compositor = compositor(letterboxes: false, decorator: decorator)
        let frame = CapturedFrame(pixelBuffer: try buffer(width: 320, height: 240), contentRect: nil, time: 1)
        try compositor.composite(frame, into: try buffer(width: 320, height: 240), target: .area(.zero), hostTime: 1)
        #expect(decorator.outputRects == [CGRect(x: 0, y: 0, width: 320, height: 240)])
    }

    @Test func aRenderFailureThrowsAndSkipsTheInk() throws {
        let decorator = Decorator()
        let compositor = compositor(letterboxes: false, decorator: decorator, render: { _, _, _ in throw RenderFailed() })
        let frame = CapturedFrame(pixelBuffer: try buffer(width: 320, height: 240), contentRect: nil, time: 1)
        #expect(throws: RecordingPipelineError.compositionFailed) {
            try compositor.composite(frame, into: try buffer(width: 320, height: 240), target: .area(.zero), hostTime: 1)
        }
        #expect(decorator.outputRects.isEmpty)
    }

    /// Review round 1 #4: no context → no decorator call → the buffer must not be appended.
    @Test func aMissingDrawingContextThrowsInsteadOfReturningAnUndecoratedBuffer() throws {
        let decorator = Decorator()
        let compositor = compositor(letterboxes: false, decorator: decorator, makeContext: { _, _ in nil })
        let frame = CapturedFrame(pixelBuffer: try buffer(width: 320, height: 240), contentRect: nil, time: 1)
        #expect(throws: RecordingPipelineError.compositionFailed) {
            try compositor.composite(frame, into: try buffer(width: 320, height: 240), target: .area(.zero), hostTime: 1)
        }
        #expect(decorator.outputRects.isEmpty)
    }
}

@Suite("PipelineFailureGate")
struct PipelineFailureGateTests {
    private func delivered(_ delivery: PipelineFailureGate<Int>.Delivery) -> Int? {
        if case .deliver(let value) = delivery { return value }
        return nil
    }

    private func isHeld(_ delivery: PipelineFailureGate<Int>.Delivery) -> Bool {
        if case .held = delivery { return true }
        return false
    }

    private func isDropped(_ delivery: PipelineFailureGate<Int>.Delivery) -> Bool {
        if case .dropped = delivery { return true }
        return false
    }

    /// Review round 1 #2: a failure while start is awaiting the stream is thrown by start.
    @Test func aFailureDuringStartIsHeldAndThrownByStart() {
        var gate = PipelineFailureGate<Int>()
        #expect(isHeld(gate.report(1)))
        #expect(isDropped(gate.report(2))) // the first one wins
        #expect(gate.startDidComplete() == 1)
        #expect(gate.phase == .ended)
        #expect(isDropped(gate.report(3)))
    }

    @Test func afterACleanStartTheFirstFailureIsDeliveredOnce() {
        var gate = PipelineFailureGate<Int>()
        #expect(gate.startDidComplete() == nil)
        #expect(gate.phase == .running)
        #expect(delivered(gate.report(7)) == 7)
        #expect(isDropped(gate.report(8)))
    }

    @Test func nothingIsReportedAfterTheEnd() {
        var gate = PipelineFailureGate<Int>()
        gate.end() // start threw
        #expect(isDropped(gate.report(1)))
        #expect(gate.startDidComplete() == nil)

        var running = PipelineFailureGate<Int>()
        _ = running.startDidComplete()
        running.end() // stop()
        #expect(isDropped(running.report(1)))
    }
}

@MainActor
@Suite("Snappy exclusion")
struct SnappyExclusionTests {
    /// A fake shareable-content fetch: answers per `preferCached`, records calls.
    private final class Fetcher {
        var cached: Bool
        var fresh: Bool
        var calls: [Bool] = []
        init(cachedListsSnappy: Bool, freshListsSnappy: Bool) {
            cached = cachedListsSnappy
            fresh = freshListsSnappy
        }
        func fetch(_ preferCached: Bool) -> Bool {
            calls.append(preferCached)
            return preferCached ? cached : fresh
        }
    }

    @Test func theCachedContentIsUsedWhenItListsSnappy() async throws {
        let fetcher = Fetcher(cachedListsSnappy: true, freshListsSnappy: true)
        let content = try await RecordingPipeline.contentListingSnappy(fetch: { fetcher.fetch($0) }, listsSnappy: { $0 })
        #expect(content && fetcher.calls == [true])
    }

    @Test func aMissingSnappyIsRefetchedFreshOnce() async throws {
        let fetcher = Fetcher(cachedListsSnappy: false, freshListsSnappy: true)
        let content = try await RecordingPipeline.contentListingSnappy(fetch: { fetcher.fetch($0) }, listsSnappy: { $0 })
        #expect(content && fetcher.calls == [true, false])
    }

    /// Review round 1 #1: no window-list fallback — a readable error instead.
    @Test func stillMissingFailsWithAReadableError() async {
        let fetcher = Fetcher(cachedListsSnappy: false, freshListsSnappy: false)
        await #expect(throws: RecordingPipelineError.snappyNotListed) {
            _ = try await RecordingPipeline.contentListingSnappy(fetch: { fetcher.fetch($0) }, listsSnappy: { $0 })
        }
        #expect(fetcher.calls == [true, false])
    }

    @Test func aPermissionDenialPassesThrough() async {
        await #expect(throws: CaptureError.self) {
            _ = try await RecordingPipeline.contentListingSnappy(
                fetch: { _ -> Bool in throw CaptureError.permissionDenied }, listsSnappy: { $0 }
            )
        }
    }
}

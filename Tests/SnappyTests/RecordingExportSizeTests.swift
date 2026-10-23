import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import Snappy

@Suite struct ExportScaleTests {
    @Test func stopsRunFromAQuarterToFull() {
        #expect(ExportScale.allCases == [.quarter, .half, .threeQuarters, .full])
        #expect(ExportScale.allCases.map(\.percent) == [25, 50, 75, 100])
        #expect(ExportScale.allCases.map(\.index) == [0, 1, 2, 3])
        #expect(ExportScale.half.title == "50 %")
        #expect(ExportScale.quarter < .full)
    }

    @Test func steppingStaysWithinTheStops() {
        #expect(ExportScale.full.stepped(by: -1) == .threeQuarters)
        #expect(ExportScale.half.stepped(by: 1) == .threeQuarters)
        #expect(ExportScale.quarter.stepped(by: -1) == .quarter)
        #expect(ExportScale.full.stepped(by: 1) == .full)
        #expect(ExportScale(index: -4) == .quarter)
        #expect(ExportScale(index: 9) == .full)
    }
}

@Suite struct ExportSizingTests {
    @Test func scalesEachSideToTheNearestEvenPixel() {
        let hd = VideoSize(width: 1280, height: 720)
        #expect(ExportSizing.videoSize(source: hd, scale: .threeQuarters) == VideoSize(width: 960, height: 540))
        #expect(ExportSizing.videoSize(source: hd, scale: .half) == VideoSize(width: 640, height: 360))
        #expect(ExportSizing.videoSize(source: hd, scale: .quarter) == VideoSize(width: 320, height: 180))
        // 1366 × 0.75 = 1024.5 → 1024; 602 × 0.25 = 150.5 → 150; 1002 × 0.25 = 250.5 → 250.
        #expect(ExportSizing.videoSize(source: VideoSize(width: 1366, height: 768), scale: .threeQuarters)
            == VideoSize(width: 1024, height: 576))
        #expect(ExportSizing.videoSize(source: VideoSize(width: 1002, height: 602), scale: .quarter)
            == VideoSize(width: 250, height: 150))
        // 1030 × 0.25 = 257.5 → the nearest even side, 258.
        #expect(ExportSizing.videoSize(source: VideoSize(width: 1030, height: 6), scale: .quarter)
            == VideoSize(width: 258, height: 2))
        #expect(ExportSizing.videoSize(source: VideoSize(width: 2, height: 2), scale: .quarter)
            == VideoSize(width: 2, height: 2))
    }

    @Test func fullKeepsTheTakesSizeExactly() {
        let odd = VideoSize(width: 1283, height: 721)
        #expect(ExportSizing.videoSize(source: odd, scale: .full) == odd)
    }

    @Test func everyReducedSideIsEven() {
        for width in stride(from: 2, through: 600, by: 2) {
            for scale in ExportScale.allCases {
                let size = ExportSizing.videoSize(source: VideoSize(width: width, height: width + 2), scale: scale)
                #expect(size.width % 2 == 0 && size.height % 2 == 0 && size.width >= 2)
            }
        }
    }

    @Test func theEstimateBoundsTheTargetBitrateWithHeadroomAndTheContainer() {
        // 640 × 360 × 60 fps × 0.1 bpp = 1 382 400 bit/s → 10 s = 1 728 000
        // bytes at the target; × 1.5 headroom + 4096 + 600 frames × 16.
        let size = VideoSize(width: 640, height: 360)
        #expect(ExportSizing.estimatedBytes(videoSize: size, framesPerSecond: 60, quality: .high, duration: 10)
            == 2_592_000 + 4096 + 9600)
        // Small frames hit the 1 Mbit/s floor, as recording does.
        #expect(ExportSizing.estimatedBytes(
            videoSize: VideoSize(width: 320, height: 180), framesPerSecond: 30, quality: .standard, duration: 10
        ) == 1_875_000 + 4096 + 4800)
        // A take shorter than the rate window still budgets a whole one: its
        // first key frame costs the same for one frame or thirty.
        let oneFrame = ExportSizing.estimatedBytes(
            videoSize: VideoSize(width: 160, height: 120), framesPerSecond: 30, quality: .high, duration: 1.0 / 30
        )
        #expect(oneFrame == 187_500 + 4096 + 16)
        #expect(ExportSizing.estimatedBytes(videoSize: size, framesPerSecond: 60, quality: .high, duration: 0) == 0)
        #expect(ExportSizing.estimatedBytes(videoSize: size, framesPerSecond: 60, quality: .high, duration: .nan) == 0)
    }

    @Test func theFrameRateSnapsToARecordingRate() {
        #expect(ExportSizing.framesPerSecond(nominal: 59.7) == 60)
        #expect(ExportSizing.framesPerSecond(nominal: 29.9) == 30)
        #expect(ExportSizing.framesPerSecond(nominal: 44) == 30)
        #expect(ExportSizing.framesPerSecond(nominal: 0) == 60)
        #expect(ExportSizing.framesPerSecond(nominal: .nan) == 60)
    }

    @Test func pixelSizesBecomeEvenVideoSizes() {
        #expect(ExportSizing.videoSize(pixels: CGSize(width: 1280, height: 720)) == VideoSize(width: 1280, height: 720))
        #expect(ExportSizing.videoSize(pixels: CGSize(width: 641, height: 361)) == VideoSize(width: 640, height: 360))
        #expect(ExportSizing.videoSize(pixels: nil) == nil)
        #expect(ExportSizing.videoSize(pixels: CGSize(width: 1, height: 400)) == nil)
    }
}

@Suite struct ExportSizeTextTests {
    @Test func bytesReadLikeFinder() {
        #expect(ExportSizeText.bytes(18_400_000) == "18.4 MB")
        #expect(ExportSizeText.bytes(1_000_000) == "1.0 MB")
        #expect(ExportSizeText.bytes(512_000) == "512 KB")
        #expect(ExportSizeText.bytes(999) == "1 KB")
        #expect(ExportSizeText.bytes(150_400_000) == "150 MB")
        #expect(ExportSizeText.bytes(2_500_000_000) == "2.5 GB")
    }

    @Test func boundariesPromoteOnTheRoundedValue() {
        #expect(ExportSizeText.bytes(999_499) == "1.0 MB")
        #expect(ExportSizeText.bytes(999_999) == "1.0 MB")
        #expect(ExportSizeText.bytes(998_999) == "999 KB")
        #expect(ExportSizeText.bytes(99_949_999) == "99.9 MB")
        #expect(ExportSizeText.bytes(99_950_000) == "100 MB")
        #expect(ExportSizeText.bytes(99_999_999) == "100 MB")
        #expect(ExportSizeText.bytes(999_499_999) == "999 MB")
        #expect(ExportSizeText.bytes(999_500_000) == "1.0 GB")
        #expect(ExportSizeText.bytes(999_999_999) == "1.0 GB")
        #expect(ExportSizeText.bytes(99_999_999_999) == "100 GB")
        #expect(ExportSizeText.bytes(5_000_000_000_000) == "5000 GB")
        // Bounds promote too, and never read below the bytes.
        #expect(ExportSizeText.bytes(99_900_001, roundingUp: true) == "100 MB")
        #expect(ExportSizeText.bytes(999_000_001, roundingUp: true) == "1.0 GB")
        #expect(ExportSizeText.bytes(999_001, roundingUp: true) == "1.0 MB")
    }

    @Test func aBoundNeverReadsBelowItsBytes() {
        #expect(ExportSizeText.bytes(18_400_000, roundingUp: true) == "18.4 MB")
        #expect(ExportSizeText.bytes(18_400_001, roundingUp: true) == "18.5 MB")
        #expect(ExportSizeText.bytes(18_449_999) == "18.4 MB")
        #expect(ExportSizeText.bytes(150_000_001, roundingUp: true) == "151 MB")
        #expect(ExportSizeText.bytes(2_500_000_001, roundingUp: true) == "2.6 GB")
        #expect(ExportSizeText.size(actual: nil, estimate: 18_449_999) == "≤ 18.5 MB")
    }

    @Test func theRealSizeWinsOverTheEstimate() {
        #expect(ExportSizeText.size(actual: 18_400_000, estimate: 30_000_000) == "18.4 MB")
        #expect(ExportSizeText.size(actual: nil, estimate: 4_600_000) == "≤ 4.6 MB")
        #expect(ExportSizeText.size(actual: nil, estimate: nil) == "")
        #expect(ExportSizeText.size(actual: nil, estimate: 0) == "")
    }

    @Test func dimensionsAndTheDurationRoundedToTheSecond() {
        let size = VideoSize(width: 1280, height: 720)
        #expect(ExportSizeText.dimensionsAndDuration(videoSize: size, duration: 41.6) == "1280 × 720 · 0:42")
        #expect(ExportSizeText.dimensionsAndDuration(videoSize: size, duration: 0.2) == "1280 × 720 · 0:00")
        #expect(ExportSizeText.dimensionsAndDuration(videoSize: size, duration: 3723) == "1280 × 720 · 1:02:03")
        #expect(ExportSizeText.dimensionsAndDuration(videoSize: size, duration: nil) == "1280 × 720")
        #expect(ExportSizeText.dimensionsAndDuration(videoSize: size, duration: .nan) == "1280 × 720")
        #expect(ExportSizeText.dimensionsAndDuration(videoSize: nil, duration: 5) == "0:05")
        #expect(ExportSizeText.dimensionsAndDuration(videoSize: nil, duration: nil) == "")
    }

    @Test func progressIsAWholePercentage() {
        #expect(ExportSizeText.progress(0.429) == "42 %")
        #expect(ExportSizeText.progress(1.5) == "100 %")
        #expect(ExportSizeText.progress(-1) == "0 %")
        #expect(ExportSizeText.progress(.nan) == "0 %")
        #expect(ExportSizeText.cancelToolTip.hasSuffix(" (Esc)"))
    }
}

@Suite struct RecordingExportSourceTests {
    private let saved = URL(filePath: "/tmp/Recording saved.mp4")
    private let encoded = URL(filePath: "/tmp/Export-50.mp4")

    @Test func saveExportsTheTakeAtFullAndAReEncodeOtherwise() {
        #expect(RecordingExportSource.forSave(scale: .full, encoded: nil) == .take)
        #expect(RecordingExportSource.forSave(scale: .full, encoded: encoded) == .take)
        #expect(RecordingExportSource.forSave(scale: .half, encoded: nil) == .needsEncode)
        #expect(RecordingExportSource.forSave(scale: .half, encoded: encoded) == .encoded(encoded))
    }

    @Test func copyReusesAFileSavedAtTheSameStopOnly() {
        // The caller passes the file saved at *this* stop (nil when it was
        // saved at another one).
        #expect(RecordingExportSource.forCopy(scale: .half, saved: saved, encoded: encoded) == .saved(saved))
        #expect(RecordingExportSource.forCopy(scale: .full, saved: saved, encoded: nil) == .saved(saved))
        #expect(RecordingExportSource.forCopy(scale: .full, saved: nil, encoded: nil) == .take)
        #expect(RecordingExportSource.forCopy(scale: .half, saved: nil, encoded: encoded) == .encoded(encoded))
        #expect(RecordingExportSource.forCopy(scale: .quarter, saved: nil, encoded: nil) == .needsEncode)
    }

    @Test @MainActor func savedFilesAreKeptPerStop() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SnappySavedPerStop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = folder.appending(path: "take.mp4"), half = folder.appending(path: "half.mp4")
        try Data("t".utf8).write(to: take)
        try Data("h".utf8).write(to: half)

        let files = RecordingSavedFiles()
        files.record(half, for: take, scale: .half)
        #expect(files.savedFile(for: take, scale: .half) == half)
        #expect(files.savedFile(for: take) == nil, "a 50 % file is never Copy's 100 % file")
        #expect(files.savedFile(for: take, scale: .quarter) == nil)
    }

    @Test @MainActor func theCacheKeepsOnlyTheLatestReEncode() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SnappyExportCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RecordingExportCache(root: root)
        let first = try cache.prepare(.half)
        try Data("1".utf8).write(to: first)
        cache.store(first, scale: .half)
        #expect(cache.file(at: .half) == first)
        #expect(cache.file(at: .quarter) == nil)

        let second = try cache.prepare(.quarter)
        #expect(second != first)
        try Data("2".utf8).write(to: second)
        cache.store(second, scale: .quarter)
        #expect(cache.file(at: .quarter) == second)
        #expect(cache.file(at: .half) == nil)
        #expect(!FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))

        cache.discard()
        #expect(cache.file(at: .quarter) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path(percentEncoded: false)))
    }
}

/// Real encodes of a small synthetic take.
@Suite struct RecordingTranscoderTests {
    /// `noise`: random pixels — the costliest content to encode. The session
    /// ends one frame after the last, as the recording pipeline's does.
    static func makeTake(width: Int = 320, height: Int = 240, frames: Int = 30, noise: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SnappyTranscodeTake-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: OutputGeometry.videoSettings(
            videoSize: VideoSize(width: width, height: height), framesPerSecond: 30, quality: .high, profile: .sRGB
        ))
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                if noise {
                    arc4random_buf(base, CVPixelBufferGetDataSize(pixels))
                } else {
                    memset(base, Int32(frame * 8 % 255), CVPixelBufferGetDataSize(pixels))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private static func digest(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }

    @Test func aHalfSizeExportHalvesEachSideAndLeavesTheTakeUntouched() async throws {
        let take = try await Self.makeTake()
        let output = take.deletingLastPathComponent().appending(path: "SnappyTranscodeOut-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: take)
            try? FileManager.default.removeItem(at: output)
        }
        let before = try Self.digest(take)
        let progress = ProgressLog()
        let result = try await RecordingTranscoder.encode(take, to: output, scale: .half, quality: .high) {
            progress.append($0)
        }
        #expect(result == output)
        #expect(try Self.digest(take) == before, "the take is never modified")

        let info = await RecordingWindowController.videoInfo(of: output)
        #expect(info.size == CGSize(width: 160, height: 120))
        #expect(abs((info.duration ?? 0) - 1) < 0.1)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        #expect(tracks.isEmpty)
        #expect(progress.values.last == 1)
        #expect(progress.values == progress.values.sorted())
    }

    /// Review R2: noise at 320 × 240 → 50 % overshot the old "≤" (target ×
    /// duration) — 161 KB for "≤ 125 KB", 24.6 KB for one frame's "≤ 5 KB".
    @Test(arguments: [1, 2, 30])
    func aDetailedReEncodeNeverExceedsTheBoundTheCapsuleShows(frames: Int) async throws {
        let take = try await Self.makeTake(frames: frames, noise: true)
        let output = take.deletingLastPathComponent().appending(path: "SnappyTranscodeOut-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: take)
            try? FileManager.default.removeItem(at: output)
        }
        // The capsule's own inputs (`RecordingWindowController.refreshStatus`).
        let info = await RecordingWindowController.videoInfo(of: take)
        let source = try #require(ExportSizing.videoSize(pixels: info.size))
        let bound = ExportSizing.estimatedBytes(
            videoSize: ExportSizing.videoSize(source: source, scale: .half),
            framesPerSecond: ExportSizing.framesPerSecond(nominal: info.framesPerSecond ?? 0),
            quality: .high, duration: try #require(info.duration)
        )
        _ = try await RecordingTranscoder.encode(take, to: output, scale: .half, quality: .high)
        let bytes = Int64(try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        #expect(bytes <= bound, "\(bytes) bytes for \(ExportSizeText.size(actual: nil, estimate: bound))")
    }

    @Test func anEncodeThatCannotFitTheBoundFailsAndLeavesNoOutput() async throws {
        let take = try await Self.makeTake(frames: 10, noise: true)
        let output = take.deletingLastPathComponent().appending(path: "SnappyTranscodeOut-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: take)
            try? FileManager.default.removeItem(at: output)
        }
        await #expect(throws: RecordingTranscoder.Failure.tooLarge) {
            try await RecordingTranscoder.encode(take, to: output, scale: .half, quality: .high, byteLimit: 1000)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }

    /// Review R3: a one-frame take came back twice as long (1/30 s → 2/30 s).
    @Test(arguments: [1, 2, 7])
    func aReEncodeKeepsTheTakesExactDuration(frames: Int) async throws {
        let take = try await Self.makeTake(frames: frames)
        let output = take.deletingLastPathComponent().appending(path: "SnappyTranscodeOut-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: take)
            try? FileManager.default.removeItem(at: output)
        }
        _ = try await RecordingTranscoder.encode(take, to: output, scale: .half, quality: .high)
        let before = try await AVURLAsset(url: take).load(.duration)
        let after = try await AVURLAsset(url: output).load(.duration)
        #expect(abs(CMTimeGetSeconds(after) - CMTimeGetSeconds(before)) < 1e-6)
        #expect(abs(CMTimeGetSeconds(after) - Double(frames) / 30) < 1e-6)
    }

    @Test func aFileWithoutVideoFailsAndLeavesNoOutput() async throws {
        let take = FileManager.default.temporaryDirectory.appending(path: "SnappyNotAVideo-\(UUID().uuidString).mp4")
        let output = take.deletingLastPathComponent().appending(path: "SnappyTranscodeOut-\(UUID().uuidString).mp4")
        try Data("not really a video".utf8).write(to: take)
        defer { try? FileManager.default.removeItem(at: take) }
        await #expect(throws: (any Error).self) {
            try await RecordingTranscoder.encode(take, to: output, scale: .half, quality: .high)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }

    @Test func cancellingStopsTheEncodeAndRemovesThePartialFile() async throws {
        let take = try await Self.makeTake(frames: 240)
        let output = take.deletingLastPathComponent().appending(path: "SnappyTranscodeOut-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: take)
            try? FileManager.default.removeItem(at: output)
        }
        let job = Task.detached {
            try await RecordingTranscoder.encode(take, to: output, scale: .quarter, quality: .high)
        }
        job.cancel()
        let result = await job.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }
}

/// Progress values from the encoding task, read after it finished.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

/// The recording window's export size, end to end on a real take.
@MainActor
@Suite struct RecordingWindowExportSizeTests {
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeWindow(take: URL, settings: SettingsStore, savedFiles: RecordingSavedFiles) -> RecordingWindowController {
        RecordingWindowController(
            take: take, anchorRect: CGRect(x: 0, y: 0, width: 320, height: 240), onRetake: nil,
            context: RecordingWindowContext(savedFiles: savedFiles, mayTakeFocus: { true }),
            settings: settings, focus: RecordingWindowFocus(activate: {}, isActive: { true })
        )
    }

    private func withStore(_ body: (SettingsStore, URL) async throws -> Void) async throws {
        let suite = "SnappyTests.ExportSize.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appending(path: "SnappyExportSize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let settings = SettingsStore(defaults: defaults)
        settings.saveDirectory = folder
        try await body(settings, folder)
    }

    @Test func aWindowOpensAtTheDefaultAndItsSliderNeverWritesBack() async throws {
        try await withStore { settings, _ in
            settings.recordingExportScale = .threeQuarters
            let take = try await RecordingTranscoderTests.makeTake()
            defer { try? FileManager.default.removeItem(at: take) }
            let window = makeWindow(take: take, settings: settings, savedFiles: RecordingSavedFiles())
            defer { window.close() }
            window.show()
            #expect(window.exportScale == .threeQuarters)
            await settle { !window.statusInfoText.isEmpty }
            #expect(window.statusInfoText == "240 × 180 · 0:01")
            #expect(window.statusSizeText.hasPrefix("≤ "))

            window.perform(.smallerExport)
            window.perform(.smallerExport)
            window.perform(.smallerExport) // stays at 25 %
            #expect(window.exportScale == .quarter)
            #expect(window.statusInfoText == "80 × 60 · 0:01")
            window.perform(.largerExport)
            #expect(window.exportScale == .half)
            #expect(settings.recordingExportScale == .threeQuarters, "a per-take override")
        }
    }

    @Test func saveAtHalfReEncodesThenCopyReusesThatFileOnlyAtTheSameStop() async throws {
        try await withStore { settings, folder in
            let take = try await RecordingTranscoderTests.makeTake()
            defer { try? FileManager.default.removeItem(at: take) }
            let before = SHA256.hash(data: try Data(contentsOf: take))
            let savedFiles = RecordingSavedFiles()
            let window = makeWindow(take: take, settings: settings, savedFiles: savedFiles)
            defer { window.close() }
            window.show()
            #expect(window.exportScale == .full)
            window.perform(.smallerExport)
            window.perform(.smallerExport)
            #expect(window.exportScale == .half)

            window.perform(.save)
            #expect(window.isEncoding)
            await settle { savedFiles.savedFile(for: take, scale: .half) != nil }
            let saved = try #require(savedFiles.savedFile(for: take, scale: .half))
            #expect(saved.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
            #expect(saved.lastPathComponent.hasPrefix("Recording "))
            #expect(await RecordingWindowController.videoInfo(of: saved).size == CGSize(width: 160, height: 120))
            #expect(SHA256.hash(data: try Data(contentsOf: take)) == before, "the take is never modified")
            #expect(window.statusSizeText == ExportSizeText.bytes(
                Int64(try #require(saved.resourceValues(forKeys: [.fileSizeKey]).fileSize))
            ), "the real size replaces the estimate")

            #expect(try window.fileToCopy() == saved, "Copy at the same stop reuses the saved file")
            window.perform(.largerExport)
            #expect(window.exportScale == .threeQuarters)
            #expect(throws: (any Error).self, "another stop needs its own re-encode") { try window.fileToCopy() }
            window.perform(.largerExport)
            let full = try window.fileToCopy()
            #expect(full != saved)
            #expect(SHA256.hash(data: try Data(contentsOf: full)) == before, "100 % is the take, bit-identical")
        }
    }

    @Test func escDuringAReEncodeCancelsOnlyTheReEncode() async throws {
        try await withStore { settings, folder in
            let take = try await RecordingTranscoderTests.makeTake(frames: 600)
            defer { try? FileManager.default.removeItem(at: take) }
            let savedFiles = RecordingSavedFiles()
            let window = makeWindow(take: take, settings: settings, savedFiles: savedFiles)
            defer { window.close() }
            window.show()
            window.perform(.smallerExport)
            window.perform(.save)
            #expect(window.isEncoding)
            window.perform(.close)
            #expect(!window.isEncoding)
            #expect(window.isOpen, "Esc cancels the export, not the window")
            try? await Task.sleep(for: .milliseconds(200))
            #expect(savedFiles.savedFile(for: take, scale: .threeQuarters) == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
            window.perform(.close)
            #expect(!window.isOpen)
        }
    }

    /// Review R1: four-digit sides, a long take and "Export failed" could run
    /// past both edges — at the 440 pt minimum, and narrower than the
    /// content (320 pt stands in for a larger text size).
    @Test func theCapsuleStaysReadableAtTheMinimumWindowWidth() async throws {
        try await withStore { settings, _ in
            let take = try await RecordingTranscoderTests.makeTake()
            defer { try? FileManager.default.removeItem(at: take) }
            let window = makeWindow(take: take, settings: settings, savedFiles: RecordingSavedFiles())
            defer { window.close() }
            window.show()
            await settle { !window.statusInfoText.isEmpty }
            let long = RecordingVideoInfo(size: CGSize(width: 4096, height: 4096), duration: 3723, framesPerSecond: 60)
            for (failed, width) in [(false, RecordingWindowLayout.minWindowSize.width), (true, 440), (true, 320)] {
                window.showStatusForTesting(long, failed: failed)
                window.resizeForTesting(width: width)
                let narrow = window.statusLabelsFitForTesting()
                let size = failed ? ExportSizeText.failure : window.statusSizeText
                let scale = window.exportScaleTitleForTesting
                let clipped = narrow.filter { !$0.fits }.map(\.text)
                #expect(clipped.isEmpty, "clipped: \(clipped)")
                #expect(narrow.map(\.text).contains(size), "the size always stays")
                #expect(narrow.map(\.text).contains(scale), "the stop always stays")

                window.resizeForTesting(width: 900)
                let wide = window.statusLabelsFitForTesting()
                let clippedWide = wide.filter { !$0.fits }.map(\.text)
                #expect(clippedWide.isEmpty, "clipped: \(clippedWide)")
                let info = window.statusInfoText
                #expect(wide.map(\.text).contains(info), "room again: the readout is back")
            }
        }
    }

    @Test func aFailedReEncodeExportsNothingAndSaysSoInline() async throws {
        try await withStore { settings, folder in
            let take = FileManager.default.temporaryDirectory.appending(path: "SnappyBrokenTake-\(UUID().uuidString).mp4")
            try Data("not really a video".utf8).write(to: take)
            defer { try? FileManager.default.removeItem(at: take) }
            let savedFiles = RecordingSavedFiles()
            let window = makeWindow(take: take, settings: settings, savedFiles: savedFiles)
            defer { window.close() }
            window.show()
            window.perform(.smallerExport)
            window.perform(.save)
            await settle { !window.isEncoding }
            #expect(window.statusSizeText == ExportSizeText.failure)
            #expect(savedFiles.savedFile(for: take, scale: .threeQuarters) == nil)
            #expect(savedFiles.savedFile(for: take) == nil, "never falls back to the full-size take")
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
            window.perform(.smallerExport)
            #expect(window.statusSizeText != ExportSizeText.failure, "a new stop clears the message")
        }
    }
}

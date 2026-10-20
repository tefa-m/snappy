import AVFoundation
import CoreMedia
import VideoToolbox

/// Re-encodes a take at a smaller export size (`ExportScale`) into a separate
/// file — the take itself is only read, never touched. AVAssetReader decodes
/// the frames, AVAssetWriter scales them (`AVVideoScalingModeKey`) and
/// encodes H.264 with the recording's own settings (`OutputGeometry
/// .videoSettings`: the bits-per-pixel bitrate for the new size, the take's
/// frame rate, its colour tags). No audio — takes have none. The file never
/// exceeds the "≤" bound the capsule shows (`ExportSizing.estimatedBytes`):
/// every one-second window is capped at the target rate, and an encode that
/// still lands over the bound is redone leaner — or fails (`.tooLarge`),
/// never kept. Nonisolated so it runs off the main actor; cancelling the
/// calling task stops it and removes the partial file.
enum RecordingTranscoder {
    enum Failure: Error, Equatable {
        case noVideoTrack
        case noFrames
        case readFailed
        case writeFailed
        /// Even the leanest attempt stayed over the size bound.
        case tooLarge
    }

    /// Encodes after the first that may still land over the bound, each at
    /// a lower target rate.
    static let leanerAttempts = 2

    /// Writes `take` at `scale` to `output` (replaced if present) and returns
    /// it. `progress` gets 0…1 in whole-percent steps, from the encoding task
    /// (never backwards, should a leaner attempt follow). `byteLimit`
    /// overrides the bound — tests only.
    static func encode(
        _ take: URL, to output: URL, scale: ExportScale, quality: RecordingQuality,
        byteLimit: Int64? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let asset = AVURLAsset(url: take)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let (naturalSize, nominalRate, formats, timeRange) = try await track.load(
            .naturalSize, .nominalFrameRate, .formatDescriptions, .timeRange
        )
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard let source = ExportSizing.videoSize(pixels: naturalSize) else { throw Failure.noVideoTrack }

        let size = ExportSizing.videoSize(source: source, scale: scale)
        let framesPerSecond = ExportSizing.framesPerSecond(nominal: Double(nominalRate))
        let limit = byteLimit ?? ExportSizing.estimatedBytes(
            videoSize: size, framesPerSecond: framesPerSecond, quality: quality, duration: duration
        )
        let settings = OutputGeometry.videoSettings(
            videoSize: size, framesPerSecond: framesPerSecond, quality: quality,
            profile: colorProfile(of: formats.first)
        )
        var bitrate = OutputGeometry.bitrate(quality: quality, videoSize: size, framesPerSecond: framesPerSecond)
        let pass = Pass(
            asset: asset, track: track, output: output, duration: duration,
            // The take's own end, so a lone (or held) last frame keeps its
            // length rather than the encoder's guess.
            end: timeRange.isValid && timeRange.duration > .zero ? timeRange.end : nil,
            progress: Progress(progress)
        )
        for attempt in 0...leanerAttempts {
            let written = try await pass.write(settings: Self.settings(settings, bitrate: bitrate))
            if written <= limit { return output }
            try? FileManager.default.removeItem(at: output)
            guard attempt < leanerAttempts else { break }
            // Aim the next attempt under the bound by the measured overshoot.
            bitrate = max(1, Int(Double(bitrate) * Double(limit) / Double(written) * 0.8))
        }
        throw Failure.tooLarge
    }

    /// `base` at `bitrate`, with every rate window capped at that rate.
    private static func settings(_ base: [String: Any], bitrate: Int) -> [String: Any] {
        var settings = base
        var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        compression[AVVideoAverageBitRateKey] = bitrate
        compression[kVTCompressionPropertyKey_DataRateLimits as String] = [
            Double(bitrate) / 8 * ExportSizing.rateWindow, ExportSizing.rateWindow,
        ]
        settings[AVVideoCompressionPropertiesKey] = compression
        // The decoded frames keep the take's size; the writer scales them.
        settings[AVVideoScalingModeKey] = AVVideoScalingModeResize
        return settings
    }

    /// Whole-percent progress that never goes backwards across attempts.
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var reported = -1
        private let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func update(_ fraction: Double) {
            let percent = Int(min(1, max(0, fraction)) * 100)
            let isNew = lock.withLock {
                guard percent > reported else { return false }
                reported = percent
                return true
            }
            if isNew { report(Double(percent) / 100) }
        }
    }

    /// One read → scale → encode pass over the take.
    private struct Pass {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let output: URL
        let duration: TimeInterval
        let end: CMTime?
        let progress: Progress

        /// Writes the file and returns its size in bytes.
        func write(settings: [String: Any]) async throws -> Int64 {
            try? FileManager.default.removeItem(at: output)
            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else { throw Failure.readFailed }
            reader.add(readerOutput)

            let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Failure.writeFailed }
            writer.add(input)

            do {
                guard reader.startReading() else { throw Failure.readFailed }
                guard writer.startWriting() else { throw Failure.writeFailed }
                var start: CMTime?
                while let sample = readerOutput.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    if start == nil {
                        writer.startSession(atSourceTime: time)
                        start = time
                    }
                    while !input.isReadyForMoreMediaData {
                        guard writer.status == .writing else { throw Failure.writeFailed }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    guard input.append(sample) else { throw Failure.writeFailed }
                    if let start, duration > 0 { progress.update(CMTimeGetSeconds(time - start) / duration) }
                }
                try Task.checkCancellation()
                guard reader.status == .completed else { throw Failure.readFailed }
                guard let start else { throw Failure.noFrames }
                input.markAsFinished()
                if let end, end > start { writer.endSession(atSourceTime: end) }
                await writer.finishWriting()
                guard writer.status == .completed else { throw Failure.writeFailed }
                try Task.checkCancellation()
                let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                progress.update(1)
                return Int64(bytes)
            } catch {
                reader.cancelReading()
                if writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
    }

    /// The take's colour tags as recorded (`VideoColorProfile`): Display P3
    /// primaries stay P3, anything else is tagged sRGB / Rec. 709.
    private static func colorProfile(of format: CMFormatDescription?) -> VideoColorProfile {
        guard let format,
              let primaries = CMFormatDescriptionGetExtension(
                  format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
              ) as? String
        else { return .sRGB }
        return VideoColorProfile(wideGamut: primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String))
    }
}

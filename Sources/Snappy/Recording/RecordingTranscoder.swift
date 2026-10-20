import AVFoundation
import CoreMedia

/// Re-encodes a take at a smaller export size (`ExportScale`) into a separate
/// file — the take itself is only read, never touched. AVAssetReader decodes
/// the frames, AVAssetWriter scales them (`AVVideoScalingModeKey`) and
/// encodes H.264 with the recording's own settings (`OutputGeometry
/// .videoSettings`: the bits-per-pixel bitrate for the new size, the take's
/// frame rate, its colour tags). No audio — takes have none. Nonisolated so
/// it runs off the main actor; cancelling the calling task stops it and
/// removes the partial file.
enum RecordingTranscoder {
    enum Failure: Error, Equatable {
        case noVideoTrack
        case noFrames
        case readFailed
        case writeFailed
    }

    /// Writes `take` at `scale` to `output` (replaced if present) and returns
    /// it. `progress` gets 0…1 in whole-percent steps, from the encoding task.
    static func encode(
        _ take: URL, to output: URL, scale: ExportScale, quality: RecordingQuality,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let asset = AVURLAsset(url: take)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let (naturalSize, nominalRate, formats) = try await track.load(
            .naturalSize, .nominalFrameRate, .formatDescriptions
        )
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard let source = ExportSizing.videoSize(pixels: naturalSize) else { throw Failure.noVideoTrack }

        let size = ExportSizing.videoSize(source: source, scale: scale)
        let framesPerSecond = ExportSizing.framesPerSecond(nominal: Double(nominalRate))
        var settings = OutputGeometry.videoSettings(
            videoSize: size, framesPerSecond: framesPerSecond, quality: quality,
            profile: colorProfile(of: formats.first)
        )
        // The decoded frames keep the take's size; the writer scales them.
        settings[AVVideoScalingModeKey] = AVVideoScalingModeResize

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
            var reported = -1
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
                if let start, duration > 0 {
                    let percent = Int(min(1, max(0, CMTimeGetSeconds(time - start) / duration)) * 100)
                    if percent > reported {
                        reported = percent
                        progress(Double(percent) / 100)
                    }
                }
            }
            try Task.checkCancellation()
            guard reader.status == .completed else { throw Failure.readFailed }
            guard start != nil else { throw Failure.noFrames }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw Failure.writeFailed }
            progress(1)
            return output
        } catch {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: output)
            throw error
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

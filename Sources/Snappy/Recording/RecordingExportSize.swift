import Foundation

/// The recording window's export size (a stop on the status capsule's
/// slider) — a **resolution scale only**: the frame rate stays, the bitrate
/// follows `OutputGeometry.bitrate` for the smaller frame. PURE, tested.
/// Settings → Recording › Default export size picks the stop a new take
/// opens at; the slider is a per-take override that never writes back.
enum ExportScale: Int, CaseIterable, Comparable, Sendable {
    // Ascending, so `allCases` is the slider's left-to-right order and the
    // Settings pop-up lists the stops from small to full.
    case quarter = 25, half = 50, threeQuarters = 75, full = 100

    var percent: Int { rawValue }
    var fraction: Double { Double(rawValue) / 100 }

    /// "50 %" — the slider's label and the Settings pop-up's titles.
    var title: String { "\(percent) %" }

    /// The slider position (0 = 25 % … 3 = 100 %).
    var index: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count - 1 }

    /// The stop at a slider position, clamped (the slider snaps to its tick
    /// marks, but its `doubleValue` is still a Double).
    init(index: Int) {
        let stops = Self.allCases
        self = stops[min(max(index, 0), stops.count - 1)]
    }

    /// `[` steps down, `]` up — staying put at either end.
    func stepped(by offset: Int) -> ExportScale {
        ExportScale(index: index + offset)
    }

    static func < (lhs: ExportScale, rhs: ExportScale) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// PURE export-size math — tested.
enum ExportSizing {
    /// The output frame for `source` at `scale`: each side scaled, rounded to
    /// the nearest **even** pixel (H.264 4:2:0, `VideoSize`), at least 2.
    /// `.full` keeps the source exactly (the take itself, never re-encoded).
    static func videoSize(source: VideoSize, scale: ExportScale) -> VideoSize {
        guard scale != .full else { return source }
        func side(_ pixels: Int) -> Int {
            max(2, Int((Double(pixels) * scale.fraction / 2).rounded()) * 2)
        }
        return VideoSize(width: side(source.width), height: side(source.height))
    }

    /// The upper-bound size of a re-encode: the target bitrate (the same
    /// bits-per-pixel rule as recording, `OutputGeometry.bitrate`) × the
    /// duration, in bytes. The encoder averages at or below the target on
    /// screen content, so the real file is normally smaller.
    static func estimatedBytes(
        videoSize: VideoSize, framesPerSecond: Int, quality: RecordingQuality, duration: TimeInterval
    ) -> Int64 {
        guard duration.isFinite, duration > 0 else { return 0 }
        let bitrate = OutputGeometry.bitrate(quality: quality, videoSize: videoSize, framesPerSecond: framesPerSecond)
        return Int64((Double(bitrate) * duration / 8).rounded(.up))
    }

    /// The take's frame rate as one of the recording rates: its track's
    /// nominal rate snapped to the nearest of 30 / 60 fps (an idle stretch
    /// makes the variable-rate file's average a little off). 60 fps when the
    /// track reports none.
    static func framesPerSecond(nominal: Double) -> Int {
        guard nominal.isFinite, nominal > 0 else { return RecordingFrameRate.fps60.framesPerSecond }
        return RecordingFrameRate.allCases.map(\.framesPerSecond)
            .min { abs(Double($0) - nominal) < abs(Double($1) - nominal) } ?? RecordingFrameRate.fps60.framesPerSecond
    }

    /// A pixel size as a `VideoSize`, nil when it has no area. A take's
    /// sides are already even (`OutputGeometry`); odd ones are trimmed.
    static func videoSize(pixels: CGSize?) -> VideoSize? {
        guard let pixels else { return nil }
        let width = Int(abs(pixels.width).rounded()) & ~1, height = Int(abs(pixels.height).rounded()) & ~1
        guard width >= 2, height >= 2 else { return nil }
        return VideoSize(width: width, height: height)
    }
}

/// PURE status-capsule readouts for the export size — tested.
enum ExportSizeText {
    /// "18.4 MB" — decimal units like Finder: KB below 1 MB, one decimal
    /// from MB up (none from 100 MB), GB from 1000 MB.
    static func bytes(_ count: Int64) -> String {
        let value = Double(max(0, count))
        if value < 1_000_000 { return "\(max(1, Int((value / 1000).rounded(.up)))) KB" }
        let (amount, unit) = value < 1_000_000_000 ? (value / 1_000_000, "MB") : (value / 1_000_000_000, "GB")
        let text = amount < 100 ? String(format: "%.1f", amount) : String(Int(amount.rounded()))
        return "\(text) \(unit)"
    }

    /// The size readout: the real file's size when one exists for the stop
    /// (the take at 100 %, a finished re-encode or Save at a smaller stop),
    /// else "≤ X MB" — the estimate's upper bound. Empty while neither is
    /// known yet.
    static func size(actual: Int64?, estimate: Int64?) -> String {
        if let actual { return bytes(actual) }
        if let estimate, estimate > 0 { return "≤ \(bytes(estimate))" }
        return ""
    }

    /// "1280 × 720 · 0:42" — the export's pixel size at the current stop and
    /// the take's duration; either left out while unknown.
    static func dimensionsAndDuration(videoSize: VideoSize?, duration: TimeInterval?) -> String {
        var parts: [String] = []
        if let videoSize { parts.append("\(videoSize.width) × \(videoSize.height)") }
        if let duration, duration.isFinite, duration >= 0 {
            parts.append(RecordingTimerText.compact(elapsed: duration.rounded()))
        }
        return parts.joined(separator: " · ")
    }

    /// In place of the size after a failed re-encode — nothing was saved or
    /// copied.
    static let failure = "Export failed"

    /// The pressed Save / Copy button's tooltip while it re-encodes.
    static let cancelToolTip = "Cancel export (Esc)"

    /// The encode's progress, 0…1, as a whole percentage ("42 %").
    static func progress(_ fraction: Double) -> String {
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return "\(Int((clamped * 100).rounded(.down))) %"
    }
}

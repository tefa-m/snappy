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

    /// The upper bound of a re-encode, in bytes — the "≤" readout, and the
    /// limit `RecordingTranscoder` holds the file to (it re-encodes leaner,
    /// and fails rather than exceed it). The target bitrate (the same
    /// bits-per-pixel rule as recording, `OutputGeometry.bitrate`) × the
    /// duration is only the encoder's *average*: detailed content overshoots
    /// it and a take's first key frame costs alike for one frame or thirty.
    /// So the bound budgets at least one second (the encoder's rate window),
    /// `rateHeadroom` over the target, and the MP4 container. Screen content
    /// normally lands far below it.
    static func estimatedBytes(
        videoSize: VideoSize, framesPerSecond: Int, quality: RecordingQuality, duration: TimeInterval
    ) -> Int64 {
        guard duration.isFinite, duration > 0 else { return 0 }
        let bitrate = OutputGeometry.bitrate(quality: quality, videoSize: videoSize, framesPerSecond: framesPerSecond)
        let video = Double(bitrate) * max(duration, rateWindow) * rateHeadroom / 8
        let frames = (duration * Double(max(1, framesPerSecond))).rounded(.up)
        let container = Double(containerBytes) + frames * Double(containerBytesPerFrame)
        return Int64((video + container).rounded(.up))
    }

    /// The encoder's rate-control window, seconds: the transcoder caps every
    /// window at the target rate (`kVTCompressionPropertyKey_DataRateLimits`)
    /// and the bound never budgets less than one.
    static let rateWindow: TimeInterval = 1
    /// How far over its target rate the encoder may land even under that cap
    /// (measured: noise at 160 × 120 reaches ~1.4×).
    static let rateHeadroom = 1.5
    /// MP4 boxes (ftyp, moov, track headers) plus the per-sample tables.
    static let containerBytes: Int64 = 4096
    static let containerBytesPerFrame: Int64 = 16

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
    /// from MB up (none from 100 MB), GB from 1000 MB. `roundingUp` for a
    /// bound, so the readout is never below the bytes it stands for.
    static func bytes(_ count: Int64, roundingUp: Bool = false) -> String {
        let count = max(0, count)
        // Whole units of `step` bytes, in integers so a bound never rounds
        // down through floating point.
        func units(_ step: Int64) -> Int64 {
            roundingUp ? (count + step - 1) / step : (count + step / 2) / step
        }
        if count < 1_000_000 { return "\(max(1, (count + 999) / 1000)) KB" }
        let (unit, name): (Int64, String) = count < 1_000_000_000 ? (1_000_000, "MB") : (1_000_000_000, "GB")
        if count < 100 * unit {
            let tenths = units(unit / 10)
            return "\(tenths / 10).\(tenths % 10) \(name)"
        }
        return "\(units(unit)) \(name)"
    }

    /// The size readout: the real file's size when one exists for the stop
    /// (the take at 100 %, a finished re-encode or Save at a smaller stop),
    /// else "≤ X MB" — the estimate's upper bound. Empty while neither is
    /// known yet.
    static func size(actual: Int64?, estimate: Int64?) -> String {
        if let actual { return bytes(actual) }
        if let estimate, estimate > 0 { return "≤ \(bytes(estimate, roundingUp: true))" }
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

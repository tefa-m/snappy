import CoreGraphics
import Foundation

/// PURE size and placement math for the recording window — tested. AppKit
/// coordinates (y up), points.
enum RecordingWindowLayout {
    /// The player is never smaller than this, so AVKit's floating controls
    /// (play, scrub bar, time) fit. A video narrower or flatter than that is
    /// letterboxed inside the player.
    static let minPlayerSize = CGSize(width: 240, height: 135)

    /// Wide enough for the traffic lights and Retake · Save · Copy, tall
    /// enough for a usable player.
    static let minWindowSize = CGSize(width: 440, height: 320)

    /// Space around the player inside the unobscured content area.
    static let margin: CGFloat = 16

    /// Kept below the player for the status capsule (capsule height plus its
    /// gaps), as in the editor.
    static let statusBand: CGFloat = 44

    /// The `.unified` toolbar's height. Only the *initial* size uses it; the
    /// live layout reads the window's `contentLayoutRect`.
    static let titlebarHeight: CGFloat = 52

    /// Offset between windows that would otherwise open exactly on top of
    /// each other.
    static let cascadeStep: CGFloat = 24

    /// The video's size in points on a screen of backing `scale`.
    static func pointSize(videoPixels: CGSize, scale: CGFloat) -> CGSize {
        let scale = scale > 0 ? scale : 1
        return CGSize(width: abs(videoPixels.width) / scale, height: abs(videoPixels.height) / scale)
    }

    /// The window's initial content size: the video 1:1, shrunk to fit 80 % ×
    /// 70 % of the screen's visible frame (like the editor), with room for the
    /// toolbar and the status capsule; never below `minWindowSize`, never
    /// larger than the visible frame. A degenerate size gets the minimum
    /// player.
    static func contentSize(videoPoints: CGSize, visible: CGSize) -> CGSize {
        let width = abs(videoPoints.width), height = abs(videoPoints.height)
        var player = minPlayerSize
        if width > 0, height > 0 {
            let fit = min(1, visible.width * 0.8 / width, visible.height * 0.7 / height)
            player = CGSize(
                width: max((width * fit).rounded(), minPlayerSize.width),
                height: max((height * fit).rounded(), minPlayerSize.height)
            )
        }
        let size = CGSize(
            width: max(minWindowSize.width, player.width + 2 * margin),
            height: max(minWindowSize.height, player.height + 2 * margin + titlebarHeight + statusBand)
        )
        return CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
    }

    /// The player's frame inside `area` (the unobscured content area above the
    /// status band): the video aspect-fit into `area` inset by `margin` —
    /// upscaled when the window grows, like the editor's canvas and
    /// QuickTime — grown to `minPlayerSize` where the area allows, centred.
    /// Rounded to whole points, so the video isn't drawn on half points.
    static func playerFrame(video: CGSize, in area: CGRect) -> CGRect {
        let available = area.insetBy(dx: margin, dy: margin)
        guard available.width > 0, available.height > 0 else { return .zero }
        let width = abs(video.width), height = abs(video.height)
        var size = available.size
        if width > 0, height > 0 {
            let scale = min(available.width / width, available.height / height)
            size = CGSize(width: width * scale, height: height * scale)
        }
        size.width = min(max(size.width, minPlayerSize.width), available.width)
        size.height = min(max(size.height, minPlayerSize.height), available.height)
        return CGRect(
            x: (available.midX - size.width / 2).rounded(), y: (available.midY - size.height / 2).rounded(),
            width: size.width.rounded(), height: size.height.rounded()
        )
    }

    /// Where a new window goes: centred on the visible frame, then stepped
    /// down-right by `cascadeStep` while another recording window already
    /// sits at that origin (within 2 pt), so two takes in a row don't hide
    /// each other. Clamped to the visible frame.
    static func origin(windowSize: CGSize, visible: CGRect, occupied: [CGPoint]) -> CGPoint {
        func clamped(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: max(min(point.x, visible.maxX - windowSize.width), visible.minX).rounded(),
                y: max(min(point.y, visible.maxY - windowSize.height), visible.minY).rounded()
            )
        }
        func isOccupied(_ point: CGPoint) -> Bool {
            occupied.contains { abs($0.x - point.x) <= 2 && abs($0.y - point.y) <= 2 }
        }
        var origin = clamped(CGPoint(
            x: visible.midX - windowSize.width / 2, y: visible.midY - windowSize.height / 2
        ))
        // Bounded: a stack of windows at the visible frame's corner stops stepping.
        for _ in 0..<occupied.count where isOccupied(origin) {
            let next = clamped(CGPoint(x: origin.x + cascadeStep, y: origin.y - cascadeStep))
            if next == origin { break }
            origin = next
        }
        return origin
    }
}

/// PURE window title and status-capsule text — tested. Mirrors the editor's
/// "Shot W × H" / "Shot W × H · 100%".
enum RecordingWindowStatus {
    /// "Recording 1280 × 720": the video's pixel size — the file's real size,
    /// what a player or Slack reports (a recording has no point scale of its
    /// own, and the 4096 px encoder cap can change it). Just "Recording"
    /// while the size is unknown.
    static func title(videoSize: CGSize?) -> String {
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return "Recording" }
        return "Recording \(Int(videoSize.width.rounded())) × \(Int(videoSize.height.rounded()))"
    }

    /// "Recording 1280 × 720 · 0:42" — the duration rounded to the nearest
    /// second in the menu bar's compact form; left out when unknown.
    static func text(title: String, duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return title }
        return "\(title) · \(RecordingTimerText.compact(elapsed: duration.rounded()))"
    }
}

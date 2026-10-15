import CoreGraphics

/// PURE placement of the recording chrome — border, glass toolbar, countdown
/// disc — in AppKit global points (`RecordingTarget` space). Unit-tested; the
/// chrome's views and panels do no layout maths of their own.
///
/// The chrome is never in the video (ScreenCaptureKit excludes Snappy by
/// application), so nothing here has to keep clear of the recorded pixels for
/// the video's sake — only for the user's view of the target.
enum ChromeLayout {
    // MARK: - Border

    /// The coloured band (amber in Setup, red while recording).
    static let borderBandWidth: CGFloat = 3
    /// A dark hairline outside the band: an amber line alone is only 2.2:1
    /// against white, the hairline keeps the edge ≥ 3:1 on light content.
    static let borderHairlineWidth: CGFloat = 1
    /// Everything the border adds around the target on each side.
    static var borderThickness: CGFloat { borderBandWidth + borderHairlineWidth }

    /// Where the border ring lies, and the windows that show it.
    struct BorderGeometry: Equatable {
        /// The ring's outer edge, AppKit global. The ring is everything
        /// between this and `inner` — a hairline, then the band.
        let outer: CGRect
        /// One frame per display the ring reaches: `outer` cut to that
        /// screen. Each window draws the **same** global ring clipped to its
        /// frame, so a cut never paints a false edge where it falls (a window
        /// target spanning two displays, or partly off screen). Empty when
        /// nothing of the ring is on any screen.
        let windowFrames: [CGRect]

        /// The ring's inner edge: the target itself, except on folded sides.
        var inner: CGRect {
            outer.insetBy(dx: ChromeLayout.borderThickness, dy: ChromeLayout.borderThickness)
        }
    }

    /// The border around `target`: `borderThickness` *outside* the rect on
    /// every side. One exception, for **area** targets (`foldsAtScreenEdges`):
    /// a side whose outside strip is on no screen at all (an area clamped to
    /// the display's physical edge, Q11) folds inward, so the user still sees
    /// that edge — the capture overlay's edge does the same. A **window**
    /// target never folds: an edge of it that is off screen simply isn't
    /// drawn, rather than drawn at the screen edge on top of the window.
    static func border(around target: CGRect, foldsAtScreenEdges: Bool, screenFrames: [CGRect]) -> BorderGeometry {
        let target = target.standardized
        let t = borderThickness
        func onAnyScreen(_ strip: CGRect) -> Bool {
            screenFrames.contains { hasArea($0.intersection(strip)) }
        }
        func outset(_ strip: CGRect) -> CGFloat {
            foldsAtScreenEdges && !onAnyScreen(strip) ? 0 : t
        }
        let left = outset(CGRect(x: target.minX - t, y: target.minY, width: t, height: target.height))
        let right = outset(CGRect(x: target.maxX, y: target.minY, width: t, height: target.height))
        let bottom = outset(CGRect(x: target.minX, y: target.minY - t, width: target.width, height: t))
        let top = outset(CGRect(x: target.minX, y: target.maxY, width: target.width, height: t))
        let outer = CGRect(
            x: target.minX - left, y: target.minY - bottom,
            width: target.width + left + right, height: target.height + bottom + top
        )
        let frames = screenFrames.map { $0.intersection(outer) }.filter(hasArea)
        return BorderGeometry(outer: outer, windowFrames: frames)
    }

    private static func hasArea(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.width > 0 && rect.height > 0
    }

    // MARK: - Toolbar

    /// Space between the border and the toolbar.
    static let toolbarGap: CGFloat = 8

    /// The toolbar's frame for a toolbar of `size`: centred under the target's
    /// border; above it when there is no room below; and when neither fits
    /// (a target filling the display) inside the target along its bottom edge.
    /// Always clamped into `visibleFrame` (the display minus menu bar and
    /// Dock), so it can never end up off screen or under the Dock.
    static func toolbarFrame(size: CGSize, target: CGRect, visibleFrame: CGRect) -> CGRect {
        let outer = target.standardized.insetBy(dx: -borderThickness, dy: -borderThickness)
        let below = outer.minY - toolbarGap - size.height
        let above = outer.maxY + toolbarGap
        let y: CGFloat
        if below >= visibleFrame.minY {
            y = below
        } else if above + size.height <= visibleFrame.maxY {
            y = above
        } else {
            y = target.minY + toolbarGap
        }
        let x = outer.midX - size.width / 2
        return CGRect(
            x: clamp(x, min: visibleFrame.minX, max: visibleFrame.maxX - size.width),
            y: clamp(y, min: visibleFrame.minY, max: visibleFrame.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Countdown disc

    /// The disc's diameter on a target with room for it.
    static let countdownDiameter: CGFloat = 120
    /// Never smaller than this, even on a tiny target (it may then overhang
    /// the target — it is never recorded).
    static let countdownMinimumDiameter: CGFloat = 56

    /// The countdown disc, centred in the target: `countdownDiameter`, shrunk
    /// to 80 % of the target's shorter side when that is smaller.
    static func countdownDiscFrame(in target: CGRect) -> CGRect {
        let target = target.standardized
        let fitted = min(countdownDiameter, min(target.width, target.height) * 0.8)
        let diameter = max(countdownMinimumDiameter, fitted).rounded()
        return CGRect(
            x: (target.midX - diameter / 2).rounded(),
            y: (target.midY - diameter / 2).rounded(),
            width: diameter,
            height: diameter
        )
    }

    /// The numeral's point size for a disc of `diameter`: large, with the
    /// glass showing around it (66 pt on the full 120 pt disc).
    static func countdownFontSize(diameter: CGFloat) -> CGFloat {
        (diameter * 0.55).rounded()
    }

    // MARK: - Display

    /// Index of the screen the chrome belongs on for `frame`: the one it
    /// overlaps most (a window target can move to another display), else the
    /// nearest one by centre. nil only without screens.
    static func screenIndex(for frame: CGRect, screenFrames: [CGRect]) -> Int? {
        func area(_ rect: CGRect) -> CGFloat {
            rect.isNull ? 0 : rect.width * rect.height
        }
        let overlaps = screenFrames.map { area($0.intersection(frame)) }
        if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 {
            return best
        }
        func distance(_ screen: CGRect) -> CGFloat {
            hypot(screen.midX - frame.midX, screen.midY - frame.midY)
        }
        return screenFrames.indices.min { distance(screenFrames[$0]) < distance(screenFrames[$1]) }
    }

    /// `value` within `min…max`; `min` wins when the range is empty (a toolbar
    /// wider than the display starts at its left edge).
    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.max(lower, Swift.min(value, upper))
    }
}

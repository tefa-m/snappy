import CoreGraphics

/// What a recording records — PURE, unit-tested. Every frame is in **AppKit
/// global** coordinates (origin bottom-left of the primary display, y up), the
/// same space as `NSScreen.frame` and the area-selection result; the pipeline
/// converts to ScreenCaptureKit's display-local space itself (T2's
/// `OutputGeometry`), never here.
///
/// One display per recording (Q11): `displayID` is the display the target was
/// chosen on. A window target's window may later move to another display, which
/// is fine — its capture filter is display-independent.
enum RecordingTarget: Equatable, Sendable {
    /// A screen region (free rect, or S = "window's area"): everything visible
    /// there is recorded, including other windows and menus on top.
    case area(globalRect: CGRect, displayID: CGDirectDisplayID)
    /// One window itself (W): only that window, followed as it moves.
    case window(windowID: CGWindowID, frame: CGRect, displayID: CGDirectDisplayID)
    /// W + a part of the window (v2, Q37): the window's own stream, cropped
    /// live to the part (V3, `PartCropTracker`). `frame` is the part's. A
    /// window target in every other respect (`windowID`, `isWindow`: locked
    /// in Setup, letterboxed, ink anchored to the window).
    ///
    /// Produced by the picker (`WindowSnapCandidates.target`, V2); while
    /// recording, the pipeline's part reports update `frame`, its window
    /// reports `windowFrame` (`withFrame`, `withWindowFrame`).
    case windowPart(WindowPartTarget, displayID: CGDirectDisplayID)

    /// The target's current frame, AppKit global — a part's own frame for
    /// `.windowPart`.
    var frame: CGRect {
        switch self {
        case .area(let rect, _): rect
        case .window(_, let frame, _): frame
        case .windowPart(let part, _): part.frame
        }
    }

    var displayID: CGDirectDisplayID {
        switch self {
        case .area(_, let id), .window(_, _, let id), .windowPart(_, let id): id
        }
    }

    var windowID: CGWindowID? {
        switch self {
        case .area: nil
        case .window(let id, _, _): id
        case .windowPart(let part, _): part.windowID
        }
    }

    var isWindow: Bool { windowID != nil }

    /// The recorded window's frame (W, W + part) — what window-anchored ink
    /// resolves against. Nil for an area.
    var windowFrame: CGRect? {
        switch self {
        case .area: nil
        case .window(_, let frame, _): frame
        case .windowPart(let part, _): part.windowFrame
        }
    }

    /// The same target at a new frame — a window that moved or resized, or an
    /// area the Setup overlay moved. The kind, window and display never change.
    /// For `.windowPart` the frame is the **part's** (its window stays put);
    /// a moved window goes through `withWindowFrame`.
    func withFrame(_ frame: CGRect) -> RecordingTarget {
        switch self {
        case .area(_, let id):
            return .area(globalRect: frame.standardized, displayID: id)
        case .window(let window, _, let id):
            return .window(windowID: window, frame: frame.standardized, displayID: id)
        case .windowPart(var part, let id):
            part.frame = frame.standardized
            return .windowPart(part, displayID: id)
        }
    }

    /// The target after its **window** moved or resized to `frame` (the
    /// pipeline's `onWindowFrameChange`). A part keeps its offset from the
    /// window's top-left corner and its size — what the recorded crop does
    /// too (window-local) — until its polled Accessibility frame says
    /// otherwise (`onPartFrameChange` → `withFrame`). An area has no window
    /// and stays as it is.
    func withWindowFrame(_ frame: CGRect) -> RecordingTarget {
        switch self {
        case .area:
            return self
        case .window:
            return withFrame(frame)
        case .windowPart(var part, let id):
            let window = frame.standardized
            part.frame.origin = CGPoint(
                x: window.minX + (part.frame.minX - part.windowFrame.minX),
                y: window.maxY - (part.windowFrame.maxY - part.frame.minY)
            )
            part.windowFrame = window
            return .windowPart(part, displayID: id)
        }
    }

    /// A part's whole window — what a Retake falls back to when the part is
    /// gone (Q41). Every other target is itself.
    var wholeWindow: RecordingTarget {
        guard case .windowPart(let part, let id) = self else { return self }
        return .window(windowID: part.windowID, frame: part.windowFrame, displayID: id)
    }

    /// What a Retake's Setup shows once the target has been looked up again
    /// (Q41) — PURE, tested. `livePartFrame` is a W + part's Accessibility
    /// frame now (nil = gone, or the app didn't answer); `window` the
    /// window server's look at the recorded window.
    ///
    /// - **Area** (free, S, S + part): itself — the last screen rect.
    /// - **Window closed** (W, W + part): its region as an area, as Setup
    ///   does when the chosen window closes (`RecordingSession`).
    /// - **W**: the window where it is now (still itself while off screen).
    /// - **W + part**: the same part at its live frame (clipped to the
    ///   window) in the window where it is now; **the whole window** when
    ///   the part is gone. A part without an element can't be looked up, so
    ///   it keeps its last rect, carried along with the window.
    func refreshedForRetake(livePartFrame: CGRect?, window: WindowObservation) -> RecordingTarget {
        switch (self, window) {
        case (.area, _):
            return self
        case (_, .missing):
            return asArea
        case (.window, .onScreen(let frame)):
            return withFrame(frame)
        case (.window, .offScreen):
            return self
        case (.windowPart(let part, _), _):
            var moved = self
            if case .onScreen(let frame) = window { moved = withWindowFrame(frame) }
            guard part.element != nil else { return moved }
            guard let live = livePartFrame?.standardized, let windowFrame = moved.windowFrame else {
                return moved.wholeWindow
            }
            let clipped = live.intersection(windowFrame)
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return moved.wholeWindow }
            return moved.withFrame(clipped)
        }
    }

    /// The region a vanished window covered: what Setup falls back to when the
    /// chosen window closes before recording starts, so the session keeps a
    /// valid target instead of pointing at a dead window.
    var asArea: RecordingTarget {
        .area(globalRect: frame, displayID: displayID)
    }

    /// An area target clamped to its display (Q11: the rect never crosses onto
    /// another display). nil when nothing of `rect` lies on the display — e.g.
    /// a window capture whose window was entirely off that screen.
    static func area(
        _ rect: CGRect, clampedTo screenFrame: CGRect, displayID: CGDirectDisplayID
    ) -> RecordingTarget? {
        let clamped = rect.standardized.intersection(screenFrame)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        return .area(globalRect: clamped, displayID: displayID)
    }
}

/// The payload of `RecordingTarget.windowPart` — everything the pipeline needs
/// to crop the window's stream to the part live (Q37): the window, the part's
/// last known rect and a live Accessibility handle to poll. AppKit global
/// frames.
struct WindowPartTarget: Equatable, Sendable {
    let windowID: CGWindowID
    /// The window's frame when it was last known.
    var windowFrame: CGRect
    /// The part's last known frame, kept when the part disappears (Q37) —
    /// what Setup and the chrome show.
    var frame: CGRect
    /// What the snap chip called it ("Web page", "Sidebar").
    let name: String
    /// The live handle the pipeline polls (~10 Hz) and Retake looks up
    /// (Q41). Nil only for a part whose element couldn't be kept; then the
    /// last `frame` is all there is.
    let element: WindowPartElement?
}

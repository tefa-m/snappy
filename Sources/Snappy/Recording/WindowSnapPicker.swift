import AppKit
import ScreenCaptureKit

/// A window the S/W snap modes can hover — AppKit global frame.
struct SnapWindow: Equatable, Sendable {
    let windowID: CGWindowID
    let frame: CGRect
    let appName: String?
    /// The owning app — where the window-part picker asks for its tree.
    var processID: pid_t?

    init(windowID: CGWindowID, frame: CGRect, appName: String?, processID: pid_t? = nil) {
        self.windowID = windowID
        self.frame = frame
        self.appName = appName
        self.processID = processID
    }
}

/// The fields of an `SCWindow` the picker needs, so the filtering is testable
/// without ScreenCaptureKit. `cgFrame` is SCK's: CoreGraphics global, origin
/// top-left of the primary display, y down.
struct SnapWindowInfo: Equatable, Sendable {
    let windowID: CGWindowID
    let cgFrame: CGRect
    let windowLayer: Int
    let isOnScreen: Bool
    let processID: pid_t?
    let appName: String?
}

/// PURE snap-candidate logic — unit-tested.
enum WindowSnapCandidates {
    /// Same floor as the screenshot window picker.
    static let minimumSize: CGFloat = 40

    /// The snappable windows on one display, front to back (SCK's order):
    /// on screen, normal layer, not Snappy's own (by PID — the ink and chrome
    /// panels are ours), at least `minimumSize`, and overlapping `screenFrame`
    /// (one display per recording, Q11). Frames are converted to AppKit global
    /// through `CaptureGeometry` — the only place that flip lives.
    static func candidates(
        from windows: [SnapWindowInfo], ownPID: pid_t, screenFrame: CGRect, primaryDisplayHeight: CGFloat
    ) -> [SnapWindow] {
        windows.compactMap { info in
            guard info.isOnScreen, info.windowLayer == 0, info.processID != ownPID,
                  info.cgFrame.width >= minimumSize, info.cgFrame.height >= minimumSize
            else { return nil }
            let frame = CaptureGeometry.appKitRect(fromCGGlobal: info.cgFrame, primaryDisplayHeight: primaryDisplayHeight)
            let onDisplay = frame.intersection(screenFrame)
            guard !onDisplay.isNull, !onDisplay.isEmpty else { return nil }
            return SnapWindow(windowID: info.windowID, frame: frame, appName: info.appName, processID: info.processID)
        }
    }

    /// The front-most candidate under `point` (AppKit global) — first hit wins.
    static func window(at point: CGPoint, in candidates: [SnapWindow]) -> SnapWindow? {
        candidates.first { $0.frame.contains(point) }
    }

    /// What snapping to `window` — or to `part` of it — makes the target:
    /// - S (`.area`): the screen region the window or part covers (Q38),
    ///   clamped to the display and to the Setup min size — everything on top
    ///   is recorded too.
    /// - W (`.window`): the window itself at its full frame (it may reach onto
    ///   another display; the window filter is display-independent); with a
    ///   part, `.windowPart` — that window cropped to the part (Q37).
    static func target(
        for window: SnapWindow, part: SnapPart? = nil, kind: SnapKind,
        screenFrame: CGRect, displayID: CGDirectDisplayID
    ) -> RecordingTarget {
        switch kind {
        case .area:
            let frame = part?.frame ?? window.frame
            let visible = frame.intersection(screenFrame)
            let region = visible.isNull ? frame : visible
            return .area(globalRect: SetupGeometry.clamped(region, to: screenFrame), displayID: displayID)
        case .window:
            guard let part else {
                return .window(windowID: window.windowID, frame: window.frame, displayID: displayID)
            }
            let target = WindowPartTarget(
                windowID: window.windowID, windowFrame: window.frame, frame: part.frame,
                name: part.name, element: part.element
            )
            return .windowPart(target, displayID: displayID)
        }
    }
}

/// Loads the snap candidates for one snap-mode visit: a **fresh**
/// `SCShareableContent` (window positions matter, so never the warm cache's),
/// filtered to the target display. A newer `load` or `cancel` drops an older
/// result that is still in flight.
@MainActor
final class WindowSnapPicker {
    private(set) var candidates: [SnapWindow] = []
    private var task: Task<Void, Never>?
    private var generation = 0

    /// Replaces the candidates; `completion` runs once they are in (not when
    /// the load was cancelled or superseded, nor when it failed).
    func load(screenFrame: CGRect, completion: @escaping @MainActor () -> Void) {
        cancel()
        let current = generation
        task = Task { [weak self] in
            let infos: [SnapWindowInfo]
            do {
                let content = try await CaptureEngine.shareableContent()
                infos = content.windows.map(SnapWindowInfo.init)
            } catch {
                // Setup still works without snapping; Esc leaves snap mode.
                NSLog("Snappy: window snap list unavailable: %@", String(describing: error))
                return
            }
            guard let self, self.generation == current, !Task.isCancelled else { return }
            self.candidates = WindowSnapCandidates.candidates(
                from: infos,
                ownPID: ProcessInfo.processInfo.processIdentifier,
                screenFrame: screenFrame,
                primaryDisplayHeight: NSScreen.screens.first?.frame.maxY ?? 0
            )
            completion()
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        candidates = []
    }

    func window(at point: CGPoint) -> SnapWindow? {
        WindowSnapCandidates.window(at: point, in: candidates)
    }
}

private extension SnapWindowInfo {
    init(_ window: SCWindow) {
        self.init(
            windowID: window.windowID,
            cgFrame: window.frame,
            windowLayer: window.windowLayer,
            isOnScreen: window.isOnScreen,
            processID: window.owningApplication?.processID,
            appName: window.owningApplication?.applicationName
        )
    }
}

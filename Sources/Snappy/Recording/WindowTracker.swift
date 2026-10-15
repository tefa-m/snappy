import AppKit

/// One look at a window-itself target (W mode).
enum WindowObservation: Equatable, Sendable {
    /// On screen at this AppKit-global frame.
    case onScreen(CGRect)
    /// Still exists but isn't on screen: minimised, its app hidden, or on
    /// another Space — indistinguishable without Accessibility access.
    case offScreen
    /// Really gone: closed (absent from the window server's full list, not
    /// just the on-screen one) or its app terminated.
    case missing
}

enum WindowTrackingEvent: Equatable, Sendable {
    case frameChanged(CGRect)
    case gone
}

/// PURE W-mode tracking decisions — unit-tested. Every frame change is
/// reported; `gone` is reported **exactly once** and nothing after it.
///
/// **Only a window that is really gone ends the recording** (Q13 — Leader
/// decision in review round 1, made final by Tefa on 2026-10-09): closed or
/// its app terminated. Off screen — minimised, on another Space, its app
/// hidden — the recording keeps going until the person stops it (the
/// pipeline re-appends the last frame with the ink; the menu bar's ● and
/// timer stay visible) and resumes when the window returns: the three can't
/// be told apart without Accessibility access, and a wrongly stopped take is
/// worse than a few extra seconds. `offScreenEndsRecording` would flip this
/// back to "minimise → auto-stop"; it stays off.
struct WindowTrackingState: Equatable, Sendable {
    /// **The switch.** `true` = an off-screen window (minimised, other Space,
    /// app hidden) ends the recording after `offScreenGrace` observations;
    /// `false` (current) = only a closed window or terminated app does.
    static let offScreenEndsRecording = false

    /// With the switch on: consecutive off-screen observations that count as
    /// minimised (~100 ms at `WindowTracker`'s 30 Hz), so a window-server
    /// hiccup during a transition doesn't end the recording.
    static let offScreenGrace = 3

    private(set) var frame: CGRect
    private(set) var isGone = false
    private let offScreenEndsRecording: Bool
    private var offScreenCount = 0

    init(frame: CGRect, offScreenEndsRecording: Bool = Self.offScreenEndsRecording) {
        self.frame = frame
        self.offScreenEndsRecording = offScreenEndsRecording
    }

    /// Off screen right now (only tracked; never `gone` with the switch off).
    var isOffScreen: Bool { offScreenCount > 0 }

    mutating func update(_ observation: WindowObservation) -> WindowTrackingEvent? {
        guard !isGone else { return nil }
        switch observation {
        case .onScreen(let newFrame):
            offScreenCount = 0
            guard newFrame != frame else { return nil }
            frame = newFrame
            return .frameChanged(newFrame)
        case .offScreen:
            offScreenCount += 1
            guard offScreenEndsRecording, offScreenCount >= Self.offScreenGrace else { return nil }
            isGone = true
            return .gone
        case .missing:
            isGone = true
            return .gone
        }
    }
}

/// Follows a W-mode window while it is recorded: frame changes (moves and
/// resizes, so the border, toolbar and window-anchored ink follow it) and its
/// closing (auto-stop; minimising only with `offScreenEndsRecording`). Polls the window server on the main
/// actor; one window lookup is cheap, and polling needs no Accessibility
/// permission (an `AXObserver` would).
@MainActor
final class WindowTracker {
    /// 30 Hz: smooth enough for the border to follow a dragged window.
    static let pollInterval: Duration = .milliseconds(33)

    var onFrameChange: (@MainActor (CGRect) -> Void)?
    /// Fires at most once; tracking stops with it.
    var onGone: (@MainActor () -> Void)?

    private let windowID: CGWindowID
    private let observe: @MainActor (CGWindowID) -> WindowObservation
    private var state: WindowTrackingState
    private var task: Task<Void, Never>?

    /// `frame` is the target's frame as last known (AppKit global); the first
    /// poll reports any difference. `observe` is injectable for tests.
    init(
        windowID: CGWindowID, frame: CGRect,
        observe: @escaping @MainActor (CGWindowID) -> WindowObservation = WindowTracker.systemObservation
    ) {
        self.windowID = windowID
        self.observe = observe
        state = WindowTrackingState(frame: frame)
    }

    var isGone: Bool { state.isGone }

    /// Starts polling. A `Task` loop rather than a `Timer`, so it keeps
    /// running while a menu holds the run loop in event-tracking mode.
    func start() {
        guard task == nil, !state.isGone else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.poll()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One observation, reported through the callbacks. Also called directly
    /// when the stream stops with an error, to tell a closed window apart
    /// from a capture failure.
    func poll() {
        guard let event = state.update(observe(windowID)) else { return }
        switch event {
        case .frameChanged(let frame):
            onFrameChange?(frame)
        case .gone:
            stop()
            onGone?()
        }
    }

    /// The window server's view of one window. `.optionIncludingWindow`
    /// looks the window up in the **full** list (on screen or not), so
    /// "absent" means closed, never merely minimised or on another Space.
    /// `kCGWindowBounds` is CG global (top-left origin), converted through
    /// `CaptureGeometry`.
    static func systemObservation(of windowID: CGWindowID) -> WindowObservation {
        guard
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]],
            let info = list.first(where: { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == windowID })
        else { return .missing }
        // Its app terminated (the window server may list the window a moment
        // longer). `kill(pid, 0)` probes the process without signalling it.
        if let pid = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value, kill(pid, 0) != 0, errno == ESRCH {
            return .missing
        }
        guard
            (info[kCGWindowIsOnscreen] as? Bool) == true,
            let boundsDictionary = info[kCGWindowBounds] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        else { return .offScreen }
        let primaryDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return .onScreen(CaptureGeometry.appKitRect(fromCGGlobal: bounds, primaryDisplayHeight: primaryDisplayHeight))
    }
}

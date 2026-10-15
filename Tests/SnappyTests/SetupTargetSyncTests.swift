import AppKit
import Foundation
import Testing
@testable import Snappy

/// `SetupTargetSync` against the **real** `RecordingCoordinator` (review
/// round 1 #1/#2): the overlay's own corrections must reach every peer, and a
/// key right after `show` must act on the corrected target. The overlay here
/// is a window-less adapter that drives `SetupTargetSync` exactly as
/// `RecordingSetupOverlay` does (`apply` → `update`, input → `reconcileNow`
/// first); the scheduler is a manual queue.
@MainActor
@Suite("SetupTargetSync", .serialized)
struct SetupTargetSyncTests {
    private static let display = SetupGeometry.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
    private static let window = SnapWindow(windowID: 9, frame: CGRect(x: 1300, y: 100, width: 400, height: 300), appName: "App")

    // MARK: - Fakes

    @MainActor final class Queue {
        var work: [@MainActor () -> Void] = []
        func drain() {
            while !work.isEmpty { work.removeFirst()() }
        }
    }

    /// `RecordingSetupOverlay` minus the window.
    @MainActor final class ProbeOverlay: RecordingSetupOverlaying {
        var onEvent: RecordingEventHandler?
        private(set) var lastSession: RecordingSession?
        private(set) lazy var sync = SetupTargetSync(schedule: { [queue] work in queue.work.append(work) }) {
            [weak self] event in self?.onEvent?(event)
        }
        let queue: Queue
        init(queue: Queue) { self.queue = queue }

        func show(_ session: RecordingSession) {
            sync.display = SetupTargetSyncTests.display
            apply(session)
        }
        func apply(_ session: RecordingSession) {
            lastSession = session
            sync.update(session)
            if session.phase.isSnapping == false { sync.hovered = nil }
        }
        func close() { sync.close() }

        /// `updateHover`: an input path, reported at once.
        func hover(_ window: SnapWindow?) {
            sync.hovered = window
            sync.reconcileNow()
        }

        /// `keyDown`: settle first, then the command.
        func press(_ command: RecordingCommand) {
            sync.reconcileNow()
            onEvent?(.command(command))
        }
    }

    @MainActor final class PeerInk: LiveInkHosting {
        var onEvent: RecordingEventHandler?
        let frameDecorator: any FrameDecorating = NullFrameDecorator()
        var target: RecordingTarget?
        func show(_ session: RecordingSession, style: InkStyle, settings: RecordingSettings,
                  restoring snapshot: (any LiveInkSetupSnapshot)?) { target = session.target }
        func apply(_ session: RecordingSession) { target = session.target }
        func apply(style: InkStyle) {}
        func perform(_ command: InkCommand) {}
        func setupSnapshot() -> (any LiveInkSetupSnapshot)? { nil }
        func close() {}
    }

    @MainActor final class PeerChrome: RecordingChromeHosting {
        var onEvent: RecordingEventHandler?
        var target: RecordingTarget?
        func show(_ session: RecordingSession, style: InkStyle) { target = session.target }
        func apply(_ session: RecordingSession) { target = session.target }
        func apply(style: InkStyle) {}
        func captureDidStart() {}
        func close() {}
    }

    @MainActor final class Pipeline: RecordingPipelining {
        var onWindowFrameChange: (@MainActor (CGRect) -> Void)?
        var onWindowGone: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        var target: RecordingTarget?
        var url: URL?
        func start(target: RecordingTarget, settings: RecordingSettings,
                   decorator: any FrameDecorating, outputURL: URL) async throws {
            self.target = target
            url = outputURL
        }
        func stop() async throws -> URL {
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            try Data("mp4".utf8).write(to: url)
            return url
        }
    }

    /// A recording window per finished take (the real one needs a screen).
    @MainActor final class Window: RecordingWindowHosting {
        let take: URL
        let onRetake: (@MainActor () -> Void)?
        var isOpen = true
        var onClose: (@MainActor () -> Void)?
        init(take: URL, onRetake: (@MainActor () -> Void)?) {
            self.take = take
            self.onRetake = onRetake
        }
        func show() {}
        func bringToFront() {}
        func close() {
            guard isOpen else { return }
            isOpen = false
            Task { @MainActor in self.onClose?() }
        }
    }

    @MainActor final class Harness {
        let queue = Queue()
        let ink = PeerInk()
        let chrome = PeerChrome()
        let pipeline = Pipeline()
        let overlay: ProbeOverlay
        let coordinator: RecordingCoordinator
        let defaults: UserDefaults
        let suiteName = "SnappyTests.SetupTargetSync.\(UUID().uuidString)"
        let tempStore: RecordingTempStore

        init() {
            overlay = ProbeOverlay(queue: queue)
            defaults = UserDefaults(suiteName: suiteName)!
            let settings = SettingsStore(defaults: defaults)
            settings.recordingCountdown = .off
            tempStore = RecordingTempStore(directory: FileManager.default.temporaryDirectory
                .appending(path: "SnappySetupSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory))
            let (overlay, ink, chrome, pipeline) = (overlay, ink, chrome, pipeline)
            coordinator = RecordingCoordinator(
                components: RecordingComponents(
                    makeSetupOverlay: { overlay }, makeLiveInk: { ink }, makePipeline: { pipeline },
                    makeChrome: { chrome },
                    makeRecordingWindow: { take, _, onRetake, _ in Window(take: take, onRetake: onRetake) }
                ),
                settings: settings, tempStore: tempStore
            )
            coordinator.activateUserApp = { _ in }
            coordinator.activateSnappy = {}
        }

        /// Every piece agrees on one target.
        var peerTargets: [RecordingTarget?] { [overlay.lastSession?.target, ink.target, chrome.target] }

        func expectInSync(_ expected: RecordingTarget, sourceLocation: SourceLocation = #_sourceLocation) {
            for target in peerTargets {
                #expect(target == expected, sourceLocation: sourceLocation)
            }
        }

        func cleanUp() {
            coordinator.handle(.command(.cancel))
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempStore.directory)
        }
    }

    private static let area = RecordingTarget.area(globalRect: CGRect(x: 100, y: 100, width: 300, height: 200), displayID: 1)

    // MARK: - #2: S ↔ W over a hovered window

    @Test func switchingSnapKindOverAHoveredWindowReachesEveryPeer() {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.coordinator.beginSession(target: Self.area, userApp: nil))
        h.queue.drain()

        h.overlay.press(.snap(.area))
        h.overlay.hover(Self.window)
        let asArea = RecordingTarget.area(globalRect: CGRect(x: 1300, y: 100, width: 140, height: 300), displayID: 1)
        h.expectInSync(asArea)

        // S → W: the overlay learns of it inside the broadcast; the
        // conversion arrives afterwards and lands in every peer.
        h.overlay.press(.snap(.window))
        h.queue.drain()
        h.expectInSync(.window(windowID: 9, frame: Self.window.frame, displayID: 1))

        // W → S.
        h.overlay.press(.snap(.area))
        h.queue.drain()
        h.expectInSync(asArea)

        // Confirm keeps it; Esc would have restored the original.
        h.overlay.press(.snap(.area))
        #expect(h.coordinator.phase == .setup(.pointer))
        h.queue.drain()
        h.expectInSync(asArea)
    }

    @Test func movingOffEveryWindowShowsThePreSnapTargetEverywhere() {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: Self.area, userApp: nil)
        h.queue.drain()
        h.overlay.press(.snap(.window))
        h.overlay.hover(Self.window)
        h.overlay.hover(nil)
        h.queue.drain()
        h.expectInSync(Self.area)
    }

    // MARK: - #1: normalising the incoming target

    @Test func aTinyHandedOverRectIsNormalisedForEveryPeer() {
        let h = Harness()
        defer { h.cleanUp() }
        let tiny = RecordingTarget.area(globalRect: CGRect(x: 500, y: 500, width: 1, height: 1), displayID: 1)
        #expect(h.coordinator.beginSession(target: tiny, userApp: nil))
        // Nothing is reported from inside `beginSession`'s broadcast…
        h.expectInSync(tiny)
        // …but right after it.
        h.queue.drain()
        h.expectInSync(.area(globalRect: CGRect(x: 500, y: 500, width: 40, height: 40), displayID: 1))
    }

    @Test func anOverhangingIncomingAreaIsMovedOntoTheDisplayForEveryPeer() {
        let h = Harness()
        defer { h.cleanUp() }
        let overhang = RecordingTarget.area(globalRect: CGRect(x: 1300, y: 800, width: 300, height: 200), displayID: 1)
        h.coordinator.beginSession(target: overhang, userApp: nil)
        h.queue.drain()
        h.expectInSync(.area(globalRect: CGRect(x: 1140, y: 700, width: 300, height: 200), displayID: 1))
    }

    /// R before the scheduled pass ran still records the normalised rect.
    @Test func recordRightAfterEntryUsesTheNormalisedTarget() async {
        let h = Harness()
        defer { h.cleanUp() }
        let tiny = RecordingTarget.area(globalRect: CGRect(x: 1430, y: 890, width: 2, height: 2), displayID: 1)
        h.coordinator.beginSession(target: tiny, userApp: nil)
        h.overlay.press(.record) // queue not drained
        for _ in 0..<500 where h.pipeline.target == nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let normalised = RecordingTarget.area(globalRect: CGRect(x: 1400, y: 860, width: 40, height: 40), displayID: 1)
        #expect(h.pipeline.target == normalised)
        h.expectInSync(normalised)
        // The late scheduled pass has nothing left to say.
        h.queue.drain()
        h.expectInSync(normalised)
    }

    @Test func aScheduledPassAfterCloseReportsNothing() {
        let h = Harness()
        let tiny = RecordingTarget.area(globalRect: CGRect(x: 500, y: 500, width: 1, height: 1), displayID: 1)
        h.coordinator.beginSession(target: tiny, userApp: nil)
        h.coordinator.handle(.command(.cancel)) // closes the overlay
        var reported: [RecordingEvent] = []
        h.overlay.onEvent = { reported.append($0) }
        h.queue.drain()
        #expect(reported.isEmpty)
        h.cleanUp()
    }

    /// A window target (W) handed back by Retake is never "corrected".
    @Test func aWindowTargetIsNeverRewritten() {
        let h = Harness()
        defer { h.cleanUp() }
        let w = RecordingTarget.window(windowID: 9, frame: CGRect(x: 1300, y: 800, width: 900, height: 600), displayID: 1)
        h.coordinator.beginSession(target: w, userApp: nil)
        h.queue.drain()
        h.expectInSync(w)
    }
}

private extension RecordingPhase {
    var isSnapping: Bool {
        if case .snapping = self { return true }
        return false
    }
}

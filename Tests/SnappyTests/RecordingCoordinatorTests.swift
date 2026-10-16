import AppKit
import Foundation
import Testing
@testable import Snappy

/// The coordinator driven end to end through the protocols with recording
/// fakes — no windows, no ScreenCaptureKit. Proves the seams wave 1 builds on.
@MainActor
@Suite("RecordingCoordinator", .serialized)
struct RecordingCoordinatorTests {
    // MARK: - Fakes

    @MainActor final class Log {
        var entries: [String] = []
        func callAsFunction(_ entry: String) { entries.append(entry) }
    }

    @MainActor final class FakeOverlay: RecordingSetupOverlaying {
        var onEvent: RecordingEventHandler?
        let log: Log
        init(log: Log) { self.log = log }
        func show(_ session: RecordingSession) { log("overlay.show") }
        func apply(_ session: RecordingSession) { log("overlay.apply \(session.phase)") }
        func close() { log("overlay.close") }
    }

    struct Snapshot: LiveInkSetupSnapshot { let id: Int }

    @MainActor final class FakeInk: LiveInkHosting {
        var onEvent: RecordingEventHandler?
        let frameDecorator: any FrameDecorating = NullFrameDecorator()
        let log: Log
        var restored: (any LiveInkSetupSnapshot)?
        var style: InkStyle?
        init(log: Log) { self.log = log }
        func show(_ session: RecordingSession, style: InkStyle, settings: RecordingSettings,
                  restoring snapshot: (any LiveInkSetupSnapshot)?) {
            restored = snapshot
            self.style = style
            log("ink.show")
        }
        func apply(_ session: RecordingSession) { log("ink.mode \(session.inkMode)") }
        func apply(style: InkStyle) { self.style = style; log("ink.style") }
        func perform(_ command: InkCommand) { log("ink.perform \(command)") }
        func setupSnapshot() -> (any LiveInkSetupSnapshot)? { Snapshot(id: 7) }
        func close() { log("ink.close") }
    }

    @MainActor final class FakeChrome: RecordingChromeHosting {
        var onEvent: RecordingEventHandler?
        let log: Log
        var style: InkStyle?
        init(log: Log) { self.log = log }
        func show(_ session: RecordingSession, style: InkStyle) { self.style = style; log("chrome.show") }
        func apply(_ session: RecordingSession) {}
        func apply(style: InkStyle) { self.style = style }
        func captureDidStart() { log("chrome.started") }
        func close() { log("chrome.close") }
    }

    @MainActor final class FakePipeline: RecordingPipelining {
        var onWindowFrameChange: (@MainActor (CGRect) -> Void)?
        var onPartFrameChange: (@MainActor (CGRect) -> Void)?
        var onWindowGone: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        let log: Log
        var url: URL?
        var failStart = false
        /// `start` writes its file, then waits for `finishStart` — the stream
        /// setup being slow.
        var suspendStart = false
        var continuation: CheckedContinuation<Void, any Error>?
        var stops = 0
        var startReturned = false
        /// `endTracking` calls (no AX read after them).
        var trackingEnded = 0
        init(log: Log) { self.log = log }
        func endTracking() { trackingEnded += 1 }
        struct Failure: Error {}
        func start(target: RecordingTarget, settings: RecordingSettings,
                   decorator: any FrameDecorating, outputURL: URL) async throws {
            log("pipeline.start")
            if failStart { throw Failure() }
            url = outputURL
            if suspendStart {
                try Data("partial".utf8).write(to: outputURL) // the writer owns it now
                try await withCheckedThrowingContinuation { continuation = $0 }
            }
            startReturned = true
        }
        func finishStart(_ error: (any Error)? = nil) {
            if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
            continuation = nil
        }
        func stop() async throws -> URL {
            stops += 1
            log("pipeline.stop")
            guard let url, startReturned else { throw Failure() }
            try Data("mp4".utf8).write(to: url)
            return url
        }
    }

    @MainActor final class FakeWindow: RecordingWindowHosting {
        let take: URL
        let anchorRect: CGRect
        let onRetake: (@MainActor () -> Void)?
        let context: RecordingWindowContext
        var isOpen = true
        var shown = false
        var fronted = 0
        var onClose: (@MainActor () -> Void)?
        init(take: URL, anchorRect: CGRect, onRetake: (@MainActor () -> Void)?, context: RecordingWindowContext) {
            self.take = take
            self.anchorRect = anchorRect
            self.onRetake = onRetake
            self.context = context
        }
        func show() { shown = true }
        func bringToFront() { fronted += 1 }
        /// Like the real window: `onClose` a run-loop turn later.
        func close() {
            guard isOpen else { return }
            isOpen = false
            Task { @MainActor in self.onClose?() }
        }
    }

    @MainActor final class Harness {
        let log = Log()
        var windows: [FakeWindow] = []
        var pipelines: [FakePipeline] = []
        var inks: [FakeInk] = []
        var overlays: [FakeOverlay] = []
        var chromes: [FakeChrome] = []
        var failNextStart = false
        var suspendNextStart = false
        var activations = 0
        var snappyActivations = 0
        /// What the window server says about any window a Retake looks up
        /// (off screen = the target stays as it was).
        var windowObservation = WindowObservation.offScreen
        let coordinator: RecordingCoordinator
        let defaults: UserDefaults
        let suiteName = "SnappyTests.RecordingCoordinator.\(UUID().uuidString)"
        let tempStore: RecordingTempStore

        /// Takes an earlier run of the app left in Caches, oldest first.
        private(set) var leftovers: [URL] = []

        init(countdown: RecordingCountdown = .off, leftovers leftoverCount: Int = 0) {
            defaults = UserDefaults(suiteName: suiteName)!
            let settings = SettingsStore(defaults: defaults)
            settings.recordingCountdown = countdown
            tempStore = RecordingTempStore(directory: FileManager.default.temporaryDirectory
                .appending(path: "SnappyCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory))
            for index in 0..<leftoverCount {
                let url = try! tempStore.prepareNewTake()
                try! Data("leftover".utf8).write(to: url)
                try! FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSinceNow: Double(index - leftoverCount) * 60)],
                    ofItemAtPath: url.path(percentEncoded: false)
                )
                leftovers.append(url)
            }
            let box = Box()
            let components = RecordingComponents(
                makeSetupOverlay: { box.harness!.makeOverlay() },
                makeLiveInk: { box.harness!.makeInk() },
                makePipeline: { box.harness!.makePipeline() },
                makeChrome: { box.harness!.makeChrome() },
                makeRecordingWindow: { box.harness!.makeWindow(take: $0, anchorRect: $1, onRetake: $2, context: $3) }
            )
            coordinator = RecordingCoordinator(components: components, settings: settings, tempStore: tempStore)
            box.harness = self
            coordinator.activateUserApp = { _ in box.harness?.activations += 1 }
            coordinator.activateSnappy = { box.harness?.snappyActivations += 1 }
            coordinator.observeWindow = { _ in box.harness?.windowObservation ?? .offScreen }
        }

        final class Box { weak var harness: Harness? }

        func makeOverlay() -> FakeOverlay { let o = FakeOverlay(log: log); overlays.append(o); return o }
        func makeInk() -> FakeInk { let i = FakeInk(log: log); inks.append(i); return i }
        func makeChrome() -> FakeChrome { let c = FakeChrome(log: log); chromes.append(c); return c }
        func makeWindow(
            take: URL, anchorRect: CGRect, onRetake: (@MainActor () -> Void)?, context: RecordingWindowContext
        ) -> FakeWindow {
            let w = FakeWindow(take: take, anchorRect: anchorRect, onRetake: onRetake, context: context)
            windows.append(w)
            return w
        }

        /// The newest recording window.
        var window: FakeWindow? { windows.last }
        /// A recording window is open and shown.
        var isPresenting: Bool { windows.contains { $0.isOpen && $0.shown } }
        func exists(_ url: URL?) -> Bool {
            url.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
        }
        func makePipeline() -> FakePipeline {
            let p = FakePipeline(log: log)
            p.failStart = failNextStart
            p.suspendStart = suspendNextStart
            pipelines.append(p)
            return p
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempStore.directory)
        }
    }

    private let target = RecordingTarget.area(globalRect: CGRect(x: 10, y: 10, width: 320, height: 240), displayID: 1)

    /// Lets the coordinator's main-actor tasks run until `condition` holds.
    private func until(_ condition: () -> Bool, _ comment: Comment? = nil) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition(), comment)
    }

    // MARK: - Tests

    @Test func fullFlowSetupRecordStopWindow() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        var phases: [RecordingPhase?] = []
        h.coordinator.onPhaseChange = { phases.append($0) }

        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        #expect(h.coordinator.isSessionActive)
        #expect(h.log.entries.prefix(3) == ["overlay.show", "ink.show", "chrome.show"])

        // R through the overlay's event sink (countdown off → recording).
        h.overlays[0].onEvent?(.command(.record))
        #expect(h.coordinator.phase == .recording(.interact))
        await until({ h.log.entries.contains("chrome.started") }, "pipeline started → timer")
        #expect(CaptureHotKeyRoute.route(for: h.coordinator.phase) == .stopRecording)

        h.coordinator.stop()
        await until({ h.isPresenting }, "recording window presented")
        #expect(!h.coordinator.isSessionActive)
        #expect(h.window?.take == h.pipelines[0].url)
        #expect(h.window?.onRetake != nil)
        #expect(h.log.entries.contains("overlay.close") && h.log.entries.contains("ink.close")
            && h.log.entries.contains("chrome.close"))
        #expect(phases.first == .setup(.pointer))
        #expect(phases.contains(.stopping))
        #expect(phases.last == .some(nil))
        #expect(h.coordinator.canReopenLastRecording)
    }

    @Test func countdownTicksIntoRecording() async {
        let h = Harness(countdown: .one)
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        #expect(h.coordinator.phase == .countdown(remaining: 1))
        await until({ h.coordinator.phase == .recording(.interact) }, "one tick → recording")
        await until({ h.log.entries.contains("pipeline.start") })
        h.coordinator.handle(.command(.cancel))
    }

    @Test func secondSessionIsBlocked() {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        #expect(!h.coordinator.beginSession(target: target, userApp: nil))
        #expect(h.overlays.count == 1)
    }

    @Test func captureGateBlocksSessions() {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.canBeginSession = { false }
        #expect(!h.coordinator.beginSession(target: target, userApp: nil))
        #expect(!h.coordinator.isSessionActive)
    }

    @Test func escInSetupPointerCancelsAndClosesEverything() {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: target, userApp: nil)
        h.overlays[0].onEvent?(.command(.stepBack))
        #expect(!h.coordinator.isSessionActive)
        #expect(h.log.entries.suffix(3) == ["overlay.close", "ink.close", "chrome.close"])
        #expect(h.pipelines.isEmpty)
        #expect(!h.isPresenting)
    }

    @Test func styleCommandsReachInkAndChromeContentCommandsOnlyInk() {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: target, userApp: nil)
        #expect(h.inks[0].style == InkStyle(settings: RecordingSettings()))
        h.coordinator.handle(.command(.ink(.color(.blue))))
        h.coordinator.handle(.command(.ink(.thicker)))
        let expected = InkStyle(color: .blue, width: .thick, fading: false)
        #expect(h.inks[0].style == expected)
        #expect(h.chromes[0].style == expected)
        h.coordinator.handle(.command(.ink(.undo)))
        #expect(h.log.entries.last == "ink.perform undo")
        h.coordinator.handle(.command(.cancel))
    }

    @Test func retakeRestoresTargetSetupInkAndStyle() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.ink(.color(.green))))
        h.coordinator.handle(.command(.record))
        await until({ h.log.entries.contains("chrome.started") })
        h.coordinator.stop()
        await until({ h.isPresenting })

        h.window?.onRetake?()
        #expect(h.window?.isOpen == false, "Retake closes the window")
        #expect(h.coordinator.phase == .setup(.pointer))
        #expect(h.coordinator.session?.target == target)
        #expect((h.inks[1].restored as? Snapshot)?.id == 7)
        #expect(h.inks[1].style?.color == .green)
        h.coordinator.handle(.command(.cancel))
    }

    @Test func pipelineStartFailureCancelsAndReportsTheError() async {
        let h = Harness()
        defer { h.cleanUp() }
        var errors = 0
        h.coordinator.onError = { _ in errors += 1 }
        h.failNextStart = true
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ !h.coordinator.isSessionActive }, "session ended")
        #expect(errors == 1)
        #expect(!h.isPresenting)
        await until({ h.log.entries.contains("pipeline.stop") }, "cancel stops the stream")
    }

    @Test func windowGoneWhileRecordingStopsAndOpensTheWindow() async {
        let h = Harness()
        defer { h.cleanUp() }
        let window = RecordingTarget.window(windowID: 3, frame: target.frame, displayID: 1)
        h.coordinator.beginSession(target: window, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.log.entries.contains("chrome.started") })
        h.pipelines[0].onWindowFrameChange?(CGRect(x: 50, y: 50, width: 320, height: 240))
        #expect(h.coordinator.session?.target.frame.origin == CGPoint(x: 50, y: 50))
        h.pipelines[0].onWindowGone?()
        await until({ h.isPresenting }, "auto-stop → recording window")
    }

    @Test func cancelWhileRecordingDiscardsThePartialTake() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.log.entries.contains("chrome.started") })
        h.coordinator.handle(.command(.cancel))
        #expect(!h.coordinator.isSessionActive)
        await until({ h.log.entries.contains("pipeline.stop") })
        await until({ h.tempStore.lastTake == nil }, "partial take deleted")
        #expect(!h.isPresenting)
    }

    @Test func reopenWithoutATakeBeeps() {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(!h.coordinator.canReopenLastRecording)
        h.coordinator.reopenLastRecording()
        #expect(!h.isPresenting)
    }

    // MARK: - Review round 1: session scoping (#1)

    private let windowTarget = RecordingTarget.window(
        windowID: 1, frame: CGRect(x: 10, y: 20, width: 300, height: 200), displayID: 1
    )

    @Test func staleWindowCallbackMustNotMoveReplacementSession() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.suspendNextStart = true
        h.coordinator.beginSession(target: windowTarget, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.first?.continuation != nil })
        // Whatever A's pipeline (or a component) kept before teardown.
        let staleFrame = h.pipelines[0].onWindowFrameChange
        let staleGone = h.pipelines[0].onWindowGone
        let staleSink = h.overlays[0].onEvent
        h.coordinator.handle(.command(.cancel))
        #expect(h.pipelines[0].onWindowFrameChange == nil, "callbacks cleared on teardown")
        h.pipelines[0].finishStart()
        await until({ !h.coordinator.isBusy })
        h.suspendNextStart = false
        #expect(h.coordinator.beginSession(target: windowTarget, userApp: nil))

        // B in Setup.
        staleFrame?(CGRect(x: 500, y: 600, width: 300, height: 200))
        staleGone?()
        staleSink?(.command(.cancel))
        #expect(h.coordinator.session?.target == windowTarget)
        #expect(h.coordinator.phase == .setup(.pointer))

        // B recording.
        h.coordinator.handle(.command(.record))
        await until({ h.log.entries.contains("chrome.started") })
        staleFrame?(CGRect(x: 500, y: 600, width: 300, height: 200))
        staleGone?()
        staleSink?(.command(.stop))
        #expect(h.coordinator.session?.target == windowTarget)
        #expect(h.coordinator.phase == .recording(.interact))
        h.coordinator.handle(.command(.cancel))
    }

    @Test func failedOldStartMustNotShowErrorDuringReplacementSetup() async {
        let h = Harness()
        defer { h.cleanUp() }
        var errors = 0
        h.coordinator.onError = { _ in errors += 1 }
        h.suspendNextStart = true
        h.coordinator.beginSession(target: windowTarget, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.first?.continuation != nil })
        let staleFailure = h.pipelines[0].onFailure
        h.coordinator.handle(.command(.cancel))
        h.pipelines[0].finishStart(FakePipeline.Failure())
        await until({ !h.coordinator.isBusy })
        #expect(errors == 0)
        h.suspendNextStart = false
        #expect(h.coordinator.beginSession(target: windowTarget, userApp: nil))
        staleFailure?(FakePipeline.Failure())
        #expect(errors == 0)
        #expect(h.coordinator.phase == .setup(.pointer))
        h.coordinator.handle(.command(.cancel))
    }

    @Test func staleSinksAreDroppedAfterAFinishedSessionToo() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: target, userApp: nil)
        let staleChrome = h.chromes[0].onEvent
        h.coordinator.handle(.command(.record))
        await until({ h.log.entries.contains("chrome.started") })
        h.coordinator.stop()
        await until({ h.isPresenting })
        #expect(h.chromes[0].onEvent == nil)
        h.window?.onRetake?()
        staleChrome?(.command(.stepBack)) // would cancel B's Setup if it leaked
        #expect(h.coordinator.phase == .setup(.pointer))
        h.coordinator.handle(.command(.cancel))
    }

    // MARK: - Review round 1: draining (#2)

    @Test func cancelDuringSuspendedStartStopsExactlyOnceAfterStart() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.suspendNextStart = true
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.first?.continuation != nil })
        h.coordinator.handle(.command(.cancel))
        #expect(!h.coordinator.isSessionActive)
        #expect(h.log.entries.contains("overlay.close"), "UI ordered out at once")
        #expect(h.coordinator.isBusy, "still draining")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.pipelines[0].stops == 0, "no stop while start is pending")
        h.pipelines[0].finishStart()
        await until({ !h.coordinator.isBusy })
        #expect(h.pipelines[0].stops == 1)
        #expect(h.tempStore.lastTake == nil, "cancelled take discarded")
    }

    @Test func restartBeforeCleanupIsBlockedAndTheWritersFileSurvives() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        h.suspendNextStart = true
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.first?.continuation != nil })
        let owned = try #require(h.pipelines[0].url)
        h.coordinator.handle(.command(.cancel))

        #expect(!h.coordinator.beginSession(target: target, userApp: nil), "blocked while draining")
        #expect(!h.coordinator.canReopenLastRecording)
        #expect(h.overlays.count == 1, "no second session")
        #expect(FileManager.default.fileExists(atPath: owned.path(percentEncoded: false)))

        h.pipelines[0].finishStart()
        await until({ !h.coordinator.isBusy })
        #expect(h.pipelines[0].stops == 1)
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.cancel))
    }

    @Test func midRecordingFailureEndsTheSessionReportsOnceAndDiscards() async {
        let h = Harness()
        defer { h.cleanUp() }
        var errors = 0
        h.coordinator.onError = { _ in errors += 1 }
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.log.entries.contains("chrome.started") })
        h.pipelines[0].onFailure?(FakePipeline.Failure())
        #expect(!h.coordinator.isSessionActive)
        #expect(errors == 1)
        await until({ !h.coordinator.isBusy })
        #expect(h.pipelines[0].stops == 1)
        #expect(h.tempStore.lastTake == nil)
        #expect(!h.isPresenting)
    }

    // MARK: - Magic Pen

    @Test func magicPenTogglesTheInkAndHandsTheKeyboardBackOnlyWhenLeaving() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.toggleMagicPen))
        #expect(h.coordinator.phase == .setup(.pointer), "ignored in Setup")
        h.coordinator.handle(.command(.record))
        await until({ h.log.entries.contains("chrome.started") })
        #expect(h.activations == 1)

        h.inks[0].onEvent?(.command(.toggleMagicPen))
        #expect(h.coordinator.phase == .recording(.magicPen(resume: nil)))
        #expect(h.log.entries.last == "ink.mode magicPen")
        #expect(h.activations == 1, "no hand-back while drawing with the Magic Pen")

        // Esc (from the ink panel's key map) goes back to interact.
        h.inks[0].onEvent?(.command(.stepBack))
        #expect(h.coordinator.phase == .recording(.interact))
        #expect(h.activations == 2, "Magic Pen → interact hands the keyboard back")

        // From draw mode and back: no hand-back at all.
        h.coordinator.handle(.command(.tool(.arrow)))
        h.coordinator.handle(.command(.toggleMagicPen))
        h.coordinator.handle(.command(.toggleMagicPen))
        #expect(h.coordinator.phase == .recording(.draw(.arrow)))
        #expect(h.activations == 2)

        h.coordinator.handle(.command(.toggleMagicPen))
        h.coordinator.stop()
        await until({ h.isPresenting }, "Stop from Magic Pen finishes the take")
        #expect(h.snappyActivations == 1)
    }

    @Test func magicPenBracketsChangeAndPersistItsThicknessOnly() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        h.coordinator.handle(.command(.toggleMagicPen))
        h.inks[0].onEvent?(.command(.ink(.magicPenThicker)))
        #expect(h.inks[0].style?.magicPenWidth == .thick)
        #expect(h.chromes[0].style?.magicPenWidth == .thick)
        #expect(h.inks[0].style?.width == .medium, "the line width is untouched")
        #expect(SettingsStore(defaults: h.defaults).recordingMagicPenWidth == .thick, "persisted")
        #expect(h.coordinator.magicPenWidth == .thick)
        // The normal [ ] don't persist anything.
        h.coordinator.handle(.command(.ink(.thinner)))
        #expect(SettingsStore(defaults: h.defaults).recordingDefaultWidth == .medium)
        h.coordinator.handle(.command(.cancel))
    }

    @Test func menuBarThicknessIsPersistedAndAppliedLiveInAnyPhase() async {
        let h = Harness()
        defer { h.cleanUp() }
        // No session: just the setting.
        h.coordinator.setMagicPenWidth(.thin)
        #expect(SettingsStore(defaults: h.defaults).recordingMagicPenWidth == .thin)
        #expect(h.coordinator.magicPenWidth == .thin)

        h.coordinator.beginSession(target: target, userApp: nil)
        #expect(h.inks[0].style?.magicPenWidth == .thin, "a session starts with the setting")
        h.coordinator.handle(.command(.record))
        h.coordinator.setMagicPenWidth(.thick)
        #expect(h.inks[0].style?.magicPenWidth == .thick)
        #expect(h.chromes[0].style?.magicPenWidth == .thick)
        let pushes = h.log.entries.filter { $0 == "ink.style" }.count
        h.coordinator.setMagicPenWidth(.thick)
        #expect(h.log.entries.filter { $0 == "ink.style" }.count == pushes, "unchanged: no push")
        #expect(h.coordinator.phase == .recording(.interact), "the phase is untouched")
        h.coordinator.handle(.command(.cancel))
    }

    /// Review should-fix: the Settings pop-up goes through the same live
    /// path as the menu bar, and an open Settings window follows changes
    /// made elsewhere (wired as in `StatusItemController`).
    @Test func settingsThicknessIsAppliedLiveAndFollowsOtherChanges() async {
        let h = Harness()
        defer { h.cleanUp() }
        let section = RecordingSettingsSection(
            settings: SettingsStore(defaults: h.defaults),
            setMagicPenWidth: h.coordinator.setMagicPenWidth
        )
        section.syncFromSettings()
        var reported: [InkWidth] = []
        h.coordinator.onMagicPenWidthChange = { width in
            reported.append(width)
            section.showMagicPenWidth(width)
        }
        let popUp = section.magicPenWidthPopUp
        func choose(_ width: InkWidth) {
            popUp.selectItem(at: InkWidth.allCases.firstIndex(of: width)!)
            _ = section.perform(popUp.action, with: popUp) // the pop-up's own action
        }
        func shown() -> InkWidth { InkWidth.allCases[popUp.indexOfSelectedItem] }

        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        h.coordinator.handle(.command(.toggleMagicPen))
        #expect(h.inks[0].style?.magicPenWidth == .medium)

        choose(.thin) // Settings, during the session
        #expect(h.inks[0].style?.magicPenWidth == .thin, "the next stroke is thin")
        #expect(h.chromes[0].style?.magicPenWidth == .thin, "the toolbar's Width shows thin")
        #expect(SettingsStore(defaults: h.defaults).recordingMagicPenWidth == .thin, "persisted")
        #expect(h.coordinator.magicPenWidth == .thin, "the menu bar's checkmark")

        h.inks[0].onEvent?(.command(.ink(.magicPenThicker))) // ] steps from thin, not the old medium
        #expect(h.inks[0].style?.magicPenWidth == .medium)
        #expect(SettingsStore(defaults: h.defaults).recordingMagicPenWidth == .medium)
        #expect(shown() == .medium, "the open Settings pop-up follows ]")

        h.coordinator.setMagicPenWidth(.thick) // menu bar
        #expect(shown() == .thick, "… and the menu bar")
        h.coordinator.setMagicPenWidth(.thick)
        #expect(reported == [.thin, .medium, .thick], "reported once per actual change")
        h.coordinator.handle(.command(.cancel))
    }

    @Test func retakeKeepsItsStyleButTakesTheCurrentMagicPenThickness() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.ink(.color(.yellow))))
        h.coordinator.handle(.command(.record))
        await until({ h.log.entries.contains("chrome.started") })
        h.coordinator.stop()
        await until({ h.isPresenting })
        h.coordinator.setMagicPenWidth(.thick) // changed from the menu bar meanwhile

        h.window?.onRetake?()
        #expect(h.inks[1].style?.color == .yellow)
        #expect(h.inks[1].style?.magicPenWidth == .thick)
        h.coordinator.handle(.command(.cancel))
    }

    // MARK: - Review round 1: delayed start (#3)

    @Test func drawToggleDuringStartIsNotUndoneByTheStartCompletion() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.suspendNextStart = true
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        #expect(h.activations == 1, "record start hands the keyboard back")
        await until({ h.pipelines.first?.continuation != nil })
        h.coordinator.handle(.command(.toggleDrawMode))
        #expect(h.coordinator.phase == .recording(.draw(.pen)))
        h.pipelines[0].finishStart()
        await until({ h.log.entries.contains("chrome.started") }, "timer still starts in draw mode")
        #expect(h.activations == 1, "no reactivation while drawing")
        h.coordinator.handle(.command(.toggleDrawMode))
        #expect(h.activations == 2, "draw → interact hands it back")
        h.coordinator.handle(.command(.cancel))
    }

    @Test func immediateStopDuringStartNeverStartsTheTimer() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.suspendNextStart = true
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.first?.continuation != nil })
        h.coordinator.stop()
        #expect(h.coordinator.phase == .stopping)
        #expect(CaptureHotKeyRoute.route(for: h.coordinator.phase) == .ignore)
        h.pipelines[0].finishStart()
        await until({ h.isPresenting })
        #expect(!h.log.entries.contains("chrome.started"))
        #expect(h.pipelines[0].stops == 1)
        #expect(h.activations == 1)
    }

    // MARK: - Q18 regression (T5 contract)

    @Test func retakeThenCancelledSetupKeepsTheOldTake() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.log.entries.contains("chrome.started") })
        h.coordinator.stop()
        await until({ h.isPresenting })
        let take = try #require(h.window?.take)

        h.window?.onRetake?()
        h.coordinator.handle(.command(.stepBack)) // Esc in Setup Pointer → cancel
        #expect(!h.coordinator.isBusy)
        try? await Task.sleep(for: .milliseconds(20)) // the window's close lands
        #expect(h.tempStore.lastTake?.standardizedFileURL == take.standardizedFileURL)
        #expect(h.coordinator.canReopenLastRecording)
    }

    // MARK: - v2: recording windows and take lifetime (Q28–Q32, Q43)

    /// Setup → record → stop on `target`; returns the take's new window.
    private func recordTake(_ h: Harness, on target: RecordingTarget? = nil) async throws -> FakeWindow {
        let windows = h.windows.count, pipelines = h.pipelines.count
        #expect(h.coordinator.beginSession(target: target ?? self.target, userApp: nil))
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.count == pipelines + 1 && h.pipelines.last?.startReturned == true })
        h.coordinator.stop()
        await until({ h.windows.count == windows + 1 }, "a window per take")
        let window = try #require(h.window)
        #expect(window.shown && window.isOpen)
        return window
    }

    /// Lets a window's deferred `onClose` land.
    private func settleClose() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func twoRecordingsInARowKeepBothWindowsAndTheirTakes() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let first = try await recordTake(h)
        let second = try await recordTake(h)

        #expect(first.isOpen && second.isOpen, "a new recording doesn't close the older window")
        #expect(first.take != second.take)
        #expect(h.exists(first.take) && h.exists(second.take), "nor delete its take")

        first.close()
        await until({ !h.exists(first.take) }, "closing the older window deletes its take")
        second.close()
        await settleClose()
        #expect(h.exists(second.take), "the latest survives its window, for Reopen")
        #expect(h.coordinator.canReopenLastRecording)
    }

    @Test func reopenFrontsTheOpenWindowAndNeverOpensASecondCopy() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let window = try await recordTake(h)

        h.coordinator.reopenLastRecording()
        h.coordinator.reopenLastRecording()
        #expect(h.windows.count == 1)
        #expect(window.fronted == 2)
    }

    @Test func reopenAfterCloseOpensANewWindowThatCanStillRetake() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let window = try await recordTake(h)
        window.close()
        await settleClose()

        h.coordinator.reopenLastRecording()
        #expect(h.windows.count == 2)
        let reopened = try #require(h.window)
        #expect(reopened.take == window.take && reopened.shown && reopened.isOpen)
        #expect(reopened.anchorRect == target.frame)
        #expect(reopened.onRetake != nil)
        reopened.onRetake?()
        #expect(h.coordinator.session?.target == target)
        h.coordinator.handle(.command(.cancel))
    }

    @Test func aNewTakeDeletesThePreviousLatestOnlyOnceItsWindowIsClosed() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let first = try await recordTake(h)
        first.close()
        await settleClose()
        #expect(h.exists(first.take), "still the latest")

        // Setup, recording and stopping don't touch it …
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.count == 2 && h.pipelines[1].startReturned })
        #expect(h.exists(first.take))
        h.coordinator.stop()
        await until({ h.windows.count == 2 })
        // … only the newer *finished* take releases it.
        #expect(!h.exists(first.take))
        #expect(h.exists(h.window?.take))
    }

    @Test func aCancelledRecordingKeepsTheLatestTakeReopenable() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let first = try await recordTake(h)
        first.close()
        await settleClose()

        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.count == 2 && h.pipelines[1].startReturned })
        h.coordinator.handle(.command(.cancel))
        await until({ !h.coordinator.isBusy })

        #expect(h.exists(first.take))
        #expect(!h.exists(h.pipelines[1].url), "the cancelled take is discarded")
        #expect(h.coordinator.canReopenLastRecording)
        h.coordinator.reopenLastRecording()
        #expect(h.window?.take == first.take)
    }

    @Test func retakeIsRefusedWhileASessionIsBusyAndTheWindowStays() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let window = try await recordTake(h)

        #expect(h.coordinator.beginSession(target: target, userApp: nil)) // a new Setup
        window.onRetake?()
        #expect(window.isOpen)
        #expect(h.overlays.count == 2, "no second session")
        h.coordinator.handle(.command(.cancel))

        h.coordinator.canBeginSession = { false } // a screenshot capture in flight
        window.onRetake?()
        #expect(window.isOpen)
        #expect(!h.coordinator.isSessionActive)
    }

    @Test func retakingAnOlderWindowUsesItsOwnTargetAndReleasesItsTake() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let other = RecordingTarget.area(globalRect: CGRect(x: 400, y: 300, width: 200, height: 100), displayID: 1)
        let first = try await recordTake(h, on: target)
        let second = try await recordTake(h, on: other)

        first.onRetake?()
        #expect(!first.isOpen && second.isOpen)
        #expect(h.coordinator.session?.target == target)
        await until({ !h.exists(first.take) }, "not the latest: released when its window closed")
        #expect(h.exists(second.take))
        h.coordinator.handle(.command(.cancel))
    }

    @Test func afterARelaunchTheNewestLeftoverReopensWithoutRetakeAndTheRestIsPruned() async throws {
        let h = Harness(leftovers: 2)
        defer { h.cleanUp() }
        let (older, newest) = (h.leftovers[0], h.leftovers[1])

        #expect(h.coordinator.canReopenLastRecording)
        h.coordinator.reopenLastRecording()
        let reopened = try #require(h.window)
        #expect(reopened.take.standardizedFileURL == newest.standardizedFileURL)
        #expect(reopened.onRetake == nil, "no target or setup ink from an earlier run")

        // The next finished take prunes the leftovers nobody shows.
        let window = try await recordTake(h)
        #expect(!h.exists(older))
        #expect(h.exists(newest), "its window is open")
        reopened.close()
        await until({ !h.exists(newest) })
        #expect(h.exists(window.take))
    }

    // MARK: - Fix round 1: focus and saved files

    /// Finding 2: the stop interaction itself asks for activation, before the
    /// asynchronous finalisation — so the window can open with focus.
    @Test func everyStopAsksForActivationOnceBeforeTheTakeIsFinalised() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.cancel))
        #expect(h.snappyActivations == 0, "a cancelled Setup never activates")

        h.coordinator.beginSession(target: target, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.last?.startReturned == true })
        #expect(h.snappyActivations == 0, "recording hands the keyboard to the user's app")
        h.coordinator.stop()
        #expect(h.snappyActivations == 1, "synchronously, inside the stop")
        #expect(h.windows.isEmpty, "before the take is finalised")
        h.coordinator.stop() // ignored while stopping
        await until({ h.isPresenting })
        #expect(h.snappyActivations == 1)

        // W-window auto-stop asks too.
        let window = RecordingTarget.window(windowID: 3, frame: target.frame, displayID: 1)
        h.coordinator.beginSession(target: window, userApp: nil)
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.count == 2 && h.pipelines[1].startReturned })
        h.pipelines[1].onWindowGone?()
        #expect(h.snappyActivations == 2)
        await until({ h.windows.count == 2 })
    }

    /// Finding 1: a window's pending focus request is dropped while a newer
    /// recording session or a screenshot capture runs.
    @Test func windowsMayTakeFocusOnlyWhileNothingNewerRuns() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let window = try await recordTake(h)
        #expect(window.context.mayTakeFocus())

        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        #expect(!window.context.mayTakeFocus(), "a newer session (Setup, recording B)")
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.count == 2 && h.pipelines[1].startReturned })
        h.coordinator.handle(.command(.cancel))
        #expect(!window.context.mayTakeFocus(), "still draining")
        await until({ !h.coordinator.isBusy })
        #expect(window.context.mayTakeFocus())

        h.coordinator.canBeginSession = { false } // a frozen screenshot capture in flight
        #expect(!window.context.mayTakeFocus())
    }

    /// Finding 3: every window — a reopened one too — shares the take-level
    /// saved files, and the coordinator forgets the takes it deletes.
    @Test func savedFilesOutliveTheWindowAndGoWithTheTake() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let first = try await recordTake(h)
        let saved = h.tempStore.directory.appending(path: "Saved.mp4")
        try Data("saved".utf8).write(to: saved)
        first.context.savedFiles.record(saved, for: first.take)
        first.close()
        await settleClose()

        h.coordinator.reopenLastRecording()
        let reopened = try #require(h.window)
        #expect(reopened !== first)
        #expect(reopened.context.savedFiles.savedFile(for: reopened.take) == saved)

        // A newer take releases the first once its window closes — and its
        // saved-file entry with it.
        _ = try await recordTake(h)
        reopened.close()
        await until({ !h.exists(first.take) })
        #expect(reopened.context.savedFiles.savedFile(for: first.take) == nil)
    }

    @Test func reopenBeepsWhenTheLatestTakeWasPurged() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let window = try await recordTake(h)
        window.close()
        await settleClose()
        try FileManager.default.removeItem(at: window.take) // Caches purged

        #expect(!h.coordinator.canReopenLastRecording)
        h.coordinator.reopenLastRecording()
        #expect(h.windows.count == 1)
    }
}

@Suite("CaptureActivity")
struct CaptureActivityTests {
    @Test func idleBlocksNothing() {
        let idle = CaptureActivity()
        #expect(!idle.blocksCapture && !idle.blocksRecording && !idle.dropsCaptureResult)
    }

    @Test func captureSessionsBlockBothAsBefore() {
        let flags: [WritableKeyPath<CaptureActivity, Bool>] = [
            \.areaCaptureInFlight, \.areaSelectionOpen, \.windowPickInFlight, \.windowPickOpen,
        ]
        for flag in flags {
            var activity = CaptureActivity()
            activity[keyPath: flag] = true
            #expect(activity.blocksCapture && activity.blocksRecording)
        }
    }

    @Test func pendingResultsBlockRecordingButNotScreenshots() {
        // Unchanged screenshot behaviour: a second ⇧⌘3 / ⇧⌘4 while a
        // fullscreen or post-pick window capture finishes still works.
        for flag in [\CaptureActivity.windowCaptureInFlight, \.fullscreenCaptureInFlight] {
            var activity = CaptureActivity()
            activity[keyPath: flag] = true
            #expect(!activity.blocksCapture)
            #expect(activity.blocksRecording)
        }
    }

    @Test func aBusyRecordingBlocksCapturesAndDropsLateResults() {
        let activity = CaptureActivity(recordingBusy: true)
        #expect(activity.blocksCapture && activity.blocksRecording && activity.dropsCaptureResult)
    }
}

/// Review round 2 (#5): several fullscreen or post-pick window captures may be
/// pending at once; the recording gate must hold until the *last* one ends.
@MainActor
@Suite("PendingCaptures")
struct PendingCapturesTests {
    /// One pending request's work: suspends until the test resumes it.
    @MainActor final class Request {
        private var continuation: CheckedContinuation<Void, any Error>?
        var isWaiting: Bool { continuation != nil }
        func work() async throws {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish(failing: Bool) {
            if failing { continuation?.resume(throwing: Failure()) } else { continuation?.resume() }
            continuation = nil
        }
    }

    struct Failure: Error {}

    enum Exit: CaseIterable { case success, error }

    /// The coordinator's derivation of the gate.
    private func activity(_ pending: PendingCaptures) -> CaptureActivity {
        CaptureActivity(
            windowCaptureInFlight: pending.isPending(.window),
            fullscreenCaptureInFlight: pending.isPending(.fullscreen)
        )
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test(arguments: [PendingCaptures.Kind.fullscreen, .window], [false, true])
    func twoConcurrentRequestsHoldTheGateUntilTheLastEnds(kind: PendingCaptures.Kind, reversed: Bool) async {
        for first in Exit.allCases {
            for second in Exit.allCases {
                let pending = PendingCaptures()
                let a = Request(), b = Request()
                // Begun synchronously, like the coordinator, before any await.
                let tokenA = pending.begin(kind)
                let tokenB = pending.begin(kind)
                let taskA = Task { try await pending.finishing(tokenA) { try await a.work() } }
                let taskB = Task { try await pending.finishing(tokenB) { try await b.work() } }
                await settle { a.isWaiting && b.isWaiting }
                #expect(activity(pending).blocksRecording)
                #expect(!activity(pending).blocksCapture, "a second screenshot may still start")

                let (early, late) = reversed ? (b, a) : (a, b)
                let (earlyTask, lateTask) = reversed ? (taskB, taskA) : (taskA, taskB)
                early.finish(failing: first == .error)
                _ = await earlyTask.result
                #expect(pending.isPending(kind), "\(kind) \(first)/\(second) reversed=\(reversed): still one left")
                #expect(activity(pending).blocksRecording)

                late.finish(failing: second == .error)
                _ = await lateTask.result
                #expect(!pending.isPending(kind), "\(kind) \(first)/\(second) reversed=\(reversed): all done")
                #expect(!activity(pending).blocksRecording)
                #expect(pending.isEmpty)
            }
        }
    }

    @Test func kindsAreTrackedIndependently() async {
        let pending = PendingCaptures()
        let screen = Request(), window = Request()
        let screenToken = pending.begin(.fullscreen)
        let windowToken = pending.begin(.window)
        let screenTask = Task { try await pending.finishing(screenToken) { try await screen.work() } }
        let windowTask = Task { try await pending.finishing(windowToken) { try await window.work() } }
        await settle { screen.isWaiting && window.isWaiting }

        screen.finish(failing: false)
        _ = await screenTask.result
        #expect(!pending.isPending(.fullscreen))
        #expect(pending.isPending(.window))
        #expect(activity(pending).blocksRecording)

        window.finish(failing: true)
        _ = await windowTask.result
        #expect(!activity(pending).blocksRecording)
    }

    @Test func earlyReturnEndsTheToken() async {
        let pending = PendingCaptures()
        let token = pending.begin(.fullscreen)
        // Like `guard let screen = screenUnderMouse() else { return }`.
        await pending.finishing(token) { () async -> Void in return }
        #expect(!pending.isPending(.fullscreen))
    }

    @Test func endIsIdempotentAndTokensAreDistinct() {
        let pending = PendingCaptures()
        let a = pending.begin(.window)
        let b = pending.begin(.window)
        #expect(a != b)
        pending.end(a)
        pending.end(a) // a second end of the same token can't release b
        #expect(pending.isPending(.window))
        pending.end(b)
        #expect(pending.isEmpty)
    }
}

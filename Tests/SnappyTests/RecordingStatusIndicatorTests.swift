import Carbon.HIToolbox
import AppKit
import Foundation
import Testing
@testable import Snappy

/// 2026-10-09: while recording, the menu bar shows a red ● and the
/// elapsed time (`● 0:42`), ticking once per second on the toolbar timer's
/// clock; a click stops.
@Suite("Recording menu bar indicator")
struct RecordingStatusIndicatorTests {
    @Test("Compact time: m:ss under an hour, h:mm:ss past it; the toolbar keeps mm:ss")
    func compactTime() {
        #expect(RecordingTimerText.compact(elapsed: 0) == "0:00")
        #expect(RecordingTimerText.compact(elapsed: 42.9) == "0:42") // whole seconds, like the toolbar
        #expect(RecordingTimerText.compact(elapsed: 725) == "12:05")
        #expect(RecordingTimerText.compact(elapsed: 3599) == "59:59")
        #expect(RecordingTimerText.compact(elapsed: 3723) == "1:02:03")
        #expect(RecordingTimerText.compact(elapsed: -3) == "0:00")
        #expect(RecordingTimerText.string(elapsed: 42.9) == "00:42") // unchanged
        #expect(RecordingTimerText.string(elapsed: 3723) == "1:02:03")
    }

    @Test("Title and VoiceOver label")
    func titleAndLabel() {
        #expect(RecordingStatusGlyph.title(elapsed: 42) == "0:42")
        #expect(RecordingStatusGlyph.title(elapsed: 3723) == "1:02:03")
        #expect(RecordingStatusGlyph.accessibilityLabel(elapsed: 42) == "Recording, 0:42, click to stop")
        #expect(RecordingStatusGlyph.symbolName == "circle.fill")
        #expect(RecordingStatusGlyph.toolTip(stopCombo: .defaultCapture) == "Stop recording (⇧⌘4)")
    }

    @Test("Ticks land on whole seconds since the start, once per second")
    func ticksOnTheSecond() {
        #expect(RecordingStatusGlyph.delayUntilNextTick(elapsed: 0) == 1)
        #expect(abs(RecordingStatusGlyph.delayUntilNextTick(elapsed: 41.75) - 0.25) < 1e-9)
        #expect(abs(RecordingStatusGlyph.delayUntilNextTick(elapsed: 42.001) - 0.999) < 1e-9)
        // Simulated: the readout changes exactly once per second.
        var elapsed = 0.3, shown: [String] = []
        while elapsed < 5 {
            shown.append(RecordingStatusGlyph.title(elapsed: elapsed))
            elapsed += RecordingStatusGlyph.delayUntilNextTick(elapsed: elapsed)
        }
        #expect(shown == ["0:00", "0:01", "0:02", "0:03", "0:04"])
    }
}

/// T7 review round 2 #2: the indicator's wiring — `StatusItemController` on a
/// stand-in status item, driven by the real `RecordingCoordinator` (with the
/// coordinator suite's fake pieces) and a test clock that steps whole seconds.
@MainActor
@Suite("StatusItemController — recording indicator", .serialized)
struct StatusItemControllerRecordingTests {
    /// The `NSStatusItem` surface the controller touches, as the app creates
    /// it: square, an untitled button.
    @MainActor final class FakeStatusItem: StatusItemHosting {
        var length = NSStatusItem.squareLength
        var menu: NSMenu?
        let button: NSStatusBarButton? = NSStatusBarButton(frame: .zero)
        init() { button?.title = "" }
    }

    /// Time moves only when a test says so; the readout's sleeps wait for it.
    @MainActor final class TestClock {
        var now = ContinuousClock.now
        private var sleepers: [CheckedContinuation<Void, Never>] = []

        var ticker: StatusItemTicker {
            StatusItemTicker(
                now: { [weak self] in self?.now ?? .now },
                sleep: { [weak self] duration in
                    guard let self else { try? await Task.sleep(for: duration); return }
                    await withCheckedContinuation { self.sleepers.append($0) }
                }
            )
        }

        func advance(seconds: Int) {
            now += .seconds(seconds)
            wakeSleepers()
        }

        func wakeSleepers() {
            let waking = sleepers
            sleepers = []
            waking.forEach { $0.resume() }
        }
    }

    @MainActor final class Fixture {
        let harness = RecordingCoordinatorTests.Harness()
        let item = FakeStatusItem()
        let clock = TestClock()
        let controller: StatusItemController
        let hotKeys: GlobalHotKeys
        var errors = 0
        private let defaults: UserDefaults
        private let suiteName = "SnappyTests.StatusItem.\(UUID().uuidString)"
        private let captureCoordinator: CaptureCoordinator

        init(center: GlobalHotKeysTests.Center? = nil) {
            defaults = UserDefaults(suiteName: suiteName)!
            captureCoordinator = CaptureCoordinator(settings: SettingsStore(defaults: defaults), recording: harness.coordinator)
            hotKeys = GlobalHotKeys(settings: SettingsStore(defaults: defaults), center: center)
            controller = StatusItemController(
                captureCoordinator: captureCoordinator, recordingCoordinator: harness.coordinator,
                globalHotKeys: hotKeys, statusItem: item, ticker: clock.ticker
            )
            // No alert in tests; count the reports instead.
            harness.coordinator.onError = { [weak self] _ in self?.errors += 1 }
            // The coordinator reports the real instant capture started; the
            // readout gets the test clock's "now" at that same moment.
            let report = harness.coordinator.onCaptureStart
            let clock = clock
            harness.coordinator.onCaptureStart = { _ in report?(clock.now) }
        }

        var button: NSStatusBarButton { item.button! }

        func record() -> Bool {
            let target = RecordingTarget.area(globalRect: CGRect(x: 10, y: 10, width: 320, height: 240), displayID: 1)
            guard harness.coordinator.beginSession(target: target, userApp: nil) else { return false }
            harness.coordinator.handle(.command(.record))
            return true
        }

        /// The click on the menu bar item: the button's own target/action,
        /// sent the way AppKit does (`performClick` needs a running app's
        /// tracking loop).
        func click() {
            guard let action = button.action else { return }
            NSApplication.shared.sendAction(action, to: button.target, from: button)
        }

        func cleanUp() {
            harness.coordinator.handle(.command(.cancel)) // no-op unless a test failed mid-session
            clock.wakeSleepers()
            harness.cleanUp()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// Lets main-actor tasks run until `condition` holds.
    private func until(_ condition: () -> Bool, _ comment: Comment? = nil) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition(), comment)
    }

    /// Lets main-actor tasks run for a moment (for things that must *not* happen).
    private func settle() async {
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(2)) }
    }

    /// The "S" item: square, its menu, no title, no action, no recording label.
    private func expectNormal(_ f: Fixture, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(f.item.length == NSStatusItem.squareLength, comment, sourceLocation: sourceLocation)
        #expect(f.item.menu?.items.filter { !$0.isSeparatorItem }.count == StatusMenuCommand.allCases.count + 1,  // + the disabled version footer
                comment, sourceLocation: sourceLocation)
        #expect(f.button.title.isEmpty, comment, sourceLocation: sourceLocation)
        #expect(f.button.imagePosition == .imageOnly, comment, sourceLocation: sourceLocation)
        #expect(f.button.image?.isTemplate == true, comment, sourceLocation: sourceLocation)
        #expect(f.button.action == nil && f.button.toolTip == nil, comment, sourceLocation: sourceLocation)
        #expect(!(f.button.accessibilityLabel() ?? "").hasPrefix("Recording"), comment, sourceLocation: sourceLocation)
    }

    /// The red ● with `title` beside it; a click stops.
    private func expectRecording(
        _ f: Fixture, _ title: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(f.item.length == NSStatusItem.variableLength, sourceLocation: sourceLocation)
        #expect(f.item.menu == nil, sourceLocation: sourceLocation)
        #expect(f.button.title == title, sourceLocation: sourceLocation)
        #expect(f.button.accessibilityLabel() == "Recording, \(title), click to stop", sourceLocation: sourceLocation)
        #expect(f.button.image?.isTemplate == false, sourceLocation: sourceLocation)
        #expect(f.button.imagePosition == .imageLeading, sourceLocation: sourceLocation)
        #expect(f.button.toolTip == RecordingStatusGlyph.toolTip(stopCombo: f.hotKeys.liveStopCombo),
                sourceLocation: sourceLocation)
        #expect(f.button.target === f.controller && f.button.action != nil, sourceLocation: sourceLocation)
    }

    @Test("The red ● names Stop's combo only while it is live: refused at launch, retried, lost on a resume")
    func stopToolTipFollowsCaptureHotKeyLiveness() async {
        let center = GlobalHotKeysTests.Center()
        center.unbound = [.captureArea] // another app owned ⇧⌘4 at launch
        let f = Fixture(center: center)
        defer { f.cleanUp() }
        #expect(f.record())
        #expect(f.hotKeys.liveStopCombo == nil)
        #expect(f.button.toolTip == "Stop recording")
        f.hotKeys.retryUnbound() // the other app let go
        #expect(f.button.toolTip == "Stop recording (⇧⌘4)")
        f.hotKeys.setRecorderActive(true)
        center.unbound = [.captureArea] // taken while the recorder paused it
        f.hotKeys.setRecorderActive(false)
        #expect(f.button.toolTip == "Stop recording")
        f.harness.coordinator.handle(.command(.cancel))
    }

    @Test func showsZeroOnCaptureStartTicksAndAClickStops() async {
        let f = Fixture()
        defer { f.cleanUp() }
        expectNormal(f, "before any session")
        let target = RecordingTarget.area(globalRect: CGRect(x: 10, y: 10, width: 320, height: 240), displayID: 1)
        #expect(f.harness.coordinator.beginSession(target: target, userApp: nil))
        expectNormal(f, "Setup is not recording")

        f.harness.coordinator.handle(.command(.record))
        expectRecording(f, "0:00") // at once, before the stream is up
        await until({ f.harness.log.entries.contains("chrome.started") }, "capture started")
        expectRecording(f, "0:00")
        f.clock.advance(seconds: 1)
        await until({ f.button.title == "0:01" }, "ticks once per second")
        expectRecording(f, "0:01")
        f.clock.advance(seconds: 1)
        await until({ f.button.title == "0:02" })
        f.clock.advance(seconds: 61)
        await until({ f.button.title == "1:03" })
        expectRecording(f, "1:03")
        // Draw mode is still recording.
        f.harness.coordinator.handle(.command(.toggleDrawMode))
        expectRecording(f, "1:03")

        f.click()
        #expect(f.harness.coordinator.phase == .stopping || f.harness.coordinator.phase == nil)
        expectNormal(f, "back to the S item as soon as Stop is sent")
        await until({ f.harness.isPresenting }, "the click stopped the recording")
        f.clock.advance(seconds: 1)
        await settle()
        expectNormal(f, "no stale tick after Stop")
    }

    /// Review r1 #4: the ●'s tooltip names the live Capture Area combo — read
    /// on entering recording, and updated when it is remapped mid-session.
    @Test func theStopTooltipFollowsTheCaptureAreaCombo() {
        let f = Fixture()
        defer { f.cleanUp() }
        let before = HotKeyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(cmdKey | optionKey))
        #expect(f.hotKeys.set(.captureArea, to: before) == nil)
        #expect(f.record())
        #expect(f.button.toolTip == "Stop recording (⌥⌘5)")
        let during = HotKeyCombo(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: UInt32(controlKey | cmdKey))
        #expect(f.hotKeys.set(.captureArea, to: during) == nil)
        #expect(f.button.toolTip == "Stop recording (⌃⌘6)")
        #expect(f.hotKeys.set(.captureFullscreen, to: before) == nil, "another hot key leaves it alone")
        #expect(f.button.toolTip == "Stop recording (⌃⌘6)")
        f.harness.coordinator.handle(.command(.cancel))
        #expect(f.button.toolTip == nil)
        #expect(f.hotKeys.set(.captureArea, to: .defaultCapture) == nil)
        #expect(f.button.toolTip == nil, "no ● — nothing to update")
    }

    @Test func cancelRestoresTheNormalItem() async {
        let f = Fixture()
        defer { f.cleanUp() }
        #expect(f.record())
        await until({ f.harness.log.entries.contains("chrome.started") })
        f.clock.advance(seconds: 3)
        await until({ f.button.title == "0:03" })
        f.harness.coordinator.handle(.command(.cancel))
        expectNormal(f, "after Cancel")
        f.clock.advance(seconds: 1)
        await settle()
        expectNormal(f, "no stale tick after Cancel")
    }

    @Test func aMidRecordingFailureRestoresTheNormalItem() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        #expect(f.record())
        await until({ f.harness.log.entries.contains("chrome.started") })
        f.clock.advance(seconds: 2)
        await until({ f.button.title == "0:02" })
        let pipeline = try #require(f.harness.pipelines.last)
        pipeline.onFailure?(RecordingCoordinatorTests.FakePipeline.Failure())
        expectNormal(f, "after a failure")
        #expect(f.errors == 1)
        f.clock.advance(seconds: 1)
        await settle()
        expectNormal(f, "no stale tick after a failure")
    }

    /// Cancelled while the stream is still being set up: the readout never
    /// starts, even when the start completes afterwards.
    @Test func cancelDuringStartNeverStartsTheReadout() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.harness.suspendNextStart = true
        #expect(f.record())
        expectRecording(f, "0:00")
        await until({ f.harness.pipelines.last?.continuation != nil }, "start suspended")
        f.harness.coordinator.handle(.command(.cancel))
        expectNormal(f, "after Cancel during start")
        try #require(f.harness.pipelines.last).finishStart()
        await settle()
        f.clock.advance(seconds: 1)
        await settle()
        expectNormal(f, "a late start doesn't bring the readout back")
        #expect(!f.harness.log.entries.contains("chrome.started"))
    }

    /// A second take counts from zero, and the first take's ticker is gone.
    @Test func aSecondTakeStartsAtZero() async {
        let f = Fixture()
        defer { f.cleanUp() }
        #expect(f.record())
        await until({ f.harness.log.entries.contains("chrome.started") })
        f.clock.advance(seconds: 5)
        await until({ f.button.title == "0:05" })
        f.click()
        await until({ f.harness.isPresenting })
        expectNormal(f, "between takes")

        // The second take's stream takes a while to come up: the item shows
        // 0:00 meanwhile, and the first take's ticker (which would say 0:06)
        // never touches it.
        let started = f.harness.log.entries.count { $0 == "chrome.started" }
        f.harness.suspendNextStart = true
        #expect(f.record())
        expectRecording(f, "0:00")
        await until({ f.harness.pipelines.last?.continuation != nil }, "second start suspended")
        f.clock.advance(seconds: 1)
        await settle()
        expectRecording(f, "0:00")
        f.harness.pipelines.last?.finishStart()
        await until({ f.harness.log.entries.count { $0 == "chrome.started" } == started + 1 }, "second capture started")
        expectRecording(f, "0:00")
        f.clock.advance(seconds: 1)
        await until({ f.button.title == "0:01" })
        await settle()
        expectRecording(f, "0:01") // the first take's ticker would say 0:06
        f.harness.coordinator.stop()
        await until({ f.harness.isPresenting })
        expectNormal(f, "after the second take")
    }
}

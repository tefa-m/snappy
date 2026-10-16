import AppKit
import Foundation
import Testing
@testable import Snappy

@Suite("WindowTrackingState")
struct WindowTrackingStateTests {
    private let start = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func anUnchangedFrameReportsNothing() {
        var state = WindowTrackingState(frame: start)
        #expect(state.update(.onScreen(start)) == nil)
        #expect(state.frame == start && !state.isGone)
    }

    @Test func everyFrameChangeIsReportedOnce() {
        var state = WindowTrackingState(frame: start)
        let moved = start.offsetBy(dx: 40, dy: -10)
        #expect(state.update(.onScreen(moved)) == .frameChanged(moved))
        #expect(state.update(.onScreen(moved)) == nil)
        let resized = CGRect(x: 140, y: 90, width: 1000, height: 600)
        #expect(state.update(.onScreen(resized)) == .frameChanged(resized))
        #expect(state.frame == resized)
    }

    @Test func aClosedWindowIsGoneAtOnceAndOnlyOnce() {
        var state = WindowTrackingState(frame: start)
        #expect(state.update(.missing) == .gone)
        #expect(state.isGone)
        #expect(state.update(.missing) == nil)
        #expect(state.update(.offScreen) == nil)
        #expect(state.update(.onScreen(start.offsetBy(dx: 1, dy: 0))) == nil)
    }

    @Test func offScreenKeepsRecordingByDefault() {
        // Design decision (review round 1 #3): minimised, another Space or
        // app hidden can't be told apart; none of them ends the recording.
        #expect(WindowTrackingState.offScreenEndsRecording == false)
        var state = WindowTrackingState(frame: start)
        for _ in 0..<1000 {
            #expect(state.update(.offScreen) == nil)
        }
        #expect(!state.isGone && state.isOffScreen)
        // Back on screen (moved meanwhile): recording resumes following it.
        let back = start.offsetBy(dx: 30, dy: 0)
        #expect(state.update(.onScreen(back)) == .frameChanged(back))
        #expect(!state.isOffScreen)
        // Only a real close ends it.
        #expect(state.update(.missing) == .gone)
    }

    @Test func withTheSwitchOnAMinimisedWindowIsGoneAfterTheGrace() {
        var state = WindowTrackingState(frame: start, offScreenEndsRecording: true)
        for _ in 1..<WindowTrackingState.offScreenGrace {
            #expect(state.update(.offScreen) == nil)
        }
        #expect(state.update(.offScreen) == .gone)
        #expect(state.update(.offScreen) == nil)
    }

    @Test func withTheSwitchOnABriefOffScreenHiccupDoesNotEndTheRecording() {
        var state = WindowTrackingState(frame: start, offScreenEndsRecording: true)
        for _ in 0..<5 {
            for _ in 1..<WindowTrackingState.offScreenGrace {
                #expect(state.update(.offScreen) == nil)
            }
            #expect(state.update(.onScreen(start)) == nil) // resets the count
        }
        #expect(!state.isGone)
    }
}

@MainActor
@Suite("WindowTracker")
struct WindowTrackerTests {
    private let start = CGRect(x: 100, y: 100, width: 800, height: 600)

    /// A tracker over a scripted window server.
    private final class Script {
        var observation: WindowObservation
        var frames: [CGRect] = []
        var goneCount = 0
        init(_ observation: WindowObservation) { self.observation = observation }
    }

    private func tracker(_ script: Script) -> WindowTracker {
        let tracker = WindowTracker(windowID: 42, frame: start) { id in
            #expect(id == 42)
            return script.observation
        }
        tracker.onFrameChange = { script.frames.append($0) }
        tracker.onGone = { script.goneCount += 1 }
        return tracker
    }

    @Test func pollReportsFrameChanges() {
        let script = Script(.onScreen(start))
        let tracker = tracker(script)
        tracker.poll()
        #expect(script.frames.isEmpty)
        let moved = start.offsetBy(dx: 25, dy: 5)
        script.observation = .onScreen(moved)
        tracker.poll()
        tracker.poll()
        #expect(script.frames == [moved])
    }

    @Test func goneFiresExactlyOnce() {
        let script = Script(.missing)
        let tracker = tracker(script)
        tracker.poll()
        tracker.poll()
        #expect(script.goneCount == 1)
        #expect(tracker.isGone)
        script.observation = .onScreen(start.offsetBy(dx: 1, dy: 1))
        tracker.poll()
        #expect(script.frames.isEmpty)
    }

    @Test func startPollsOnItsOwnUntilGone() async throws {
        let script = Script(.onScreen(start))
        let tracker = tracker(script)
        tracker.start()
        let moved = start.offsetBy(dx: 0, dy: 50)
        script.observation = .onScreen(moved)
        try await waitUntil { script.frames == [moved] }
        script.observation = .missing
        try await waitUntil { script.goneCount == 1 }
        // Tracking stopped with it: nothing more is reported.
        script.observation = .onScreen(start)
        try await Task.sleep(for: .milliseconds(150))
        #expect(script.frames == [moved] && script.goneCount == 1)
        tracker.stop()
    }

    @Test func stopEndsPolling() async throws {
        let script = Script(.onScreen(start))
        let tracker = tracker(script)
        tracker.start()
        tracker.stop()
        script.observation = .missing
        try await Task.sleep(for: .milliseconds(150))
        #expect(script.goneCount == 0)
    }

    @Test func anOffScreenWindowNeverFiresGone() async throws {
        let script = Script(.offScreen)
        let tracker = tracker(script)
        tracker.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(script.goneCount == 0 && !tracker.isGone)
        tracker.stop()
    }

    @Test func aMissingWindowIDIsMissingInTheWindowServer() {
        // No window has id 0 — the real system query reports it as closed.
        #expect(WindowTracker.systemObservation(of: 0) == .missing)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

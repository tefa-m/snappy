import CoreGraphics
import Foundation
import Testing
@testable import Snappy

@Suite("RecordingSession")
struct RecordingSessionTests {
    private let area = RecordingTarget.area(globalRect: CGRect(x: 100, y: 100, width: 400, height: 300), displayID: 1)
    private let snapped = RecordingTarget.area(globalRect: CGRect(x: 0, y: 0, width: 800, height: 600), displayID: 1)
    private let window = RecordingTarget.window(windowID: 42, frame: CGRect(x: 10, y: 10, width: 500, height: 400), displayID: 1)
    private let take = URL(filePath: "/tmp/take.mp4")

    private func session(countdown: Int = 3, target: RecordingTarget? = nil) -> RecordingSession {
        RecordingSession(target: target ?? area, countdownSeconds: countdown)
    }

    /// A session driven into `phase` through real transitions.
    private func session(in phase: RecordingPhase, countdown: Int = 3, target: RecordingTarget? = nil) -> RecordingSession {
        var s = session(countdown: countdown, target: target)
        switch phase {
        case .setup(.pointer): break
        case .setup(.tool(let tool)): s.handle(.command(.tool(tool)))
        case .snapping(let kind, _, let returnTo):
            if case .tool(let tool) = returnTo { s.handle(.command(.tool(tool))) }
            s.handle(.command(.snap(kind)))
        case .countdown(let remaining):
            s.handle(.command(.record))
            for _ in 0..<(countdown - remaining) { s.handle(.countdownTick) }
        case .recording(let mode):
            s = RecordingSession(target: target ?? area, countdownSeconds: 0)
            s.handle(.command(.record))
            switch mode {
            case .interact: break
            case .draw(let tool): s.handle(.command(.tool(tool)))
            case .magicPen(let resume):
                if let resume { s.handle(.command(.tool(resume))) }
                s.handle(.command(.toggleMagicPen))
            }
        case .stopping:
            s = self.session(in: .recording(.interact), target: target)
            s.handle(.command(.stop))
        case .finished(let url):
            s = self.session(in: .stopping, target: target)
            s.handle(.captureFinished(url))
        case .cancelled:
            s.handle(.command(.cancel))
        }
        #expect(s.phase == phase, "fixture failed to reach \(phase)")
        return s
    }

    // MARK: - Setup

    @Test func startsInSetupPointerOnTheGivenTarget() {
        let s = session()
        #expect(s.phase == .setup(.pointer))
        #expect(s.target == area)
        #expect(s.lastTool == .pen)
        #expect(s.inkMode == .pointer)
        #expect(!s.isCapturing)
    }

    @Test func negativeCountdownIsTreatedAsOff() {
        #expect(RecordingSession(target: area, countdownSeconds: -2).countdownSeconds == 0)
    }

    @Test func recordStartsTheCountdownOrRecordsAtOnceWhenOff() {
        var s = session(countdown: 3)
        #expect(s.handle(.command(.record)) == .changed(from: .setup(.pointer)))
        #expect(s.phase == .countdown(remaining: 3))

        var off = session(countdown: 0)
        off.handle(.command(.record))
        #expect(off.phase == .recording(.interact))
    }

    @Test func recordFromAToolStartsToo() {
        var s = session(in: .setup(.tool(.arrow)), countdown: 0)
        s.handle(.command(.record))
        #expect(s.phase == .recording(.interact))
    }

    @Test(arguments: InkTool.allCases)
    func pickingAToolEntersToolModeAndRemembersIt(tool: InkTool) {
        var s = session()
        #expect(s.handle(.command(.tool(tool))) == .changed(from: .setup(.pointer)))
        #expect(s.phase == .setup(.tool(tool)))
        #expect(s.lastTool == tool)
        #expect(s.inkMode == .tool(tool))
    }

    @Test func pickingTheSameToolAgainIsIgnored() {
        var s = session(in: .setup(.tool(.oval)))
        #expect(s.handle(.command(.tool(.oval))) == .ignored)
    }

    @Test func pointerFromAToolReturnsToPointerAndIsIgnoredInPointer() {
        var s = session(in: .setup(.tool(.box)))
        s.handle(.command(.pointer))
        #expect(s.phase == .setup(.pointer))
        #expect(s.handle(.command(.pointer)) == .ignored)
    }

    @Test func escStepsBackToolToPointerThenCancels() {
        var s = session(in: .setup(.tool(.pen)))
        s.handle(.command(.stepBack))
        #expect(s.phase == .setup(.pointer))
        s.handle(.command(.stepBack))
        #expect(s.phase == .cancelled)
    }

    @Test func stopAndDrawToggleAreIgnoredInSetup() {
        for mode in [SetupMode.pointer, .tool(.highlighter)] {
            var s = session(in: .setup(mode))
            #expect(s.handle(.command(.stop)) == .ignored)
            #expect(s.handle(.command(.toggleDrawMode)) == .ignored)
            #expect(s.phase == .setup(mode))
        }
    }

    @Test func inkCommandsPassThroughInSetup() {
        var s = session()
        #expect(s.handle(.command(.ink(.color(.blue)))) == .ink(.color(.blue)))
        #expect(s.handle(.command(.ink(.undo))) == .ink(.undo))
        #expect(s.phase == .setup(.pointer))
    }

    @Test func targetChangesAreTakenInSetupAndIgnoredWhenEqual() {
        var s = session()
        #expect(s.handle(.targetChanged(snapped)) == .changed(from: .setup(.pointer)))
        #expect(s.target == snapped)
        #expect(s.handle(.targetChanged(snapped)) == .ignored)
    }

    @Test func cancelEndsSetup() {
        var s = session(in: .setup(.tool(.pen)))
        s.handle(.command(.cancel))
        #expect(s.phase == .cancelled)
    }

    @Test func irrelevantEventsAreIgnoredInSetup() {
        var s = session()
        for event: RecordingEvent in [.confirmSnap, .countdownTick, .captureFinished(take), .captureFailed] {
            #expect(s.handle(event) == .ignored, "\(event)")
        }
        // windowGone only matters for a window target.
        #expect(s.handle(.windowGone) == .ignored)
    }

    // MARK: - Snapping

    @Test(arguments: [SnapKind.area, .window])
    func snapRemembersThePreviousTargetAndMode(kind: SnapKind) {
        var s = session(in: .setup(.tool(.arrow)))
        s.handle(.command(.snap(kind)))
        #expect(s.phase == .snapping(kind, previous: area, returnTo: .tool(.arrow)))
        #expect(s.inkMode == .pointer)
    }

    @Test func hoverFollowsAndSameKeyConfirms() {
        var s = session(in: .snapping(.area, previous: area, returnTo: .pointer))
        s.handle(.targetChanged(snapped))
        #expect(s.target == snapped)
        s.handle(.command(.snap(.area)))
        #expect(s.phase == .setup(.pointer))
        #expect(s.target == snapped)
    }

    @Test func clickConfirms() {
        var s = session(in: .snapping(.window, previous: area, returnTo: .tool(.pen)))
        s.handle(.targetChanged(window))
        s.handle(.confirmSnap)
        #expect(s.phase == .setup(.tool(.pen)))
        #expect(s.target == window)
    }

    @Test func otherKeySwitchesModeAndKeepsTheOriginalTarget() {
        var s = session(in: .snapping(.area, previous: area, returnTo: .pointer))
        s.handle(.targetChanged(snapped))
        s.handle(.command(.snap(.window)))
        #expect(s.phase == .snapping(.window, previous: area, returnTo: .pointer))
        s.handle(.command(.snap(.area)))
        #expect(s.phase == .snapping(.area, previous: area, returnTo: .pointer))
    }

    @Test func escRestoresThePreviousTarget() {
        var s = session(in: .snapping(.window, previous: area, returnTo: .tool(.oval)))
        s.handle(.targetChanged(window))
        s.handle(.command(.stepBack))
        #expect(s.phase == .setup(.tool(.oval)))
        #expect(s.target == area)
    }

    @Test func snappingIgnoresEverythingElse() {
        var s = session(in: .snapping(.area, previous: area, returnTo: .pointer))
        let ignored: [RecordingEvent] = [
            .command(.record), .command(.pointer), .command(.tool(.pen)), .command(.ink(.clear)),
            .command(.toggleDrawMode), .command(.stop), .countdownTick, .windowGone,
            .captureFinished(take), .captureFailed,
        ]
        for event in ignored {
            #expect(s.handle(event) == .ignored, "\(event)")
        }
        s.handle(.command(.cancel))
        #expect(s.phase == .cancelled)
    }

    // MARK: - Countdown

    @Test func countdownTicksDownThenRecordsInInteractMode() {
        var s = session(in: .countdown(remaining: 3))
        s.handle(.countdownTick)
        #expect(s.phase == .countdown(remaining: 2))
        s.handle(.countdownTick)
        #expect(s.phase == .countdown(remaining: 1))
        #expect(s.handle(.countdownTick) == .changed(from: .countdown(remaining: 1)))
        #expect(s.phase == .recording(.interact))
        #expect(s.isCapturing)
    }

    @Test func oneSecondCountdownRecordsOnTheFirstTick() {
        var s = session(in: .countdown(remaining: 1), countdown: 1)
        s.handle(.countdownTick)
        #expect(s.phase == .recording(.interact))
    }

    @Test func escDuringCountdownReturnsToSetup() {
        var s = session(in: .countdown(remaining: 2))
        s.handle(.command(.stepBack))
        #expect(s.phase == .setup(.pointer))
    }

    @Test func countdownIgnoresStopRecordAndTools() {
        var s = session(in: .countdown(remaining: 3))
        for command: RecordingCommand in [.stop, .record, .tool(.pen), .snap(.area), .toggleDrawMode, .ink(.clear)] {
            #expect(s.handle(.command(command)) == .ignored, "\(command)")
        }
        #expect(s.inkMode == .pointer)
    }

    @Test func countdownCancels() {
        var s = session(in: .countdown(remaining: 3))
        s.handle(.command(.cancel))
        #expect(s.phase == .cancelled)
    }

    // MARK: - Window gone before recording

    @Test func vanishedWindowBecomesItsAreaInSetup() {
        var s = session(target: window)
        s.handle(.windowGone)
        #expect(s.phase == .setup(.pointer))
        #expect(s.target == .area(globalRect: window.frame, displayID: 1))
    }

    @Test func vanishedWindowDuringCountdownReturnsToSetup() {
        var s = session(in: .countdown(remaining: 2), target: window)
        s.handle(.windowGone)
        #expect(s.phase == .setup(.pointer))
        #expect(!s.target.isWindow)
    }

    // MARK: - Recording

    @Test func toggleDrawModeUsesTheLastToolAndBack() {
        var s = session(in: .recording(.interact))
        #expect(s.inkMode == .interact)
        s.handle(.command(.toggleDrawMode))
        #expect(s.phase == .recording(.draw(.pen)))
        #expect(s.inkMode == .tool(.pen))
        s.handle(.command(.toggleDrawMode))
        #expect(s.phase == .recording(.interact))
    }

    @Test func toolPickedInSetupCarriesIntoDrawMode() {
        var s = RecordingSession(target: area, countdownSeconds: 0)
        s.handle(.command(.tool(.highlighter)))
        s.handle(.command(.record))
        #expect(s.phase == .recording(.interact))
        s.handle(.command(.toggleDrawMode))
        #expect(s.phase == .recording(.draw(.highlighter)))
    }

    @Test func aToolFromTheToolbarInInteractModeStartsDrawing() {
        var s = session(in: .recording(.interact))
        s.handle(.command(.tool(.box)))
        #expect(s.phase == .recording(.draw(.box)))
        #expect(s.lastTool == .box)
    }

    @Test func switchingToolsInDrawMode() {
        var s = session(in: .recording(.draw(.pen)))
        s.handle(.command(.tool(.arrow)))
        #expect(s.phase == .recording(.draw(.arrow)))
        #expect(s.handle(.command(.tool(.arrow))) == .ignored)
    }

    @Test func pointerAndEscLeaveDrawModeButNotInteract() {
        for command: RecordingCommand in [.pointer, .stepBack] {
            var s = session(in: .recording(.draw(.oval)))
            s.handle(.command(command))
            #expect(s.phase == .recording(.interact), "\(command)")
            #expect(s.handle(.command(command)) == .ignored, "\(command)")
        }
    }

    @Test func rDoesNothingWhileRecording() {
        for mode in [RecordingMode.interact, .draw(.pen)] {
            var s = session(in: .recording(mode))
            #expect(s.handle(.command(.record)) == .ignored)
            #expect(s.handle(.command(.snap(.area))) == .ignored)
            #expect(s.handle(.command(.snap(.window))) == .ignored)
            #expect(s.phase == .recording(mode))
        }
    }

    @Test func inkCommandsPassThroughInBothModes() {
        for mode in [RecordingMode.interact, .draw(.pen)] {
            var s = session(in: .recording(mode))
            #expect(s.handle(.command(.ink(.toggleFading))) == .ink(.toggleFading))
            #expect(s.handle(.command(.ink(.redo))) == .ink(.redo))
        }
    }

    @Test func stopFromEitherModeGoesToStopping() {
        for mode in [RecordingMode.interact, .draw(.highlighter)] {
            var s = session(in: .recording(mode))
            s.handle(.command(.stop))
            #expect(s.phase == .stopping)
            #expect(s.isCapturing)
            #expect(s.inkMode == .interact)
        }
    }

    @Test func windowGoneWhileRecordingStops() {
        var s = session(in: .recording(.interact), target: window)
        s.handle(.windowGone)
        #expect(s.phase == .stopping)
    }

    @Test func windowTargetFollowsTheWindowWhileRecording() {
        var s = session(in: .recording(.interact), target: window)
        let moved = window.withFrame(CGRect(x: 300, y: 200, width: 500, height: 400))
        #expect(s.handle(.targetChanged(moved)) == .changed(from: .recording(.interact)))
        #expect(s.target == moved)
        #expect(s.phase == .recording(.interact))
    }

    @Test func captureFailureWhileRecordingCancels() {
        var s = session(in: .recording(.draw(.pen)))
        s.handle(.captureFailed)
        #expect(s.phase == .cancelled)
    }

    @Test func cancelWhileRecordingDiscards() {
        var s = session(in: .recording(.interact))
        s.handle(.command(.cancel))
        #expect(s.phase == .cancelled)
    }

    @Test func recordingIgnoresTicksAndSnapClicks() {
        var s = session(in: .recording(.interact))
        #expect(s.handle(.countdownTick) == .ignored)
        #expect(s.handle(.confirmSnap) == .ignored)
        #expect(s.handle(.captureFinished(take)) == .ignored)
    }

    // MARK: - Magic Pen (design decision, not yet confirmed)

    @Test func magicPenTogglesOnFromInteractAndBack() {
        var s = session(in: .recording(.interact))
        #expect(s.handle(.command(.toggleMagicPen)) == .changed(from: .recording(.interact)))
        #expect(s.phase == .recording(.magicPen(resume: nil)))
        #expect(s.inkMode == .magicPen)
        #expect(s.isCapturing)
        s.handle(.command(.toggleMagicPen))
        #expect(s.phase == .recording(.interact))
        #expect(s.inkMode == .interact)
    }

    @Test(arguments: InkTool.allCases)
    func magicPenFromDrawModeTogglesBackToThatTool(tool: InkTool) {
        var s = session(in: .recording(.draw(tool)))
        s.handle(.command(.toggleMagicPen))
        #expect(s.phase == .recording(.magicPen(resume: tool)))
        #expect(s.inkMode == .magicPen)
        s.handle(.command(.toggleMagicPen))
        #expect(s.phase == .recording(.draw(tool)))
    }

    @Test func escAndQInMagicPenGoBackWhereItCameFrom() {
        var fromInteract = session(in: .recording(.magicPen(resume: nil)))
        fromInteract.handle(.command(.stepBack))
        #expect(fromInteract.phase == .recording(.interact))

        var fromDraw = session(in: .recording(.magicPen(resume: .arrow)))
        fromDraw.handle(.command(.stepBack))
        #expect(fromDraw.phase == .recording(.draw(.arrow)))
    }

    @Test func pointerInMagicPenAlwaysHandsTheMouseBack() {
        for resume: InkTool? in [nil, .box] {
            var s = session(in: .recording(.magicPen(resume: resume)))
            s.handle(.command(.pointer))
            #expect(s.phase == .recording(.interact), "\(String(describing: resume))")
        }
    }

    @Test func drawModeToggleInMagicPenSwitchesToNormalDrawing() {
        var s = session(in: .recording(.magicPen(resume: nil)))
        #expect(s.lastTool == .pen)
        s.handle(.command(.toggleDrawMode))
        #expect(s.phase == .recording(.draw(.pen)))

        var fromHighlighter = session(in: .recording(.magicPen(resume: .highlighter)))
        fromHighlighter.handle(.command(.toggleDrawMode))
        #expect(fromHighlighter.phase == .recording(.draw(.highlighter)))
    }

    @Test(arguments: InkTool.allCases)
    func aToolInMagicPenSwitchesToThatTool(tool: InkTool) {
        var s = session(in: .recording(.magicPen(resume: nil)))
        s.handle(.command(.tool(tool)))
        #expect(s.phase == .recording(.draw(tool)))
        #expect(s.lastTool == tool)
    }

    @Test func magicPenPassesInkCommandsAndIgnoresSetupCommands() {
        var s = session(in: .recording(.magicPen(resume: nil)))
        for command: InkCommand in [.clear, .undo, .redo, .magicPenThicker, .magicPenThinner, .magicPenWidth(.thick)] {
            #expect(s.handle(.command(.ink(command))) == .ink(command), "\(command)")
        }
        for command: RecordingCommand in [.record, .snap(.area), .snap(.window)] {
            #expect(s.handle(.command(command)) == .ignored, "\(command)")
        }
        #expect(s.phase == .recording(.magicPen(resume: nil)))
    }

    @Test func stopCancelFailureAndWindowGoneEndMagicPenToo() {
        var stop = session(in: .recording(.magicPen(resume: nil)))
        stop.handle(.command(.stop))
        #expect(stop.phase == .stopping)
        #expect(stop.inkMode == .interact)

        var cancel = session(in: .recording(.magicPen(resume: .pen)))
        cancel.handle(.command(.cancel))
        #expect(cancel.phase == .cancelled)

        var failure = session(in: .recording(.magicPen(resume: nil)))
        failure.handle(.captureFailed)
        #expect(failure.phase == .cancelled)

        var gone = session(in: .recording(.magicPen(resume: nil)), target: window)
        gone.handle(.windowGone)
        #expect(gone.phase == .stopping)
    }

    @Test func magicPenFollowsAMovingWindowTarget() {
        var s = session(in: .recording(.magicPen(resume: nil)), target: window)
        let moved = window.withFrame(CGRect(x: 300, y: 200, width: 500, height: 400))
        s.handle(.targetChanged(moved))
        #expect(s.target == moved)
        #expect(s.phase == .recording(.magicPen(resume: nil)))
    }

    @Test func magicPenToggleIsIgnoredBeforeRecordingAndWhileStopping() {
        let phases: [RecordingPhase] = [
            .setup(.pointer), .setup(.tool(.pen)), .snapping(.area, previous: area, returnTo: .pointer),
            .countdown(remaining: 2), .stopping,
        ]
        for phase in phases {
            var s = session(in: phase)
            #expect(s.handle(.command(.toggleMagicPen)) == .ignored, "\(phase)")
            #expect(s.phase == phase)
        }
    }

    @Test func modeIsDrawingClassification() {
        #expect(!RecordingMode.interact.isDrawing)
        #expect(RecordingMode.draw(.pen).isDrawing)
        #expect(RecordingMode.magicPen(resume: nil).isDrawing)
        #expect(RecordingMode.magicPen(resume: .oval).isDrawing)
    }

    @Test func hotKeyRouteStopsFromMagicPen() {
        #expect(CaptureHotKeyRoute.route(for: .recording(.magicPen(resume: nil))) == .stopRecording)
    }

    // MARK: - Stopping and the end states

    @Test func stoppingFinishesWithTheTake() {
        var s = session(in: .stopping)
        #expect(s.handle(.captureFinished(take)) == .changed(from: .stopping))
        #expect(s.phase == .finished(take))
        #expect(s.phase.isTerminal)
    }

    @Test func stoppingFailureCancels() {
        var s = session(in: .stopping)
        s.handle(.captureFailed)
        #expect(s.phase == .cancelled)
    }

    @Test func stoppingIgnoresEveryCommandIncludingASecondStopAndCancel() {
        var s = session(in: .stopping, target: window)
        let ignored: [RecordingEvent] = [
            .command(.stop), .command(.cancel), .command(.toggleDrawMode), .command(.record),
            .command(.ink(.clear)), .windowGone, .countdownTick, .confirmSnap,
            .targetChanged(snapped),
        ]
        for event in ignored {
            #expect(s.handle(event) == .ignored, "\(event)")
        }
        #expect(s.phase == .stopping)
    }

    @Test(arguments: [RecordingPhase.finished(URL(filePath: "/tmp/take.mp4")), .cancelled])
    func terminalPhasesIgnoreEverything(phase: RecordingPhase) {
        var s = session(in: phase)
        let events: [RecordingEvent] = [
            .command(.record), .command(.stop), .command(.cancel), .command(.stepBack),
            .targetChanged(snapped), .confirmSnap, .countdownTick, .windowGone,
            .captureFinished(take), .captureFailed,
        ]
        for event in events {
            #expect(s.handle(event) == .ignored, "\(event)")
        }
        #expect(s.phase == phase)
    }

    // MARK: - Phase helpers

    @Test func phaseClassification() {
        let pre: [RecordingPhase] = [
            .setup(.pointer), .snapping(.area, previous: area, returnTo: .pointer), .countdown(remaining: 1),
        ]
        #expect(pre.allSatisfy { $0.isPreRecording && !$0.isRecording && !$0.isTerminal })
        #expect(RecordingPhase.recording(.interact).isRecording)
        #expect(!RecordingPhase.stopping.isRecording && !RecordingPhase.stopping.isTerminal)
        #expect(RecordingPhase.cancelled.isTerminal && RecordingPhase.finished(take).isTerminal)
    }
}

@Suite("CaptureHotKeyRoute")
struct CaptureHotKeyRouteTests {
    private let target = RecordingTarget.area(globalRect: CGRect(x: 0, y: 0, width: 10, height: 10), displayID: 1)

    @Test func noSessionCaptures() {
        #expect(CaptureHotKeyRoute.route(for: nil) == .captureArea)
        #expect(CaptureHotKeyRoute.route(for: .cancelled) == .captureArea)
        #expect(CaptureHotKeyRoute.route(for: .finished(URL(filePath: "/tmp/x.mp4"))) == .captureArea)
    }

    @Test func recordingStops() {
        #expect(CaptureHotKeyRoute.route(for: .recording(.interact)) == .stopRecording)
        #expect(CaptureHotKeyRoute.route(for: .recording(.draw(.pen))) == .stopRecording)
    }

    @Test func restOfTheSessionIgnores() {
        let phases: [RecordingPhase] = [
            .setup(.pointer), .setup(.tool(.box)), .snapping(.window, previous: target, returnTo: .pointer),
            .countdown(remaining: 3), .stopping,
        ]
        for phase in phases {
            #expect(CaptureHotKeyRoute.route(for: phase) == .ignore, "\(phase)")
        }
    }
}

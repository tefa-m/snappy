import AppKit
import Foundation
import Synchronization
import Testing
@testable import Snappy

/// The W + part target (V2 → V3 contract), what S/W make of a picked part,
/// and the ink staying anchored to the window (Q42).
@MainActor
@Suite("Window parts — targets")
struct WindowPartTargetTests {
    private static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let windowFrame = CGRect(x: 100, y: 100, width: 1000, height: 700)
    private static let partFrame = CGRect(x: 100, y: 100, width: 1000, height: 619) // below an 81 pt toolbar
    private static let window = SnapWindow(windowID: 9, frame: windowFrame, appName: "Brave Browser", processID: 7)

    private func part(_ element: WindowPartElement? = nil) -> SnapPart {
        SnapPart(frame: Self.partFrame, name: "Web page", element: element)
    }

    private func partTarget(_ element: WindowPartElement? = nil) -> RecordingTarget {
        .windowPart(
            WindowPartTarget(
                windowID: 9, windowFrame: Self.windowFrame, frame: Self.partFrame, name: "Web page", element: element
            ),
            displayID: 3
        )
    }

    // MARK: Q37 / Q38

    /// S + part: the part's screen region, fixed (Q38).
    @Test func snapAreaOfAPartIsItsRegion() {
        let target = WindowSnapCandidates.target(
            for: Self.window, part: part(), kind: .area, screenFrame: Self.screen, displayID: 3
        )
        #expect(target == .area(globalRect: Self.partFrame, displayID: 3))
    }

    @Test func snapAreaOfAPartIsClampedToTheDisplayAndTheMinimumSize() {
        let sliver = SnapPart(frame: CGRect(x: 1420, y: 300, width: 300, height: 200), name: "Sidebar")
        let target = WindowSnapCandidates.target(
            for: Self.window, part: sliver, kind: .area, screenFrame: Self.screen, displayID: 3
        )
        #expect(target.frame == CGRect(x: 1400, y: 300, width: SetupGeometry.minSize.width, height: 200))
    }

    /// W + part: the new case, carrying window, part rect, name and handle (Q37).
    @Test func snapWindowOfAPartIsTheWindowPartCase() {
        let element = WindowPartElement(processID: 7) { nil }
        let target = WindowSnapCandidates.target(
            for: Self.window, part: part(element), kind: .window, screenFrame: Self.screen, displayID: 3
        )
        #expect(target == partTarget(element))
        #expect(target.frame == Self.partFrame)
        #expect(target.windowID == 9)
        #expect(target.isWindow, "locked in Setup, anchored ink, letterboxed — a window target")
        #expect(target.windowFrame == Self.windowFrame)
        #expect(target.displayID == 3)
    }

    @Test func desiredTargetWhileSnappingFollowsThePickedPart() {
        let display = SetupGeometry.Display(id: 3, frame: Self.screen)
        let previous = RecordingTarget.area(globalRect: CGRect(x: 10, y: 10, width: 200, height: 200), displayID: 3)
        var session = RecordingSession(target: previous, countdownSeconds: 3)
        session.handle(.command(.snap(.window)))
        let element = WindowPartElement(processID: 7) { nil }
        #expect(SetupGeometry.desiredTarget(for: session, hovered: Self.window, part: part(element), display: display)
            == partTarget(element))
        #expect(SetupGeometry.desiredTarget(for: session, hovered: Self.window, part: nil, display: display)
            == .window(windowID: 9, frame: Self.windowFrame, displayID: 3))
        #expect(SetupGeometry.desiredTarget(for: session, hovered: nil, part: part(), display: display) == previous)
    }

    // MARK: RecordingTarget.windowPart

    @Test func elementsCompareByIdentity() {
        let a = WindowPartElement(processID: 7) { nil }
        let b = WindowPartElement(processID: 7) { nil }
        #expect(partTarget(a) == partTarget(a))
        #expect(partTarget(a) != partTarget(b))
        #expect(partTarget(nil) != partTarget(a))
    }

    @Test func theElementReportsItsLiveFrame() async {
        let live = Mutex<CGRect?>(CGRect(x: 1, y: 2, width: 300, height: 200))
        let element = WindowPartElement(processID: 7) { live.withLock { $0 } }
        #expect(await element.currentFrame() == CGRect(x: 1, y: 2, width: 300, height: 200))
        live.withLock { $0 = nil }
        #expect(await element.currentFrame() == nil, "gone: V3 keeps the last rect")
    }

    @Test func theElementLetsGoOfItsAXElementWhenItGoes() {
        let released = Mutex(false)
        var element: WindowPartElement? = WindowPartElement(processID: 7, release: { released.withLock { $0 = true } }) { nil }
        #expect(element != nil)
        element = nil
        #expect(released.withLock { $0 })
    }

    @Test func withFrameMovesThePartNotTheWindow() {
        let moved = CGRect(x: 120, y: 90, width: 500, height: 400)
        let target = partTarget().withFrame(moved)
        #expect(target.frame == moved)
        #expect(target.windowFrame == Self.windowFrame)
        #expect(target.windowID == 9)
    }

    /// A moved or resized window (the pipeline's frame report) carries the
    /// part along at the same offset from its top-left corner.
    @Test func withWindowFrameKeepsThePartsOffsetFromTheTopLeft() {
        let part = CGRect(x: 300, y: 200, width: 400, height: 300) // 200 from the left, 300 below the top (800)
        let target = RecordingTarget.windowPart(
            WindowPartTarget(windowID: 9, windowFrame: Self.windowFrame, frame: part, name: "Sidebar", element: nil),
            displayID: 3
        )
        // Moved by (+50, −20) and 100 pt taller (the top edge rises by 80).
        let moved = target.withWindowFrame(CGRect(x: 150, y: 80, width: 1000, height: 800))
        #expect(moved.windowFrame == CGRect(x: 150, y: 80, width: 1000, height: 800))
        #expect(moved.frame == CGRect(x: 350, y: 280, width: 400, height: 300))
        // Plain windows just take the frame; areas have no window.
        let window = RecordingTarget.window(windowID: 9, frame: Self.windowFrame, displayID: 3)
        #expect(window.withWindowFrame(part) == window.withFrame(part))
        let area = RecordingTarget.area(globalRect: part, displayID: 3)
        #expect(area.withWindowFrame(Self.windowFrame) == area)
    }

    /// A part's whole window — Retake's fallback when the part is gone (Q41).
    @Test func wholeWindowIsThePartsWindow() {
        #expect(partTarget().wholeWindow == .window(windowID: 9, frame: Self.windowFrame, displayID: 3))
        let area = RecordingTarget.area(globalRect: Self.partFrame, displayID: 3)
        #expect(area.wholeWindow == area)
        let window = RecordingTarget.window(windowID: 9, frame: Self.windowFrame, displayID: 3)
        #expect(window.wholeWindow == window)
    }

    @Test func aClosedPartsWindowLeavesThePartsRegion() {
        #expect(partTarget().asArea == .area(globalRect: Self.partFrame, displayID: 3))
        #expect(RecordingTarget.area(globalRect: Self.partFrame, displayID: 3).windowFrame == nil)
    }

    // MARK: Q42 — ink stays anchored to the window

    /// Setup ink drawn on the whole window doesn't jump when S/W picks a part
    /// of it: anchors resolve against the window, never the part.
    @Test func inkDrawnOnTheWindowStaysPutWhenTheTargetBecomesAPartOfIt() throws {
        var ink = LiveInk(fadeDelay: 3)
        ink.setTarget(.window(windowID: 9, frame: Self.windowFrame, displayID: 3))
        ink.beginStroke(tool: .arrow, at: CGPoint(x: 300, y: 500), style: InkStyle(color: .red, width: .thin, fading: false),
                        isCapturing: false)
        ink.extendStroke(to: CGPoint(x: 400, y: 400))
        ink.endStroke(at: 0)
        ink.setTarget(partTarget())
        // The ink panel and the video cover the part; anchors resolve against
        // its window.
        let arrow = try #require(ink.scene.renderItems(
            time: 0, targetFrame: Self.partFrame, windowFrame: Self.windowFrame
        ).first?.annotation)
        guard case .arrow(let resolved) = arrow else {
            Issue.record("not an arrow")
            return
        }
        #expect(resolved.tail == CGPoint(x: 300, y: 500))
        #expect(resolved.head == CGPoint(x: 400, y: 400))
    }
}

@Suite("Window parts — permission and tree switches")
struct WindowPartAccessRulesTests {
    @Test func promptsOnlyOnceOnlyWithoutAccessOnlyAsTheApp() {
        #expect(WindowPartPermission.shouldPrompt(isTrusted: false, alreadyPrompted: false, isBundledApp: true))
        #expect(!WindowPartPermission.shouldPrompt(isTrusted: false, alreadyPrompted: true, isBundledApp: true))
        #expect(!WindowPartPermission.shouldPrompt(isTrusted: true, alreadyPrompted: false, isBundledApp: true))
        #expect(!WindowPartPermission.shouldPrompt(isTrusted: false, alreadyPrompted: false, isBundledApp: false))
    }

    @Test func statusRowSaysAllowedOrOffersSystemSettings() {
        let allowed = WindowPartPermission.status(isTrusted: true)
        #expect(allowed.title == "Allowed")
        #expect(!allowed.offersSettings)
        let needed = WindowPartPermission.status(isTrusted: false)
        #expect(needed.title == "Needs Accessibility")
        #expect(needed.offersSettings)
        #expect(needed.detail.contains("whole windows"))
        #expect(NSImage(systemSymbolName: allowed.symbolName, accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: needed.symbolName, accessibilityDescription: nil) != nil)
        #expect(WindowPartPermission.settingsURL?.absoluteString.contains("Privacy_Accessibility") == true)
    }

    @Test func appKindsFromTheBundleLayout() {
        #expect(WindowPartAppKind.classify(
            frameworks: ["Code Helper (Renderer).app", "Electron Framework.framework", "Squirrel.framework"],
            helpers: []
        ) == .electron)
        #expect(WindowPartAppKind.classify(
            frameworks: ["Brave Browser Framework.framework"],
            helpers: ["Brave Browser Helper.app", "Brave Browser Helper (Renderer).app", "chrome_crashpad_handler"]
        ) == .chromium)
        #expect(WindowPartAppKind.classify(
            frameworks: ["Codex Framework.framework", "Sparkle.framework"],
            helpers: ["Codex (GPU).app", "Codex (Renderer).app"]
        ) == .chromium, "ChatGPT's Chromium shell names its helpers without 'Helper'")
        #expect(WindowPartAppKind.classify(frameworks: ["Sparkle.framework"], helpers: ["Updater.app"]) == .other)
        #expect(WindowPartAppKind.classify(frameworks: [], helpers: []) == .other)
        #expect(WindowPartAppKind.electron.treeSwitch == .manualAccessibility)
        #expect(WindowPartAppKind.chromium.treeSwitch == .enhancedUserInterface)
        #expect(WindowPartAppKind.other.treeSwitch == nil)
        #expect(WindowPartTreeSwitch.enhancedUserInterface.rawValue == "AXEnhancedUserInterface")
        #expect(WindowPartTreeSwitch.manualAccessibility.rawValue == "AXManualAccessibility")
    }

    @Test func appKindOfAMissingBundleIsOther() {
        #expect(WindowPartAppKind.of(bundleURL: nil) == .other)
        #expect(WindowPartAppKind.of(bundleURL: URL(filePath: "/nonexistent/Nothing.app")) == .other)
    }

    @Test func eachAppIsSwitchedAtMostOnceOnlyWhenItsTreeIsEmpty() {
        var ledger = WindowPartSwitchLedger()
        #expect(ledger.switchToTry(pid: 1, kind: .electron, treeIsEmpty: false) == nil)
        #expect(ledger.switchToTry(pid: 1, kind: .other, treeIsEmpty: true) == nil)
        #expect(ledger.switchToTry(pid: 1, kind: .electron, treeIsEmpty: true) == .manualAccessibility)
        #expect(ledger.switchToTry(pid: 1, kind: .electron, treeIsEmpty: true) == nil, "tried once")
        #expect(ledger.switchToTry(pid: 2, kind: .chromium, treeIsEmpty: true) == .enhancedUserInterface)
    }

    @Test func onlyWhatWentOnIsRestoredOnceThenTheLedgerStartsOver() {
        var ledger = WindowPartSwitchLedger()
        _ = ledger.switchToTry(pid: 2, kind: .chromium, treeIsEmpty: true)
        _ = ledger.switchToTry(pid: 1, kind: .electron, treeIsEmpty: true)
        _ = ledger.switchToTry(pid: 3, kind: .electron, treeIsEmpty: true) // refused by the app: never recorded
        ledger.didSwitch(WindowPartSwitchRecord(pid: 2, identity: "b", treeSwitch: .enhancedUserInterface, original: false))
        ledger.didSwitch(WindowPartSwitchRecord(pid: 1, identity: "a", treeSwitch: .manualAccessibility, original: false))
        let restore = ledger.takeForRestore()
        #expect(restore.map(\.pid) == [1, 2])
        #expect(restore.map(\.treeSwitch) == [.manualAccessibility, .enhancedUserInterface])
        #expect(restore.map(\.identity) == ["a", "b"])
        #expect(ledger.takeForRestore().isEmpty)
        // A new session may try the same app again.
        #expect(ledger.switchToTry(pid: 1, kind: .electron, treeIsEmpty: true) == .manualAccessibility)
    }
}

/// The two coordinator hooks (Q39 prompt on snap entry, Q40 restore at the
/// session's end) and the W + part hand-off through the coordinator.
@MainActor
@Suite("Window parts — coordinator hooks", .serialized)
struct WindowPartCoordinatorTests {
    @MainActor final class FakeParts: WindowPartSessionHooking {
        var entries = 0
        var ends = 0
        func snapModeEntered() { entries += 1 }
        var began: [RecordingTarget] = []
        func sessionBegan(target: RecordingTarget) { began.append(target) }
        var terminations = 0
        /// Runs inside `sessionEnded` — what the tests look at then.
        var onEnded: (@MainActor () -> Void)?
        func sessionEnded() {
            ends += 1
            onEnded?()
        }
        func applicationWillTerminate() { terminations += 1 }
    }

    private let target = RecordingTarget.area(globalRect: CGRect(x: 10, y: 10, width: 320, height: 240), displayID: 1)

    private func harness() -> (RecordingCoordinatorTests.Harness, FakeParts) {
        let h = RecordingCoordinatorTests.Harness()
        let parts = FakeParts()
        h.coordinator.windowParts = parts
        return (h, parts)
    }

    @Test func everySnapModeEntryIsReportedButNotASwitchBetweenSAndW() {
        let (h, parts) = harness()
        defer { h.cleanUp() }
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        #expect(parts.entries == 0)
        h.coordinator.handle(.command(.snap(.area)))
        #expect(parts.entries == 1)
        h.coordinator.handle(.command(.snap(.window))) // S → W: still the same visit
        #expect(parts.entries == 1)
        h.coordinator.handle(.command(.snap(.window))) // W again: back
        #expect(h.coordinator.phase == .setup(.pointer))
        h.coordinator.handle(.command(.snap(.window)))
        #expect(parts.entries == 2)
    }

    @Test func theSessionEndRestoresOnCancelAndOnFinish() async {
        let (h, parts) = harness()
        defer { h.cleanUp() }
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.cancel))
        #expect(parts.ends == 1)

        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.record))
        h.coordinator.stop()
        for _ in 0..<500 where h.coordinator.isSessionActive {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(!h.coordinator.isSessionActive)
        #expect(parts.ends == 2)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Quit (Q40): from snap mode, from Setup after a pick, and while
    /// recording — the restore hook runs once, without ending the session.
    @Test func quittingRestoresFromSnappingSetupAndRecording() async {
        let (h, parts) = harness()
        defer { h.cleanUp() }
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.snap(.window)))
        h.coordinator.applicationWillTerminate()
        #expect(parts.terminations == 1)

        let window = RecordingTarget.window(windowID: 4, frame: target.frame, displayID: 1)
        h.coordinator.handle(.targetChanged(window))
        h.coordinator.handle(.confirmSnap)
        #expect(h.coordinator.phase == .setup(.pointer))
        h.coordinator.applicationWillTerminate()
        #expect(parts.terminations == 2)

        h.coordinator.handle(.command(.record))
        await waitUntil { h.coordinator.phase?.isRecording == true }
        h.coordinator.applicationWillTerminate()
        #expect(parts.terminations == 3)
        #expect(parts.ends == 0)
        h.coordinator.handle(.command(.cancel))
        #expect(parts.ends == 1)
    }

    @Test func theSessionEndRestoresOnAFailedStartAMidRecordingFailureAndACancelDuringStart() async {
        let (h, parts) = harness()
        defer { h.cleanUp() }
        h.failNextStart = true
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.record))
        await waitUntil { !h.coordinator.isSessionActive }
        #expect(parts.ends == 1)

        await waitUntil { !h.coordinator.isBusy }
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.record))
        await waitUntil { h.log.entries.contains("chrome.started") }
        h.pipelines.last?.onFailure?(RecordingCoordinatorTests.FakePipeline.Failure())
        #expect(parts.ends == 2)

        await waitUntil { !h.coordinator.isBusy }
        h.suspendNextStart = true
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.record))
        await waitUntil { h.pipelines.last?.continuation != nil }
        h.coordinator.handle(.command(.cancel))
        #expect(parts.ends == 3)
        h.pipelines.last?.finishStart()
        await waitUntil { !h.coordinator.isBusy }
        #expect(parts.ends == 3)
    }

    /// Every session reports its target when it begins — Retake included,
    /// which reuses a W + part target without a snap visit (review 2
    /// finding 2: the session adopts a restore still owed on that app).
    @Test func everySessionReportsItsTargetRetakeIncluded() async {
        let (h, parts) = harness()
        defer { h.cleanUp() }
        let element = WindowPartElement(processID: 77) { nil }
        let part = RecordingTarget.windowPart(
            WindowPartTarget(
                windowID: 5, windowFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
                frame: CGRect(x: 100, y: 100, width: 800, height: 520), name: "Web page", element: element
            ),
            displayID: 1
        )
        #expect(h.coordinator.beginSession(target: part, userApp: nil))
        #expect(parts.began == [part])
        h.coordinator.handle(.command(.record))
        await waitUntil { h.log.entries.contains("chrome.started") }
        h.coordinator.stop()
        await waitUntil { h.isPresenting }

        h.window?.onRetake?()
        #expect(parts.began == [part, part])
        h.coordinator.handle(.command(.cancel))
    }

    /// The window's frame reports carry the part along (`withWindowFrame`):
    /// the recorded crop is window-local, so the part keeps its place in it.
    @Test func aMovingWindowCarriesThePartTarget() async {
        let (h, _) = harness()
        defer { h.cleanUp() }
        let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let part = RecordingTarget.windowPart(
            WindowPartTarget(
                windowID: 5, windowFrame: windowFrame, frame: CGRect(x: 100, y: 100, width: 800, height: 520),
                name: "Web page", element: nil
            ),
            displayID: 1
        )
        #expect(h.coordinator.beginSession(target: part, userApp: nil))
        h.coordinator.handle(.command(.record))
        for _ in 0..<500 where h.pipelines.isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }
        h.pipelines.first?.onWindowFrameChange?(windowFrame.offsetBy(dx: 40, dy: 30))
        #expect(h.coordinator.session?.target.frame == CGRect(x: 140, y: 130, width: 800, height: 520))
        #expect(h.coordinator.session?.target.windowFrame == windowFrame.offsetBy(dx: 40, dy: 30))
        h.coordinator.handle(.command(.cancel))
    }

    // MARK: V3 — the live part, tracking's end, Retake (Q37, Q41)

    private static let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    private static let partFrame = CGRect(x: 100, y: 100, width: 800, height: 520)

    private func partTarget(_ element: WindowPartElement?) -> RecordingTarget {
        .windowPart(
            WindowPartTarget(windowID: 5, windowFrame: Self.windowFrame, frame: Self.partFrame, name: "Web page", element: element),
            displayID: 1
        )
    }

    /// A finished W + part take and its window's Retake.
    private func finishTake(_ h: RecordingCoordinatorTests.Harness, _ target: RecordingTarget) async {
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.record))
        await waitUntil { h.log.entries.contains("chrome.started") }
        h.coordinator.stop()
        await waitUntil { h.isPresenting }
    }

    /// The pipeline's part report moves the part inside its window — the
    /// border, toolbar and ink panel follow `session.target.frame` (Q42).
    @Test func aPartReportMovesThePartNotItsWindow() async {
        let (h, _) = harness()
        defer { h.cleanUp() }
        #expect(h.coordinator.beginSession(target: partTarget(nil), userApp: nil))
        h.coordinator.handle(.command(.record))
        await waitUntil { !h.pipelines.isEmpty }
        let sidebar = CGRect(x: 100, y: 100, width: 300, height: 520)
        h.pipelines.first?.onPartFrameChange?(sidebar)
        #expect(h.coordinator.session?.target.frame == sidebar)
        #expect(h.coordinator.session?.target.windowFrame == Self.windowFrame)
        h.coordinator.handle(.command(.cancel))

        // A plain window target ignores a part report.
        await waitUntil { !h.coordinator.isBusy }
        let window = RecordingTarget.window(windowID: 5, frame: Self.windowFrame, displayID: 1)
        #expect(h.coordinator.beginSession(target: window, userApp: nil))
        h.coordinator.handle(.command(.record))
        await waitUntil { h.pipelines.count == 2 }
        h.pipelines.last?.onPartFrameChange?(sidebar)
        #expect(h.coordinator.session?.target == window)
        h.coordinator.handle(.command(.cancel))
    }

    /// The pipeline stops following the part **before** the session's tree
    /// switches are restored — also on Cancel, when its `stop()` comes later
    /// (draining): a frame read after the restore would re-own the app.
    @Test func trackingEndsBeforeTheSessionsRestores() async {
        let (h, parts) = harness()
        defer { h.cleanUp() }
        var trackingEndedAtRestore: Int?
        parts.onEnded = { trackingEndedAtRestore = h.pipelines.last?.trackingEnded }
        h.suspendNextStart = true
        #expect(h.coordinator.beginSession(target: partTarget(nil), userApp: nil))
        h.coordinator.handle(.command(.record))
        await waitUntil { h.pipelines.last?.continuation != nil }
        h.coordinator.handle(.command(.cancel))
        #expect(trackingEndedAtRestore == 1)
        #expect(h.pipelines.last?.stops == 0, "still draining")
        h.pipelines.last?.finishStart()
        await waitUntil { !h.coordinator.isBusy }
    }

    /// Retake (Q41): the same part, looked up again — at its live frame, in
    /// its window where it is now.
    @Test func retakeRestoresThePartAtItsLiveFrame() async {
        let (h, _) = harness()
        defer { h.cleanUp() }
        let live = Mutex<CGRect?>(CGRect(x: 150, y: 120, width: 700, height: 500))
        let element = WindowPartElement(processID: 7) { live.withLock { $0 } }
        await finishTake(h, partTarget(element))
        let movedWindow = Self.windowFrame.offsetBy(dx: 50, dy: 20)
        h.windowObservation = .onScreen(movedWindow)

        h.window?.onRetake?()
        #expect(h.coordinator.session?.target == partTarget(element), "Setup opens on the take's part at once")
        await waitUntil { h.coordinator.session?.target.frame != Self.partFrame }
        guard case .windowPart(let part, _) = h.coordinator.session?.target else {
            Issue.record("not a part target")
            return
        }
        #expect(part.element === element)
        #expect(part.frame == CGRect(x: 150, y: 120, width: 700, height: 500))
        #expect(part.windowFrame == movedWindow)
        h.coordinator.handle(.command(.cancel))
    }

    /// Retake of a part that is gone (tab closed) records the whole window (Q41).
    @Test func retakeOfAGonePartFallsBackToTheWholeWindow() async {
        let (h, _) = harness()
        defer { h.cleanUp() }
        let element = WindowPartElement(processID: 7) { nil }
        await finishTake(h, partTarget(element))
        h.windowObservation = .onScreen(Self.windowFrame)
        h.window?.onRetake?()
        await waitUntil {
            if case .window = h.coordinator.session?.target { true } else { false }
        }
        #expect(h.coordinator.session?.target == .window(windowID: 5, frame: Self.windowFrame, displayID: 1))
        h.coordinator.handle(.command(.cancel))
    }

    /// Retake whose window has closed: its region as an area, as Setup does
    /// when the chosen window closes.
    @Test func retakeOfAClosedWindowKeepsItsRegion() async {
        let (h, _) = harness()
        defer { h.cleanUp() }
        let element = WindowPartElement(processID: 7) { nil }
        await finishTake(h, partTarget(element))
        h.windowObservation = .missing
        h.window?.onRetake?()
        await waitUntil { h.coordinator.session?.target.isWindow == false }
        #expect(h.coordinator.session?.target == .area(globalRect: Self.partFrame, displayID: 1))
        h.coordinator.handle(.command(.cancel))
    }

    /// Retake and Cancel in the same turn (review V3 finding 2): the
    /// look-up never reads the part — the cancelled session's restores are
    /// already posted, so a read would re-own the app.
    @Test func aRetakeCancelledInTheSameTurnNeverReadsThePart() async {
        let (h, _) = harness()
        defer { h.cleanUp() }
        let reads = Mutex(0)
        let element = WindowPartElement(processID: 7) {
            reads.withLock { $0 += 1 }
            return CGRect(x: 150, y: 120, width: 700, height: 500)
        }
        await finishTake(h, partTarget(element))
        let afterTake = reads.withLock { $0 }
        h.windowObservation = .onScreen(Self.windowFrame)
        h.window?.onRetake?()
        h.coordinator.handle(.command(.cancel))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(reads.withLock { $0 } == afterTake)
        #expect(!h.coordinator.isSessionActive)
    }

    /// A look-up that answers after the person picked another target (or
    /// left Setup) changes nothing.
    @Test func aLateRetakeLookUpNeverOverridesThePersonsChoice() async {
        let (h, _) = harness()
        defer { h.cleanUp() }
        let element = WindowPartElement(processID: 7) {
            try? await Task.sleep(for: .milliseconds(60))
            return CGRect(x: 150, y: 120, width: 700, height: 500)
        }
        await finishTake(h, partTarget(element))
        h.windowObservation = .onScreen(Self.windowFrame)
        h.window?.onRetake?()
        h.coordinator.handle(.targetChanged(target))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(h.coordinator.session?.target == target)
        h.coordinator.handle(.command(.cancel))
    }
}

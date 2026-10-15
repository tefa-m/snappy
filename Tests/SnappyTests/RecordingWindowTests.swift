import AppKit
import Foundation
import Testing
@testable import Snappy

@Suite struct RecordingWindowLayoutTests {
    private let visible = CGSize(width: 1440, height: 875)
    private let min = RecordingWindowLayout.minPlayerSize
    private let minWindow = RecordingWindowLayout.minWindowSize
    /// Everything around the player in the initial content size.
    private var chrome: CGSize {
        CGSize(
            width: 2 * RecordingWindowLayout.margin,
            height: 2 * RecordingWindowLayout.margin + RecordingWindowLayout.titlebarHeight
                + RecordingWindowLayout.statusBand
        )
    }

    @Test func pointSizeDividesByTheBackingScale() {
        #expect(RecordingWindowLayout.pointSize(videoPixels: CGSize(width: 1280, height: 720), scale: 2)
            == CGSize(width: 640, height: 360))
        #expect(RecordingWindowLayout.pointSize(videoPixels: CGSize(width: 1280, height: 720), scale: 0)
            == CGSize(width: 1280, height: 720))
    }

    @Test func mediumVideosOpenOneToOne() {
        let size = RecordingWindowLayout.contentSize(videoPoints: CGSize(width: 640, height: 360), visible: visible)
        #expect(size == CGSize(width: 640 + chrome.width, height: 360 + chrome.height))
    }

    @Test func largeVideosShrinkToEightyBySeventyPercentKeepingTheirAspect() {
        // 0.7 × 875 / 1080 is the binding factor.
        let size = RecordingWindowLayout.contentSize(videoPoints: CGSize(width: 1920, height: 1080), visible: visible)
        let fit = 0.7 * 875 / 1080.0
        #expect(abs(size.width - ((1920 * fit).rounded() + chrome.width)) < 0.001)
        #expect(abs(size.height - ((1080 * fit).rounded() + chrome.height)) < 0.001)
    }

    @Test func smallVideosGetTheMinimumWindow() {
        let size = RecordingWindowLayout.contentSize(videoPoints: CGSize(width: 100, height: 60), visible: visible)
        #expect(size == minWindow)
        #expect(RecordingWindowLayout.contentSize(videoPoints: .zero, visible: visible) == minWindow)
    }

    @Test func theWindowNeverOutgrowsTheVisibleFrame() {
        let tiny = CGSize(width: 400, height: 300)
        let size = RecordingWindowLayout.contentSize(videoPoints: CGSize(width: 2000, height: 50), visible: tiny)
        #expect(size.width <= tiny.width && size.height <= tiny.height)
    }

    private let area = CGRect(x: 0, y: 44, width: 800, height: 500)

    @Test func thePlayerAspectFitsIntoTheAreaInsideTheMargin() {
        let frame = RecordingWindowLayout.playerFrame(video: CGSize(width: 1920, height: 1080), in: area)
        let available = area.insetBy(dx: RecordingWindowLayout.margin, dy: RecordingWindowLayout.margin)
        #expect(available.contains(frame))
        #expect(frame.width == available.width) // width-bound: 768 / 1920 < 468 / 1080
        #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.01)
        #expect(abs(frame.midX - area.midX) <= 0.5 && abs(frame.midY - area.midY) <= 0.5)
        #expect(frame == frame.integral)

        let tall = RecordingWindowLayout.playerFrame(video: CGSize(width: 1000, height: 1000), in: area)
        #expect(tall.height == available.height) // height-bound
    }

    @Test func smallVideosAreUpscaledLikeTheEditorCanvas() {
        let frame = RecordingWindowLayout.playerFrame(video: CGSize(width: 100, height: 100), in: area)
        #expect(frame.width == frame.height)
        #expect(frame.height == area.height - 2 * RecordingWindowLayout.margin)
    }

    @Test func extremeAspectsKeepTheMinimumPlayerForTheControls() {
        let wide = RecordingWindowLayout.playerFrame(video: CGSize(width: 4000, height: 50), in: area)
        #expect(wide.height == min.height)
        let tall = RecordingWindowLayout.playerFrame(video: CGSize(width: 50, height: 4000), in: area)
        #expect(tall.width == min.width)
    }

    @Test func aTinyAreaClampsThePlayerAndNothingIsNegative() {
        let small = CGRect(x: 0, y: 0, width: 200, height: 100)
        let frame = RecordingWindowLayout.playerFrame(video: CGSize(width: 1920, height: 1080), in: small)
        #expect(small.insetBy(dx: RecordingWindowLayout.margin, dy: RecordingWindowLayout.margin).contains(frame))
        #expect(RecordingWindowLayout.playerFrame(video: CGSize(width: 1920, height: 1080), in: .zero) == .zero)
    }

    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private let window = CGSize(width: 700, height: 500)

    @Test func theFirstWindowIsCentred() {
        let origin = RecordingWindowLayout.origin(windowSize: window, visible: screen, occupied: [])
        #expect(origin == CGPoint(x: 370, y: 213)) // (1440 − 700) / 2, 25 + (875 − 500) / 2 rounded
    }

    @Test func aSecondWindowCascadesInsteadOfHidingTheFirst() {
        let first = RecordingWindowLayout.origin(windowSize: window, visible: screen, occupied: [])
        let second = RecordingWindowLayout.origin(windowSize: window, visible: screen, occupied: [first])
        #expect(second == CGPoint(x: first.x + 24, y: first.y - 24))
        let third = RecordingWindowLayout.origin(windowSize: window, visible: screen, occupied: [first, second])
        #expect(third == CGPoint(x: first.x + 48, y: first.y - 48))
        // A window moved elsewhere doesn't push the next one.
        let moved = RecordingWindowLayout.origin(windowSize: window, visible: screen, occupied: [.zero])
        #expect(moved == first)
    }

    @Test func cascadingStopsAtTheVisibleFrame() {
        let big = CGSize(width: 1400, height: 860)
        let first = RecordingWindowLayout.origin(windowSize: big, visible: screen, occupied: [])
        let origins = (0..<10).map { _ in first }
        let next = RecordingWindowLayout.origin(windowSize: big, visible: screen, occupied: origins)
        #expect(screen.contains(CGRect(origin: next, size: big)))
    }
}

@Suite struct RecordingWindowStatusTests {
    @Test func titleNamesThePixelSize() {
        #expect(RecordingWindowStatus.title(videoSize: CGSize(width: 1280, height: 720)) == "Recording 1280 × 720")
        #expect(RecordingWindowStatus.title(videoSize: nil) == "Recording")
        #expect(RecordingWindowStatus.title(videoSize: .zero) == "Recording")
    }

    @Test func capsuleAddsTheDurationRoundedToTheSecond() {
        let title = "Recording 1280 × 720"
        #expect(RecordingWindowStatus.text(title: title, duration: 41.6) == "Recording 1280 × 720 · 0:42")
        #expect(RecordingWindowStatus.text(title: title, duration: 0.2) == "Recording 1280 × 720 · 0:00")
        #expect(RecordingWindowStatus.text(title: title, duration: 3723) == "Recording 1280 × 720 · 1:02:03")
        #expect(RecordingWindowStatus.text(title: title, duration: nil) == title)
        #expect(RecordingWindowStatus.text(title: title, duration: .nan) == title)
    }
}

@Suite struct RecordingExportTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SnappyRecordingExportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTake(in directory: URL) throws -> URL {
        let take = directory.appending(path: "Take-1-abcd.mp4")
        try Data("video".utf8).write(to: take)
        return take
    }

    @Test func saveCopiesUnderTheRecordingNameAndKeepsTheTake() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let take = try makeTake(in: root)
        let folder = root.appending(path: "Desktop", directoryHint: .isDirectory)
        let moment = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try RecordingExport.save(take, to: folder, date: moment)
        let second = try RecordingExport.save(take, to: folder, date: moment)

        #expect(first.lastPathComponent == RecordingNamer.filename(for: moment))
        #expect(second.lastPathComponent == RecordingNamer.filename(for: moment, index: 2))
        #expect(try Data(contentsOf: take) == Data("video".utf8)) // Q18: the take survives Save
        #expect(try Data(contentsOf: second) == Data("video".utf8))
    }

    @Test func recordedDateIsTheTakesModificationDate() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let take = try makeTake(in: root)
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: moment], ofItemAtPath: take.path(percentEncoded: false))

        #expect(RecordingExport.recordedDate(of: take) == moment)
    }

    @Test func clipboardFileIsANamedCloneThatReplacesTheLastOne() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let take = try makeTake(in: root)
        let clipboard = root.appending(path: "Clipboard", directoryHint: .isDirectory)
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        let later = Date(timeIntervalSince1970: 1_800_000_100)

        let first = try RecordingExport.clipboardFile(for: take, in: clipboard, date: earlier)
        #expect(first.lastPathComponent == RecordingNamer.filename(for: earlier))
        let second = try RecordingExport.clipboardFile(for: take, in: clipboard, date: later)
        #expect(second.lastPathComponent == RecordingNamer.filename(for: later))

        let files = try FileManager.default.contentsOfDirectory(atPath: clipboard.path(percentEncoded: false))
        #expect(files == [second.lastPathComponent]) // the previous clone is gone
        #expect(try Data(contentsOf: second) == Data("video".utf8))
        #expect(FileManager.default.fileExists(atPath: take.path(percentEncoded: false)))
    }

    @MainActor
    @Test func copyPutsTheFileURLOnThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SnappyTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let file = URL(fileURLWithPath: "/tmp/Recording 2026-10-09 at 14.32.05.mp4")

        RecordingExport.copyToPasteboard(file, pasteboard: pasteboard)

        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls == [file])
        #expect(pasteboard.types?.contains(.fileURL) == true)
    }
}

@MainActor
@Suite struct RecordingWindowControllerTests {
    private func makeTake() throws -> URL {
        let take = FileManager.default.temporaryDirectory.appending(path: "SnappyWindowTake-\(UUID().uuidString).mp4")
        try Data("not really a video".utf8).write(to: take)
        return take
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func closeBeforeTheTakeLoadedFiresOnCloseOnceAndNeverDeletesTheTake() async throws {
        let take = try makeTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let window = RecordingWindowController(
            take: take, anchorRect: CGRect(x: 0, y: 0, width: 400, height: 300), onRetake: nil,
            context: RecordingWindowContext(savedFiles: RecordingSavedFiles(), mayTakeFocus: { true }),
            focus: RecordingWindowFocus(activate: {}, isActive: { true })
        )
        var closes = 0
        window.onClose = { closes += 1 }

        #expect(window.isOpen)
        #expect(window.take == take)
        window.show()
        window.close()
        #expect(!window.isOpen)
        window.close() // idempotent
        window.bringToFront() // a closed window never comes back
        await settle { closes > 0 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(closes == 1)
        #expect(FileManager.default.fileExists(atPath: take.path(percentEncoded: false)))
    }

    /// Activation requests, and whether macOS has granted one.
    @MainActor final class Focus {
        var activations = 0
        var active = false
        var mayTakeFocus = true
        var focus: RecordingWindowFocus {
            RecordingWindowFocus(activate: { self.activations += 1 }, isActive: { self.active })
        }
    }

    private func makeWindow(
        take: URL, focus: Focus, savedFiles: RecordingSavedFiles = RecordingSavedFiles(),
        settings: SettingsStore = .shared,
        loadVideoInfo: @escaping @Sendable (URL) async -> RecordingVideoInfo = { _ in RecordingVideoInfo() }
    ) -> RecordingWindowController {
        RecordingWindowController(
            take: take, anchorRect: CGRect(x: 0, y: 0, width: 400, height: 300), onRetake: nil,
            context: RecordingWindowContext(savedFiles: savedFiles, mayTakeFocus: { focus.mayTakeFocus }),
            settings: settings, focus: focus.focus, loadVideoInfo: loadVideoInfo
        )
    }

    /// Fix round 1, finding 1: the window opens — and takes focus — inside
    /// the end of the session; the take's size arriving later (a newer
    /// recording or screenshot capture may be running by then) only updates
    /// it and never activates Snappy or moves key.
    @Test func aLateMetadataLoadNeverTakesFocusDuringANewerOperation() async throws {
        let take = try makeTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let focus = Focus()
        focus.active = true
        let (infos, release) = AsyncStream.makeStream(of: RecordingVideoInfo.self)
        let window = makeWindow(take: take, focus: focus) { _ in
            for await info in infos { return info }
            return RecordingVideoInfo()
        }
        defer { window.close() }

        window.show()
        #expect(window.focusRequests == 1, "shown and focused synchronously")
        #expect(focus.activations == 1)
        #expect(window.windowTitle == "Recording")

        focus.mayTakeFocus = false // recording B / a frozen screenshot capture started
        release.yield(RecordingVideoInfo(size: CGSize(width: 1280, height: 720), duration: 42))
        await settle { window.windowTitle != "Recording" }
        #expect(window.windowTitle == "Recording 1280 × 720")
        #expect(window.focusRequests == 1, "the load never asks for focus")
        #expect(focus.activations == 1)
        #expect(window.lateKeyGrants == 0)
    }

    /// Fix round 1, finding 2: a declined activation (W-window auto-stop) is
    /// handled — the window waits for a late activation and takes key then.
    @Test func aLateActivationMakesTheWaitingWindowKey() async throws {
        let take = try makeTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let focus = Focus()
        let window = makeWindow(take: take, focus: focus)
        defer { window.close() }

        window.show()
        #expect(window.isAwaitingActivation, "declined: waits for the activation")
        focus.active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        await settle { window.lateKeyGrants > 0 }
        #expect(window.lateKeyGrants == 1)
        #expect(!window.isAwaitingActivation)
    }

    /// … but never while a newer operation runs, and not after the grace —
    /// an unrelated activation later (⇧⌘4) must not steal key.
    @Test func aLateActivationDuringANewerOperationOrAfterTheGraceIsIgnored() async throws {
        let take = try makeTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let focus = Focus()
        let window = makeWindow(take: take, focus: focus)
        defer { window.close() }

        window.show()
        focus.mayTakeFocus = false
        try? await Task.sleep(for: RecordingWindowController.focusRetry + .milliseconds(50))
        #expect(focus.activations == 1, "no retry during a newer operation")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        await settle { !window.isAwaitingActivation }
        #expect(window.lateKeyGrants == 0)

        // A second request (Reopen) that nobody grants expires.
        focus.mayTakeFocus = true
        window.bringToFront()
        #expect(window.isAwaitingActivation)
        await settle { focus.activations == 3 }
        #expect(focus.activations == 3, "one retry while nothing newer runs")
        try? await Task.sleep(for: RecordingWindowController.focusGrace)
        #expect(!window.isAwaitingActivation, "expires after the grace")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(window.lateKeyGrants == 0)
    }

    @Test func closingEndsAWaitingFocusRequest() throws {
        let take = try makeTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let window = makeWindow(take: take, focus: Focus())
        window.show()
        #expect(window.isAwaitingActivation)
        window.close()
        #expect(!window.isAwaitingActivation)
    }

    /// Fix round 1, finding 3: Save → close → Reopen → Copy pastes the saved
    /// file, even when the Save only finishes after its window closed.
    @Test func aSaveFinishingAfterItsWindowClosedIsPastedByTheReopenedWindow() async throws {
        let take = try makeTake()
        let folder = FileManager.default.temporaryDirectory.appending(path: "SnappyWindowSave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "SnappyTests.RecordingWindowSave.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: take)
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        let settings = SettingsStore(defaults: defaults)
        settings.saveDirectory = folder
        let savedFiles = RecordingSavedFiles()
        let focus = Focus()
        focus.active = true

        let first = makeWindow(take: take, focus: focus, savedFiles: savedFiles, settings: settings)
        first.show()
        first.perform(.save)
        first.close() // before the off-main copy has finished
        await settle { savedFiles.savedFile(for: take) != nil }
        let saved = try #require(savedFiles.savedFile(for: take))
        #expect(saved.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)

        let reopened = makeWindow(take: take, focus: focus, savedFiles: savedFiles, settings: settings)
        defer { reopened.close() }
        reopened.show()
        #expect(try reopened.fileToCopy() == saved, "the saved file, not a fresh clone")
    }

    @Test func theToolbarLeavesRetakeOutWhenTheTakeCantBeRetaken() {
        #expect(RecordingWindowController.toolbarOrder(hasRetake: true)
            == [.recordingRetake, .flexibleSpace, .recordingSave, .recordingCopy])
        #expect(RecordingWindowController.toolbarOrder(hasRetake: false)
            == [.flexibleSpace, .recordingSave, .recordingCopy])
    }
}

/// Review round 1, finding 1: an accepted Save must survive the take being
/// deleted (its window closed, a newer take released it) before the off-main
/// export runs.
@Suite struct RecordingSaveStagingTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SnappySaveStagingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func aStagedSaveSurvivesTheNextTakeDeletingTheOriginal() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingTempStore(directory: root.appending(path: "Recordings", directoryHint: .isDirectory))
        let take = try store.prepareNewTake()
        try Data("the take".utf8).write(to: take)
        let folder = root.appending(path: "Desktop", directoryHint: .isDirectory)
        let moment = Date(timeIntervalSince1970: 1_800_000_000)

        // Save accepted: staged synchronously, export still pending …
        let staged = try RecordingExport.stage(take)
        // … the window closes, or a newer take finishes, and the ledger
        // releases the take: it is unlinked …
        store.prune(keeping: [])
        #expect(!exists(take))
        // … and the delayed, off-main export still succeeds.
        let saved = try await Task.detached {
            try await Task.sleep(for: .milliseconds(20))
            return try RecordingExport.save(staged: staged, to: folder, date: moment)
        }.value

        #expect(saved.lastPathComponent == RecordingNamer.filename(for: moment))
        #expect(try Data(contentsOf: saved) == Data("the take".utf8))
        #expect(!exists(staged.deletingLastPathComponent())) // staging cleaned up
        #expect(store.lastTake == nil) // nothing leaked into the take store
    }

    @Test func stagingFallsBackToACloneWhenLinkingFails() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let take = root.appending(path: "Take-1-abcd.mp4")
        try Data("video".utf8).write(to: take)

        let staged = try RecordingExport.stage(take, link: { _, _ in EXDEV })
        defer { RecordingExport.discardStaged(staged) }
        try FileManager.default.removeItem(at: take)

        #expect(try Data(contentsOf: staged) == Data("video".utf8))
    }

    /// Review round 2: staging must never fabricate a missing take (Foundation
    /// can create the path while picking replacement storage for it — that
    /// depends on the environment, so the guard comes first, unconditionally).
    @Test func stagingAMissingTakeThrowsAndNeverCreatesIt() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingTempStore(directory: root)
        let gone = root.appending(path: "Take-gone.mp4")
        var linked = false

        #expect(throws: (any Error).self) {
            try RecordingExport.stage(gone, link: { _, _ in linked = true; return 0 })
        }
        #expect(!linked) // refused before any staging work
        #expect(!exists(gone))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).isEmpty)
        #expect(store.lastTake == nil) // no empty take for "Reopen Last Recording"
    }

    @Test func stagingRefusesSomethingThatIsNotAFile() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Take-1-abcd.mp4", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) { try RecordingExport.stage(folder) }
    }

    @Test func aStagedTakeHasTheTakesBytes() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let take = root.appending(path: "Take-1-abcd.mp4")
        try Data("the whole take".utf8).write(to: take)

        let staged = try RecordingExport.stage(take)
        defer { RecordingExport.discardStaged(staged) }

        #expect(staged != take)
        #expect(try Data(contentsOf: staged) == Data("the whole take".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)) == [take.lastPathComponent])
    }

    @Test func aFailedStagedSaveStillRemovesTheStagingName() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let take = root.appending(path: "Take-1-abcd.mp4")
        try Data("video".utf8).write(to: take)
        let staged = try RecordingExport.stage(take)
        // A file where the Save folder should be: createDirectory fails.
        let blocked = root.appending(path: "NotAFolder")
        try Data("x".utf8).write(to: blocked)

        #expect(throws: (any Error).self) {
            try RecordingExport.save(staged: staged, to: blocked, date: .now)
        }
        #expect(!exists(staged.deletingLastPathComponent()))
        #expect(exists(take)) // the take itself is never touched
    }
}

/// Review round 1, finding 2: Space is play/pause at the window level, even
/// with a button focused (Full Keyboard Access).
@MainActor
@Suite struct RecordingWindowKeyTests {
    private final class FocusableButton: NSButton {
        var pressed = false
        override var acceptsFirstResponder: Bool { true }
        override func performClick(_ sender: Any?) { pressed = true }
    }

    private func keyDown(_ window: NSWindow, _ keyCode: UInt16, _ characters: String,
                         _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    @Test func spaceIsPlayPauseEvenWithAFocusedButton() throws {
        let window = RecordingWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 320))
        defer { window.close() }
        let button = FocusableButton(title: "Save", target: nil, action: nil)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        content.addSubview(button)
        window.contentView = content
        #expect(window.makeFirstResponder(button))
        var actions: [RecordingWindowAction] = []
        window.onAction = { actions.append($0) }

        window.sendEvent(keyDown(window, RecordingWindowAction.spaceKeyCode, " "))

        #expect(actions == [.playPause])
        #expect(!button.pressed)
    }

    @Test func shortcutsDispatchThroughTheWindowAndPlainCAndSDoNot() {
        let window = RecordingWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 320))
        defer { window.close() }
        var actions: [RecordingWindowAction] = []
        window.onAction = { actions.append($0) }

        window.sendEvent(keyDown(window, 15, "r"))
        window.sendEvent(keyDown(window, 8, "c"))
        window.sendEvent(keyDown(window, 1, "s"))
        #expect(window.performKeyEquivalent(with: keyDown(window, 1, "s", .command)))
        #expect(window.performKeyEquivalent(with: keyDown(window, 8, "c", [.command, .shift])))
        window.sendEvent(keyDown(window, RecordingWindowAction.escapeKeyCode, "\u{1b}"))

        #expect(window.performKeyEquivalent(with: keyDown(window, 13, "w", .command)))
        window.sendEvent(keyDown(window, 12, "q"))

        #expect(actions == [.retake, .save, .copy, .close, .close, .close])
    }
}

/// Fix round 1, finding 3: saved files belong to the take, not its window.
@MainActor
@Suite struct RecordingSavedFilesTests {
    private func makeFile(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SnappySavedFiles-\(UUID().uuidString)-\(name)")
        try Data(name.utf8).write(to: url)
        return url
    }

    @Test func remembersTheSavedFileWhileBothExist() throws {
        let take = try makeFile("take.mp4"), saved = try makeFile("Recording.mp4")
        defer { [take, saved].forEach { try? FileManager.default.removeItem(at: $0) } }
        let files = RecordingSavedFiles()
        #expect(files.savedFile(for: take) == nil)
        files.record(saved, for: take)
        #expect(files.savedFile(for: take) == saved)
        try FileManager.default.removeItem(at: saved)
        #expect(files.savedFile(for: take) == nil, "a saved file deleted since is not pasted")
    }

    @Test func aSaveOfADeletedTakeIsNotRecorded() throws {
        let take = try makeFile("take.mp4"), saved = try makeFile("Recording.mp4")
        defer { try? FileManager.default.removeItem(at: saved) }
        try FileManager.default.removeItem(at: take)
        let files = RecordingSavedFiles()
        files.record(saved, for: take)
        try Data("again".utf8).write(to: take) // a new file at the same path
        defer { try? FileManager.default.removeItem(at: take) }
        #expect(files.savedFile(for: take) == nil)
    }

    @Test func retainForgetsTakesThatAreGone() throws {
        let kept = try makeFile("kept.mp4"), dropped = try makeFile("dropped.mp4"), saved = try makeFile("Recording.mp4")
        defer { [kept, dropped, saved].forEach { try? FileManager.default.removeItem(at: $0) } }
        let files = RecordingSavedFiles()
        files.record(saved, for: kept)
        files.record(saved, for: dropped)
        files.retain(only: [kept])
        #expect(files.savedFile(for: kept) == saved)
        #expect(files.savedFile(for: dropped) == nil)
    }
}

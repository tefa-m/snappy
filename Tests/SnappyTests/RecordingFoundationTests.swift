import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Snappy

@Suite("RecordingTarget")
struct RecordingTargetTests {
    private let rect = CGRect(x: 100, y: 50, width: 400, height: 300)

    @Test func accessors() {
        let area = RecordingTarget.area(globalRect: rect, displayID: 7)
        #expect(area.frame == rect && area.displayID == 7 && area.windowID == nil && !area.isWindow)
        let window = RecordingTarget.window(windowID: 99, frame: rect, displayID: 3)
        #expect(window.frame == rect && window.displayID == 3 && window.windowID == 99 && window.isWindow)
    }

    @Test func withFrameKeepsKindWindowAndDisplay() {
        let moved = CGRect(x: 0, y: 0, width: 640, height: 480)
        #expect(RecordingTarget.area(globalRect: rect, displayID: 2).withFrame(moved)
            == .area(globalRect: moved, displayID: 2))
        #expect(RecordingTarget.window(windowID: 5, frame: rect, displayID: 2).withFrame(moved)
            == .window(windowID: 5, frame: moved, displayID: 2))
    }

    @Test func withFrameStandardizes() {
        let flipped = CGRect(x: 100, y: 100, width: -50, height: -20)
        #expect(RecordingTarget.area(globalRect: rect, displayID: 1).withFrame(flipped).frame
            == CGRect(x: 50, y: 80, width: 50, height: 20))
    }

    @Test func asAreaKeepsTheRegion() {
        #expect(RecordingTarget.window(windowID: 5, frame: rect, displayID: 4).asArea
            == .area(globalRect: rect, displayID: 4))
    }

    @Test func areaIsClampedToItsDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let overhanging = CGRect(x: 1300, y: 800, width: 400, height: 300)
        #expect(RecordingTarget.area(overhanging, clampedTo: screen, displayID: 1)
            == .area(globalRect: CGRect(x: 1300, y: 800, width: 140, height: 100), displayID: 1))
        #expect(RecordingTarget.area(rect, clampedTo: screen, displayID: 1)
            == .area(globalRect: rect, displayID: 1))
    }

    @Test func areaOnASecondDisplayWithNegativeOrigin() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: -100, y: 100, width: 300, height: 200) // crosses onto the main display
        #expect(RecordingTarget.area(rect, clampedTo: left, displayID: 2)
            == .area(globalRect: CGRect(x: -100, y: 100, width: 100, height: 200), displayID: 2))
    }

    @Test func areaOffTheDisplayOrEmptyIsNil() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(RecordingTarget.area(CGRect(x: 2000, y: 0, width: 100, height: 100), clampedTo: screen, displayID: 1) == nil)
        #expect(RecordingTarget.area(CGRect(x: 1440, y: 0, width: 100, height: 100), clampedTo: screen, displayID: 1) == nil)
        #expect(RecordingTarget.area(CGRect(x: 10, y: 10, width: 0, height: 100), clampedTo: screen, displayID: 1) == nil)
    }
}

@Suite("RecordingSettings")
struct RecordingSettingsTests {
    @Test func defaultsMatchTheFeatureDocTable() {
        let s = RecordingSettings()
        #expect(s.countdown == .three && s.countdown.seconds == 3)
        #expect(s.frameRate == .fps60 && s.frameRate.framesPerSecond == 60)
        #expect(s.showsCursor)
        #expect(s.showsClicks)
        #expect(!s.fadingInkAtStart)
        #expect(s.fadeDelay == 3)
        #expect(s.defaultColor == .red)
        #expect(s.defaultWidth == .medium)
        #expect(s.quality == .high)
        #expect(s.drawModeHotKey == HotKeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | optionKey)))
        #expect(s.magicPenHotKey == HotKeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey)))
        #expect(s.magicPenWidth == .medium)
    }

    @Test func offeredValues() {
        #expect(RecordingCountdown.allCases.map(\.seconds) == [0, 1, 2, 3, 5])
        #expect(RecordingFrameRate.allCases.map(\.framesPerSecond) == [30, 60])
        #expect(RecordingQuality.allCases == [.standard, .high])
    }

    @Test func fadeDelayIsClampedToOneThroughTen() {
        var s = RecordingSettings()
        s.fadeDelay = 0
        #expect(s.fadeDelay == 1)
        s.fadeDelay = 11
        #expect(s.fadeDelay == 10)
        s.fadeDelay = 7
        #expect(s.fadeDelay == 7)
        #expect(RecordingSettings.clampedFadeDelay(-5) == 1)
    }

    @Test func drawModeHotKeyIsDistinctFromTheCaptureKeys() {
        #expect(HotKeyCombo.defaultDrawMode != .defaultCapture)
        #expect(HotKeyCombo.defaultDrawMode != .defaultFullscreen)
    }

    @Test func magicPenHotKeyIsDistinctFromEveryOtherAndHoldsControlOrOption() {
        let magic = HotKeyCombo.defaultMagicPen
        #expect(magic != .defaultCapture && magic != .defaultFullscreen && magic != .defaultDrawMode)
        #expect(magic.carbonModifiers & UInt32(controlKey | optionKey) != 0)
        #expect(magic.carbonModifiers & UInt32(cmdKey) == 0) // never a ⌘ combo the recorded app needs
        #expect(magic.displayString == "⌃⌥P")
    }

    @MainActor private func withStore(_ body: (UserDefaults, SettingsStore) throws -> Void) throws {
        let suiteName = "SnappyTests.Recording.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults, SettingsStore(defaults: defaults))
    }

    @Test @MainActor func freshStoreReadsTheDefaults() throws {
        try withStore { _, store in
            #expect(store.recordingSettings == RecordingSettings())
        }
    }

    @Test @MainActor func everyOptionRoundTripsThroughUserDefaults() throws {
        try withStore { defaults, store in
            let custom = RecordingSettings(
                countdown: .five, frameRate: .fps30, showsCursor: false, showsClicks: false,
                fadingInkAtStart: true, fadeDelay: 8, defaultColor: .blue, defaultWidth: .thick,
                quality: .standard,
                drawModeHotKey: HotKeyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(cmdKey | optionKey)),
                magicPenHotKey: HotKeyCombo(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(controlKey)),
                magicPenWidth: .thick
            )
            store.recordingSettings = custom
            // A fresh store over the same persisted defaults.
            let reread = SettingsStore(defaults: defaults)
            #expect(reread.recordingSettings == custom)
            // Each individual accessor (T6's UI binds these) agrees.
            #expect(reread.recordingCountdown == .five)
            #expect(reread.recordingFrameRate == .fps30)
            #expect(!reread.recordingShowsCursor)
            #expect(!reread.recordingShowsClicks)
            #expect(reread.recordingFadingInkAtStart)
            #expect(reread.recordingFadeDelay == 8)
            #expect(reread.recordingDefaultColor == .blue)
            #expect(reread.recordingDefaultWidth == .thick)
            #expect(reread.recordingQuality == .standard)
            #expect(reread.recordingDrawModeHotKey == custom.drawModeHotKey)
            #expect(reread.recordingMagicPenHotKey == custom.magicPenHotKey)
            #expect(reread.recordingMagicPenWidth == .thick)
        }
    }

    @Test @MainActor func individualAccessorsRoundTrip() throws {
        try withStore { defaults, store in
            for countdown in RecordingCountdown.allCases {
                store.recordingCountdown = countdown
                #expect(SettingsStore(defaults: defaults).recordingCountdown == countdown)
            }
            for color in InkColorPreset.allCases {
                store.recordingDefaultColor = color
                #expect(SettingsStore(defaults: defaults).recordingDefaultColor == color)
            }
            for width in InkWidth.allCases {
                store.recordingDefaultWidth = width
                #expect(SettingsStore(defaults: defaults).recordingDefaultWidth == width)
            }
            for width in InkWidth.allCases {
                store.recordingMagicPenWidth = width
                #expect(SettingsStore(defaults: defaults).recordingMagicPenWidth == width)
            }
            store.recordingFadeDelay = 42
            #expect(SettingsStore(defaults: defaults).recordingFadeDelay == 10)
        }
    }

    @Test @MainActor func unreadableValuesFallBackToDefaults() throws {
        try withStore { defaults, store in
            defaults.set(4, forKey: "recordingCountdown")
            defaults.set(24, forKey: "recordingFrameRate")
            defaults.set("yes", forKey: "recordingShowsCursor")
            defaults.set(0, forKey: "recordingFadeDelay")
            defaults.set(9, forKey: "recordingDefaultColor")
            defaults.set(-1, forKey: "recordingDefaultWidth")
            defaults.set("ultra", forKey: "recordingQuality")
            defaults.set(["keyCode": 2], forKey: "recordingDrawModeHotKey")
            defaults.set("big", forKey: "recordingMagicPenHotKey")
            defaults.set(3, forKey: "recordingMagicPenWidth")
            var expected = RecordingSettings()
            expected.fadeDelay = 1 // a stored 0 clamps rather than resetting
            #expect(store.recordingSettings == expected)
        }
    }

    @Test @MainActor func recordingKeysDontDisturbTheOtherSettings() throws {
        try withStore { defaults, store in
            store.recordingSettings = RecordingSettings(countdown: .off, drawModeHotKey: .defaultCapture)
            let reread = SettingsStore(defaults: defaults)
            #expect(reread.captureHotKey == .defaultCapture)
            #expect(reread.fullscreenHotKey == .defaultFullscreen)
            #expect(reread.canvasPadding == SettingsStore.defaultCanvasPadding)
        }
    }
}

@Suite("Live-ink vocabulary")
struct LiveInkVocabularyTests {
    @Test func colourPresetsAreTheFiveKeysInOrder() {
        #expect(InkColorPreset.allCases == [.red, .yellow, .green, .blue, .white])
        #expect(InkColorPreset.allCases.map(\.key) == ["1", "2", "3", "4", "5"])
        #expect(InkColorPreset.red.color == .red) // the editor's red
        #expect(InkColorPreset.white.color == .white)
        #expect(Set(InkColorPreset.allCases.map(\.title)).count == 5)
    }

    @Test func widthsStepAndClamp() {
        #expect(InkWidth.allCases == [.thin, .medium, .thick])
        #expect(InkWidth.thin.thinner == .thin)
        #expect(InkWidth.thin.thicker == .medium)
        #expect(InkWidth.medium.thicker == .thick)
        #expect(InkWidth.thick.thicker == .thick)
        #expect(InkWidth.thick.thinner == .medium)
        #expect(InkWidth.thin.points < InkWidth.medium.points && InkWidth.medium.points < InkWidth.thick.points)
        #expect(InkWidth.thin < InkWidth.thick)
    }

    @Test func styleSeededFromSettings() {
        var settings = RecordingSettings()
        settings.defaultColor = .green
        settings.defaultWidth = .thin
        settings.fadingInkAtStart = true
        settings.magicPenWidth = .thick
        #expect(InkStyle(settings: settings) == InkStyle(color: .green, width: .thin, fading: true, magicPenWidth: .thick))
    }

    @Test func magicPenWidthCommandsChangeOnlyTheMagicPenWidthAndClamp() {
        let style = InkStyle(color: .red, width: .medium, fading: false, magicPenWidth: .medium)
        #expect(style.applying(.magicPenThinner) == InkStyle(color: .red, width: .medium, fading: false, magicPenWidth: .thin))
        #expect(style.applying(.magicPenThicker).magicPenWidth == .thick)
        #expect(style.applying(.magicPenThicker).applying(.magicPenThicker).magicPenWidth == .thick)
        #expect(style.applying(.magicPenThinner).applying(.magicPenThinner).magicPenWidth == .thin)
        #expect(style.applying(.magicPenWidth(.thin)).magicPenWidth == .thin)
        #expect(style.applying(.magicPenWidth(.thin)).width == .medium)
        // The normal width steps leave the Magic Pen alone.
        #expect(style.applying(.thicker).magicPenWidth == .medium)
        for command: InkCommand in [.magicPenThinner, .magicPenThicker, .magicPenWidth(.thick)] {
            #expect(command.isStyle && command.changesMagicPenWidth, "\(command)")
        }
        for command: InkCommand in [.color(.red), .thinner, .thicker, .toggleFading, .clear, .undo, .redo] {
            #expect(!command.changesMagicPenWidth, "\(command)")
        }
    }

    @Test func magicPenLookIsVividAndSlightlyTransparent() {
        #expect(MagicPenLook.alpha == 0.85)
        #expect(MagicPenLook.alpha > LiveInk.highlighterAlpha)
        #expect(MagicPenLook.color.alpha == 1)
        #expect(MagicPenLook.color.red == 1) // a red-orange, full red channel
        #expect(MagicPenLook.color != InkColorPreset.red.color)
        #expect(MagicPenLook.haloColor.alpha > 0 && MagicPenLook.haloColor.alpha < 0.5)
        #expect(MagicPenLook.haloColor.relativeLuminance == 0)
    }

    @Test func styleCommandsChangeTheStyleContentCommandsDont() {
        let style = InkStyle(color: .red, width: .medium, fading: false)
        #expect(style.applying(.color(.yellow)).color == .yellow)
        #expect(style.applying(.thinner).width == .thin)
        #expect(style.applying(.thicker).width == .thick)
        #expect(style.applying(.toggleFading).fading)
        #expect(style.applying(.toggleFading).applying(.toggleFading) == style)
        for command: InkCommand in [.clear, .undo, .redo] {
            #expect(style.applying(command) == style)
            #expect(!command.isStyle)
        }
        for command: InkCommand in [.color(.blue), .thinner, .thicker, .toggleFading] {
            #expect(command.isStyle)
        }
    }

    @Test func windowLevelsStackSetupBelowInkBelowChrome() {
        #expect(RecordingWindowLevel.setup < RecordingWindowLevel.ink)
        #expect(RecordingWindowLevel.ink < RecordingWindowLevel.chrome)
        #expect(RecordingWindowLevel.setup > .floating) // above the screenshot preview panel
        #expect(RecordingWindowLevel.chrome < .popUpMenu)
        #expect(RecordingWindowLevel.chrome < .screenSaver) // below the area-capture overlay
    }

    @Test func decoratorTransformMapsTheTargetOntoTheOutputRect() {
        let target = CGRect(x: 100, y: 200, width: 400, height: 300)
        // 2× Retina, letterboxed 20 px from the left.
        let output = CGRect(x: 20, y: 0, width: 800, height: 600)
        let t = FrameDecoratingGeometry.transform(targetFrame: target, outputRect: output)
        #expect(CGPoint(x: 100, y: 200).applying(t) == CGPoint(x: 20, y: 0))
        #expect(CGPoint(x: 500, y: 500).applying(t) == CGPoint(x: 820, y: 600))
        #expect(CGPoint(x: 300, y: 350).applying(t) == CGPoint(x: 420, y: 300))
        #expect(FrameDecoratingGeometry.transform(targetFrame: .zero, outputRect: output) == .identity)
    }
}

@Suite("HotKeyAction ids")
struct HotKeyActionIDTests {
    @Test func idsAreStableAndAppendOnly() {
        #expect(HotKeyAction.captureArea.rawValue == 1)
        #expect(HotKeyAction.captureFullscreen.rawValue == 2)
        #expect(HotKeyAction.toggleDrawMode.rawValue == 3)
        #expect(HotKeyAction.toggleMagicPen.rawValue == 4)
        #expect(HotKeyAction.availabilityProbe.rawValue == 5)
        #expect(HotKeyAction.allCases
            == [.captureArea, .captureFullscreen, .toggleDrawMode, .toggleMagicPen, .availabilityProbe])
    }
}

@Suite("RecordingTempStore")
struct RecordingTempStoreTests {
    private func makeStore() throws -> RecordingTempStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SnappyTempStoreTests-\(UUID().uuidString)/Recordings", directoryHint: .isDirectory)
        return RecordingTempStore(directory: directory)
    }

    private func cleanUp(_ store: RecordingTempStore) {
        try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent())
    }

    @Test func defaultDirectoryIsInCaches() {
        let path = RecordingTempStore.defaultDirectory.path(percentEncoded: false)
        #expect(path.hasSuffix("/Library/Caches/com.tefa.snappy/Recordings/"))
    }

    @Test func noTakeBeforeTheFirstRecording() throws {
        let store = try makeStore()
        defer { cleanUp(store) }
        #expect(store.lastTake == nil) // the directory doesn't even exist yet
    }

    @Test func prepareCreatesTheDirectoryAndReturnsAnUnwrittenMP4() throws {
        let store = try makeStore()
        defer { cleanUp(store) }
        let url = try store.prepareNewTake()
        #expect(url.pathExtension == "mp4")
        #expect(url.deletingLastPathComponent().standardizedFileURL == store.directory.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: store.directory.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(store.lastTake == nil) // nothing written yet
    }

    @Test func writtenTakeIsTheLastTake() throws {
        let store = try makeStore()
        defer { cleanUp(store) }
        let url = try store.prepareNewTake()
        try Data("video".utf8).write(to: url)
        #expect(store.lastTake?.standardizedFileURL == url.standardizedFileURL)
    }

    /// v2 (Q30): open windows and the latest take keep theirs through the
    /// next recording — preparing a take never deletes one.
    @Test func preparingANewTakeDeletesNothing() throws {
        let store = try makeStore()
        defer { cleanUp(store) }
        let first = try store.prepareNewTake()
        try Data("one".utf8).write(to: first)
        let second = try store.prepareNewTake()
        #expect(second != first)
        #expect(FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))
        #expect(store.lastTake?.standardizedFileURL == first.standardizedFileURL) // second not written yet
    }

    @Test func pruneDeletesEveryTakeButTheKeptOnes() throws {
        let store = try makeStore()
        defer { cleanUp(store) }
        let urls = try (0..<3).map { index in
            let url = try store.prepareNewTake()
            try Data("take \(index)".utf8).write(to: url)
            return url
        }
        // Kept URLs match however they are spelled.
        let spelledDifferently = URL(fileURLWithPath: urls[2].path(percentEncoded: false)
            .replacingOccurrences(of: "/Recordings/", with: "/Recordings/./"))
        store.prune(keeping: [urls[0], spelledDifferently])
        #expect(FileManager.default.fileExists(atPath: urls[0].path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: urls[1].path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: urls[2].path(percentEncoded: false)))
        store.prune(keeping: [])
        #expect(store.lastTake == nil)
    }

    @Test func pruneLeavesOtherFilesAlone() throws {
        let store = try makeStore()
        defer { cleanUp(store) }
        _ = try store.prepareNewTake()
        let note = store.directory.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: note)
        store.prune(keeping: [])
        #expect(FileManager.default.fileExists(atPath: note.path(percentEncoded: false)))
        #expect(store.lastTake == nil)
    }

    @Test func lastTakeIsTheNewestWhenSeveralExist() throws {
        let store = try makeStore()
        defer { cleanUp(store) }
        _ = try store.prepareNewTake()
        let older = store.directory.appending(path: "a.mp4")
        let newer = store.directory.appending(path: "b.mp4")
        try Data("a".utf8).write(to: older)
        try Data("b".utf8).write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: newer.path(percentEncoded: false)
        )
        #expect(store.lastTake?.lastPathComponent == "a.mp4")
    }

    @Test func discardRemovesOneTake() throws {
        let store = try makeStore()
        defer { cleanUp(store) }
        let url = try store.prepareNewTake()
        try Data("partial".utf8).write(to: url)
        store.discard(url)
        #expect(store.lastTake == nil)
        store.discard(url) // already gone: no throw
    }
}

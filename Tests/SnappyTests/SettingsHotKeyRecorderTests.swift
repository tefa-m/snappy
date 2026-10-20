import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Snappy

/// The Settings window's shortcut recorders against a fake center: however
/// recording ends, the hot keys resume (review r1 #1), and an accepted combo
/// is bound **before** they resume (review r1 #2).
@MainActor
@Suite("Settings shortcut recorders", .serialized)
struct SettingsHotKeyRecorderTests {
    private let defaults: UserDefaults
    private let settings: SettingsStore
    private let center = GlobalHotKeysTests.Center()
    private let controller: SettingsWindowController

    init() {
        defaults = UserDefaults(suiteName: "SnappyTests.SettingsRecorder.\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        controller = SettingsWindowController(
            settings: settings, hotKeys: GlobalHotKeys(settings: settings, center: center)
        ) { _ in }
    }

    private static let cmdOpt5 = HotKeyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(cmdKey | optionKey))

    private func startRecording(_ hotKey: SnappyHotKey = .captureArea) {
        controller.recordShortcut(hotKey)
        #expect(controller.isRecordingShortcut)
        #expect(center.log == ["suspend"])
    }

    /// ⌥⌘5 typed into the recording field (⌘ combos arrive as key equivalents).
    private func type5() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
            windowNumber: controller.window.windowNumber, context: nil, characters: "5",
            charactersIgnoringModifiers: "5", isARepeat: false, keyCode: UInt16(kVK_ANSI_5)
        )!
        #expect(controller.window.performKeyEquivalent(with: event))
    }

    @Test func closingTheWindowMidRecordingResumesTheHotKeys() {
        startRecording()
        controller.window.close()
        #expect(!controller.isRecordingShortcut)
        #expect(center.log == ["suspend", "resume"])
    }

    @Test func losingKeyStatusMidRecordingResumesTheHotKeys() {
        startRecording(.magicPen)
        controller.window.resignKey()
        #expect(!controller.isRecordingShortcut)
        #expect(center.log == ["suspend", "resume"])
    }

    @Test func switchingAppsMidRecordingResumesTheHotKeys() {
        startRecording(.drawMode)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!controller.isRecordingShortcut)
        #expect(center.log == ["suspend", "resume"])
    }

    @Test func anAcceptedComboIsBoundBeforeTheHotKeysResume() {
        startRecording()
        type5()
        #expect(center.log == ["suspend", "replace", "resume"])
        #expect(settings.captureHotKey == Self.cmdOpt5)
        #expect(!controller.isRecordingShortcut)
        controller.window.close()
        #expect(center.log.count == 3, "nothing left to resume")
    }

    @Test func aRefusedComboKeepsTheOldOneAndStillResumes() {
        center.taken = [Self.cmdOpt5.key]
        startRecording()
        type5()
        #expect(center.log == ["suspend", "replace", "resume"])
        #expect(settings.captureHotKey == .defaultCapture)
        #expect(!controller.isRecordingShortcut)
    }

    @Test func openingSettingsRetriesARefusedHotKey() {
        center.unbound = [.captureArea]
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(center.retries == 1)
    }
}

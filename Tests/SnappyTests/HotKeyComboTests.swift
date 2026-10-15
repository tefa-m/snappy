import Carbon.HIToolbox
import Foundation
import Testing
@testable import Snappy

@Suite struct HotKeyComboTests {
    @Test func representationRoundTrips() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey | shiftKey))
        let decoded = HotKeyCombo(userDefaultsRepresentation: combo.userDefaultsRepresentation)
        #expect(decoded == combo)
    }

    @Test func defaultComboIsShiftCommand4() {
        let combo = HotKeyCombo.defaultCapture
        #expect(combo.keyCode == UInt32(kVK_ANSI_4))
        #expect(combo.carbonModifiers == UInt32(cmdKey | shiftKey))
    }

    @Test func decodeRejectsMissingFields() {
        #expect(HotKeyCombo(userDefaultsRepresentation: [:]) == nil)
        #expect(HotKeyCombo(userDefaultsRepresentation: ["keyCode": 21]) == nil)
        #expect(HotKeyCombo(userDefaultsRepresentation: ["modifiers": 768]) == nil)
    }

    @Test func decodeRejectsOutOfRangeValues() {
        #expect(HotKeyCombo(userDefaultsRepresentation: ["keyCode": -1, "modifiers": 768]) == nil)
        #expect(HotKeyCombo(userDefaultsRepresentation: ["keyCode": 21, "modifiers": Int.max]) == nil)
    }

    @Test @MainActor func settingsStoreRoundTripsThroughUserDefaults() throws {
        let suiteName = "SnappyTests.HotKeyCombo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.captureHotKey == .defaultCapture)

        let custom = HotKeyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(optionKey | controlKey))
        store.captureHotKey = custom
        // Read back through a fresh store over the same persisted defaults.
        #expect(SettingsStore(defaults: defaults).captureHotKey == custom)
    }

    // MARK: - Fullscreen hot key (⇧⌘3)

    @Test func defaultFullscreenComboIsShiftCommand3() {
        let combo = HotKeyCombo.defaultFullscreen
        #expect(combo.keyCode == UInt32(kVK_ANSI_3))
        #expect(combo.carbonModifiers == UInt32(cmdKey | shiftKey))
    }

    @Test func areaAndFullscreenDefaultsAreDistinct() {
        #expect(HotKeyCombo.defaultCapture != HotKeyCombo.defaultFullscreen)
    }

    @Test @MainActor func theTwoHotKeysUseSeparateDefaultsKeys() throws {
        let suiteName = "SnappyTests.HotKeyCombo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.fullscreenHotKey == .defaultFullscreen)

        let custom = HotKeyCombo(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: UInt32(optionKey))
        store.fullscreenHotKey = custom

        let reread = SettingsStore(defaults: defaults)
        #expect(reread.fullscreenHotKey == custom)
        // Changing one binding must not disturb the other.
        #expect(reread.captureHotKey == .defaultCapture)
    }

    @Test func hotKeyActionIdsAreUniqueAndNonZero() {
        let ids = HotKeyAction.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(0))
    }
}

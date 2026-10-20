import Carbon.HIToolbox
import Foundation
import Testing
@testable import Snappy

/// Remappable hot keys (2026-10-20): `GlobalHotKeys` validates, binds and
/// only then saves; a refused combo leaves the old one bound and saved.
@MainActor
@Suite("GlobalHotKeys")
struct GlobalHotKeysTests {
    /// Accepts or refuses like Carbon would.
    final class Center: HotKeyRebinding {
        var taken: Set<HotKeyCombo.Key> = []
        private(set) var replaced: [(HotKeyAction, HotKeyCombo)] = []
        private(set) var probed: [HotKeyCombo] = []
        private(set) var suspensions: [Bool] = []
        func replace(_ action: HotKeyAction, with combo: HotKeyCombo) -> Bool {
            guard !taken.contains(combo.key) else { return false }
            replaced.append((action, combo))
            return true
        }
        func isAvailable(_ combo: HotKeyCombo) -> Bool {
            probed.append(combo)
            return !taken.contains(combo.key)
        }
        func setSuspended(_ suspended: Bool) { suspensions.append(suspended) }
    }

    private let defaults: UserDefaults
    private let settings: SettingsStore
    private let center = Center()
    private let hotKeys: GlobalHotKeys

    init() {
        defaults = UserDefaults(suiteName: "SnappyTests.GlobalHotKeys.\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        hotKeys = GlobalHotKeys(settings: settings, center: center)
    }

    private static let ctrlOptX = HotKeyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(controlKey | optionKey))
    private static let cmdOpt5 = HotKeyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(cmdKey | optionKey))

    @Test func aCaptureComboIsReplacedLiveThenSavedAndAnnounced() {
        var changes: [(SnappyHotKey, HotKeyCombo)] = []
        hotKeys.onChange.append { changes.append(($0, $1)) }
        #expect(hotKeys.set(.captureArea, to: Self.cmdOpt5) == nil)
        #expect(center.replaced.map(\.0) == [.captureArea])
        #expect(settings.captureHotKey == Self.cmdOpt5)
        #expect(SettingsStore(defaults: defaults).captureHotKey == Self.cmdOpt5, "persisted")
        #expect(changes.map(\.0) == [.captureArea])
        #expect(changes.map(\.1) == [Self.cmdOpt5])
        #expect(center.probed.isEmpty, "a lifetime hot key is rebound, not probed")
    }

    @Test func aComboTheSystemRefusesKeepsTheOldOne() {
        center.taken = [Self.cmdOpt5.key]
        var changes = 0
        hotKeys.onChange.append { _, _ in changes += 1 }
        #expect(hotKeys.set(.captureFullscreen, to: Self.cmdOpt5) == .unavailable(Self.cmdOpt5))
        #expect(settings.fullscreenHotKey == .defaultFullscreen)
        #expect(changes == 0)
    }

    @Test func anotherSnappyHotKeysComboIsRefusedBeforeTheSystemIsAsked() {
        #expect(hotKeys.set(.captureFullscreen, to: .defaultCapture)
            == .reserved(ReservedHotKey(combo: .defaultCapture, name: "Capture Area")))
        #expect(hotKeys.set(.magicPen, to: .defaultDrawMode)
            == .reserved(ReservedHotKey(combo: .defaultDrawMode, name: "Draw Mode")))
        #expect(center.replaced.isEmpty)
        #expect(center.probed.isEmpty)
        #expect(settings.hotKeyBindings == .defaults)
    }

    @Test func theSameComboAgainIsANoOp() {
        #expect(hotKeys.set(.captureArea, to: .defaultCapture) == nil)
        #expect(center.replaced.isEmpty)
    }

    @Test func outsideASessionASessionHotKeyIsProbed() {
        #expect(hotKeys.set(.drawMode, to: Self.ctrlOptX) == nil)
        #expect(center.probed == [Self.ctrlOptX])
        #expect(center.replaced.isEmpty, "nothing is registered outside a session")
        #expect(settings.recordingDrawModeHotKey == Self.ctrlOptX)

        let y = HotKeyCombo(keyCode: UInt32(kVK_ANSI_Y), carbonModifiers: UInt32(controlKey | optionKey))
        center.taken = [y.key]
        #expect(hotKeys.set(.magicPen, to: y) == .unavailable(y))
        #expect(settings.recordingMagicPenHotKey == .defaultMagicPen)
    }

    @Test func duringASessionTheCoordinatorRebindsASessionHotKey() {
        /// The coordinator's answer, and what it was asked.
        final class Session {
            var accepts = true
            var asked: [HotKeyCombo] = []
        }
        let session = Session()
        hotKeys.rebindSession = { hotKey, combo in
            #expect(hotKey == .magicPen)
            session.asked.append(combo)
            return session.accepts
        }
        #expect(hotKeys.set(.magicPen, to: Self.ctrlOptX) == nil)
        #expect(settings.recordingMagicPenHotKey == Self.ctrlOptX)
        session.accepts = false
        let y = HotKeyCombo(keyCode: UInt32(kVK_ANSI_Y), carbonModifiers: UInt32(controlKey))
        #expect(hotKeys.set(.magicPen, to: y) == .unavailable(y))
        #expect(settings.recordingMagicPenHotKey == Self.ctrlOptX, "the old one stays")
        #expect(session.asked == [Self.ctrlOptX, y])
        #expect(center.probed.isEmpty, "the live rebind is the check")
    }

    @Test func resetRestoresTheDefaultUnlessAnotherHotKeyHoldsIt() {
        #expect(hotKeys.set(.drawMode, to: Self.ctrlOptX) == nil)
        #expect(hotKeys.set(.magicPen, to: .defaultDrawMode) == nil)
        #expect(hotKeys.reset(.drawMode)
            == .reserved(ReservedHotKey(combo: .defaultDrawMode, name: "Magic Pen")))
        #expect(settings.recordingDrawModeHotKey == Self.ctrlOptX)
        #expect(hotKeys.reset(.magicPen) == nil)
        #expect(hotKeys.reset(.drawMode) == nil)
        #expect(settings.hotKeyBindings == .defaults)
    }

    @Test func aRecorderSuspendsTheCenterWhileItWaits() {
        hotKeys.setRecorderActive(true)
        hotKeys.setRecorderActive(false)
        #expect(center.suspensions == [true, false])
    }

    @Test func withoutACenterCombosAreValidatedAndSaved() {
        let plain = GlobalHotKeys(settings: settings, center: nil)
        #expect(plain.set(.captureArea, to: Self.cmdOpt5) == nil)
        #expect(plain.set(.captureFullscreen, to: Self.cmdOpt5)
            == .reserved(ReservedHotKey(combo: Self.cmdOpt5, name: "Capture Area")))
        #expect(settings.captureHotKey == Self.cmdOpt5)
    }

    @Test func settingsStoreReadsAndWritesAllFourBindings() {
        var bindings = HotKeyBindings.defaults
        bindings.captureArea = Self.cmdOpt5
        bindings.magicPen = Self.ctrlOptX
        settings.hotKeyBindings = bindings
        let reread = SettingsStore(defaults: defaults)
        #expect(reread.hotKeyBindings == bindings)
        #expect(reread.captureHotKey == Self.cmdOpt5)
        #expect(reread.recordingMagicPenHotKey == Self.ctrlOptX)
        #expect(reread.fullscreenHotKey == .defaultFullscreen)
    }
}

extension HotKeyCombo {
    /// Hashable stand-in for the fake's taken set.
    struct Key: Hashable { let keyCode: UInt32, modifiers: UInt32 }
    var key: Key { Key(keyCode: keyCode, modifiers: carbonModifiers) }
}

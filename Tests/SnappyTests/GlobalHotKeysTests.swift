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
        /// Registered combos (the two capture keys, like the app's launch).
        var combos: [HotKeyAction: HotKeyCombo] = [.captureArea: .defaultCapture, .captureFullscreen: .defaultFullscreen]
        /// Registered but refused by the system.
        var unbound: Set<HotKeyAction> = []
        private(set) var replaced: [(HotKeyAction, HotKeyCombo)] = []
        private(set) var probed: [HotKeyCombo] = []
        private(set) var suspensions: [Bool] = []
        private(set) var retries = 0
        /// Every call, in order: "suspend", "resume", "replace", "probe".
        private(set) var log: [String] = []
        /// Registered presses, by action.
        var handlers: [HotKeyAction: @MainActor () -> Void] = [:]
        private(set) var unregistered: [HotKeyAction] = []
        func register(_ action: HotKeyAction, combo: HotKeyCombo, handler: @escaping @MainActor () -> Void) -> Bool {
            combos[action] = combo
            handlers[action] = handler
            guard !taken.contains(combo.key) else {
                unbound.insert(action)
                return false
            }
            unbound.remove(action)
            return true
        }
        func unregister(_ action: HotKeyAction) {
            unregistered.append(action)
            combos[action] = nil
            handlers[action] = nil
            unbound.remove(action)
        }
        func replace(_ action: HotKeyAction, with combo: HotKeyCombo) -> Bool {
            log.append("replace")
            guard !taken.contains(combo.key) else { return false }
            replaced.append((action, combo))
            combos[action] = combo
            unbound.remove(action)
            return true
        }
        func isAvailable(_ combo: HotKeyCombo) -> Bool {
            log.append("probe")
            probed.append(combo)
            return !taken.contains(combo.key)
        }
        func setSuspended(_ suspended: Bool) {
            log.append(suspended ? "suspend" : "resume")
            suspensions.append(suspended)
        }
        func isRegistered(_ action: HotKeyAction) -> Bool { combos[action] != nil && !unbound.contains(action) }
        func combo(for action: HotKeyAction) -> HotKeyCombo? { combos[action] }
        func retryUnbound() -> [HotKeyAction] {
            retries += 1
            unbound = unbound.filter { combos[$0].map { taken.contains($0.key) } ?? false }
            return Array(unbound)
        }
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

    @Test func theCaptureKeysAreRegisteredWithTheStoredCombosAndRouted() throws {
        var bindings = HotKeyBindings.defaults
        bindings.captureArea = Self.cmdOpt5
        settings.hotKeyBindings = bindings
        var phase: RecordingPhase?
        var presses: [String] = []
        hotKeys.installCaptureKeys(
            phase: { phase },
            onCaptureArea: { presses.append("area") },
            onStopRecording: { presses.append("stop") },
            onCaptureFullscreen: { presses.append("fullscreen") }
        )
        #expect(center.combos[.captureArea] == Self.cmdOpt5)
        #expect(center.combos[.captureFullscreen] == .defaultFullscreen)
        let area = try #require(center.handlers[.captureArea])
        area()
        phase = .recording(.interact)
        area()
        phase = .setup(.pointer)
        area()
        let fullscreen = try #require(center.handlers[.captureFullscreen])
        fullscreen()
        #expect(presses == ["area", "stop", "fullscreen"])
    }

    @Test func aCaptureComboIsReplacedLiveThenSavedAndAnnounced() {
        var labels = 0
        hotKeys.observeLabels { labels += 1 }
        #expect(hotKeys.set(.captureArea, to: Self.cmdOpt5) == nil)
        #expect(center.replaced.map(\.0) == [.captureArea])
        #expect(settings.captureHotKey == Self.cmdOpt5)
        #expect(SettingsStore(defaults: defaults).captureHotKey == Self.cmdOpt5, "persisted")
        #expect(labels == 1)
        #expect(hotKeys.label(for: .captureArea) == "⌥⌘5")
        #expect(center.probed.isEmpty, "a lifetime hot key is rebound, not probed")
    }

    @Test func aComboTheSystemRefusesKeepsTheOldOne() {
        center.taken = [Self.cmdOpt5.key]
        var changes = 0
        hotKeys.observeLabels { changes += 1 }
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

    @Test func theSameComboAgainIsNotSavedOrAnnounced() {
        var changes = 0
        hotKeys.observeLabels { changes += 1 }
        #expect(hotKeys.set(.captureArea, to: .defaultCapture) == nil)
        #expect(changes == 0)
        #expect(settings.hotKeyBindings == .defaults)
    }

    /// Review r1 #6: a stored combo the system refused (at launch, or after a
    /// recorder's pause) is retried by recording it again — with the real
    /// answer, and the fields told when it went live.
    @Test func theStoredComboAgainRetriesItWhenItIsNotLive() {
        center.unbound = [.captureArea]
        center.taken = [HotKeyCombo.defaultCapture.key]
        var statusChanges = 0
        hotKeys.observeLabels { statusChanges += 1 }
        #expect(!hotKeys.isLive(.captureArea))
        #expect(hotKeys.isLive(.captureFullscreen))
        #expect(hotKeys.set(.captureArea, to: .defaultCapture) == .unavailable(.defaultCapture), "still taken")
        #expect(hotKeys.reset(.captureArea) == .unavailable(.defaultCapture), "Reset retries the default too")
        center.taken = []
        #expect(hotKeys.set(.captureArea, to: .defaultCapture) == nil)
        #expect(hotKeys.isLive(.captureArea))
        #expect(statusChanges == 1)
        #expect(settings.hotKeyBindings == .defaults)
    }

    @Test func aLabelIsTheComboWhileItIsLiveElseNil() {
        #expect(hotKeys.label(for: .captureArea) == "⇧⌘4")
        center.unbound = [.captureArea]
        #expect(hotKeys.label(for: .captureArea) == nil)
        #expect(hotKeys.label(for: .drawMode) == "⌃⌥D", "outside a session: the next session's")
        #expect(GlobalHotKeys(settings: settings, center: nil).label(for: .captureArea) == "⇧⌘4", "no center")
    }

    @Test func aSessionHotKeyOutsideASessionReadsAsLive() {
        #expect(hotKeys.isLive(.drawMode))
        #expect(hotKeys.isLive(.magicPen))
        center.combos[.toggleDrawMode] = .defaultDrawMode
        center.unbound = [.toggleDrawMode]
        #expect(!hotKeys.isLive(.drawMode), "a session holds it, refused")
    }

    @Test func retryingTellsTheFields() {
        center.unbound = [.captureFullscreen]
        var statusChanges = 0
        hotKeys.observeLabels { statusChanges += 1 }
        hotKeys.retryUnbound()
        #expect(center.retries == 1)
        #expect(statusChanges == 1)
        #expect(hotKeys.isLive(.captureFullscreen))
    }

    @Test func aLayoutChangeTellsTheObserversToReReadTheLabels() {
        var changes = 0
        hotKeys.observeLabels { changes += 1 }
        hotKeys.keyboardLayoutDidChange()
        #expect(changes == 1)
        #expect(settings.hotKeyBindings == .defaults)
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

    @Test func duringASessionASessionHotKeyIsReboundLive() {
        hotKeys.beginSession(onDrawMode: {}, onMagicPen: {})
        var labels = 0
        hotKeys.observeLabels { labels += 1 }
        #expect(hotKeys.set(.magicPen, to: Self.ctrlOptX) == nil)
        #expect(settings.recordingMagicPenHotKey == Self.ctrlOptX)
        #expect(hotKeys.label(for: .magicPen) == "⌃⌥X")
        #expect(labels == 1, "the toolbar re-reads its labels")
        let y = HotKeyCombo(keyCode: UInt32(kVK_ANSI_Y), carbonModifiers: UInt32(controlKey))
        center.taken = [y.key]
        #expect(hotKeys.set(.magicPen, to: y) == .unavailable(y))
        #expect(settings.recordingMagicPenHotKey == Self.ctrlOptX, "the old one stays")
        #expect(center.combos[.toggleMagicPen] == Self.ctrlOptX)
        #expect(center.replaced.map(\.1) == [Self.ctrlOptX])
        #expect(center.probed.isEmpty, "the live rebind is the check")
        #expect(labels == 1)
    }

    @Test func aSessionRegistersBothSessionKeysAndReportsTheRefusedOnes() throws {
        var presses: [String] = []
        center.taken = [HotKeyCombo.defaultMagicPen.key]
        let refused = hotKeys.beginSession(onDrawMode: { presses.append("draw") }, onMagicPen: { presses.append("magic") })
        #expect(refused == [.magicPen])
        #expect(center.combos[.toggleDrawMode] == .defaultDrawMode)
        #expect(hotKeys.label(for: .drawMode) == "⌃⌥D")
        #expect(hotKeys.label(for: .magicPen) == nil, "refused: not advertised")
        #expect(!hotKeys.isLive(.magicPen))
        let draw = try #require(center.handlers[.toggleDrawMode])
        draw()
        #expect(presses == ["draw"])

        hotKeys.endSession()
        #expect(center.unregistered == [.toggleDrawMode, .toggleMagicPen])
        #expect(center.combos[.toggleDrawMode] == nil)
        #expect(hotKeys.isLive(.magicPen), "outside a session a session key reads as live")
    }

    @Test func aMagicPenComboEqualToTheDrawModeOneIsNotRegisteredTwice() {
        settings.recordingDrawModeHotKey = .defaultMagicPen
        #expect(hotKeys.beginSession(onDrawMode: {}, onMagicPen: {}) == [.magicPen])
        #expect(center.combos[.toggleMagicPen] == nil)
        #expect(hotKeys.label(for: .magicPen) == nil)
        #expect(hotKeys.label(for: .drawMode) == "⌃⌥P")
    }

    @Test func aSessionKeyNotRegisteredAtSessionStartIsRegisteredByARebind() throws {
        settings.recordingDrawModeHotKey = .defaultMagicPen
        var presses = 0
        hotKeys.beginSession(onDrawMode: {}, onMagicPen: { presses += 1 })
        #expect(hotKeys.set(.magicPen, to: Self.ctrlOptX) == nil)
        #expect(center.combos[.toggleMagicPen] == Self.ctrlOptX)
        #expect(hotKeys.label(for: .magicPen) == "⌃⌥X")
        let magic = try #require(center.handlers[.toggleMagicPen])
        magic()
        #expect(presses == 1, "the session's handler")
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
        var statusChanges = 0
        hotKeys.observeLabels { statusChanges += 1 }
        hotKeys.setRecorderActive(true)
        #expect(statusChanges == 0)
        hotKeys.setRecorderActive(false)
        #expect(center.suspensions == [true, false])
        #expect(statusChanges == 1, "a resume may have lost a combo — the fields re-check")
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

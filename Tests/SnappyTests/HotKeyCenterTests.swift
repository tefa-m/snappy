import Carbon
import Testing
@testable import Snappy

/// Review r1 #2: a refused registration is reported, and `isRegistered`
/// reflects a live Carbon hot key — never a binding that doesn't work.
@MainActor
@Suite("HotKeyCenter registration", .serialized)
struct HotKeyCenterTests {
    /// ⌃⌥⇧⌘F19: nothing else on the machine binds it.
    private let combo = HotKeyCombo(
        keyCode: UInt32(kVK_F19), carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
    )

    @Test func aComboAlreadyTakenIsRefusedAndNotRegistered() {
        let owner = HotKeyCenter()
        #expect(owner.register(.toggleDrawMode, combo: combo) {})
        #expect(owner.isRegistered(.toggleDrawMode))

        // Another registrant (another app, in real life) can't have it.
        let other = HotKeyCenter()
        #expect(!other.register(.toggleDrawMode, combo: combo) {})
        #expect(!other.isRegistered(.toggleDrawMode))

        owner.unregister(.toggleDrawMode)
        #expect(!owner.isRegistered(.toggleDrawMode))
        // Released: it can be taken now.
        #expect(other.register(.toggleDrawMode, combo: combo) {})
        other.unregister(.toggleDrawMode)
    }

    /// ⌃⌥⇧⌘F18, likewise free.
    private let other = HotKeyCombo(
        keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
    )

    @Test func replaceRebindsLiveAndReleasesTheOldCombo() {
        let center = HotKeyCenter()
        #expect(center.register(.toggleMagicPen, combo: combo) {})
        #expect(center.replace(.toggleMagicPen, with: other))
        #expect(center.isRegistered(.toggleMagicPen))
        #expect(center.combo(for: .toggleMagicPen) == other)
        #expect(center.isAvailable(combo), "the old combo is free again")
        #expect(!center.isAvailable(other), "the new one is held")
        center.unregister(.toggleMagicPen)
    }

    @Test func aRefusedReplaceKeepsTheOldBindingLive() {
        let owner = HotKeyCenter()
        #expect(owner.register(.toggleDrawMode, combo: other) {})
        let center = HotKeyCenter()
        #expect(center.register(.toggleMagicPen, combo: combo) {})
        #expect(!center.replace(.toggleMagicPen, with: other), "another registrant holds it")
        #expect(center.isRegistered(.toggleMagicPen))
        #expect(center.combo(for: .toggleMagicPen) == combo)
        #expect(!owner.isAvailable(combo), "the old combo is bound again")
        #expect(!center.replace(.captureArea, with: other), "not registered: nothing to replace")
        owner.unregister(.toggleDrawMode)
        center.unregister(.toggleMagicPen)
    }

    @Test func suspendingReleasesEveryComboAndResumingBindsThemAgain() {
        let center = HotKeyCenter()
        #expect(center.register(.toggleDrawMode, combo: combo) {})
        center.setSuspended(true)
        #expect(center.isSuspended)
        #expect(!center.isRegistered(.toggleDrawMode))
        #expect(center.combo(for: .toggleDrawMode) == combo, "the registration stays")
        #expect(center.isAvailable(combo), "released while suspended")
        // A rebind while suspended is checked by the probe and applied on resume.
        #expect(center.replace(.toggleDrawMode, with: other))
        center.setSuspended(false)
        #expect(center.isRegistered(.toggleDrawMode))
        #expect(center.combo(for: .toggleDrawMode) == other)
        #expect(center.isAvailable(combo))
        #expect(!center.isAvailable(other))
        center.unregister(.toggleDrawMode)
    }
}

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
        #expect(center.unboundActions.isEmpty, "nothing is meant to be live while suspended")
        // A rebind while suspended is the real bind: the new combo is held at once.
        #expect(center.replace(.toggleDrawMode, with: other))
        #expect(center.isRegistered(.toggleDrawMode))
        #expect(!center.isAvailable(other))
        center.setSuspended(false)
        #expect(center.isRegistered(.toggleDrawMode))
        #expect(center.combo(for: .toggleDrawMode) == other)
        #expect(center.isAvailable(combo))
        #expect(!center.isAvailable(other))
        center.unregister(.toggleDrawMode)
    }

    /// Review r1 #2: another app takes the combo while a recorder has the hot
    /// keys paused. The resume can't get it back — the registration and its
    /// combo stay (reported by `unboundActions`), and a retry binds it once
    /// it is free again.
    @Test func aFailedResumeKeepsTheRegistrationAndRetriesLater() {
        let center = HotKeyCenter()
        var fired = 0
        #expect(center.register(.toggleDrawMode, combo: combo) { fired += 1 })
        center.setSuspended(true)
        let thief = HotKeyCenter()
        #expect(thief.register(.toggleMagicPen, combo: combo) {})
        center.setSuspended(false)
        #expect(!center.isRegistered(.toggleDrawMode))
        #expect(center.combo(for: .toggleDrawMode) == combo, "not silently dropped")
        #expect(center.unboundActions == [.toggleDrawMode])
        #expect(center.retryUnbound() == [.toggleDrawMode], "still taken")
        thief.unregister(.toggleMagicPen)
        #expect(center.retryUnbound().isEmpty)
        #expect(center.isRegistered(.toggleDrawMode))
        #expect(!center.isAvailable(combo), "held again")
        center.unregister(.toggleDrawMode)
        #expect(fired == 0)
    }

    /// The old "rollback" case: a refused rebind of a registration whose own
    /// combo was lost. Nothing is released or rolled back — the stored combo
    /// stays, unbound, and is retried; the same combo again retries at once.
    @Test func aRefusedRebindOfAnUnboundRegistrationKeepsItsCombo() {
        let center = HotKeyCenter()
        #expect(center.register(.toggleDrawMode, combo: combo) {})
        center.setSuspended(true)
        let thief = HotKeyCenter()
        #expect(thief.register(.toggleDrawMode, combo: combo) {})
        #expect(thief.register(.toggleMagicPen, combo: other) {})
        center.setSuspended(false)
        #expect(!center.replace(.toggleDrawMode, with: other), "the new combo is taken too")
        #expect(center.combo(for: .toggleDrawMode) == combo)
        #expect(!center.isRegistered(.toggleDrawMode))
        #expect(!center.replace(.toggleDrawMode, with: combo), "the same combo again: a retry, still taken")
        thief.unregister(.toggleDrawMode)
        #expect(center.replace(.toggleDrawMode, with: combo), "free now: the retry binds it")
        #expect(center.isRegistered(.toggleDrawMode))
        thief.unregister(.toggleMagicPen)
        center.unregister(.toggleDrawMode)
    }

    /// The new combo is acquired before the old is released: at no point is
    /// the action without a live binding, and a refusal never touches it.
    @Test func replaceHoldsTheNewComboBeforeReleasingTheOld() {
        let center = HotKeyCenter()
        #expect(center.register(.captureArea, combo: combo) {})
        let rival = HotKeyCenter()
        #expect(rival.register(.captureArea, combo: other) {})
        #expect(!center.replace(.captureArea, with: other))
        #expect(center.isRegistered(.captureArea))
        #expect(!rival.isAvailable(combo), "the old combo was never let go")
        rival.unregister(.captureArea)
        #expect(center.replace(.captureArea, with: other))
        #expect(rival.isAvailable(combo))
        center.unregister(.captureArea)
    }

    @Test func aRefusedRegistrationIsKeptForARetry() {
        let owner = HotKeyCenter()
        #expect(owner.register(.toggleDrawMode, combo: combo) {})
        let center = HotKeyCenter()
        #expect(!center.register(.captureArea, combo: combo) {})
        #expect(center.combo(for: .captureArea) == combo)
        #expect(center.unboundActions == [.captureArea])
        owner.unregister(.toggleDrawMode)
        #expect(center.retry(.captureArea))
        #expect(center.isRegistered(.captureArea))
        center.unregister(.captureArea)
        #expect(center.combo(for: .captureArea) == nil)
    }
}

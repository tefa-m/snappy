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
}

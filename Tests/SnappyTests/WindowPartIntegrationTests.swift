import AppKit
import Carbon.HIToolbox
import Testing
@testable import Snappy

/// v2 snap keys through the **real** Setup overlay and AppKit's key routing
/// (`NSApp.sendEvent`): the same key steps back, the other switches, ↑ / ↓
/// belong to the part picker in snap mode and still nudge in Setup. Only
/// keys whose result doesn't depend on where the pointer happens to be.
///
/// An extension of the integration suite, so its `.serialized` trait keeps
/// these real windows from interleaving with the other window tests.
extension RecordingIntegrationTests {
    @MainActor final class SnapParts: WindowPartSessionHooking {
        var entries = 0
        func sessionBegan(target: RecordingTarget) {}
        func snapModeEntered() { entries += 1 }
        func sessionEnded() {}
        func applicationWillTerminate() {}
    }

    private func pressKey(_ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        )!
        NSApp.sendEvent(event)
    }

    private func snapTestTarget() throws -> RecordingTarget {
        let screen = try #require(NSScreen.screens.first, "needs a display")
        let id = try #require(CaptureEngine.displayID(for: screen))
        let visible = screen.visibleFrame
        return .area(globalRect: CGRect(x: visible.minX + 200, y: visible.minY + 200, width: 400, height: 240), displayID: id)
    }

    @Test("Snap keys: same key back, other key switches, ↑/↓ stay in snap mode")
    func sameKeyStepsBackOtherKeySwitchesArrowsStayInSnapMode() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let parts = SnapParts()
        h.coordinator.windowParts = parts
        let target = try snapTestTarget()
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        #expect(NSApp.keyWindow?.level == RecordingWindowLevel.setup)

        pressKey("s", keyCode: kVK_ANSI_S)
        #expect(h.coordinator.phase == .snapping(.area, previous: target, returnTo: .pointer))
        #expect(parts.entries == 1)
        // ↑ / ↓ pick parts here: swallowed, still snapping (no Setup nudge).
        pressKey("\u{F700}", keyCode: kVK_UpArrow, modifiers: [.numericPad, .function])
        pressKey("\u{F701}", keyCode: kVK_DownArrow, modifiers: [.numericPad, .function])
        #expect(h.coordinator.phase == .snapping(.area, previous: target, returnTo: .pointer))

        pressKey("w", keyCode: kVK_ANSI_W)
        #expect(h.coordinator.phase == .snapping(.window, previous: target, returnTo: .pointer))
        pressKey("w", keyCode: kVK_ANSI_W)
        #expect(h.coordinator.phase == .setup(.pointer))
        #expect(h.coordinator.session?.target == target, "back to the rect from before snapping")

        // Back in Setup, ↑ nudges the area again.
        pressKey("\u{F700}", keyCode: kVK_UpArrow, modifiers: [.numericPad, .function])
        #expect(h.coordinator.session?.target == target.withFrame(target.frame.offsetBy(dx: 0, dy: 1)))
        #expect(parts.entries == 1)
    }
}

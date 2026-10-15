import AppKit
import Testing

@testable import Snappy

@Suite("CountdownSequence")
struct CountdownSequenceTests {
    @Test("Numerals per Settings → Countdown: Off/1/2/3/5")
    func numerals() {
        #expect(CountdownSequence.numerals(for: .off) == [])
        #expect(CountdownSequence.numerals(for: .one) == [1])
        #expect(CountdownSequence.numerals(for: .two) == [2, 1])
        #expect(CountdownSequence.numerals(for: .three) == [3, 2, 1])
        #expect(CountdownSequence.numerals(for: .five) == [5, 4, 3, 2, 1])
    }

    @Test("The session's ticks show exactly that sequence, then recording starts")
    func matchesSessionTicks() {
        let target = RecordingTarget.area(globalRect: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 1)
        for countdown in RecordingCountdown.allCases {
            var session = RecordingSession(target: target, countdownSeconds: countdown.seconds)
            session.handle(.command(.record))
            var shown: [Int] = []
            while let numeral = CountdownSequence.numeral(for: session.phase) {
                shown.append(numeral)
                session.handle(.countdownTick)
            }
            #expect(shown == CountdownSequence.numerals(for: countdown), "\(countdown)")
            #expect(session.phase == .recording(.interact))
        }
    }

    @Test("No numeral outside the countdown")
    func numeralOnlyInCountdown() {
        #expect(CountdownSequence.numeral(for: .countdown(remaining: 2)) == 2)
        #expect(CountdownSequence.numeral(for: .setup(.pointer)) == nil)
        #expect(CountdownSequence.numeral(for: .recording(.interact)) == nil)
    }

    @Test("VoiceOver hears what is coming first, then the count")
    func announcements() {
        #expect(CountdownSequence.announcement(numeral: 3, total: 3) == "Recording in 3")
        #expect(CountdownSequence.announcement(numeral: 2, total: 3) == "2")
    }
}

@Suite("RecordingStatusGlyph")
struct RecordingStatusGlyphTests {
    @Test("The red ■ shows only while frames are recorded")
    func showsStop() {
        #expect(RecordingStatusGlyph.showsStop(for: .recording(.interact)))
        #expect(RecordingStatusGlyph.showsStop(for: .recording(.draw(.pen))))
        #expect(!RecordingStatusGlyph.showsStop(for: .setup(.pointer)))
        #expect(!RecordingStatusGlyph.showsStop(for: .countdown(remaining: 1)))
        #expect(!RecordingStatusGlyph.showsStop(for: .stopping))
        #expect(!RecordingStatusGlyph.showsStop(for: nil))
    }

    @Test("Tooltip names the action and the hot key; the symbol exists")
    @MainActor
    func appearance() {
        #expect(RecordingStatusGlyph.toolTip == "Stop recording (⇧⌘4)")
        let image = RecordingStatusGlyph.image()
        #expect(image != nil)
        #expect(image?.isTemplate == false)
    }
}

@Suite("RecordingChrome")
@MainActor
struct RecordingChromeTests {
    private let target = RecordingTarget.area(globalRect: CGRect(x: 200, y: 200, width: 640, height: 400), displayID: 1)

    @Test("Show → countdown → close twice: no stray events, nothing applied after close")
    func lifecycle() {
        let chrome = RecordingChrome(drawModeKey: "⌃⌥D")
        var events: [RecordingEvent] = []
        chrome.onEvent = { events.append($0) }
        var session = RecordingSession(target: target, countdownSeconds: 3)
        chrome.show(session, style: InkStyle(settings: RecordingSettings()))
        session.handle(.command(.record))
        chrome.apply(session)
        session.handle(.countdownTick)
        chrome.apply(session)
        chrome.close()
        chrome.close()
        chrome.apply(session)
        chrome.captureDidStart()
        #expect(events.isEmpty)
    }

    @Test("The timer passing one and ten hours re-fits the toolbar panel without a session event (review r1 #3)")
    func timerGrowthRefitsToolbar() throws {
        let chrome = RecordingChrome(drawModeKey: "⌃⌥D")
        var session = RecordingSession(target: target, countdownSeconds: 0)
        chrome.show(session, style: InkStyle(settings: RecordingSettings()))
        session.handle(.command(.record))
        chrome.apply(session)
        chrome.captureDidStart()
        defer { chrome.close() }

        chrome.showElapsed(3599)
        let minutes = chrome.toolbarFrame
        chrome.showElapsed(3600)
        let hour = chrome.toolbarFrame
        chrome.showElapsed(36000)
        let tenHours = chrome.toolbarFrame

        // Each step widens the panel to what the controls now need, and the
        // panel stays centred under the target and on screen.
        let probe = RecordingToolbarView(drawModeKey: "⌃⌥D")
        probe.showElapsed(36000, running: true)
        #expect(hour.width > minutes.width)
        #expect(tenHours.width > hour.width)
        #expect(tenHours.width == probe.fittingSize.width)
        #expect(abs(tenHours.midX - target.frame.midX) <= 0.5)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(target.frame) }) {
            #expect(screen.visibleFrame.contains(tenHours))
        }
    }

    @Test("The toolbar is a 36 pt capsule wide enough for every control")
    func toolbarSize() {
        let toolbar = RecordingToolbarView(drawModeKey: "⌃⌥D")
        let size = toolbar.fittingSize
        #expect(size.height == 36)
        // 13 buttons × 28 pt alone are 364 pt.
        #expect(size.width > 364)
        #expect(toolbar.cornerRadius == 18)
    }
}

import Foundation
import Testing
@testable import Snappy

@Suite struct RecordingNamerTests {
    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int,
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    @Test func formatsFixedDate() {
        let zone = TimeZone(identifier: "Europe/Vienna")!
        let fixed = date(2026, 10, 9, 14, 32, 5, timeZone: zone)
        #expect(RecordingNamer.filename(for: fixed, timeZone: zone) == "Recording 2026-10-09 at 14.32.05.mp4")
    }

    @Test func padsSingleDigitComponentsAndUsesTheTwentyFourHourClock() {
        let zone = TimeZone(identifier: "UTC")!
        #expect(RecordingNamer.filename(for: date(2026, 1, 5, 9, 4, 3, timeZone: zone), timeZone: zone)
            == "Recording 2026-01-05 at 09.04.03.mp4")
        #expect(RecordingNamer.filename(for: date(2026, 12, 31, 23, 59, 59, timeZone: zone), timeZone: zone)
            == "Recording 2026-12-31 at 23.59.59.mp4")
    }

    @Test func indexSuffixDisambiguatesSameSecondFiles() {
        let zone = TimeZone(identifier: "UTC")!
        let fixed = date(2026, 10, 9, 14, 32, 5, timeZone: zone)
        #expect(RecordingNamer.filename(for: fixed, timeZone: zone, index: nil) == "Recording 2026-10-09 at 14.32.05.mp4")
        #expect(RecordingNamer.filename(for: fixed, timeZone: zone, index: 1) == "Recording 2026-10-09 at 14.32.05.mp4")
        #expect(RecordingNamer.filename(for: fixed, timeZone: zone, index: 2) == "Recording 2026-10-09 at 14.32.05 (2).mp4")
        #expect(RecordingNamer.filename(for: fixed, timeZone: zone, index: 13) == "Recording 2026-10-09 at 14.32.05 (13).mp4")
    }

    @Test func sharesTheScreenshotTimestampFormat() {
        let zone = TimeZone(identifier: "UTC")!
        let fixed = date(2026, 10, 9, 14, 32, 5, timeZone: zone)
        let shot = ScreenshotNamer.filename(for: fixed, timeZone: zone, index: 3)
        let recording = RecordingNamer.filename(for: fixed, timeZone: zone, index: 3)
        #expect(shot.dropFirst("Shot ".count).dropLast(".png".count)
            == recording.dropFirst("Recording ".count).dropLast(".mp4".count))
    }
}

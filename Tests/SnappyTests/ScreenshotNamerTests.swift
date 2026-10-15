import Foundation
import Testing
@testable import Snappy

@Suite struct ScreenshotNamerTests {
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
        let fixed = date(2026, 7, 17, 14, 32, 5, timeZone: zone)
        #expect(ScreenshotNamer.filename(for: fixed, timeZone: zone) == "Shot 2026-07-17 at 14.32.05.png")
    }

    @Test func padsSingleDigitComponents() {
        let zone = TimeZone(identifier: "UTC")!
        let fixed = date(2026, 1, 5, 9, 4, 3, timeZone: zone)
        #expect(ScreenshotNamer.filename(for: fixed, timeZone: zone) == "Shot 2026-01-05 at 09.04.03.png")
    }

    @Test func usesTwentyFourHourClockRegardlessOfLocale() {
        let zone = TimeZone(identifier: "UTC")!
        let fixed = date(2026, 12, 31, 23, 59, 59, timeZone: zone)
        #expect(ScreenshotNamer.filename(for: fixed, timeZone: zone) == "Shot 2026-12-31 at 23.59.59.png")
    }

    @Test func indexSuffixDisambiguatesSameSecondFiles() {
        let zone = TimeZone(identifier: "UTC")!
        let fixed = date(2026, 7, 17, 14, 32, 5, timeZone: zone)
        #expect(ScreenshotNamer.filename(for: fixed, timeZone: zone, index: nil) == "Shot 2026-07-17 at 14.32.05.png")
        #expect(ScreenshotNamer.filename(for: fixed, timeZone: zone, index: 1) == "Shot 2026-07-17 at 14.32.05.png")
        #expect(ScreenshotNamer.filename(for: fixed, timeZone: zone, index: 2) == "Shot 2026-07-17 at 14.32.05 (2).png")
        #expect(ScreenshotNamer.filename(for: fixed, timeZone: zone, index: 13) == "Shot 2026-07-17 at 14.32.05 (13).png")
    }
}

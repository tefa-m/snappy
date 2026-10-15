import Foundation
import Testing
@testable import Snappy

/// v2 take lifetime (Q30/Q43): each window owns its take, the latest is kept
/// for Reopen, a new recording never deletes a take whose window is open.
@Suite("RecordingTakeLedger")
struct RecordingTakeLedgerTests {
    private let directory = URL(fileURLWithPath: "/tmp/Snappy/Recordings", isDirectory: true)
    private func take(_ name: String) -> URL { directory.appending(path: "Take-\(name).mp4") }

    @Test func emptyKeepsNothing() {
        let ledger = RecordingTakeLedger()
        #expect(ledger.latest == nil)
        #expect(ledger.kept.isEmpty)
        #expect(!ledger.keeps(take("a")))
    }

    @Test func aRelaunchedLedgerKeepsTheNewestTakeOnDisk() {
        let ledger = RecordingTakeLedger(latest: take("a"))
        #expect(ledger.latest == take("a"))
        #expect(ledger.keeps(take("a")))
    }

    @Test func aFinishedTakeIsKeptWhileItsWindowIsOpenAndAfterwardsAsTheLatest() {
        var ledger = RecordingTakeLedger()
        #expect(ledger.finished(take("a")).isEmpty)
        ledger.opened(take("a"))
        #expect(ledger.isOpen(take("a")))
        #expect(ledger.closed(take("a")).isEmpty) // the latest survives its window (Reopen)
        #expect(!ledger.isOpen(take("a")))
        #expect(ledger.keeps(take("a")))
    }

    @Test func aNewTakeReleasesThePreviousLatestOnlyWhenItsWindowIsClosed() {
        var ledger = RecordingTakeLedger()
        _ = ledger.finished(take("a"))
        ledger.opened(take("a"))
        _ = ledger.closed(take("a"))

        #expect(ledger.finished(take("b")) == [take("a")])
        #expect(ledger.latest == take("b"))
        #expect(!ledger.keeps(take("a")))
    }

    @Test func aNewRecordingNeverReleasesATakeWhoseWindowIsOpen() {
        var ledger = RecordingTakeLedger()
        _ = ledger.finished(take("a"))
        ledger.opened(take("a"))

        #expect(ledger.finished(take("b")).isEmpty) // A's window is still open
        ledger.opened(take("b"))
        #expect(ledger.kept == [take("a"), take("b")])

        // Closing the older window now releases it: it is no longer the latest.
        #expect(ledger.closed(take("a")) == [take("a")])
        // Closing the newest keeps it for Reopen.
        #expect(ledger.closed(take("b")).isEmpty)
        #expect(ledger.kept == [take("b")])
    }

    @Test func severalWindowsCoexistAndEachReleasesOnlyItsOwnTake() {
        var ledger = RecordingTakeLedger()
        for name in ["a", "b", "c"] {
            _ = ledger.finished(take(name))
            ledger.opened(take(name))
        }
        #expect(ledger.kept == [take("a"), take("b"), take("c")])
        #expect(ledger.closed(take("b")) == [take("b")])
        #expect(ledger.kept == [take("a"), take("c")])
        #expect(ledger.closed(take("c")).isEmpty) // latest
        #expect(ledger.closed(take("a")) == [take("a")])
        #expect(ledger.kept == [take("c")])
    }

    /// A reopened window and the one still closing (its close arrives a turn
    /// later) overlap on the same take; the late close must not release it.
    @Test func windowsAreCountedSoALateCloseDoesNotReleaseAReopenedTake() {
        var ledger = RecordingTakeLedger()
        _ = ledger.finished(take("a"))
        ledger.opened(take("a"))
        ledger.opened(take("a")) // Reopen while the first window is closing
        #expect(ledger.closed(take("a")).isEmpty)
        #expect(ledger.isOpen(take("a")))

        _ = ledger.finished(take("b")) // A still has a window
        #expect(ledger.keeps(take("a")))
        #expect(ledger.closed(take("a")) == [take("a")])
    }

    @Test func aCloseWithoutAWindowReleasesNothing() {
        var ledger = RecordingTakeLedger(latest: take("a"))
        #expect(ledger.closed(take("z")).isEmpty)
        #expect(ledger.closed(take("a")).isEmpty)
        #expect(ledger.keeps(take("a")))
    }

    @Test func urlsAreComparedStandardized() {
        var ledger = RecordingTakeLedger()
        let spelled = URL(fileURLWithPath: "/tmp/Snappy/./Recordings/Take-a.mp4")
        _ = ledger.finished(spelled)
        ledger.opened(take("a"))
        #expect(ledger.keeps(take("a")))
        #expect(ledger.isOpen(spelled))
        #expect(ledger.closed(spelled).isEmpty)
        #expect(ledger.finished(take("b")) == [take("a")])
    }
}

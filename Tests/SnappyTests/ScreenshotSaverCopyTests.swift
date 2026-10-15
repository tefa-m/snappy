import Foundation
import Testing
@testable import Snappy

/// The generic, additive placement + copy helpers recordings use. The
/// screenshot path keeps its own tests in `ScreenshotSaverTests` (unchanged).
@Suite struct ScreenshotSaverCopyTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SnappySaverCopyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func name(_ index: Int) -> String { index > 1 ? "clip (\(index)).mp4" : "clip.mp4" }

    @Test func copyLeavesTheSourceInPlaceAndNeverOverwrites() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mp4")
        try Data("take".utf8).write(to: source)
        let destination = root.appending(path: "Saved", directoryHint: .isDirectory)

        let first = try ScreenshotSaver.copyWithoutOverwriting(source, into: destination, named: name)
        let second = try ScreenshotSaver.copyWithoutOverwriting(source, into: destination, named: name)

        #expect(first.lastPathComponent == "clip.mp4")
        #expect(second.lastPathComponent == "clip (2).mp4")
        #expect(try Data(contentsOf: source) == Data("take".utf8)) // the take survives
        #expect(try Data(contentsOf: first) == Data("take".utf8))
        #expect(try Data(contentsOf: second) == Data("take".utf8))
        // No temporary siblings are left behind.
        let files = try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false))
        #expect(Set(files) == ["clip.mp4", "clip (2).mp4"])
    }

    @Test func copyKeepsAnExistingFileWithTheSameName() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mp4")
        try Data("take".utf8).write(to: source)
        let destination = root.appending(path: "Saved", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: destination.appending(path: "clip.mp4"))

        let saved = try ScreenshotSaver.copyWithoutOverwriting(source, into: destination, named: name)

        #expect(saved.lastPathComponent == "clip (2).mp4")
        #expect(try Data(contentsOf: destination.appending(path: "clip.mp4")) == Data("keep me".utf8))
    }

    @Test func copyFallsBackToMovingTheTemporaryCopyWithoutHardLinks() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mp4")
        try Data("take".utf8).write(to: source)
        let destination = root.appending(path: "Saved", directoryHint: .isDirectory)

        let saved = try ScreenshotSaver.copyWithoutOverwriting(
            source, into: destination, named: name, link: { _, _ in ENOTSUP }
        )

        #expect(saved.lastPathComponent == "clip.mp4")
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        let files = try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false))
        #expect(files == ["clip.mp4"])
    }

    @Test func aMissingSourceThrowsAndLeavesNothingBehind() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Saved", directoryHint: .isDirectory)

        #expect(throws: (any Error).self) {
            try ScreenshotSaver.copyWithoutOverwriting(root.appending(path: "gone.mp4"), into: destination, named: name)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false))
        #expect(files.isEmpty)
    }

    @Test func screenshotPlacementStillUsesTheShotNames() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let temporary = directory.appending(path: ".tmp-test")
        try Data("new".utf8).write(to: temporary)

        let placed = try ScreenshotSaver.placeWithoutOverwriting(temporary, in: directory, date: moment)
        #expect(placed.lastPathComponent == ScreenshotNamer.filename(for: moment))
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Snappy

@Suite struct ScreenshotSaverTests {
    private func image(width: Int = 8, height: Int = 4) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SnappySaverTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func savingTwiceInTheSameSecondKeepsBothFiles() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moment = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try ScreenshotSaver.save(image(), scale: 1, to: directory, date: moment)
        let second = try ScreenshotSaver.save(image(), scale: 1, to: directory, date: moment)
        let third = try ScreenshotSaver.save(image(), scale: 1, to: directory, date: moment)

        #expect(first != second && second != third && first != third)
        #expect(second.lastPathComponent.hasSuffix(" (2).png"))
        #expect(third.lastPathComponent.hasSuffix(" (3).png"))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(files.count == 3)
    }

    @Test func savingDoesNotClobberAnExistingFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = directory.appending(path: ScreenshotNamer.filename(for: moment))
        try Data("keep me".utf8).write(to: existing)

        let saved = try ScreenshotSaver.save(image(), scale: 1, to: directory, date: moment)

        #expect(saved != existing)
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
    }

    @Test func savingCreatesAMissingDestinationFolder() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let nested = parent.appending(path: "deleted/since/configured", directoryHint: .isDirectory)

        let saved = try ScreenshotSaver.save(image(), scale: 1, to: nested)
        #expect(FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)))
    }

    @Test func retinaCapturesAreEncodedWithTheirDPI() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let at2x = try ScreenshotSaver.save(image(width: 200, height: 100), scale: 2, to: directory)
        let at1x = try ScreenshotSaver.save(
            image(width: 200, height: 100), scale: 1, to: directory,
            date: Date(timeIntervalSince1970: 1_800_000_100)
        )

        // The decoded resolution (from the PNG `pHYs` chunk), nil when absent.
        func dpi(_ url: URL) throws -> Double? {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            // Integral values bridge to Int inside `Any`, so go through NSNumber.
            return (properties[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue
        }
        let dpi2x = try #require(try dpi(at2x))
        #expect(abs(dpi2x - 144) < 1)
        // A 1× capture is the plain 72 dpi default: no `pHYs` chunk is written.
        #expect(try dpi(at1x).map { abs($0 - 72) < 1 } ?? true)
    }

    @Test func bitmapRepPointSizeIsPixelSizeOverScale() {
        let rep = BitmapRep.make(image(width: 300, height: 150), scale: 2)
        #expect(rep.size == NSSize(width: 150, height: 75))
        #expect(rep.pixelsWide == 300)
    }

    @Test func fallsBackToMovingWhenHardLinksAreUnsupported() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = directory.appending(path: ScreenshotNamer.filename(for: moment))
        try Data("keep me".utf8).write(to: existing)
        let temporary = directory.appending(path: ".tmp-test")
        try Data("new".utf8).write(to: temporary)

        var linkCalls = 0
        let placed = try ScreenshotSaver.placeWithoutOverwriting(
            temporary, in: directory, date: moment,
            link: { _, _ in linkCalls += 1; return ENOTSUP }
        )

        #expect(linkCalls == 1) // gave up on linking after the first unsupported error
        #expect(placed.lastPathComponent.hasSuffix(" (2).png")) // moveItem refused to overwrite #1
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
        #expect(try Data(contentsOf: placed) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: temporary.path(percentEncoded: false)))
    }

    @Test func eexistFromLinkKeepsLinkingInsteadOfFallingBack() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let temporary = directory.appending(path: ".tmp-test")
        try Data("new".utf8).write(to: temporary)

        var attempts: [String] = []
        let placed = try ScreenshotSaver.placeWithoutOverwriting(
            temporary, in: directory, date: moment,
            link: { _, destination in
                attempts.append(destination.lastPathComponent)
                return attempts.count < 3 ? EEXIST : 0
            }
        )
        #expect(attempts.count == 3)
        #expect(placed.lastPathComponent.hasSuffix(" (3).png"))
    }
}

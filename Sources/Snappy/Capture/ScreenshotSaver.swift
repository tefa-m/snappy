import AppKit

/// Builds the `Shot yyyy-MM-dd at HH.mm.ss.png` filenames — pure so the
/// format is unit-testable.
enum ScreenshotNamer {
    /// `index` disambiguates files saved within the same second: nil or 1 gives
    /// the plain name, 2… append ` (2)`, ` (3)`, ….
    static func filename(for date: Date, timeZone: TimeZone = .current, index: Int? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let suffix = (index ?? 1) > 1 ? " (\(index!))" : ""
        return "Shot \(formatter.string(from: date))\(suffix).png"
    }
}

enum ScreenshotSaveError: Error {
    case pngEncodingFailed
    case tooManyCollisions
}

/// Writes captures as timestamped PNGs into the configured folder.
enum ScreenshotSaver {
    /// Upper bound on same-second collisions before giving up.
    private static let maxAttempts = 1000

    /// Hard-links `source` to `destination`; 0 on success, else the `errno`.
    typealias LinkOperation = (_ source: URL, _ destination: URL) -> Int32

    static func hardLink(_ source: URL, _ destination: URL) -> Int32 {
        Darwin.link(source.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0 ? 0 : errno
    }

    /// `scale` is the capture's pixels-per-point (sets the PNG's DPI). Never
    /// overwrites and never leaves a half-written file: the PNG is written to a
    /// temporary sibling, then placed at its final name by `placeWithoutOverwriting`.
    @discardableResult
    static func save(_ image: CGImage, scale: CGFloat, to directory: URL, date: Date = Date()) throws -> URL {
        let rep = BitmapRep.make(image, scale: scale)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ScreenshotSaveError.pngEncodingFailed
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appending(path: ".snappy-\(UUID().uuidString).tmp")
        try png.write(to: temporary, options: .atomic)
        // After a successful move the temp file is gone; removal is then a no-op.
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try placeWithoutOverwriting(temporary, in: directory, date: date)
    }

    /// Gives `temporary` the first free `Shot …` name (` (2)`, ` (3)`… on a
    /// collision). Primary path is `link(2)`, which fails atomically with EEXIST
    /// if the name is taken (Foundation's `.atomic` and `.withoutOverwriting`
    /// write options cannot be combined). Volumes without hard links (FAT/exFAT,
    /// some SMB shares) fail it with ENOTSUP/EPERM/EXDEV…; any errno other than
    /// EEXIST then switches the rest of the sequence to `moveItem`, which also
    /// refuses to overwrite (`fileWriteFileExists` → next index). `link` is
    /// injectable so the fallback is testable without such a volume.
    static func placeWithoutOverwriting(
        _ temporary: URL, in directory: URL, date: Date, link: LinkOperation = ScreenshotSaver.hardLink
    ) throws -> URL {
        try placeWithoutOverwriting(
            temporary, in: directory, named: { ScreenshotNamer.filename(for: date, index: $0) }, link: link
        )
    }

    /// The same placement for any file kind: `name(index)` gives the candidate
    /// filename for index 1, 2, … (1 = the plain name). Used by recordings
    /// (`RecordingNamer`) as well as screenshots.
    static func placeWithoutOverwriting(
        _ temporary: URL, in directory: URL, named name: (Int) -> String,
        link: LinkOperation = ScreenshotSaver.hardLink
    ) throws -> URL {
        var linkingWorks = true
        for index in 1...maxAttempts {
            let url = directory.appending(path: name(index))
            if linkingWorks {
                let error = link(temporary, url)
                if error == 0 { return url }
                if error == EEXIST { continue }
                linkingWorks = false // unsupported here — move instead, from this index on
            }
            do {
                try FileManager.default.moveItem(at: temporary, to: url)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw ScreenshotSaveError.tooManyCollisions
    }

    /// Copies `source` into `directory` under the first free `name(index)`,
    /// never overwriting and never leaving a half-written file under a final
    /// name: the copy goes to a hidden temporary sibling first (an APFS clone
    /// when both are on one volume), then `placeWithoutOverwriting` names it.
    /// `source` is left untouched — the recording take must survive in Caches
    /// for "Reopen Last Recording" (Q18).
    @discardableResult
    static func copyWithoutOverwriting(
        _ source: URL, into directory: URL, named name: (Int) -> String,
        link: LinkOperation = ScreenshotSaver.hardLink
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".snappy-\(UUID().uuidString).tmp")
        // Also cleans up a partial copy. After a successful link the temp file is
        // a second name for the result (removed here); after a move it is gone
        // and removal is a no-op.
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        return try placeWithoutOverwriting(temporary, in: directory, named: name, link: link)
    }
}

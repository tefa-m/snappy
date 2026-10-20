import AppKit

/// Save and Copy file handling for the recording window — nonisolated so Save
/// can run off the main actor, and tested with temporary directories. Neither
/// ever touches the take itself: only `RecordingTakeLedger` decides when a
/// take goes.
enum RecordingExport {
    /// When the take was recorded: its modification date (the writer finishes
    /// it at Stop), so a take reopened hours later still saves under its own
    /// time. Falls back to now.
    static func recordedDate(of take: URL) -> Date {
        (try? take.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
    }

    /// Copies the take into `directory` as `Recording … .mp4` — ` (2)` on a
    /// same-second collision, never overwriting (the screenshot saver's
    /// link(2) placement).
    static func save(_ take: URL, to directory: URL, date: Date) throws -> URL {
        try ScreenshotSaver.copyWithoutOverwriting(
            take, into: directory, named: { RecordingNamer.filename(for: date, index: $0) }
        )
    }

    /// Gives the take a **private second name**, synchronously, before Save
    /// yields: a hard link in a fresh staging directory on the take's own
    /// volume (`itemReplacementDirectory`), or a clone if linking fails.
    /// Deleting the take (its window closed, or a newer take released it)
    /// only unlinks the Caches name, so an export still running then keeps
    /// its data (review round 1). Pair with `save(staged:to:date:)`, which
    /// removes it.
    static func stage(_ take: URL, link: ScreenshotSaver.LinkOperation = ScreenshotSaver.hardLink) throws -> URL {
        let fileManager = FileManager.default
        // The take must already be a regular file: asking Foundation for
        // replacement storage "appropriate for" a missing path can create that
        // path in some environments, and the link would then stage — and Save
        // export — an empty MP4 (review round 2). `resourceValues` throws for a
        // missing file; a directory or other non-file is refused too.
        guard try take.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: take])
        }
        // Volume choice from the take's (existing) folder, never the take path
        // itself, so nothing here can fabricate the source.
        let directory = (try? fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: take.deletingLastPathComponent(), create: true
        )) ?? fileManager.temporaryDirectory.appending(
            path: "com.tefa.snappy/SaveStaging-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appending(path: take.lastPathComponent)
        if link(take, staged) != 0 {
            do {
                try fileManager.copyItem(at: take, to: staged)
            } catch {
                try? fileManager.removeItem(at: directory)
                throw error
            }
        }
        return staged
    }

    /// Saves a take secured by `stage` (see `save(_:to:date:)`), then removes
    /// the staging name — on success and on failure.
    static func save(staged: URL, to directory: URL, date: Date) throws -> URL {
        defer { discardStaged(staged) }
        return try save(staged, to: directory, date: date)
    }

    /// Removes a `stage` result and its staging directory.
    static func discardStaged(_ staged: URL) {
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }

    /// Where Copy puts a nicely named clone of an unsaved take — the system
    /// temporary directory, emptied on the next Copy.
    static var clipboardDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "com.tefa.snappy/Clipboard", directoryHint: .isDirectory)
    }

    /// The file Copy puts on the pasteboard for an unsaved take: a clone named
    /// `Recording … .mp4` in `directory` (an APFS clone costs no space), so a
    /// paste into Slack or Finder doesn't arrive as `Take-<id>.mp4`. Earlier
    /// clipboard clones in `directory` are removed first.
    static func clipboardFile(for take: URL, in directory: URL, date: Date) throws -> URL {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: RecordingNamer.filename(for: date))
        try fileManager.copyItem(at: take, to: url)
        return url
    }

    /// Puts `file` on `pasteboard` as a file URL (`NSURL`), which Finder
    /// pastes as a copy of the file and Slack uploads.
    @MainActor
    static func copyToPasteboard(_ file: URL, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
    }
}

/// Where each take was last saved, per **export size** — per **take**, not
/// per window (fix round 1, finding 3). A take outlives its window (the latest
/// is reopenable), so Copy in a reopened window still pastes the saved file,
/// and a Save that finishes after its window closed is still recorded. Copy
/// reuses a saved file only when it was saved at the stop Copy asks for
/// (`RecordingExportSource`). The coordinator owns it and forgets the takes
/// it deletes.
@MainActor
final class RecordingSavedFiles {
    private var saved: [URL: [ExportScale: URL]] = [:]

    /// A Save of `take` at `scale` finished as `file`. Ignored when the take
    /// is already gone (its window closed and it was deleted while the Save
    /// ran).
    func record(_ file: URL, for take: URL, scale: ExportScale = .full) {
        guard FileManager.default.fileExists(atPath: take.path(percentEncoded: false)) else { return }
        saved[take.standardizedFileURL, default: [:]][scale] = file
    }

    /// The file `take` was last saved as at `scale`, while it still exists.
    func savedFile(for take: URL, scale: ExportScale = .full) -> URL? {
        guard let file = saved[take.standardizedFileURL]?[scale],
              FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        return file
    }

    /// Drops every take not in `kept` (deleted alongside the takes).
    func retain(only kept: Set<URL>) {
        let keep = Set(kept.map(\.standardizedFileURL))
        saved = saved.filter { keep.contains($0.key) }
    }
}

/// What Save or Copy exports at the current stop — PURE, tested. The take
/// itself is never modified: 100 % exports it as is (bit-identical, no
/// re-encode); a smaller stop exports a separate re-encode
/// (`RecordingTranscoder`), made once per stop and kept until the next stop's
/// encode or the window closes. **Never** falls back to the full-size take.
enum RecordingExportSource: Equatable {
    /// 100 %: the take as is (Save stages a link, Copy clones it).
    case take
    /// A file already saved at this stop — Copy pastes it directly.
    case saved(URL)
    /// A finished re-encode at this stop.
    case encoded(URL)
    /// No file at this stop yet: re-encode first.
    case needsEncode

    /// Save always writes a new file: the take at 100 %, else the re-encode.
    static func forSave(scale: ExportScale, encoded: URL?) -> Self {
        if scale == .full { return .take }
        return encoded.map(Self.encoded) ?? .needsEncode
    }

    /// Copy matches the current stop: a file saved at this stop is reused,
    /// one saved at another stop never is.
    static func forCopy(scale: ExportScale, saved: URL?, encoded: URL?) -> Self {
        if let saved { return .saved(saved) }
        if scale == .full { return .take }
        return encoded.map(Self.encoded) ?? .needsEncode
    }
}

/// The re-encodes of one recording window: one private folder in the system
/// temporary directory holding at most one file — the latest stop encoded.
/// A new encode replaces it, and closing the window removes the folder, so
/// re-encodes go with the take (Copy's clipboard clone and Save's copy are
/// separate files and outlive it).
@MainActor
final class RecordingExportCache {
    let directory: URL
    private(set) var encoded: (scale: ExportScale, file: URL)?

    init(root: URL = FileManager.default.temporaryDirectory.appending(
        path: "com.tefa.snappy/Exports", directoryHint: .isDirectory
    )) {
        directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// The finished re-encode at `scale`, while it still exists.
    func file(at scale: ExportScale) -> URL? {
        guard let encoded, encoded.scale == scale,
              FileManager.default.fileExists(atPath: encoded.file.path(percentEncoded: false)) else { return nil }
        return encoded.file
    }

    /// Where the next encode at `scale` writes — a fresh name, so a running
    /// Save of the previous file is never cut short. Creates the folder.
    func prepare(_ scale: ExportScale) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Export-\(scale.percent)-\(UUID().uuidString).mp4")
    }

    /// An encode finished: it replaces the previous file.
    func store(_ file: URL, scale: ExportScale) {
        if let previous = encoded?.file, previous != file { try? FileManager.default.removeItem(at: previous) }
        encoded = (scale, file)
    }

    /// The window closed: every re-encode goes.
    func discard() {
        encoded = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

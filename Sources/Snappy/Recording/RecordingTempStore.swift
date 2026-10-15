import Foundation

/// Where takes live until the user saves them — tested with a temp directory.
/// Nothing is lost on close: a take stays in Caches for as long as
/// `RecordingTakeLedger` keeps it (its recording window is open, or it is the
/// latest take), so "Reopen Last Recording" works after its window closed, and
/// even after a relaunch.
///
/// Stateless on purpose: `lastTake` is read from the directory, so there is no
/// bookkeeping to go stale. Which takes to keep is the ledger's decision; the
/// store only lists, names and deletes files.
struct RecordingTempStore: Sendable {
    let directory: URL

    static let takeExtension = "mp4"

    /// `~/Library/Caches/com.tefa.snappy/Recordings/`. The bundle id is spelled
    /// out because an unbundled `swift run` has none.
    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches")
        return caches.appending(path: "com.tefa.snappy/Recordings", directoryHint: .isDirectory)
    }

    init(directory: URL = Self.defaultDirectory) {
        self.directory = directory
    }

    /// Creates the directory and returns the URL the new take is written to
    /// (not created — the pipeline writes it). Deletes nothing (v2, Q30): a
    /// take whose window is open must survive the next recording, and the
    /// latest take survives a recording that is cancelled or fails.
    func prepareNewTake(date: Date = .now) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(date.timeIntervalSince1970 * 1000)
        return directory.appending(path: "Take-\(stamp)-\(UUID().uuidString.prefix(8)).\(Self.takeExtension)")
    }

    /// The most recent take still on disk, nil if there is none.
    var lastTake: URL? {
        takes().max { modificationDate($0) < modificationDate($1) }
    }

    /// Deletes every take except `kept` — the ledger's set when a new take
    /// finished, which also clears takes left behind by an earlier run of the
    /// app. Never call while a capture may be writing a take that isn't in
    /// `kept` (the coordinator calls it only when no run is active).
    func prune(keeping kept: Set<URL>) {
        let keep = Set(kept.map(\.standardizedFileURL))
        for take in takes() where !keep.contains(take.standardizedFileURL) {
            discard(take)
        }
    }

    /// Removes one take — a cancelled recording's partial file, or a take the
    /// ledger released.
    func discard(_ take: URL) {
        try? FileManager.default.removeItem(at: take)
    }

    private func takes() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.pathExtension.lowercased() == Self.takeExtension }
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

/// PURE take lifetime (v2, Q30/Q43) — tested. Decides which takes must stay
/// on disk; `RecordingTempStore` deletes the rest.
///
/// - Each recording window **owns its take**: a take is kept while a window
///   shows it, so several windows coexist and a new recording never deletes
///   a take whose window is open.
/// - The **latest** take is kept even with its window closed, for "Reopen
///   Last Recording" — until a newer take *finishes* and its own window is
///   closed. A recording that is cancelled or fails never becomes a take, so
///   the latest stays reopenable then.
/// - Windows are counted, not flagged: a window that is still closing (its
///   close is reported a run-loop turn later) and a reopened one may briefly
///   overlap on the same take.
///
/// URLs are compared as standardized file URLs.
struct RecordingTakeLedger: Equatable, Sendable {
    /// Open windows per take.
    private var windows: [URL: Int] = [:]
    /// The newest finished take, nil before the first one.
    private(set) var latest: URL?

    /// `latest`: the newest take already on disk (after a relaunch), if any.
    init(latest: URL? = nil) {
        self.latest = latest?.standardizedFileURL
    }

    /// Every take that must stay on disk right now.
    var kept: Set<URL> {
        var kept = Set(windows.keys)
        if let latest { kept.insert(latest) }
        return kept
    }

    func keeps(_ take: URL) -> Bool {
        kept.contains(take.standardizedFileURL)
    }

    /// True while at least one window shows `take`.
    func isOpen(_ take: URL) -> Bool {
        windows[take.standardizedFileURL, default: 0] > 0
    }

    /// A recording finished as `take`; it becomes the latest. Returns the
    /// takes this releases: the previous latest, unless a window still shows
    /// it. (The take's own window opens next, through `opened`.)
    mutating func finished(_ take: URL) -> [URL] {
        let take = take.standardizedFileURL
        let previous = latest
        latest = take
        guard let previous, previous != take, !isOpen(previous) else { return [] }
        return [previous]
    }

    /// A window opened on `take`.
    mutating func opened(_ take: URL) {
        windows[take.standardizedFileURL, default: 0] += 1
    }

    /// A window on `take` closed. Returns `[take]` when that released it — no
    /// other window shows it and it isn't the latest — else nothing.
    mutating func closed(_ take: URL) -> [URL] {
        let take = take.standardizedFileURL
        guard let count = windows[take] else { return [] }
        if count > 1 {
            windows[take] = count - 1
            return []
        }
        windows[take] = nil
        return take == latest ? [] : [take]
    }
}

import Foundation

/// Builds the `Recording yyyy-MM-dd at HH.mm.ss.mp4` filenames for Save and
/// Copy in the recording window — pure so the format is unit-testable. Mirrors
/// `ScreenshotNamer`, so a saved recording sorts next to the screenshots taken
/// around it.
enum RecordingNamer {
    /// `index` disambiguates files saved within the same second: nil or 1 gives
    /// the plain name, 2… append ` (2)`, ` (3)`, ….
    static func filename(for date: Date, timeZone: TimeZone = .current, index: Int? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let suffix = (index ?? 1) > 1 ? " (\(index!))" : ""
        return "Recording \(formatter.string(from: date))\(suffix).\(RecordingTempStore.takeExtension)"
    }
}

import Carbon.HIToolbox
import Foundation

/// Settings → Countdown (Off / 1 / 2 / 3 / 5 s).
enum RecordingCountdown: Int, CaseIterable, Equatable, Sendable {
    case off = 0, one = 1, two = 2, three = 3, five = 5

    var seconds: Int { rawValue }
}

/// Settings → Frame rate.
enum RecordingFrameRate: Int, CaseIterable, Equatable, Sendable {
    case fps30 = 30, fps60 = 60

    var framesPerSecond: Int { rawValue }
}

/// Settings → Video quality. The bitrate per quality lives in T2's
/// `OutputGeometry` bitrate table.
enum RecordingQuality: String, CaseIterable, Equatable, Sendable {
    case standard, high
}

/// Every option of Settings → Recording (`features/recording.md`, Q10/Q27) with
/// its default — PURE value, tested. The pipeline, ink and chrome get a copy
/// per session (`SettingsStore.recordingSettings`); T6 builds the UI over the
/// individual `SettingsStore` accessors, which all exist already.
struct RecordingSettings: Equatable, Sendable {
    var countdown: RecordingCountdown = .three
    var frameRate: RecordingFrameRate = .fps60
    var showsCursor = true
    /// ScreenCaptureKit's `showMouseClicks` ripples.
    var showsClicks = true
    var fadingInkAtStart = false
    /// Seconds before a faded stroke disappears, `fadeDelayRange`.
    var fadeDelay: Int = 3 {
        didSet { fadeDelay = Self.clampedFadeDelay(fadeDelay) }
    }
    var defaultColor: InkColorPreset = .red
    var defaultWidth: InkWidth = .medium
    var quality: RecordingQuality = .high
    /// The export-size stop each new recording window opens at; the window's
    /// slider is a per-take override that never writes back.
    var exportScale: ExportScale = .full
    /// Session-only draw/interact toggle (registered only while a session is active).
    var drawModeHotKey: HotKeyCombo = .defaultDrawMode
    /// Session-only Magic Pen toggle (registered only while a session is active).
    var magicPenHotKey: HotKeyCombo = .defaultMagicPen
    /// Magic Pen thickness — also changed live from the menu bar and with [ ].
    var magicPenWidth: InkWidth = .medium

    static let fadeDelayRange = 1...10

    static func clampedFadeDelay(_ seconds: Int) -> Int {
        min(fadeDelayRange.upperBound, max(fadeDelayRange.lowerBound, seconds))
    }
}

extension HotKeyCombo {
    /// ⌃⌥D — toggles draw/interact mode while a recording session is active.
    static let defaultDrawMode = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_D),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    /// ⌃⌥P — toggles Magic Pen mode while a recording session is active.
    static let defaultMagicPen = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_P),
        carbonModifiers: UInt32(controlKey | optionKey)
    )
}

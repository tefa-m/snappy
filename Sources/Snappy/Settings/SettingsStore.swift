import CoreGraphics
import Foundation

/// UserDefaults-backed app settings. Grows per feature (see docs/FEATURE_MAP.md).
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    private enum Key {
        static let saveDirectoryPath = "saveDirectoryPath"
        static let captureHotKey = "captureHotKey"
        static let fullscreenHotKey = "fullscreenHotKey"
        static let toolAwareCursorEnabled = "toolAwareCursorEnabled"
        static let canvasPadding = "canvasPadding"
        static let hasCompletedFirstCapture = "hasCompletedFirstCapture"
        // Settings → Recording (features/recording.md)
        static let recordingCountdown = "recordingCountdown"
        static let recordingFrameRate = "recordingFrameRate"
        static let recordingShowsCursor = "recordingShowsCursor"
        static let recordingShowsClicks = "recordingShowsClicks"
        static let recordingFadingInkAtStart = "recordingFadingInkAtStart"
        static let recordingFadeDelay = "recordingFadeDelay"
        static let recordingDefaultColor = "recordingDefaultColor"
        static let recordingDefaultWidth = "recordingDefaultWidth"
        static let recordingQuality = "recordingQuality"
        static let recordingDrawModeHotKey = "recordingDrawModeHotKey"
        static let recordingMagicPenHotKey = "recordingMagicPenHotKey"
        static let recordingMagicPenWidth = "recordingMagicPenWidth"
        static let recordingAccessibilityPrompted = "recordingAccessibilityPrompted"
    }

    /// Padding (screen points) added between an annotation and the new canvas
    /// edge when the canvas auto-expands (M-F). Multiplied by the capture's
    /// backing scale to get image pixels. Default 16 pt.
    static let defaultCanvasPadding: CGFloat = 16

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Folder the Save action writes PNGs into. Defaults to ~/Desktop.
    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: Key.saveDirectoryPath) {
                return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Desktop", directoryHint: .isDirectory)
        }
        set { defaults.set(newValue.path, forKey: Key.saveDirectoryPath) }
    }

    /// True once a capture has succeeded at least once, which proves the
    /// Screen Recording grant is in place. Gates every `SCShareableContent`
    /// warm-up: priming before the user has asked for a capture would move the
    /// TCC prompt to login.
    var hasCompletedFirstCapture: Bool {
        get { defaults.bool(forKey: Key.hasCompletedFirstCapture) }
        set { defaults.set(newValue, forKey: Key.hasCompletedFirstCapture) }
    }

    /// Global capture shortcut (⇧⌘4 by default; Settings → Shortcuts changes
    /// it through `GlobalHotKeys`, which persists only a combo it could register).
    var captureHotKey: HotKeyCombo {
        get {
            if let dict = defaults.dictionary(forKey: Key.captureHotKey) as? [String: Int],
               let combo = HotKeyCombo(userDefaultsRepresentation: dict) {
                return combo
            }
            return .defaultCapture
        }
        set { defaults.set(newValue.userDefaultsRepresentation, forKey: Key.captureHotKey) }
    }

    /// Global fullscreen-capture shortcut (⇧⌘3 by default). Its own key, so
    /// changing one hot key never disturbs the other.
    var fullscreenHotKey: HotKeyCombo {
        get {
            if let dict = defaults.dictionary(forKey: Key.fullscreenHotKey) as? [String: Int],
               let combo = HotKeyCombo(userDefaultsRepresentation: dict) {
                return combo
            }
            return .defaultFullscreen
        }
        set { defaults.set(newValue.userDefaultsRepresentation, forKey: Key.fullscreenHotKey) }
    }

    /// All four remappable hot keys at once (`SnappyHotKey`), each through
    /// its own key above.
    var hotKeyBindings: HotKeyBindings {
        get {
            HotKeyBindings(
                captureArea: captureHotKey,
                captureFullscreen: fullscreenHotKey,
                drawMode: recordingDrawModeHotKey,
                magicPen: recordingMagicPenHotKey
            )
        }
        set {
            if newValue.captureArea != captureHotKey { captureHotKey = newValue.captureArea }
            if newValue.captureFullscreen != fullscreenHotKey { fullscreenHotKey = newValue.captureFullscreen }
            if newValue.drawMode != recordingDrawModeHotKey { recordingDrawModeHotKey = newValue.drawMode }
            if newValue.magicPen != recordingMagicPenHotKey { recordingMagicPenHotKey = newValue.magicPen }
        }
    }

    /// Tool-aware editor cursor (crosshair + tool badge, hover cursors, tool
    /// name flash). ON by default; OFF falls back to the plain cursor rects.
    var toolAwareCursorEnabled: Bool {
        get { defaults.object(forKey: Key.toolAwareCursorEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.toolAwareCursorEnabled) }
    }

    /// Auto-expand canvas padding in screen points (0…100). Default 16.
    var canvasPadding: CGFloat {
        get {
            guard let value = defaults.object(forKey: Key.canvasPadding) as? Double else {
                return Self.defaultCanvasPadding
            }
            return min(100, max(0, CGFloat(value)))
        }
        set { defaults.set(Double(min(100, max(0, newValue))), forKey: Key.canvasPadding) }
    }

    // MARK: - Recording (features/recording.md › Settings → Recording)

    // One accessor per row of the Settings table, for T6's UI. A missing or
    // unreadable value (e.g. a countdown of 4 s written by hand) reads as the
    // default, never as a crash or an out-of-range value.

    /// Every recording option at once — what a session copies at its start.
    var recordingSettings: RecordingSettings {
        get {
            RecordingSettings(
                countdown: recordingCountdown,
                frameRate: recordingFrameRate,
                showsCursor: recordingShowsCursor,
                showsClicks: recordingShowsClicks,
                fadingInkAtStart: recordingFadingInkAtStart,
                fadeDelay: recordingFadeDelay,
                defaultColor: recordingDefaultColor,
                defaultWidth: recordingDefaultWidth,
                quality: recordingQuality,
                drawModeHotKey: recordingDrawModeHotKey,
                magicPenHotKey: recordingMagicPenHotKey,
                magicPenWidth: recordingMagicPenWidth
            )
        }
        set {
            recordingCountdown = newValue.countdown
            recordingFrameRate = newValue.frameRate
            recordingShowsCursor = newValue.showsCursor
            recordingShowsClicks = newValue.showsClicks
            recordingFadingInkAtStart = newValue.fadingInkAtStart
            recordingFadeDelay = newValue.fadeDelay
            recordingDefaultColor = newValue.defaultColor
            recordingDefaultWidth = newValue.defaultWidth
            recordingQuality = newValue.quality
            recordingDrawModeHotKey = newValue.drawModeHotKey
            recordingMagicPenHotKey = newValue.magicPenHotKey
            recordingMagicPenWidth = newValue.magicPenWidth
        }
    }

    private static let recordingDefaults = RecordingSettings()

    /// Countdown before recording starts (Off / 1 / 2 / 3 / 5 s). Default 3 s.
    var recordingCountdown: RecordingCountdown {
        get {
            (defaults.object(forKey: Key.recordingCountdown) as? Int).flatMap(RecordingCountdown.init(rawValue:))
                ?? Self.recordingDefaults.countdown
        }
        set { defaults.set(newValue.rawValue, forKey: Key.recordingCountdown) }
    }

    /// 30 or 60 fps. Default 60.
    var recordingFrameRate: RecordingFrameRate {
        get {
            (defaults.object(forKey: Key.recordingFrameRate) as? Int).flatMap(RecordingFrameRate.init(rawValue:))
                ?? Self.recordingDefaults.frameRate
        }
        set { defaults.set(newValue.rawValue, forKey: Key.recordingFrameRate) }
    }

    /// Cursor in the video. Default on.
    var recordingShowsCursor: Bool {
        get { defaults.object(forKey: Key.recordingShowsCursor) as? Bool ?? Self.recordingDefaults.showsCursor }
        set { defaults.set(newValue, forKey: Key.recordingShowsCursor) }
    }

    /// Click ripples in the video. Default on.
    var recordingShowsClicks: Bool {
        get { defaults.object(forKey: Key.recordingShowsClicks) as? Bool ?? Self.recordingDefaults.showsClicks }
        set { defaults.set(newValue, forKey: Key.recordingShowsClicks) }
    }

    /// Fading ink already on when a session starts. Default off.
    var recordingFadingInkAtStart: Bool {
        get {
            defaults.object(forKey: Key.recordingFadingInkAtStart) as? Bool
                ?? Self.recordingDefaults.fadingInkAtStart
        }
        set { defaults.set(newValue, forKey: Key.recordingFadingInkAtStart) }
    }

    /// Fade delay in whole seconds, clamped to 1…10. Default 3.
    var recordingFadeDelay: Int {
        get {
            guard let value = defaults.object(forKey: Key.recordingFadeDelay) as? Int else {
                return Self.recordingDefaults.fadeDelay
            }
            return RecordingSettings.clampedFadeDelay(value)
        }
        set { defaults.set(RecordingSettings.clampedFadeDelay(newValue), forKey: Key.recordingFadeDelay) }
    }

    /// Colour preset new sessions start with. Default red.
    var recordingDefaultColor: InkColorPreset {
        get {
            (defaults.object(forKey: Key.recordingDefaultColor) as? Int).flatMap(InkColorPreset.init(rawValue:))
                ?? Self.recordingDefaults.defaultColor
        }
        set { defaults.set(newValue.rawValue, forKey: Key.recordingDefaultColor) }
    }

    /// Line width new sessions start with. Default medium.
    var recordingDefaultWidth: InkWidth {
        get {
            (defaults.object(forKey: Key.recordingDefaultWidth) as? Int).flatMap(InkWidth.init(rawValue:))
                ?? Self.recordingDefaults.defaultWidth
        }
        set { defaults.set(newValue.rawValue, forKey: Key.recordingDefaultWidth) }
    }

    /// Standard or High bitrate. Default High.
    var recordingQuality: RecordingQuality {
        get {
            defaults.string(forKey: Key.recordingQuality).flatMap(RecordingQuality.init(rawValue:))
                ?? Self.recordingDefaults.quality
        }
        set { defaults.set(newValue.rawValue, forKey: Key.recordingQuality) }
    }

    /// Session-only draw/interact hot key. Default ⌃⌥D. Read at each session
    /// start; a Settings change during a session is rebound live
    /// (`RecordingCoordinator.rebindSessionHotKey`).
    var recordingDrawModeHotKey: HotKeyCombo {
        get {
            if let dict = defaults.dictionary(forKey: Key.recordingDrawModeHotKey) as? [String: Int],
               let combo = HotKeyCombo(userDefaultsRepresentation: dict) {
                return combo
            }
            return Self.recordingDefaults.drawModeHotKey
        }
        set { defaults.set(newValue.userDefaultsRepresentation, forKey: Key.recordingDrawModeHotKey) }
    }

    /// Session-only Magic Pen hot key. Default ⌃⌥P. Read at each session
    /// start and rebound live, like the draw-mode hot key.
    var recordingMagicPenHotKey: HotKeyCombo {
        get {
            if let dict = defaults.dictionary(forKey: Key.recordingMagicPenHotKey) as? [String: Int],
               let combo = HotKeyCombo(userDefaultsRepresentation: dict) {
                return combo
            }
            return Self.recordingDefaults.magicPenHotKey
        }
        set { defaults.set(newValue.userDefaultsRepresentation, forKey: Key.recordingMagicPenHotKey) }
    }

    /// Magic Pen thickness. Default medium. Unlike the other recording
    /// options it also applies live — the menu bar, Settings and [ ] change it
    /// during a session (`RecordingCoordinator.setMagicPenWidth`).
    var recordingMagicPenWidth: InkWidth {
        get {
            (defaults.object(forKey: Key.recordingMagicPenWidth) as? Int).flatMap(InkWidth.init(rawValue:))
                ?? Self.recordingDefaults.magicPenWidth
        }
        set { defaults.set(newValue.rawValue, forKey: Key.recordingMagicPenWidth) }
    }

    /// True once the Accessibility prompt for window parts was shown (the
    /// first S/W snap mode without access, Q39). Snappy never prompts
    /// automatically again; Settings → Recording links to System Settings.
    var recordingAccessibilityPrompted: Bool {
        get { defaults.bool(forKey: Key.recordingAccessibilityPrompted) }
        set { defaults.set(newValue, forKey: Key.recordingAccessibilityPrompted) }
    }
}

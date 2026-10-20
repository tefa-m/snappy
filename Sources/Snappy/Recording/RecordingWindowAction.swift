import AppKit

/// Everything the recording window does (v2, Q31/Q32; keys from Q24) — pure,
/// tested. The toolbar shows `buttons`; Space and Esc/Q have no button (the
/// player's own controls play/pause, and the traffic light closes).
///
/// Unlike the screenshot panel, Copy and Save need ⌘ here (Q24): plain C / S
/// do nothing, so the only bare letters are R (Retake) and Q (Close). `[` / `]`
/// step the status capsule's export-size slider (no clash: the recording
/// session's own `[` `]` — `RecordingKeyMap` — only reach the Setup overlay
/// and the ink panel, never this window).
enum RecordingWindowAction: CaseIterable, Equatable {
    case playPause, retake, save, copy, close, smallerExport, largerExport

    /// The toolbar buttons, leading to trailing: Retake after the traffic
    /// lights, then Save and the prominent Copy at the trailing edge — Copy
    /// last, the "done" position, as in the editor toolbar (Save·Pin·Copy).
    static let buttons: [RecordingWindowAction] = [.retake, .save, .copy]

    var title: String {
        switch self {
        case .playPause: "Play/Pause"
        case .retake: "Retake"
        case .save: "Save"
        case .copy: "Copy"
        case .close: "Close"
        case .smallerExport: "Decrease Export Size"
        case .largerExport: "Increase Export Size"
        }
    }

    var symbolName: String {
        switch self {
        case .playPause: "playpause"
        case .retake: "arrow.counterclockwise"
        // Same symbols as the screenshot panel's and the editor's Save and Copy.
        case .save: "square.and.arrow.down"
        case .copy: "document.on.document"
        case .close: "xmark"
        case .smallerExport: "arrow.down.right.and.arrow.up.left"
        case .largerExport: "arrow.up.left.and.arrow.down.right"
        }
    }

    /// The shortcut as advertised in the tooltip.
    var keyLabel: String {
        switch self {
        case .playPause: "Space"
        case .retake: "R"
        case .save: "⌘S"
        case .copy: "⇧⌘C"
        case .close: "Esc"
        case .smallerExport: "["
        case .largerExport: "]"
        }
    }

    /// Tooltip in the app-wide "<verb phrase> (KEY)" form, brief and without
    /// articles like the editor's (HIG Offering help). Save names the
    /// destination folder; Copy says it closes, like the editor's Copy.
    func toolTip(saveFolderName: String) -> String {
        let description = switch self {
        case .playPause: "Play or pause recording"
        case .retake: "Record this area again"
        case .save: "Save MP4 to \(saveFolderName)"
        case .copy: "Copy video file and close"
        case .close: "Close without saving"
        case .smallerExport: "Smaller export"
        case .largerExport: "Larger export"
        }
        return "\(description) (\(keyLabel))"
    }

    /// The action a key press triggers, nil when the window ignores it.
    /// `characters` is `charactersIgnoringModifiers`.
    ///
    /// - Space, R, Q, Esc, `[` and `]` are bare keys (`ShortcutKeys.isBareKey`: Shift and
    ///   Caps Lock tolerated).
    /// - ⌘S saves. ⇧⌘C is the advertised Copy; plain ⌘C also works, as in the
    ///   editor. ⌘W closes — the app has no main menu, so every window handles
    ///   it itself (ARCHITECTURE › No main menu).
    /// - Plain C and S do nothing (Q24).
    static func action(
        keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> RecordingWindowAction? {
        let key = characters?.lowercased()
        if ShortcutKeys.isBareKey(modifiers) {
            if keyCode == escapeKeyCode { return .close }
            if keyCode == spaceKeyCode { return .playPause }
            switch key {
            case "q": return .close
            case "r": return .retake
            case "[": return .smallerExport
            case "]": return .largerExport
            default: return nil
            }
        }
        let held = modifiers.intersection([.command, .shift, .option, .control])
        switch (key, held) {
        case ("s", [.command]): return .save
        case ("c", [.command, .shift]), ("c", [.command]): return .copy
        case ("w", [.command]): return .close
        default: return nil
        }
    }

    static let escapeKeyCode: UInt16 = 53
    static let spaceKeyCode: UInt16 = 49
}

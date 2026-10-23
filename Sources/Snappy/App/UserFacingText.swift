import Foundation

/// Title + informative text for an `NSAlert`.
struct AlertText: Equatable {
    let title: String
    let message: String
}

/// Title + body for a notification banner.
struct BannerText: Equatable {
    let title: String
    let body: String
}

/// PURE user-facing copy for alerts and banners — unit-tested. One place, so
/// the voice stays consistent and no raw `String(describing: error)` reaches
/// a person.
///
/// - Alerts (HIG Alerts › Content): the title is a complete sentence in
///   sentence case with ending punctuation; the message says what to do next.
/// - Banners (HIG Notifications › Content): title-style title, no ending
///   punctuation; the body is a complete sentence.
enum UserFacingText {
    // MARK: - Alerts

    static func captureFailed(_ error: Error) -> AlertText {
        let title = "Snappy couldn’t take the screenshot."
        switch error {
        case CaptureError.noMatchingDisplay:
            return AlertText(
                title: title,
                message: "The displays changed while the screenshot was being taken. Try again."
            )
        case CaptureError.noImage:
            return AlertText(title: title, message: "The screen didn’t return an image. Try again.")
        default:
            return AlertText(title: title, message: retryMessage(for: error))
        }
    }

    /// A recording that couldn't start or finish. The pipeline (T2) gives its
    /// errors a `LocalizedError.errorDescription`, which becomes the reason; a
    /// TCC denial never gets here (it shows `screenRecordingPermission`).
    static func recordingFailed(_ error: Error) -> AlertText {
        AlertText(title: "Snappy couldn’t record the screen.", message: retryMessage(for: error))
    }

    static func textRecognitionFailed(_ error: Error) -> AlertText {
        AlertText(
            title: "Snappy couldn’t recognize text in the screenshot.",
            message: retryMessage(for: error)
        )
    }

    static func saveFailed(_ error: Error, folderName: String) -> AlertText {
        let reason: String? = switch error {
        case ScreenshotSaveError.pngEncodingFailed:
            "The image couldn’t be converted to PNG."
        case ScreenshotSaveError.tooManyCollisions:
            "Too many screenshots with the same name were saved in the same second."
        default:
            systemReason(for: error)
        }
        let advice = "To save somewhere else, choose a different folder in Snappy Settings."
        return AlertText(
            title: "Snappy couldn’t save the screenshot to “\(folderName)”.",
            message: reason.map { "\($0) \(advice)" } ?? advice
        )
    }

    /// The session-only draw-mode hot key couldn't be registered — another
    /// app owns the combo. Recording still works; the toolbar toggles.
    static func drawModeHotKeyUnavailable(_ combo: String) -> BannerText {
        BannerText(
            title: "Draw Mode Shortcut Unavailable",
            body: "Another app is using \(combo). Switch modes with the toolbar’s draw button, "
                + "or choose a different shortcut in Snappy Settings."
        )
    }

    /// The session-only Magic Pen hot key couldn't be registered — another
    /// app owns the combo (or it is the draw-mode one). The toolbar's Magic
    /// Pen button still works.
    static func magicPenHotKeyUnavailable(_ combo: String) -> BannerText {
        BannerText(
            title: "Magic Pen Shortcut Unavailable",
            body: "\(combo) can’t be used right now. Turn on the Magic Pen with the toolbar’s wand button, "
                + "or choose a different shortcut in Snappy Settings."
        )
    }

    /// Save from a recording window failed.
    static func recordingSaveFailed(_ error: Error, folderName: String) -> AlertText {
        let reason: String? = switch error {
        case ScreenshotSaveError.tooManyCollisions:
            "Too many recordings with the same name were saved in the same second."
        default:
            systemReason(for: error)
        }
        let advice = "To save somewhere else, choose a different folder in Snappy Settings."
        return AlertText(
            title: "Snappy couldn’t save the recording to “\(folderName)”.",
            message: reason.map { "\($0) \(advice)" } ?? advice
        )
    }

    /// Copy from a recording window couldn't prepare the file to paste (a
    /// `Recording … .mp4` clone of the take). The window stays open, so the
    /// take can still be saved.
    static func recordingCopyFailed(_ error: Error) -> AlertText {
        AlertText(title: "Snappy couldn’t copy the recording.", message: retryMessage(for: error))
    }

    /// Copy from a recording window prepared the file, but the clipboard
    /// refused it. The window stays open, so Copy can be tried again.
    static let recordingClipboardFailed = AlertText(
        title: "Snappy couldn’t copy the recording.",
        message: "The clipboard didn’t accept it. Try again. If it keeps happening, quit and reopen Snappy."
    )

    /// The button opens System Settings, so the text names the switch rather
    /// than explaining the button (HIG Alerts › Content). The pane has been
    /// "Screen & System Audio Recording" since macOS 15.
    /// The editor couldn't flatten the annotations into an image, so Copy,
    /// Save or Pin had nothing to export.
    static let annotatedImageFailed = AlertText(
        title: "Snappy couldn’t create the annotated image.",
        message: "Nothing was copied, saved or pinned. Try again."
    )

    static let screenRecordingPermission = AlertText(
        title: "Snappy doesn’t have permission to record the screen.",
        message: "Turn on Snappy in Privacy & Security › Screen & System Audio Recording, "
            + "then quit and reopen Snappy."
    )

    static let openSystemSettingsButton = "Open System Settings"

    // MARK: - Banners

    static func textCopied(_ text: String) -> BannerText {
        BannerText(title: "Text Copied", body: TextAssembler.preview(of: text))
    }

    static let noTextFound = BannerText(
        title: "No Text Found",
        body: "The screenshot contains no recognizable text. The clipboard is unchanged."
    )

    // MARK: - Helpers

    /// The system's own description when it is written for people, followed by
    /// the generic next step.
    private static func retryMessage(for error: Error) -> String {
        let advice = "Try again. If it keeps happening, quit and reopen Snappy."
        guard let reason = systemReason(for: error) else { return advice }
        return "\(reason) \(advice)"
    }

    /// A description only when someone actually wrote one: a `LocalizedError`
    /// with an `errorDescription`, an `NSError` carrying
    /// `NSLocalizedDescriptionKey`, or a Cocoa error (Foundation localizes those
    /// codes into sentences). Everything else — a plain Swift enum, or an
    /// Apple-domain error with no description — would surface a synthesized
    /// "The operation couldn’t be completed. (… error -3812.)", so it is
    /// dropped and only the advice remains. The domain alone proves nothing.
    static func systemReason(for error: Error) -> String? {
        let nsError = error as NSError
        let written: String? = if let localized = error as? LocalizedError,
                                  let description = localized.errorDescription {
            description
        } else if let description = nsError.userInfo[NSLocalizedDescriptionKey] as? String {
            description
        } else if nsError.domain == NSCocoaErrorDomain {
            nsError.localizedDescription
        } else {
            nil
        }
        guard let text = written?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text.hasSuffix(".") ? text : text + "."
    }
}

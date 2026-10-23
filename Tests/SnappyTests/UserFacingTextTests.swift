import Foundation
import Testing

@testable import Snappy

@Suite("UserFacingText")
struct UserFacingTextTests {
    private enum OpaqueError: Error { case boom }

    @Test("Capture errors map to readable copy, never the enum case name")
    func captureErrorsAreReadable() {
        for error: Error in [CaptureError.noImage, CaptureError.noMatchingDisplay, OpaqueError.boom] {
            let text = UserFacingText.captureFailed(error)
            #expect(text.title == "Snappy couldn’t take the screenshot.")
            #expect(!text.message.contains("noImage"))
            #expect(!text.message.contains("noMatchingDisplay"))
            #expect(!text.message.contains("Snappy.CaptureError"), "no bridged Swift error domain")
            #expect(!text.message.contains("couldn’t be completed"), "no bridged Swift error text")
            #expect(text.message.hasSuffix("."))
        }
    }

    @Test("Opaque Swift errors get advice only; system errors keep their description")
    func systemReasonFiltering() {
        #expect(UserFacingText.systemReason(for: OpaqueError.boom) == nil)
        let cocoa = CocoaError(.fileWriteNoPermission)
        #expect(UserFacingText.systemReason(for: cocoa) == (cocoa as NSError).localizedDescription)
        let written = NSError(
            domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
            userInfo: [NSLocalizedDescriptionKey: "The disk is full"]
        )
        #expect(UserFacingText.systemReason(for: written) == "The disk is full.")
    }

    private struct SilentLocalizedError: LocalizedError {}

    @Test("Synthesized descriptions are dropped, whatever the domain")
    func synthesizedDescriptionsAreDropped() {
        let sck = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3812)
        #expect(UserFacingText.systemReason(for: sck) == nil)
        #expect(UserFacingText.systemReason(for: NSError(domain: NSOSStatusErrorDomain, code: -50)) == nil)
        #expect(UserFacingText.systemReason(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == nil)
        #expect(UserFacingText.systemReason(for: SilentLocalizedError()) == nil)
        #expect(UserFacingText.captureFailed(sck).message
            == "Try again. If it keeps happening, quit and reopen Snappy.")
    }

    @Test("Text recognition failure is a sentence and avoids the OCR acronym")
    func ocrFailure() {
        let text = UserFacingText.textRecognitionFailed(OpaqueError.boom)
        #expect(text.title == "Snappy couldn’t recognize text in the screenshot.")
        #expect(!text.title.contains("OCR"))
        #expect(text.message == "Try again. If it keeps happening, quit and reopen Snappy.")
    }

    @Test("Save failure names the folder and points to Settings")
    func saveFailure() {
        let text = UserFacingText.saveFailed(ScreenshotSaveError.tooManyCollisions, folderName: "Desktop")
        #expect(text.title == "Snappy couldn’t save the screenshot to “Desktop”.")
        #expect(text.message.hasPrefix("Too many screenshots"))
        #expect(text.message.hasSuffix("choose a different folder in Snappy Settings."))
    }

    @Test("Recording save failure names the recording and the folder")
    func recordingSaveFailure() {
        let text = UserFacingText.recordingSaveFailed(ScreenshotSaveError.tooManyCollisions, folderName: "Desktop")
        #expect(text.title == "Snappy couldn’t save the recording to “Desktop”.")
        #expect(text.message.hasPrefix("Too many recordings with the same name"))
        #expect(text.message.hasSuffix("choose a different folder in Snappy Settings."))
        // An undescribed error contributes no synthesized reason.
        #expect(UserFacingText.recordingSaveFailed(OpaqueError.boom, folderName: "Desktop").message
            == "To save somewhere else, choose a different folder in Snappy Settings.")
    }

    @Test("Recording copy failure is a sentence with the retry advice")
    func recordingCopyFailure() {
        let text = UserFacingText.recordingCopyFailed(CocoaError(.fileWriteOutOfSpace))
        #expect(text.title == "Snappy couldn’t copy the recording.")
        #expect(text.message.hasSuffix("Try again. If it keeps happening, quit and reopen Snappy."))
        #expect(UserFacingText.recordingCopyFailed(OpaqueError.boom).message
            == "Try again. If it keeps happening, quit and reopen Snappy.")
    }

    @Test("Permission alert names the macOS 15+ pane")
    func permissionAlert() {
        #expect(UserFacingText.screenRecordingPermission.message.contains("Screen & System Audio Recording"))
    }

    @Test("Alert titles are complete sentences; banner titles are title-style without punctuation")
    func capitalizationRules() {
        let alerts = [
            UserFacingText.captureFailed(OpaqueError.boom),
            UserFacingText.textRecognitionFailed(OpaqueError.boom),
            UserFacingText.saveFailed(OpaqueError.boom, folderName: "Desktop"),
            UserFacingText.screenRecordingPermission,
            UserFacingText.annotatedImageFailed,
            UserFacingText.recordingCopyFailed(OpaqueError.boom),
            UserFacingText.recordingClipboardFailed,
        ]
        for alert in alerts {
            #expect(alert.title.hasSuffix("."))
            #expect(alert.title.first?.isUppercase == true)
        }
        #expect(UserFacingText.textCopied("x").title == "Text Copied")
        #expect(UserFacingText.noTextFound.title == "No Text Found")
        for banner in [UserFacingText.textCopied("x"), UserFacingText.noTextFound,
                       UserFacingText.drawModeHotKeyUnavailable("⌃⌥D")] {
            #expect(banner.title.last?.isLetter == true)
        }
    }

    @Test("A refused draw-mode shortcut names the combo and both ways out")
    func drawModeHotKeyUnavailable() {
        let banner = UserFacingText.drawModeHotKeyUnavailable("⌃⌥D")
        #expect(banner.title == "Draw Mode Shortcut Unavailable")
        #expect(banner.body.contains("⌃⌥D"))
        #expect(banner.body.contains("toolbar"))
        #expect(banner.body.hasSuffix("Snappy Settings."))
    }

    @Test("Text Copied body is the single-line preview")
    func textCopiedBody() {
        #expect(UserFacingText.textCopied("Hallo\nWelt").body == "Hallo Welt")
    }
}

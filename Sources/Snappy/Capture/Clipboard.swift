import AppKit

enum Clipboard {
    /// Copies an image to the general pasteboard as PNG + TIFF. `scale` is the
    /// capture's pixels-per-point; it becomes the encoded DPI (PNG `pHYs`, TIFF
    /// resolution tags) so a 2× shot pastes at its on-screen size.
    static func copy(_ image: CGImage, scale: CGFloat) {
        let rep = BitmapRep.make(image, scale: scale)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    /// Copies plain text to the general pasteboard.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Builds the `NSBitmapImageRep` used for every PNG/TIFF encode (Copy, Save).
enum BitmapRep {
    /// `rep.size` defaults to the pixel size (72 dpi); dividing by the capture
    /// scale makes the encoders write 144 dpi for a 2× capture, so other apps
    /// open and paste it at the size it had on screen.
    static func make(_ image: CGImage, scale: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(cgImage: image)
        if scale > 0 {
            rep.size = NSSize(
                width: CGFloat(image.width) / scale,
                height: CGFloat(image.height) / scale
            )
        }
        return rep
    }
}

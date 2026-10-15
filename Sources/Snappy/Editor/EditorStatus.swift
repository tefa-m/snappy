import CoreGraphics

/// Text of the editor's glass status capsule (Tahoe Glass): the capture's
/// name — the same "Shot W × H" as the hidden window title — and the current
/// zoom. Pure, unit-tested.
enum EditorStatus {
    /// On-screen zoom in percent: view points per image point, where an image
    /// point is `scale` pixels. 100 % = the capture at its original size.
    static func zoomPercent(viewWidth: CGFloat, canvasPixelWidth: CGFloat, scale: CGFloat) -> Int {
        guard viewWidth > 0, canvasPixelWidth > 0, scale > 0 else { return 100 }
        return Int((viewWidth / (canvasPixelWidth / scale) * 100).rounded())
    }

    static func text(title: String, zoomPercent: Int) -> String {
        "\(title) · \(zoomPercent)%"
    }
}

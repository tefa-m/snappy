import CoreGraphics
import CoreText
import Foundation
import os

/// Pure text metrics and CTLine construction for text annotations and counter
/// badge numbers (M6). Uses the system UI font via CoreText — the same family
/// NSTextField uses — so the in-place editor matches the rendered result.
/// All sizes are in the same units as the model (image pixels).
enum TextGeometry {

    /// Font size derived from the style's stroke width, so the existing width
    /// popup doubles as the text-size control (1/2/3/5/8 pt → 6/12/18/30/48 pt
    /// at 1x). Advertised in the popup's tooltip.
    static func fontSize(strokeWidth: CGFloat) -> CGFloat {
        max(8, 6 * strokeWidth)
    }

    /// Fonts by size: hit-testing and canvas-rect derivation measure every
    /// label on each event, and a CTFont is immutable, so rebuilding one per
    /// measurement is pure waste. Few distinct sizes exist (the width popup),
    /// but the cache is capped anyway. Locked because this type is nonisolated.
    private struct FontKey: Hashable {
        let size: CGFloat
        let bold: Bool
    }
    private static let fontCache = OSAllocatedUnfairLock(uncheckedState: [FontKey: CTFont]())
    private static let maxCachedFonts = 64

    /// The system UI font; `bold` is the emphasized system font (counter
    /// badge digits — bold text needs 3:1 contrast instead of 4.5:1).
    static func font(ofSize size: CGFloat, bold: Bool = false) -> CTFont {
        let key = FontKey(size: size, bold: bold)
        if let cached = fontCache.withLockUnchecked({ $0[key] }) { return cached }
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        fontCache.withLockUnchecked { cache in
            if cache.count >= maxCachedFonts { cache.removeAll() }
            cache[key] = font
        }
        return font
    }

    struct Metrics {
        var size: CGSize
        var ascent: CGFloat
        var descent: CGFloat
    }

    /// Typographic bounds of a single line. The bounding box height is
    /// ascent + descent; the baseline sits `descent` above the box bottom.
    static func measure(_ text: String, fontSize: CGFloat, bold: Bool = false) -> Metrics {
        guard !text.isEmpty else {
            return Metrics(size: .zero, ascent: 0, descent: 0)
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(
            line(text, fontSize: fontSize, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), bold: bold),
            &ascent, &descent, &leading
        )
        return Metrics(
            size: CGSize(width: CGFloat(width), height: ascent + descent),
            ascent: ascent,
            descent: descent
        )
    }

    static func line(_ text: String, fontSize: CGFloat, color: CGColor, bold: Bool = false) -> CTLine {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font(ofSize: fontSize, bold: bold),
            kCTForegroundColorAttributeName: color,
        ]
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attributes as CFDictionary
        )!
        return CTLineCreateWithAttributedString(attributed)
    }
}

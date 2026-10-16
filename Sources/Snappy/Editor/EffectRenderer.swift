import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import os

/// Renders blur / pixelate regions of the base image via CoreImage (M6).
/// Fully offline — CIFilters run locally. CI shares the model's bottom-left
/// coordinate convention, so annotation rects map to CI extents without
/// flipping. Effect strength is derived from the base image size AND the
/// region size (see `blurRadius`), without extra model state.
enum EffectRenderer {
    private static let context = CIContext()

    /// The process-wide cache used by the canvas and export paths.
    static let sharedCache = EffectCache()

    /// Drops every cached result (image changed, editor closed).
    static func clearCache() {
        sharedCache.clear()
    }

    /// Gaussian blur radius (image px) for a region. The image-size term alone
    /// was too weak wherever text is large relative to the capture: Vision OCR
    /// read "Token 4821-7730" back out of a blurred 13 pt line in a 700×90 px
    /// capture (radius 4 px), and read 24 pt text back verbatim from both blur
    /// and pixelate. The region term ties strength to what is being hidden —
    /// a region drawn around one line of text is about one line tall. The cap
    /// limits only that region term (a large region shouldn't dissolve into a
    /// flat colour); the image term can exceed it. Measured: no readable OCR
    /// result for 11–48 pt text at 2× and 13 pt at 1× (design review C1;
    /// `EffectRedactionTests` re-runs the leaking cases). Obscuring, not a
    /// redaction guarantee — the output still derives from the source pixels.
    static func blurRadius(imageSize: CGSize, region: CGSize) -> CGFloat {
        let side = min(region.width, region.height)
        return max(4, min(imageSize.width, imageSize.height) / 50, min(0.3 * side, 40))
    }

    /// Pixelate block size (image px) — same reasoning as `blurRadius`; half the
    /// region's short side puts at most ~2 blocks across one line of text.
    static func pixelScale(imageSize: CGSize, region: CGSize) -> CGFloat {
        let side = min(region.width, region.height)
        return max(6, min(imageSize.width, imageSize.height) / 40, min(0.5 * side, 64))
    }

    /// The effect applied to `rect` of the base image, returned as a CGImage
    /// covering exactly the integral clamped rect (also returned, bottom-left
    /// coordinates). Nil when the region is degenerate or CoreImage produced
    /// nothing (the caller then covers the region opaquely).
    static func render(
        _ kind: EffectKind, base: CGImage, rect: CGRect, cache: EffectCache = sharedCache
    ) -> (image: CGImage, rect: CGRect)? {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let target = rect.integral.intersection(bounds)
        guard target.width >= 1, target.height >= 1 else { return nil }

        let key = EffectCache.Key(base: base, kind: kind, region: target)
        if let hit = cache.lookup(key, base: base) { return hit }

        // Clamp extends edge pixels to infinity so blur doesn't fade to
        // transparent at the image border; cropping keeps rendering cheap.
        let input = CIImage(cgImage: base).clampedToExtent()
        let imageSize = bounds.size
        let output: CIImage?
        switch kind {
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input
            filter.radius = Float(blurRadius(imageSize: imageSize, region: target.size))
            output = filter.outputImage
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = input
            filter.scale = Float(pixelScale(imageSize: imageSize, region: target.size))
            filter.center = CGPoint(x: target.minX, y: target.minY)
            output = filter.outputImage
        }
        // Never fall back to the unfiltered input: nil makes the caller cover the region.
        guard let output, let rendered = context.createCGImage(output, from: target) else { return nil }
        cache.store(rendered, rect: target, base: base, for: key)
        return (rendered, target)
    }
}

/// Bounded LRU cache of rendered blur / pixelate regions.
///
/// The canvas redraws on every drag event, and each effect annotation used to
/// re-run its CIFilter and read the pixels back from the GPU every time — even
/// when only an unrelated annotation moved. A result depends only on (base
/// image, kind, integral region), so it is kept briefly.
///
/// Keyed by the base image's identity. Each entry also holds the base image
/// strongly: that is what makes an `ObjectIdentifier` safe (an address can't be
/// recycled by a different image while its entry is alive) — and why the cache
/// must be cleared when the document image changes or the editor closes, or it
/// would pin a screenshot. A lock rather than main-actor isolation because
/// `EffectRenderer.render` is nonisolated and also runs from synchronous tests.
final class EffectCache: @unchecked Sendable {
    struct Key: Hashable {
        let base: ObjectIdentifier
        let isBlur: Bool
        let x: Int, y: Int, width: Int, height: Int

        init(base: CGImage, kind: EffectKind, region: CGRect) {
            self.base = ObjectIdentifier(base)
            isBlur = kind == .blur
            x = Int(region.minX); y = Int(region.minY)
            width = Int(region.width); height = Int(region.height)
        }
    }

    private struct Entry {
        let base: CGImage
        let image: CGImage
        let rect: CGRect
        var cost: Int { image.width * image.height * 4 }
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var order: [Key] = [] // least recently used first
        var totalCost = 0
    }

    /// Entry-count and memory bounds: a drag creates a new region per event.
    let maxEntries: Int
    let maxBytes: Int
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(maxEntries: Int = 16, maxBytes: Int = 192 * 1024 * 1024) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    var count: Int { state.withLockUnchecked { $0.entries.count } }

    func clear() {
        state.withLockUnchecked { $0 = State() }
    }

    func lookup(_ key: Key, base: CGImage) -> (image: CGImage, rect: CGRect)? {
        state.withLockUnchecked { state in
            guard let entry = state.entries[key], entry.base === base else { return nil }
            if let index = state.order.firstIndex(of: key) {
                state.order.remove(at: index)
                state.order.append(key)
            }
            return (entry.image, entry.rect)
        }
    }

    func store(_ image: CGImage, rect: CGRect, base: CGImage, for key: Key) {
        let entry = Entry(base: base, image: image, rect: rect)
        guard entry.cost <= maxBytes else { return }
        state.withLockUnchecked { state in
            if let old = state.entries[key] {
                state.totalCost -= old.cost
                state.order.removeAll { $0 == key }
            }
            state.entries[key] = entry
            state.order.append(key)
            state.totalCost += entry.cost
            while state.order.count > maxEntries || state.totalCost > maxBytes,
                  let oldest = state.order.first {
                state.order.removeFirst()
                if let evicted = state.entries.removeValue(forKey: oldest) {
                    state.totalCost -= evicted.cost
                }
            }
        }
    }
}

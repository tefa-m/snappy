import CoreGraphics
import Foundation

/// Adaptive background for the auto-expanding canvas (Post-MVP M-F): fills the
/// area outside the screenshot with a **single, clean, uniform color** derived
/// from the screenshot's perimeter, so the expanded canvas blends in.
///
/// The earlier design extended each edge pixel outward at its own coordinate,
/// which smeared every color variation, wood grain, and dark divider into long
/// horizontal/vertical bands. Instead we now pick ONE background color that
/// visually matches the area surrounding the content and fill the whole
/// expansion with it — no stretching, mirroring, blurring, or repeating.
///
/// Built once per base image (the color is detected and cached; the document
/// invalidates it on crop). Detection is a pure function of the sampled
/// perimeter:
///
/// - Slide small windows along a shallow band inside each edge; each window
///   contributes its mean color, weighted by how **uniform** it is (textures,
///   text, borders, and dividers are high-variance and heavily down-weighted),
///   by **size**, and by an extra **corner** boost (corners are most likely to
///   be background).
/// - Cluster the window means (coarse RGB quantization) so colors that recur
///   across multiple edges and large continuous regions accumulate weight; take
///   the heaviest cluster's weighted-mean, then refine with one mean-shift step
///   (merge nearby windows) so a color straddling a bin boundary isn't split.
/// - Fallbacks when nothing reads as clean background: the single most-uniform
///   window, then the perimeter mean, then a neutral.
///
/// Consumers (canvas draw, export flatten) fill the expansion directly with
/// `fillColor.cgColor` — the fill is uniform, so no intermediate bitmap is built.
struct CanvasBackground: Sendable {

    /// Straight RGBA components in 0…1 (backgrounds are always opaque).
    struct RGBA: Equatable, Sendable {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
        var a: CGFloat = 1

        static func mix(_ x: RGBA, _ y: RGBA, t: CGFloat) -> RGBA {
            let s = 1 - t
            return RGBA(r: x.r * s + y.r * t, g: x.g * s + y.g * t, b: x.b * s + y.b * t,
                        a: x.a * s + y.a * t)
        }

        /// The colour as an sRGB-tagged `CGColor`, for direct context fills.
        var cgColor: CGColor {
            CGColor(srgbRed: r, green: g, blue: b, alpha: a)
        }

        /// Squared Euclidean distance in RGB (alpha ignored — always opaque).
        func distanceSquared(to other: RGBA) -> CGFloat {
            let dr = r - other.r, dg = g - other.g, db = b - other.b
            return dr * dr + dg * dg + db * db
        }
    }

    /// Target depth (px) of the perimeter band sampled per edge (clamped to a
    /// fraction of the image so tiny captures still sample something).
    private static let bandDepth = 8
    /// Target number of windows per edge (each window = one color candidate).
    private static let windowsPerEdge = 24
    /// Variance→weight falloff: `1 / (1 + detailPenalty · variance)`. Larger ⇒
    /// high-detail (textured / text / bordered) windows are punished harder.
    private static let detailPenalty: CGFloat = 250
    /// Extra weight for windows near an edge's ends (the four corners).
    private static let cornerBoost: CGFloat = 2
    /// Fraction of an edge, at each end, treated as "corner".
    private static let cornerFraction: CGFloat = 0.15
    /// Quantization step per channel for clustering window means.
    private static let clusterStep: CGFloat = 1.0 / 12.0
    /// Radius (RGB distance) for the mean-shift merge around the top cluster.
    private static let mergeDistance: CGFloat = 0.12

    let imageBounds: CGRect
    /// The single detected background color used for the whole expansion.
    let fillColor: RGBA

    /// Test-facing memberwise init (fill color supplied directly).
    init(imageBounds: CGRect, fill: RGBA) {
        self.imageBounds = imageBounds
        self.fillColor = fill
    }

    /// Detects one clean uniform background color from `image`'s perimeter.
    ///
    /// Only the four perimeter bands are rasterised (cropped out of the image),
    /// never the whole image: detection reads nothing else, and a full-image
    /// bitmap of a 5K capture is ~60 MB plus a colour-converting blit.
    init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let vBand = max(1, min(Self.bandDepth, height / 4))   // depth for top/bottom
        let hBand = max(1, min(Self.bandDepth, width / 4))    // depth for left/right
        // Rects are in the image's own space: origin top-left, y down — the same
        // "buffer" orientation `pixel(x:y:)` below addresses.
        guard
            let top = Self.rasterize(image, CGRect(x: 0, y: 0, width: width, height: vBand), space),
            let bottom = Self.rasterize(image, CGRect(x: 0, y: height - vBand, width: width, height: vBand), space),
            let left = Self.rasterize(image, CGRect(x: 0, y: 0, width: hBand, height: height), space),
            let right = Self.rasterize(image, CGRect(x: width - hBand, y: 0, width: hBand, height: height), space)
        else { return nil }

        /// Buffer-space pixel, served from whichever band holds it. Windows
        /// only ever ask for coordinates inside one of the four bands.
        func pixel(x: Int, y: Int) -> RGBA {
            if y < vBand { return top.pixel(x: x, y: y) }
            if y >= height - vBand { return bottom.pixel(x: x, y: y - (height - vBand)) }
            if x < hBand { return left.pixel(x: x, y: y) }
            return right.pixel(x: x - (width - hBand), y: y)
        }

        // Collect one candidate per window along all four edges. Orientation is
        // irrelevant to detection (we want a single color), so buffer-space
        // coordinates are fine here.
        var candidates: [Candidate] = []
        // Top band (buffer rows 0…vBand-1) and bottom band, varying x.
        Self.scan(along: width, windows: Self.windowsPerEdge, into: &candidates) { x0, x1, out in
            out(Self.window(x0: x0, x1: x1, y0: 0, y1: vBand, pixel: pixel))
            out(Self.window(x0: x0, x1: x1, y0: height - vBand, y1: height, pixel: pixel))
        }
        // Left band (buffer cols 0…hBand-1) and right band, varying y.
        Self.scan(along: height, windows: Self.windowsPerEdge, into: &candidates) { y0, y1, out in
            out(Self.window(x0: 0, x1: hBand, y0: y0, y1: y1, pixel: pixel))
            out(Self.window(x0: width - hBand, x1: width, y0: y0, y1: y1, pixel: pixel))
        }

        self.imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        self.fillColor = Self.detectFill(from: candidates)
    }

    // MARK: - Perimeter sampling

    /// A small RGBA8 (sRGB, premultiplied) raster of one perimeter band.
    private struct Band {
        let width: Int
        let data: [UInt8]

        func pixel(x: Int, y: Int) -> RGBA {
            let i = (y * width + x) * 4
            return RGBA(
                r: CGFloat(data[i]) / 255, g: CGFloat(data[i + 1]) / 255,
                b: CGFloat(data[i + 2]) / 255, a: CGFloat(data[i + 3]) / 255
            )
        }
    }

    /// Rasterises `rect` (image space, top-left origin) of `image` into a
    /// tightly packed sRGB bitmap.
    private static func rasterize(_ image: CGImage, _ rect: CGRect, _ space: CGColorSpace) -> Band? {
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0, let piece = image.cropping(to: rect),
              piece.width == w, piece.height == h else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Band(width: w, data: data) : nil
    }

    // MARK: - Detection

    /// One sampled window: its mean color, per-pixel color variance, pixel
    /// count, and normalized position (0…1) along its edge.
    private struct Candidate {
        var mean: RGBA
        var variance: CGFloat
        var count: CGFloat
        var position: CGFloat
    }

    /// Splits an edge of length `along` into `windows` spans and, for each,
    /// hands the pixel range plus a normalized center position to `body`, which
    /// emits zero or more `Candidate`s via its `out` closure.
    private static func scan(
        along: Int, windows: Int, into candidates: inout [Candidate],
        body: (_ start: Int, _ end: Int, _ out: (Candidate) -> Void) -> Void
    ) {
        guard along > 0 else { return }
        let n = max(1, min(windows, along))
        for i in 0..<n {
            let start = i * along / n
            let end = max(start + 1, (i + 1) * along / n)
            let center = (CGFloat(start) + CGFloat(end)) / 2 / CGFloat(along)
            body(start, end) { c in
                var c = c
                c.position = center
                candidates.append(c)
            }
        }
    }

    /// Mean + per-pixel color variance over a pixel rectangle.
    private static func window(
        x0: Int, x1: Int, y0: Int, y1: Int, pixel: (Int, Int) -> RGBA
    ) -> Candidate {
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0
        var qr: CGFloat = 0, qg: CGFloat = 0, qb: CGFloat = 0
        var count: CGFloat = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = pixel(x, y)
                sr += p.r; sg += p.g; sb += p.b
                qr += p.r * p.r; qg += p.g * p.g; qb += p.b * p.b
                count += 1
            }
        }
        guard count > 0 else {
            return Candidate(mean: RGBA(r: 0, g: 0, b: 0), variance: 0, count: 0, position: 0)
        }
        let mr = sr / count, mg = sg / count, mb = sb / count
        // Var(X) = E[X²] − E[X]²; average the three channels.
        let vr = max(0, qr / count - mr * mr)
        let vg = max(0, qg / count - mg * mg)
        let vb = max(0, qb / count - mb * mb)
        return Candidate(
            mean: RGBA(r: mr, g: mg, b: mb), variance: (vr + vg + vb) / 3,
            count: count, position: 0
        )
    }

    /// The combined weight of a candidate: uniform · size · corner boost.
    private static func weight(_ c: Candidate) -> CGFloat {
        guard c.count > 0 else { return 0 }
        let uniform = 1 / (1 + detailPenalty * c.variance)
        let corner = (c.position < cornerFraction || c.position > 1 - cornerFraction)
            ? cornerBoost : 1
        return uniform * c.count * corner
    }

    /// Picks the single background color: heaviest quantized cluster refined by
    /// one mean-shift step, with graceful fallbacks.
    private static func detectFill(from candidates: [Candidate]) -> RGBA {
        let neutral = RGBA(r: 1, g: 1, b: 1)
        let usable = candidates.filter { $0.count > 0 }
        guard !usable.isEmpty else { return neutral }

        // Accumulate weight into coarse RGB bins.
        struct Bin { var weight: CGFloat = 0; var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0 }
        var bins: [Int: Bin] = [:]
        func key(_ c: RGBA) -> Int {
            let qr = Int((c.r / clusterStep).rounded())
            let qg = Int((c.g / clusterStep).rounded())
            let qb = Int((c.b / clusterStep).rounded())
            return (qr * 97 + qg) * 97 + qb
        }
        var totalWeight: CGFloat = 0
        for c in usable {
            let w = weight(c)
            guard w > 0 else { continue }
            totalWeight += w
            var bin = bins[key(c.mean), default: Bin()]
            bin.weight += w
            bin.r += c.mean.r * w; bin.g += c.mean.g * w; bin.b += c.mean.b * w
            bins[key(c.mean)] = bin
        }

        // Fallback: no window read as clean background → most-uniform window,
        // else the plain perimeter mean.
        guard totalWeight > 0, let top = bins.values.max(by: { $0.weight < $1.weight }) else {
            if let calmest = usable.min(by: { $0.variance < $1.variance }) { return calmest.mean }
            return perimeterMean(usable) ?? neutral
        }

        // Cluster center = the heaviest bin's weighted mean.
        let center = RGBA(r: top.r / top.weight, g: top.g / top.weight, b: top.b / top.weight)

        // One mean-shift step: average every window within `mergeDistance` of
        // the center, so a color split across two adjacent bins reunites.
        let mergeSq = mergeDistance * mergeDistance
        var wr: CGFloat = 0, wg: CGFloat = 0, wb: CGFloat = 0, wsum: CGFloat = 0
        for c in usable {
            guard c.mean.distanceSquared(to: center) <= mergeSq else { continue }
            let w = weight(c)
            wr += c.mean.r * w; wg += c.mean.g * w; wb += c.mean.b * w; wsum += w
        }
        guard wsum > 0 else { return center }
        return RGBA(r: wr / wsum, g: wg / wsum, b: wb / wsum)
    }

    private static func perimeterMean(_ candidates: [Candidate]) -> RGBA? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, count: CGFloat = 0
        for c in candidates {
            r += c.mean.r * c.count; g += c.mean.g * c.count; b += c.mean.b * c.count
            count += c.count
        }
        guard count > 0 else { return nil }
        return RGBA(r: r / count, g: g / count, b: b / count)
    }
}

// Regenerates all Snappy icon artifacts from assets/snappy-dynamic-s.png
// (2048×2048, black S on white). Run via scripts/generate-icons.sh — that
// wrapper also converts the iconsets to .icns. Re-run only when the source
// image changes; the generated .icns + menu bar PNGs are committed.
//
// Outputs (in assets/generated/):
//   AppIcon.iconset/        dark squircle, white S  (shipped default)
//   AppIcon-light.iconset/  white squircle, black S (kept for future)
//   MenuBarIcon.png (18×18) + MenuBarIcon@2x.png (36×36) — black+alpha
//   template glyph for the status item

import AppKit
import UniformTypeIdentifiers

// MARK: - Paths (relative to the script's location → repo root)

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = repoRoot.appending(path: "assets/snappy-dynamic-s.png")
let outDir = repoRoot.appending(path: "assets/generated")

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ERROR: " + message + "\n").utf8))
    exit(1)
}

// MARK: - Load the source and extract the S as an alpha mask
// The source is a black glyph on white: alpha = (1 − luminance) × sourceAlpha,
// so dark strokes become opaque and the white background becomes transparent.

guard let sourceData = try? Data(contentsOf: sourceURL),
      let provider = CGDataProvider(data: sourceData as CFData),
      let source = CGImage(
          pngDataProviderSource: provider, decode: nil, shouldInterpolate: true,
          intent: .defaultIntent)
else { die("cannot load \(sourceURL.path)") }

let srcW = source.width
let srcH = source.height
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

guard let rgbaContext = CGContext(
    data: nil, width: srcW, height: srcH, bitsPerComponent: 8, bytesPerRow: 0,
    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { die("cannot create RGBA context") }
rgbaContext.draw(source, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))
guard let rgba = rgbaContext.data else { die("no bitmap data") }

var alphaPixels = [UInt8](repeating: 0, count: srcW * srcH)
for i in 0..<(srcW * srcH) {
    let p = rgba.advanced(by: i * 4).assumingMemoryBound(to: UInt8.self)
    let a = CGFloat(p[3]) / 255
    guard a > 0 else { continue }
    // Un-premultiply before computing luminance.
    let r = CGFloat(p[0]) / 255 / a
    let g = CGFloat(p[1]) / 255 / a
    let b = CGFloat(p[2]) / 255 / a
    let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    alphaPixels[i] = UInt8(max(0, min(255, (1 - luminance) * a * 255)))
}

/// Alpha-only CGImage usable both as a clip mask and for direct drawing.
func makeAlphaImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage {
    // The context owns its backing store (`data: nil`) and the mask bytes are
    // copied into it — a context built over a Swift array's pointer would
    // outlive the borrow that `withUnsafeMutableBytes` guarantees.
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
        let storage = ctx.data
    else { die("cannot build alpha mask") }
    // The context's rows may be padded; copy row by row.
    let stride = ctx.bytesPerRow
    pixels.withUnsafeBytes { source in
        for row in 0..<height {
            memcpy(storage + row * stride, source.baseAddress! + row * width, width)
        }
    }
    guard let image = ctx.makeImage() else { die("cannot build alpha mask") }
    return image
}

// Tight-crop to the glyph's bounding box so layout math uses the S alone.
var minX = srcW, minY = srcH, maxX = -1, maxY = -1
for y in 0..<srcH {
    for x in 0..<srcW where alphaPixels[y * srcW + x] > 8 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else { die("source image is blank") }
let cropW = maxX - minX + 1
let cropH = maxY - minY + 1
var cropped = [UInt8](repeating: 0, count: cropW * cropH)
for y in 0..<cropH {
    for x in 0..<cropW {
        cropped[y * cropW + x] = alphaPixels[(minY + y) * srcW + (minX + x)]
    }
}
let glyphMask = makeAlphaImage(cropped, width: cropW, height: cropH)
let glyphAspect = CGFloat(cropH) / CGFloat(cropW)

// MARK: - Rendering helpers

func writePNG(_ image: CGImage, to url: URL) {
    guard
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { die("cannot create \(url.lastPathComponent)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { die("cannot write \(url.lastPathComponent)") }
}

func makeContext(_ pixels: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { die("cannot create \(pixels)px context") }
    ctx.interpolationQuality = .high
    return ctx
}

/// Centered rect of `width` keeping the glyph's aspect ratio.
func glyphRect(width: CGFloat, centeredIn canvas: CGFloat) -> CGRect {
    let height = width * glyphAspect
    return CGRect(
        x: (canvas - width) / 2, y: (canvas - height) / 2, width: width, height: height)
}

// Apple icon grid: 832×832 rounded rect on a 1024 canvas, radius ≈ 186.
// All sizes render from these 1024-reference proportions.
func drawAppIcon(pixels: Int, dark: Bool) -> CGImage {
    let ctx = makeContext(pixels)
    let s = CGFloat(pixels) / 1024
    let shape = CGRect(x: 96 * s, y: 96 * s, width: 832 * s, height: 832 * s)
    let path = CGPath(
        roundedRect: shape, cornerWidth: 186 * s, cornerHeight: 186 * s, transform: nil)

    ctx.addPath(path)
    ctx.clip()
    if dark {
        // Near-black #1C1C1E base with a subtle vertical gradient for depth.
        let gradient = CGGradient(
            colorsSpace: srgb,
            colors: [
                CGColor(srgbRed: 0.137, green: 0.137, blue: 0.145, alpha: 1),  // top
                CGColor(srgbRed: 0.086, green: 0.086, blue: 0.094, alpha: 1),  // bottom
            ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: shape.maxY),
            end: CGPoint(x: 0, y: shape.minY), options: [])
    } else {
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(shape)
    }

    let sRect = glyphRect(width: shape.width * 0.62, centeredIn: CGFloat(pixels))
    ctx.clip(to: sRect, mask: glyphMask)
    ctx.setFillColor(
        dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            : CGColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1))
    ctx.fill(sRect)

    guard let image = ctx.makeImage() else { die("cannot render \(pixels)px icon") }
    return image
}

// Menu bar template glyph: black+alpha S, ~10% padding, square canvas.
func drawMenuBarIcon(pixels: Int) -> CGImage {
    let ctx = makeContext(pixels)
    let inset = CGFloat(pixels) * 0.10
    let available = CGFloat(pixels) - inset * 2
    // Fit by the larger glyph dimension so nothing crosses the padding.
    let width = glyphAspect > 1 ? available / glyphAspect : available
    let rect = glyphRect(width: width, centeredIn: CGFloat(pixels))
    ctx.clip(to: rect, mask: glyphMask)
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(rect)
    guard let image = ctx.makeImage() else { die("cannot render menu bar icon") }
    return image
}

// MARK: - Emit everything

let fm = FileManager.default
for variant in ["AppIcon.iconset", "AppIcon-light.iconset"] {
    let dir = outDir.appending(path: variant)
    try? fm.removeItem(at: dir)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
}

// Standard macOS iconset: 16/32/128/256/512 pt, each 1x + 2x (covers 64/1024 px).
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    writePNG(
        drawAppIcon(pixels: pixels, dark: true),
        to: outDir.appending(path: "AppIcon.iconset/\(name)"))
    writePNG(
        drawAppIcon(pixels: pixels, dark: false),
        to: outDir.appending(path: "AppIcon-light.iconset/\(name)"))
}

writePNG(drawMenuBarIcon(pixels: 18), to: outDir.appending(path: "MenuBarIcon.png"))
writePNG(drawMenuBarIcon(pixels: 36), to: outDir.appending(path: "MenuBarIcon@2x.png"))

print("Generated iconsets + menu bar PNGs in \(outDir.path)")

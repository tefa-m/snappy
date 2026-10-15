import AppKit
import Foundation
import Testing
@testable import Snappy

@MainActor
@Suite("RecordingCompositor")
struct RecordingCompositorTests {
    /// A white frame buffer laid out like the pipeline's (32-bit BGRA,
    /// premultiplied first, little-endian), with pixel reads in CG coordinates.
    private final class Frame {
        let width: Int, height: Int
        private(set) var bytes: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            bytes = [UInt8](repeating: 255, count: width * height * 4)
        }

        /// Runs `body` on a context over the buffer; the context never outlives it.
        func draw(_ body: (CGContext) -> Void) {
            let width = self.width, height = self.height
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                )!
                body(context)
            }
        }

        /// (r, g, b) at CG pixel (x, y), origin bottom-left. Row 0 of the
        /// buffer is the top row.
        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let index = ((height - 1 - y) * width + x) * 4
            return (Int(bytes[index + 2]), Int(bytes[index + 1]), Int(bytes[index]))
        }

        func isWhite(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return p.r > 250 && p.g > 250 && p.b > 250
        }
    }

    private static func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        p.r < 40 && p.b > 220 // #007AFF
    }

    /// A scene with strokes drawn through the model, as the panel does.
    private func scene(
        target: RecordingTarget, fadeDelay: TimeInterval = 3,
        _ strokes: [(tool: InkTool, points: [CGPoint], style: InkStyle, capturing: Bool)]
    ) -> InkScene {
        var ink = LiveInk(fadeDelay: fadeDelay)
        ink.setTarget(target)
        for stroke in strokes {
            ink.beginStroke(tool: stroke.tool, at: stroke.points[0], style: stroke.style, isCapturing: stroke.capturing)
            for point in stroke.points.dropFirst() { ink.extendStroke(to: point) }
            ink.endStroke(at: 0)
        }
        return ink.scene
    }

    private static let blue = InkStyle(color: .blue, width: .thin, fading: false)

    // MARK: - Mapping

    @Test func targetPointsLandOnOutputPixelsAtTheCaptureScale() {
        let target = CGRect(x: 100, y: 100, width: 100, height: 50)
        let compositor = RecordingCompositor()
        compositor.update(scene(target: .area(globalRect: target, displayID: 1), [
            (.box, [CGPoint(x: 120, y: 110), CGPoint(x: 180, y: 140)], Self.blue, false),
        ]))
        let frame = Frame(width: 200, height: 100) // 2× pixels
        frame.draw { compositor.draw(in: $0, outputRect: CGRect(x: 0, y: 0, width: 200, height: 100), targetFrame: target, hostTime: 0) }

        // Left edge at global x 120 → pixel 40; middle height global 125 → pixel 50.
        #expect(Self.isBlue(frame.pixel(40, 50)))
        // Thin = 2 pt → 4 px: the edge reaches 1 px outside but not 3.
        #expect(Self.isBlue(frame.pixel(39, 50)))
        #expect(frame.isWhite(36, 50))
        // Inside the box stays untouched (no fill), and so does the outside.
        #expect(frame.isWhite(100, 50))
        #expect(frame.isWhite(10, 90))
    }

    @Test func inkIsClippedToTheLetterboxedOutputRect() {
        // A window target letterboxed into the middle of a wider buffer.
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let compositor = RecordingCompositor()
        compositor.update(scene(target: .area(globalRect: target, displayID: 1), [
            (.pen, [CGPoint(x: -60, y: 50), CGPoint(x: 20, y: 50), CGPoint(x: 160, y: 50)], Self.blue, false),
        ]))
        let frame = Frame(width: 200, height: 100)
        let output = CGRect(x: 50, y: 0, width: 100, height: 100)
        frame.draw { compositor.draw(in: $0, outputRect: output, targetFrame: target, hostTime: 0) }

        #expect(Self.isBlue(frame.pixel(100, 50)))
        #expect(frame.isWhite(25, 50))  // left bar
        #expect(frame.isWhite(175, 50)) // right bar
    }

    @Test func aWindowStrokeFollowsEachFramesTargetFrame() {
        let window = RecordingTarget.window(windowID: 9, frame: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 1)
        let compositor = RecordingCompositor()
        compositor.update(scene(target: window, [
            (.box, [CGPoint(x: 10, y: 90), CGPoint(x: 40, y: 60)], Self.blue, true),
        ]))
        // The window moved 500 pt right since; the box moves with it, so it
        // lands on the same output pixels.
        let moved = CGRect(x: 500, y: 0, width: 100, height: 100)
        let frame = Frame(width: 100, height: 100)
        frame.draw { compositor.draw(in: $0, outputRect: CGRect(x: 0, y: 0, width: 100, height: 100), targetFrame: moved, hostTime: 0) }
        #expect(Self.isBlue(frame.pixel(10, 75)))
        #expect(frame.isWhite(25, 75))
    }

    // MARK: - Opacity

    @Test func fadingInkFadesAtTheFramesHostTime() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let compositor = RecordingCompositor()
        let fading = InkStyle(color: .blue, width: .thick, fading: true)
        compositor.update(scene(target: .area(globalRect: target, displayID: 1), fadeDelay: 1, [
            (.pen, [CGPoint(x: 10, y: 50), CGPoint(x: 50, y: 50), CGPoint(x: 90, y: 50)], fading, true),
        ]))
        func red(at time: TimeInterval) -> Int {
            let frame = Frame(width: 100, height: 100)
            frame.draw { compositor.draw(in: $0, outputRect: target, targetFrame: target, hostTime: time) }
            return frame.pixel(50, 50).r
        }
        #expect(red(at: 0.5) < 10)                                   // fully visible
        #expect(abs(red(at: 1 + LiveInk.fadeDuration / 2) - 128) < 8) // half faded over white
        #expect(red(at: 5) == 255)                                   // gone
    }

    @Test func theHighlighterIsFortyPercent() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let compositor = RecordingCompositor()
        compositor.update(scene(target: .area(globalRect: target, displayID: 1), [
            (.highlighter, [CGPoint(x: 10, y: 50), CGPoint(x: 50, y: 50), CGPoint(x: 90, y: 50)], Self.blue, false),
        ]))
        let frame = Frame(width: 100, height: 100)
        frame.draw { compositor.draw(in: $0, outputRect: target, targetFrame: target, hostTime: 0) }
        // Blue (r 0) at 40 % over white: r ≈ 0.6 × 255.
        #expect(abs(frame.pixel(50, 50).r - 153) < 6)
        // Always thick (8 pt), whatever the style's width: 3 pt off-centre is covered.
        #expect(abs(frame.pixel(50, 53).r - 153) < 6)
    }

    @Test func aFadingArrowDoesNotDoubleUpWhereFillAndRoundingOverlap() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let compositor = RecordingCompositor()
        let fading = InkStyle(color: .blue, width: .thick, fading: true)
        compositor.update(scene(target: .area(globalRect: target, displayID: 1), fadeDelay: 1, [
            (.arrow, [CGPoint(x: 5, y: 50), CGPoint(x: 95, y: 50)], fading, true),
        ]))
        let frame = Frame(width: 100, height: 100)
        frame.draw {
            compositor.draw(in: $0, outputRect: target, targetFrame: target, hostTime: 1 + LiveInk.fadeDuration / 2)
        }
        // Half opacity everywhere: no pixel of the column darker than ~50 %
        // (a double-drawn overlap would reach 75 %, r ≈ 64).
        let column = (0..<100).map { frame.pixel(50, $0).r }
        #expect(column.min()! > 115)
        #expect(column.contains { $0 < 140 })
    }

    // MARK: - Magic Pen

    /// One Magic Pen stroke across the middle of `target`, as the panel draws it.
    private func magicPenScene(target: CGRect, width: InkWidth = .medium, fadeDelay: TimeInterval = 3) -> InkScene {
        var ink = LiveInk(fadeDelay: fadeDelay)
        ink.setTarget(.area(globalRect: target, displayID: 1))
        let style = InkStyle(color: .blue, width: .thin, fading: false, magicPenWidth: width)
        ink.beginMagicPenStroke(at: CGPoint(x: target.minX + 10, y: target.midY), style: style)
        ink.extendStroke(to: CGPoint(x: target.midX, y: target.midY))
        ink.extendStroke(to: CGPoint(x: target.maxX - 10, y: target.midY))
        ink.endStroke(at: 0)
        return ink.scene
    }

    @Test func theMagicPenIsVividSlightlyTransparentWithASoftDarkHalo() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let compositor = RecordingCompositor()
        compositor.update(magicPenScene(target: target))
        let frame = Frame(width: 100, height: 100)
        frame.draw { compositor.draw(in: $0, outputRect: target, targetFrame: target, hostTime: 0) }
        // Centre: the Magic Pen colour (#FF451A) at 85 % over white —
        // red stays full, green/blue lifted by the 15 % white.
        let centre = frame.pixel(50, 50)
        let ink = MagicPenLook.color
        func over(_ c: CGFloat) -> Int { Int(((c * 0.85 + 0.15) * 255).rounded()) }
        #expect(abs(centre.r - over(ink.red)) < 6)
        #expect(abs(centre.g - over(ink.green)) < 6)
        #expect(abs(centre.b - over(ink.blue)) < 6)
        // Medium = 6 pt: 2 pt off-centre is still the stroke …
        #expect(abs(frame.pixel(50, 52).g - over(ink.green)) < 6)
        // … and just outside it (3 … 5 pt) the halo darkens white, never the colour.
        let halo = frame.pixel(50, 54)
        #expect(halo.r < 250 && abs(halo.r - halo.g) < 6 && abs(halo.g - halo.b) < 6)
        // Far away: untouched.
        #expect(frame.isWhite(50, 60))
    }

    @Test func aFadingMagicPenStrokeDoesNotDoubleUpWhereHaloAndStrokeOverlap() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let compositor = RecordingCompositor()
        compositor.update(magicPenScene(target: target, width: .thick, fadeDelay: 1))
        let full = Frame(width: 100, height: 100)
        full.draw { compositor.draw(in: $0, outputRect: target, targetFrame: target, hostTime: 0) }
        let half = Frame(width: 100, height: 100)
        half.draw {
            compositor.draw(in: $0, outputRect: target, targetFrame: target, hostTime: 1 + LiveInk.fadeDuration / 2)
        }
        // The halo under the stroke never shows through it: the centre keeps
        // the colour's hue, half as strong at half the fade.
        let green = (full: full.pixel(50, 50).g, half: half.pixel(50, 50).g)
        #expect(abs((255 - green.half) * 2 - (255 - green.full)) < 8)
        #expect(half.pixel(50, 50).r > 245)
    }

    @Test func theOnScreenViewDrawsTheSameMagicPenPixelsAsTheVideo() {
        let target = CGRect(x: 300, y: 200, width: 80, height: 60)
        let inkScene = magicPenScene(target: target, width: .thick)
        let compositor = RecordingCompositor()
        compositor.update(inkScene)
        let video = Frame(width: 160, height: 120)
        video.draw {
            compositor.draw(in: $0, outputRect: CGRect(x: 0, y: 0, width: 160, height: 120), targetFrame: target, hostTime: 0)
        }
        let view = LiveInkView(frame: CGRect(origin: .zero, size: target.size))
        view.clock = { 0 }
        view.targetFrame = target
        view.scene = inkScene
        let screen = Frame(width: 160, height: 120)
        screen.draw { context in
            context.scaleBy(x: 2, y: 2)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            view.draw(view.bounds)
            NSGraphicsContext.current = previous
        }
        #expect(video.bytes.contains { $0 != 255 })
        let largest = zip(video.bytes, screen.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(largest <= 2)
    }

    // MARK: - Snapshot swap

    @Test func drawsOnlyWhatWasPublished() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let compositor = RecordingCompositor()
        func drawsAnything() -> Bool {
            let frame = Frame(width: 100, height: 100)
            frame.draw { compositor.draw(in: $0, outputRect: target, targetFrame: target, hostTime: 0) }
            return frame.bytes.contains { $0 != 255 }
        }
        #expect(!drawsAnything())
        compositor.update(scene(target: .area(globalRect: target, displayID: 1), [
            (.oval, [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 90)], Self.blue, false),
        ]))
        #expect(drawsAnything())
        compositor.update(.empty)
        #expect(!drawsAnything())
    }

    @Test func drawingOnAnotherThreadWhileTheMainActorPublishes() async {
        let target = CGRect(x: 0, y: 0, width: 64, height: 64)
        let compositor = RecordingCompositor()
        let decorator: any FrameDecorating = compositor
        let drawing = Task.detached {
            let frame = Frame(width: 64, height: 64)
            for _ in 0..<200 {
                frame.draw { decorator.draw(in: $0, outputRect: target, targetFrame: target, hostTime: 0) }
            }
        }
        for index in 0..<200 {
            let offset = CGFloat(index % 50)
            compositor.update(scene(target: .area(globalRect: target, displayID: 1), [
                (.box, [CGPoint(x: offset, y: offset), CGPoint(x: offset + 10, y: offset + 10)], Self.blue, false),
            ]))
        }
        await drawing.value
        #expect(compositor.currentScene.strokes.count == 1)
    }

    // MARK: - Canvas ≡ export

    @Test func theOnScreenViewDrawsTheSamePixelsAsTheVideo() {
        let target = CGRect(x: 300, y: 200, width: 80, height: 60)
        let inkScene = scene(target: .area(globalRect: target, displayID: 1), [
            (.arrow, [CGPoint(x: 310, y: 210), CGPoint(x: 370, y: 250)], InkStyle(color: .red, width: .medium, fading: false), false),
            (.oval, [CGPoint(x: 305, y: 205), CGPoint(x: 340, y: 255)], Self.blue, false),
            (.highlighter, [CGPoint(x: 300, y: 230), CGPoint(x: 340, y: 232), CGPoint(x: 380, y: 228)], Self.blue, false),
        ])

        // Video: a 2× frame.
        let compositor = RecordingCompositor()
        compositor.update(inkScene)
        let video = Frame(width: 160, height: 120)
        video.draw {
            compositor.draw(in: $0, outputRect: CGRect(x: 0, y: 0, width: 160, height: 120), targetFrame: target, hostTime: 0)
        }

        // Screen: the real view drawing into a 2× (Retina) backing context.
        let view = LiveInkView(frame: CGRect(origin: .zero, size: target.size))
        view.clock = { 0 }
        view.targetFrame = target
        view.scene = inkScene
        let screen = Frame(width: 160, height: 120)
        screen.draw { context in
            context.scaleBy(x: 2, y: 2)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            view.draw(view.bounds)
            NSGraphicsContext.current = previous
        }

        #expect(video.bytes.contains { $0 != 255 })
        let largest = zip(video.bytes, screen.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(largest <= 2)
    }

    // MARK: - Lifetime

    @Test func theDecoratorOutlivesTheClosedPanel() {
        let panel = LiveInkPanel(clock: { 0 })
        let decorator = panel.frameDecorator
        panel.close()
        panel.close()          // idempotent
        panel.perform(.clear)  // a no-op once closed
        let target = CGRect(x: 0, y: 0, width: 10, height: 10)
        let frame = Frame(width: 10, height: 10)
        frame.draw { decorator.draw(in: $0, outputRect: target, targetFrame: target, hostTime: 0) }
        #expect(frame.isWhite(5, 5))
        #expect(panel.setupSnapshot() is InkSetupSnapshot)
    }
}

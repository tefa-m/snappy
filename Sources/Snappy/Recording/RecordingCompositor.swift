import CoreGraphics
import Foundation
import os

/// Draws an `InkScene` — the single drawing path for the on-screen ink view
/// and the recorded video (canvas ≡ export, like the editor). Every stroke is
/// an editor `Annotation` drawn by `AnnotationRenderer`; opacity (fading, the
/// highlighter's 40 %, the Magic Pen's 85 %) is applied around it with a
/// transparency layer, so an arrow's fill and rounding stroke — or the Magic
/// Pen's halo and stroke — don't double up where they overlap.
///
/// The context's CTM must map AppKit-global points to the destination (the
/// view's origin, or `FrameDecoratingGeometry.transform` for a frame); stroke
/// widths scale with it, so a medium line is 4 pt on screen and 4 pt × scale
/// pixels in the video. `windowFrame` is the recorded window's frame when it
/// isn't `targetFrame` itself (W + part: the target is the part).
enum InkRenderer {
    static func draw(
        _ scene: InkScene, in context: CGContext, targetFrame: CGRect, windowFrame: CGRect? = nil, time: TimeInterval
    ) {
        for item in scene.renderItems(time: time, targetFrame: targetFrame, windowFrame: windowFrame) {
            let annotations = (item.underlay.map { [$0] } ?? []) + [item.annotation]
            guard item.alpha < 1 else {
                AnnotationRenderer.draw(annotations, in: context)
                continue
            }
            context.saveGState()
            context.setAlpha(item.alpha)
            context.beginTransparencyLayer(in: item.paintedBounds, auxiliaryInfo: nil)
            AnnotationRenderer.draw(annotations, in: context)
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }
}

/// T3's `FrameDecorating`: draws the live ink into each recorded frame on the
/// pipeline's capture queue.
///
/// The main actor swaps in a new immutable `InkScene` under a lock whenever
/// the ink changes (`update`); `draw` copies the current one out and draws
/// without holding the lock, so it never waits on the main actor. It owns no
/// UI, which is what keeps it safe after `LiveInkPanel.close()` until the
/// pipeline has drained (`FrameDecorating` › Lifetime): it simply keeps
/// drawing the last scene — fades still progress, since they are evaluated at
/// each frame's `hostTime`.
final class RecordingCompositor: FrameDecorating {
    private let scene = OSAllocatedUnfairLock(initialState: InkScene.empty)

    /// Main actor: publish the ink's latest state.
    func update(_ newScene: InkScene) {
        scene.withLock { $0 = newScene }
    }

    var currentScene: InkScene {
        scene.withLock { $0 }
    }

    func draw(
        in context: CGContext, outputRect: CGRect, targetFrame: CGRect, windowFrame: CGRect?, hostTime: TimeInterval
    ) {
        let current = currentScene
        guard !current.strokes.isEmpty, targetFrame.width > 0, targetFrame.height > 0 else { return }
        context.saveGState()
        // Ink outside the target (a W + part's part) is hidden, not deleted (Q42).
        context.clip(to: outputRect)
        context.concatenate(FrameDecoratingGeometry.transform(targetFrame: targetFrame, outputRect: outputRect))
        InkRenderer.draw(current, in: context, targetFrame: targetFrame, windowFrame: windowFrame, time: hostTime)
        context.restoreGState()
    }
}

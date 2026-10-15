import CoreGraphics
import Foundation
import Testing
import os
@testable import Snappy

/// V3 — W + part recorded as the window's stream cropped live to the part
/// (Q37): the window-local crop, the poll samples that may move it, what the
/// decorator is told, the ink staying on the window (Q42) and Retake (Q41).
@Suite("Window parts — live crop")
struct PartCropTests {
    /// A 1000 × 700 pt window whose top-left corner is at (100, 800) AppKit.
    private static let window = CGRect(x: 100, y: 100, width: 1000, height: 700)
    /// Its page area under an 81 pt toolbar.
    private static let page = CGRect(x: 100, y: 100, width: 1000, height: 619)

    // MARK: PartCropGeometry

    @Test func localIsWindowRelativeFromTheTopLeft() {
        // 81 pt below the window's top edge (800 − 719), flush left.
        #expect(PartCropGeometry.local(Self.page, in: Self.window) == CGRect(x: 0, y: 81, width: 1000, height: 619))
        let sidebar = CGRect(x: 120, y: 150, width: 240, height: 500) // top at 650 → 150 below the top
        #expect(PartCropGeometry.local(sidebar, in: Self.window) == CGRect(x: 20, y: 150, width: 240, height: 500))
    }

    @Test func globalIsTheInverseOfLocal() {
        let sidebar = CGRect(x: 120, y: 150, width: 240, height: 500)
        let local = PartCropGeometry.local(sidebar, in: Self.window)
        #expect(PartCropGeometry.global(local, in: Self.window) == sidebar)
        // The same window-local crop in a moved window moves with it.
        let moved = Self.window.offsetBy(dx: 50, dy: -30)
        #expect(PartCropGeometry.global(local, in: moved) == sidebar.offsetBy(dx: 50, dy: -30))
    }

    @Test func aPartInsideTheWindowIsRecordedAsIs() {
        let local = CGRect(x: 0, y: 81, width: 1000, height: 619)
        #expect(PartCropGeometry.sourceRect(local, windowSize: Self.window.size, scale: 2) == local)
    }

    @Test func theCropIsOnThePixelGridWithEvenPixelSides() {
        // 1×: 301 × 201 px → 300 × 200, the odd pixel trimmed at the far edges.
        let odd = CGRect(x: 10, y: 20, width: 301, height: 201)
        #expect(PartCropGeometry.sourceRect(odd, windowSize: Self.window.size, scale: 1)
            == CGRect(x: 10, y: 20, width: 300, height: 200))
        // 2×: edges on half points (whole pixels), even pixel lengths.
        let fractional = CGRect(x: 10.3, y: 20.8, width: 300.4, height: 200.2)
        let source = PartCropGeometry.sourceRect(fractional, windowSize: Self.window.size, scale: 2)
        #expect(source == CGRect(x: 10.5, y: 21, width: 300, height: 200))
        #expect(Int(source.width * 2) % 2 == 0 && Int(source.height * 2) % 2 == 0)
    }

    /// SCK clips a source rect to the window and *stretches* the rest into
    /// the frame (measured live) — so the crop never reaches outside it.
    @Test func theCropIsClampedToTheWindow() {
        let overhanging = CGRect(x: 900, y: 600, width: 300, height: 200)
        #expect(PartCropGeometry.sourceRect(overhanging, windowSize: Self.window.size, scale: 2)
            == CGRect(x: 900, y: 600, width: 100, height: 100))
        let negative = CGRect(x: -20, y: -10, width: 200, height: 100)
        #expect(PartCropGeometry.sourceRect(negative, windowSize: Self.window.size, scale: 2)
            == CGRect(x: 0, y: 0, width: 180, height: 90))
    }

    @Test func nothingOfThePartInTheWindowRecordsTheWholeWindow() {
        let outside = CGRect(x: 1200, y: 10, width: 200, height: 100)
        #expect(PartCropGeometry.sourceRect(outside, windowSize: Self.window.size, scale: 2)
            == CGRect(origin: .zero, size: Self.window.size))
        #expect(PartCropGeometry.sourceRect(.zero, windowSize: Self.window.size, scale: 2)
            == CGRect(origin: .zero, size: Self.window.size))
    }

    @Test func aPartOfItsStartingSizeFillsTheVideoAtOneToOne() {
        // The video is the crop's pixels: no bar, no resampling.
        let source = PartCropGeometry.sourceRect(
            CGRect(x: 0, y: 81, width: 999.5, height: 619), windowSize: Self.window.size, scale: 2
        )
        let video = OutputGeometry.videoSize(forPixelSize: CGSize(width: source.width * 2, height: source.height * 2))
        #expect(CGFloat(video.width) == source.width * 2 && CGFloat(video.height) == source.height * 2)
        #expect(OutputGeometry.letterboxRect(contentSize: video.cgSize, in: video) == video.bounds)
    }

    // MARK: PartCropTracker

    private func tracker() -> PartCropTracker {
        PartCropTracker(part: Self.page, window: Self.window, scale: 2)
    }

    /// Runs one mutating update (`#expect` can't call a mutating member).
    private static func changed(_ crop: inout PartCropTracker, _ update: (inout PartCropTracker) -> Bool) -> Bool {
        update(&crop)
    }

    @Test func startsOnThePickedPart() {
        #expect(tracker().sourceRect == CGRect(x: 0, y: 81, width: 1000, height: 619))
    }

    @Test func aSampleWithTheWindowAtRestMovesTheCrop() {
        var crop = tracker()
        let sidebar = CGRect(x: 100, y: 100, width: 300, height: 619)
        #expect(Self.changed(&crop) { $0.observe(part: sidebar, windowBefore: .onScreen(Self.window), windowAfter: .onScreen(Self.window)) })
        #expect(crop.sourceRect == CGRect(x: 0, y: 81, width: 300, height: 619))
        // The same sample again changes nothing.
        #expect(!Self.changed(&crop) { $0.observe(part: sidebar, windowBefore: .onScreen(Self.window), windowAfter: .onScreen(Self.window)) })
    }

    /// A window being dragged: its frame changed around the AX read, so the
    /// part's frame and the window's don't belong together — dropped.
    @Test func aSampleTakenWhileTheWindowMovesIsDropped() {
        var crop = tracker()
        let moved = Self.window.offsetBy(dx: 12, dy: 0)
        let laggingPart = Self.page.offsetBy(dx: 4, dy: 0)
        #expect(!Self.changed(&crop) { $0.observe(part: laggingPart, windowBefore: .onScreen(Self.window), windowAfter: .onScreen(moved)) })
        #expect(crop.sourceRect == CGRect(x: 0, y: 81, width: 1000, height: 619))
    }

    /// A sample taken entirely in a moved window is consistent: the crop is
    /// window-local, so the same part in the moved window is the same crop.
    @Test func aConsistentSampleInAMovedWindowKeepsTheCrop() {
        var crop = tracker()
        let moved = Self.window.offsetBy(dx: 300, dy: -50)
        #expect(!Self.changed(&crop) { $0.observe(part: Self.page.offsetBy(dx: 300, dy: -50),
                              windowBefore: .onScreen(moved), windowAfter: .onScreen(moved)) })
        #expect(crop.sourceRect == CGRect(x: 0, y: 81, width: 1000, height: 619))
    }

    /// Q37: the part disappeared (tab closed, navigated) or the app didn't
    /// answer — the last rect stays.
    @Test func aGonePartKeepsTheLastRect() {
        var crop = tracker()
        #expect(!Self.changed(&crop) { $0.observe(part: nil, windowBefore: .onScreen(Self.window), windowAfter: .onScreen(Self.window)) })
        #expect(!Self.changed(&crop) { $0.observe(part: .zero, windowBefore: .onScreen(Self.window), windowAfter: .onScreen(Self.window)) })
        #expect(crop.sourceRect == CGRect(x: 0, y: 81, width: 1000, height: 619))
    }

    /// Off screen (minimised, other Space, hidden): nothing to compare with —
    /// the crop holds, like the recording (Q44).
    @Test func anOffScreenWindowDropsTheSample() {
        var crop = tracker()
        let sidebar = CGRect(x: 100, y: 100, width: 300, height: 619)
        #expect(!Self.changed(&crop) { $0.observe(part: sidebar, windowBefore: .offScreen, windowAfter: .offScreen) })
        #expect(!Self.changed(&crop) { $0.observe(part: sidebar, windowBefore: .missing, windowAfter: .missing) })
        #expect(!Self.changed(&crop) { $0.observe(part: sidebar, windowBefore: .onScreen(Self.window), windowAfter: .offScreen) })
        #expect(crop.sourceRect == CGRect(x: 0, y: 81, width: 1000, height: 619))
    }

    @Test func aWindowMoveNeverChangesTheCrop() {
        var crop = tracker()
        #expect(!Self.changed(&crop) { $0.windowChanged(Self.window.offsetBy(dx: 80, dy: 40)) })
        #expect(crop.sourceRect == CGRect(x: 0, y: 81, width: 1000, height: 619))
    }

    /// A window that shrinks under the part re-clamps the crop at once; grown
    /// back, the part's own rect returns (it is kept unclamped).
    @Test func aShrinkingWindowClampsTheCropAndGrowingBackRestoresIt() {
        var crop = tracker()
        #expect(Self.changed(&crop) { $0.windowChanged(CGRect(x: 100, y: 300, width: 600, height: 500)) })
        #expect(crop.sourceRect == CGRect(x: 0, y: 81, width: 600, height: 419))
        #expect(Self.changed(&crop) { $0.windowChanged(Self.window) })
        #expect(crop.sourceRect == CGRect(x: 0, y: 81, width: 1000, height: 619))
    }

    // MARK: DecorationTarget

    @Test func theDecoratorShowsThePartAndAnchorsToTheWindow() {
        let part = DecorationTarget.part(window: Self.window, sourceRect: CGRect(x: 0, y: 81, width: 1000, height: 619))
        #expect(part.frame == Self.page)
        #expect(part.windowFrame == Self.window)
        let moved = part.withWindowFrame(Self.window.offsetBy(dx: 50, dy: 10))
        #expect(moved.frame == Self.page.offsetBy(dx: 50, dy: 10))
        #expect(moved.withSourceRect(CGRect(x: 0, y: 81, width: 300, height: 619)).frame
            == CGRect(x: 150, y: 110, width: 300, height: 619))

        #expect(DecorationTarget.window(Self.window).frame == Self.window)
        #expect(DecorationTarget.window(Self.window).windowFrame == Self.window)
        #expect(DecorationTarget.window(Self.window).withWindowFrame(Self.page) == .window(Self.page))
        let area = DecorationTarget.area(Self.page)
        #expect(area.windowFrame == nil)
        #expect(area.withWindowFrame(Self.window) == area)
        #expect(area.withSourceRect(.zero) == area)
    }

    // MARK: Q42 — ink on the window, hidden outside the part

    private func strokeOnTheWindow(at point: CGPoint) -> LiveInk {
        var ink = LiveInk(fadeDelay: 3)
        ink.setTarget(.windowPart(
            WindowPartTarget(windowID: 9, windowFrame: Self.window, frame: Self.page, name: "Web page", element: nil),
            displayID: 1
        ))
        ink.beginStroke(tool: .box, at: point, style: InkStyle(color: .red, width: .thin, fading: false), isCapturing: true)
        ink.extendStroke(to: CGPoint(x: point.x + 40, y: point.y - 30))
        ink.endStroke(at: 0)
        return ink
    }

    @Test func inkResolvesAgainstTheWindowNotThePart() throws {
        let ink = strokeOnTheWindow(at: CGPoint(x: 200, y: 600))
        // The window moved by (+50, −20); the part is the page area in it.
        let window = Self.window.offsetBy(dx: 50, dy: -20)
        let page = Self.page.offsetBy(dx: 50, dy: -20)
        let item = try #require(ink.scene.renderItems(time: 0, targetFrame: page, windowFrame: window).first)
        guard case .shape(let box) = item.annotation else {
            Issue.record("not a box")
            return
        }
        #expect(box.rect == CGRect(x: 250, y: 550, width: 40, height: 30))
    }

    @Test func inkOutsideThePartIsHiddenNotDeleted() {
        // In the toolbar strip above the page area.
        let ink = strokeOnTheWindow(at: CGPoint(x: 200, y: 790))
        let toolbarOnly = CGRect(x: 100, y: 719, width: 1000, height: 81)
        #expect(ink.scene.renderItems(time: 0, targetFrame: Self.page, windowFrame: Self.window).isEmpty)
        #expect(ink.scene.renderItems(time: 0, targetFrame: toolbarOnly, windowFrame: Self.window).count == 1)
        #expect(ink.strokes.count == 1)
    }

    // MARK: Q41 — Retake

    private func partTarget(element: WindowPartElement?) -> RecordingTarget {
        .windowPart(
            WindowPartTarget(windowID: 9, windowFrame: Self.window, frame: Self.page, name: "Web page", element: element),
            displayID: 1
        )
    }

    @Test func retakeFindsThePartAtItsLiveFrameInItsWindowNow() {
        let element = WindowPartElement(processID: 7) { nil }
        let moved = Self.window.offsetBy(dx: 40, dy: 10)
        let live = CGRect(x: 140, y: 110, width: 700, height: 619)
        let refreshed = partTarget(element: element).refreshedForRetake(livePartFrame: live, window: .onScreen(moved))
        #expect(refreshed == .windowPart(
            WindowPartTarget(windowID: 9, windowFrame: moved, frame: live, name: "Web page", element: element),
            displayID: 1
        ))
    }

    @Test func retakeClipsTheLivePartToItsWindow() {
        let element = WindowPartElement(processID: 7) { nil }
        let tall = CGRect(x: 100, y: -500, width: 1000, height: 1219) // a document taller than the window
        let refreshed = partTarget(element: element).refreshedForRetake(livePartFrame: tall, window: .onScreen(Self.window))
        #expect(refreshed.frame == Self.page)
    }

    @Test func retakeOfAGonePartIsTheWholeWindow() {
        let element = WindowPartElement(processID: 7) { nil }
        let moved = Self.window.offsetBy(dx: 40, dy: 10)
        #expect(partTarget(element: element).refreshedForRetake(livePartFrame: nil, window: .onScreen(moved))
            == .window(windowID: 9, frame: moved, displayID: 1))
        #expect(partTarget(element: element).refreshedForRetake(livePartFrame: nil, window: .offScreen)
            == .window(windowID: 9, frame: Self.window, displayID: 1))
        let elsewhere = CGRect(x: 2000, y: 2000, width: 100, height: 100)
        #expect(partTarget(element: element).refreshedForRetake(livePartFrame: elsewhere, window: .onScreen(Self.window))
            == .window(windowID: 9, frame: Self.window, displayID: 1))
    }

    @Test func retakeOfAPartWithoutAnElementKeepsItsLastRectInItsWindow() {
        let moved = Self.window.offsetBy(dx: 40, dy: 10)
        #expect(partTarget(element: nil).refreshedForRetake(livePartFrame: nil, window: .onScreen(moved))
            == partTarget(element: nil).withWindowFrame(moved))
    }

    @Test func retakeOfAClosedWindowIsItsRegion() {
        let element = WindowPartElement(processID: 7) { nil }
        #expect(partTarget(element: element).refreshedForRetake(livePartFrame: Self.page, window: .missing)
            == .area(globalRect: Self.page, displayID: 1))
        let window = RecordingTarget.window(windowID: 9, frame: Self.window, displayID: 1)
        #expect(window.refreshedForRetake(livePartFrame: nil, window: .missing)
            == .area(globalRect: Self.window, displayID: 1))
    }

    @Test func retakeOfAWindowFindsItWhereItIsNow() {
        let window = RecordingTarget.window(windowID: 9, frame: Self.window, displayID: 1)
        let moved = Self.window.offsetBy(dx: 40, dy: 10)
        #expect(window.refreshedForRetake(livePartFrame: nil, window: .onScreen(moved))
            == .window(windowID: 9, frame: moved, displayID: 1))
        #expect(window.refreshedForRetake(livePartFrame: nil, window: .offScreen) == window)
    }

    /// S + part was recorded as a fixed screen rect: Retake keeps it (Q41).
    @Test func retakeOfAnAreaIsTheLastScreenRect() {
        let area = RecordingTarget.area(globalRect: Self.page, displayID: 1)
        #expect(area.refreshedForRetake(livePartFrame: nil, window: .missing) == area)
        #expect(area.refreshedForRetake(livePartFrame: Self.window, window: .onScreen(Self.window)) == area)
    }
}

/// Review V3 findings 1 and 3, the pure side: the visible frame of a live
/// chain, which crop each frame was presented under, and the one-at-a-time
/// crop updates around SCK.
@Suite("Window parts — visible frame and crop timeline")
struct PartCropTimelineTests {
    // MARK: Finding 1 — visible frame

    @Test func aPartIsClippedByEveryEnclosingFrame() {
        let viewport = CGRect(x: 100, y: 100, width: 800, height: 500)
        let table = CGRect(x: 100, y: -300, width: 400, height: 1500)
        #expect(WindowPartSelection.visibleFrame(of: [viewport, table]) == CGRect(x: 100, y: 100, width: 400, height: 500))
        // A frameless wrapper, or one wholly elsewhere, doesn't clip.
        #expect(WindowPartSelection.visibleFrame(of: [.null, viewport, .zero, table])
            == CGRect(x: 100, y: 100, width: 400, height: 500))
        #expect(WindowPartSelection.visibleFrame(of: [viewport, CGRect(x: 2000, y: 0, width: 10, height: 10), table])
            == CGRect(x: 100, y: 100, width: 400, height: 500))
        #expect(WindowPartSelection.visibleFrame(of: [table]) == table)
    }

    @Test func aPartWithNothingVisibleHasNoFrame() {
        let viewport = CGRect(x: 100, y: 100, width: 800, height: 500)
        #expect(WindowPartSelection.visibleFrame(of: [viewport, CGRect(x: 100, y: 900, width: 400, height: 100)]) == nil)
        #expect(WindowPartSelection.visibleFrame(of: [viewport, .null]) == nil)
        #expect(WindowPartSelection.visibleFrame(of: []) == nil)
    }

    /// The live read and the picker agree on every node of a chain.
    @Test func theVisibleFrameIsThePickersLevelFrame() {
        let window = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let nodes = [
            WindowPartNode(role: "AXSplitGroup", frame: CGRect(x: 100, y: 100, width: 1000, height: 619)),
            WindowPartNode(role: "AXScrollArea", frame: CGRect(x: 400, y: 100, width: 700, height: 500)),
            WindowPartNode(role: "AXTable", frame: CGRect(x: 400, y: -900, width: 500, height: 2000)),
        ]
        let point = CGPoint(x: 600, y: 300)
        let levels = WindowPartSelection.levels(window: window, chain: WindowPartChain(nodes: nodes), at: point)
        #expect(levels.last?.frame == WindowPartSelection.visibleFrame(of: nodes.map(\.frame)))
    }

    // MARK: Finding 3 — the crop timeline

    private static let a = CGRect(x: 0, y: 80, width: 400, height: 300)
    private static let b = CGRect(x: 400, y: 80, width: 400, height: 300)
    private static let c = CGRect(x: 200, y: 80, width: 400, height: 300)
    private static let interval = 1.0 / 60

    private func timeline() -> PartCropTimeline {
        PartCropTimeline(source: Self.a, margin: Self.interval, grace: 2 * Self.interval)
    }

    @Test func framesBeforeTheRequestAreOldAfterTheCompletionNewBetweenUncertain() {
        var crops = timeline()
        crops.requested(Self.b, at: 10)
        #expect(crops.crop(at: 9.9) == .known(Self.a))
        #expect(crops.crop(at: 10 - Self.interval / 2) == .uncertain, "SCK may be cropping it as the update arrives")
        #expect(crops.crop(at: 10.5) == .uncertain, "no completion yet: not known")
        crops.applied(at: 10.03)
        #expect(crops.crop(at: 9.9) == .known(Self.a), "a queued old frame stays old after the completion")
        #expect(crops.crop(at: 10.02) == .uncertain)
        #expect(crops.crop(at: 10.04) == .known(Self.b))
    }

    @Test func aFailedUpdateLeavesTheOldCrop() {
        var crops = timeline()
        crops.requested(Self.b, at: 10)
        crops.failed()
        #expect(crops.crop(at: 10.02) == .known(Self.a))
        #expect(crops.pendingChanges == 0)
    }

    @Test func placedFramesFoldOlderChanges() {
        var crops = timeline()
        crops.requested(Self.b, at: 10)
        crops.applied(at: 10.03)
        crops.requested(Self.c, at: 10.2)
        crops.applied(at: 10.22)
        #expect(crops.crop(at: 10.1) == .known(Self.b))
        #expect(crops.crop(at: 10.3) == .known(Self.c))
        crops.framePlaced(at: 10.1)
        #expect(crops.pendingChanges == 1)
        #expect(crops.base == Self.b)
        crops.framePlaced(at: 10.3)
        #expect(crops.pendingChanges == 0)
        #expect(crops.base == Self.c)
    }

    @Test func aHeldFrameSettlesOnTheNewCropOnlyAfterTheGrace() {
        var crops = timeline()
        crops.requested(Self.b, at: 10)
        #expect(crops.settledCrop(forHeldFrameAt: 10.02, now: 11) == nil, "not returned yet")
        crops.applied(at: 10.03)
        #expect(crops.settledCrop(forHeldFrameAt: 10.02, now: 10.04) == nil, "a later frame may still come")
        #expect(crops.settledCrop(forHeldFrameAt: 10.02, now: 10.03 + 2 * Self.interval) == Self.b)
        crops.requested(Self.c, at: 10.5)
        crops.failed()
        #expect(crops.settledCrop(forHeldFrameAt: 10.5, now: 10.5) == Self.b, "known again once a failure dropped it")
    }

    @Test func areasAndWholeWindowsHaveNoCrop() {
        var state = FrameDecorationState(target: .window(CGRect(x: 0, y: 0, width: 800, height: 600)), frameInterval: Self.interval)
        state.cropRequested(Self.b, at: 1)
        #expect(state.place(frameAt: 1.01) == FrameCrop.none)
        #expect(state.target(for: .none) == .window(CGRect(x: 0, y: 0, width: 800, height: 600)))
    }

    @Test func aPartFrameIsDecoratedWithItsOwnCropInTheWindowWhereItIsNow() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        var state = FrameDecorationState(target: .part(window: window, sourceRect: Self.a), frameInterval: Self.interval)
        state.cropRequested(Self.b, at: 2)
        state.cropApplied(at: 2.03)
        #expect(state.place(frameAt: 1.9) == .source(Self.a))
        #expect(state.place(frameAt: 2.01) == .uncertain)
        state.windowMoved(to: window.offsetBy(dx: 50, dy: 0))
        #expect(state.target(for: .source(Self.a)) == .part(window: window.offsetBy(dx: 50, dy: 0), sourceRect: Self.a))
        #expect(state.place(frameAt: 2.05) == .source(Self.b))
    }
}

/// `PartCropUpdater` with a fake SCK: one update in flight, the newest crop
/// next, the stamps around the call, a failure shown honestly and retried.
@MainActor
@Suite("Window parts — crop updates")
struct PartCropUpdaterTests {
    private static let a = CGRect(x: 0, y: 80, width: 400, height: 300)
    private static let b = CGRect(x: 400, y: 80, width: 400, height: 300)
    private static let c = CGRect(x: 200, y: 80, width: 400, height: 300)
    private static let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    @MainActor final class FakeSCK {
        var requests: [CGRect] = []
        var completions: [@Sendable (Bool) -> Void] = []
        /// What the writer's timeline said when each update was called.
        var cropAtCall: [PartCropTimeline.Crop] = []
    }

    private final class Clock: Sendable {
        private let value = OSAllocatedUnfairLockBox(0.0)
        var now: Double { value.get() }
        func set(_ time: Double) { value.set(time) }
    }

    private func make(_ sck: FakeSCK, clock: Clock, shown: @escaping @MainActor (CGRect) -> Void = { _ in })
        -> (PartCropUpdater, OSAllocatedUnfairLockBox<FrameDecorationState>)
    {
        let state = FrameDecorationState(target: .part(window: Self.window, sourceRect: Self.a), frameInterval: 1.0 / 60)
        let box = OSAllocatedUnfairLockBox(state)
        let updater = PartCropUpdater(source: Self.a, decoration: box.lock, now: { clock.now }) { source, done in
            sck.requests.append(source)
            sck.cropAtCall.append(box.get().crops?.crop(at: clock.now) ?? .known(.zero))
            sck.completions.append(done)
        }
        updater.onShow = shown
        return (updater, box)
    }

    private func drain() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test func oneUpdateAtATimeThenTheNewestCrop() async {
        let sck = FakeSCK()
        let clock = Clock()
        var shown: [CGRect] = []
        let (updater, _) = make(sck, clock: clock) { shown.append($0) }
        updater.want(Self.a)
        #expect(sck.requests.isEmpty, "already recorded")
        updater.want(Self.b)
        updater.want(Self.c)
        updater.want(Self.b)
        #expect(sck.requests == [Self.b], "one in flight")
        #expect(shown == [Self.b], "the chrome follows the request at once")
        updater.want(Self.c)
        sck.completions[0](true)
        await drain()
        #expect(updater.applied == Self.b)
        #expect(sck.requests == [Self.b, Self.c], "the newest wanted crop goes next")
        sck.completions[1](true)
        await drain()
        #expect(updater.applied == Self.c)
        #expect(updater.inFlight == nil)
    }

    /// Requested before SCK is called; the completion stamped on SCK's own
    /// callback, before the main actor hears of it.
    @Test func theTimelineIsStampedAroundTheCall() async {
        let sck = FakeSCK()
        let clock = Clock()
        clock.set(5)
        let (updater, box) = make(sck, clock: clock)
        updater.want(Self.b)
        #expect(sck.cropAtCall == [.uncertain], "the change was requested before the call")
        clock.set(5.03)
        sck.completions[0](true) // no main-actor turn yet
        #expect(box.get().crops?.crop(at: 5.04) == .known(Self.b))
        #expect(box.get().crops?.crop(at: 4.9) == .known(Self.a))
    }

    /// A failure: SCK kept the old crop — the chrome goes back to it, the
    /// timeline drops the change, and the crop is asked again a second later.
    @Test func aFailedUpdateIsShownHonestlyAndRetried() async {
        let sck = FakeSCK()
        let clock = Clock()
        clock.set(5)
        var shown: [CGRect] = []
        let (updater, box) = make(sck, clock: clock) { shown.append($0) }
        updater.want(Self.b)
        sck.completions[0](false)
        #expect(box.get().crops?.crop(at: 5.01) == .known(Self.a))
        await drain()
        #expect(updater.applied == Self.a)
        #expect(shown == [Self.b, Self.a])
        updater.want(Self.b)
        #expect(sck.requests.count == 1, "not before the retry delay")
        clock.set(5 + PartCropUpdater.retryDelay)
        updater.want(Self.b)
        #expect(sck.requests == [Self.b, Self.b])
    }

    @Test func nothingIsSentOrShownOnceStopped() async {
        let sck = FakeSCK()
        let clock = Clock()
        var shown: [CGRect] = []
        let (updater, _) = make(sck, clock: clock) { shown.append($0) }
        updater.want(Self.b)
        updater.stop()
        updater.want(Self.c)
        sck.completions[0](false)
        await drain()
        #expect(sck.requests == [Self.b])
        #expect(shown == [Self.b])
    }
}

/// A lock and its value, for tests that read what the code under test keeps
/// in an `OSAllocatedUnfairLock`.
final class OSAllocatedUnfairLockBox<Value: Sendable>: Sendable {
    let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    func get() -> Value { lock.withLock { $0 } }
    func set(_ value: Value) { lock.withLock { $0 = value } }
}

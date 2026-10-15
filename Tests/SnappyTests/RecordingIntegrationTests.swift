import AppKit
import Carbon
import Foundation
import QuartzCore
import Testing
@testable import Snappy

/// T7 — the real wave-1 pieces wired together by the real coordinator: the
/// Setup overlay (T1), live ink (T3) and chrome (T4) as shipped, with only the
/// pipeline (ScreenCaptureKit) and the recording window faked. Checks what no single
/// piece can: that they agree on window levels, mouse ownership, the target
/// a moving window drags along, and what Retake brings back. Needs a display.
@MainActor
@Suite("Recording integration (real pieces)", .serialized)
struct RecordingIntegrationTests {
    // MARK: - Fakes (the two pieces that need TCC or a real file)

    @MainActor final class Pipeline: RecordingPipelining {
        var onWindowFrameChange: (@MainActor (CGRect) -> Void)?
        var onPartFrameChange: (@MainActor (CGRect) -> Void)?
        var onWindowGone: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        var url: URL?
        var failStart = false
        struct Failure: Error {}
        func start(target: RecordingTarget, settings: RecordingSettings,
                   decorator: any FrameDecorating, outputURL: URL) async throws {
            if failStart { throw Failure() }
            url = outputURL
        }
        func stop() async throws -> URL {
            // Called after a failed start too (contract): throwing is fine then.
            guard let url else { throw Failure() }
            try Data("mp4".utf8).write(to: url)
            return url
        }
    }

    /// A recording window per finished take (the real one needs a screen).
    @MainActor final class Window: RecordingWindowHosting {
        let take: URL
        let onRetake: (@MainActor () -> Void)?
        var isOpen = true
        var onClose: (@MainActor () -> Void)?
        init(take: URL, onRetake: (@MainActor () -> Void)?) {
            self.take = take
            self.onRetake = onRetake
        }
        func show() {}
        func bringToFront() {}
        func close() {
            guard isOpen else { return }
            isOpen = false
            Task { @MainActor in self.onClose?() }
        }
    }

    /// The session hot key seam: accepts or refuses like Carbon would.
    @MainActor final class HotKeys: SessionHotKeyRegistering {
        /// Actions whose combo another app owns.
        var refused: Set<HotKeyAction> = []
        var handlers: [HotKeyAction: @MainActor () -> Void] = [:]
        var combos: [HotKeyAction: HotKeyCombo] = [:]
        private(set) var unregistered: [HotKeyAction] = []
        /// Draw-mode unregistrations (the count the T7 tests check).
        var unregistrations: Int { unregistrations(of: .toggleDrawMode) }
        func unregistrations(of action: HotKeyAction) -> Int { unregistered.filter { $0 == action }.count }
        func register(_ action: HotKeyAction, combo: HotKeyCombo, handler: @escaping @MainActor () -> Void) -> Bool {
            guard !refused.contains(action) else { return false }
            handlers[action] = handler
            combos[action] = combo
            return true
        }
        func unregister(_ action: HotKeyAction) {
            unregistered.append(action)
            handlers[action] = nil
        }
    }

    @MainActor final class Harness {
        var windows: [Window] = []
        /// The newest recording window, while it is open.
        var openWindow: Window? { windows.last.flatMap { $0.isOpen ? $0 : nil } }
        let hotKeys = HotKeys()
        var notices: [BannerText] = []
        var failNextStart = false
        var pipelines: [Pipeline] = []
        var inks: [LiveInkPanel] = []
        var activations = 0
        let coordinator: RecordingCoordinator
        let defaults: UserDefaults
        let suiteName = "SnappyTests.RecordingIntegration.\(UUID().uuidString)"
        let tempStore: RecordingTempStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            let settings = SettingsStore(defaults: defaults)
            settings.recordingCountdown = .off
            tempStore = RecordingTempStore(directory: FileManager.default.temporaryDirectory
                .appending(path: "SnappyIntegrationTests-\(UUID().uuidString)", directoryHint: .isDirectory))
            let box = Box()
            coordinator = RecordingCoordinator(
                components: RecordingComponents(
                    makeSetupOverlay: { RecordingSetupOverlay() },
                    makeLiveInk: { box.harness!.makeInk() },
                    makePipeline: { box.harness!.makePipeline() },
                    makeChrome: { RecordingChrome(drawModeKey: "⌃⌥D") },
                    makeRecordingWindow: { take, _, onRetake, _ in
                        let window = Window(take: take, onRetake: onRetake)
                        box.harness?.windows.append(window)
                        return window
                    }
                ),
                settings: settings, tempStore: tempStore
            )
            box.harness = self
            coordinator.activateUserApp = { _ in box.harness?.activations += 1 }
            coordinator.activateSnappy = {}
            coordinator.observeWindow = { _ in .offScreen }
            coordinator.hotKeys = hotKeys
            coordinator.notify = { box.harness?.notices.append($0) }
        }

        final class Box { weak var harness: Harness? }

        func makeInk() -> LiveInkPanel { let ink = LiveInkPanel(); inks.append(ink); return ink }
        func makePipeline() -> Pipeline {
            let p = Pipeline()
            p.failStart = failNextStart
            pipelines.append(p)
            return p
        }

        func cleanUp() {
            coordinator.handle(.command(.cancel))
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempStore.directory)
        }
    }

    // MARK: - Helpers

    /// A target well inside the main display, so no piece has to move it.
    private func areaTarget() throws -> RecordingTarget {
        let screen = try #require(NSScreen.screens.first, "needs a display")
        let id = try #require(CaptureEngine.displayID(for: screen))
        let visible = screen.visibleFrame
        let rect = CGRect(x: visible.minX + 200, y: visible.minY + 200, width: 400, height: 240)
        return .area(globalRect: rect, displayID: id)
    }

    /// Our visible windows at one recording level.
    private func windows(at level: NSWindow.Level) -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.level == level && $0.isVisible }
    }

    private func inkWindow() throws -> NSWindow {
        try #require(windows(at: RecordingWindowLevel.ink).first)
    }

    /// Lets queued main-actor work (the overlay's target sync, async
    /// start/stop) run until `condition` holds.
    private func until(_ condition: () -> Bool, _ comment: Comment? = nil) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition(), comment)
    }

    /// A pen drag across the ink window, as the window server would deliver it.
    private func drag(in window: NSWindow, from start: CGPoint, to end: CGPoint) {
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        window.sendEvent(event(.leftMouseDown, start))
        for step in 1...8 {
            let t = CGFloat(step) / 8
            window.sendEvent(event(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
        }
        window.sendEvent(event(.leftMouseUp, end))
    }

    /// Whether the ink's video decorator paints at `point` (target-local
    /// points); `window` = the recorded window when the target is a part of it.
    private func decoratorPaints(
        _ decorator: any FrameDecorating, target: CGRect, window: CGRect? = nil, at point: CGPoint
    ) -> Bool {
        let width = Int(target.width), height = Int(target.height)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        decorator.draw(in: context, outputRect: CGRect(x: 0, y: 0, width: width, height: height),
                       targetFrame: target, windowFrame: window, hostTime: CACurrentMediaTime())
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        // CG bitmap memory is top row first.
        let offset = (height - 1 - Int(point.y)) * width * 4 + Int(point.x) * 4
        return bytes[offset + 3] > 0
    }

    // MARK: - Tests

    @Test("The factory builds the real wave-1 pieces")
    func theFactoryBuildsTheRealPieces() {
        let components = RecordingComponents.current
        let overlay = components.makeSetupOverlay()
        let ink = components.makeLiveInk()
        let chrome = components.makeChrome()
        #expect(overlay is RecordingSetupOverlay)
        #expect(ink is LiveInkPanel)
        #expect(components.makePipeline() is RecordingPipeline)
        #expect(chrome is RecordingChrome)
        let take = URL(fileURLWithPath: "/tmp/Take-0.mp4")
        let window = components.makeRecordingWindow(
            take, .zero, nil, RecordingWindowContext(savedFiles: RecordingSavedFiles(), mayTakeFocus: { true })
        )
        #expect(window is RecordingWindowController)
        window.close()
        overlay.close()
        ink.close()
        chrome.close()
    }

    @Test("Window levels: setup < ink < chrome; the overlay leaves when recording starts; nothing activates Snappy")
    func windowLevelsAndOwnership() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let target = try areaTarget()
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        await until({ !windows(at: RecordingWindowLevel.chrome).isEmpty }, "chrome on screen")

        let setup = windows(at: RecordingWindowLevel.setup)
        let ink = windows(at: RecordingWindowLevel.ink)
        let chrome = windows(at: RecordingWindowLevel.chrome)
        #expect(setup.count == 1)
        #expect(ink.count == 1)
        #expect(chrome.count >= 2) // border segment(s) + toolbar
        #expect(RecordingWindowLevel.setup < RecordingWindowLevel.ink)
        #expect(RecordingWindowLevel.ink < RecordingWindowLevel.chrome)
        #expect(RecordingWindowLevel.chrome < .screenSaver) // under the area-capture overlay

        // Every recording window is a non-activating panel: none of them can
        // pull the user's app out of the foreground. Only the overlay and the
        // ink ever take key status; the chrome never does.
        for window in setup + ink + chrome {
            #expect(window.styleMask.contains(.nonactivatingPanel))
            #expect(window.animationBehavior == .none)
            #expect(!window.hidesOnDeactivate)
        }
        #expect(setup.allSatisfy { $0.canBecomeKey })
        #expect(ink.allSatisfy { $0.canBecomeKey })
        #expect(chrome.allSatisfy { !$0.canBecomeKey })

        // The ink covers exactly the target; in Setup/Pointer it lets the
        // mouse through to the overlay below.
        #expect(ink[0].frame == target.frame)
        #expect(ink[0].ignoresMouseEvents)
        h.coordinator.handle(.command(.tool(.pen)))
        #expect(!ink[0].ignoresMouseEvents)
        h.coordinator.handle(.command(.pointer))
        #expect(ink[0].ignoresMouseEvents)

        // Recording: the overlay is gone, the ink is click-through (interact),
        // the chrome stays; the user's app gets the keyboard back.
        h.coordinator.handle(.command(.record))
        #expect(h.coordinator.phase == .recording(.interact))
        #expect(windows(at: RecordingWindowLevel.setup).isEmpty)
        #expect(ink[0].isVisible && ink[0].ignoresMouseEvents)
        #expect(!windows(at: RecordingWindowLevel.chrome).isEmpty)
        #expect(h.activations == 1)

        // Draw mode takes the mouse; back to interact hands everything back.
        h.coordinator.handle(.command(.toggleDrawMode))
        #expect(h.coordinator.phase == .recording(.draw(.pen)))
        #expect(!ink[0].ignoresMouseEvents)
        #expect(h.activations == 1) // draw mode never activates the user's app
        h.coordinator.handle(.command(.toggleDrawMode))
        #expect(ink[0].ignoresMouseEvents)
        #expect(h.activations == 2)

        h.coordinator.stop()
        await until({ h.openWindow != nil }, "recording window")
        for level in [RecordingWindowLevel.setup, RecordingWindowLevel.ink, RecordingWindowLevel.chrome] {
            #expect(windows(at: level).isEmpty)
        }
    }

    @Test("A moving window target drags the ink panel and the border along")
    func inkAndBorderFollowAMovingWindow() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let area = try areaTarget()
        let target = RecordingTarget.window(windowID: 4242, frame: area.frame, displayID: area.displayID)
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.first?.url != nil }, "pipeline started")

        let moved = area.frame.offsetBy(dx: 60, dy: -40).insetBy(dx: 20, dy: 10)
        try #require(h.pipelines.first).onWindowFrameChange?(moved)

        #expect(h.coordinator.session?.target == .window(windowID: 4242, frame: moved, displayID: area.displayID))
        #expect(try inkWindow().frame == moved)
        // The border ring sits 4 pt outside the target (`ChromeLayout`).
        let ring = moved.insetBy(dx: -4, dy: -4)
        #expect(windows(at: RecordingWindowLevel.chrome).contains { $0.frame == ring })
    }

    /// V3 (Q37/Q42): the ink panel and the border sit on the **part** and
    /// follow it — a part report moves them inside the window, a window move
    /// carries them along — while a stroke stays on the window's content: in
    /// the video it is where it was drawn on the window, and it is hidden
    /// (not deleted) once the part no longer covers it.
    @Test("A W + part target: ink and border on the part, following it; ink stays on the window")
    func inkAndBorderFollowAPart() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let area = try areaTarget()
        let window = area.frame.insetBy(dx: -100, dy: -60)
        let part = CGRect(x: window.minX, y: window.minY, width: window.width, height: window.height - 80)
        let target = RecordingTarget.windowPart(
            WindowPartTarget(windowID: 4243, windowFrame: window, frame: part, name: "Web page", element: nil),
            displayID: area.displayID
        )
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        #expect(try inkWindow().frame == part, "the ink covers the part, not its window")
        h.coordinator.handle(.command(.record))
        await until({ h.pipelines.first?.url != nil }, "pipeline started")
        let pipeline = try #require(h.pipelines.first)

        // A pen stroke in draw mode, 40 pt into the part from its top-left
        // (ink-window-local points).
        h.coordinator.handle(.command(.toggleDrawMode))
        drag(in: try inkWindow(), from: CGPoint(x: 40, y: part.height - 40), to: CGPoint(x: 100, y: part.height - 40))
        h.coordinator.handle(.command(.toggleDrawMode))
        let decorator = try #require(h.inks.first).frameDecorator
        #expect(decoratorPaints(decorator, target: part, window: window, at: CGPoint(x: 70, y: part.height - 40)))

        // The page area shrinks to its right half: panel and ring follow; the
        // stroke (left half, window-anchored) is hidden there, not deleted.
        let rightHalf = CGRect(x: part.midX, y: part.minY, width: part.width / 2, height: part.height)
        pipeline.onPartFrameChange?(rightHalf)
        #expect(h.coordinator.session?.target.frame == rightHalf)
        #expect(h.coordinator.session?.target.windowFrame == window)
        #expect(try inkWindow().frame == rightHalf)
        #expect(windows(at: RecordingWindowLevel.chrome).contains { $0.frame == rightHalf.insetBy(dx: -4, dy: -4) })
        #expect(!decoratorPaints(decorator, target: rightHalf, window: window, at: CGPoint(x: 10, y: part.height - 40)))
        pipeline.onPartFrameChange?(part)
        #expect(decoratorPaints(decorator, target: part, window: window, at: CGPoint(x: 70, y: part.height - 40)))

        // The window moves: the part keeps its place in it, and so does the ink.
        let moved = window.offsetBy(dx: 30, dy: -20)
        pipeline.onWindowFrameChange?(moved)
        let movedPart = part.offsetBy(dx: 30, dy: -20)
        #expect(h.coordinator.session?.target.frame == movedPart)
        #expect(try inkWindow().frame == movedPart)
        #expect(decoratorPaints(decorator, target: movedPart, window: moved, at: CGPoint(x: 70, y: part.height - 40)))
    }

    @Test("Retake restores the target and the setup ink; recorded strokes are gone")
    func retakeRestoresSetupInkOnly() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let target = try areaTarget()
        let frame = target.frame
        #expect(h.coordinator.beginSession(target: target, userApp: nil))

        // A setup stroke across the lower third (window-local points).
        h.coordinator.handle(.command(.tool(.pen)))
        let setupY = frame.height / 3, recordedY = frame.height * 2 / 3
        drag(in: try inkWindow(), from: CGPoint(x: 40, y: setupY), to: CGPoint(x: frame.width - 40, y: setupY))
        h.coordinator.handle(.command(.pointer))

        // A recorded stroke across the upper third, in draw mode.
        h.coordinator.handle(.command(.record))
        h.coordinator.handle(.command(.toggleDrawMode))
        drag(in: try inkWindow(), from: CGPoint(x: 40, y: recordedY), to: CGPoint(x: frame.width - 40, y: recordedY))
        let first = try #require(h.inks.first).frameDecorator
        let mid = frame.width / 2
        #expect(decoratorPaints(first, target: frame, at: CGPoint(x: mid, y: setupY)))
        #expect(decoratorPaints(first, target: frame, at: CGPoint(x: mid, y: recordedY)))

        h.coordinator.stop()
        await until({ h.openWindow != nil }, "recording window")
        let retake = try #require(h.openWindow?.onRetake)
        retake()

        #expect(h.coordinator.phase == .setup(.pointer))
        #expect(h.coordinator.session?.target == target)
        #expect(h.inks.count == 2)
        let second = h.inks[1].frameDecorator
        #expect(decoratorPaints(second, target: frame, at: CGPoint(x: mid, y: setupY)))
        #expect(!decoratorPaints(second, target: frame, at: CGPoint(x: mid, y: recordedY)))
    }


    // MARK: - Key routing through AppKit (review r1 #3)

    /// A key as the window server delivers it: through `NSApp.sendEvent`, so
    /// local monitors run first and then the key window gets it.
    private func press(
        _ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow? = nil
    ) {
        let target = window ?? NSApp.keyWindow
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: target?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        )!
        NSApp.sendEvent(event)
    }

    /// Two pen strokes, at a third and two thirds of the height.
    private func drawTwoStrokes(in window: NSWindow, frame: CGRect) -> (CGFloat, CGFloat) {
        let low = frame.height / 3, high = frame.height * 2 / 3
        drag(in: window, from: CGPoint(x: 40, y: low), to: CGPoint(x: frame.width - 40, y: low))
        drag(in: window, from: CGPoint(x: 40, y: high), to: CGPoint(x: frame.width - 40, y: high))
        return (low, high)
    }

    @Test("Setup keys reach the session exactly once, whichever recording window has them")
    func setupKeysTakeOnePath() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let target = try areaTarget()
        let frame = target.frame
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        #expect(NSApp.keyWindow?.level == RecordingWindowLevel.setup) // the overlay owns Setup keys

        press("p", keyCode: kVK_ANSI_P)
        #expect(h.coordinator.phase == .setup(.tool(.pen)))
        let ink = try inkWindow()
        let (low, high) = drawTwoStrokes(in: ink, frame: frame)
        let decorator = try #require(h.inks.first).frameDecorator
        let mid = frame.width / 2

        // A click can make the ink panel key in Setup: its keys still take
        // the one Setup path (the overlay's monitor), never a second one.
        ink.makeKey()
        #expect(NSApp.keyWindow === ink)
        press("z", keyCode: kVK_ANSI_Z, modifiers: .command, to: ink)
        #expect(decoratorPaints(decorator, target: frame, at: CGPoint(x: mid, y: low)))
        #expect(!decoratorPaints(decorator, target: frame, at: CGPoint(x: mid, y: high))) // one undo, not two
        press("z", keyCode: kVK_ANSI_Z, modifiers: [.command, .shift], to: ink)
        #expect(decoratorPaints(decorator, target: frame, at: CGPoint(x: mid, y: high)))
        press("v", keyCode: kVK_ANSI_V, to: ink)
        #expect(h.coordinator.phase == .setup(.pointer))
        // The same Setup key on the overlay itself.
        let overlay: NSWindow = try #require(windows(at: RecordingWindowLevel.setup).first)
        press("o", keyCode: kVK_ANSI_O, to: overlay)
        #expect(h.coordinator.phase == .setup(.tool(.oval)))
    }

    @Test("Draw-mode keys go to the key ink panel once; V hands the keyboard back")
    func drawModeKeysTakeOnePath() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let target = try areaTarget()
        let frame = target.frame
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.record))
        h.coordinator.handle(.command(.toggleDrawMode))
        let ink = try inkWindow()
        #expect(NSApp.keyWindow === ink)

        press("o", keyCode: kVK_ANSI_O)
        #expect(h.coordinator.phase == .recording(.draw(.oval)))
        press("p", keyCode: kVK_ANSI_P)
        let (low, high) = drawTwoStrokes(in: ink, frame: frame)
        let decorator = try #require(h.inks.first).frameDecorator
        let mid = frame.width / 2
        press("z", keyCode: kVK_ANSI_Z, modifiers: .command)
        #expect(decoratorPaints(decorator, target: frame, at: CGPoint(x: mid, y: low)))
        #expect(!decoratorPaints(decorator, target: frame, at: CGPoint(x: mid, y: high)))
        // Setup-only keys do nothing here (no R/S/W while recording).
        press("s", keyCode: kVK_ANSI_S)
        press("r", keyCode: kVK_ANSI_R)
        #expect(h.coordinator.phase == .recording(.draw(.pen)))

        press("v", keyCode: kVK_ANSI_V)
        #expect(h.coordinator.phase == .recording(.interact))
        #expect(NSApp.keyWindow !== ink) // no Snappy window keeps the keyboard
        #expect(h.activations == 2)
    }

    @Test("Interact mode: letters, Esc, ⌫ and ⌘Z never change anything in Snappy")
    func interactModeKeysNeverReachSnappy() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let target = try areaTarget()
        let frame = target.frame
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.record))
        h.coordinator.handle(.command(.toggleDrawMode))
        let ink = try inkWindow()
        let (low, _) = drawTwoStrokes(in: ink, frame: frame)
        h.coordinator.handle(.command(.toggleDrawMode))
        #expect(h.coordinator.phase == .recording(.interact))
        let recordingLevels = [RecordingWindowLevel.setup, RecordingWindowLevel.ink, RecordingWindowLevel.chrome]
        let keyLevel = NSApp.keyWindow?.level
        #expect(keyLevel.map { !recordingLevels.contains($0) } ?? true)

        let keys: [(String, Int, NSEvent.ModifierFlags)] = [
            ("r", kVK_ANSI_R, []), ("s", kVK_ANSI_S, []), ("p", kVK_ANSI_P, []), ("q", kVK_ANSI_Q, []),
            ("v", kVK_ANSI_V, []), ("2", kVK_ANSI_2, []), ("\u{1B}", kVK_Escape, []), ("\u{7F}", kVK_Delete, []),
            ("z", kVK_ANSI_Z, .command),
        ]
        let chrome = try #require(windows(at: RecordingWindowLevel.chrome).first)
        for (characters, keyCode, modifiers) in keys {
            // Through the app (no Snappy window is key), and even straight at
            // the ink and chrome windows.
            press(characters, keyCode: keyCode, modifiers: modifiers)
            press(characters, keyCode: keyCode, modifiers: modifiers, to: ink)
            ink.sendEvent(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: ink.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: UInt16(keyCode)
            )!)
            press(characters, keyCode: keyCode, modifiers: modifiers, to: chrome)
            #expect(h.coordinator.phase == .recording(.interact), "\(characters)")
        }
        #expect(h.coordinator.phase == .recording(.interact))
        let decorator = try #require(h.inks.first).frameDecorator
        #expect(decoratorPaints(decorator, target: frame, at: CGPoint(x: frame.width / 2, y: low))) // nothing cleared or undone
        #expect(h.activations == 2)
    }

    // MARK: - Draw-mode hot key (review r1 #2)

    /// The toolbar's draw/interact toggle, as the real chrome shows it.
    private func drawModeButton() throws -> NSButton {
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
        }
        let all = windows(at: RecordingWindowLevel.chrome).compactMap(\.contentView).flatMap(buttons(in:))
        return try #require(all.first { $0.accessibilityLabel() == RecordingToolbarItem.drawMode.title })
    }

    @Test("A registered draw-mode hot key toggles, is advertised, and is released when the session ends")
    func registeredDrawModeHotKey() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.coordinator.beginSession(target: try areaTarget(), userApp: nil))
        let toggle = try #require(h.hotKeys.handlers[.toggleDrawMode])
        h.coordinator.handle(.command(.record))
        #expect(try drawModeButton().toolTip?.hasSuffix("(⌃⌥D)") == true)
        toggle()
        #expect(h.coordinator.phase == .recording(.draw(.pen)))
        #expect(h.notices.isEmpty)

        h.coordinator.stop()
        await until({ h.openWindow != nil }, "recording window")
        #expect(h.hotKeys.handlers[.toggleDrawMode] == nil)
        #expect(h.hotKeys.unregistrations == 1)
    }

    @Test("A draw-mode hot key another app owns: the person is told, the toolbar doesn't advertise it, the toggle still works")
    func refusedDrawModeHotKey() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        h.hotKeys.refused = [.toggleDrawMode]
        #expect(h.coordinator.beginSession(target: try areaTarget(), userApp: nil))
        #expect(h.notices == [UserFacingText.drawModeHotKeyUnavailable("⌃⌥D")])
        h.coordinator.handle(.command(.record))
        let button = try drawModeButton()
        #expect(button.toolTip == "Switch between drawing and using your app")
        _ = button.sendAction(button.action, to: button.target) // a click, without the click animation
        #expect(h.coordinator.phase == .recording(.draw(.pen)))
    }

    @Test("The draw-mode hot key is released on Cancel and on a failed start too")
    func drawModeHotKeyReleasedOnCancelAndFailure() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.coordinator.beginSession(target: try areaTarget(), userApp: nil))
        h.coordinator.handle(.command(.cancel))
        #expect(h.hotKeys.handlers[.toggleDrawMode] == nil)
        #expect(h.hotKeys.unregistrations == 1)

        h.failNextStart = true
        var errors = 0
        h.coordinator.onError = { _ in errors += 1 }
        #expect(h.coordinator.beginSession(target: try areaTarget(), userApp: nil))
        h.coordinator.handle(.command(.record))
        await until({ errors == 1 && !h.coordinator.isBusy }, "start failed, drained")
        #expect(h.hotKeys.handlers[.toggleDrawMode] == nil)
        #expect(h.hotKeys.unregistrations == 2)
    }

    // MARK: - Magic Pen

    /// A toolbar button of the real chrome, by its VoiceOver label.
    private func toolbarButton(_ item: RecordingToolbarItem) throws -> NSButton {
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
        }
        let all = windows(at: RecordingWindowLevel.chrome).compactMap(\.contentView).flatMap(buttons(in:))
        return try #require(all.first { $0.accessibilityLabel() == item.title })
    }

    @Test("⌃⌥P: the ink panel takes the mouse and keys without activating Snappy; strokes are Magic Pen ink; Esc gives everything back")
    func magicPenHotKeyDrawsFadingInk() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let target = try areaTarget()
        let frame = target.frame
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        #expect(h.hotKeys.combos[.toggleMagicPen] == .defaultMagicPen)
        let toggle = try #require(h.hotKeys.handlers[.toggleMagicPen])
        h.coordinator.handle(.command(.record))
        #expect(try toolbarButton(.magicPen).toolTip == "Draw fading ink (⌃⌥P)")
        let ink = try inkWindow()
        #expect(ink.ignoresMouseEvents)

        toggle()
        #expect(h.coordinator.phase == .recording(.magicPen(resume: nil)))
        #expect(NSApp.keyWindow === ink)
        #expect(!ink.ignoresMouseEvents)
        #expect(try toolbarButton(.magicPen).state == .on)
        #expect(try drawModeButton().state == .off)

        let (low, high) = drawTwoStrokes(in: ink, frame: frame)
        let compositor = try #require(h.inks.first?.frameDecorator as? RecordingCompositor)
        #expect(compositor.currentScene.strokes.count == 2)
        #expect(compositor.currentScene.strokes.allSatisfy { $0.isMagicPen && $0.fades && !$0.isSetup })
        let mid = frame.width / 2
        #expect(decoratorPaints(compositor, target: frame, at: CGPoint(x: mid, y: low)))

        // ⌘Z undoes one stroke; ] makes the next one thicker (persisted); F does nothing.
        press("z", keyCode: kVK_ANSI_Z, modifiers: .command)
        #expect(!decoratorPaints(compositor, target: frame, at: CGPoint(x: mid, y: high)))
        press("]", keyCode: kVK_ANSI_RightBracket)
        #expect(SettingsStore(defaults: h.defaults).recordingMagicPenWidth == .thick)
        press("f", keyCode: kVK_ANSI_F)
        #expect(h.coordinator.phase == .recording(.magicPen(resume: nil)))
        drag(in: ink, from: CGPoint(x: 40, y: high), to: CGPoint(x: frame.width - 40, y: high))
        #expect(compositor.currentScene.strokes.last?.width == .thick)

        press("\u{1B}", keyCode: kVK_Escape)
        #expect(h.coordinator.phase == .recording(.interact))
        #expect(NSApp.keyWindow !== ink)
        #expect(ink.ignoresMouseEvents)
        #expect(h.activations == 2)

        h.coordinator.stop()
        await until({ h.openWindow != nil }, "recording window")
        #expect(h.hotKeys.unregistrations(of: .toggleMagicPen) == 1)
        #expect(h.hotKeys.handlers[.toggleMagicPen] == nil)
    }

    @Test("Magic Pen from draw mode toggles back to that tool; the toolbar button does what ⌃⌥P does")
    func magicPenFromDrawModeAndTheToolbar() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.coordinator.beginSession(target: try areaTarget(), userApp: nil))
        h.coordinator.handle(.command(.record))
        h.coordinator.handle(.command(.tool(.box)))
        let ink = try inkWindow()
        #expect(NSApp.keyWindow === ink)
        let button = try toolbarButton(.magicPen)
        _ = button.sendAction(button.action, to: button.target)
        #expect(h.coordinator.phase == .recording(.magicPen(resume: .box)))
        #expect(NSApp.keyWindow === ink, "kept between draw mode and Magic Pen")
        _ = button.sendAction(button.action, to: button.target)
        #expect(h.coordinator.phase == .recording(.draw(.box)))
        #expect(h.activations == 1, "never handed back in between")
    }

    @Test("A Magic Pen combo that is taken (here: the draw-mode one) is not registered; the person is told, the button still works")
    func magicPenHotKeyClash() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        SettingsStore(defaults: h.defaults).recordingDrawModeHotKey = .defaultMagicPen
        #expect(h.coordinator.beginSession(target: try areaTarget(), userApp: nil))
        #expect(h.hotKeys.handlers[.toggleMagicPen] == nil)
        #expect(h.hotKeys.combos[.toggleDrawMode] == .defaultMagicPen)
        #expect(h.notices == [UserFacingText.magicPenHotKeyUnavailable("⌃⌥P")])
        h.coordinator.handle(.command(.record))
        let button = try toolbarButton(.magicPen)
        #expect(button.toolTip == "Draw fading ink")
        _ = button.sendAction(button.action, to: button.target)
        #expect(h.coordinator.phase == .recording(.magicPen(resume: nil)))
    }

    @Test("A Magic Pen hot key another app owns gets its own banner, next to a refused draw-mode one")
    func bothHotKeysRefused() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        h.hotKeys.refused = [.toggleDrawMode, .toggleMagicPen]
        #expect(h.coordinator.beginSession(target: try areaTarget(), userApp: nil))
        #expect(h.notices == [
            UserFacingText.drawModeHotKeyUnavailable("⌃⌥D"), UserFacingText.magicPenHotKeyUnavailable("⌃⌥P"),
        ])
        #expect(Set(h.notices.map(\.title)).count == 2, "distinct titles → distinct banner identifiers")
    }

    // MARK: - Menu bar clock (Tefa 2026-10-09)

    @Test("The capture start is reported once, when the pipeline runs — the clock the menu bar and toolbar share")
    func captureStartIsReportedOnce() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        var starts: [ContinuousClock.Instant] = []
        h.coordinator.onCaptureStart = { starts.append($0) }
        let before = ContinuousClock.now
        #expect(h.coordinator.beginSession(target: try areaTarget(), userApp: nil))
        #expect(starts.isEmpty) // not in Setup
        h.coordinator.handle(.command(.record))
        await until({ starts.count == 1 }, "reported after start")
        #expect(try #require(starts.first) >= before)
        h.coordinator.handle(.command(.toggleDrawMode))
        h.coordinator.handle(.command(.toggleDrawMode))
        h.coordinator.stop()
        await until({ h.openWindow != nil }, "recording window")
        #expect(starts.count == 1)
    }
}

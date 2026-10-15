import CoreGraphics
import Testing
@testable import Snappy

@Suite("WindowSnapCandidates")
struct WindowSnapPickerTests {
    /// Primary 1440 × 900; a secondary 1920 × 1080 to its right whose top is
    /// 180 pt higher (AppKit y 0…1080 → CG y −180…900).
    private static let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    private static let primaryHeight: CGFloat = 900
    private static let ownPID: pid_t = 42

    private static func info(
        _ id: CGWindowID, _ cgFrame: CGRect, layer: Int = 0, onScreen: Bool = true, pid: pid_t? = 7, app: String? = "App"
    ) -> SnapWindowInfo {
        SnapWindowInfo(windowID: id, cgFrame: cgFrame, windowLayer: layer, isOnScreen: onScreen, processID: pid, appName: app)
    }

    private func candidates(_ infos: [SnapWindowInfo], on screen: CGRect = primary) -> [SnapWindow] {
        WindowSnapCandidates.candidates(
            from: infos, ownPID: Self.ownPID, screenFrame: screen, primaryDisplayHeight: Self.primaryHeight
        )
    }

    // MARK: - Filtering

    @Test func onlyNormalOnScreenForeignWindowsOfUsableSizeOnTheDisplay() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let infos = [
            Self.info(1, frame),
            Self.info(2, frame, layer: 25), // menu bar, Dock, panels
            Self.info(3, frame, onScreen: false),
            Self.info(4, frame, pid: Self.ownPID), // Snappy's own ink / chrome
            Self.info(5, CGRect(x: 100, y: 100, width: 39, height: 300)), // too small
            Self.info(6, CGRect(x: 2000, y: 100, width: 400, height: 300)), // other display
            Self.info(7, frame, pid: nil), // no owning app: still a window
        ]
        #expect(candidates(infos).map(\.windowID) == [1, 7])
    }

    @Test func frontToBackOrderIsKept() {
        let infos = (1...5).map { Self.info(CGWindowID($0), CGRect(x: 10 * $0, y: 10, width: 300, height: 300)) }
        #expect(candidates(infos).map(\.windowID) == [1, 2, 3, 4, 5])
    }

    @Test func aWindowSpanningTwoDisplaysIsOfferedOnBoth() {
        let spanning = Self.info(1, CGRect(x: 1300, y: 100, width: 400, height: 300))
        #expect(candidates([spanning], on: Self.primary).count == 1)
        #expect(candidates([spanning], on: Self.secondary).count == 1)
    }

    // MARK: - SCK → AppKit conversion

    /// SCK frames are top-left/y-down from the primary display; the
    /// candidates are AppKit global (bottom-left/y-up).
    @Test func framesAreConvertedToAppKitGlobal() {
        let window = candidates([Self.info(1, CGRect(x: 100, y: 50, width: 400, height: 300))])[0]
        #expect(window.frame == CGRect(x: 100, y: 550, width: 400, height: 300))
    }

    @Test func aWindowAboveThePrimaryDisplayHasANegativeCGOrigin() {
        // Top of the secondary display: CG y = 900 − 1080 = −180.
        let window = candidates([Self.info(1, CGRect(x: 1500, y: -180, width: 400, height: 300))], on: Self.secondary)[0]
        #expect(window.frame == CGRect(x: 1500, y: 780, width: 400, height: 300))
        #expect(Self.secondary.maxY == window.frame.maxY)
    }

    // MARK: - Hover

    @Test func theFrontMostWindowUnderThePointerWins() {
        let list = candidates([
            Self.info(1, CGRect(x: 200, y: 200, width: 200, height: 200)), // front
            Self.info(2, CGRect(x: 100, y: 100, width: 600, height: 600)), // behind
        ])
        // AppKit: CG y 200…400 → 500…700.
        #expect(WindowSnapCandidates.window(at: CGPoint(x: 300, y: 600), in: list)?.windowID == 1)
        #expect(WindowSnapCandidates.window(at: CGPoint(x: 150, y: 600), in: list)?.windowID == 2)
        #expect(WindowSnapCandidates.window(at: CGPoint(x: 1000, y: 50), in: list) == nil)
    }

    // MARK: - Targets

    private static let window = SnapWindow(windowID: 9, frame: CGRect(x: 1300, y: 100, width: 400, height: 300), appName: "App")

    /// S: the window's area — the region on this display, as an area.
    @Test func snapAreaIsTheWindowsRegionClampedToTheDisplay() {
        let target = WindowSnapCandidates.target(for: Self.window, kind: .area, screenFrame: Self.primary, displayID: 3)
        #expect(target == .area(globalRect: CGRect(x: 1300, y: 100, width: 140, height: 300), displayID: 3))
    }

    @Test func snapAreaOfAWindowSliverGrowsToTheMinimumSize() {
        let sliver = SnapWindow(windowID: 9, frame: CGRect(x: 1420, y: 100, width: 400, height: 300), appName: nil)
        let target = WindowSnapCandidates.target(for: sliver, kind: .area, screenFrame: Self.primary, displayID: 3)
        #expect(target.frame == CGRect(x: 1400, y: 100, width: SetupGeometry.minSize.width, height: 300))
    }

    /// W: the window itself, at its full frame, on the target display.
    @Test func snapWindowIsTheWindowItself() {
        let target = WindowSnapCandidates.target(for: Self.window, kind: .window, screenFrame: Self.primary, displayID: 3)
        #expect(target == .window(windowID: 9, frame: Self.window.frame, displayID: 3))
    }
}

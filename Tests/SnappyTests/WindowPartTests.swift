import AppKit
import Carbon.HIToolbox
import Testing
@testable import Snappy

// MARK: - Fake trees

/// One box of a fake accessibility tree. Frames are given **window-local,
/// top-left** (like reading a screenshot) and converted to AppKit global by
/// `FakeTree`, so the trees below read like the apps they imitate.
struct Box {
    var role: String
    var subrole: String?
    var label: String?
    var frame: CGRect
    var children: [Box] = []

    init(_ role: String, sub subrole: String? = nil, label: String? = nil, _ x: CGFloat, _ y: CGFloat,
         _ width: CGFloat, _ height: CGFloat, _ children: [Box] = []) {
        self.role = role
        self.subrole = subrole
        self.label = label
        frame = CGRect(x: x, y: y, width: width, height: height)
        self.children = children
    }
}

/// `WindowPartTree` over nested boxes: the chain at a point is the path of
/// top-most (last) children containing it — what an AX hit test plus the
/// walk up to the window return. One handle per box, like the live tree.
@MainActor
final class FakeTree: WindowPartTree {
    let window: SnapWindow
    let root: [Box]
    var webContentIsAppUI: Bool
    /// The app answers nothing (no tree, a timeout).
    var isSilent = false
    /// Answers wait for `answer()` instead of coming at once (the live tree
    /// answers from its AX executor, later).
    var defersAnswers = false
    private(set) var waiting: [@MainActor () -> Void] = []
    private(set) var handles: [String: WindowPartElement] = [:]

    init(window: CGRect, appName: String? = "App", webContentIsAppUI: Bool = false, _ root: [Box]) {
        self.window = SnapWindow(windowID: 42, frame: window, appName: appName, processID: 4242)
        self.root = root
        self.webContentIsAppUI = webContentIsAppUI
    }

    /// Window-local top-left → AppKit global.
    func global(_ local: CGRect) -> CGRect {
        CGRect(x: window.frame.minX + local.minX, y: window.frame.maxY - local.maxY, width: local.width, height: local.height)
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: window.frame.minX + x, y: window.frame.maxY - y)
    }

    func chain(at point: CGPoint, in window: SnapWindow) -> WindowPartChain? {
        guard !isSilent, window == self.window else { return nil }
        var nodes: [WindowPartNode] = []
        var children = root
        var path = ""
        while let index = children.lastIndex(where: { global($0.frame).contains(point) }) {
            let box = children[index]
            path += "/\(index)"
            nodes.append(WindowPartNode(
                role: box.role, subrole: box.subrole, label: box.label, frame: global(box.frame),
                hasChildren: !box.children.isEmpty, element: handle(path)
            ))
            children = box.children
        }
        return WindowPartChain(nodes: nodes, webContentIsAppUI: webContentIsAppUI)
    }

    func requestChain(
        at point: CGPoint, in window: SnapWindow, completion: @escaping @MainActor (WindowPartChain?) -> Void
    ) {
        let chain = chain(at: point, in: window)
        guard defersAnswers else { return completion(chain) }
        waiting.append { completion(chain) }
    }

    /// Delivers the deferred answers, oldest first.
    func answer() {
        let answers = waiting
        waiting = []
        for answer in answers { answer() }
    }

    /// The handle of the box at `path` ("/0/1"), as the chain hands it out.
    func handle(_ path: String) -> WindowPartElement {
        if let known = handles[path] { return known }
        let handle = WindowPartElement(processID: 4242) { nil }
        handles[path] = handle
        return handle
    }

    func model() -> WindowPartModel { WindowPartModel(tree: self) }

    /// The pick at a window-local point (automatic, no override).
    func pick(_ x: CGFloat, _ y: CGFloat) -> WindowPartLevel? {
        let model = model()
        model.pointerMoved(to: point(x, y), over: window)
        return model.current
    }

    func levels(_ x: CGFloat, _ y: CGFloat) -> [String] {
        WindowPartSelection.levels(window: window.frame, chain: chain(at: point(x, y), in: window), at: point(x, y))
            .map(\.name)
    }
}

// MARK: - Trees like the real apps (measured live, 2026-10-11)

/// Chrome / Brave, 1200 × 800: tab strip in the title bar row, a 40 pt
/// toolbar, then the page (`AXScrollArea` › `AXWebArea`) whose own
/// landmarks belong to the page.
@MainActor func chromeLike(webTree: Bool = true) -> FakeTree {
    let page: [Box] = webTree ? [
        Box("AXWebArea", label: "Some article — Brave", 0, 81, 1200, 719, [
            Box("AXGroup", 0, 81, 1185, 719, [
                Box("AXGroup", sub: "AXLandmarkMain", 300, 81, 700, 719, [
                    Box("AXGroup", sub: "AXLandmarkRegion", label: "Comments", 300, 81, 700, 719, [
                        Box("AXGroup", 300, 200, 700, 96, [Box("AXStaticText", 320, 220, 300, 16)]),
                    ]),
                ]),
            ]),
        ]),
    ] : []
    return FakeTree(window: CGRect(x: 100, y: 100, width: 1200, height: 800), appName: "Brave Browser", [
        Box("AXGroup", 0, 0, 1200, 800, [
            Box("AXGroup", 0, 0, 1200, 800, [
                Box("AXGroup", 0, 81, 1200, 719, [
                    Box("AXGroup", 0, 81, 1200, 719, [Box("AXScrollArea", 0, 81, 1200, 719, page)]),
                ]),
                Box("AXGroup", 0, 40, 1200, 41, [
                    Box("AXToolbar", 0, 40, 1200, 40, [
                        Box("AXButton", label: "Back", 4, 46, 28, 28),
                        Box("AXTextField", label: "Address and search bar", 200, 46, 700, 28),
                    ]),
                ]),
                Box("AXGroup", 80, 0, 1120, 40, [
                    Box("AXTabGroup", 80, 0, 1000, 40, [Box("AXRadioButton", sub: "AXTabButton", 80, 0, 200, 40)]),
                ]),
            ]),
        ]),
    ])
}

/// Safari, 1200 × 800, sidebar shown: unified 52 pt toolbar; a split view
/// with the sidebar outline and the tab view, whose web area is the whole
/// *document* (4000 pt tall) inside the viewport's scroll area.
@MainActor func safariLike() -> FakeTree {
    FakeTree(window: CGRect(x: 0, y: 0, width: 1200, height: 800), appName: "Safari", [
        Box("AXToolbar", 0, 0, 1200, 52),
        Box("AXSplitGroup", 0, 52, 1200, 748, [
            Box("AXScrollArea", 0, 52, 250, 748, [
                Box("AXOutline", label: "Sidebar", 0, 52, 250, 1400, [Box("AXRow", 0, 80, 250, 24)]),
            ]),
            Box("AXTabGroup", 251, 52, 949, 748, [
                Box("AXGroup", 251, 52, 949, 748, [
                    Box("AXScrollArea", 251, 52, 949, 748, [
                        Box("AXWebArea", label: "Apple", 251, 52, 934, 4000, [
                            Box("AXGroup", sub: "AXLandmarkMain", 400, 52, 600, 4000, [Box("AXLink", 420, 300, 80, 20)]),
                        ]),
                    ]),
                ]),
            ]),
        ]),
    ])
}

/// VS Code / Claude (Electron), 1400 × 900: the whole UI is one web area;
/// panes are ARIA landmarks or labelled trees.
@MainActor func vsCodeLike(webContentIsAppUI: Bool = true, nativeTitleBar: Bool = false) -> FakeTree {
    let top: CGFloat = nativeTitleBar ? 28 : 0
    return FakeTree(window: CGRect(x: 0, y: 0, width: 1400, height: 900), appName: "Code",
                    webContentIsAppUI: webContentIsAppUI, [
        Box("AXGroup", 0, 0, 1400, 900, [
            Box("AXGroup", 0, top, 1400, 900 - top, [
                Box("AXWebArea", label: "main.swift — Snappy", 0, top, 1400, 900 - top, [
                    Box("AXGroup", 0, top, 1400, 900 - top, [
                        Box("AXGroup", 0, top, 48, 878 - top), // activity bar
                        Box("AXGroup", 48, top + 35, 300, 843 - top, [
                            Box("AXOutline", label: "Files Explorer", 48, top + 80, 300, 700, [
                                Box("AXRow", 48, top + 100, 300, 22),
                            ]),
                        ]),
                        Box("AXGroup", sub: "AXLandmarkMain", 348, top + 35, 1052, 600, [
                            Box("AXGroup", 348, top + 35, 1052, 35), // tabs
                            Box("AXGroup", 348, top + 70, 1052, 565, [Box("AXTextArea", 348, top + 70, 1052, 565)]),
                        ]),
                        Box("AXGroup", 348, top + 635, 1052, 243 - top, [Box("AXTextArea", 348, top + 640, 1052, 200)]),
                    ]),
                ]),
            ]),
        ]),
    ])
}

/// Many nested boxes that are the same box give or take a border or a
/// scroll bar — one level.
@MainActor func nestedLike() -> FakeTree {
    FakeTree(window: CGRect(x: 0, y: 0, width: 1000, height: 700), [
        Box("AXGroup", 0, 0, 1000, 700, [
            Box("AXScrollArea", 50, 60, 900, 600, [
                Box("AXScrollArea", label: "Inner", 51, 61, 898, 598, [
                    Box("AXTable", 51, 61, 883, 598, [
                        Box("AXList", 52, 62, 880, 590, [Box("AXCell", 60, 100, 200, 20)]),
                    ]),
                ]),
            ]),
        ]),
    ])
}

// MARK: - Tests

@MainActor
@Suite("Window parts — selection over fake trees")
struct WindowPartSelectionTests {
    // MARK: Chrome-like

    @Test func chromePageIsOnePartItsLandmarksAreNot() {
        let tree = chromeLike()
        #expect(tree.levels(330, 225) == ["Window", "Web page"])
        let pick = tree.pick(330, 225)
        #expect(pick?.name == "Web page")
        #expect(pick?.frame == tree.global(CGRect(x: 0, y: 81, width: 1200, height: 719)))
        // The outermost part of the collapsed run: the page's scroll area
        // (the viewport), not the web area inside it.
        #expect(pick?.element === tree.handle("/0/0/0/0/0"))
    }

    @Test func chromeTabStripAndToolbarPickTheWholeWindow() {
        let tree = chromeLike()
        #expect(tree.pick(300, 34)?.isWholeWindow == true) // tab strip, below the title bar band
        #expect(tree.pick(400, 60)?.isWholeWindow == true) // address field: toolbar is only 40 pt tall
        #expect(tree.levels(400, 60) == ["Window"])
    }

    @Test func titleBarAndEdgeBandPickTheWholeWindowButNarrowingStillWorks() {
        let tree = chromeLike()
        for (x, y) in [(8.0, 400.0), (1195.0, 400.0), (600.0, 790.0), (600.0, 10.0)] {
            #expect(tree.pick(x, y)?.isWholeWindow == true, "\(x), \(y)")
        }
        let model = tree.model()
        let edge = tree.point(8, 400)
        model.pointerMoved(to: edge, over: tree.window)
        #expect(model.part == nil)
        let stepped1 = model.step(.narrow, at: edge)
        #expect(stepped1)
        #expect(model.part?.name == "Web page")
    }

    @Test func freshChromiumWithoutAWebTreeStillOffersThePageArea() {
        let tree = chromeLike(webTree: false)
        let pick = tree.pick(330, 225)
        #expect(pick?.name == "Scroll area")
        #expect(pick?.frame == tree.global(CGRect(x: 0, y: 81, width: 1200, height: 719)))
        let chain = tree.chain(at: tree.point(330, 225), in: tree.window)
        #expect(!WindowPartSelection.isTreeEmpty(chain, window: tree.window.frame))
    }

    // MARK: Safari-like

    @Test func safariPageIsClippedToTheViewportAndTheSidebarIsItsOwnPart() {
        let tree = safariLike()
        #expect(tree.levels(600, 300) == ["Window", "Split view", "Web page"])
        #expect(tree.pick(600, 300)?.frame == tree.global(CGRect(x: 251, y: 52, width: 949, height: 748)))
        let sidebar = tree.pick(100, 400)
        #expect(sidebar?.name == "Sidebar")
        #expect(sidebar?.frame == tree.global(CGRect(x: 0, y: 52, width: 250, height: 748)))
    }

    @Test func upWidensFromThePageToPagePlusSidebarThenTheWindow() {
        let tree = safariLike()
        let model = tree.model()
        let point = tree.point(600, 300)
        model.pointerMoved(to: point, over: tree.window)
        #expect(model.part?.name == "Web page")
        let stepped2 = model.step(.widen, at: point)
        #expect(stepped2)
        #expect(model.part?.name == "Split view")
        let stepped3 = model.step(.widen, at: point)
        #expect(stepped3)
        #expect(model.part == nil)
        #expect(model.current?.isWholeWindow == true)
        let stepped4 = model.step(.widen, at: point)
        #expect(!stepped4, "the whole window is the widest")
        let stepped5 = model.step(.narrow, at: point)
        #expect(stepped5)
        let stepped6 = model.step(.narrow, at: point)
        #expect(stepped6)
        let stepped7 = model.step(.narrow, at: point)
        #expect(!stepped7, "the page is the narrowest")
    }

    // MARK: VS Code-like (Electron)

    @Test func electronPanesAreLandmarksAndLabelledTrees() {
        let tree = vsCodeLike()
        #expect(tree.pick(200, 400)?.name == "Files Explorer")
        #expect(tree.pick(200, 400)?.frame == tree.global(CGRect(x: 48, y: 80, width: 300, height: 700)))
        #expect(tree.pick(800, 300)?.name == "Main content")
        #expect(tree.pick(800, 300)?.frame == tree.global(CGRect(x: 348, y: 35, width: 1052, height: 600)))
        // The panel has no landmark: the whole window (no error).
        #expect(tree.pick(800, 750)?.isWholeWindow == true)
    }

    /// A web area filling the window is the app's UI even when the app isn't
    /// recognised as Electron (a WebKit-based app shell).
    @Test func aWindowFillingWebAreaIsLookedIntoWithoutTheElectronFlag() {
        let tree = vsCodeLike(webContentIsAppUI: false)
        #expect(tree.pick(800, 300)?.name == "Main content")
    }

    /// Electron under a native title bar: the web area is a part ("Web
    /// page"), and its landmarks are parts below it.
    @Test func electronWithANativeTitleBarHasThePageThenItsPanes() {
        let tree = vsCodeLike(nativeTitleBar: true)
        #expect(tree.levels(800, 300) == ["Window", "Web page", "Main content"])
        // Without the Electron flag that web area is a browser page: atomic.
        let browser = vsCodeLike(webContentIsAppUI: false, nativeTitleBar: true)
        #expect(browser.levels(800, 300) == ["Window", "Web page"])
    }

    // MARK: Nested, tiny, roles

    @Test func nestedNearIdenticalBoxesCollapseIntoOneLevelWithTheBestName() {
        let tree = nestedLike()
        #expect(tree.levels(100, 200) == ["Window", "Inner"])
        let pick = tree.pick(100, 200)
        #expect(pick?.frame == tree.global(CGRect(x: 50, y: 60, width: 900, height: 600)))
        #expect(pick?.element === tree.handle("/0/0"))
    }

    @Test func equalRanksNameTheLevelAfterTheInnermost() {
        let tree = FakeTree(window: CGRect(x: 0, y: 0, width: 1000, height: 700), [
            Box("AXScrollArea", 50, 60, 900, 600, [Box("AXTable", 50, 60, 900, 600)]),
        ])
        #expect(tree.levels(100, 200) == ["Window", "Table"])
    }

    @Test func tinyElementsAreNeverPicked() {
        let tree = FakeTree(window: CGRect(x: 0, y: 0, width: 1000, height: 700), [
            Box("AXScrollArea", 100, 100, 119, 300, [Box("AXButton", 110, 110, 20, 20)]),
            Box("AXScrollArea", 300, 100, 120, 80, [Box("AXButton", 310, 110, 20, 20)]),
            Box("AXScrollArea", 500, 100, 400, 79),
        ])
        #expect(tree.pick(115, 115)?.isWholeWindow == true)
        #expect(tree.pick(315, 115)?.name == "Scroll area", "exactly the minimum size counts")
        #expect(tree.pick(600, 120)?.isWholeWindow == true)
    }

    @Test func onlyContainerRolesArePartsAndGroupsOnlyAsPanesOrLandmarks() {
        let tree = FakeTree(window: CGRect(x: 0, y: 0, width: 1000, height: 700), [
            Box("AXSplitGroup", 0, 0, 1000, 700, [
                Box("AXGroup", 0, 0, 300, 700, [Box("AXGroup", 20, 100, 260, 300)]),
                Box("AXGroup", 301, 0, 699, 700, [
                    Box("AXList", sub: "AXCollectionList", label: "icon view", 320, 100, 600, 500, [
                        Box("AXList", sub: "AXSectionList", 330, 110, 500, 300, [Box("AXImage", 340, 120, 64, 64)]),
                    ]),
                ]),
            ]),
            Box("AXTextArea", 600, 650, 300, 40),
        ])
        // A split view's pane is a part; a plain group inside it isn't.
        #expect(tree.levels(100, 200) == ["Window", "Pane"])
        // A list is, its sections aren't; its label names it.
        #expect(tree.levels(350, 130) == ["Window", "Pane", "Icon view"])
    }

    @Test func aNodeThatDoesNotContainThePointerIsSkipped() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let chain = WindowPartChain(nodes: [
            WindowPartNode(role: "AXScrollArea", frame: CGRect(x: 500, y: 100, width: 400, height: 400)),
        ])
        let levels = WindowPartSelection.levels(window: window, chain: chain, at: CGPoint(x: 100, y: 300))
        #expect(levels.map(\.name) == ["Window"])
    }

    @Test func aFramelessWrapperNeitherClipsNorCounts() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let chain = WindowPartChain(nodes: [
            WindowPartNode(role: "AXGroup", frame: .zero),
            WindowPartNode(role: "AXScrollArea", frame: CGRect(x: 100, y: 100, width: 400, height: 400)),
        ])
        let levels = WindowPartSelection.levels(window: window, chain: chain, at: CGPoint(x: 200, y: 200))
        #expect(levels.map(\.name) == ["Window", "Scroll area"])
    }

    // MARK: No tree

    @Test func withoutATreeOnlyTheWholeWindow() {
        let tree = safariLike()
        let model = WindowPartModel(tree: nil)
        model.pointerMoved(to: tree.point(600, 300), over: tree.window)
        #expect(model.current?.isWholeWindow == true)
        #expect(model.part == nil)
        let stepped8 = model.step(.narrow, at: tree.point(600, 300))
        #expect(!stepped8)

        tree.isSilent = true
        #expect(tree.pick(600, 300)?.isWholeWindow == true)
    }

    @Test func overNoWindowThereIsNoPick() {
        let model = safariLike().model()
        model.pointerMoved(to: CGPoint(x: 5000, y: 5000), over: nil)
        #expect(model.current == nil)
        #expect(model.part == nil)
    }

    @Test func aTreeForAnotherWindowGivesTheWholeWindow() {
        let tree = safariLike()
        let model = tree.model()
        let other = SnapWindow(windowID: 7, frame: tree.window.frame, appName: "Safari", processID: 4242)
        model.pointerMoved(to: tree.point(600, 300), over: other)
        #expect(model.current?.isWholeWindow == true)
    }

    // MARK: Hidden trees (Q40)

    @Test func treeIsEmptyOnlyWhenTheHitStopsAtAChildlessWindowSizedBox() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let hidden = WindowPartChain(nodes: [
            WindowPartNode(role: "AXGroup", frame: window),
            WindowPartNode(role: "AXWebArea", frame: window.insetBy(dx: 1, dy: 1), hasChildren: false),
        ])
        #expect(WindowPartSelection.isTreeEmpty(hidden, window: window))
        #expect(WindowPartSelection.isTreeEmpty(nil, window: window))
        #expect(WindowPartSelection.isTreeEmpty(WindowPartChain(nodes: []), window: window))
        let populated = WindowPartChain(nodes: [WindowPartNode(role: "AXWebArea", frame: window, hasChildren: true)])
        #expect(!WindowPartSelection.isTreeEmpty(populated, window: window))
        let smallLeaf = WindowPartChain(nodes: [
            WindowPartNode(role: "AXButton", frame: CGRect(x: 10, y: 10, width: 30, height: 30), hasChildren: false),
        ])
        #expect(!WindowPartSelection.isTreeEmpty(smallLeaf, window: window))
    }

    // MARK: Element identity

    @Test func theSamePartUnderAMovingPointerIsTheSameTarget() {
        let tree = chromeLike()
        let model = tree.model()
        model.pointerMoved(to: tree.point(330, 225), over: tree.window)
        let first = model.part
        model.pointerMoved(to: tree.point(900, 600), over: tree.window)
        #expect(model.part == first)
        #expect(model.part?.element === first?.element)
    }
}

/// The live tree answers later, from its AX executor (finding 1 of the
/// second V2 review): the model keeps the pick until the latest answer
/// arrives and drops stale ones.
@MainActor
@Suite("Window parts — asynchronous answers")
struct WindowPartAsyncModelTests {
    @Test func aNewWindowIsPickedWholeAtOnceItsPartWhenTheTreeAnswers() {
        let tree = chromeLike()
        tree.defersAnswers = true
        let model = tree.model()
        var changes = 0
        model.onChange = { changes += 1 }
        model.pointerMoved(to: tree.point(330, 225), over: tree.window)
        #expect(model.current?.isWholeWindow == true, "the window needs no AX")
        #expect(changes == 0)
        tree.answer()
        #expect(model.part?.name == "Web page")
        #expect(changes == 1)
    }

    @Test func thePickStaysUntilTheLatestAnswerArrivesAndStaleAnswersAreDropped() {
        let tree = vsCodeLike()
        let model = tree.model()
        let sidebar = tree.point(150, 400)
        let editor = tree.point(900, 400)
        model.pointerMoved(to: sidebar, over: tree.window)
        let first = model.part
        #expect(first != nil)

        tree.defersAnswers = true
        var changes = 0
        model.onChange = { changes += 1 }
        model.pointerMoved(to: editor, over: tree.window)
        model.pointerMoved(to: sidebar, over: tree.window)
        #expect(model.part == first, "kept while the tree hasn't answered")
        #expect(tree.waiting.count == 2)
        tree.answer() // the editor answer is stale, the sidebar one is the latest
        #expect(model.part == first)
        #expect(changes == 1)
    }

    @Test func anAnswerForAWindowThePointerLeftIsDropped() {
        let tree = chromeLike()
        tree.defersAnswers = true
        let model = tree.model()
        model.pointerMoved(to: tree.point(330, 225), over: tree.window)
        model.pointerMoved(to: CGPoint(x: 5000, y: 5000), over: nil)
        tree.answer()
        #expect(model.current == nil)
    }

    @Test func aResetDropsWhatIsStillComing() {
        let tree = chromeLike()
        tree.defersAnswers = true
        let model = tree.model()
        model.pointerMoved(to: tree.point(330, 225), over: tree.window)
        model.reset()
        tree.answer()
        #expect(model.current == nil)
    }
}

@MainActor
@Suite("Window parts — override, scroll, keys")
struct WindowPartOverrideTests {
    @Test func movingThePointerGoesBackToTheAutomaticPick() {
        let tree = safariLike()
        let model = tree.model()
        let start = tree.point(600, 300)
        model.pointerMoved(to: start, over: tree.window)
        model.step(.widen, at: start)
        #expect(model.part?.name == "Split view")
        // A hand resting on the mouse: the override holds.
        model.pointerMoved(to: CGPoint(x: start.x + 3, y: start.y - 2), over: tree.window)
        #expect(model.part?.name == "Split view")
        // A real move: automatic again.
        model.pointerMoved(to: CGPoint(x: start.x + 20, y: start.y), over: tree.window)
        #expect(model.part?.name == "Web page")
    }

    @Test func anotherWindowStartsOver() {
        let tree = safariLike()
        let model = tree.model()
        let point = tree.point(600, 300)
        model.pointerMoved(to: point, over: tree.window)
        model.step(.widen, at: point)
        let other = SnapWindow(windowID: 8, frame: tree.window.frame, appName: nil, processID: 1)
        model.pointerMoved(to: point, over: other)
        model.pointerMoved(to: point, over: tree.window)
        #expect(model.part?.name == "Web page")
    }

    @Test func pickingClampsAnOverrideToFewerLevels() {
        var picking = WindowPartPicking()
        let window = WindowPartLevel.window(CGRect(x: 0, y: 0, width: 100, height: 100))
        let part = WindowPartLevel(frame: CGRect(x: 0, y: 0, width: 50, height: 50), name: "Pane")
        picking.update(levels: [window, part, part], automatic: 2, at: .zero)
        #expect(picking.index == 2)
        picking.step(.widen, at: .zero)
        picking.step(.narrow, at: .zero)
        picking.update(levels: [window], automatic: 0, at: .zero)
        #expect(picking.index == 0)
        #expect(picking.current == window)
    }

    @Test func scrollWheelNotchesStepOnceEach() {
        var stepper = WindowPartScrollStepper()
        let steps1 = stepper.steps(deltaY: 1, isPrecise: false, isMomentum: false)
        #expect(steps1 == [.widen])
        let steps2 = stepper.steps(deltaY: -3, isPrecise: false, isMomentum: false)
        #expect(steps2 == [.narrow])
        let steps3 = stepper.steps(deltaY: 0, isPrecise: false, isMomentum: false)
        #expect(steps3.isEmpty)
    }

    @Test func trackpadDeltasAddUpAndADirectionChangeStartsOver() {
        var stepper = WindowPartScrollStepper()
        let step = WindowPartScrollStepper.stepDistance
        let steps4 = stepper.steps(deltaY: step / 2, isPrecise: true, isMomentum: false)
        #expect(steps4.isEmpty)
        let steps5 = stepper.steps(deltaY: step / 2, isPrecise: true, isMomentum: false)
        #expect(steps5 == [.widen])
        let steps6 = stepper.steps(deltaY: step * 2.5, isPrecise: true, isMomentum: false)
        #expect(steps6 == [.widen, .widen])
        // Half a step left over, then the other way: starts from zero.
        let steps7 = stepper.steps(deltaY: -step * 0.75, isPrecise: true, isMomentum: false)
        #expect(steps7.isEmpty)
        let steps8 = stepper.steps(deltaY: -step * 0.25, isPrecise: true, isMomentum: false)
        #expect(steps8 == [.narrow])
    }

    @Test func momentumIsIgnored() {
        var stepper = WindowPartScrollStepper()
        let steps9 = stepper.steps(deltaY: 500, isPrecise: true, isMomentum: true)
        #expect(steps9.isEmpty)
    }

    @Test func modelScrollStepsThroughTheLevels() {
        let tree = safariLike()
        let model = tree.model()
        let point = tree.point(600, 300)
        model.pointerMoved(to: point, over: tree.window)
        let scrolled1 = model.scrolled(deltaY: 3, isPrecise: false, isMomentum: false, at: point)
        #expect(scrolled1)
        #expect(model.part?.name == "Split view")
        let scrolled2 = model.scrolled(deltaY: -1, isPrecise: false, isMomentum: false, at: point)
        #expect(scrolled2)
        #expect(model.part?.name == "Web page")
        let scrolled3 = model.scrolled(deltaY: -1, isPrecise: false, isMomentum: false, at: point)
        #expect(!scrolled3)
    }

    @Test func upAndDownArrowsAreTheOnlyStepKeys() {
        #expect(WindowPartStep(keyCode: UInt16(kVK_UpArrow), modifiers: []) == .widen)
        #expect(WindowPartStep(keyCode: UInt16(kVK_DownArrow), modifiers: []) == .narrow)
        #expect(WindowPartStep(keyCode: UInt16(kVK_UpArrow), modifiers: [.numericPad, .function]) == .widen)
        #expect(WindowPartStep(keyCode: UInt16(kVK_DownArrow), modifiers: .capsLock) == .narrow)
        for modifiers: NSEvent.ModifierFlags in [.shift, .option, .command, .control] {
            #expect(WindowPartStep(keyCode: UInt16(kVK_UpArrow), modifiers: modifiers) == nil)
        }
        #expect(WindowPartStep(keyCode: UInt16(kVK_LeftArrow), modifiers: []) == nil)
        #expect(WindowPartStep(keyCode: UInt16(kVK_ANSI_S), modifiers: []) == nil)
    }
}

@Suite("Window parts — names, chip, glide")
struct WindowPartTextTests {
    @Test func labelsAreTrimmedCapitalisedAndTruncated() {
        #expect(WindowPartSelection.displayLabel("sidebar") == "Sidebar")
        #expect(WindowPartSelection.displayLabel("  Primary pane \n second line") == "Primary pane")
        #expect(WindowPartSelection.displayLabel("") == nil)
        #expect(WindowPartSelection.displayLabel("   ") == nil)
        #expect(WindowPartSelection.displayLabel(nil) == nil)
        let long = WindowPartSelection.displayLabel(String(repeating: "a", count: 50))
        #expect(long?.count == WindowPartSelection.maximumNameLength)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test func rolesAndLandmarksHaveNames() {
        func name(_ role: String, _ subrole: String? = nil, label: String? = nil) -> String {
            WindowPartSelection.naming(WindowPartNode(role: role, subrole: subrole, label: label, frame: .zero)).name
        }
        #expect(name("AXWebArea", label: "Page title") == "Web page")
        #expect(name("AXOutline", label: "sidebar") == "Sidebar")
        #expect(name("AXScrollArea") == "Scroll area")
        #expect(name("AXSplitGroup") == "Split view")
        #expect(name("AXTabGroup") == "Tab view")
        #expect(name("AXToolbar") == "Toolbar")
        #expect(name("AXTable") == "Table")
        #expect(name("AXList") == "List")
        #expect(name("AXBrowser") == "Column view")
        #expect(name("AXGroup", "AXLandmarkMain") == "Main content")
        #expect(name("AXGroup", "AXLandmarkComplementary") == "Sidebar")
        #expect(name("AXGroup", "AXLandmarkNavigation") == "Navigation")
        #expect(name("AXGroup") == "Pane")
    }

    @Test func chipTextNamesTheWindowByAppAndPartsBySize() {
        let window = WindowPartLevel.window(CGRect(x: 0, y: 0, width: 1280, height: 800))
        #expect(WindowPartSelection.chipText(for: window, appName: "Chrome") == "Window · Chrome")
        #expect(WindowPartSelection.chipText(for: window, appName: nil) == "Window · 1280 × 800")
        let part = WindowPartLevel(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), name: "Web page")
        #expect(WindowPartSelection.chipText(for: part, appName: "Chrome") == "Web page · 1280 × 720")
    }

    @Test func glideEasesOutOverItsDurationAndReduceMotionIsInstant() {
        #expect(WindowPartGlide.progress(elapsed: 0, reduceMotion: false) == 0)
        #expect(WindowPartGlide.progress(elapsed: WindowPartGlide.duration, reduceMotion: false) == 1)
        #expect(WindowPartGlide.progress(elapsed: 10, reduceMotion: false) == 1)
        #expect(WindowPartGlide.progress(elapsed: -1, reduceMotion: false) == 0)
        let half = WindowPartGlide.progress(elapsed: WindowPartGlide.duration / 2, reduceMotion: false)
        #expect(half > 0.5 && half < 1, "ease-out: past the middle at half time")
        #expect(WindowPartGlide.progress(elapsed: 0, reduceMotion: true) == 1)
    }

    @Test func glideInterpolatesEveryEdge() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 100, y: 50, width: 300, height: 200)
        #expect(WindowPartGlide.rect(from: from, to: to, progress: 0) == from)
        #expect(WindowPartGlide.rect(from: from, to: to, progress: 1) == to)
        #expect(WindowPartGlide.rect(from: from, to: to, progress: 0.5) == CGRect(x: 50, y: 25, width: 200, height: 150))
        #expect(WindowPartGlide.rect(from: from, to: to, progress: 2) == to)
    }
}

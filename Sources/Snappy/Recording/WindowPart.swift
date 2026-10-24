import AppKit
import Carbon.HIToolbox

// Window parts (v2, `features/recording.md` › Window parts, Q34–Q42): S and W
// pick a *part* of the hovered window — a browser's page area, a sidebar, an
// editor pane — as well as the whole window. This file is the PURE side
// (unit-tested with fake trees); the Accessibility side is
// `WindowPartAccessibility.swift`.

// MARK: - The tree under the pointer

/// One accessibility element on the path from the hovered window down to the
/// element under the pointer. Frames are **AppKit global** (the live tree
/// converts AX's top-left space through `CaptureGeometry`).
struct WindowPartNode: Equatable, Sendable {
    /// `AXRole` (`AXWebArea`, `AXScrollArea`, `AXGroup` …).
    var role: String
    /// `AXSubrole` (`AXLandmarkMain`, `AXSectionList` …).
    var subrole: String?
    /// `AXDescription` — a human label some parts carry ("sidebar", "Primary pane").
    var label: String?
    var frame: CGRect
    /// Whether it has any children. Only read for the deepest node: an app
    /// whose tree stops at a childless, window-sized element hides its tree.
    var hasChildren = true
    /// The live handle (nil in fake trees).
    var element: WindowPartElement?
}

/// The path at one pointer position: the hovered window's parts, **outermost
/// first**, without the window itself.
struct WindowPartChain: Equatable, Sendable {
    var nodes: [WindowPartNode]
    /// The app's whole UI is web content (Electron, which answers
    /// `AXManualAccessibility`): its panes are ARIA landmarks inside the web
    /// area, so the picker looks inside it even when the web area is smaller
    /// than the window (a native title bar above it).
    var webContentIsAppUI = false
}

/// Where the live tree comes from — the Accessibility API in the app, fakes in
/// the tests. Asked from the main actor; the live tree answers **later**
/// (its AX calls run on their own executor, so a slow app never stalls the
/// pointer), a fake may answer at once.
@MainActor
protocol WindowPartTree: AnyObject {
    /// Asks for the chain under `point` (AppKit global) in `window`.
    /// `completion` runs on the main actor with nil when the app has no
    /// usable tree there (no tree, a timeout, a different window on top) —
    /// the picker then offers the whole window only. **Latest wins:** a
    /// request a newer one superseded may never complete.
    func requestChain(at point: CGPoint, in window: SnapWindow, completion: @escaping @MainActor (WindowPartChain?) -> Void)
}

/// A live handle on one window part's accessibility element — the V2 → V3
/// contract for W + part. The element itself never leaves the AX executor
/// (`AXUIElement` isn't Sendable): the handle is an opaque, Sendable token
/// whose `currentFrame()` asks that executor and gets a plain rect back.
/// Compared by **identity**: the live tree hands out one handle per element
/// per snap visit, so the same part under a moving pointer is the same target.
final class WindowPartElement: Equatable, Sendable {
    /// The app that owns the element.
    let processID: pid_t
    private let requestFrame: @Sendable (_ deliver: @escaping @Sendable (CGRect?) -> Void) -> Void
    private let release: (@Sendable () -> Void)?

    /// `request` must **enqueue** the read before it returns (the live tree
    /// posts it to the AX executor) and call `deliver` once, later.
    /// `release` runs when the last reference goes (the live tree lets go of
    /// the element on the AX executor then).
    init(
        processID: pid_t, release: (@Sendable () -> Void)? = nil,
        request: @escaping @Sendable (_ deliver: @escaping @Sendable (CGRect?) -> Void) -> Void
    ) {
        self.processID = processID
        self.release = release
        requestFrame = request
    }

    /// A handle whose frame comes from `readFrame` (fakes in tests).
    convenience init(
        processID: pid_t, release: (@Sendable () -> Void)? = nil,
        readFrame: @escaping @Sendable () async -> CGRect?
    ) {
        self.init(processID: processID, release: release) { deliver in
            Task { deliver(await readFrame()) }
        }
    }

    deinit {
        release?()
    }

    /// The part's **visible** frame now, AppKit global — clipped by every
    /// enclosing element, as the picker showed it — what V3 polls (~10 Hz)
    /// and Retake looks up. Never blocks the caller's thread on the app. Nil
    /// when the element is gone (tab closed, navigated) or scrolled out of
    /// view, when the app doesn't answer (then reads back off for a while),
    /// or outside a recording session; keep the last rect then (Q37).
    ///
    /// The read is **enqueued in the caller's isolation before the first
    /// suspension** — so from the main actor it reaches the AX executor in
    /// program order, ahead of a session end posted after it (the engine
    /// answers no read once the session has ended, Q40).
    func currentFrame(isolation: isolated (any Actor)? = #isolation) async -> CGRect? {
        await withCheckedContinuation(isolation: isolation) { continuation in
            requestFrame { continuation.resume(returning: $0) }
        }
    }

    static func == (lhs: WindowPartElement, rhs: WindowPartElement) -> Bool {
        lhs === rhs
    }
}

// MARK: - Levels

/// One pickable level at the pointer: the whole window (index 0) or a part.
struct WindowPartLevel: Equatable, Sendable {
    /// AppKit global, clipped to the window and every enclosing part.
    var frame: CGRect
    /// The chip's name: "Web page", "Sidebar", or "Window" for the whole window.
    var name: String
    /// The handle of the **outermost** element of the collapsed run — its frame
    /// is the visible box (a scroll area's, not its document's).
    var element: WindowPartElement?
    /// True only for index 0.
    var isWholeWindow = false

    static func window(_ frame: CGRect) -> WindowPartLevel {
        WindowPartLevel(frame: frame, name: WindowPartSelection.windowName, element: nil, isWholeWindow: true)
    }
}

/// PURE part selection (Q35) — unit-tested with fake trees:
///
/// | Pointer | Pick |
/// | ------- | ---- |
/// | title bar, or within `edgeBand` of the window's edge | the whole window |
/// | anywhere else | the smallest *meaningful part* under it |
///
/// A meaningful part is a container role (web area, scroll area, split-view
/// pane, tab view, toolbar, sidebar/outline, table, list), at least
/// `minimumPartSize`, and **clearly smaller** than the level around it
/// (`minimumInset`), so nested near-identical boxes collapse into one level.
/// Buttons, text and links are never picked. A browser's web page is one
/// part — its inner landmarks are the page's business — but an app whose UI
/// *is* web content (Electron, or a web area filling the window) is looked
/// into: its panes are ARIA landmarks.
///
/// Tuning values (Q35: "to be adjusted live") are the named constants below.
enum WindowPartSelection {
    /// Within this distance of the window's edge the whole window is picked.
    static let edgeBand: CGFloat = 16
    /// The top strip that counts as the title bar (a standard macOS title
    /// bar's height). Tab strips and toolbars below it are too short to be
    /// parts anyway, so they pick the whole window too.
    static let titleBarHeight: CGFloat = 28
    /// Smallest part worth recording.
    static let minimumPartSize = CGSize(width: 120, height: 80)
    /// A part must be at least this much narrower or shorter than the level
    /// around it; less (a scroll bar, a 1 pt border) is the same box.
    static let minimumInset: CGFloat = 24
    /// Longest name the chip shows before it truncates.
    static let maximumNameLength = 32

    static let windowName = "Window"

    // MARK: Levels

    /// Every level at the pointer, the whole window first, then the
    /// meaningful parts from outermost to innermost (each clearly smaller
    /// than the one before). Nodes that don't contain `point` once clipped
    /// are skipped.
    static func levels(window: CGRect, chain: WindowPartChain?, at point: CGPoint) -> [WindowPartLevel] {
        var levels = [WindowPartLevel.window(window)]
        guard let chain else { return levels }
        // The rank of the name each level currently shows (see `naming`).
        var ranks = [Int.max]
        var clip = window
        var inWebContent = false
        var parentRole: String?

        for node in chain.nodes {
            defer { parentRole = node.role }
            // A frameless wrapper (zero size) neither clips nor counts.
            let visible = clip.intersection(node.frame)
            guard !visible.isNull, !visible.isEmpty else { continue }
            clip = visible

            if isContainer(node, parentRole: parentRole, inWebContent: inWebContent),
               visible.contains(point), fits(visible) {
                let (name, rank) = naming(node)
                if isClearlySmaller(visible, than: levels[levels.count - 1].frame) {
                    levels.append(WindowPartLevel(frame: visible, name: name, element: node.element))
                    ranks.append(rank)
                } else if levels.count > 1, rank >= ranks[ranks.count - 1] {
                    // The same box as the level around it: one level, the
                    // best name. (The window keeps its own name.)
                    levels[levels.count - 1].name = name
                    ranks[ranks.count - 1] = rank
                }
            }

            if node.role == Role.webArea {
                // A browser's page is atomic: its landmarks are the page's.
                guard looksInside(webArea: visible, window: window, chain: chain) else { break }
                inWebContent = true
            }
        }
        return levels
    }

    /// What is visible of the innermost of `frames` (outermost first, the
    /// window itself excluded): clipped by every enclosing frame — the rule
    /// `levels` applies walking down, here for one element's live chain (V3
    /// polls it). A frameless wrapper, or one wholly outside what is visible
    /// so far, neither clips nor counts. Nil when nothing of the innermost
    /// is visible (empty, or scrolled out of its viewport).
    static func visibleFrame(of frames: [CGRect]) -> CGRect? {
        guard let own = frames.last else { return nil }
        var clip: CGRect?
        for frame in frames.dropLast() {
            let visible = clip?.intersection(frame) ?? frame
            guard !visible.isNull, !visible.isEmpty else { continue }
            clip = visible
        }
        let visible = clip?.intersection(own) ?? own
        guard !visible.isNull, !visible.isEmpty else { return nil }
        return visible
    }

    /// The automatic pick (Q35): the whole window on the title bar and in the
    /// edge band, else the innermost level.
    static func automaticIndex(at point: CGPoint, window: CGRect, levelCount: Int) -> Int {
        guard levelCount > 1, !isOnWindowEdge(point, window: window) else { return 0 }
        return levelCount - 1
    }

    /// On the title bar, or within `edgeBand` of any edge (AppKit: the top is
    /// `maxY`).
    static func isOnWindowEdge(_ point: CGPoint, window: CGRect) -> Bool {
        let fromTop = window.maxY - point.y
        let nearest = min(point.x - window.minX, window.maxX - point.x, point.y - window.minY, fromTop)
        return nearest < edgeBand || fromTop < titleBarHeight
    }

    /// The app hides its tree (Q40): nothing below the window, or the hit
    /// stops at a childless element that is the window's own box. Then the
    /// Chromium / Electron switch is worth a try.
    static func isTreeEmpty(_ chain: WindowPartChain?, window: CGRect) -> Bool {
        guard let deepest = chain?.nodes.last else { return true }
        let visible = window.intersection(deepest.frame)
        let isWindowBox = visible.isNull || !isClearlySmaller(visible, than: window)
        return !deepest.hasChildren && isWindowBox
    }

    // MARK: Rules

    private enum Role {
        static let webArea = "AXWebArea"
        static let scrollArea = "AXScrollArea"
        static let splitGroup = "AXSplitGroup"
        static let tabGroup = "AXTabGroup"
        static let toolbar = "AXToolbar"
        static let outline = "AXOutline"
        static let table = "AXTable"
        static let list = "AXList"
        static let browser = "AXBrowser"
        static let group = "AXGroup"
    }

    /// Container roles that are parts wherever they appear.
    private static let containerRoles: Set<String> = [
        Role.webArea, Role.scrollArea, Role.splitGroup, Role.tabGroup, Role.toolbar,
        Role.outline, Role.table, Role.browser,
    ]

    /// Whether `node` can be a part at all (size and containment aside).
    /// - Native UI: the container roles, lists (not a list's sections), and a
    ///   group only as a split view's pane or an ARIA landmark.
    /// - Inside web content: the container roles and landmarks only — a web
    ///   page's lists and `div`s are content, not panes.
    static func isContainer(_ node: WindowPartNode, parentRole: String?, inWebContent: Bool) -> Bool {
        if containerRoles.contains(node.role) { return true }
        let isLandmark = node.subrole?.hasPrefix("AXLandmark") == true
        switch node.role {
        case Role.group:
            return isLandmark || (!inWebContent && parentRole == Role.splitGroup)
        case Role.list:
            return !inWebContent && node.subrole != "AXSectionList"
        default:
            return false
        }
    }

    private static func fits(_ frame: CGRect) -> Bool {
        frame.width >= minimumPartSize.width && frame.height >= minimumPartSize.height
    }

    /// At least `minimumInset` narrower or shorter than `outer`.
    static func isClearlySmaller(_ frame: CGRect, than outer: CGRect) -> Bool {
        outer.width - frame.width >= minimumInset || outer.height - frame.height >= minimumInset
    }

    /// Look inside a web area only when it is the app's UI: Electron, or a
    /// web area that is the window's whole box.
    private static func looksInside(webArea: CGRect, window: CGRect, chain: WindowPartChain) -> Bool {
        chain.webContentIsAppUI || !isClearlySmaller(webArea, than: window)
    }

    // MARK: Names

    /// A node's chip name and how telling it is: a web area is always "Web
    /// page" (its label is the page title); an element's own label wins over
    /// a role name; a split view's unnamed pane is the least telling. In a
    /// collapsed run the best rank names the level (ties: the innermost).
    static func naming(_ node: WindowPartNode) -> (name: String, rank: Int) {
        if node.role == Role.webArea { return ("Web page", 3) }
        if let label = displayLabel(node.label) { return (label, 2) }
        switch node.role {
        case Role.scrollArea: return ("Scroll area", 1)
        case Role.splitGroup: return ("Split view", 1)
        case Role.tabGroup: return ("Tab view", 1)
        case Role.toolbar: return ("Toolbar", 1)
        case Role.outline: return ("Outline", 1)
        case Role.table: return ("Table", 1)
        case Role.list: return ("List", 1)
        case Role.browser: return ("Column view", 1)
        default: break
        }
        switch node.subrole {
        case "AXLandmarkMain": return ("Main content", 1)
        case "AXLandmarkNavigation": return ("Navigation", 1)
        case "AXLandmarkComplementary": return ("Sidebar", 1)
        case "AXLandmarkBanner": return ("Header", 1)
        case "AXLandmarkContentInfo": return ("Footer", 1)
        case "AXLandmarkSearch": return ("Search", 1)
        case "AXLandmarkRegion": return ("Region", 1)
        default: return ("Pane", 0)
        }
    }

    /// A label as the chip shows it: trimmed, one line, first letter
    /// capitalised ("sidebar" → "Sidebar"), truncated at
    /// `maximumNameLength`. Nil when empty.
    static func displayLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        let line = label.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        let capitalised = first.uppercased() + trimmed.dropFirst()
        guard capitalised.count > maximumNameLength else { return capitalised }
        return capitalised.prefix(maximumNameLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The chip text (Q36): `Web page · 1280 × 720` for a part, `Window ·
    /// Chrome` for a whole window (its size when the app has no name).
    static func chipText(for level: WindowPartLevel, appName: String?) -> String {
        if level.isWholeWindow, let appName, !appName.isEmpty {
            return "\(windowName) · \(appName)"
        }
        return "\(level.name) · \(SetupGeometry.sizeReadout(level.frame.size))"
    }
}

// MARK: - Override (↑ / ↓ / scroll)

/// One step of the manual override: wider (towards the whole window) or
/// narrower (towards the innermost part).
enum WindowPartStep: Equatable, Sendable {
    case widen, narrow

    /// Bare ↑ widens, bare ↓ narrows (arrow keys carry `.numericPad` and
    /// `.function`, which don't count; Caps Lock is ignored). Nil for
    /// anything else.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty else { return nil }
        switch Int(keyCode) {
        case kVK_UpArrow: self = .widen
        case kVK_DownArrow: self = .narrow
        default: return nil
        }
    }
}

/// Scroll → steps: a mouse wheel's notch is one step; a trackpad's precise
/// deltas add up, one step per `stepDistance` points, and a change of
/// direction starts over. Momentum is ignored (a flick would race through
/// every level). Up (positive) widens, like scrolling up grows the Setup rect.
struct WindowPartScrollStepper: Equatable, Sendable {
    static let stepDistance: CGFloat = 24

    private var accumulated: CGFloat = 0

    mutating func steps(deltaY: CGFloat, isPrecise: Bool, isMomentum: Bool) -> [WindowPartStep] {
        guard !isMomentum, deltaY != 0 else { return [] }
        let step: WindowPartStep = deltaY > 0 ? .widen : .narrow
        guard isPrecise else {
            accumulated = 0
            return [step]
        }
        if accumulated != 0, (accumulated > 0) != (deltaY > 0) { accumulated = 0 }
        accumulated += deltaY
        let count = Int(abs(accumulated) / Self.stepDistance)
        accumulated -= CGFloat(count) * Self.stepDistance * (deltaY > 0 ? 1 : -1)
        return Array(repeating: step, count: count)
    }

    mutating func reset() {
        accumulated = 0
    }
}

/// Which level is picked: the automatic one, unless ↑ / ↓ / scroll moved it
/// (Q35). Moving the pointer goes back to the automatic pick — once it has
/// moved more than `overrideReleaseDistance` from where the override was
/// made, so a hand resting on the mouse doesn't undo the keypress.
struct WindowPartPicking: Equatable, Sendable {
    static let overrideReleaseDistance: CGFloat = 4

    private(set) var levels: [WindowPartLevel] = []
    private(set) var index = 0
    private var automatic = 0
    private var overrideAnchor: CGPoint?

    var current: WindowPartLevel? {
        levels.indices.contains(index) ? levels[index] : nil
    }

    /// New levels at `point`. An override survives only while the pointer
    /// stays near where it was made (and is clamped to the new levels).
    mutating func update(levels: [WindowPartLevel], automatic: Int, at point: CGPoint) {
        self.levels = levels
        self.automatic = min(max(automatic, 0), max(levels.count - 1, 0))
        if let anchor = overrideAnchor, hypot(point.x - anchor.x, point.y - anchor.y) <= Self.overrideReleaseDistance {
            index = min(index, max(levels.count - 1, 0))
        } else {
            overrideAnchor = nil
            index = self.automatic
        }
    }

    /// One level wider / narrower at `point`. False at either end.
    @discardableResult
    mutating func step(_ step: WindowPartStep, at point: CGPoint) -> Bool {
        let next = step == .widen ? index - 1 : index + 1
        guard levels.indices.contains(next) else { return false }
        index = next
        overrideAnchor = point
        return true
    }

    mutating func reset() {
        self = WindowPartPicking()
    }
}

// MARK: - The model

/// What the snap picker shows for the hovered window: a part, or nil for the
/// whole window.
struct SnapPart: Equatable, Sendable {
    /// AppKit global.
    var frame: CGRect
    var name: String
    var element: WindowPartElement?
}

/// The part picker for one snap visit (Q35): pointer → tree → levels →
/// automatic pick, with the ↑ / ↓ / scroll override on top. No tree (no
/// Accessibility access) = whole windows only, exactly as in v1.
///
/// The tree answers asynchronously and **latest wins**: a new window shows
/// as a whole window at once (the window itself needs no AX), and within a
/// window the pick stays where it is until the answer for the latest pointer
/// position arrives; an older answer is dropped. `onChange` reports a pick
/// that changed after `pointerMoved` returned.
///
/// So a click (or Return) confirms the part **under it**, not the one the
/// last answer showed, `whenSettled` holds the confirm until the pick
/// reflects the latest `pointerMoved` — bounded by `settleTimeout`.
@MainActor
final class WindowPartModel {
    typealias Delay = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

    /// The longest a confirm waits for the tree: one query's worst case
    /// (`WindowPartAXEngine.queryBudget` plus one call) with room to spare.
    static let settleTimeout: Duration = .seconds(1)

    static let mainActorDelay: Delay = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            work()
        }
    }

    private let tree: (any WindowPartTree)?
    private let delay: Delay
    private var picking = WindowPartPicking()
    private var scroll = WindowPartScrollStepper()
    private var window: SnapWindow?
    /// The latest request; an answer to any other is stale.
    private var request = 0
    private var isRequesting = false
    /// The latest tree request while it is unanswered: the pick doesn't
    /// reflect `point` yet.
    private var awaiting: (id: Int, point: CGPoint, window: SnapWindow)?
    /// The confirm `whenSettled` holds; `id` tells its timeout apart from a
    /// later one's.
    private var settling: (id: Int, action: @MainActor () -> Void)?
    private var settleID = 0
    /// The pick changed later than `pointerMoved` (the tree answered).
    var onChange: (@MainActor () -> Void)?

    init(tree: (any WindowPartTree)?, delay: @escaping Delay = WindowPartModel.mainActorDelay) {
        self.tree = tree
        self.delay = delay
    }

    /// A confirm is waiting for the tree's answer.
    var isSettling: Bool { settling != nil }

    /// The level picked now (nil: nothing hovered).
    var current: WindowPartLevel? { picking.current }

    /// The current pick as a part; nil for the whole window or nothing.
    var part: SnapPart? {
        guard let level = picking.current, !level.isWholeWindow else { return nil }
        return SnapPart(frame: level.frame, name: level.name, element: level.element)
    }

    /// The pointer moved (or the tree changed) over `window`; nil window =
    /// over no window.
    /// A newer position drops a confirm still waiting (`whenSettled`): the
    /// answer it waited for is stale now.
    func pointerMoved(to point: CGPoint, over window: SnapWindow?) {
        settling = nil
        awaiting = nil
        if window != self.window {
            picking.reset()
            scroll.reset()
            self.window = window
            request += 1
            if let window { apply(nil, at: point, in: window) }
        }
        guard let window, let tree else { return }
        request += 1
        let id = request
        awaiting = (id, point, window)
        isRequesting = true
        defer { isRequesting = false }
        tree.requestChain(at: point, in: window) { [weak self] chain in
            guard let self, id == request, window == self.window else { return }
            awaiting = nil
            apply(chain, at: point, in: window)
            if !isRequesting { onChange?() }
            runSettled()
        }
    }

    /// Runs `action` once the pick reflects the latest `pointerMoved` — at
    /// once when it already does (no tree, over no window, the tree has
    /// answered), else right after that answer is applied and `onChange`
    /// has reported it. A newer `pointerMoved`, a newer `whenSettled` or
    /// `reset` drops it. After `settleTimeout` without an answer the whole
    /// window at that position is picked (what a tree that doesn't answer
    /// gives) and `action` runs, so a hung app can't hold the confirm.
    func whenSettled(_ action: @escaping @MainActor () -> Void) {
        guard awaiting != nil else {
            settling = nil
            return action()
        }
        settleID += 1
        let id = settleID
        settling = (id, action)
        delay(Self.settleTimeout) { [weak self] in self?.settleTimedOut(id) }
    }

    /// Drops a confirm still waiting; the pick goes on following the tree.
    func cancelSettling() {
        settling = nil
    }

    private func settleTimedOut(_ id: Int) {
        guard settling?.id == id, let awaiting else { return }
        self.awaiting = nil
        request += 1 // the late answer is stale now
        apply(nil, at: awaiting.point, in: awaiting.window)
        onChange?()
        runSettled()
    }

    private func runSettled() {
        guard let settling else { return }
        self.settling = nil
        settling.action()
    }

    private func apply(_ chain: WindowPartChain?, at point: CGPoint, in window: SnapWindow) {
        let levels = WindowPartSelection.levels(window: window.frame, chain: chain, at: point)
        let automatic = WindowPartSelection.automaticIndex(at: point, window: window.frame, levelCount: levels.count)
        picking.update(levels: levels, automatic: automatic, at: point)
    }

    /// ↑ / ↓. True when the pick changed.
    @discardableResult
    func step(_ step: WindowPartStep, at point: CGPoint) -> Bool {
        picking.step(step, at: point)
    }

    /// A scroll event. True when the pick changed.
    @discardableResult
    func scrolled(deltaY: CGFloat, isPrecise: Bool, isMomentum: Bool, at point: CGPoint) -> Bool {
        var changed = false
        for step in scroll.steps(deltaY: deltaY, isPrecise: isPrecise, isMomentum: isMomentum) {
            changed = picking.step(step, at: point) || changed
        }
        return changed
    }

    func reset() {
        picking.reset()
        scroll.reset()
        window = nil
        request += 1
        awaiting = nil
        settling = nil
    }
}

// MARK: - Glide (Q36)

/// The highlight glides between picks instead of jumping — PURE, tested.
enum WindowPartGlide {
    /// Q36: ~0.12 s; instant with Reduce Motion.
    static let duration: TimeInterval = 0.12

    /// Ease-out cubic progress for `elapsed` seconds (0…1).
    static func progress(elapsed: TimeInterval, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, duration > 0 else { return 1 }
        let t = min(max(elapsed / duration, 0), 1)
        return CGFloat(1 - pow(1 - t, 3))
    }

    /// `from` → `to` at `progress` (0 = from, 1 = to), each edge linearly.
    static func rect(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        let p = min(max(progress, 0), 1)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return CGRect(
            x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
            width: mix(from.width, to.width), height: mix(from.height, to.height)
        )
    }
}

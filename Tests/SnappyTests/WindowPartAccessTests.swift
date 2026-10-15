import AppKit
import ApplicationServices
import Foundation
import Synchronization
import Testing
@testable import Snappy

/// A stand-in for the Accessibility API: elements are inert tokens (never
/// messaged), every call is logged and may fail or take time. Called from the
/// AX executor's queue while the test reads it on the main actor, so all of
/// its state is behind one lock.
final class FakeAX: WindowPartAXMessaging, @unchecked Sendable {
    struct Node {
        var role: String
        /// AX space (top-left global).
        var frame: CGRect
        var parent: AXUIElement?
        var childCount = 0
        var label: String?
        var valuesError: AXError = .success
        var childError: AXError = .success
    }

    private static let tokens = Mutex<pid_t>(60_000)
    /// A fresh element nobody else uses.
    static func token() -> AXUIElement {
        AXUIElementCreateApplication(tokens.withLock { $0 += 1; return $0 })
    }

    private let lock = NSLock()
    private var nodes: [(element: AXUIElement, node: Node)] = []
    private var _hit: AXUIElement?
    private var _hitError: AXError = .success
    private var _appValues: [String: AnyObject] = [:]
    private var _readError: AXError = .success
    private var _setErrors: [AXError] = []
    private var _cost: TimeInterval = 0
    private var _realDelay: TimeInterval = 0
    private var _clock: TimeInterval = 100
    private var _calls: [String] = []
    private var _identities: [pid_t: String] = [:]
    private var _hungPIDs: Set<pid_t> = []
    private var _hitGate: (entered: DispatchSemaphore, release: DispatchSemaphore)?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var hit: AXUIElement? {
        get { locked { _hit } }
        set { locked { _hit = newValue } }
    }
    var hitError: AXError {
        get { locked { _hitError } }
        set { locked { _hitError = newValue } }
    }
    /// The app's tree-switch attributes, by name.
    var appValues: [String: AnyObject] {
        get { locked { _appValues } }
        set { locked { _appValues = newValue } }
    }
    var readError: AXError {
        get { locked { _readError } }
        set { locked { _readError = newValue } }
    }
    /// Popped by each `setValue`; `.success` once empty.
    var setErrors: [AXError] {
        get { locked { _setErrors } }
        set { locked { _setErrors = newValue } }
    }
    /// What one call costs on the fake clock.
    var cost: TimeInterval {
        get { locked { _cost } }
        set { locked { _cost = newValue } }
    }
    /// What one call really blocks the calling thread (a hung app).
    var realDelay: TimeInterval {
        get { locked { _realDelay } }
        set { locked { _realDelay = newValue } }
    }
    var clock: TimeInterval {
        get { locked { _clock } }
        set { locked { _clock = newValue } }
    }
    var calls: [String] { locked { _calls } }
    /// `set <attribute>=<value> <pid>`, in order.
    var sets: [String] { calls.filter { $0.hasPrefix("set ") } }
    /// Running processes (bundle id + launch date stand-ins).
    var identities: [pid_t: String] {
        get { locked { _identities } }
        set { locked { _identities = newValue } }
    }

    /// Apps whose every write times out (alive, not answering).
    var hungPIDs: Set<pid_t> {
        get { locked { _hungPIDs } }
        set { locked { _hungPIDs = newValue } }
    }

    /// The next hit test signals `entered` and waits for `release` — a query
    /// caught mid-execution. One-shot.
    func holdNextHit() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        locked { _hitGate = gate }
        return gate
    }

    func identity(of pid: pid_t) -> String? {
        locked { _identities[pid] }
    }

    func add(_ element: AXUIElement, _ node: Node) {
        locked { nodes.append((element, node)) }
    }

    func update(_ element: AXUIElement, _ change: (inout Node) -> Void) {
        locked {
            guard let index = nodes.firstIndex(where: { CFEqual($0.element, element) }) else { return }
            change(&nodes[index].node)
        }
    }

    private func node(_ element: AXUIElement) -> Node? {
        locked { nodes.first { CFEqual($0.element, element) }?.node }
    }

    private func call(_ name: String) {
        let delay = locked {
            _calls.append(name)
            _clock += _cost
            return _realDelay
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }

    private static func axError(_ error: AXError) -> AnyObject {
        var error = error
        return AXValueCreate(.axError, &error)!
    }

    func application(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    func element(at point: CGPoint, in app: AXUIElement) -> (AXError, AXUIElement?) {
        call("hit")
        if let gate = locked({ () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
            defer { _hitGate = nil }
            return _hitGate
        }) {
            gate.entered.signal()
            gate.release.wait()
        }
        return locked { (_hitError, _hitError == .success ? _hit : nil) }
    }

    func values(of attributes: [String], of element: AXUIElement) -> (AXError, [AnyObject]) {
        call("values")
        guard let node = node(element) else { return (.invalidUIElement, []) }
        guard node.valuesError == .success else { return (node.valuesError, []) }
        return (.success, attributes.map { name -> AnyObject in
            switch name {
            case kAXRoleAttribute: return node.role as NSString
            case kAXPositionAttribute:
                var origin = node.frame.origin
                return AXValueCreate(.cgPoint, &origin)!
            case kAXSizeAttribute:
                var size = node.frame.size
                return AXValueCreate(.cgSize, &size)!
            case kAXParentAttribute: return node.parent ?? Self.axError(.noValue)
            case kAXDescriptionAttribute: return (node.label as NSString?) ?? Self.axError(.noValue)
            default: return Self.axError(.noValue)
            }
        })
    }

    func childCount(of element: AXUIElement) -> (AXError, Int) {
        call("children")
        guard let node = node(element) else { return (.invalidUIElement, 0) }
        return (node.childError, node.childCount)
    }

    func value(of attribute: String, of element: AXUIElement) -> (AXError, AnyObject?) {
        call("read \(attribute)")
        return locked { (_readError, _readError == .success ? _appValues[attribute] : nil) }
    }

    func setValue(_ value: Bool, of attribute: String, on element: AXUIElement) -> AXError {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        call("set \(attribute)=\(value) \(pid)")
        return locked {
            if _hungPIDs.contains(pid) { return .cannotComplete }
            let error = _setErrors.isEmpty ? .success : _setErrors.removeFirst()
            if error == .success { _appValues[attribute] = value as NSNumber }
            return error
        }
    }

    func now() -> TimeInterval {
        clock
    }
}

extension WindowPartAXTree {
    /// One query, awaited (tests ask one at a time, so it is the latest).
    func chain(at point: CGPoint, in window: SnapWindow) async -> WindowPartChain? {
        await withCheckedContinuation { continuation in
            requestChain(at: point, in: window) { continuation.resume(returning: $0) }
        }
    }
}

extension WindowPartAXEngine {
    /// Waits until everything posted so far has run, and what it delivered
    /// to the main actor with it.
    func settle() async {
        await withCheckedContinuation { continuation in
            post { _ in continuation.resume() }
        }
    }
}

/// The live window-part access, tree and AX executor against `FakeAX`: every
/// AX call bounded and off the main thread (a stalled call at any stage, or a
/// slow query, ends parts for the visit; hover is latest-wins), the tree
/// switch only changes a value it read, restores are owned per process (a
/// later session that uses the app adopts them) and survive a non-answering
/// app and a quit, and the prompting session stays whole-window.
@MainActor
@Suite("Window parts — Accessibility access", .serialized)
final class WindowPartAccessTests {
    static let pid: pid_t = 4242
    static let height: CGFloat = 1000
    /// AX space; AppKit (100, 100, 800, 600) with a 1000 pt primary display.
    static let axWindow = CGRect(x: 100, y: 300, width: 800, height: 600)
    static let window = SnapWindow(
        windowID: 1,
        frame: CaptureGeometry.appKitRect(fromCGGlobal: axWindow, primaryDisplayHeight: height),
        appName: "Fake", processID: pid
    )
    /// 5 pt from the window's left edge — the edge band.
    static let edge = CGPoint(x: 105, y: 400)
    static let interior = CGPoint(x: 500, y: 350)
    static let manual = WindowPartTreeSwitch.manualAccessibility.rawValue
    static let enhanced = WindowPartTreeSwitch.enhancedUserInterface.rawValue

    let ax = FakeAX()
    let suiteName = "SnappyTests.WindowPartAccess.\(UUID().uuidString)"
    let defaults: UserDefaults
    var trusted = true
    var prompts = 0
    let windowElement = FakeAX.token()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        ax.identities = [Self.pid: "fake@1"]
        ax.add(windowElement, .init(role: kAXWindowRole, frame: Self.axWindow, childCount: 1))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func makeAccess(
        settings: SettingsStore? = nil, kind: WindowPartAppKind = .electron, retryDelay: Duration = .seconds(60)
    ) -> WindowPartAccess {
        WindowPartAccess(
            settings: settings ?? SettingsStore(defaults: defaults),
            messaging: ax,
            isTrusted: { [unowned self] in trusted },
            prompt: { [unowned self] in prompts += 1 },
            isBundledApp: true,
            processIdentity: { [ax] in ax.identity(of: $0) },
            appKind: { _ in kind },
            primaryDisplayHeight: { Self.height },
            restoreRetryDelay: retryDelay
        )
    }

    func makeTree(_ access: WindowPartAccess) throws -> WindowPartAXTree {
        try #require(access.makeTree())
    }

    /// Electron's hidden tree: the hit is a childless, window-sized group.
    @discardableResult
    func hiddenTree(switchedOn: Bool = false) -> AXUIElement {
        let group = FakeAX.token()
        ax.add(group, .init(role: kAXGroupRole, frame: Self.axWindow, parent: windowElement))
        ax.hit = group
        ax.appValues[Self.manual] = switchedOn ? kCFBooleanTrue : kCFBooleanFalse
        return group
    }

    /// window → split group → sidebar (hit), with a real tree under it.
    @discardableResult
    func visibleTree() -> (split: AXUIElement, sidebar: AXUIElement) {
        let split = FakeAX.token()
        let sidebar = FakeAX.token()
        ax.add(split, .init(role: "AXSplitGroup", frame: Self.axWindow, parent: windowElement, childCount: 2))
        ax.add(sidebar, .init(
            role: kAXGroupRole, frame: CGRect(x: 100, y: 300, width: 250, height: 600), parent: split,
            childCount: 3, label: "sidebar"
        ))
        ax.hit = sidebar
        return (split, sidebar)
    }

    /// A recording session begins (a retained part is read only inside one).
    func beginSession(_ access: WindowPartAccess) async {
        access.sessionBegan(target: .area(globalRect: Self.window.frame, displayID: 1))
        await access.engine.settle()
    }

    /// Asked again, the app isn't messaged at all (whole window for the visit).
    func expectQuarantined(_ tree: WindowPartAXTree) async {
        let calls = ax.calls.count
        #expect(await tree.chain(at: Self.interior, in: Self.window) == nil)
        #expect(ax.calls.count == calls, "quarantined: not messaged again")
    }

    // MARK: Review 1 finding 1 / review 2 finding 1 — every stage bounded

    @Test func aVisibleTreeWalksToTheWindow() async throws {
        visibleTree()
        let tree = try makeTree(makeAccess())
        let chain = try #require(await tree.chain(at: Self.interior, in: Self.window))
        #expect(chain.nodes.map(\.role) == ["AXSplitGroup", kAXGroupRole])
        #expect(chain.nodes.last?.frame == CGRect(x: 100, y: 100, width: 250, height: 600))
    }

    @Test func aHitTestTimeoutEndsPartsForTheVisit() async throws {
        visibleTree()
        ax.hitError = .cannotComplete
        let tree = try makeTree(makeAccess())
        #expect(await tree.chain(at: Self.interior, in: Self.window) == nil)
        ax.hitError = .success
        await expectQuarantined(tree)
    }

    @Test func anAncestorTimeoutAfterAGoodHitEndsPartsForTheVisit() async throws {
        let (split, _) = visibleTree()
        ax.update(split) { $0.valuesError = .cannotComplete }
        let tree = try makeTree(makeAccess())
        #expect(await tree.chain(at: Self.interior, in: Self.window) == nil)
        ax.update(split) { $0.valuesError = .success }
        await expectQuarantined(tree)
    }

    @Test func aChildrenTimeoutEndsPartsForTheVisit() async throws {
        let (_, sidebar) = visibleTree()
        ax.update(sidebar) { $0.childError = .cannotComplete }
        let tree = try makeTree(makeAccess())
        #expect(await tree.chain(at: Self.interior, in: Self.window) == nil)
        ax.update(sidebar) { $0.childError = .success }
        await expectQuarantined(tree)
    }

    /// Each call answers inside the timeout, but together they go over the
    /// query budget.
    @Test func aSlowAppOverTheQueryBudgetEndsPartsForTheVisit() async throws {
        visibleTree()
        ax.cost = 0.2
        let tree = try makeTree(makeAccess())
        #expect(await tree.chain(at: Self.interior, in: Self.window) == nil)
        ax.cost = 0
        await expectQuarantined(tree)
    }

    /// Review 2 finding 1's probe: hit → window attributes → switch read,
    /// each 0.24 s. Review 3 finding 3: past the budget after the read, the
    /// write never starts — nothing switched, nothing owed.
    @Test func theWindowOnlyPathWithASlowSwitchIsOverBudget() async throws {
        ax.hit = windowElement
        ax.appValues[Self.manual] = kCFBooleanFalse
        ax.cost = 0.24
        let access = makeAccess()
        let tree = try makeTree(access)
        #expect(await tree.chain(at: Self.interior, in: Self.window) == nil)
        #expect(ax.calls == ["hit", "values", "read \(Self.manual)"], "no write after the deadline")
        #expect(ax.appValues[Self.manual] as? Bool == false)
        ax.cost = 0
        await expectQuarantined(tree)
        #expect(await access.engine.sessionSwitches.isEmpty)
    }

    /// The write started inside the budget and took the query over it: it
    /// may have landed, so it's quarantined *and* still put back.
    @Test func aWriteStartedInsideTheBudgetIsStillOwed() async throws {
        ax.hit = windowElement
        ax.appValues[Self.manual] = kCFBooleanFalse
        ax.cost = 0.15 // read done at 0.45 s, write done at 0.6 s
        let access = makeAccess()
        let tree = try makeTree(access)
        #expect(await tree.chain(at: Self.interior, in: Self.window) == nil)
        #expect(ax.calls == ["hit", "values", "read \(Self.manual)", "set \(Self.manual)=true \(Self.pid)"])
        ax.cost = 0
        await expectQuarantined(tree)
        #expect(await access.engine.sessionSwitches.map(\.pid) == [Self.pid])
    }

    /// A cached chain needs only the hit test — a slow one still counts.
    @Test func aSlowCachedHitIsOverBudgetToo() async throws {
        visibleTree()
        let tree = try makeTree(makeAccess())
        #expect(await tree.chain(at: Self.interior, in: Self.window) != nil)
        ax.cost = 0.6
        #expect(await tree.chain(at: Self.interior.applying(.init(translationX: 4, y: 0)), in: Self.window) == nil)
        #expect(ax.calls.last == "hit", "the cached chain: one call")
        ax.cost = 0
        await expectQuarantined(tree)
    }

    @Test func aTreeSwitchReadTimeoutEndsPartsForTheVisit() async throws {
        hiddenTree()
        ax.readError = .cannotComplete
        let tree = try makeTree(makeAccess())
        #expect(await tree.chain(at: Self.interior, in: Self.window) == nil)
        #expect(ax.sets.isEmpty)
        await expectQuarantined(tree)
    }

    // MARK: Review 2 findings 1 and 3 — the main thread never waits for AX

    /// The executor is busy (a slow app, 0.1 s per call): asking for the
    /// chain, ending a session and restoring all return at once; the answer
    /// comes when the executor gets to it.
    @Test func aHungAppNeverBlocksTheMainActor() async throws {
        visibleTree()
        ax.realDelay = 0.1
        let access = makeAccess()
        let tree = try makeTree(access)
        let start = ProcessInfo.processInfo.systemUptime
        var answered = false
        tree.requestChain(at: Self.interior, in: Self.window) { _ in answered = true }
        access.engine.post { $0.attemptPendingRestores() }
        access.sessionEnded()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        #expect(elapsed < 0.1, "main actor returned after \(elapsed) s")
        #expect(!answered, "the hung app hasn't answered yet")
        await access.engine.settle()
        #expect(answered)
    }

    /// Latest wins: queries made while the executor is busy are skipped
    /// except the last, and only the last is answered.
    @Test func onlyTheLatestQueryIsAskedAndAnswered() async throws {
        visibleTree()
        let access = makeAccess()
        let tree = try makeTree(access)
        let gate = DispatchSemaphore(value: 0)
        access.engine.post { _ in gate.wait() }
        var answers: [Int] = []
        for index in 0..<3 {
            tree.requestChain(at: Self.interior.applying(.init(translationX: CGFloat(index), y: 0)), in: Self.window) { _ in
                answers.append(index)
            }
        }
        gate.signal()
        await access.engine.settle()
        #expect(answers == [2])
        #expect(ax.calls.filter { $0 == "hit" }.count == 1)
    }

    /// Review 3 finding 1: query A switches the hidden tree on while B (over
    /// the same element) is already waiting. A's pick is stale, but its
    /// switch still brings the delayed second look — with no pointer move —
    /// and that look walks the newly built tree instead of B's cached empty
    /// chain.
    @Test func aSupersededSwitchQueryStillRechecks() async throws {
        let group = hiddenTree()
        let access = makeAccess()
        let tree = try makeTree(access)
        var rechecks = 0
        tree.onTreeChange = { rechecks += 1 }
        let gate = ax.holdNextHit()
        var answers: [String] = []
        tree.requestChain(at: Self.interior, in: Self.window) { _ in answers.append("A") }
        #expect(Self.waitBlocking(gate.entered), "A is executing")
        tree.requestChain(at: Self.interior.applying(.init(translationX: 1, y: 0)), in: Self.window) { chain in
            answers.append(chain == nil ? "B nil" : "B")
        }
        gate.release.signal()
        await access.engine.settle()
        #expect(answers == ["B"], "only the latest pick is answered")
        #expect(ax.sets == ["set \(Self.manual)=true \(Self.pid)"], "A switched; B couldn't again")

        // The app builds its tree under the same deepest element.
        let sidebar = FakeAX.token()
        ax.add(sidebar, .init(
            role: kAXGroupRole, frame: CGRect(x: 100, y: 300, width: 250, height: 600), parent: windowElement,
            childCount: 3, label: "sidebar"
        ))
        ax.update(group) { $0.frame = CGRect(x: 100, y: 300, width: 250, height: 600); $0.parent = sidebar }
        for _ in 0..<200 where rechecks == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rechecks == 1)
        let chain = try #require(await tree.chain(at: Self.interior, in: Self.window))
        #expect(chain.nodes.map(\.label) == ["sidebar", nil], "walked again, not the cached empty chain")
    }

    /// A real wait on the main thread (the executor doesn't need it).
    private static func waitBlocking(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 2) == .success
    }

    /// Leaving the visit (the tree goes) cancels a pending recheck.
    @Test func aRecheckIsCancelledWhenTheVisitEnds() async throws {
        hiddenTree()
        let access = makeAccess()
        var tree: WindowPartAXTree? = try makeTree(access)
        var rechecks = 0
        tree?.onTreeChange = { rechecks += 1 }
        _ = await tree?.chain(at: Self.interior, in: Self.window)
        #expect(ax.sets == ["set \(Self.manual)=true \(Self.pid)"])
        tree = nil
        await access.engine.settle()
        #expect(await access.engine.visitCount == 0)
        try await Task.sleep(for: WindowPartAccess.treeBuildDelay + .milliseconds(200))
        #expect(rechecks == 0)
    }

    /// Restores owed to several hung apps are retried in batches of at most
    /// `restoreBudget`, never one long run of every app.
    @Test func aRestoreBatchStopsAtItsBudget() async {
        let access = makeAccess(retryDelay: .seconds(60))
        for pid: pid_t in 1...8 {
            ax.identities[pid] = "app\(pid)@1"
            ax.appValues[Self.enhanced] = kCFBooleanFalse
            #expect(await access.engine.enableTreeIfHidden(pid: pid, kind: .chromium, treeIsEmpty: true) == .switched)
        }
        ax.cost = 0.2
        ax.setErrors = Array(repeating: .cannotComplete, count: 8)
        let before = ax.sets.count
        access.sessionEnded()
        await access.engine.settle()
        #expect(ax.sets.count - before == 3, "0, 0.2 and 0.4 s fit the 0.5 s budget")
        #expect(await access.engine.pendingRestores.count == 8)
    }

    @Test func pendingRestoresStopWhenOutOfTimeAndMoveFailuresBack() {
        var pending = WindowPartPendingRestores()
        pending.add((1...4).map { WindowPartSwitchRecord(pid: $0, identity: "\($0)", treeSwitch: .enhancedUserInterface, original: false) })
        var tried: [pid_t] = []
        pending.attempt(while: { tried.count < 2 }) { record in
            tried.append(record.pid)
            return record.pid == 1 ? .restored : .failed
        }
        #expect(tried == [1, 2])
        #expect(pending.records.map(\.pid) == [3, 4, 2], "the failure goes behind what wasn't reached")
        #expect(pending.failedAttempts == 1)
    }

    /// Review 3 finding 2's probe: records 1 and 2 never answer, 3 and 4 do,
    /// and a batch has time for two. Batch after batch, 3 and 4 get their
    /// turn instead of 1 and 2 using up every batch.
    @Test func hungRecordsDoNotStarveTheRestAcrossBatches() {
        var pending = WindowPartPendingRestores()
        pending.add((1...4).map { WindowPartSwitchRecord(pid: $0, identity: "\($0)", treeSwitch: .enhancedUserInterface, original: false) })
        var batches: [[pid_t]] = []
        for _ in 0..<3 {
            var tried: [pid_t] = []
            pending.attempt(while: { tried.count < 2 }) { record in
                tried.append(record.pid)
                return record.pid <= 2 ? .failed : .restored
            }
            batches.append(tried)
        }
        #expect(batches == [[1, 2], [3, 4], [1, 2]])
        #expect(pending.records.map(\.pid) == [1, 2])
    }

    /// The same through the engine: three apps hang at the front, five
    /// answer; consecutive bounded batches restore all five while the three
    /// stay owed (and keep their records).
    @Test func hungAppsAtTheFrontDoNotStarveLaterRestores() async {
        let access = makeAccess(retryDelay: .seconds(60))
        for pid: pid_t in 1...8 {
            ax.identities[pid] = "app\(pid)@1"
            ax.appValues[Self.enhanced] = kCFBooleanFalse
            #expect(await access.engine.enableTreeIfHidden(pid: pid, kind: .chromium, treeIsEmpty: true) == .switched)
        }
        ax.cost = 0.2
        ax.hungPIDs = [1, 2, 3]
        access.sessionEnded()
        await access.engine.settle()
        await access.engine.attemptPendingRestores()
        await access.engine.attemptPendingRestores()
        let restored = Set(ax.sets.compactMap { set -> pid_t? in
            guard set.hasPrefix("set \(Self.enhanced)=false ") else { return nil }
            let pid = pid_t(set.split(separator: " ").last!)!
            return ax.hungPIDs.contains(pid) ? nil : pid
        })
        #expect(restored == Set(4...8))
        #expect(Set(await access.engine.pendingRestores.map(\.pid)) == [1, 2, 3])
    }

    // MARK: Retained parts (what V3 polls)

    /// A retained part's frame comes back through the executor and backs off
    /// after a read the app can't complete, instead of stalling every poll.
    @Test func aRetainedPartsFrameReadBacksOffAfterATimeout() async throws {
        let (_, sidebar) = visibleTree()
        let access = makeAccess()
        let tree = try makeTree(access)
        let element = try #require(await tree.chain(at: Self.interior, in: Self.window)?.nodes.last?.element)
        await beginSession(access)
        #expect(await element.currentFrame() == CGRect(x: 100, y: 100, width: 250, height: 600))

        ax.update(sidebar) { $0.valuesError = .cannotComplete }
        #expect(await element.currentFrame() == nil)
        let calls = ax.calls.count
        #expect(await element.currentFrame() == nil)
        #expect(ax.calls.count == calls, "backing off: not messaged")

        ax.update(sidebar) { $0.valuesError = .success }
        ax.clock += 1.01
        #expect(await element.currentFrame() == CGRect(x: 100, y: 100, width: 250, height: 600))
    }

    @Test func frameReadBackoffDoublesToEightSeconds() {
        #expect((1...5).map(WindowPartAXEngine.frameReadBackoff(afterFailures:)) == [1, 2, 4, 8, 8])
    }

    /// Elements stay on the executor while a handle refers to them — past
    /// the visit — and go with the last handle.
    @Test func aRetainedElementOutlivesItsVisitAndGoesWithItsHandle() async throws {
        visibleTree()
        let access = makeAccess()
        var tree: WindowPartAXTree? = try makeTree(access)
        var element: WindowPartElement? = try #require(await tree?.chain(at: Self.interior, in: Self.window)?.nodes.last?.element)
        #expect(await access.engine.retainedElementCount == 2)
        tree = nil
        await beginSession(access)
        #expect(await access.engine.visitCount == 0)
        #expect(await access.engine.retainedElementCount == 1, "the handle still holds its element")
        #expect(await element?.currentFrame() == CGRect(x: 100, y: 100, width: 250, height: 600))
        element = nil
        await access.engine.settle()
        #expect(await access.engine.retainedElementCount == 0)
    }

    // MARK: Review 1 finding 4 — a cached hit still gets its switch

    @Test func edgeThenInteriorOverTheSameHitTriesTheSwitchOnce() async throws {
        hiddenTree()
        let tree = try makeTree(makeAccess())
        #expect(await tree.chain(at: Self.edge, in: Self.window) != nil)
        #expect(ax.sets.isEmpty, "not on the edge band")
        let walks = ax.calls.filter { $0 == "values" }.count

        #expect(await tree.chain(at: Self.interior, in: Self.window) != nil)
        #expect(ax.calls.filter { $0 == "values" }.count == walks, "the cached chain is reused")
        #expect(ax.sets == ["set \(Self.manual)=true \(Self.pid)"])
        _ = await tree.chain(at: Self.interior.applying(.init(translationX: 20, y: 0)), in: Self.window)
        #expect(ax.sets.count == 1, "tried once per app")
    }

    @Test func aChainEndingInAnotherWindowNeverSwitches() async throws {
        let group = hiddenTree()
        let other = FakeAX.token()
        ax.add(other, .init(role: kAXWindowRole, frame: Self.axWindow.offsetBy(dx: 300, dy: 0)))
        ax.update(group) { $0.parent = other }
        let tree = try makeTree(makeAccess())
        #expect(await tree.chain(at: Self.interior, in: Self.window) == nil)
        #expect(!ax.calls.contains { $0.hasPrefix("read ") || $0.hasPrefix("set ") })
    }

    // MARK: Review 1 finding 5 — only a value read is changed

    private func trySwitch(_ access: WindowPartAccess, pid: pid_t = pid) async -> WindowPartAXEngine.SwitchResult {
        await access.engine.enableTreeIfHidden(pid: pid, kind: .chromium, treeIsEmpty: true)
    }

    private func endSession(_ access: WindowPartAccess) async {
        access.sessionEnded()
        await access.engine.settle()
    }

    @Test func alreadyOnIsLeftAlone() async {
        ax.appValues[Self.enhanced] = kCFBooleanTrue
        let access = makeAccess()
        #expect(await trySwitch(access) == .notSwitched)
        await endSession(access)
        #expect(ax.sets.isEmpty)
    }

    @Test func knownOffIsSwitchedAndPutBack() async {
        ax.appValues[Self.enhanced] = NSNumber(value: 0)
        let access = makeAccess()
        #expect(await trySwitch(access) == .switched)
        await endSession(access)
        #expect(ax.sets == ["set \(Self.enhanced)=true \(Self.pid)", "set \(Self.enhanced)=false \(Self.pid)"])
        #expect(await access.engine.pendingRestores.isEmpty)
    }

    @Test func aFailedReadChangesNothing() async {
        ax.readError = .attributeUnsupported
        let access = makeAccess()
        #expect(await trySwitch(access) == .notSwitched)
        await endSession(access)
        #expect(ax.sets.isEmpty)
    }

    @Test func anInvalidValueChangesNothing() async {
        ax.appValues[Self.enhanced] = "yes" as NSString
        let access = makeAccess()
        #expect(await trySwitch(access) == .notSwitched)
        await endSession(access)
        #expect(ax.sets.isEmpty)
    }

    /// Electron without a readable `AXManualAccessibility` (a set-only
    /// build): no switch — the known limitation, whole windows instead.
    @Test func anElectronAppWithoutAReadableSwitchIsNotSwitched() async throws {
        hiddenTree()
        ax.readError = .attributeUnsupported
        let access = makeAccess(kind: .electron)
        let tree = try makeTree(access)
        #expect(await tree.chain(at: Self.interior, in: Self.window) != nil)
        await endSession(access)
        #expect(ax.sets.isEmpty)
    }

    @Test func aRefusedSetIsNotRestored() async {
        ax.appValues[Self.enhanced] = kCFBooleanFalse
        ax.setErrors = [.notImplemented]
        let access = makeAccess()
        #expect(await trySwitch(access) == .notSwitched)
        await endSession(access)
        #expect(ax.sets.count == 1)
    }

    /// A set that timed out may have landed: its restore is owed.
    @Test func aTimedOutSetIsStillRestored() async {
        ax.appValues[Self.enhanced] = kCFBooleanFalse
        ax.setErrors = [.cannotComplete]
        let access = makeAccess()
        #expect(await trySwitch(access) == .unresponsive)
        await endSession(access)
        #expect(ax.sets.last == "set \(Self.enhanced)=false \(Self.pid)")
    }

    @Test func aGoneProcessIsNeverSwitched() async {
        ax.appValues[Self.enhanced] = kCFBooleanFalse
        ax.identities = [:]
        #expect(await trySwitch(makeAccess()) == .notSwitched)
        #expect(ax.calls.isEmpty)
    }

    // MARK: Review 1 finding 3 — a failed restore is kept

    @Test func aFailedRestoreIsRetriedUntilItGoesThrough() async {
        ax.appValues[Self.enhanced] = kCFBooleanFalse
        ax.setErrors = [.success, .cannotComplete]
        let access = makeAccess()
        #expect(await trySwitch(access) == .switched)
        await endSession(access)
        #expect(await access.engine.pendingRestores.map(\.pid) == [Self.pid])
        #expect(ax.appValues[Self.enhanced] as? Bool == true)

        await access.engine.attemptPendingRestores() // the app answers again
        #expect(await access.engine.pendingRestores.isEmpty)
        #expect(ax.appValues[Self.enhanced] as? Bool == false)
    }

    @Test func aFailedRestoreIsDroppedOnceItsProcessIsGone() async {
        ax.appValues[Self.enhanced] = kCFBooleanFalse
        ax.setErrors = [.success, .cannotComplete]
        let access = makeAccess()
        _ = await trySwitch(access)
        await endSession(access)
        let sets = ax.sets.count
        ax.identities = [Self.pid: "another process reusing the pid@2"]
        await access.engine.attemptPendingRestores()
        #expect(await access.engine.pendingRestores.isEmpty)
        #expect(ax.sets.count == sets, "never touches a different process")
    }

    @Test func aFailedRestoreIsRetriedOnItsOwn() async {
        ax.appValues[Self.enhanced] = kCFBooleanFalse
        ax.setErrors = [.success, .cannotComplete]
        let access = makeAccess(retryDelay: .milliseconds(5))
        _ = await trySwitch(access)
        await endSession(access)
        for _ in 0..<500 where await !access.engine.pendingRestores.isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await access.engine.pendingRestores.isEmpty)
        #expect(ax.appValues[Self.enhanced] as? Bool == false)
    }

    /// A session that never touches the app: its ledger starts clean, and
    /// its end retries what's still owed.
    @Test func aPendingRestoreOutlivesASessionThatDoesNotUseTheApp() async {
        ax.appValues[Self.enhanced] = kCFBooleanFalse
        ax.setErrors = [.success, .cannotComplete, .cannotComplete]
        let access = makeAccess()
        _ = await trySwitch(access)
        await endSession(access)
        await endSession(access)
        #expect(await access.engine.pendingRestores.count == 1)
        await endSession(access)
        #expect(await access.engine.pendingRestores.isEmpty)
        #expect(ax.sets.count == 4)
    }

    @Test func restoreRetriesBackOffToAMinute() {
        let delays = (1...8).map {
            WindowPartPendingRestores.retryDelay(afterFailures: $0, base: .seconds(2), maximum: .seconds(60))
        }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
    }

    // MARK: Review 2 finding 2 — a later session adopts what is owed

    /// Session A switches the app on; its restore fails, so it's owed.
    private func owedFromAnEarlierSession(_ access: WindowPartAccess) async throws {
        hiddenTree()
        ax.setErrors = [.success, .cannotComplete]
        let tree = try makeTree(access)
        #expect(await tree.chain(at: Self.interior, in: Self.window) != nil)
        await endSession(access)
        #expect(await access.engine.pendingRestores.map(\.pid) == [Self.pid])
        #expect(ax.appValues[Self.manual] as? Bool == true)
    }

    /// The owed retry fires during the later session, then that session ends.
    private func expectRestoredOnlyWhenTheLaterSessionEnds(_ access: WindowPartAccess) async {
        let sets = ax.sets.count
        await access.engine.attemptPendingRestores()
        #expect(ax.sets.count == sets, "the old retry leaves the later session's tree alone")
        #expect(ax.appValues[Self.manual] as? Bool == true)
        await endSession(access)
        #expect(ax.sets.last == "set \(Self.manual)=false \(Self.pid)")
        #expect(ax.appValues[Self.manual] as? Bool == false)
        #expect(await access.engine.pendingRestores.isEmpty)
    }

    @Test func aLaterSessionOverTheStillVisibleTreeAdoptsTheRestore() async throws {
        let access = makeAccess()
        try await owedFromAnEarlierSession(access)
        visibleTree() // the switch is still on: a real tree now
        let tree = try makeTree(access)
        #expect(await tree.chain(at: Self.interior, in: Self.window) != nil)
        #expect(await access.engine.sessionSwitches.map(\.pid) == [Self.pid])
        await expectRestoredOnlyWhenTheLaterSessionEnds(access)
    }

    /// The hidden-tree path with the switch already on: adopted, so not even
    /// read again (and no "already on → not ours" that would leave it to the
    /// old retry).
    @Test func aLaterSessionOnTheAlreadyOnSwitchPathAdoptsTheRestore() async throws {
        let access = makeAccess()
        try await owedFromAnEarlierSession(access)
        let reads = ax.calls.filter { $0.hasPrefix("read ") }.count
        let tree = try makeTree(access)
        #expect(await tree.chain(at: Self.interior, in: Self.window) != nil)
        #expect(ax.calls.filter { $0.hasPrefix("read ") }.count == reads)
        await expectRestoredOnlyWhenTheLaterSessionEnds(access)
    }

    /// Retake: a W + part target, no snap visit — the session uses the app
    /// from its first moment.
    @Test func aRetakeOfAPartTargetAdoptsTheRestoreWithoutASnapVisit() async throws {
        let access = makeAccess()
        try await owedFromAnEarlierSession(access)
        let part = WindowPartTarget(
            windowID: 1, windowFrame: Self.window.frame, frame: Self.window.frame, name: "Web page",
            element: WindowPartElement(processID: Self.pid) { nil }
        )
        access.sessionBegan(target: .windowPart(part, displayID: 1))
        await access.engine.settle()
        #expect(await access.engine.sessionSwitches.map(\.pid) == [Self.pid])
        await expectRestoredOnlyWhenTheLaterSessionEnds(access)
    }

    /// V3's poll during a recording uses the app too.
    @Test func readingARetainedPartAdoptsTheRestore() async throws {
        let access = makeAccess()
        visibleTree()
        let tree = try makeTree(access)
        let element = try #require(await tree.chain(at: Self.interior, in: Self.window)?.nodes.last?.element)
        await endSession(access)
        let group = FakeAX.token()
        ax.add(group, .init(role: kAXGroupRole, frame: Self.axWindow, parent: windowElement))
        ax.hit = group
        ax.appValues[Self.manual] = kCFBooleanFalse
        ax.setErrors = [.success, .cannotComplete]
        let other = try makeTree(access)
        #expect(await other.chain(at: Self.interior, in: Self.window) != nil)
        await endSession(access)
        #expect(await access.engine.pendingRestores.count == 1)
        await beginSession(access) // the recording
        _ = await element.currentFrame()
        #expect(await access.engine.pendingRestores.isEmpty)
        await expectRestoredOnlyWhenTheLaterSessionEnds(access)
    }

    // MARK: Review V3 finding 2 — no read after the session's restores

    /// Owed from an earlier session: the switch went on, its restore didn't
    /// go through (the app stays hung, so every later restore fails too).
    private func owedWithAHungApp(_ access: WindowPartAccess) async {
        ax.appValues[Self.enhanced] = kCFBooleanFalse
        #expect(await trySwitch(access) == .switched)
        ax.hungPIDs = [Self.pid]
        await endSession(access)
        #expect(await access.engine.pendingRestores.count == 1)
    }

    /// The app answers again: the owed restore goes through on its own retry.
    private func expectTheOwedRestoreStillRetries(_ access: WindowPartAccess) async {
        #expect(await access.engine.sessionSwitches.isEmpty, "never adopted into an ended session")
        #expect(await access.engine.pendingRestores.count == 1)
        ax.hungPIDs = []
        await access.engine.attemptPendingRestores()
        #expect(await access.engine.pendingRestores.isEmpty)
        #expect(ax.appValues[Self.enhanced] as? Bool == false)
    }

    /// A poll whose read reaches the executor after the session ended (a
    /// cancelled start that resumed, a late task): the app isn't messaged
    /// and what it owes stays with the retry.
    @Test func aPartReadAfterTheSessionEndedNeitherReadsNorAdopts() async throws {
        visibleTree()
        let access = makeAccess(kind: .chromium)
        let tree = try makeTree(access)
        let element = try #require(await tree.chain(at: Self.interior, in: Self.window)?.nodes.last?.element)
        await beginSession(access)
        await owedWithAHungApp(access)
        let calls = ax.calls.count
        #expect(await element.currentFrame() == nil)
        #expect(ax.calls.count == calls, "not messaged between sessions")
        await expectTheOwedRestoreStillRetries(access)
    }

    /// A read requested on the main actor **before** the session's end is
    /// posted runs before it — the request is enqueued in program order, not
    /// after a hop — so it is that session's use of the app.
    @Test func aPartReadRequestedBeforeTheEndIsAnsweredInsideTheSession() async throws {
        visibleTree()
        let access = makeAccess()
        let tree = try makeTree(access)
        let element = try #require(await tree.chain(at: Self.interior, in: Self.window)?.nodes.last?.element)
        await beginSession(access)
        let read = Task { await element.currentFrame() }
        let end = Task { access.sessionEnded() }
        #expect(await read.value == CGRect(x: 100, y: 100, width: 250, height: 600))
        await end.value
        await access.engine.settle()
        #expect(await element.currentFrame() == nil, "after the end: no read")
    }

    /// The reviewer's repro: Retake and Cancel in the same main-actor turn,
    /// with the app still not answering — the Retake's look-up never runs,
    /// so the restore stays owed and retries once the app answers.
    @Test func aRetakeCancelledBeforeItsLookUpLeavesTheOwedRestoreToItsRetry() async throws {
        visibleTree()
        let access = makeAccess(kind: .chromium)
        let tree = try makeTree(access)
        let element = try #require(await tree.chain(at: Self.interior, in: Self.window)?.nodes.last?.element)
        await owedWithAHungApp(access)

        let h = RecordingCoordinatorTests.Harness()
        defer { h.cleanUp() }
        h.coordinator.windowParts = access
        h.windowObservation = .onScreen(Self.window.frame)
        let sidebar = CGRect(x: 100, y: 100, width: 250, height: 600)
        let target = RecordingTarget.windowPart(
            WindowPartTarget(windowID: 1, windowFrame: Self.window.frame, frame: sidebar, name: "Sidebar", element: element),
            displayID: 1
        )
        #expect(h.coordinator.beginSession(target: target, userApp: nil))
        h.coordinator.handle(.command(.record))
        for _ in 0..<500 where !h.log.entries.contains("chrome.started") {
            try? await Task.sleep(for: .milliseconds(2))
        }
        h.coordinator.stop()
        for _ in 0..<500 where !h.isPresenting {
            try? await Task.sleep(for: .milliseconds(2))
        }
        await access.engine.settle()
        #expect(await access.engine.pendingRestores.count == 1, "the take's end couldn't restore either")

        h.window?.onRetake?()
        h.coordinator.handle(.command(.cancel))
        #expect(!h.coordinator.isSessionActive)
        try? await Task.sleep(for: .milliseconds(50)) // the look-up task's turn
        await access.engine.settle()
        await expectTheOwedRestoreStillRetries(access)
    }

    // MARK: Review V3 finding 1 — the live frame is clipped like the pick

    /// AX space. A scroll view below a 100 pt toolbar; inside it a narrower
    /// table that is far taller than the scroll view (its rows scroll).
    private static let axViewport = CGRect(x: 100, y: 400, width: 800, height: 500)
    private static let axTable = CGRect(x: 100, y: -200, width: 400, height: 1500)

    @discardableResult
    private func scrolledTableTree() -> (viewport: AXUIElement, table: AXUIElement) {
        let viewport = FakeAX.token()
        let table = FakeAX.token()
        ax.add(viewport, .init(role: "AXScrollArea", frame: Self.axViewport, parent: windowElement, childCount: 1))
        ax.add(table, .init(role: "AXTable", frame: Self.axTable, parent: viewport, childCount: 40))
        ax.hit = table
        return (viewport, table)
    }

    /// Picker → W + part target → the recording's poll and a Retake: the
    /// part is what the picker showed (the table as far as the scroll view
    /// shows it), not the table's own frame with the window around it — and
    /// it follows the scroll view when that resizes.
    @Test func anOversizedNarrowerPartIsPolledAndRetakenAsShown() async throws {
        let (viewport, _) = scrolledTableTree()
        let access = makeAccess(kind: .other)
        let tree = try makeTree(access)
        let point = CGPoint(x: 300, y: 350)
        let chain = await tree.chain(at: point, in: Self.window)
        let levels = WindowPartSelection.levels(window: Self.window.frame, chain: chain, at: point)
        let shown = CGRect(x: 100, y: 100, width: 400, height: 500)
        #expect(levels.map(\.frame) == [Self.window.frame, CGRect(x: 100, y: 100, width: 800, height: 500), shown])
        let table = try #require(levels.last)
        let target = WindowSnapCandidates.target(
            for: Self.window, part: SnapPart(frame: table.frame, name: table.name, element: table.element),
            kind: .window, screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 1000), displayID: 1
        )
        let element = try #require(table.element)
        #expect(target.frame == shown)

        await beginSession(access)
        let window = WindowObservation.onScreen(Self.window.frame)
        var crop = PartCropTracker(part: target.frame, window: Self.window.frame, scale: 2)
        let start = crop.sourceRect
        let live = await element.currentFrame()
        #expect(live == shown)
        let moved = crop.observe(part: live, windowBefore: window, windowAfter: window)
        #expect(!moved, "nothing moved: the crop stays")
        #expect(crop.sourceRect == start)

        // The scroll view gets 100 pt shorter at the bottom.
        ax.update(viewport) { $0.frame.size.height = 400 }
        let shorter = CGRect(x: 100, y: 200, width: 400, height: 400)
        let resized = await element.currentFrame()
        #expect(resized == shorter)
        let followed = crop.observe(part: resized, windowBefore: window, windowAfter: window)
        #expect(followed)
        #expect(crop.sourceRect == CGRect(x: 0, y: 100, width: 400, height: 400))

        // Retake reads the same visible frame.
        #expect(target.refreshedForRetake(livePartFrame: resized, window: window).frame == shorter)
    }

    /// A part scrolled wholly out of its viewport, or taken out of its
    /// window, has no visible frame: nil, so the last rect is kept (Q37).
    @Test func aPartScrolledOutOrDetachedHasNoVisibleFrame() async throws {
        let (viewport, table) = scrolledTableTree()
        let access = makeAccess(kind: .other)
        let tree = try makeTree(access)
        let element = try #require(await tree.chain(at: CGPoint(x: 300, y: 350), in: Self.window)?.nodes.last?.element)
        await beginSession(access)
        ax.update(table) { $0.frame.origin.y = 2000 }
        #expect(await element.currentFrame() == nil)
        ax.update(table) { $0.frame.origin.y = -200 }
        ax.update(viewport) { $0.parent = nil }
        #expect(await element.currentFrame() == nil)
    }


    @Test func aPartTargetOfAnotherProcessReusingThePidDropsTheRecord() async throws {
        let access = makeAccess()
        try await owedFromAnEarlierSession(access)
        ax.identities = [Self.pid: "another process@2"]
        let part = WindowPartTarget(
            windowID: 1, windowFrame: Self.window.frame, frame: Self.window.frame, name: "Web page",
            element: WindowPartElement(processID: Self.pid) { nil }
        )
        let sets = ax.sets.count
        access.sessionBegan(target: .windowPart(part, displayID: 1))
        await access.engine.settle()
        #expect(await access.engine.pendingRestores.isEmpty)
        #expect(await access.engine.sessionSwitches.isEmpty)
        await endSession(access)
        #expect(ax.sets.count == sets, "never written to the new process")
    }

    @Test func pendingRecordsKeepTheEarliestOriginal() {
        var pending = WindowPartPendingRestores()
        let first = WindowPartSwitchRecord(pid: 1, identity: "a@1", treeSwitch: .manualAccessibility, original: false)
        pending.add([first])
        pending.add([WindowPartSwitchRecord(pid: 1, identity: "a@1", treeSwitch: .manualAccessibility, original: true)])
        #expect(pending.records == [first])
        let reused = WindowPartSwitchRecord(pid: 1, identity: "b@2", treeSwitch: .manualAccessibility, original: false)
        pending.add([reused])
        #expect(pending.records == [reused])
        #expect(pending.take(pid: 1) == [reused])
        #expect(pending.isEmpty)
    }

    // MARK: Review 1 finding 2 — quitting restores, once

    @Test func quittingRestoresOnceAndALaterEndDoesNothing() async {
        ax.appValues[Self.enhanced] = kCFBooleanFalse
        let access = makeAccess()
        _ = await trySwitch(access)
        access.applicationWillTerminate()
        #expect(ax.sets.last == "set \(Self.enhanced)=false \(Self.pid)")
        await endSession(access)
        #expect(ax.sets.count == 2)
    }

    @Test func quittingTriesWhatIsStillOwedOnceWithoutARetry() async {
        ax.appValues[Self.enhanced] = kCFBooleanFalse
        ax.setErrors = [.success, .cannotComplete, .cannotComplete]
        let access = makeAccess(retryDelay: .milliseconds(5))
        _ = await trySwitch(access)
        await endSession(access) // fails; a retry is scheduled
        access.applicationWillTerminate() // fails again; no retry after a quit
        try? await Task.sleep(for: .milliseconds(40))
        #expect(ax.sets.count == 3)
    }

    /// The quit waits for the executor at most its bound, even when a hung
    /// app holds it.
    @Test func quittingWaitsAtMostItsBound() {
        let access = makeAccess()
        let gate = DispatchSemaphore(value: 0)
        access.engine.post { _ in gate.wait() }
        let start = ProcessInfo.processInfo.systemUptime
        #expect(!access.engine.restoreForQuit(waitingAtMost: 0.1))
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.5)
        gate.signal()
    }

    // MARK: Review 1 finding 6 — the prompting session stays whole-window

    @Test func thePromptingSessionKeepsWholeWindowsTheNextRereads() {
        trusted = false
        let access = makeAccess()
        access.snapModeEntered()
        #expect(prompts == 1)
        trusted = true // granted while the session runs
        #expect(access.makeTree() == nil)
        access.snapModeEntered() // S/W again, same session
        #expect(prompts == 1)
        #expect(access.makeTree() == nil)
        access.sessionEnded()
        #expect(access.makeTree() != nil)
    }

    @Test func aSessionThatDidNotPromptRereadsTrustEachVisit() {
        trusted = false
        let settings = SettingsStore(defaults: defaults)
        settings.recordingAccessibilityPrompted = true
        let access = makeAccess(settings: settings)
        access.snapModeEntered()
        #expect(prompts == 0)
        #expect(access.makeTree() == nil)
        trusted = true
        #expect(access.makeTree() != nil)
    }

    /// Prompt once, ever: the flag survives a relaunch (a new store on the
    /// same defaults).
    @Test func thePromptIsShownOnceAcrossLaunches() {
        trusted = false
        makeAccess().snapModeEntered()
        #expect(prompts == 1)
        let relaunched = makeAccess(settings: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!))
        relaunched.snapModeEntered()
        #expect(prompts == 1)
        #expect(SettingsStore(defaults: UserDefaults(suiteName: suiteName)!).recordingAccessibilityPrompted)
    }
}

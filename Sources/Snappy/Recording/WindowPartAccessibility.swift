import AppKit
import ApplicationServices
import Synchronization

// The Accessibility side of window parts (v2, Q34/Q39/Q40): the live tree
// under the pointer, the one-time permission prompt, and the Chromium /
// Electron tree switch that is restored when the session ends. The pure
// rules are at the top (tested); the live types below them are thin.

// MARK: - Permission (Q39) — PURE

/// When to prompt for Accessibility and what Settings → Recording shows.
enum WindowPartPermission {
    /// Prompt only the first time S/W snap mode is entered without access —
    /// never again automatically (Q39) — and only as the bundled app (the
    /// grant belongs to the app bundle; an unbundled `swift run` or the test
    /// runner would prompt for the terminal instead).
    static func shouldPrompt(isTrusted: Bool, alreadyPrompted: Bool, isBundledApp: Bool) -> Bool {
        !isTrusted && !alreadyPrompted && isBundledApp
    }

    /// The Settings → Recording status row.
    struct Status: Equatable {
        let title: String
        let symbolName: String
        let detail: String
        /// Show "Open System Settings…".
        let offersSettings: Bool
    }

    static func status(isTrusted: Bool) -> Status {
        isTrusted
            ? Status(
                title: "Allowed",
                symbolName: "checkmark.circle.fill",
                detail: "S and W can pick part of a window, such as a browser's page area.",
                offersSettings: false
            )
            : Status(
                title: "Needs Accessibility",
                symbolName: "exclamationmark.triangle.fill",
                detail: "Without it, S and W pick whole windows. Turn on Snappy in Privacy & Security › Accessibility.",
                offersSettings: true
            )
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}

// MARK: - Apps that hide their tree (Q40) — PURE

/// The attribute that makes an app build its accessibility tree.
enum WindowPartTreeSwitch: String, Equatable, Sendable {
    /// Chromium browsers (what VoiceOver sets).
    case enhancedUserInterface = "AXEnhancedUserInterface"
    /// Electron apps.
    case manualAccessibility = "AXManualAccessibility"
}

/// Which kind of app owns a window, from its bundle layout.
enum WindowPartAppKind: Equatable, Sendable {
    case electron, chromium, other

    /// Electron ships `Electron Framework.framework`; a Chromium browser or
    /// shell ships `<Name> Framework.framework` whose `Helpers` hold a
    /// renderer helper (`<Name> Helper (Renderer).app`, or `Codex
    /// (Renderer).app` in ChatGPT). `frameworks` are the names in
    /// `Contents/Frameworks`, `helpers` the names in each framework's `Helpers`.
    static func classify(frameworks: [String], helpers: [String]) -> WindowPartAppKind {
        if frameworks.contains("Electron Framework.framework") { return .electron }
        if helpers.contains(where: { $0.hasSuffix(" (Renderer).app") }) { return .chromium }
        return .other
    }

    /// The switch this kind of app answers to; nil for every other app,
    /// which is never touched.
    var treeSwitch: WindowPartTreeSwitch? {
        switch self {
        case .electron: .manualAccessibility
        case .chromium: .enhancedUserInterface
        case .other: nil
        }
    }

    /// Reads the layout of the app at `bundleURL` (two directory listings).
    static func of(bundleURL: URL?) -> WindowPartAppKind {
        guard let bundleURL else { return .other }
        let fileManager = FileManager.default
        let frameworksURL = bundleURL.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        let frameworks = (try? fileManager.contentsOfDirectory(atPath: frameworksURL.path)) ?? []
        let helpers = frameworks.filter { $0.hasSuffix(".framework") }.flatMap { framework in
            let helpersURL = frameworksURL.appending(path: "\(framework)/Helpers", directoryHint: .isDirectory)
            return (try? fileManager.contentsOfDirectory(atPath: helpersURL.path)) ?? []
        }
        return classify(frameworks: frameworks, helpers: helpers)
    }
}


/// One switch Snappy turned on (Q40): what to put back, on which process.
struct WindowPartSwitchRecord: Equatable, Sendable {
    let pid: pid_t
    /// The process it was set on (bundle id + launch date), so a restore
    /// retried later never touches a new process that reused the pid.
    let identity: String
    let treeSwitch: WindowPartTreeSwitch
    /// The value read before switching on — what the restore writes back.
    let original: Bool
}

/// Which app got which switch this session (Q40): tried **once per app**,
/// only for Chromium / Electron, only when its tree under the pointer came
/// back empty, and only recorded when Snappy actually changed it — so the
/// session's end puts back exactly what Snappy switched on. PURE, tested.
struct WindowPartSwitchLedger: Equatable, Sendable {
    private var tried: Set<pid_t> = []
    private(set) var switched: [pid_t: WindowPartSwitchRecord] = [:]

    /// The switch to try for `pid` now, or nil (not that kind of app, the
    /// tree isn't empty, or already tried). Marks the app as tried.
    mutating func switchToTry(pid: pid_t, kind: WindowPartAppKind, treeIsEmpty: Bool) -> WindowPartTreeSwitch? {
        guard treeIsEmpty, let treeSwitch = kind.treeSwitch, !tried.contains(pid) else { return nil }
        tried.insert(pid)
        return treeSwitch
    }

    /// Snappy changed the switch (from a value it read).
    mutating func didSwitch(_ record: WindowPartSwitchRecord) {
        switched[record.pid] = record
    }

    /// This session uses a process whose restore an earlier session still
    /// owes: the record becomes this session's (restored when it ends), and
    /// the app isn't switched again. The owed record is the older one, so
    /// its `original` — the earliest value read — wins.
    mutating func adopt(_ record: WindowPartSwitchRecord) {
        tried.insert(record.pid)
        switched[record.pid] = record
    }

    /// Everything to put back, once; the ledger starts over.
    mutating func takeForRestore() -> [WindowPartSwitchRecord] {
        let restore = switched.values.sorted { $0.pid < $1.pid }
        self = WindowPartSwitchLedger()
        return restore
    }
}

/// Restores that haven't gone through yet — an app that didn't answer when
/// the session ended. Ownership records per process (pid + identity, the
/// earliest original value), kept apart from the next session's ledger and
/// retried (with a growing delay, least recently tried first) until the
/// write succeeds or the process that got the switch is gone. A later session that uses the process
/// **takes** its record (`take(pid:)` → `WindowPartSwitchLedger.adopt`), so
/// no retry switches the tree off under it. PURE, tested.
struct WindowPartPendingRestores: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case restored, failed, processGone }

    private(set) var records: [WindowPartSwitchRecord] = []
    /// Attempts in a row that left something pending (the retry delay).
    private(set) var failedAttempts = 0

    var isEmpty: Bool { records.isEmpty }

    /// One record per process and switch: an existing record for the same
    /// process keeps its (earlier) original; one for a process that reused
    /// the pid is replaced.
    mutating func add(_ new: [WindowPartSwitchRecord]) {
        for record in new {
            if let index = records.firstIndex(where: { $0.pid == record.pid && $0.treeSwitch == record.treeSwitch }) {
                guard records[index].identity != record.identity else { continue }
                records.remove(at: index)
            }
            records.append(record)
        }
    }

    /// Hands over (and forgets) what is owed on `pid`.
    mutating func take(pid: pid_t) -> [WindowPartSwitchRecord] {
        let taken = records.filter { $0.pid == pid }
        records.removeAll { $0.pid == pid }
        return taken
    }

    /// One attempt per record, least recently tried first, while
    /// `hasTime()`. What failed or wasn't reached stays — what failed moves
    /// **behind** what wasn't reached, so apps that hang at the front can't
    /// use up every batch's time while responsive ones wait forever.
    mutating func attempt(while hasTime: () -> Bool, _ restore: (WindowPartSwitchRecord) -> Outcome) {
        var failed: [WindowPartSwitchRecord] = []
        var unreached: [WindowPartSwitchRecord] = []
        for record in records {
            guard unreached.isEmpty, hasTime() else {
                unreached.append(record)
                continue
            }
            if restore(record) == .failed { failed.append(record) }
        }
        records = unreached + failed
        failedAttempts = records.isEmpty ? 0 : failedAttempts + 1
    }

    /// `base`, doubling per failed attempt, at most `maximum`.
    static func retryDelay(afterFailures failures: Int, base: Duration, maximum: Duration) -> Duration {
        let factor = 1 << min(max(failures - 1, 0), 16)
        return min(base * factor, maximum)
    }
}

// MARK: - Session hooks

/// What the recording coordinator tells the window-part side: a session
/// began (on which target), snap mode was entered (the one-time prompt,
/// Q39), the session ended, and Snappy is quitting (both restore the tree
/// switches, Q40). `WindowPartAccess` in the app, a fake in tests.
@MainActor
protocol WindowPartSessionHooking: AnyObject {
    /// Every new session, Retake included: a W + part target uses its app's
    /// tree from the start, so a restore still owed on it waits for this
    /// session's end.
    func sessionBegan(target: RecordingTarget)
    func snapModeEntered()
    func sessionEnded()
    /// Graceful quit: the session's end never runs, so restore now (one
    /// bounded attempt). Idempotent with a later `sessionEnded`.
    func applicationWillTerminate()
}

// MARK: - Accessibility messaging

/// Every Accessibility call window parts make — the live API in the app, a
/// fake in tests (a slow or hung app, a failed read, a failed restore).
/// Called **only on the AX executor** (`WindowPartAXEngine`), never on the
/// main thread. Points are AX's (top-left global).
protocol WindowPartAXMessaging: Sendable {
    func application(_ pid: pid_t) -> AXUIElement
    func element(at point: CGPoint, in app: AXUIElement) -> (AXError, AXUIElement?)
    /// One round trip for several attributes; an attribute that fails comes
    /// back as an `AXValue` of type `.axError` in its slot.
    func values(of attributes: [String], of element: AXUIElement) -> (AXError, [AnyObject])
    func childCount(of element: AXUIElement) -> (AXError, Int)
    func value(of attribute: String, of element: AXUIElement) -> (AXError, AnyObject?)
    func setValue(_ value: Bool, of attribute: String, on element: AXUIElement) -> AXError
    /// Monotonic seconds — what budgets and back-offs are measured in.
    func now() -> TimeInterval
}

/// The live Accessibility API. **Every** element gets `timeout` right before
/// it is messaged: an AX timeout belongs to the one object it is set on
/// (`AXUIElementSetMessagingTimeout`), and the hit element, its parents, a
/// retained part and a restore's application object are all different
/// objects — unset, each would wait the system's default of several seconds
/// on a hung app (on the AX executor: no stall on screen, but nothing else
/// gets through meanwhile).
final class WindowPartLiveAX: WindowPartAXMessaging {
    static let messagingTimeout: Float = 0.25

    private func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return element
    }

    func application(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    func element(at point: CGPoint, in app: AXUIElement) -> (AXError, AXUIElement?) {
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(bounded(app), Float(point.x), Float(point.y), &hit)
        return (error, hit)
    }

    func values(of attributes: [String], of element: AXUIElement) -> (AXError, [AnyObject]) {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(bounded(element), attributes as CFArray, [], &values)
        return (error, (values as? [AnyObject]) ?? [])
    }

    func childCount(of element: AXUIElement) -> (AXError, Int) {
        var count = 0
        let error = AXUIElementGetAttributeValueCount(bounded(element), kAXChildrenAttribute as CFString, &count)
        return (error, count)
    }

    func value(of attribute: String, of element: AXUIElement) -> (AXError, AnyObject?) {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(bounded(element), attribute as CFString, &value)
        return (error, value)
    }

    func setValue(_ value: Bool, of attribute: String, on element: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(bounded(element), attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

// MARK: - Queries (values only)

/// Which pointer query is the latest one of a snap visit — shared by the
/// main actor (which bumps it) and the AX executor (which skips a query
/// once a newer one exists). Latest wins.
final class WindowPartQueryTicket: Sendable {
    private let latest = Atomic<UInt64>(0)

    /// A new latest query.
    func next() -> UInt64 {
        latest.wrappingAdd(1, ordering: .relaxed).newValue
    }

    func isLatest(_ query: UInt64) -> Bool {
        latest.load(ordering: .relaxed) == query
    }
}

/// One pointer query, as plain values (AppKit global).
struct WindowPartQuery: Equatable, Sendable {
    /// The snap visit (one live tree) asking.
    let visit: UInt64
    let sequence: UInt64
    let processID: pid_t
    let point: CGPoint
    let window: CGRect
    let primaryDisplayHeight: CGFloat
}

/// What the AX executor answers: the chain (its elements as opaque handles)
/// and whether the tree switch just went on (look again later).
struct WindowPartQueryResult: Equatable, Sendable {
    var chain: WindowPartChain?
    var switched = false
}

// MARK: - The AX executor

/// **All** Accessibility messaging for window parts, and every `AXUIElement`
/// it holds, live here — an actor on its own serial queue, never the main
/// thread. The main actor sends plain values in and gets plain values back
/// (rects, roles, names, opaque element handles), so a slow or hung app can
/// never stall the pointer, Esc or the glide:
/// - **Pointer queries** (`requestChain`) are latest-wins: a query a newer
///   one superseded is skipped, its answer never delivered.
/// - **Element handles** (`WindowPartElement`) map to elements kept here;
///   `currentFrame()` posts a read of the part's visible frame (its own,
///   clipped by its live ancestors) with back-off — what V3 polls — and
///   only while a session is open.
/// - **Tree switches and restores** (Q40): the session's ledger, the
///   restores still owed (adopted by a later session that uses the process)
///   and their retries.
///
/// Per-call timeouts, the query budget, per-visit quarantine and the
/// frame-read back-off still apply — they keep one hung app from hogging
/// the executor, which every app's queries share.
actor WindowPartAXEngine {
    /// The most one pointer query may spend messaging an app, end to end —
    /// hit test, the walk (or the cached chain) and the tree switch. Checked
    /// after every call: over it, no further call starts and the app is
    /// whole-window only for the rest of the visit. A soft deadline — the
    /// call in flight when it passes still finishes, so a query takes at
    /// most the budget plus one call (`WindowPartLiveAX.messagingTimeout`).
    static let queryBudget: TimeInterval = 0.5
    /// The most one batch of restores may take; the rest wait for the retry.
    static let restoreBudget: TimeInterval = 0.5
    static let windowMatchTolerance: CGFloat = 2
    /// Deeper than any real UI; a cycle guard.
    static let maximumDepth = 64
    static let maximumRestoreRetryDelay: Duration = .seconds(60)

    /// Set by a tree switch: switched on, left alone, or the app didn't
    /// answer (then it's whole-window only for the rest of the visit).
    enum SwitchResult: Equatable, Sendable { case switched, notSwitched, unresponsive }

    private let queue = DispatchSerialQueue(label: "com.tefa.snappy.window-parts.ax", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let messaging: any WindowPartAXMessaging
    private let processIdentity: @Sendable (pid_t) -> String?
    private let appKind: @Sendable (pid_t) -> WindowPartAppKind
    private let primaryDisplayHeight: @MainActor @Sendable () -> CGFloat
    private let restoreRetryDelay: Duration

    private var visits: [UInt64: Visit] = [:]
    private var elements: [UInt64: Retained] = [:]
    private var nextElementID: UInt64 = 0
    private var ledger = WindowPartSwitchLedger()
    private var pending = WindowPartPendingRestores()
    private var retry: Task<Void, Never>?
    /// Between a session's begin and its end (both posted in order with
    /// every read): a retained part is read — and adopts what is owed on
    /// its app — only then, so nothing reaches an app after its session's
    /// restores (Q40).
    private(set) var isInSession = false
    /// After the quit's last attempt: nothing is retried any more.
    private var isTerminating = false

    init(
        messaging: any WindowPartAXMessaging,
        processIdentity: @escaping @Sendable (pid_t) -> String?,
        appKind: @escaping @Sendable (pid_t) -> WindowPartAppKind,
        primaryDisplayHeight: @escaping @MainActor @Sendable () -> CGFloat,
        restoreRetryDelay: Duration
    ) {
        self.messaging = messaging
        self.processIdentity = processIdentity
        self.appKind = appKind
        self.primaryDisplayHeight = primaryDisplayHeight
        self.restoreRetryDelay = restoreRetryDelay
    }

    isolated deinit {
        retry?.cancel()
    }

    // MARK: Main actor → executor

    /// Runs `work` on the executor, **in the order posted** (one serial
    /// queue), without waiting. Session hooks and pointer queries go this
    /// way, so a session's end is handled before the next session's first
    /// query.
    nonisolated func post(_ work: @escaping @Sendable (isolated WindowPartAXEngine) -> Void) {
        queue.async { self.assumeIsolated { work($0) } }
    }

    /// Answers `query` on the main actor — unless a newer query of its visit
    /// was made by the time it runs (then nothing is delivered).
    nonisolated func requestChain(
        _ query: WindowPartQuery, ticket: WindowPartQueryTicket,
        deliver: @escaping @MainActor @Sendable (WindowPartQueryResult) -> Void
    ) {
        post { engine in
            guard ticket.isLatest(query.sequence) else { return }
            let result = engine.chain(for: query)
            DispatchQueue.main.async { deliver(result) }
        }
    }

    /// A graceful quit: one bounded attempt at every restore (this session's
    /// and those still owed), no retry after it. Blocks the caller at most
    /// `wait` (an in-flight query finishes first). True when it finished.
    @discardableResult
    nonisolated func restoreForQuit(waitingAtMost wait: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        post { engine in
            engine.restoreForQuit()
            done.signal()
        }
        return done.wait(timeout: .now() + wait) == .success
    }

    // MARK: Session

    /// The session uses `pid`'s tree: a restore still owed on it becomes
    /// this session's (finding: an old retry must not switch it off under a
    /// later session).
    func use(_ pid: pid_t) {
        let owed = pending.take(pid: pid)
        guard !owed.isEmpty else { return }
        let identity = processIdentity(pid)
        // A record for a process that reused the pid is simply dropped.
        for record in owed where record.identity == identity {
            ledger.adopt(record)
        }
    }

    /// A recording session began; `pid` is a W + part target's app, which
    /// it uses from the start (Retake: no snap visit needed).
    func sessionBegan(using pid: pid_t?) {
        isInSession = true
        if let pid { use(pid) }
    }

    func sessionEnded() {
        isInSession = false
        pending.add(ledger.takeForRestore())
        attemptPendingRestores()
    }

    private func restoreForQuit() {
        isInSession = false
        isTerminating = true
        retry?.cancel()
        retry = nil
        pending.add(ledger.takeForRestore())
        attemptPendingRestores()
    }

    /// Restores still owed (the app didn't answer yet).
    var pendingRestores: [WindowPartSwitchRecord] { pending.records }

    /// This session's switches, restored when it ends.
    var sessionSwitches: [WindowPartSwitchRecord] { ledger.switched.values.sorted { $0.pid < $1.pid } }

    /// One bounded call per owed restore, for at most `restoreBudget`; what
    /// fails (or isn't reached) is retried later — unless Snappy is quitting.
    func attemptPendingRestores() {
        retry?.cancel()
        retry = nil
        guard !pending.isEmpty else { return }
        let start = messaging.now()
        pending.attempt(while: { messaging.now() - start <= Self.restoreBudget }) { record in
            guard processIdentity(record.pid) == record.identity else { return .processGone }
            let error = messaging.setValue(
                record.original, of: record.treeSwitch.rawValue, on: messaging.application(record.pid)
            )
            return error == .success ? .restored : .failed
        }
        guard !isTerminating, !pending.isEmpty else { return }
        let delay = WindowPartPendingRestores.retryDelay(
            afterFailures: pending.failedAttempts, base: restoreRetryDelay, maximum: Self.maximumRestoreRetryDelay
        )
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.attemptPendingRestores()
        }
    }

    /// The tree under the pointer came back empty: switch it on for that app
    /// (Chromium / Electron only, once per session). Only a value actually
    /// **read** as off is changed — a failed or odd read may hide another
    /// assistive client's `true`, which a restore would then clear.
    /// `isOverBudget` is the pointer query's deadline: past it after the
    /// read, the write never starts.
    func enableTreeIfHidden(
        pid: pid_t, app: AXUIElement, kind: WindowPartAppKind, treeIsEmpty: Bool,
        isOverBudget: () -> Bool = { false }
    ) -> SwitchResult {
        guard let treeSwitch = ledger.switchToTry(pid: pid, kind: kind, treeIsEmpty: treeIsEmpty),
              let identity = processIdentity(pid)
        else { return .notSwitched }
        let attribute = treeSwitch.rawValue
        let (readError, value) = messaging.value(of: attribute, of: app)
        if readError == .cannotComplete || isOverBudget() { return .unresponsive }
        guard readError == .success, let original = value as? Bool else { return .notSwitched }
        // Already on (VoiceOver, another assistive app): not ours to restore.
        guard !original else { return .notSwitched }
        let setError = messaging.setValue(true, of: attribute, on: app)
        // A set that timed out may still have landed: owe its restore too.
        guard setError == .success || setError == .cannotComplete else { return .notSwitched }
        ledger.didSwitch(WindowPartSwitchRecord(pid: pid, identity: identity, treeSwitch: treeSwitch, original: original))
        return setError == .success ? .switched : .unresponsive
    }

    /// `enableTreeIfHidden` on the app's own element (tests).
    func enableTreeIfHidden(pid: pid_t, kind: WindowPartAppKind, treeIsEmpty: Bool) -> SwitchResult {
        enableTreeIfHidden(pid: pid, app: messaging.application(pid), kind: kind, treeIsEmpty: treeIsEmpty)
    }

    // MARK: Visits

    /// One snap visit's state: the apps asked (and which stopped answering),
    /// the last hit and its chain, one handle per element.
    private final class Visit {
        struct App {
            let element: AXUIElement
            let kind: WindowPartAppKind
            var isUnresponsive = false
        }

        var apps: [pid_t: App] = [:]
        var last: (pid: pid_t, hit: AXUIElement, chain: WindowPartChain?)?
        var handles: [CFHashCode: [(element: AXUIElement, handle: WindowPartElement)]] = [:]
    }

    /// The visit's tree went away. Handles it gave out (a W + part target)
    /// keep their elements until they go too.
    func endVisit(_ visit: UInt64) {
        visits[visit] = nil
    }

    /// The tree switch went on and the app has had time to build its tree:
    /// walk again, even over the same deepest element.
    func forgetLastHit(_ visit: UInt64) {
        visits[visit]?.last = nil
    }

    /// Visits still known (tests).
    var visitCount: Int { visits.count }

    // MARK: Pointer queries

    /// The chain under the query's point — `requestChain`'s work, also
    /// callable directly (tests). Bounded: every call by the messaging
    /// timeout, the whole query by `queryBudget`; a call the app can't
    /// complete at **any** stage or a query over budget makes the app
    /// whole-window only for the rest of the visit.
    func chain(for query: WindowPartQuery) -> WindowPartQueryResult {
        let visit = visits[query.visit] ?? Visit()
        visits[query.visit] = visit
        let pid = query.processID
        use(pid)
        let app: Visit.App
        if let known = visit.apps[pid] {
            app = known
        } else {
            app = Visit.App(element: messaging.application(pid), kind: appKind(pid))
            visit.apps[pid] = app
        }
        guard !app.isUnresponsive else { return WindowPartQueryResult() }

        let start = messaging.now()
        let position = CaptureGeometry.cgPoint(fromAppKitGlobal: query.point, primaryDisplayHeight: query.primaryDisplayHeight)
        let (error, hit) = messaging.element(at: position, in: app.element)
        if error == .cannotComplete || isOverBudget(start) { return quarantine(pid, in: visit) }
        guard error == .success, let hit else { return WindowPartQueryResult() }

        let chain: WindowPartChain?
        if let last = visit.last, last.pid == pid, CFEqual(last.hit, hit) {
            chain = last.chain
        } else {
            switch walk(from: hit, pid: pid, app: app, query: query, visit: visit, start: start) {
            case .stalled: return quarantine(pid, in: visit)
            case .done(let walked): chain = walked
            }
            visit.last = (pid, hit, chain)
        }
        // Only a chain that reached this window says anything about its tree
        // (nil: another window of the app is on top, or AX failed). Asked for
        // a cached chain too: the pointer may have just left the edge band
        // over the same element. The ledger tries each app once.
        guard let chain, !WindowPartSelection.isOnWindowEdge(query.point, window: query.window) else {
            return WindowPartQueryResult(chain: chain)
        }
        let switched = enableTreeIfHidden(
            pid: pid, app: app.element, kind: app.kind,
            treeIsEmpty: WindowPartSelection.isTreeEmpty(chain, window: query.window),
            isOverBudget: { isOverBudget(start) }
        )
        if switched == .unresponsive || isOverBudget(start) { return quarantine(pid, in: visit) }
        return WindowPartQueryResult(chain: chain, switched: switched == .switched)
    }

    private func quarantine(_ pid: pid_t, in visit: Visit) -> WindowPartQueryResult {
        visit.apps[pid]?.isUnresponsive = true
        visit.last = nil
        return WindowPartQueryResult()
    }

    private func isOverBudget(_ start: TimeInterval) -> Bool {
        messaging.now() - start > Self.queryBudget
    }

    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXParentAttribute, kAXDescriptionAttribute,
    ]

    private enum Walk {
        case done(WindowPartChain?)
        /// A call didn't complete, or the query went over budget.
        case stalled
    }

    /// Deepest element → its window; `.done(nil)` when it doesn't end in the
    /// query's window.
    private func walk(
        from hit: AXUIElement, pid: pid_t, app: Visit.App, query: WindowPartQuery, visit: Visit, start: TimeInterval
    ) -> Walk {
        var nodes: [WindowPartNode] = []
        var current: AXUIElement? = hit
        for _ in 0..<Self.maximumDepth {
            guard let element = current else { return .done(nil) }
            let (error, values) = messaging.values(of: Self.attributes, of: element)
            if error == .cannotComplete || isOverBudget(start) { return .stalled }
            guard error == .success, values.count == 6 else { return .done(nil) }
            let role = values[0] as? String ?? ""
            let frame = Self.axRect(position: values[2], size: values[3]).map {
                CaptureGeometry.appKitRect(fromCGGlobal: $0, primaryDisplayHeight: query.primaryDisplayHeight)
            }
            if role == kAXWindowRole {
                guard let frame, Self.matches(frame, query.window) else { return .done(nil) }
                return .done(WindowPartChain(nodes: nodes.reversed(), webContentIsAppUI: app.kind == .electron))
            }
            var hasChildren = true
            if nodes.isEmpty {
                let (childError, count) = messaging.childCount(of: element)
                if childError == .cannotComplete || isOverBudget(start) { return .stalled }
                hasChildren = childError == .success && count > 0
            }
            nodes.append(WindowPartNode(
                role: role,
                subrole: values[1] as? String,
                label: values[5] as? String,
                frame: frame ?? .null,
                hasChildren: hasChildren,
                element: handle(for: element, pid: pid, in: visit)
            ))
            current = Self.element(values[4])
        }
        return .done(nil)
    }

    /// AX's own (top-left global) rect from a position and a size value.
    static func axRect(position: AnyObject, size: AnyObject) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func element(_ value: AnyObject) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func matches(_ frame: CGRect, _ window: CGRect) -> Bool {
        abs(frame.minX - window.minX) <= windowMatchTolerance && abs(frame.minY - window.minY) <= windowMatchTolerance
            && abs(frame.maxX - window.maxX) <= windowMatchTolerance
            && abs(frame.maxY - window.maxY) <= windowMatchTolerance
    }

    // MARK: Retained elements (what V3 polls)

    /// An element some handle refers to, with its read back-off.
    private struct Retained {
        let element: AXUIElement
        let pid: pid_t
        var failures = 0
        var retryAt: TimeInterval = -.infinity
    }

    /// 1 s after the first stalled read, doubling to 8 s.
    static func frameReadBackoff(afterFailures failures: Int) -> TimeInterval {
        min(8, Double(1 << min(max(failures - 1, 0), 3)))
    }

    private func handle(for element: AXUIElement, pid: pid_t, in visit: Visit) -> WindowPartElement {
        let hash = CFHash(element)
        if let known = visit.handles[hash]?.first(where: { CFEqual($0.element, element) }) { return known.handle }
        nextElementID += 1
        let id = nextElementID
        elements[id] = Retained(element: element, pid: pid)
        let height = primaryDisplayHeight
        let handle = WindowPartElement(
            processID: pid,
            release: { [weak self] in self?.post { $0.elements[id] = nil } },
            // Posted at once: in order with the session hooks (see `post`).
            request: { [weak self] deliver in
                guard let self else { return deliver(nil) }
                post { engine in
                    let frame = engine.visibleFrame(of: id)
                    Task { @MainActor in
                        deliver(frame.map { CaptureGeometry.appKitRect(fromCGGlobal: $0, primaryDisplayHeight: height()) })
                    }
                }
            }
        )
        visit.handles[hash, default: []].append((element, handle))
        return handle
    }

    /// Elements still held for some handle (tests).
    var retainedElementCount: Int { elements.count }

    private static let frameAttributes = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute]

    /// One retained element's **visible** frame (AX space): its own frame
    /// clipped by every ancestor up to its window, read live — the rule the
    /// picker applied (`WindowPartSelection.visibleFrame`), so a part larger
    /// than the scroll view around it is recorded as shown, not with the
    /// window around it (review V3 finding 1). One multi-attribute round
    /// trip per level, bounded like a pointer query (`queryBudget`); after a
    /// call the app can't complete, or a read over budget, the app isn't
    /// asked again for the back-off (nil meanwhile → keep the last rect,
    /// Q37). Nil when the element is gone, no longer in a window, or wholly
    /// scrolled out of view — and **outside a session**: no read, no
    /// adoption (reading counts as the session using that app's tree).
    func visibleFrame(of id: UInt64) -> CGRect? {
        guard isInSession, var retained = elements[id] else { return nil }
        use(retained.pid)
        guard messaging.now() >= retained.retryAt else { return nil }
        let start = messaging.now()
        // The element's own frame first, then each ancestor's.
        var frames: [CGRect] = []
        var current: AXUIElement? = retained.element
        var inWindow = false
        for _ in 0..<Self.maximumDepth {
            guard let element = current else { break }
            let (error, values) = messaging.values(of: Self.frameAttributes, of: element)
            if error == .cannotComplete || isOverBudget(start) {
                retained.failures += 1
                retained.retryAt = messaging.now() + Self.frameReadBackoff(afterFailures: retained.failures)
                elements[id] = retained
                return nil
            }
            guard error == .success, values.count == 4 else { break }
            if values[0] as? String == kAXWindowRole {
                inWindow = true
                break
            }
            frames.append(Self.axRect(position: values[1], size: values[2]) ?? .null)
            current = Self.element(values[3])
        }
        retained.failures = 0
        elements[id] = retained
        guard inWindow else { return nil }
        return WindowPartSelection.visibleFrame(of: frames.reversed())
    }
}

// MARK: - Live access

/// The app's Accessibility state for window parts on the main actor: trust,
/// the prompt-once flag and the session hooks. Everything that messages an
/// app — the tree, the switches, the restores — is its `engine`'s.
@MainActor
final class WindowPartAccess: WindowPartSessionHooking {
    static let shared = WindowPartAccess()

    /// How long an app gets to build its tree after the switch before the
    /// picker looks again (Chromium/Electron build it asynchronously).
    static let treeBuildDelay: Duration = .milliseconds(500)
    /// First retry of a restore the app didn't answer; doubles up to the maximum.
    static let restoreRetryDelay: Duration = .seconds(2)
    /// The most a graceful quit waits for its one restore attempt.
    static let quitWait: TimeInterval = 1

    let engine: WindowPartAXEngine
    private let settings: SettingsStore
    private let trusted: @MainActor () -> Bool
    private let showPrompt: @MainActor () -> Void
    private let isBundledApp: Bool
    private let primaryDisplayHeight: @MainActor @Sendable () -> CGFloat
    /// This session showed the prompt: it carries on with whole windows
    /// (Q39) even if access is granted before it ends; the next one rereads.
    private(set) var promptedThisSession = false

    init(
        settings: SettingsStore = .shared,
        messaging: any WindowPartAXMessaging = WindowPartLiveAX(),
        isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        // Shows the system prompt and returns at once. (The option key spelled
        // out: the imported global isn't concurrency-safe in Swift 6.)
        prompt: @escaping @MainActor () -> Void = {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        },
        isBundledApp: Bool = Bundle.main.bundleURL.pathExtension == "app",
        processIdentity: @escaping @Sendable (pid_t) -> String? = WindowPartAccess.liveProcessIdentity,
        appKind: @escaping @Sendable (pid_t) -> WindowPartAppKind = {
            WindowPartAppKind.of(bundleURL: NSRunningApplication(processIdentifier: $0)?.bundleURL)
        },
        primaryDisplayHeight: @escaping @MainActor @Sendable () -> CGFloat = { NSScreen.screens.first?.frame.maxY ?? 0 },
        restoreRetryDelay: Duration = WindowPartAccess.restoreRetryDelay
    ) {
        self.settings = settings
        self.trusted = isTrusted
        self.showPrompt = prompt
        self.isBundledApp = isBundledApp
        self.primaryDisplayHeight = primaryDisplayHeight
        engine = WindowPartAXEngine(
            messaging: messaging, processIdentity: processIdentity, appKind: appKind,
            primaryDisplayHeight: primaryDisplayHeight, restoreRetryDelay: restoreRetryDelay
        )
    }

    /// Bundle id + launch date of a running process; nil once it's gone.
    nonisolated static func liveProcessIdentity(_ pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return "\(app.bundleIdentifier ?? "-")@\(app.launchDate?.timeIntervalSinceReferenceDate ?? 0)"
    }

    /// Accessibility granted (re-read every time: the person may grant or
    /// revoke it while Snappy runs).
    var isTrusted: Bool { trusted() }

    /// The live tree for one snap visit, or nil without access or in the
    /// session that prompted — then S/W pick whole windows exactly as in v1
    /// (Q34, Q39).
    func makeTree() -> WindowPartAXTree? {
        isTrusted && !promptedThisSession
            ? WindowPartAXTree(engine: engine, primaryDisplayHeight: primaryDisplayHeight)
            : nil
    }

    func sessionBegan(target: RecordingTarget) {
        let pid: pid_t? = if case .windowPart(let part, _) = target { part.element?.processID } else { nil }
        engine.post { $0.sessionBegan(using: pid) }
    }

    func snapModeEntered() {
        guard WindowPartPermission.shouldPrompt(
            isTrusted: isTrusted, alreadyPrompted: settings.recordingAccessibilityPrompted, isBundledApp: isBundledApp
        ) else { return }
        settings.recordingAccessibilityPrompted = true
        promptedThisSession = true
        showPrompt()
    }

    /// Restores on the AX executor; returns at once.
    func sessionEnded() {
        promptedThisSession = false
        engine.post { $0.sessionEnded() }
    }

    /// One last bounded attempt at everything — no retry after a quit. The
    /// only place the main thread waits for the executor, at most `quitWait`.
    func applicationWillTerminate() {
        engine.restoreForQuit(waitingAtMost: Self.quitWait)
    }
}

// MARK: - Live tree

/// The Accessibility tree under the pointer for one snap visit
/// (`WindowPartTree`): a main-actor front for the AX executor. Each pointer
/// query goes there as values and comes back later; latest wins (a newer
/// query skips an older one still waiting, and an older answer's pick is
/// dropped — though a tree switch it made still schedules the recheck).
/// What the executor does per query (`WindowPartAXEngine.chain(for:)`):
/// - **App-scoped hit test** (on the hovered window's *application*): the
///   Setup overlay covers the display, so a system-wide hit test would find
///   Snappy.
/// - One multi-attribute round trip per ancestor; the chain is reused while
///   the deepest element under the pointer is the same. Measured live
///   (2026-10-11): the first query to an app ~35–50 ms, then ~0.3 ms per hit
///   test + 1–4 ms per walk of a 26-deep Chromium chain.
/// - Every call is bounded by `WindowPartLiveAX.messagingTimeout`, the whole
///   query by `WindowPartAXEngine.queryBudget`.
/// - The chain must end in the hovered window (its frame within
///   `windowMatchTolerance`), else it's another window of that app on top.
@MainActor
final class WindowPartAXTree: WindowPartTree {
    private static var nextVisit: UInt64 = 0

    /// The tree switch went on — the picker should look again at the pointer.
    var onTreeChange: (@MainActor () -> Void)?

    private let engine: WindowPartAXEngine
    private let visit: UInt64
    private let ticket = WindowPartQueryTicket()
    private let primaryDisplayHeight: @MainActor () -> CGFloat
    private var waiting: (sequence: UInt64, completion: @MainActor (WindowPartChain?) -> Void)?
    private var recheck: Task<Void, Never>?

    init(engine: WindowPartAXEngine, primaryDisplayHeight: @escaping @MainActor () -> CGFloat) {
        self.engine = engine
        self.primaryDisplayHeight = primaryDisplayHeight
        Self.nextVisit += 1
        visit = Self.nextVisit
    }

    isolated deinit {
        recheck?.cancel()
        let visit = visit
        engine.post { $0.endVisit(visit) }
    }

    func requestChain(at point: CGPoint, in window: SnapWindow, completion: @escaping @MainActor (WindowPartChain?) -> Void) {
        guard let pid = window.processID else {
            waiting = nil
            completion(nil)
            return
        }
        let sequence = ticket.next()
        waiting = (sequence, completion)
        let query = WindowPartQuery(
            visit: visit, sequence: sequence, processID: pid, point: point, window: window.frame,
            primaryDisplayHeight: primaryDisplayHeight()
        )
        engine.requestChain(query, ticket: ticket) { [weak self] result in
            self?.deliver(result, for: sequence)
        }
    }

    private func deliver(_ result: WindowPartQueryResult, for sequence: UInt64) {
        // A switch that went on owes the visit a second look even when its
        // pick is stale: the newer query over the same element reuses the
        // empty chain and can't switch again (the ledger tried the app once).
        if result.switched { scheduleRecheck() }
        guard let waiting, waiting.sequence == sequence else { return }
        self.waiting = nil
        waiting.completion(result.chain)
    }

    private func scheduleRecheck() {
        recheck?.cancel()
        recheck = Task { [weak self] in
            try? await Task.sleep(for: WindowPartAccess.treeBuildDelay)
            guard !Task.isCancelled, let self else { return }
            let visit = visit
            engine.post { $0.forgetLastHit(visit) }
            onTreeChange?()
        }
    }
}

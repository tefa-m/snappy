import AppKit
import ScreenCaptureKit

enum CaptureError: Error {
    case permissionDenied
    case noMatchingDisplay
    case noImage
}

/// One display's frozen full-resolution screenshot, taken *before* Snappy
/// activates so transient UI (context menus, menu-bar menus, tooltips) is still
/// on screen and lands in the pixels.
@MainActor
struct FrozenScreen {
    let screen: NSScreen
    /// The screen's AppKit-global frame **at freeze time**. The overlay size,
    /// the backdrop's 1:1 point mapping and the crop math all use this, never a
    /// re-read `screen.frame`, so they cannot disagree mid-selection.
    let frame: CGRect
    let image: CGImage

    var pixelSize: CGSize {
        CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
    }

    /// The image's own pixels-per-point, not the screen's backing scale — see
    /// `CaptureGeometry.derivedScale`. Guarantees a full-screen selection maps
    /// to the whole image.
    var scale: CGFloat {
        CaptureGeometry.derivedScale(imagePixelSize: pixelSize, displayPointSize: frame.size)
    }
}

/// Thin wrapper around ScreenCaptureKit's screenshot APIs.
@MainActor
enum CaptureEngine {
    /// Fetches shareable content, mapping a TCC denial to `.permissionDenied`.
    /// The first call on a fresh install triggers the system permission prompt.
    static func shareableContent(preferCached: Bool = false) async throws -> SCShareableContent {
        if preferCached, let cached = usableCachedContent() {
            return cached
        }
        do {
            // Only cache what was fetched under the generation we started in:
            // a display change during the await invalidates this result too.
            let generation = cacheGeneration
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if generation == cacheGeneration { cache(content) }
            return content
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw CaptureError.permissionDenied
        }
    }

    /// The `SCDisplay` backing an `NSScreen`.
    static func display(for screen: NSScreen, in content: SCShareableContent) throws -> SCDisplay {
        guard
            let id = displayID(for: screen),
            let display = content.displays.first(where: { $0.displayID == id })
        else {
            throw CaptureError.noMatchingDisplay
        }
        return display
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: - Frozen snapshots

    /// A full-resolution snapshot of every attached display, captured
    /// concurrently. All-or-nothing: a failure on any display propagates rather
    /// than leaving a mix of frozen and unfrozen overlays, so the selection
    /// overlay has exactly one drawing path.
    static func snapshotAllScreens() async throws -> [FrozenScreen] {
        try await snapshots(of: NSScreen.screens)
    }

    /// A full-resolution snapshot of a single display.
    static func snapshot(of screen: NSScreen) async throws -> FrozenScreen {
        guard let frozen = try await snapshots(of: [screen]).first else {
            throw CaptureError.noMatchingDisplay
        }
        return frozen
    }

    private static func snapshots(of screens: [NSScreen]) async throws -> [FrozenScreen] {
        let content = try await contentKeepingPins(shareableContent(preferCached: true))

        // Pair screens with their displays and build the SCK inputs on the main
        // actor; only Sendable values cross into the child tasks.
        var jobs: [(screen: NSScreen, frame: CGRect, scale: CGFloat, id: CGDirectDisplayID)] = []
        for screen in screens {
            guard
                let id = displayID(for: screen),
                content.displays.contains(where: { $0.displayID == id })
            else { continue } // A display that vanished between fetch and freeze.
            jobs.append((screen, screen.frame, screen.backingScaleFactor, id))
        }
        guard !jobs.isEmpty else { throw CaptureError.noMatchingDisplay }

        // Main-actor tasks, not a task group: SCContentFilter is neither Sendable
        // nor region-transferable, so it cannot cross an isolation boundary. The
        // round-trips still overlap — each `await` inside SCK releases the main
        // actor for the others.
        var inFlight: [Task<CGImage, Error>] = []
        for job in jobs {
            let display = try display(for: job.screen, in: content)
            let filter = filter(for: display, in: content)
            let configuration = configuration(
                pointSize: CGSize(width: display.width, height: display.height),
                scale: job.scale
            )
            inFlight.append(Task { try await screenshot(filter: filter, configuration: configuration) })
        }

        // All-or-nothing: cancel the rest so a failure can't leave half the
        // displays frozen and half live.
        var frozen: [FrozenScreen] = []
        do {
            for (job, task) in zip(jobs, inFlight) {
                let image = try await task.value
                frozen.append(FrozenScreen(screen: job.screen, frame: job.frame, image: image))
            }
        } catch {
            for task in inFlight { task.cancel() }
            throw error
        }
        return frozen
    }

    /// Crops a frozen snapshot and **detaches** the result from the source's
    /// data provider. `CGImage.cropping(to:)` shares the parent's buffer, so a
    /// small selection would otherwise pin the whole ~30–80 MB display image in
    /// memory for as long as the crop lives — and it lives in the preview
    /// panel, then possibly a pin, indefinitely.
    nonisolated static func crop(_ image: CGImage, to pixelRect: CGRect) -> CGImage? {
        guard !pixelRect.isEmpty, let cropped = image.cropping(to: pixelRect) else { return nil }
        // A whole-snapshot selection pins nothing it doesn't already own, so the
        // detaching copy (30–80 MB) would be pure waste.
        if cropped.width == image.width, cropped.height == image.height { return image }

        let width = cropped.width
        let height = cropped.height
        let colorSpace = cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        let context = colorSpace.flatMap {
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: cropped.bitsPerComponent,
                bytesPerRow: 0,
                space: $0,
                bitmapInfo: cropped.bitmapInfo.rawValue
            )
        } ?? CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        guard let context else { return cropped } // Correct, just still attached.
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? cropped
    }

    // MARK: - Capture

    /// Captures a single window (without other content or the desktop).
    static func captureWindow(_ window: SCWindow, scale: CGFloat) async throws -> CGImage {
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        let pixels = CaptureGeometry.pixelSize(of: window.frame, scale: scale)
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)

        return try await screenshot(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }

    /// The content to build an exclusion filter from: `content` itself, or one
    /// fresh fetch when an open pin isn't listed in it yet (see `PinInclusion`).
    static func contentKeepingPins(_ content: SCShareableContent) async throws -> SCShareableContent {
        let listed = Set(content.windows.map(\.windowID))
        guard PinInclusion.needsFreshContent(pinIDs: PinWindowRegistry.windowIDs, listedIDs: listed) else {
            return content
        }
        return try await shareableContent(preferCached: false)
    }

    /// The open pins' `SCWindow`s — the exceptions to Snappy's self-exclusion.
    static func pinWindows(in content: SCShareableContent) -> [SCWindow] {
        let pinIDs = PinWindowRegistry.windowIDs
        return content.windows.filter { pinIDs.contains($0.windowID) }
    }

    /// Excludes Snappy's own windows by **application**, not by window list —
    /// except the open pins, which stay in the picture (`exceptingWindows`).
    /// The window list is a snapshot of a moment; a panel, editor or the
    /// status-bar menu opened after the (possibly cached) content fetch would
    /// not be in it and would be baked into the capture. `SCRunningApplication`
    /// identity survives that churn. Pins are the one list we do need, which is
    /// why `contentKeepingPins` refetches when a pin is newer than the cache.
    private static func filter(for display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pins = pinWindows(in: content)
        if let ownApp = content.applications.first(where: { $0.processID == ownPID }) {
            return SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: pins)
        }
        // Cold start: we may not be listed yet (no on-screen windows of our own).
        let pinIDs = Set(pins.map(\.windowID))
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownPID && !pinIDs.contains($0.windowID)
        }
        return SCContentFilter(display: display, excludingWindows: ownWindows)
    }

    private static func configuration(pointSize: CGSize, scale: CGFloat) -> SCScreenshotConfiguration {
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr  // the whole pipeline (PNG, clipboard, editor) is SDR
        let pixels = CaptureGeometry.pixelSize(of: CGRect(origin: .zero, size: pointSize), scale: scale)
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)
        return configuration
    }

    /// The raw SCK round-trip. Stays on the main actor — `SCContentFilter` is
    /// non-Sendable, so results never cross an isolation boundary.
    private static func screenshot(
        filter: SCContentFilter,
        configuration: SCScreenshotConfiguration
    ) async throws -> CGImage {
        do {
            let output = try await SCScreenshotManager.captureScreenshot(
                contentFilter: filter,
                configuration: configuration
            )
            guard let image = output.sdrImage else { throw CaptureError.noImage }
            // Pixels came back, so the Screen Recording grant is real. This is
            // what unlocks cache warming and the instant overlay.
            noteCaptureSucceeded()
            return image
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw CaptureError.permissionDenied
        }
    }

    // MARK: - Shareable-content cache

    // Fetching SCShareableContent costs 50–150 ms, and for area capture that
    // cost sits between the hot key and the freeze — the window in which the
    // transient UI we want must stay alive, and in which macOS still grants
    // cooperative activation. Caching it removes that from the hot path.
    //
    // Safe to cache, and safe to cache for a long time, because the area path
    // reads only two things out of the content: `displays`, and our own
    // `SCRunningApplication` for the self-exclusion filter. `usableCachedContent`
    // validates both, so the only way a stale entry can be wrong is a display
    // change — which invalidates it outright. Window-list staleness is
    // irrelevant here precisely because self-exclusion is application-based (see
    // `filter(for:in:)`); a window-list-based exclusion would bake our own panels
    // into the shot. Window *pick* mode still fetches fresh: it needs the list.
    //
    // The lifetime is a safety net, not the mechanism. Freshness comes from
    // re-priming when the window world actually changes — app switches, launches
    // and quits — which is also exactly when the user is about to screenshot.
    // Priming never happens before the first successful capture: it would move
    // the Screen Recording prompt to login, before the user asked for anything.

    private static var cachedContent: SCShareableContent?
    private static var cachedAt: ContinuousClock.Instant?
    /// Bumped on every invalidation. A fetch remembers the value it started
    /// under and refuses to cache if it changed while awaiting — otherwise a
    /// warm-up racing a display change would re-install pre-change displays.
    private static var cacheGeneration = 0
    private static var observersInstalled = false
    private static var primeTask: Task<Void, Never>?
    /// Upper bound only — the workspace observers refresh long before this.
    private static let cacheLifetime: Duration = .seconds(300)
    /// A cache younger than this is left alone, so a burst of app switches
    /// cannot turn into a burst of SCK round-trips.
    private static let reprimeThreshold: Duration = .seconds(10)

    private static func cache(_ content: SCShareableContent) {
        cachedContent = content
        cachedAt = ContinuousClock.now
        installObservers()
    }

    private static func usableCachedContent() -> SCShareableContent? {
        guard
            let content = cachedContent,
            let cachedAt,
            ContinuousClock.now - cachedAt < cacheLifetime,
            content.applications.contains(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }),
            NSScreen.screens.allSatisfy({ screen in
                guard let id = displayID(for: screen),
                      let display = content.displays.first(where: { $0.displayID == id })
                else { return false }
                // A resolution / "More Space" change keeps the display ID but
                // changes its size; the snapshot is requested at the cached
                // `SCDisplay`'s size, so a mismatch would capture at the wrong one.
                return display.width == Int(screen.frame.width.rounded())
                    && display.height == Int(screen.frame.height.rounded())
            })
        else { return nil }
        return content
    }

    static func invalidateShareableContentCache() {
        cacheGeneration += 1
        cachedContent = nil
        cachedAt = nil
    }

    /// Fire-and-forget warm-up so the *next* capture's pre-activation await is
    /// as short as possible. Never surfaces an error: a denial here is silent,
    /// and the alert belongs to the capture the user actually asked for.
    ///
    /// A no-op until the first successful capture — see the cache notes above.
    /// Only one warm-up is ever in flight.
    static func primeShareableContentCache(force: Bool = false) {
        guard SettingsStore.shared.hasCompletedFirstCapture else { return }
        if !force, let cachedAt, ContinuousClock.now - cachedAt < reprimeThreshold { return }
        guard primeTask == nil else { return }
        primeTask = Task {
            _ = try? await shareableContent()
            primeTask = nil
        }
        installObservers()
    }

    /// Called once a capture has actually produced pixels: from then on the
    /// grant is known-good, so warming up can no longer surface a TCC prompt.
    static func noteCaptureSucceeded() {
        guard !SettingsStore.shared.hasCompletedFirstCapture else { return }
        SettingsStore.shared.hasCompletedFirstCapture = true
    }

    private static func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true

        // A display change makes the cached `displays` wrong — drop it outright
        // rather than refreshing, so a capture during the reconfiguration
        // fetches fresh.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { invalidateShareableContentCache() }
        }

        // The window world changed — and an app switch is the single most
        // common thing to happen right before someone screenshots.
        let workspace = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { primeShareableContentCache() }
            }
        }
    }
}

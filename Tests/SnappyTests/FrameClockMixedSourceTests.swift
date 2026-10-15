import Foundation
import Testing
@testable import Snappy

/// T7 review rounds 1 + 2: SCK frames and idle re-appends sharing one slot
/// grid. A simulation that makes exactly `FrameWriter`'s decisions
/// (`slotTimeForCaptured` / `idleFrameTime`) over captured frames — stamped
/// at their display time, delivered later — and the idle timer's ticks,
/// merged in arrival order.
@Suite("FrameClock — captured and idle frames together")
struct FrameClockMixedSourceTests {
    struct Appended: Equatable { let time: Double; let captured: Bool }

    struct Simulation {
        var clock: FrameClock
        var appended: [Appended] = []
        var skipped = 0
        /// The captured frames that were appended: slot time and arrival.
        var captured: [(time: Double, arrival: Double)] = []

        init(fps: Int) { clock = FrameClock(framesPerSecond: fps) }

        mutating func capture(displayedAt time: Double, arrivedAt arrival: Double) {
            if let slot = clock.slotTimeForCaptured(time) {
                clock.didAppendCaptured(at: slot)
                appended.append(Appended(time: slot, captured: true))
                captured.append((slot, arrival))
            } else {
                clock.didSkipCaptured(displayedAt: time)
                skipped += 1
            }
        }

        mutating func tick(now: Double) {
            guard let time = clock.idleFrameTime(now: now) else { return }
            clock.didAppend(at: time)
            appended.append(Appended(time: time, captured: false))
        }

        var times: [Double] { appended.map(\.time) }
        var gaps: [Double] { zip(appended.dropFirst(), appended).map { $0.time - $1.time } }
    }

    private enum Event { case capture(display: Double), tick }

    /// Runs captures (display time, arrival time) and timer ticks, merged in
    /// arrival order.
    private func simulate(fps: Int, captures: [(display: Double, arrival: Double)], ticks: [Double]) -> Simulation {
        var simulation = Simulation(fps: fps)
        let events = captures.map { (at: $0.arrival, event: Event.capture(display: $0.display)) }
            + ticks.map { (at: $0, event: Event.tick) }
        for (at, event) in events.sorted(by: { $0.at < $1.at }) {
            switch event {
            case .capture(let display): simulation.capture(displayedAt: display, arrivedAt: at)
            case .tick: simulation.tick(now: at)
            }
        }
        return simulation
    }

    /// The writer's idle timer: every half interval from `phase`, alternating
    /// ±0.1 ms jitter.
    private func writerTicks(fps: Int, phase: Double, until end: Double) -> [Double] {
        let interval = 1.0 / Double(fps)
        var ticks: [Double] = []
        var tick = 0
        while true {
            let jitter = tick.isMultiple(of: 2) ? 0.0001 : -0.0001
            let at = phase + Double(tick) * interval / 2 + jitter
            if at > end { return ticks }
            ticks.append(at)
            tick += 1
        }
    }

    /// Captures (display times, each delivered `latency` later) and the
    /// writer's ticks from `tickPhase`, from 0 to `until`.
    private func run(
        fps: Int, displayTimes: [Double], latency: (Int) -> Double, tickPhase: Double, until end: Double
    ) -> Simulation {
        let captures = displayTimes.enumerated().map { index, display in (display, display + latency(index)) }
        return simulate(fps: fps, captures: captures, ticks: writerTicks(fps: fps, phase: tickPhase, until: end))
    }

    /// SCK's display stamps: on the frame cadence, ±0.3 ms.
    private func displayTimes(fps: Int, from start: Double, until end: Double) -> [Double] {
        let interval = 1.0 / Double(fps)
        return stride(from: start, to: end, by: interval).enumerated().map { index, time in
            time + (index.isMultiple(of: 2) ? 0.0003 : -0.0003)
        }
    }

    // MARK: - Invariants every run must keep

    /// The hard guarantee: timestamps strictly increase, every one is on the
    /// grid (t0 + k / fps), and no 1-second window holds more than `fps` frames.
    private func expectRateCeiling(_ simulation: Simulation, fps: Int, _ comment: Comment) {
        let times = simulation.times
        guard let first = times.first else { return }
        #expect(zip(times.dropFirst(), times).allSatisfy { $0 > $1 }, comment)
        let offGrid = times.filter { time in
            let slots = (time - first) * Double(fps)
            return abs(slots - slots.rounded()) > 1e-6
        }
        #expect(offGrid.isEmpty, comment)
        #expect(maxFramesInAnySecond(times) <= fps, comment)
    }

    /// The most frames in any half-open 1-second window. The busiest window
    /// starts at a frame, so only those are checked; the epsilon keeps a
    /// frame exactly one second later (on the grid, give or take rounding)
    /// out of the window it closes.
    private func maxFramesInAnySecond(_ times: [Double]) -> Int {
        var end = 0, most = 0
        for (start, time) in times.enumerated() {
            while end < times.count, times[end] < time + 1 - 1e-6 { end += 1 }
            most = max(most, end - start)
        }
        return most
    }

    // MARK: - Rules

    @Test func whileCapturingTheIdleSlotWaitsTheGraceThenKeepsTheCadence() {
        var clock = FrameClock(framesPerSecond: 60)
        clock.didAppendCaptured(at: 10)
        let interval = clock.interval
        let slot = 10 + interval
        #expect(clock.idleFrameTime(now: slot - 0.0001) == nil) // the idle rule would take this
        #expect(clock.idleFrameTime(now: slot + interval * 0.35) == nil) // still the real frame's
        #expect(clock.idleFrameTime(now: slot + interval * 0.41) == slot)
        #expect(clock.idleFrameTime(now: slot + interval * 1.4) == slot) // stamped on the grid
        // A stalled timer resynchronises to the latest due slot, no burst.
        #expect(clock.idleFrameTime(now: 10.5) == 10 + 29.0 / 60)
        #expect(clock.idleFrameTime(now: 10 + 29.5 / 60) == 10 + 29.0 / 60)
        // SCK quiet for longer than `captureMemory`: the plain idle cadence.
        #expect(clock.isCapturing(at: 10.5) && !clock.isCapturing(at: 11.5))
        #expect(clock.idleFrameTime(now: 11.5) == 11.5)
    }

    @Test func aCapturedFrameWhoseSlotIsFilledIsSkippedButKeepsCapturing() {
        var clock = FrameClock(framesPerSecond: 60)
        clock.didAppendCaptured(at: 10)
        clock.didAppend(at: 10 + 1.0 / 60) // an idle frame took slot 1
        #expect(clock.slotTimeForCaptured(10 + 0.9 / 60) == nil)
        #expect(clock.slotTimeForCaptured(10 + 1.3 / 60) == nil)
        #expect(clock.slotTimeForCaptured(10 + 1.5 / 60) == 10 + 2.0 / 60)
        clock.didSkipCaptured(displayedAt: 10 + 1.2 / 60)
        #expect(clock.isCapturing(at: 10.9)) // so the next slot still waits for SCK
        #expect(!clock.isCapturing(at: 11.1))
    }

    // MARK: - Mixed sources

    /// Real frames delivered within normal latency — up to just under 0.4
    /// interval for frames displayed on the slot (6.7 ms at 60 fps) — own every
    /// slot: no idle frame, nothing skipped, exactly the frame rate, for
    /// several timer phases against the SCK cadence.
    @Test(arguments: [30, 60])
    func realFramesWithinNormalLatencyFillEverySlot(fps: Int) {
        let interval = 1.0 / Double(fps)
        for phase in [0.0, 0.2, 0.45, 0.7, 0.95].map({ $0 * interval }) {
            for latency in [0.02, 0.1, 0.15, 0.3, 0.37].map({ $0 * interval }) {
                let simulation = run(
                    fps: fps, displayTimes: displayTimes(fps: fps, from: 0, until: 1),
                    latency: { _ in latency }, tickPhase: phase, until: 1
                )
                let comment: Comment = "phase \(phase), latency \(latency)"
                #expect(simulation.appended.allSatisfy { $0.captured }, comment)
                #expect(simulation.skipped == 0, comment)
                #expect(simulation.appended.count == fps, comment)
                #expect(simulation.gaps.allSatisfy { abs($0 - interval) < 1e-9 }, comment)
            }
        }
    }

    /// Late deliveries (up to 0.9 interval) lose some slots to the idle
    /// timer, but a slot is never filled twice and never left out.
    @Test(arguments: [30, 60])
    func lateRealFramesNeverDoubleASlot(fps: Int) {
        let interval = 1.0 / Double(fps)
        for phase in [0.0, 0.3, 0.6].map({ $0 * interval }) {
            let simulation = run(
                fps: fps, displayTimes: displayTimes(fps: fps, from: 0, until: 1),
                latency: { index in interval * [0.3, 0.6, 0.9, 0.5][index % 4] }, tickPhase: phase, until: 1
            )
            expectRateCeiling(simulation, fps: fps, "phase \(phase)")
            #expect(simulation.gaps.allSatisfy { abs($0 - interval) < 1e-9 }, "phase \(phase)")
            #expect(simulation.appended.count >= fps - 2)
        }
    }

    /// SCK goes quiet (static screen): idle frames continue exactly one
    /// interval apart from the last real frame — through the grace, and
    /// through the switch to the plain idle cadence when `captureMemory`
    /// runs out — with jittered ticks.
    @Test(arguments: [30, 60])
    func fromCapturingToIdleTheCadenceHolds(fps: Int) throws {
        let interval = 1.0 / Double(fps)
        for phase in [0.0, 0.37, 0.74].map({ $0 * interval }) {
            let simulation = run(
                fps: fps, displayTimes: displayTimes(fps: fps, from: 0, until: 0.5),
                latency: { _ in interval * 0.1 }, tickPhase: phase, until: 2.5
            )
            let lastCaptured = try #require(simulation.appended.lastIndex { $0.captured })
            let idle = simulation.appended[lastCaptured...].map(\.time)
            #expect(idle.count >= 2 * fps - 2, "phase \(phase)")
            let idleGaps = zip(idle.dropFirst(), idle).map { $0 - $1 }
            #expect(idleGaps.allSatisfy { abs($0 - interval) < 1e-9 }, "phase \(phase)")
        }
    }

    /// The screen changes again after an idle stretch longer than
    /// `captureMemory`: the first real frame may land in a slot the idle
    /// timer just filled — then it is skipped, never doubled — and capture
    /// takes over.
    @Test(arguments: [30, 60])
    func fromIdleToCapturingNoSlotIsDoubled(fps: Int) {
        let interval = 1.0 / Double(fps)
        for offset in [0.0, 0.3, 0.8].map({ $0 * interval }) {
            let displays = [0.0] + displayTimes(fps: fps, from: 1.5 + offset, until: 2)
            let simulation = run(
                fps: fps, displayTimes: displays, latency: { _ in interval * 0.1 }, tickPhase: interval * 0.2, until: 2
            )
            expectRateCeiling(simulation, fps: fps, "offset \(offset)")
            #expect(simulation.gaps.allSatisfy { abs($0 - interval) < 1e-9 }, "offset \(offset)")
            #expect(simulation.skipped <= 1)
            #expect(simulation.appended.suffix(fps / 4).allSatisfy { $0.captured })
        }
    }

    /// T7 review round 2, the reviewer's exact probe: captures 1.7501
    /// intervals apart (slower than the frame rate), delivered 0.1 interval
    /// after display, the writer's 2× ticks with alternating ±0.1 ms jitter,
    /// 10 s, no closing frame. The round-1 clock appended 685 frames at 60 fps
    /// (68.5 fps) and 343 at 30, in pairs 1 + 0.7501 intervals apart.
    @Test(arguments: [30, 60])
    func reviewerProbeNeverExceedsTheFrameRate(fps: Int) {
        let interval = 1.0 / Double(fps)
        let displays = Array((0...).lazy.map { Double($0) * interval * 1.7501 }.prefix { $0 < 10 })
        let simulation = run(
            fps: fps, displayTimes: displays, latency: { _ in interval * 0.1 }, tickPhase: 0, until: 10
        )
        expectRateCeiling(simulation, fps: fps, "probe")
        #expect(simulation.appended.count <= 10 * fps)
        #expect(simulation.gaps.allSatisfy { $0 > interval - 1e-9 })
        // Every capture still wins its slot (its delivery is well within the
        // grace), and the grid-aligned timer fills every slot in between.
        #expect(simulation.skipped == 0)
        #expect(simulation.captured.count == displays.count)
        #expect(simulation.gaps.allSatisfy { abs($0 - interval) < 1e-9 })
        #expect(simulation.appended.count >= 10 * fps - 1)
    }

    // MARK: - Properties over randomized runs

    /// Seeded SplitMix64: the same runs every time, so a failure reproduces.
    struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A randomized source and timer: SCK frames `captureStep` apart (faster
    /// or slower than the frame rate) — anywhere, or on the vsyncs of a
    /// 120 Hz display (a slot or half way) — with display jitter, delivered
    /// in order after a latency that varies per frame; an idle timer at
    /// `tickRate` per interval with jitter and a random phase.
    struct Scenario: CustomStringConvertible {
        let fps: Int
        let seed: UInt64
        let captureStep, displayJitter, latency, latencySpread: Double // intervals
        /// Display times snap to half intervals (the grid starts on a vsync).
        var onVsync = false
        let tickRate: Double // ticks per interval
        let tickJitter: Double // seconds
        let tickPhase: Double // intervals
        /// SCK sends nothing from `quiet.lowerBound` until `quiet.upperBound` (seconds).
        let quiet: Range<Double>?
        let duration: Double

        var interval: Double { 1 / Double(fps) }

        var description: String {
            "fps \(fps) seed \(seed): step \(captureStep)\(onVsync ? " on vsync" : ""), display ±\(displayJitter), latency \(latency)+\(latencySpread), "
                + "ticks \(tickRate)/interval ±\(tickJitter) s from \(tickPhase), quiet \(quiet.map { "\($0)" } ?? "none")"
        }

        func captures(_ random: inout SeededRandom) -> [(display: Double, arrival: Double)] {
            var captures: [(display: Double, arrival: Double)] = []
            var time = 0.0
            while time < duration {
                defer { time += captureStep * interval }
                if let quiet, quiet.contains(time) { continue }
                let jitter = displayJitter * interval * Double.random(in: -1...1, using: &random)
                let vsync = onVsync ? (time / interval * 2).rounded() * interval / 2 : time
                let display = max((captures.last?.display ?? -1) + 0.0001, vsync + jitter)
                let delay = (latency + latencySpread * Double.random(in: 0...1, using: &random)) * interval
                // SCK delivers in order.
                captures.append((display, max(captures.last?.arrival ?? 0, display + delay)))
            }
            return captures
        }

        func ticks(_ random: inout SeededRandom) -> [Double] {
            let period = interval / tickRate
            return stride(from: tickPhase * interval, through: duration, by: period).map {
                $0 + tickJitter * Double.random(in: -1...1, using: &random)
            }
        }
    }

    /// For many seeded combinations of capture interval (0.3–4 intervals,
    /// i.e. up to 3× faster than the frame rate), display jitter, delivery
    /// latency (up to 1.8 intervals), tick rate (2–4 per interval), tick
    /// jitter (up to 1 ms) and phase, with a static stretch in the middle:
    /// no 1-second window ever holds more than `fps` frames, timestamps
    /// strictly increase on the grid, and the static stretch is still filled
    /// at exactly the frame rate.
    @Test(arguments: [30, 60])
    func noSecondEverExceedsTheFrameRateAndStaticStretchesAreFilled(fps: Int) throws {
        for seed in UInt64(1)...300 {
            var random = SeededRandom(state: seed &* 7919 &+ UInt64(fps))
            let quietStart = Double.random(in: 0.8...1.4, using: &random)
            let scenario = Scenario(
                fps: fps, seed: seed,
                captureStep: .random(in: 0.3...4, using: &random),
                displayJitter: .random(in: 0...0.3, using: &random),
                latency: .random(in: 0...1.2, using: &random),
                latencySpread: .random(in: 0...0.6, using: &random),
                tickRate: .random(in: 2...4, using: &random),
                tickJitter: .random(in: 0...0.001, using: &random),
                tickPhase: .random(in: 0..<1, using: &random),
                quiet: quietStart..<(quietStart + .random(in: 1.3...2, using: &random)),
                duration: 4
            )
            let captures = scenario.captures(&random)
            let simulation = simulate(fps: fps, captures: captures, ticks: scenario.ticks(&random))
            let comment = Comment(rawValue: scenario.description)
            expectRateCeiling(simulation, fps: fps, comment)

            // The static stretch: from the last real frame appended before SCK
            // resumes until shortly before it does, every slot is filled.
            let quiet = try #require(scenario.quiet)
            let resumed = try #require(captures.first { $0.display >= quiet.upperBound - 0.31 * scenario.interval }?.arrival)
            let lastReal = try #require(simulation.captured.last { $0.arrival < resumed }?.time, comment)
            let stretch = simulation.times.filter { $0 >= lastReal && $0 <= resumed - 1.5 * scenario.interval }
            let gaps = zip(stretch.dropFirst(), stretch).map { $0 - $1 }
            #expect(gaps.allSatisfy { abs($0 - scenario.interval) < 1e-9 }, comment)
            #expect(try #require(stretch.last) >= resumed - 2.6 * scenario.interval, comment)
        }
    }

    /// For many seeded sources no faster than the frame rate, displayed on
    /// vsyncs and delivered within normal latency (up to 0.35 interval —
    /// 5.8 ms at 60 fps, 11.7 ms at 30), with SCK never quiet for long: every
    /// real frame wins its slot — the idle re-append never takes it first.
    @Test(arguments: [30, 60])
    func realFramesWithinNormalLatencyAlwaysWinTheirSlot(fps: Int) {
        for seed in UInt64(1)...200 {
            var random = SeededRandom(state: seed &* 104_729 &+ UInt64(fps))
            let scenario = Scenario(
                fps: fps, seed: seed,
                captureStep: .random(in: 1.05...4, using: &random),
                displayJitter: .random(in: 0...0.02, using: &random),
                latency: 0,
                latencySpread: .random(in: 0...0.35, using: &random),
                onVsync: true,
                tickRate: .random(in: 2...4, using: &random),
                tickJitter: .random(in: 0...0.001, using: &random),
                tickPhase: .random(in: 0..<1, using: &random),
                quiet: nil,
                duration: 3
            )
            let captures = scenario.captures(&random)
            let simulation = simulate(fps: fps, captures: captures, ticks: scenario.ticks(&random))
            let comment = Comment(rawValue: scenario.description)
            expectRateCeiling(simulation, fps: fps, comment)
            #expect(simulation.skipped == 0, comment)
            #expect(simulation.captured.count == captures.count, comment)
        }
    }
}

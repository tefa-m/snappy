import AppKit

/// The countdown before recording — PURE, unit-tested. The coordinator owns the
/// clock (one `countdownTick` per second, `RecordingSession`); the chrome only
/// renders the numeral of the current phase.
enum CountdownSequence {
    /// The numerals shown, in order, for Settings → Countdown: 3 s → 3, 2, 1;
    /// Off → none (recording starts at once).
    static func numerals(for countdown: RecordingCountdown) -> [Int] {
        Array(stride(from: countdown.seconds, to: 0, by: -1))
    }

    /// The numeral for a phase; nil outside the countdown.
    static func numeral(for phase: RecordingPhase) -> Int? {
        guard case .countdown(let remaining) = phase, remaining > 0 else { return nil }
        return remaining
    }

    /// What VoiceOver announces as the numeral changes: the first says what
    /// is about to happen, the rest only count.
    static func announcement(numeral: Int, total: Int) -> String {
        numeral == total ? "Recording in \(numeral)" : "\(numeral)"
    }
}

/// A large numeral on a Liquid Glass disc, centred in the target
/// (`ChromeLayout.countdownDiscFrame`). Passive — it never takes a click.
/// The number changes without animation (HIG Motion: no motion on something
/// that repeats every second; Reduce Motion needs no special case).
@MainActor
final class CountdownView: NSGlassEffectView {
    private let label = NSTextField(labelWithString: "")
    private var fontSize: CGFloat = 0

    init() {
        super.init(frame: .zero)
        label.alignment = .center
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        contentView = container
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Shows `numeral` sized for a disc of `diameter` points.
    func show(_ numeral: Int, diameter: CGFloat) {
        cornerRadius = diameter / 2
        let size = ChromeLayout.countdownFontSize(diameter: diameter)
        if size != fontSize {
            fontSize = size
            // Rounded, bold, monospaced digits: every numeral sits in the
            // same place on the disc.
            let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            label.font = base.fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
        label.stringValue = "\(numeral)"
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

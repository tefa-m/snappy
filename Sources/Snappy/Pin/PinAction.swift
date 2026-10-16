/// Actions offered by a pin's hover toolbar, in display order.
enum PinAction: CaseIterable {
    case close, edit, copy

    /// Short name — the VoiceOver label of the icon-only button.
    var title: String {
        switch self {
        case .close: "Close"
        case .edit: "Edit"
        case .copy: "Copy"
        }
    }

    var symbolName: String {
        switch self {
        case .close: "xmark.circle.fill"
        case .edit: "pencil.tip.crop.circle"
        case .copy: "document.on.document"
        }
    }

    /// Template symbol for the pin's context menu: the standard Close icon
    /// (`xmark`) rather than the toolbar's red disc.
    var menuSymbolName: String {
        self == .close ? "xmark" : symbolName
    }

    /// Context-menu groups (separator between them): the frequent actions
    /// first, Close last. No shortcuts shown (HIG Context menus).
    static let contextMenuGroups: [[PinAction]] = [[.edit, .copy], [.close]]

    /// Bare key handled by the pin window (Esc also closes).
    var shortcutKey: String {
        switch self {
        case .close: "q"
        case .edit: "e"
        case .copy: "c"
        }
    }

    /// Tooltip in the app-wide "… (KEY)" form, led by a verb phrase that says
    /// what the action does (HIG Offering help) — the same wording as the
    /// preview panel's matching actions.
    var toolTip: String {
        let description = switch self {
        case .close: "Close this pin"
        case .edit: "Annotate in the editor"
        case .copy: "Copy image to clipboard"
        }
        return "\(description) (\(shortcutKey.uppercased()))"
    }
}

/// Hover appearance of a pin.
enum PinHover {
    /// Subtle hover transparency (M-C spec: "keep the hover feedback
    /// subtle"). With Reduce Transparency on, the pin stays opaque.
    static let alpha: Double = 0.9

    static func windowAlpha(hovering: Bool, reduceTransparency: Bool) -> Double {
        hovering && !reduceTransparency ? alpha : 1
    }
}

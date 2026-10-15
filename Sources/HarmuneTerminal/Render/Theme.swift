/// Color tokens from product_spec.md §10.2.
public struct Theme: Sendable, Equatable {
    public var name: String
    public var background: TermColor
    public var surface: TermColor
    public var elevated: TermColor
    public var text: TermColor
    public var textSecondary: TermColor
    public var muted: TermColor
    public var accent: TermColor
    public var accentPink: TermColor
    public var accentBlue: TermColor
    public var success: TermColor
    public var warning: TermColor
    public var error: TermColor
    public var border: TermColor
    /// Mono themes mark selection with reverse video instead of color.
    public var usesReverseSelection = false

    public static let midnight = Theme(
        name: "harmune-midnight",
        background: TermColor(hex: 0x101018), surface: TermColor(hex: 0x181824), elevated: TermColor(hex: 0x222235),
        text: TermColor(hex: 0xEAEAF2), textSecondary: TermColor(hex: 0xA1A1B5), muted: TermColor(hex: 0x69697D),
        accent: TermColor(hex: 0xC6A5FF), accentPink: TermColor(hex: 0xF3A6C8), accentBlue: TermColor(hex: 0x94BFFF),
        success: TermColor(hex: 0xA6E3A1), warning: TermColor(hex: 0xF9D58B), error: TermColor(hex: 0xF38BA8),
        border: TermColor(hex: 0x343446))

    public static let mono = Theme(
        name: "mono",
        background: .default, surface: .default, elevated: .default,
        text: .default, textSecondary: .default, muted: .default,
        accent: .default, accentPink: .default, accentBlue: .default,
        success: .default, warning: .default, error: .default, border: .default,
        usesReverseSelection: true)

    public static let all: [Theme] = [.midnight, .mono]

    public static func named(_ name: String) -> Theme? { all.first { $0.name == name } }

    // Common styles
    var base: Style { Style(fg: text, bg: background) }
    var panel: Style { Style(fg: text, bg: surface) }
    var secondary: Style { Style(fg: textSecondary) }
    var dimmed: Style { usesReverseSelection ? Style(dim: true) : Style(fg: muted) }
    var borderStyle: Style { Style(fg: border) }
    var accentStyle: Style { Style(fg: accent, bold: true) }

    func selection(focused: Bool) -> Style {
        if usesReverseSelection { return Style(underline: !focused, reverse: focused) }
        return Style(fg: focused ? text : textSecondary, bg: elevated)
    }
}

/// Responsive layout classes from product_spec.md §5.
public struct LayoutClass: Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) { self.columns = columns; self.rows = rows }

    public var showsSidebar: Bool { columns >= 90 }
    public var showsRightPanel: Bool { columns >= 120 && rows >= 20 }
    public var showsHeader: Bool { rows >= 12 }
    /// Full 3-row player bar with artwork thumbnail, or a single line.
    public var playerRows: Int { rows >= 20 ? 3 : 1 }
    public var sidebarWidth: Int { columns >= 140 ? 22 : 18 }
    public var rightPanelWidth: Int { min(44, max(34, columns / 4)) }
}

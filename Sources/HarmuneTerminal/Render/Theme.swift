import Foundation

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
        background: TermColor(hex: 0x101619), surface: TermColor(hex: 0x161F23), elevated: TermColor(hex: 0x243137),
        text: TermColor(hex: 0xEDF3EE), textSecondary: TermColor(hex: 0xA1AFB1), muted: TermColor(hex: 0x718184),
        accent: TermColor(hex: 0xB9F674), accentPink: TermColor(hex: 0xF3A6C8), accentBlue: TermColor(hex: 0x94BFFF),
        success: TermColor(hex: 0xA6E3A1), warning: TermColor(hex: 0xF9D58B), error: TermColor(hex: 0xF38BA8),
        border: TermColor(hex: 0x303C41))

    public static let mono = Theme(
        name: "mono",
        background: .default, surface: .default, elevated: .default,
        text: .default, textSecondary: .default, muted: .default,
        accent: .default, accentPink: .default, accentBlue: .default,
        success: .default, warning: .default, error: .default, border: .default,
        usesReverseSelection: true)

    public static let tokyoNight = Theme(
        name: "tokyo-night",
        background: TermColor(hex: 0x1A1B26), surface: TermColor(hex: 0x16161E), elevated: TermColor(hex: 0x292E42),
        text: TermColor(hex: 0xC0CAF5), textSecondary: TermColor(hex: 0xA9B1D6), muted: TermColor(hex: 0x565F89),
        accent: TermColor(hex: 0xBB9AF7), accentPink: TermColor(hex: 0xF7768E), accentBlue: TermColor(hex: 0x7AA2F7),
        success: TermColor(hex: 0x9ECE6A), warning: TermColor(hex: 0xE0AF68), error: TermColor(hex: 0xF7768E),
        border: TermColor(hex: 0x3B4261))

    public static let catppuccinMocha = Theme(
        name: "catppuccin-mocha",
        background: TermColor(hex: 0x1E1E2E), surface: TermColor(hex: 0x181825), elevated: TermColor(hex: 0x313244),
        text: TermColor(hex: 0xCDD6F4), textSecondary: TermColor(hex: 0xBAC2DE), muted: TermColor(hex: 0x6C7086),
        accent: TermColor(hex: 0xCBA6F7), accentPink: TermColor(hex: 0xF5C2E7), accentBlue: TermColor(hex: 0x89B4FA),
        success: TermColor(hex: 0xA6E3A1), warning: TermColor(hex: 0xF9E2AF), error: TermColor(hex: 0xF38BA8),
        border: TermColor(hex: 0x45475A))

    public static let gruvboxDark = Theme(
        name: "gruvbox-dark",
        background: TermColor(hex: 0x282828), surface: TermColor(hex: 0x1D2021), elevated: TermColor(hex: 0x3C3836),
        text: TermColor(hex: 0xEBDBB2), textSecondary: TermColor(hex: 0xD5C4A1), muted: TermColor(hex: 0x928374),
        accent: TermColor(hex: 0xFABD2F), accentPink: TermColor(hex: 0xD3869B), accentBlue: TermColor(hex: 0x83A598),
        success: TermColor(hex: 0xB8BB26), warning: TermColor(hex: 0xFE8019), error: TermColor(hex: 0xFB4934),
        border: TermColor(hex: 0x504945))

    public static let nord = Theme(
        name: "nord",
        background: TermColor(hex: 0x2E3440), surface: TermColor(hex: 0x3B4252), elevated: TermColor(hex: 0x434C5E),
        text: TermColor(hex: 0xECEFF4), textSecondary: TermColor(hex: 0xD8DEE9), muted: TermColor(hex: 0x7B88A1),
        accent: TermColor(hex: 0x88C0D0), accentPink: TermColor(hex: 0xB48EAD), accentBlue: TermColor(hex: 0x81A1C1),
        success: TermColor(hex: 0xA3BE8C), warning: TermColor(hex: 0xEBCB8B), error: TermColor(hex: 0xBF616A),
        border: TermColor(hex: 0x4C566A))

    public static let dracula = Theme(
        name: "dracula",
        background: TermColor(hex: 0x282A36), surface: TermColor(hex: 0x21222C), elevated: TermColor(hex: 0x44475A),
        text: TermColor(hex: 0xF8F8F2), textSecondary: TermColor(hex: 0xBDC1D6), muted: TermColor(hex: 0x6272A4),
        accent: TermColor(hex: 0xBD93F9), accentPink: TermColor(hex: 0xFF79C6), accentBlue: TermColor(hex: 0x8BE9FD),
        success: TermColor(hex: 0x50FA7B), warning: TermColor(hex: 0xF1FA8C), error: TermColor(hex: 0xFF5555),
        border: TermColor(hex: 0x44475A))

    public static let all: [Theme] = [.midnight, .tokyoNight, .catppuccinMocha, .gruvboxDark, .nord, .dracula, .mono]

    public static func named(_ name: String) -> Theme? { all.first { $0.name == name } }

    /// Built-in themes plus `*.toml` files in `directory`. A file's name is its
    /// theme's name, and a file can replace a built-in theme of the same name.
    public static func available(customDirectory directory: String) -> (themes: [Theme], warnings: [String]) {
        var themes = all
        var warnings: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for file in files.sorted() where file.hasSuffix(".toml") {
            let name = String(file.dropLast(".toml".count))
            guard let text = try? String(contentsOfFile: directory + "/" + file, encoding: .utf8) else {
                warnings.append("couldn't read theme \(file)")
                continue
            }
            let (theme, problems) = parse(name: name, text: text)
            warnings += problems.map { "theme \(file): \($0)" }
            themes.removeAll { $0.name == name }
            themes.append(theme)
        }
        return (themes, warnings)
    }

    /// Parses a custom theme: `token = "#RRGGBB"` lines, plus an optional
    /// `base = "<theme>"` that supplies every token the file leaves out.
    public static func parse(name: String, text: String) -> (Theme, [String]) {
        var values: [String: String] = [:]
        var warnings: [String] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.components(separatedBy: "#\u{20}").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                warnings.append("line \(i + 1): expected token = \"#RRGGBB\"")
                continue
            }
            values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        var theme = midnight
        if let base = values.removeValue(forKey: "base") {
            if let found = named(base) { theme = found } else { warnings.append("unknown base theme \"\(base)\"") }
        }
        theme.name = name
        let tokens: [(String, WritableKeyPath<Theme, TermColor>)] = [
            ("background", \.background), ("surface", \.surface), ("elevated", \.elevated), ("text", \.text),
            ("text_secondary", \.textSecondary), ("muted", \.muted), ("accent", \.accent), ("accent_pink", \.accentPink),
            ("accent_blue", \.accentBlue), ("success", \.success), ("warning", \.warning), ("error", \.error), ("border", \.border),
        ]
        for (token, path) in tokens {
            guard let value = values.removeValue(forKey: token) else { continue }
            if value.hasPrefix("#"), value.count == 7, let hex = UInt32(value.dropFirst(), radix: 16) {
                theme[keyPath: path] = TermColor(hex: hex)
            } else {
                warnings.append("\(token) = \"\(value)\" isn't a #RRGGBB color")
            }
        }
        warnings += values.keys.sorted().map { "unknown token \($0)" }
        return (theme, warnings)
    }

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

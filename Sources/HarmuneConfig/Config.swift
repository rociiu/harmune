import Foundation

/// User configuration from `~/.config/harmune/config.toml` (spec §17).
///
/// Invalid or unknown settings never stop Harmune: each produces a warning
/// and falls back to the default.
public struct HarmuneConfig: Equatable, Sendable {
    public var theme = "harmune-midnight"
    public var startPage = "home"
    public var showArtwork = true
    /// "auto", "kitty", "halfblock" or "none".
    public var graphics = "auto"
    /// "grid" or "table".
    public var albumView = "grid"
    public var animations = true
    public var reducedMotion = false
    public var sequenceTimeoutMs = 600
    /// Table name (e.g. "normal", "queue") → key sequence → action name.
    public var keybindings: [String: [String: String]] = [:]

    public init() {}

    public static let startPages = ["home", "search", "songs", "albums", "artists", "playlists", "queue"]

    public static func defaultPath(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { return xdg + "/harmune/config.toml" }
        return NSHomeDirectory() + "/.config/harmune/config.toml"
    }

    /// Loads a config file. A missing file is not an error.
    public static func load(path: String) -> (HarmuneConfig, [String]) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            if FileManager.default.fileExists(atPath: path) { return (HarmuneConfig(), ["Could not read \(path)"]) }
            return (HarmuneConfig(), [])
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> (HarmuneConfig, [String]) {
        var config = HarmuneConfig()
        var warnings: [String] = []
        let doc = TOMLLite.parse(text, warnings: &warnings)

        for (section, entries) in doc.sorted(by: { $0.key < $1.key }) {
            if section.hasPrefix("keybindings.") {
                let table = String(section.dropFirst("keybindings.".count))
                for (key, value) in entries {
                    guard case .string(let action) = value.value else {
                        warnings.append("line \(value.line): keybinding \"\(key)\" must map to an action name string")
                        continue
                    }
                    config.keybindings[table, default: [:]][key] = action
                }
                continue
            }
            for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
                config.apply(section: section, key: key, value: value, warnings: &warnings)
            }
        }
        return (config, warnings)
    }

    private mutating func apply(section: String, key: String, value: TOMLLite.Entry, warnings: inout [String]) {
        let name = section.isEmpty ? key : "\(section).\(key)"
        func bool(_ assign: (Bool) -> Void) {
            if case .bool(let b) = value.value { assign(b) } else { warnings.append("line \(value.line): \(name) must be true or false") }
        }
        func string(_ allowed: [String]? = nil, _ assign: (String) -> Void) {
            guard case .string(let v) = value.value else {
                warnings.append("line \(value.line): \(name) must be a string"); return
            }
            if let allowed, !allowed.contains(v) {
                warnings.append("line \(value.line): \(name) = \"\(v)\" is not one of \(allowed.joined(separator: ", "))"); return
            }
            assign(v)
        }
        func int(_ range: ClosedRange<Int>, _ assign: (Int) -> Void) {
            guard case .int(let v) = value.value, range.contains(v) else {
                warnings.append("line \(value.line): \(name) must be an integer in \(range.lowerBound)...\(range.upperBound)"); return
            }
            assign(v)
        }

        switch name {
        case "general.theme": string { theme = $0 }  // validated against installed themes by the TUI
        case "general.start_page": string(Self.startPages) { startPage = $0 }
        case "general.restore_last_view": break  // reserved
        case "appearance.show_artwork": bool { showArtwork = $0 }
        case "appearance.graphics": string(["auto", "kitty", "halfblock", "none"]) { graphics = $0 }
        case "appearance.album_view": string(["grid", "table"]) { albumView = $0 }
        case "appearance.artwork_size", "appearance.show_visualizer", "appearance.show_borders",
             "appearance.dynamic_colors", "player.show_progress", "player.show_duration", "animation.max_fps":
            break  // in the spec, not yet implemented; accepted silently
        case "animation.enabled": bool { animations = $0 }
        case "animation.reduced_motion": bool { reducedMotion = $0 }
        case "keys.sequence_timeout_ms": int(100...5000) { sequenceTimeoutMs = $0 }
        default: warnings.append("line \(value.line): unknown setting \(name)")
        }
    }
}

/// Parses the subset of TOML Harmune's config uses: `[tables]`, `key = value`
/// with strings, booleans and integers, quoted keys and `#` comments.
enum TOMLLite {
    enum Value: Equatable { case string(String), bool(Bool), int(Int), float(Double) }
    struct Entry: Equatable { var value: Value; var line: Int }

    static func parse(_ text: String, warnings: inout [String]) -> [String: [String: Entry]] {
        var doc: [String: [String: Entry]] = [:]
        var section = ""
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let lineNo = i + 1
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                    warnings.append("line \(lineNo): unsupported table syntax"); continue
                }
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = findEquals(line) else {
                warnings.append("line \(lineNo): expected key = value"); continue
            }
            let keyPart = line[..<eq].trimmingCharacters(in: .whitespaces)
            let valuePart = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard let key = parseKey(keyPart) else { warnings.append("line \(lineNo): invalid key"); continue }
            guard let value = parseValue(valuePart) else {
                warnings.append("line \(lineNo): unsupported value for \(key)"); continue
            }
            if doc[section]?[key] != nil { warnings.append("line \(lineNo): duplicate key \(key)") }
            doc[section, default: [:]][key] = Entry(value: value, line: lineNo)
        }
        return doc
    }

    /// Removes a `#` comment that is not inside a string.
    static func stripComment(_ s: String) -> String {
        var inString = false, escaped = false
        for (i, c) in s.enumerated() {
            if escaped { escaped = false; continue }
            if c == "\\" && inString { escaped = true; continue }
            if c == "\"" { inString.toggle() }
            if c == "#" && !inString { return String(s.prefix(i)) }
        }
        return s
    }

    static func findEquals(_ s: String) -> String.Index? {
        var inString = false
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\"" { inString.toggle() }
            if s[i] == "=" && !inString { return i }
            i = s.index(after: i)
        }
        return nil
    }

    static func parseKey(_ s: String) -> String? {
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { return unescape(String(s.dropFirst().dropLast())) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return !s.isEmpty && s.unicodeScalars.allSatisfy(allowed.contains) ? s : nil
    }

    static func parseValue(_ s: String) -> Value? {
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { return unescape(String(s.dropFirst().dropLast())).map(Value.string) }
        if let i = Int(s.replacingOccurrences(of: "_", with: "")) { return .int(i) }
        if let d = Double(s) { return .float(d) }
        return nil
    }

    static func unescape(_ s: String) -> String? {
        var out = "", escaped = false
        for c in s {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: return nil
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return escaped ? nil : out
    }
}

extension Keymap {
    /// Applies `[keybindings.<table>]` overrides on top of the defaults.
    ///
    /// Tables: `normal` and `navigation` bind globally; `list`, `grid` and
    /// `queue` bind in that context. The action `"none"` unbinds a key.
    /// Returns a warning for each binding that was rejected.
    public mutating func apply(overrides: [String: [String: String]]) -> [String] {
        var warnings: [String] = []
        for (table, bindings) in overrides.sorted(by: { $0.key < $1.key }) {
            let context: KeyContext
            switch table {
            case "normal", "navigation": context = .global
            case "list": context = .list
            case "grid": context = .grid
            case "queue": context = .queue
            default:
                warnings.append("unknown keybinding table [keybindings.\(table)]")
                continue
            }
            for (sequence, action) in bindings.sorted(by: { $0.key < $1.key }) {
                guard let keys = Key.parseSequence(sequence) else {
                    warnings.append("keybindings.\(table): cannot parse key \"\(sequence)\"")
                    continue
                }
                if action == "none" {
                    unbind(keys, in: context)
                    continue
                }
                guard let command = KeyCommand(rawValue: action) else {
                    warnings.append("keybindings.\(table): unknown action \"\(action)\" for \"\(sequence)\"")
                    continue
                }
                if let first = keys.first, first.digit != nil, first.digit != 0 {
                    warnings.append("keybindings.\(table): \"\(sequence)\" starts with a digit, which is a count prefix")
                    continue
                }
                bind(keys, to: command, in: context)
            }
        }
        warnings += conflicts()
        return warnings
    }

    mutating func bind(_ keys: [Key], to command: KeyCommand, in context: KeyContext) {
        bindings[context, default: [:]][keys] = command
    }

    /// A single key that is also the start of a longer sequence only fires
    /// after the sequence timeout, which feels laggy. Warn about each one.
    func conflicts() -> [String] {
        var out: [String] = []
        for (context, map) in bindings {
            for keys in map.keys where keys.count == 1 && isPrefix(keys, in: context) {
                out.append("\"\(keys[0])\" (\(context.rawValue)) also starts a longer sequence, so it waits for the sequence timeout")
            }
        }
        return out.sorted()
    }
}

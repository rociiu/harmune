/// A normalised key press.
///
/// Notation (also used in `config.toml`): printable characters as-is
/// (`j`, `G`, `>`), and `<space>`, `<cr>`, `<esc>`, `<tab>`, `<s-tab>`,
/// `<bs>`, `<up>`, `<down>`, `<left>`, `<right>`, `<c-x>` for Ctrl+x.
public enum Key: Hashable, Sendable, CustomStringConvertible {
    case char(Character)
    case ctrl(Character)
    case enter, escape, tab, backTab, backspace, space
    case up, down, left, right
    /// The terminal window gained or lost focus. Never bound to a command.
    case focusIn, focusOut

    public var description: String {
        switch self {
        case .char(let c): String(c)
        case .ctrl(let c): "<c-\(c)>"
        case .enter: "<cr>"
        case .escape: "<esc>"
        case .tab: "<tab>"
        case .backTab: "<s-tab>"
        case .backspace: "<bs>"
        case .space: "<space>"
        case .up: "<up>"
        case .down: "<down>"
        case .left: "<left>"
        case .right: "<right>"
        case .focusIn: "<focus-in>"
        case .focusOut: "<focus-out>"
        }
    }

    /// The digit value when this key can be part of a count prefix.
    var digit: Int? {
        if case .char(let c) = self, let v = c.wholeNumberValue, c.isASCII { return v }
        return nil
    }

    /// Parses a sequence such as `gg`, `<c-d>` or `<space>`.
    public static func parseSequence(_ text: String) -> [Key]? {
        // A bare key name ("space", "enter", "esc") means that key, as in the
        // spec's example config; otherwise "space" would be five keys.
        if text.count > 1, !text.contains("<"), let key = named(text.lowercased()) { return [key] }
        var keys: [Key] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "<", let close = text[i...].firstIndex(of: ">"), close > text.index(after: i) {
                let name = text[text.index(after: i)..<close].lowercased()
                guard let key = named(name) else { return nil }
                keys.append(key)
                i = text.index(after: close)
            } else {
                keys.append(text[i] == " " ? .space : .char(text[i]))
                i = text.index(after: i)
            }
        }
        return keys.isEmpty ? nil : keys
    }

    private static func named(_ name: String) -> Key? {
        switch name {
        case "space": .space
        case "cr", "enter", "return": .enter
        case "esc", "escape": .escape
        case "tab": .tab
        case "s-tab": .backTab
        case "bs", "backspace": .backspace
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        case "lt": .char("<")
        case "gt": .char(">")
        default:
            if name.hasPrefix("c-"), name.count == 3, let c = name.last { .ctrl(c) } else { nil }
        }
    }
}

/// Decodes raw terminal input bytes into keys.
///
/// A lone ESC is ambiguous with the start of an escape sequence; callers
/// should call `flushEscape()` after a short timeout (~25 ms) with no input.
public struct KeyDecoder: Sendable {
    private var pending: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Key] {
        pending.append(contentsOf: bytes)
        var keys: [Key] = []
        while !pending.isEmpty {
            guard let (key, used) = decodeOne() else { break }
            pending.removeFirst(used)
            if let key { keys.append(key) }
        }
        return keys
    }

    /// Treats a dangling ESC as the Escape key.
    public mutating func flushEscape() -> [Key] {
        guard pending == [0x1B] else { return [] }
        pending.removeAll()
        return [.escape]
    }

    /// Returns the decoded key (nil for ignored sequences) and bytes used,
    /// or nil when more bytes are needed.
    private func decodeOne() -> (Key?, Int)? {
        let b = pending[0]
        switch b {
        case 0x1B:
            guard pending.count > 1 else { return nil }
            if pending[1] == 0x5B || pending[1] == 0x4F {  // CSI or SS3
                var end = 2
                while end < pending.count, !(0x40...0x7E).contains(pending[end]) { end += 1 }
                guard end < pending.count else { return nil }
                let params = String(decoding: pending[2..<end], as: UTF8.self)
                let key: Key? = switch (pending[end], params) {
                case (0x41, _): .up
                case (0x42, _): .down
                case (0x43, _): .right
                case (0x44, _): .left
                case (0x5A, _): .backTab
                case (0x49, "") where pending[1] == 0x5B: .focusIn
                case (0x4F, "") where pending[1] == 0x5B: .focusOut
                default: nil
                }
                return (key, end + 1)
            }
            if pending[1] == 0x1B { return (.escape, 1) }
            return (.escape, 1)  // Alt+key: treat as Esc then key.
        case 0x0D, 0x0A: return (.enter, 1)
        case 0x09: return (.tab, 1)
        case 0x7F, 0x08: return (.backspace, 1)
        case 0x20: return (.space, 1)
        case 0x01...0x1A: return (.ctrl(Character(UnicodeScalar(b + 0x60))), 1)
        case 0x00...0x1F: return (nil, 1)
        default:
            let length = b < 0x80 ? 1 : b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            guard pending.count >= length else { return nil }
            let s = String(decoding: pending[0..<length], as: UTF8.self)
            return (s.first.map(Key.char), length)
        }
    }
}

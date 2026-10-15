/// Color depth of the attached terminal.
public enum ColorMode: Sendable {
    case truecolor, ansi256, none

    /// Detects from the environment (`NO_COLOR`, `COLORTERM`, `TERM`).
    public static func detect(_ env: [String: String]) -> ColorMode {
        if env["NO_COLOR"].map({ !$0.isEmpty }) == true { return .none }
        if let c = env["COLORTERM"]?.lowercased(), c == "truecolor" || c == "24bit" { return .truecolor }
        let program = env["TERM_PROGRAM"] ?? ""
        if ["ghostty", "iTerm.app", "WezTerm", "vscode"].contains(program) { return .truecolor }
        if env["TERM"]?.contains("kitty") == true || env["TERM"]?.contains("ghostty") == true { return .truecolor }
        return .ansi256
    }
}

/// Turns canvases into ANSI output, writing only cells that changed since
/// the previous frame.
public struct Renderer: Sendable {
    public var colorMode: ColorMode
    private var previous: Canvas?
    /// Whether the last frame cleared the screen (graphics must re-place).
    public private(set) var lastFrameWasFull = false

    public init(colorMode: ColorMode) { self.colorMode = colorMode }

    /// Forces the next frame to redraw everything (e.g. after resume).
    public mutating func invalidate() { previous = nil }

    public mutating func frame(_ canvas: Canvas) -> String {
        var out = "\u{1B}[?2026h"  // synchronized update (ignored if unsupported)
        let full = previous == nil || previous!.width != canvas.width || previous!.height != canvas.height
        if full { out += "\u{1B}[0m\u{1B}[2J" }
        lastFrameWasFull = full

        var currentStyle: Style? = nil
        for y in 0..<canvas.height {
            var cursorX = -1
            var x = 0
            while x < canvas.width {
                let cell = canvas[x, y]
                if cell.continuation { x += 1; continue }
                let wide = cellWidth(cell.char) == 2 && x + 1 < canvas.width
                var changed = full || previous![x, y] != cell
                if !changed, wide { changed = previous![x + 1, y] != canvas[x + 1, y] }
                if changed {
                    if cursorX != x { out += "\u{1B}[\(y + 1);\(x + 1)H" }
                    if cell.style != currentStyle {
                        out += sgr(cell.style)
                        currentStyle = cell.style
                    }
                    out.append(cell.char)
                    cursorX = x + (wide ? 2 : 1)
                }
                x += wide ? 2 : 1
            }
        }
        out += "\u{1B}[0m\u{1B}[?2026l"
        previous = canvas
        return out
    }

    func sgr(_ s: Style) -> String {
        var codes = ["0"]
        if s.bold == true { codes.append("1") }
        if s.dim == true { codes.append("2") }
        if s.italic == true { codes.append("3") }
        if s.underline == true { codes.append("4") }
        if s.reverse == true { codes.append("7") }
        if colorMode != .none {
            if let fg = s.fg, let c = color(fg, foreground: true) { codes.append(c) }
            if let bg = s.bg, let c = color(bg, foreground: false) { codes.append(c) }
        }
        return "\u{1B}[" + codes.joined(separator: ";") + "m"
    }

    private func color(_ c: TermColor, foreground: Bool) -> String? {
        guard case .rgb(let r, let g, let b) = c else { return nil }
        let base = foreground ? "38" : "48"
        switch colorMode {
        case .truecolor: return "\(base);2;\(r);\(g);\(b)"
        case .ansi256: return "\(base);5;\(Self.ansi256(r, g, b))"
        case .none: return nil
        }
    }

    /// Nearest xterm-256 color (6×6×6 cube or grayscale ramp).
    static func ansi256(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        let levels = [0, 95, 135, 175, 215, 255]
        func nearest(_ v: UInt8) -> Int {
            levels.enumerated().min { abs($0.element - Int(v)) < abs($1.element - Int(v)) }!.offset
        }
        let (ri, gi, bi) = (nearest(r), nearest(g), nearest(b))
        let cubeIndex = 16 + 36 * ri + 6 * gi + bi
        let cubeDist = sq(levels[ri] - Int(r)) + sq(levels[gi] - Int(g)) + sq(levels[bi] - Int(b))

        let avg = (Int(r) + Int(g) + Int(b)) / 3
        let grayStep = min(23, max(0, (avg - 8 + 5) / 10))
        let grayValue = 8 + grayStep * 10
        let grayDist = sq(grayValue - Int(r)) + sq(grayValue - Int(g)) + sq(grayValue - Int(b))
        return grayDist < cubeDist ? 232 + grayStep : cubeIndex
    }

    private static func sq(_ v: Int) -> Int { v * v }
}

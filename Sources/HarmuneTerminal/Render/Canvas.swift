/// Terminal colors. `.default` leaves the terminal's own color.
public enum TermColor: Equatable, Sendable {
    case `default`
    case rgb(UInt8, UInt8, UInt8)

    public init(hex: UInt32) {
        self = .rgb(UInt8(hex >> 16 & 0xFF), UInt8(hex >> 8 & 0xFF), UInt8(hex & 0xFF))
    }
}

/// Cell style. `nil` fields inherit from what is already in the cell, so
/// text drawn over a filled panel keeps the panel background.
public struct Style: Equatable, Sendable {
    public var fg: TermColor?
    public var bg: TermColor?
    public var bold: Bool?
    public var dim: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var reverse: Bool?

    public init(fg: TermColor? = nil, bg: TermColor? = nil, bold: Bool? = nil, dim: Bool? = nil,
                italic: Bool? = nil, underline: Bool? = nil, reverse: Bool? = nil) {
        self.fg = fg; self.bg = bg; self.bold = bold; self.dim = dim
        self.italic = italic; self.underline = underline; self.reverse = reverse
    }

    public func over(_ base: Style) -> Style {
        Style(fg: fg ?? base.fg, bg: bg ?? base.bg, bold: bold ?? base.bold, dim: dim ?? base.dim,
              italic: italic ?? base.italic, underline: underline ?? base.underline, reverse: reverse ?? base.reverse)
    }
}

public struct Cell: Equatable, Sendable {
    public var char: Character = " "
    public var style = Style()
    /// Right half of a double-width character; not written to the terminal.
    public var continuation = false
}

public struct Rect: Hashable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = max(0, width); self.height = max(0, height)
    }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width == 0 || height == 0 }

    public func inset(dx: Int, dy: Int) -> Rect { Rect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy) }
    public func row(_ i: Int) -> Rect { Rect(x: x, y: y + i, width: width, height: 1) }

    /// Splits off `n` columns from the left.
    public func splitLeft(_ n: Int) -> (Rect, Rect) {
        let n = min(max(0, n), width)
        return (Rect(x: x, y: y, width: n, height: height), Rect(x: x + n, y: y, width: width - n, height: height))
    }
    public func splitRight(_ n: Int) -> (Rect, Rect) {
        let (l, r) = splitLeft(width - n)
        return (l, r)
    }
    public func splitTop(_ n: Int) -> (Rect, Rect) {
        let n = min(max(0, n), height)
        return (Rect(x: x, y: y, width: width, height: n), Rect(x: x, y: y + n, width: width, height: height - n))
    }
    public func splitBottom(_ n: Int) -> (Rect, Rect) {
        let (t, b) = splitTop(height - n)
        return (t, b)
    }
}

/// Display width of a character in terminal cells (0, 1 or 2).
public func cellWidth(_ c: Character) -> Int {
    guard let s = c.unicodeScalars.first else { return 0 }
    let v = s.value
    if v < 0x20 || (0x7F..<0xA0).contains(v) { return 0 }
    if s.properties.generalCategory == .nonspacingMark { return 0 }
    let wide: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
        0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD,
    ]
    return wide.contains { $0.contains(v) } ? 2 : 1
}

public func textWidth(_ s: String) -> Int { s.reduce(0) { $0 + cellWidth($1) } }

/// Truncates to `width` cells, ending with `…` when cut.
public func truncate(_ s: String, to width: Int) -> String {
    guard width > 0 else { return "" }
    if textWidth(s) <= width { return s }
    var out = "", used = 0
    for c in s {
        let w = cellWidth(c)
        if used + w > width - 1 { break }
        out.append(c); used += w
    }
    return out + "…"
}

public func pad(_ s: String, to width: Int, alignRight: Bool = false) -> String {
    let t = truncate(s, to: width)
    let gap = String(repeating: " ", count: max(0, width - textWidth(t)))
    return alignRight ? gap + t : t + gap
}

/// A grid of styled cells. Drawing is clipped to the canvas.
public struct Canvas: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public private(set) var cells: [Cell]
    /// Terminal-protocol images to show over this frame.
    public var imagePlacements: [ImagePlacement] = []
    /// Artwork the views wanted but that isn't decoded yet.
    public var artworkRequests: Set<ArtworkKey> = []

    public init(width: Int, height: Int, style: Style = Style()) {
        self.width = max(0, width); self.height = max(0, height)
        cells = Array(repeating: Cell(char: " ", style: style), count: self.width * self.height)
    }

    public var bounds: Rect { Rect(x: 0, y: 0, width: width, height: height) }

    public subscript(x: Int, y: Int) -> Cell {
        get { cells[y * width + x] }
        set { cells[y * width + x] = newValue }
    }

    public mutating func fill(_ rect: Rect, char: Character = " ", style: Style) {
        for y in max(0, rect.y)..<min(height, rect.maxY) {
            for x in max(0, rect.x)..<min(width, rect.maxX) {
                self[x, y] = Cell(char: char, style: style.over(self[x, y].style))
            }
        }
    }

    /// Restyles cells without changing their characters.
    public mutating func paint(_ rect: Rect, style: Style) {
        for y in max(0, rect.y)..<min(height, rect.maxY) {
            for x in max(0, rect.x)..<min(width, rect.maxX) {
                self[x, y].style = style.over(self[x, y].style)
            }
        }
    }

    /// Draws text clipped to `maxWidth` (and the canvas). Returns the
    /// number of columns used.
    @discardableResult
    public mutating func text(_ s: String, x: Int, y: Int, maxWidth: Int? = nil, style: Style = Style()) -> Int {
        guard y >= 0, y < height else { return 0 }
        let limit = min(maxWidth ?? Int.max, width - x)
        guard limit > 0 else { return 0 }
        var col = x
        for c in truncate(s, to: limit) {
            let w = cellWidth(c)
            guard w > 0 else { continue }
            if col >= 0, col + w <= width {
                self[col, y] = Cell(char: c, style: style.over(self[col, y].style))
                if w == 2 { self[col + 1, y] = Cell(char: " ", style: self[col, y].style, continuation: true) }
            }
            col += w
        }
        return col - x
    }

    public mutating func hline(_ y: Int, from x0: Int, to x1: Int, char: Character = "─", style: Style) {
        for x in max(0, x0)..<min(width, x1) where y >= 0 && y < height {
            self[x, y] = Cell(char: char, style: style.over(self[x, y].style))
        }
    }

    public mutating func vline(_ x: Int, from y0: Int, to y1: Int, char: Character = "│", style: Style) {
        for y in max(0, y0)..<min(height, y1) where x >= 0 && x < width {
            self[x, y] = Cell(char: char, style: style.over(self[x, y].style))
        }
    }

    /// The characters only, one line per row (for tests and snapshots).
    public var plainText: String {
        (0..<height).map { y in
            String((0..<width).compactMap { x in self[x, y].continuation ? nil : self[x, y].char })
        }.joined(separator: "\n")
    }
}

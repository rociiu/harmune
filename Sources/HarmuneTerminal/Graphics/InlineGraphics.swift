import Foundation

/// Images drawn into cells: iTerm2's OSC 1337 (iTerm2, WezTerm) and Sixel.
///
/// Unlike Kitty's images, these replace the cells they cover and have no ID
/// to delete them by. So when one moves or goes away, the run loop calls
/// `removed` and has the renderer rewrite those cells.
public struct InlineGraphics: Sendable {
    public enum Format: Sendable { case iterm2, sixel }

    public let format: Format
    public var cellPixels: (width: Int, height: Int)
    private var placed: Set<ImagePlacement> = []
    private var payloads: [ArtworkKey: String] = [:]
    private static let maxCached = 64
    private static let maxSixelSide = 640

    public init(format: Format, cellPixels: (width: Int, height: Int) = (10, 20)) {
        self.format = format
        self.cellPixels = cellPixels
    }

    /// Rects of images that aren't wanted any more, which must be redrawn.
    public mutating func removed(_ wanted: [ImagePlacement]) -> [Rect] {
        let gone = placed.subtracting(wanted)
        placed.subtract(gone)
        return gone.map(\.rect)
    }

    /// The screen was cleared, so nothing is showing any more.
    public mutating func reset() { placed.removeAll() }

    /// Escape sequences that draw whatever isn't on screen yet.
    public mutating func place(_ wanted: [ImagePlacement]) -> String {
        var out = ""
        for placement in wanted where !placed.contains(placement) {
            guard let payload = payload(for: placement) else { continue }
            out += "\u{1B}7\u{1B}[\(placement.rect.y + 1);\(placement.rect.x + 1)H" + payload + "\u{1B}8"
            placed.insert(placement)
        }
        return out
    }

    private mutating func payload(for placement: ImagePlacement) -> String? {
        let key = ArtworkKey(path: placement.path, columns: placement.rect.width, rows: placement.rect.height)
        if let cached = payloads[key] { return cached }
        let made: String?
        switch format {
        case .iterm2:
            made = FileManager.default.contents(atPath: placement.path).map {
                Self.iterm2($0, columns: placement.rect.width, rows: placement.rect.height)
            }
        case .sixel:
            let width = min(placement.rect.width * cellPixels.width, Self.maxSixelSide)
            let height = min(placement.rect.height * cellPixels.height, Self.maxSixelSide)
            made = PixelGrid.load(path: placement.path, width: width, height: height).map(Sixel.encode)
        }
        guard let made else { return nil }
        if payloads.count >= Self.maxCached { payloads.removeAll() }
        payloads[key] = made
        return made
    }

    static func iterm2(_ data: Data, columns: Int, rows: Int) -> String {
        "\u{1B}]1337;File=inline=1;size=\(data.count);width=\(columns);height=\(rows);preserveAspectRatio=0;doNotMoveCursor=1:"
            + data.base64EncodedString() + "\u{07}"
    }
}

/// Encodes pixels as Sixel, using the 216 colors of a 6×6×6 cube.
enum Sixel {
    static func encode(_ grid: PixelGrid) -> String {
        let (w, h) = (grid.width, grid.height)
        var indices = [UInt8](repeating: 0, count: w * h)
        var used = [Bool](repeating: false, count: 216)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = grid.pixel(x, y)
                let index = (Int(r) * 5 + 127) / 255 * 36 + (Int(g) * 5 + 127) / 255 * 6 + (Int(b) * 5 + 127) / 255
                indices[y * w + x] = UInt8(index)
                used[index] = true
            }
        }

        var out = Array("\u{1B}P0;1;0q\"1;1;\(w);\(h)".utf8)
        for color in 0..<216 where used[color] {
            let (r, g, b) = (color / 36 * 20, color / 6 % 6 * 20, color % 6 * 20)
            out += Array("#\(color);2;\(r);\(g);\(b)".utf8)
        }
        var masks = [UInt8](repeating: 0, count: w)
        for band in stride(from: 0, to: h, by: 6) {
            var inBand = [Bool](repeating: false, count: 216)
            for i in (band * w)..<(min(band + 6, h) * w) { inBand[Int(indices[i])] = true }
            for color in 0..<216 where inBand[color] {
                for x in 0..<w {
                    var mask: UInt8 = 0
                    for row in 0..<min(6, h - band) where indices[(band + row) * w + x] == color { mask |= 1 << row }
                    masks[x] = mask
                }
                out += Array("#\(color)".utf8)
                var x = 0
                while x < w {
                    var end = x + 1
                    while end < w, masks[end] == masks[x] { end += 1 }
                    let run = end - x
                    if run >= 4 { out += Array("!\(run)".utf8) + [63 + masks[x]] }
                    else { out += [UInt8](repeating: 63 + masks[x], count: run) }
                    x = end
                }
                out.append(UInt8(ascii: "$"))
            }
            out.append(UInt8(ascii: "-"))
        }
        out += Array("\u{1B}\\".utf8)
        return String(decoding: out, as: UTF8.self)
    }
}

/// Picks an accent from a cover for decorative elements (product_spec.md §9.2).
enum DynamicColor {
    /// The most prominent saturated color, lightened until text in it is
    /// readable on `background`. Nil for grayscale covers, which keep the
    /// theme's accent.
    static func accent(from grid: PixelGrid, on background: TermColor) -> TermColor? {
        guard case .rgb(let br, let bg, let bb) = background else { return nil }
        var scores: [Int: (score: Double, r: Int, g: Int, b: Int, n: Int)] = [:]
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                let (r, g, b) = grid.pixel(x, y)
                let high = Double(max(r, g, b)) / 255, low = Double(min(r, g, b)) / 255
                let saturation = high > 0 ? (high - low) / high : 0
                guard saturation > 0.25, high > 0.2 else { continue }
                let bucket = Int(r >> 4) << 8 | Int(g >> 4) << 4 | Int(b >> 4)
                var entry = scores[bucket] ?? (0, 0, 0, 0, 0)
                entry.score += saturation * high
                entry.r += Int(r); entry.g += Int(g); entry.b += Int(b); entry.n += 1
                scores[bucket] = entry
            }
        }
        guard let best = scores.values.max(by: { $0.score < $1.score }), best.n > 0 else { return nil }
        var color = (Double(best.r / best.n), Double(best.g / best.n), Double(best.b / best.n))
        let backgroundLuminance = luminance(Double(br), Double(bg), Double(bb))
        var steps = 0
        while contrast(luminance(color.0, color.1, color.2), backgroundLuminance) < 4.5, steps < 12 {
            color = (color.0 + (255 - color.0) * 0.15, color.1 + (255 - color.1) * 0.15, color.2 + (255 - color.2) * 0.15)
            steps += 1
        }
        guard contrast(luminance(color.0, color.1, color.2), backgroundLuminance) >= 4.5 else { return nil }
        return .rgb(UInt8(color.0), UInt8(color.1), UInt8(color.2))
    }

    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func channel(_ v: Double) -> Double {
            let c = v / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

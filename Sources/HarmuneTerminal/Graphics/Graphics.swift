import CoreGraphics
import Foundation
import ImageIO

/// How artwork is drawn in this terminal (product_spec.md §10.6).
public enum GraphicsMode: String, Sendable, CaseIterable {
    /// Kitty graphics protocol (Kitty, Ghostty).
    case kitty
    /// iTerm2 inline images (iTerm2, WezTerm).
    case iterm2
    /// Sixel, for terminals that support it.
    case sixel
    /// Real pixels approximated with `▀` cells and fg/bg colors.
    case halfblock
    /// Generated gradient placeholders only.
    case none

    /// Picks a mode from the environment. `HARMUNE_GRAPHICS` overrides.
    ///
    /// Detection goes by the terminal's name, because every terminal here
    /// identifies itself. tmux gets half-blocks: images need its passthrough
    /// setting, which is off by default and can't be detected from here.
    public static func detect(_ env: [String: String], colorMode: ColorMode) -> GraphicsMode {
        if let forced = env["HARMUNE_GRAPHICS"].flatMap(GraphicsMode.init(rawValue:)) { return forced }
        if colorMode == .none { return .none }
        if env["TMUX"] != nil { return .halfblock }  // needs passthrough; not yet supported
        let term = env["TERM"] ?? "", program = env["TERM_PROGRAM"] ?? ""
        if env["KITTY_WINDOW_ID"] != nil || term.contains("kitty") || program == "ghostty" || term.contains("ghostty") {
            return .kitty
        }
        if program == "iTerm.app" || program == "WezTerm" { return .iterm2 }
        if term.contains("sixel") || term.hasPrefix("foot") || term.hasPrefix("mlterm") || program == "contour" { return .sixel }
        return .halfblock
    }

    /// Whether the terminal draws the file, rather than Harmune drawing cells.
    var usesPlacements: Bool { self == .kitty || self == .iterm2 || self == .sixel }
}

/// A decoded image scaled to a pixel grid.
public struct PixelGrid: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// RGB triplets, row-major.
    public let rgb: [UInt8]

    public func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (min(y, height - 1) * width + min(x, width - 1)) * 3
        return (rgb[i], rgb[i + 1], rgb[i + 2])
    }

    /// Decodes and resamples an image file. Returns nil if unreadable.
    public static func load(path: String, width: Int, height: Int) -> PixelGrid? {
        guard width > 0, height > 0,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](); rgb.reserveCapacity(width * height * 3)
        for i in stride(from: 0, to: buffer.count, by: 4) { rgb += buffer[i..<i + 3] }
        return PixelGrid(width: width, height: height, rgb: rgb)
    }
}

/// Identifies a decoded image at a cell size.
public struct ArtworkKey: Hashable, Sendable {
    public var path: String
    public var columns: Int
    public var rows: Int
}

/// Where a terminal-protocol image should appear in a frame.
public struct ImagePlacement: Hashable, Sendable {
    public var path: String
    public var rect: Rect
}


/// What the views need to draw artwork: the mode and whatever has been
/// decoded so far. Views record what they still need in the canvas.
public struct ArtworkSnapshot: Sendable {
    public var mode: GraphicsMode
    public var decoded: [ArtworkKey: PixelGrid]
    public var available: Set<String>
    /// `:artwork off` shows placeholders without changing the mode.
    public var enabled: Bool

    public init(mode: GraphicsMode = .none, decoded: [ArtworkKey: PixelGrid] = [:], available: Set<String> = [],
                enabled: Bool = true) {
        self.mode = mode; self.decoded = decoded; self.available = available; self.enabled = enabled
    }
}

/// Draws artwork for `path` into `rect`, using the best available method,
/// falling back to a placeholder gradient.
enum Artwork {
    static func draw(_ c: inout Canvas, _ rect: Rect, path: String?, seed: String, theme: Theme, art: ArtworkSnapshot,
                     transition: (previousSeed: String, progress: Double)? = nil) {
        guard rect.width > 0, rect.height > 0 else { return }
        guard let path, art.enabled, art.mode != .none, !theme.usesReverseSelection else {
            ArtworkPlaceholder.draw(&c, rect, seed: seed, theme: theme, transition: transition)
            return
        }
        switch art.mode {
        case .kitty where art.available.contains(path):
            c.fill(rect, style: Style(bg: theme.surface))
            c.imagePlacements.append(ImagePlacement(path: path, rect: rect))
        case .iterm2 where art.available.contains(path), .sixel where art.available.contains(path):
            c.blank(rect, style: Style(bg: theme.surface))
            c.imagePlacements.append(ImagePlacement(path: path, rect: rect))
        case .kitty, .iterm2, .sixel:
            c.artworkRequests.insert(ArtworkKey(path: path, columns: 0, rows: 0))
            ArtworkPlaceholder.draw(&c, rect, seed: seed, theme: theme, transition: transition)
        case .halfblock:
            let key = ArtworkKey(path: path, columns: rect.width, rows: rect.height)
            if let grid = art.decoded[key] {
                HalfBlock.draw(&c, rect, grid)
            } else {
                c.artworkRequests.insert(key)
                ArtworkPlaceholder.draw(&c, rect, seed: seed, theme: theme, transition: transition)
            }
        case .none:
            ArtworkPlaceholder.draw(&c, rect, seed: seed, theme: theme, transition: transition)
        }
    }
}

enum HalfBlock {
    /// Each cell shows two vertical pixels: top as fg of `▀`, bottom as bg.
    static func draw(_ c: inout Canvas, _ r: Rect, _ grid: PixelGrid) {
        for y in 0..<r.height {
            for x in 0..<r.width {
                let top = grid.pixel(x, y * 2), bottom = grid.pixel(x, y * 2 + 1)
                c.text("▀", x: r.x + x, y: r.y + y,
                       style: Style(fg: .rgb(top.0, top.1, top.2), bg: .rgb(bottom.0, bottom.1, bottom.2)))
            }
        }
    }
}

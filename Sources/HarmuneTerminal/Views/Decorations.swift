import Foundation
import HarmuneCore

/// Stable hash (Swift's `hashValue` is randomized per process).
func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

/// Half-block gradient standing in for album art until the terminal
/// graphics layer (Kitty / iTerm2 / Sixel) lands. Deterministic per album.
enum ArtworkPlaceholder {
    static let palette: [(UInt8, UInt8, UInt8)] = [
        (198, 165, 255), (243, 166, 200), (148, 191, 255), (166, 227, 161),
        (249, 213, 139), (243, 139, 168), (120, 90, 200), (60, 70, 140),
    ]

    static func draw(_ c: inout Canvas, _ r: Rect, seed: String, theme: Theme) {
        guard r.width > 0, r.height > 0 else { return }
        if theme.usesReverseSelection {
            c.fill(r, char: "░", style: Style())
            c.text("♪", x: r.x + r.width / 2, y: r.y + r.height / 2, style: Style(bold: true))
            return
        }
        let h = stableHash(seed)
        let a = palette[Int(h % 8)], b = palette[Int((h >> 8) % 8)]
        let dark: (UInt8, UInt8, UInt8) = (24, 24, 36)
        let angle = Double(h >> 16 & 0xFF) / 255.0
        func color(_ x: Int, _ y: Int) -> TermColor {
            let fx = Double(x) / Double(max(1, r.width - 1))
            let fy = Double(y) / Double(max(1, r.height * 2 - 1))
            let t = fx * angle + fy * (1 - angle)
            let mixed = mix(a, b, t)
            // Vignette toward the edges for a softer look.
            let edge = min(fx, 1 - fx, fy, 1 - fy) * 2
            let rgb = mix(dark, mixed, min(1, 0.45 + edge))
            return .rgb(rgb.0, rgb.1, rgb.2)
        }
        for y in 0..<r.height {
            for x in 0..<r.width {
                c.text("▀", x: r.x + x, y: r.y + y, style: Style(fg: color(x, y * 2), bg: color(x, y * 2 + 1)))
            }
        }
    }

    static func mix(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8), _ t: Double) -> (UInt8, UInt8, UInt8) {
        let t = min(max(t, 0), 1)
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8(Double(x) + (Double(y) - Double(x)) * t) }
        return (m(a.0, b.0), m(a.1, b.1), m(a.2, b.2))
    }
}

/// Decorative spectrum. Not audio-reactive: MusicKit does not expose
/// decoded audio (product_spec.md §9.2). Frozen while paused.
enum Visualizer {
    static let levels: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    /// Draws one row of bars; returns rows used.
    @discardableResult
    static func draw(_ c: inout Canvas, _ r: Rect, _ s: AppState, compact: Bool = false) -> Int {
        guard r.width > 0, r.height > 0, let track = s.playback.track else { return 0 }
        // Reduced motion: a still frame.
        let t = s.art.reducedMotion ? 0 : s.playback.position(at: s.now)
        let seed = Double(stableHash(track.id) % 1000) / 100
        let bars = compact ? r.width : min(r.width, 48)
        let x0 = r.x + (r.width - bars) / 2
        for i in 0..<bars {
            let fi = Double(i)
            let v = 0.5 + 0.25 * sin(fi * 0.55 + t * 3.1 + seed) + 0.2 * sin(fi * 1.7 - t * 5.3 + seed * 2)
                + 0.1 * sin(t * 7 + fi)
            let level = Int((min(max(v, 0), 0.999)) * Double(levels.count))
            let frac = Double(i) / Double(max(1, bars - 1))
            let col = ArtworkPlaceholder.mix((198, 165, 255), (148, 191, 255), frac)
            let style = s.theme.usesReverseSelection ? Style() : Style(fg: .rgb(col.0, col.1, col.2))
            c.text(String(levels[level]), x: x0 + i, y: r.y, style: style)
        }
        return 1
    }
}

enum NowPlayingView {
    static func draw(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        let t = s.theme
        guard let track = s.playback.track else {
            c.text("Nothing playing", x: r.x + max(0, (r.width - 15) / 2), y: r.y + r.height / 2, style: t.dimmed)
            return
        }
        // Artwork sized to ~55% of the height, square in cells (2:1).
        let artH = max(3, min((r.height - 10), Int(Double(r.height) * 0.55)))
        let artW = min(r.width - 4, artH * 2)
        let art = Rect(x: r.x + (r.width - artW) / 2, y: r.y + 1, width: artW, height: artH)
        Artwork.draw(&c, art, path: track.artwork?.path, seed: track.album, theme: t, art: s.art)

        var y = art.maxY + 1
        func centered(_ text: String, _ style: Style) {
            let w = min(textWidth(text), r.width - 2)
            c.text(text, x: r.x + (r.width - w) / 2, y: y, maxWidth: r.width - 2, style: style)
            y += 1
        }
        centered(track.title.uppercased(), Style(fg: t.text, bold: true))
        centered(track.artist, Style(fg: t.accent))
        centered(track.album, t.secondary)
        y += 1

        let barW = min(r.width - 8, 56)
        let bx = r.x + (r.width - barW) / 2
        let position = s.playback.position(at: s.now)
        if y < r.maxY {
            ShellView.drawProgress(&c, x: bx, y: y, width: barW, fraction: position / max(1, track.duration), theme: t)
            y += 1
            c.text(formatTime(position), x: bx, y: y, style: t.secondary)
            let total = formatTime(track.duration)
            c.text(total, x: bx + barW - textWidth(total), y: y, style: t.secondary)
            y += 2
        }
        if y < r.maxY - 2 {
            Visualizer.draw(&c, Rect(x: bx, y: y, width: barW, height: 1), s)
            y += 2
        }
        if y < r.maxY {
            let p = s.playback
            let flags = "\(p.shuffle ? "⤨ shuffle" : "")\(p.repeat != .off ? "   ↻ repeat \(p.repeat.rawValue)" : "")"
            centered("◀◀        \(p.isPlaying ? "Ⅱ" : "▶")        ▶▶", Style(fg: t.text, bold: true))
            if !flags.isEmpty, y < r.maxY { centered(flags, Style(fg: t.accent)) }
        }
    }
}

enum HelpContent {
    struct Line { var keys: String; var action: String }

    static let lines: [Line] = [
        Line(keys: "", action: "NAVIGATION"),
        Line(keys: "j / k", action: "move down / up (5j moves five)"),
        Line(keys: "gg / G", action: "first / last item"),
        Line(keys: "Ctrl+d / Ctrl+u", action: "half page down / up"),
        Line(keys: "l / Enter", action: "open or play the selection"),
        Line(keys: "h / Esc", action: "back"),
        Line(keys: "Tab", action: "switch between sidebar and content"),
        Line(keys: "gh gs gl ga gA", action: "home · search · songs · albums · artists"),
        Line(keys: "gp gq gn", action: "playlists · queue · now playing"),
        Line(keys: "", action: "PLAYBACK"),
        Line(keys: "Space", action: "play / pause"),
        Line(keys: "> / <", action: "next / previous track"),
        Line(keys: "] / [", action: "seek ±5 seconds"),
        Line(keys: "s / r", action: "shuffle / cycle repeat"),
        Line(keys: "v", action: "now playing"),
        Line(keys: "", action: "QUEUE"),
        Line(keys: "a / p", action: "add to queue / play next"),
        Line(keys: "dd  J/K  D", action: "remove · move · clear (in Queue)"),
        Line(keys: "", action: "SEARCH & COMMANDS"),
        Line(keys: "/", action: "search (Ctrl+S toggles Apple Music / Library)"),
        Line(keys: "F", action: "filter the current list"),
        Line(keys: ":", action: "command (:theme mono, :seek 90, :q)"),
        Line(keys: "q", action: "back; quit from the root (music keeps playing)"),
    ]
}

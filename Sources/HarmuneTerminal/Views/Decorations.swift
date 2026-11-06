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

    static func draw(_ c: inout Canvas, _ r: Rect, seed: String, theme: Theme,
                     transition: (previousSeed: String, progress: Double)? = nil) {
        guard r.width > 0, r.height > 0 else { return }
        if theme.usesReverseSelection {
            c.fill(r, char: "░", style: Style())
            c.text("♪", x: r.x + r.width / 2, y: r.y + r.height / 2, style: Style(bold: true))
            return
        }
        let h = stableHash(seed)
        var a = palette[Int(h % 8)], b = palette[Int((h >> 8) % 8)]
        if let transition, transition.previousSeed != seed {
            let oldHash = stableHash(transition.previousSeed)
            a = mix(palette[Int(oldHash % 8)], a, transition.progress)
            b = mix(palette[Int((oldHash >> 8) % 8)], b, transition.progress)
        }
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

    /// Draws one row of bars.
    static func draw(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        guard r.width > 0, r.height > 0, let track = s.playback.track else { return }
        // Reduced motion: a still frame.
        let t = s.prefs.reducedMotion ? 0 : s.playback.position(at: s.now)
        let seed = Double(stableHash(track.id) % 1000) / 100
        let bars = min(r.width, 48)
        let x0 = r.x + (r.width - bars) / 2
        for i in 0..<bars {
            let fi = Double(i)
            let v = 0.5 + 0.25 * sin(fi * 0.55 + t * 3.1 + seed) + 0.2 * sin(fi * 1.7 - t * 5.3 + seed * 2)
                + 0.1 * sin(t * 7 + fi)
            let level = Int((min(max(v, 0), 0.999)) * Double(levels.count))
            let frac = Double(i) / Double(max(1, bars - 1))
            let theme = s.decorativeTheme
            let style: Style
            if case .rgb(let r1, let g1, let b1) = theme.accent, case .rgb(let r2, let g2, let b2) = theme.accentBlue {
                let col = ArtworkPlaceholder.mix((r1, g1, b1), (r2, g2, b2), frac)
                style = Style(fg: .rgb(col.0, col.1, col.2))
            } else {
                style = Style()
            }
            c.text(String(levels[level]), x: x0 + i, y: r.y, style: style)
        }
    }
}

enum NowPlayingView {
    /// Full-screen Now Playing: header, large cover, progress and visualizer.
    static func drawImmersive(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        let t = s.decorativeTheme
        c.text("$", x: r.x + 2, y: r.y, style: t.accentStyle)
        c.text("harmune", x: r.x + 4, y: r.y, style: Style(fg: t.text, bold: true))
        let label = "Now playing"
        if r.width >= 28 {
            c.text(label, x: r.maxX - textWidth(label) - 2, y: r.y, style: t.secondary)
        }
        draw(&c, Rect(x: r.x, y: r.y + 1, width: r.width, height: r.height - 1), s)
    }

    static func draw(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        let t = s.decorativeTheme
        guard let track = s.playback.track else {
            c.text("Nothing playing", x: r.x + max(0, (r.width - 15) / 2), y: r.y + r.height / 2, style: t.dimmed)
            return
        }
        if s.prefs.dynamicColors {
            ArtworkBackdrop.draw(&c, r, path: track.artwork?.path, theme: t, art: s.art)
        }
        // Square on screen, because cells are about twice as tall as wide.
        let artH = max(3, min(r.height - 10, Int(Double(r.height) * s.prefs.artworkSize.fraction)))
        let artW = min(r.width - 4, artH * 2)
        let art = Rect(x: r.x + (r.width - artW) / 2, y: r.y + 1, width: artW, height: artH)
        let transitionProgress = s.trackTransitionProgress
        let transition = transitionProgress.flatMap { progress in
            s.trackTransition.map { (previousSeed: $0.previousAlbum, progress: progress) }
        }
        Artwork.draw(&c, art, path: track.artwork?.path, seed: track.album, theme: t, art: s.art, transition: transition)

        var y = art.maxY + 1
        func centered(_ text: String, _ style: Style, slide: Int = 0) {
            guard y < r.maxY else { return }
            let w = min(textWidth(text), r.width - 2)
            let padding = (r.width - w) / 2
            c.text(text, x: r.x + padding + min(slide, max(0, padding - 1)), y: y,
                   maxWidth: w, style: style)
            y += 1
        }
        centered(track.title.uppercased(), Style(fg: t.text, bold: true), slide: transitionProgress.map { Int((4 * (1 - $0)).rounded()) } ?? 0)
        centered(track.artist, Style(fg: t.accent))
        centered(track.album, t.secondary)
        y += 1

        let barW = min(r.width - 8, 56)
        let bx = r.x + (r.width - barW) / 2
        let position = s.playback.position(at: s.now)
        if y < r.maxY, s.prefs.showProgress {
            ShellView.drawProgress(&c, x: bx, y: y, width: barW, fraction: position / max(1, track.duration), theme: t)
            y += 1
            c.text(formatTime(position), x: bx, y: y, style: t.secondary)
            let total = formatTime(track.duration)
            c.text(total, x: bx + barW - textWidth(total), y: y, style: t.secondary)
            y += 2
        }
        if y < r.maxY - 2, s.prefs.showVisualizer {
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

    static func lines(_ keymap: Keymap) -> [Line] {
        Keymap.helpSections.flatMap { section -> [Line] in
            let rows = section.entries.compactMap { entry -> Line? in
                let keys = keymap.keysLabel(for: entry)
                return keys.isEmpty ? nil : Line(keys: keys, action: entry.action)
            }
            return [Line(keys: "", action: section.title)] + rows
        }
    }
}

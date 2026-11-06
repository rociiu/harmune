import Foundation
import HarmuneCore

/// Regions computed for a terminal size. Shared by the renderer and the
/// run loop (which needs `listHeight` for paging).
public struct ShellLayout: Equatable, Sendable {
    public var header: Rect?
    public var sidebar: Rect?
    public var content: Rect
    public var rightPanel: Rect?
    public var player: Rect
    public var status: Rect

    public init(columns: Int, rows: Int) {
        let lc = LayoutClass(columns: columns, rows: rows)
        var area = Rect(x: 0, y: 0, width: columns, height: rows)
        (area, status) = area.splitBottom(1)
        let playerHeight = lc.playerRows + 1  // + separator line
        (area, player) = area.splitBottom(min(playerHeight, max(0, area.height - 1)))
        if lc.showsHeader {
            var h: Rect
            (h, area) = area.splitTop(2)  // title + separator
            header = h
        }
        if lc.showsSidebar {
            var s: Rect
            (s, area) = area.splitLeft(lc.sidebarWidth)
            sidebar = s
        }
        if lc.showsRightPanel {
            var r: Rect
            (area, r) = area.splitRight(lc.rightPanelWidth)
            rightPanel = r
        }
        content = area
    }

    /// Rows available to list items for a screen.
    public func listHeight(hasHeader: Bool) -> Int {
        // breadcrumb + blank, column titles + rule, footer
        max(1, content.height - 5 - (hasHeader ? 5 : 0))
    }
}

public enum ShellView {
    public static func render(_ input: AppState, columns: Int, rows: Int, selectedIndex: Int) -> Canvas {
        var s = input
        if !s.prefs.showBorders { s.theme.border = s.theme.background }
        let theme = s.theme
        var c = Canvas(width: columns, height: rows, style: theme.base)
        guard columns >= 20, rows >= 6 else {
            c.text("Harmune: terminal too small", x: 0, y: 0, style: theme.secondary)
            return c
        }
        let layout = ShellLayout(columns: columns, rows: rows)
        let model = screen(for: s.route, in: s)

        if s.route == .nowPlaying {
            // Immersive: nothing on screen but the music.
            NowPlayingView.drawImmersive(&c, Rect(x: 0, y: 0, width: columns, height: rows - 1), s)
        } else {
            if let h = layout.header { drawHeader(&c, h, s) }
            if let sb = layout.sidebar { drawSidebar(&c, sb, s) }
            drawContent(&c, layout.content, s, model, selectedIndex: selectedIndex)
            if let r = layout.rightPanel { drawRightPanel(&c, r, s) }
            drawPlayer(&c, layout.player, s)
        }
        drawStatus(&c, layout.status, s, model)
        if s.mode == .command { drawSuggestions(&c, above: layout.status, s) }
        if let overlay = s.overlay {
            // Protocol images draw above text, so hide them under overlays.
            c.imagePlacements.removeAll()
            drawOverlay(&c, overlay, s)
        }
        return c
    }

    /// The commands matching what's typed, above the command line.
    static func drawSuggestions(_ c: inout Canvas, above status: Rect, _ s: AppState) {
        let t = s.theme
        let items = Array(CommandLine.suggestions(s.input, themes: s.themes).prefix(8))
        guard !items.isEmpty, status.y > items.count else { return }
        let width = min(status.width - 2, (items.map(textWidth).max() ?? 0) + 4)
        let box = Rect(x: 1, y: status.y - items.count, width: width, height: items.count)
        c.imagePlacements.removeAll { p in
            p.rect.x < box.maxX && box.x < p.rect.maxX && p.rect.y < box.maxY && box.y < p.rect.maxY
        }
        c.fill(box, style: Style(fg: t.text, bg: t.elevated))
        for (i, item) in items.enumerated() {
            c.text(":" + item, x: box.x + 1, y: box.y + i, maxWidth: box.width - 2,
                   style: i == 0 ? Style(fg: t.accent, bold: true) : Style(fg: t.textSecondary))
        }
    }

    // MARK: Header

    static func drawHeader(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        let t = s.theme
        var x = r.x + 2
        x += c.text("◈ ", x: x, y: r.y, style: Style(fg: t.accentPink))
        x += c.text("harmune", x: x, y: r.y, style: t.accentStyle)

        // Search box hint, as in the design.
        let boxX = x + 4
        let scope = s.route.isLibrary ? "Search library…" : "Search Apple Music…"
        if r.width > 70 {
            c.text("/ \(scope)", x: boxX, y: r.y, maxWidth: 30, style: t.dimmed)
        }

        var right: [(String, Style)] = []
        switch s.connection {
        case .connected:
            if let track = s.playback.track {
                right.append((s.playback.isPlaying ? "● Playing" : "● Paused", Style(fg: s.playback.isPlaying ? t.success : t.warning)))
                right.append(("  \(track.title) — \(track.artist)", t.secondary))
            } else {
                right.append(("○ Idle", t.dimmed))
            }
        case .reconnecting: right.append(("◌ Reconnecting…", Style(fg: t.warning)))
        case .offline: right.append(("✕ Host offline", Style(fg: t.error)))
        }
        let rightText = right.map(\.0).joined()
        let maxRight = max(0, r.maxX - (r.width > 70 ? boxX + 32 : x + 2) - 2)
        var rx = r.maxX - 2 - min(textWidth(rightText), maxRight)
        var remaining = maxRight
        for (text, style) in right where remaining > 0 {
            let used = c.text(text, x: rx, y: r.y, maxWidth: remaining, style: style)
            rx += used; remaining -= used
        }
        c.hline(r.y + 1, from: r.x, to: r.maxX, style: t.borderStyle)
    }

    // MARK: Sidebar

    static func drawSidebar(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        let t = s.theme
        c.fill(r, style: Style(bg: t.surface))
        c.vline(r.maxX - 1, from: r.y, to: r.maxY, style: t.borderStyle)
        let focused = s.focus == .sidebar
        let active = s.stack.first ?? .home
        var y = r.y + 1
        var index = 0
        for item in Route.sidebar(s.capabilities) {
            guard y < r.maxY - 1 else { break }
            guard let route = item else {
                y += 1; continue
            }
            let isActive = route == active
            let isCursor = focused && index == s.sidebarIndex
            let line = r.row(y - r.y).inset(dx: 1, dy: 0)
            let rowRect = Rect(x: line.x, y: y, width: line.width - 1, height: 1)
            if isCursor || isActive {
                c.paint(rowRect, style: isCursor ? t.selection(focused: true) : Style(bg: t.elevated))
            }
            let icon = icon(for: route)
            let style = isActive ? Style(fg: t.accent, bold: true) : (isCursor ? Style(fg: t.text) : t.secondary)
            c.text(" \(icon)  \(route.title)", x: rowRect.x, y: y, maxWidth: rowRect.width, style: style)
            y += 1; index += 1
        }
    }

    static func icon(for route: Route) -> String {
        switch route {
        case .home: "⌂"
        case .search: "⌕"
        case .songs: "♪"
        case .albums: "◉"
        case .artists: "☺"
        case .playlists: "≡"
        case .recentlyPlayed: "↺"
        case .queue: "☰"
        case .settings: "⚙"
        default: "·"
        }
    }

    // MARK: Content

    static func drawContent(_ c: inout Canvas, _ r: Rect, _ s: AppState, _ m: ScreenModel, selectedIndex: Int) {
        let t = s.theme
        let area = r.inset(dx: 2, dy: 0)
        var y = r.y + 1
        let focused = s.focus == .content

        // Breadcrumb
        var x = area.x
        let parts = m.breadcrumb.components(separatedBy: " / ")
        for (i, part) in parts.enumerated() {
            if i > 0 { x += c.text(" / ", x: x, y: y, style: t.dimmed) }
            x += c.text(part, x: x, y: y, maxWidth: area.maxX - x,
                        style: i == parts.count - 1 ? Style(fg: t.text, bold: true) : t.secondary)
        }
        if s.loading.contains(s.route) {
            let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            let frame = frames[Int(s.now.timeIntervalSinceReferenceDate * 10) % frames.count]
            c.text("  \(frame)", x: x, y: y, style: Style(fg: t.accent))
        }
        drawTabs(&c, m, y: y, maxX: area.maxX, minX: x + 4, theme: t)
        y += 2

        if let gate = authGate(route: s.route, status: s.auth) {
            c.text(gate.title, x: area.x + 2, y: y + 1, maxWidth: area.width - 2, style: Style(fg: t.accent, bold: true))
            for (i, line) in gate.lines.enumerated() {
                c.text(line, x: area.x + 2, y: y + 3 + i, maxWidth: area.width - 2, style: Style(fg: t.textSecondary))
            }
            return
        }

        // Detail header (album/playlist/artist)
        if let h = m.header {
            let art = Rect(x: area.x, y: y, width: 8, height: 4)
            Artwork.draw(&c, art, path: h.artworkPath, seed: h.title, theme: t, art: s.art)
            let tx = art.maxX + 2
            c.text(h.title.uppercased(), x: tx, y: y, maxWidth: area.maxX - tx, style: Style(fg: t.text, bold: true))
            c.text(h.subtitle, x: tx, y: y + 1, maxWidth: area.maxX - tx, style: Style(fg: t.accent))
            c.text(h.meta, x: tx, y: y + 2, maxWidth: area.maxX - tx, style: t.secondary)
            c.text("Enter play from track   p next   a queue", x: tx, y: y + 3, maxWidth: area.maxX - tx, style: t.dimmed)
            y += 5
        }

        if homeGridApplies(s, width: area.width, height: r.height) {
            let body = Rect(x: area.x, y: y, width: area.width, height: r.maxY - 1 - y)
            if m.rows.isEmpty {
                drawEmpty(&c, m.empty, x: area.x + 2, y: y + 1, width: area.width - 2, loading: s.loading.contains(.home), theme: t)
            } else {
                drawHome(&c, body, s, m, selectedIndex: selectedIndex, focused: focused)
            }
            return
        }

        if gridApplies(s, width: area.width) {
            drawGrid(&c, Rect(x: area.x, y: y, width: area.width, height: r.maxY - 1 - y), s, m,
                     selectedIndex: selectedIndex, focused: focused)
            if let footer = m.footer {
                c.text(footer, x: area.x + 2, y: r.maxY - 1, maxWidth: area.width - 2, style: t.dimmed)
            }
            return
        }

        // Columns
        let cellIndices = m.columns.indices.filter { area.width >= m.columns[$0].minContentWidth }
        let columns = cellIndices.map { m.columns[$0] }
        let widths = columnWidths(columns, total: area.width - 2)
        if !columns.allSatisfy({ $0.title.isEmpty }) {
            var cx = area.x + 2
            for (col, w) in zip(columns, widths) {
                c.text(pad(col.title, to: w, alignRight: col.alignRight), x: cx, y: y, style: t.dimmed)
                cx += w + 1
            }
            y += 1
            c.hline(y, from: area.x, to: area.maxX, style: t.borderStyle)
            y += 1
        } else {
            y += 1
        }

        let footerY = r.maxY - 1
        let listRect = Rect(x: area.x, y: y, width: area.width, height: footerY - y - 1)

        if m.rows.isEmpty {
            drawEmpty(&c, m.empty, x: area.x + 2, y: listRect.y + 1, width: area.width - 2, loading: s.loading.contains(s.route), theme: t)
        } else {
            let top = s.scroll[s.route] ?? 0
            let playingID = s.playback.track?.id
            for (offset, row) in m.rows.dropFirst(top).prefix(listRect.height).enumerated() {
                let ry = listRect.y + offset
                let index = top + offset
                drawRow(&c, row, x: area.x, y: ry, width: area.width, columns: columns, cellIndices: cellIndices, widths: widths,
                        selected: index == selectedIndex, focused: focused,
                        playing: row.trackID != nil && row.trackID == playingID
                            && (row.isQueueCurrent(s.queue) ?? true),
                        theme: t)
            }
            // Scroll indicator
            if m.rows.count > listRect.height, listRect.height > 2 {
                let fraction = Double(top) / Double(max(1, m.rows.count - listRect.height))
                let thumbY = listRect.y + Int((Double(listRect.height - 1) * fraction).rounded())
                c.vline(area.maxX, from: listRect.y, to: listRect.maxY, char: "│", style: t.borderStyle)
                c.text("┃", x: area.maxX, y: thumbY, style: Style(fg: t.accent))
            }
        }

        if let footer = m.footer {
            c.text(footer, x: area.x + 2, y: footerY, maxWidth: area.width - 2, style: t.dimmed)
        }
    }

    static func drawEmpty(_ c: inout Canvas, _ text: String, x: Int, y: Int, width: Int, loading: Bool, theme t: Theme) {
        guard !loading else { return }
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            c.text(String(line), x: x, y: y + i, maxWidth: width, style: i == 0 ? Style(fg: t.text) : t.secondary)
        }
    }

    static func drawTabs(_ c: inout Canvas, _ m: ScreenModel, y: Int, maxX: Int, minX: Int, theme t: Theme) {
        guard !m.tabs.isEmpty else { return }
        let total = m.tabs.reduce(0) { $0 + textWidth($1) + 3 }
        var x = maxX - total
        guard x >= minX else {
            // Too narrow for all of them: show the active one.
            let label = m.tabs[m.activeTab]
            c.text(label, x: maxX - textWidth(label), y: y, style: Style(fg: t.accent, bold: true))
            return
        }
        for (i, tab) in m.tabs.enumerated() {
            let active = i == m.activeTab
            x += c.text(" \(tab) ", x: x, y: y, style: active ? Style(fg: t.background, bg: t.accent, bold: true) : t.secondary) + 1
        }
    }

    // MARK: Home rows

    static let homeTileWidth = 14
    static let homeArtHeight = 7
    static let homeSectionHeight = homeArtHeight + 4  // title + art + 2 text lines + gap

    static func homeVisibleSections(height: Int) -> Int { max(1, height / homeSectionHeight) }

    /// Rows of artwork need room. Small terminals and filtered lists get the plain list.
    static func homeGridApplies(_ s: AppState, width: Int, height: Int) -> Bool {
        s.route == .home && width >= homeTileWidth + 6 && height >= homeSectionHeight + 4 && (s.filters[.home] ?? "").isEmpty
    }

    static func drawHome(_ c: inout Canvas, _ r: Rect, _ s: AppState, _ m: ScreenModel, selectedIndex: Int, focused: Bool) {
        let t = s.theme
        let sections = AppStore.sections(in: m.rows)
        let top = s.scroll[.home] ?? 0
        let tiles = max(1, (r.width - 2) / (homeTileWidth + 2))
        for (position, range) in sections.enumerated().dropFirst(top).prefix(homeVisibleSections(height: r.height)) {
            let y = r.y + (position - top) * homeSectionHeight
            if range.lowerBound > 0, case .header(let title) = m.rows[range.lowerBound - 1].kind {
                c.text(title, x: r.x + 2, y: y, style: Style(fg: t.accentBlue, bold: true))
            }
            // Slide the row along so the selection stays visible.
            let first = range.contains(selectedIndex) ? max(0, selectedIndex - range.lowerBound - tiles + 1) : 0
            for (slot, index) in range.dropFirst(first).prefix(tiles).enumerated() {
                let x = r.x + 2 + slot * (homeTileWidth + 2)
                let tileY = y + 1
                if index == selectedIndex {
                    c.paint(Rect(x: x - 1, y: tileY, width: homeTileWidth + 2, height: homeArtHeight + 2), style: t.selection(focused: focused))
                }
                let (title, subtitle, path): (String, String, String?)
                switch m.rows[index].kind {
                case .album(let a): (title, subtitle, path) = (a.title, a.artist, a.artwork?.path)
                case .playlist(let p): (title, subtitle, path) = (p.name, p.curator ?? "", p.artwork?.path)
                default: continue
                }
                Artwork.draw(&c, Rect(x: x, y: tileY, width: homeTileWidth, height: homeArtHeight), path: path, seed: title, theme: t, art: s.art)
                c.text(title, x: x, y: tileY + homeArtHeight, maxWidth: homeTileWidth, style: Style(fg: t.text, bold: index == selectedIndex))
                c.text(subtitle, x: x, y: tileY + homeArtHeight + 1, maxWidth: homeTileWidth, style: t.secondary)
            }
            if range.count > tiles {
                let current = range.contains(selectedIndex) ? selectedIndex - range.lowerBound + 1 : 1
                let more = "\(current)/\(range.count)"
                c.text(more, x: r.maxX - textWidth(more) - 1, y: y, style: t.dimmed)
            }
        }
    }

    // MARK: Album grid

    static let gridTileWidth = 16
    static let gridArtHeight = 8
    static let gridTileHeight = gridArtHeight + 3  // art + title + artist + gap

    static func gridApplies(_ s: AppState, width: Int) -> Bool {
        s.route == .albums && s.albumGrid && width >= gridTileWidth + 6
    }

    /// Tiles per row for the current frame, or 0 when the grid isn't shown.
    public static func gridColumns(for s: AppState, layout: ShellLayout) -> Int {
        let width = layout.content.width - 4
        if s.route == .home {
            guard homeGridApplies(s, width: width, height: layout.content.height) else { return 0 }
            return max(1, (width - 2) / (homeTileWidth + 2))
        }
        guard gridApplies(s, width: width) else { return 0 }
        return max(1, (width - 2) / (gridTileWidth + 2))
    }

    static func drawGrid(_ c: inout Canvas, _ r: Rect, _ s: AppState, _ m: ScreenModel, selectedIndex: Int, focused: Bool) {
        let t = s.theme
        let columns = max(1, (r.width - 2) / (gridTileWidth + 2))
        // Matches AppStore.adjustScroll (listHeight = this height - 1).
        let visibleRows = max(1, (r.height - 1) / gridTileHeight)
        let topRow = s.scroll[.albums] ?? 0
        if m.rows.isEmpty {
            if !s.loading.contains(.albums) { c.text(m.empty, x: r.x + 2, y: r.y + 1, style: t.secondary) }
            return
        }
        for (index, row) in m.rows.enumerated() {
            let gridRow = index / columns
            guard gridRow >= topRow, gridRow < topRow + visibleRows, case .album(let album) = row.kind else { continue }
            let x = r.x + 2 + (index % columns) * (gridTileWidth + 2)
            let y = r.y + (gridRow - topRow) * gridTileHeight
            let selected = index == selectedIndex
            if selected {
                let frame = Rect(x: x - 1, y: y, width: gridTileWidth + 2, height: gridTileHeight - 1)
                c.paint(frame, style: t.selection(focused: focused))
            }
            Artwork.draw(&c, Rect(x: x, y: y, width: gridTileWidth, height: gridArtHeight),
                         path: album.artwork?.path, seed: album.title, theme: t, art: s.art)
            let playing = s.playback.track?.albumID == album.id
            c.text((playing ? "▶ " : "") + album.title, x: x, y: y + gridArtHeight, maxWidth: gridTileWidth,
                   style: Style(fg: playing ? t.accentPink : t.text, bold: selected))
            c.text(album.artist, x: x, y: y + gridArtHeight + 1, maxWidth: gridTileWidth, style: t.secondary)
        }
        // Scroll position
        let totalRows = (m.rows.count + columns - 1) / columns
        if totalRows > visibleRows {
            c.text("\(topRow + 1)–\(min(totalRows, topRow + visibleRows)) of \(totalRows) rows",
                   x: r.maxX - 22, y: r.maxY, maxWidth: 22, style: t.dimmed)
        }
    }

    static func drawRow(_ c: inout Canvas, _ row: Row, x: Int, y: Int, width: Int, columns: [Column], cellIndices: [Int], widths: [Int],
                        selected: Bool, focused: Bool, playing: Bool, theme t: Theme) {
        if case .header(let title) = row.kind {
            c.text(title, x: x + 2, y: y, style: Style(fg: t.accentBlue, bold: true))
            return
        }
        if selected {
            c.paint(Rect(x: x, y: y, width: width, height: 1), style: t.selection(focused: focused))
            if focused { c.text("▌", x: x, y: y, style: Style(fg: t.accent)) }
        }
        if playing { c.text("▶", x: x + 1, y: y, style: Style(fg: t.accentPink)) }
        var cx = x + 2
        for (i, (col, w)) in zip(columns, widths).enumerated() {
            let cell = cellIndices[i]
            let value = cell < row.cells.count ? row.cells[cell] : ""
            let primary = cell == 1 || columns.count == 1 || (cell == 0 && col.flex > 0)
            let style: Style = if playing { Style(fg: primary || cell == 0 ? t.accentPink : t.textSecondary) }
                else if primary { Style(fg: t.text) }
                else { t.secondary }
            c.text(pad(value, to: w, alignRight: col.alignRight), x: cx, y: y, maxWidth: w, style: style)
            cx += w + 1
        }
    }

    static func columnWidths(_ columns: [Column], total: Int) -> [Int] {
        let gaps = max(0, columns.count - 1)
        let fixed = columns.reduce(0) { $0 + $1.width }
        let flexTotal = columns.reduce(0) { $0 + $1.flex }
        let free = max(0, total - fixed - gaps)
        var widths = columns.map { $0.flex > 0 ? free * $0.flex / max(1, flexTotal) : $0.width }
        // Give rounding leftovers to the first flex column.
        if let first = columns.firstIndex(where: { $0.flex > 0 }) {
            widths[first] += max(0, total - gaps - widths.reduce(0, +))
        }
        return widths
    }

    // MARK: Right panel

    static func drawRightPanel(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        let t = s.theme
        c.fill(r, style: Style(bg: t.surface))
        c.vline(r.x, from: r.y, to: r.maxY, style: t.borderStyle)
        let area = r.inset(dx: 2, dy: 1)
        guard let track = s.playback.track else {
            c.text("Nothing playing", x: area.x + 1, y: area.y + 1, style: t.dimmed)
            return
        }
        let artSize = min(area.width - 2, 16)
        let art = Rect(x: area.x + 1, y: area.y, width: artSize, height: artSize / 2)
        Artwork.draw(&c, art, path: track.artwork?.path, seed: track.album, theme: t, art: s.art)
        var y = art.maxY + 1
        c.text(track.title, x: area.x + 1, y: y, maxWidth: area.width - 1, style: Style(fg: t.text, bold: true)); y += 1
        c.text(track.artist, x: area.x + 1, y: y, maxWidth: area.width - 1, style: Style(fg: t.accent)); y += 1
        c.text(track.album, x: area.x + 1, y: y, maxWidth: area.width - 1, style: t.secondary); y += 1
        y += 1
        if s.prefs.showVisualizer {
            y += Visualizer.draw(&c, Rect(x: area.x + 1, y: y, width: area.width - 1, height: 1), s, compact: true)
        }
        y += 1

        // Upcoming from the current container / queue.
        let entries = s.queue.entries
        guard let current = s.queue.currentIndex else { return }
        let start = max(0, current - 1)
        for (i, e) in entries.enumerated().dropFirst(start) {
            guard y < area.maxY else { break }
            let isCurrent = i == current
            let line = Rect(x: area.x, y: y, width: area.width, height: 1)
            if isCurrent { c.paint(line, style: Style(bg: t.elevated)) }
            c.text(pad(String(i + 1), to: 3, alignRight: true), x: area.x, y: y, style: t.dimmed)
            c.text(isCurrent ? "▶" : " ", x: area.x + 4, y: y, style: Style(fg: t.accentPink))
            c.text(e.track.title, x: area.x + 6, y: y, maxWidth: area.width - 13,
                   style: isCurrent ? Style(fg: t.accentPink) : (i < current ? t.dimmed : Style(fg: t.text)))
            c.text(pad(formatTime(e.track.duration), to: 6, alignRight: true), x: area.maxX - 6, y: y, style: t.dimmed)
            y += 1
        }
    }

    // MARK: Player bar

    static func drawPlayer(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        let t = s.decorativeTheme
        guard r.height > 0 else { return }
        c.hline(r.y, from: r.x, to: r.maxX, style: t.borderStyle)
        let body = Rect(x: r.x, y: r.y + 1, width: r.width, height: r.height - 1)
        guard body.height > 0 else { return }
        c.fill(body, style: Style(bg: t.surface))
        let p = s.playback
        guard let track = p.track else {
            c.text("♪  Nothing playing — press / to find music", x: body.x + 2, y: body.y + body.height / 2,
                   maxWidth: body.width - 4, style: t.dimmed)
            return
        }
        let position = p.position(at: s.now)
        let times = s.prefs.showDuration ? "\(formatTime(position)) / \(formatTime(track.duration))" : formatTime(position)
        let flags = (p.shuffle ? "⤨ " : "  ") + (p.repeat == .one ? "↻¹" : p.repeat == .all ? "↻ " : "  ")

        if body.height >= 3 {
            let art = Rect(x: body.x + 2, y: body.y, width: 6, height: 3)
            Artwork.draw(&c, art, path: track.artwork?.path, seed: track.album, theme: t, art: s.art)
            let tx = art.maxX + 2
            let infoWidth = max(10, min(36, body.width / 3))
            c.text(track.title, x: tx, y: body.y, maxWidth: infoWidth, style: Style(fg: t.text, bold: true))
            c.text("\(track.artist) — \(track.album)", x: tx, y: body.y + 1, maxWidth: infoWidth, style: t.secondary)
            c.text(p.isPlaying ? "▶ playing" : "⏸ paused", x: tx, y: body.y + 2, style: Style(fg: p.isPlaying ? t.success : t.warning))

            let barX = tx + infoWidth + 2
            let rightW = textWidth(times) + 6
            let barW = body.maxX - barX - rightW - 2
            if barW >= 10 {
                if s.prefs.showProgress {
                    drawProgress(&c, x: barX, y: body.y + 1, width: barW, fraction: position / max(1, track.duration), theme: t)
                }
                c.text(times, x: barX + barW + 2, y: body.y + 1, style: t.secondary)
                c.text(flags, x: barX + barW + 2 + textWidth(times) + 1, y: body.y + 1, style: Style(fg: t.accent))
                c.text("◀◀    \(p.isPlaying ? "Ⅱ" : "▶")    ▶▶", x: barX + barW / 2 - 7, y: body.y + 2, style: t.secondary)
            } else {
                c.text(times, x: body.maxX - textWidth(times) - 2, y: body.y + 1, style: t.secondary)
            }
        } else {
            let icon = p.isPlaying ? "▶" : "⏸"
            let x = body.x + 1
            let label = "\(icon) \(track.title) — \(track.artist)"
            let labelW = min(textWidth(label), body.width / 2)
            c.text(label, x: x, y: body.y, maxWidth: labelW, style: Style(fg: t.text))
            let barX = x + labelW + 2
            let barW = body.maxX - barX - textWidth(times) - 3
            if barW >= 6, s.prefs.showProgress {
                drawProgress(&c, x: barX, y: body.y, width: barW, fraction: position / max(1, track.duration), theme: t)
            }
            c.text(times, x: body.maxX - textWidth(times) - 1, y: body.y, style: t.secondary)
        }
    }

    static func drawProgress(_ c: inout Canvas, x: Int, y: Int, width: Int, fraction: Double, theme t: Theme) {
        let f = min(max(fraction, 0), 1)
        let filled = Int((Double(width - 1) * f).rounded())
        c.hline(y, from: x, to: x + filled, char: "━", style: Style(fg: t.accentPink))
        c.hline(y, from: x + filled + 1, to: x + width, char: "━", style: Style(fg: t.border))
        c.text("●", x: x + filled, y: y, style: Style(fg: t.text))
    }

    // MARK: Status bar

    static func drawStatus(_ c: inout Canvas, _ r: Rect, _ s: AppState, _ m: ScreenModel) {
        let t = s.theme
        c.fill(r, style: Style(bg: t.surface))
        let modeLabel: String, modeColor: TermColor
        switch s.mode {
        case .normal: (modeLabel, modeColor) = ("NORMAL", t.accent)
        case .search: (modeLabel, modeColor) = ("SEARCH", t.accentBlue)
        case .filter: (modeLabel, modeColor) = ("FILTER", t.warning)
        case .command: (modeLabel, modeColor) = ("COMMAND", t.accentPink)
        }
        var x = r.x
        x += c.text(" \(modeLabel) ", x: x, y: r.y, style: Style(fg: t.background, bg: modeColor, bold: true))
        x += 1

        switch s.mode {
        case .search, .filter, .command:
            let prefix: String = switch s.mode {
            case .search: "/ "
            case .filter: "filter: "
            default: ":"
            }
            if s.mode == .search {
                let scope = s.searchScope == .catalog ? " Apple Music " : " Library "
                x += c.text(scope, x: x, y: r.y, style: Style(fg: t.text, bg: t.elevated))
                x += 1
            }
            x += c.text(prefix + s.input, x: x, y: r.y, maxWidth: r.maxX - x - 1, style: Style(fg: t.text))
            c.text("█", x: x, y: r.y, style: Style(fg: t.accent))
            let hint = s.mode == .search ? "Enter results  Ctrl+S scope  Esc cancel" : s.mode == .command ? "Tab complete  ↑↓ history  Enter run  Esc cancel" : "Enter keep  Esc clear"
            let hx = r.maxX - textWidth(hint) - 1
            if hx > x + 4 { c.text(hint, x: hx, y: r.y, style: t.dimmed) }
            return
        case .normal:
            break
        }

        x += c.text(s.route.title.uppercased(), x: x, y: r.y, style: t.secondary)
        x += 2
        if let toast = s.toast {
            c.text(toast.message, x: x, y: r.y, maxWidth: r.maxX - x - 1,
                   style: Style(fg: toast.isError ? t.error : t.success))
        } else {
            let hints = m.hints + "   : command   ? help"
            let hx = max(x, r.maxX - textWidth(hints) - 1)
            c.text(hints, x: hx, y: r.y, maxWidth: r.maxX - hx - 1, style: t.dimmed)
        }
        if !s.pendingKeys.isEmpty {
            let px = r.maxX - textWidth(s.pendingKeys) - 2
            c.text(" \(s.pendingKeys) ", x: px - 1, y: r.y, style: Style(fg: t.background, bg: t.warning, bold: true))
        }
    }

    // MARK: Overlays

    static func drawOverlay(_ c: inout Canvas, _ overlay: Overlay, _ s: AppState) {
        let t = s.theme
        switch overlay {
        case .confirm(let message, _):
            let w = min(c.width - 4, max(40, textWidth(message) + 8))
            let box = Rect(x: (c.width - w) / 2, y: c.height / 2 - 3, width: w, height: 6)
            drawBox(&c, box, title: "Confirm", theme: t)
            c.text(message, x: box.x + 3, y: box.y + 2, maxWidth: box.width - 6, style: Style(fg: t.text))
            c.text("y  yes      any other key  cancel", x: box.x + 3, y: box.y + 4, maxWidth: box.width - 6, style: t.secondary)
        case .picker(let picker):
            let w = min(c.width - 4, max(30, (picker.options.map(textWidth).max() ?? 0) + 10))
            let visible = min(picker.options.count, max(1, c.height - 7))
            let h = visible + 4
            let box = Rect(x: (c.width - w) / 2, y: max(0, (c.height - h) / 2), width: w, height: h)
            drawBox(&c, box, title: picker.title, theme: t)
            let first = min(max(0, picker.index - visible / 2), picker.options.count - visible)
            for (i, option) in picker.options.enumerated().dropFirst(first).prefix(visible) {
                let y = box.y + 1 + i - first
                let selected = i == picker.index
                if selected { c.paint(Rect(x: box.x + 1, y: y, width: box.width - 2, height: 1), style: Style(bg: t.surface)) }
                c.text((selected ? "▌ " : "  ") + option, x: box.x + 2, y: y, maxWidth: box.width - 4,
                       style: selected ? Style(fg: t.accent, bold: true) : Style(fg: t.text))
            }
            c.text("j/k move  Enter choose  Esc cancel", x: box.x + 3, y: box.maxY - 2, maxWidth: box.width - 6, style: t.dimmed)
        case .help:
            let lines = HelpContent.lines(s.keymap)
            let w = min(c.width - 4, 76)
            let h = min(c.height - 2, lines.count + 4)
            let box = Rect(x: (c.width - w) / 2, y: (c.height - h) / 2, width: w, height: h)
            drawBox(&c, box, title: "Keyboard", theme: t)
            for (i, line) in lines.dropFirst(s.helpScroll).prefix(h - 4).enumerated() {
                let y = box.y + 2 + i
                if line.keys.isEmpty {
                    c.text(line.action, x: box.x + 3, y: y, style: Style(fg: t.accentBlue, bold: true))
                } else {
                    c.text(pad(line.keys, to: 18), x: box.x + 3, y: y, style: Style(fg: t.accent))
                    c.text(line.action, x: box.x + 22, y: y, maxWidth: box.width - 25, style: Style(fg: t.text))
                }
            }
            let more = lines.count + 4 > h
            let hint = more ? "j/k scroll · any key closes" : "any key to close"
            c.text(hint, x: box.maxX - textWidth(hint) - 3, y: box.maxY - 1, style: t.dimmed)
        }
    }

    static func drawBox(_ c: inout Canvas, _ r: Rect, title: String, theme t: Theme) {
        c.fill(r, style: Style(fg: t.text, bg: t.elevated))
        c.hline(r.y, from: r.x + 1, to: r.maxX - 1, style: Style(fg: t.accent))
        c.hline(r.maxY - 1, from: r.x + 1, to: r.maxX - 1, style: Style(fg: t.accent))
        c.vline(r.x, from: r.y + 1, to: r.maxY - 1, style: Style(fg: t.accent))
        c.vline(r.maxX - 1, from: r.y + 1, to: r.maxY - 1, style: Style(fg: t.accent))
        c.text("╭", x: r.x, y: r.y, style: Style(fg: t.accent))
        c.text("╮", x: r.maxX - 1, y: r.y, style: Style(fg: t.accent))
        c.text("╰", x: r.x, y: r.maxY - 1, style: Style(fg: t.accent))
        c.text("╯", x: r.maxX - 1, y: r.maxY - 1, style: Style(fg: t.accent))
        c.text(" \(title) ", x: r.x + 2, y: r.y, style: Style(fg: t.accent, bold: true))
    }
}

extension Row {
    /// For queue rows, only the current entry is "playing" (the same song
    /// can appear twice). Nil for non-queue rows.
    func isQueueCurrent(_ q: QueueState) -> Bool? {
        if case .queueEntry(_, let i) = kind { return i == q.currentIndex }
        return nil
    }
}

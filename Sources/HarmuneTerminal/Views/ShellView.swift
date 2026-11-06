import Foundation
import HarmuneCore

/// Regions computed for a terminal size. Shared by the renderer and the
/// run loop (which needs `listHeight` for paging).
public struct ShellLayout: Equatable, Sendable {
    public var header: Rect
    public var content: Rect
    public var player: Rect
    public var status: Rect

    public init(columns: Int, rows: Int) {
        var area = Rect(x: 0, y: 0, width: columns, height: rows)
        (area, status) = area.splitBottom(1)
        (area, player) = area.splitBottom(2)
        (header, content) = area.splitTop(1)
    }

    public func listHeight(hasHeader: Bool) -> Int {
        max(0, content.height - 4 - (hasHeader ? 1 : 0))
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

        if s.route == .nowPlaying && s.focus == .content {
            // Immersive: nothing on screen but the music.
            NowPlayingView.drawImmersive(&c, Rect(x: 0, y: 0, width: columns, height: rows - 1), s)
        } else {
            drawHeader(&c, layout.header, s)
            if s.focus == .views {
                drawViews(&c, layout.content, s)
            } else {
                drawContent(&c, layout, s, model, selectedIndex: selectedIndex)
            }
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

    static func drawHeader(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        let t = s.theme
        c.text("$", x: r.x + 2, y: r.y, style: t.accentStyle)
        c.text("harmune", x: r.x + 4, y: r.y, style: Style(fg: t.text, bold: true))

        let notice: (String, Style)? = switch s.connection {
        case .connected: nil
        case .reconnecting:
            (s.reconnectSeconds.map { "retry in \($0)s" } ?? "reconnecting…", Style(fg: t.warning))
        case .offline: ("host offline", Style(fg: t.error))
        }
        let available = r.width - 14
        let compact = r.width < 38
        let actions: [(KeyCommand, String)] = [(.focusNext, "views"), (.search, "search"),
                                                (.queue, "queue"), (.playPause, "play/pause")]
        var line = ""
        for (command, label) in actions {
            guard let key = s.keymap.shortcut(for: command) else { continue }
            let action = compact ? key : "\(key) \(label)"
            let next = line.isEmpty ? action : line + (compact ? " " : "   ") + action
            guard textWidth(next) <= available else { break }
            line = next
        }
        let (label, style) = notice ?? (line, t.secondary)
        let width = min(available, textWidth(label))
        c.text(label, x: r.maxX - width - 2, y: r.y, maxWidth: width, style: style)
    }

    static func drawViews(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        let t = s.theme
        let routes = Route.destinations(s.capabilities)
        c.text("Open a view", x: r.x + 2, y: r.y + 1, maxWidth: r.width - 4, style: t.accentStyle)
        let visible = max(0, r.height - 2)
        let first = max(0, s.viewIndex - visible + 1)
        for (offset, route) in routes.dropFirst(first).prefix(visible).enumerated() {
            let selected = first + offset == s.viewIndex
            let y = r.y + 2 + offset
            if selected {
                c.paint(Rect(x: r.x + 2, y: y, width: r.width - 4, height: 1), style: t.selection(focused: true))
            }
            c.text((selected ? "> " : "  ") + route.title, x: r.x + 2, y: y, maxWidth: r.width - 4,
                   style: selected ? t.accentStyle : t.secondary)
        }
    }

    // MARK: Content

    static func drawContent(_ c: inout Canvas, _ layout: ShellLayout, _ s: AppState, _ m: ScreenModel, selectedIndex: Int) {
        let t = s.theme
        let r = layout.content
        let area = r.inset(dx: 2, dy: 0)
        var y = r.y + 1
        guard y < r.maxY else { return }

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
        y += 1

        if let gate = authGate(route: s.route, status: s.auth) {
            drawEmpty(&c, ([gate.title, ""] + gate.lines).joined(separator: "\n"),
                      in: Rect(x: area.x, y: y, width: area.width, height: r.maxY - y),
                      loading: false, theme: t)
            return
        }

        if let h = m.header, y < r.maxY {
            let metadata = [h.subtitle, h.meta].filter { !$0.isEmpty }.joined(separator: " · ")
            c.text(metadata, x: area.x, y: y, maxWidth: area.width, style: t.secondary)
            y += 1
        }

        if gridColumns(for: s, layout: layout) > 0 {
            drawGrid(&c, Rect(x: area.x, y: y, width: area.width, height: r.maxY - 1 - y), s, m,
                     selectedIndex: selectedIndex)
            if let footer = m.footer {
                c.text(footer, x: area.x + 2, y: r.maxY - 1, maxWidth: area.width - 2, style: t.secondary)
            }
            return
        }

        // Columns
        let cellIndices = m.columns.indices.filter { area.width >= m.columns[$0].minContentWidth }
        let columns = cellIndices.map { m.columns[$0] }
        let widths = columnWidths(columns, total: area.width - 2)
        if y < r.maxY, !columns.allSatisfy({ $0.title.isEmpty }) {
            var cx = area.x + 2
            for (col, w) in zip(columns, widths) {
                c.text(pad(col.title, to: w, alignRight: col.alignRight), x: cx, y: y, style: t.dimmed)
                cx += w + 1
            }
        }
        y += 1

        let footerY = r.maxY - 1
        let listRect = Rect(x: area.x, y: y, width: area.width, height: footerY - y)

        if m.rows.isEmpty {
            drawEmpty(&c, m.empty, in: listRect, loading: s.loading.contains(s.route), theme: t)
        } else {
            let top = s.scroll[s.route] ?? 0
            let playingID = s.playback.track?.id
            for (offset, row) in m.rows.dropFirst(top).prefix(listRect.height).enumerated() {
                let ry = listRect.y + offset
                let index = top + offset
                drawRow(&c, row, x: area.x, y: ry, width: area.width, columns: columns, cellIndices: cellIndices, widths: widths,
                        selected: index == selectedIndex,
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

        if let footer = m.footer, footerY >= y {
            c.text(footer, x: area.x + 2, y: footerY, maxWidth: area.width - 2, style: t.secondary)
        }
    }

    static func drawEmpty(_ c: inout Canvas, _ text: String, in r: Rect, loading: Bool, theme t: Theme) {
        guard !loading else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.prefix(r.height).enumerated() {
            c.text(String(line), x: r.x, y: r.y + i, maxWidth: r.width, style: i == 0 ? Style(fg: t.text) : t.secondary)
        }
    }

    static func drawTabs(_ c: inout Canvas, _ m: ScreenModel, y: Int, maxX: Int, minX: Int, theme t: Theme) {
        guard !m.tabs.isEmpty else { return }
        let total = m.tabs.reduce(0) { $0 + textWidth($1) + 3 }
        var x = maxX - total
        guard x >= minX else {
            // Too narrow for all of them: show the active one.
            let label = m.tabs[m.activeTab]
            if maxX - textWidth(label) >= minX {
                c.text(label, x: maxX - textWidth(label), y: y, style: t.accentStyle)
            }
            return
        }
        for (i, tab) in m.tabs.enumerated() {
            let active = i == m.activeTab
            x += c.text(" \(tab) ", x: x, y: y, style: active ? Style(fg: t.background, bg: t.accent, bold: true) : t.secondary) + 1
        }
    }

    // MARK: Optional album grid

    static let gridTileWidth = 16
    static let gridArtHeight = 8
    static let gridTileHeight = gridArtHeight + 3  // art + title + artist + gap

    /// Tiles per row for the current frame, or 0 when the grid isn't shown.
    public static func gridColumns(for s: AppState, layout: ShellLayout) -> Int {
        let width = layout.content.width - 4
        guard s.route == .albums, s.albumGrid, width >= gridTileWidth + 6,
              layout.listHeight(hasHeader: false) >= gridTileHeight else { return 0 }
        return max(1, (width - 2) / (gridTileWidth + 2))
    }

    static func drawGrid(_ c: inout Canvas, _ r: Rect, _ s: AppState, _ m: ScreenModel, selectedIndex: Int) {
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
                c.paint(frame, style: t.selection(focused: true))
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
                        selected: Bool, playing: Bool, theme t: Theme) {
        if case .header(let title) = row.kind {
            c.text(title, x: x + 2, y: y, style: Style(fg: t.accentBlue, bold: true))
            return
        }
        if selected {
            c.paint(Rect(x: x, y: y, width: width, height: 1), style: t.selection(focused: true))
            c.text(">", x: x, y: y, style: t.accentStyle)
        }
        if playing { c.text("▶", x: x + 1, y: y, style: Style(fg: t.accent)) }
        var cx = x + 2
        for (i, (col, w)) in zip(columns, widths).enumerated() {
            let cell = cellIndices[i]
            let value = cell < row.cells.count ? row.cells[cell] : ""
            let primary = cell == 1 || columns.count == 1 || (cell == 0 && col.flex > 0)
            let style: Style = if playing { Style(fg: primary || cell == 0 ? t.accent : t.textSecondary) }
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

    // MARK: Player

    static func drawPlayer(_ c: inout Canvas, _ r: Rect, _ s: AppState) {
        guard r.height >= 2 else { return }
        let t = s.decorativeTheme
        c.hline(r.y, from: r.x + 2, to: r.maxX - 2, style: t.borderStyle)
        let y = r.y + 1
        let x = r.x + 2
        let right = r.maxX - 2
        let p = s.playback
        guard let track = p.track else {
            c.text("■ Idle · / search", x: x, y: y, maxWidth: right - x, style: t.secondary)
            return
        }

        let position = p.position(at: s.now)
        let elapsed = formatTime(position)
        let times = s.prefs.showDuration ? "\(elapsed) / \(formatTime(track.duration))" : elapsed
        let timeX = right - textWidth(times)
        let barWidth = s.prefs.showProgress && r.width >= 56 ? min(24, r.width / 5) : 0
        let barX = timeX - barWidth - 2
        let trackEnd = barWidth > 0 ? barX - 2 : timeX - 2
        let marker = p.isPlaying ? "▶" : "Ⅱ"
        let status = r.width >= 46 ? (p.isPlaying ? "\(marker) Playing  " : "\(marker) Paused  ") : marker + " "
        let labelX = x + c.text(status, x: x, y: y, maxWidth: max(0, trackEnd - x), style: t.accentStyle)
        if labelX < trackEnd {
            let titleWidth = c.text(track.title, x: labelX, y: y, maxWidth: trackEnd - labelX, style: Style(fg: t.text, bold: true))
            let artistX = labelX + titleWidth
            if trackEnd - artistX >= 6 {
                c.text(" · " + track.artist, x: artistX, y: y, maxWidth: trackEnd - artistX, style: t.secondary)
            }
        }
        if barWidth > 0 {
            drawProgress(&c, x: barX, y: y, width: barWidth, fraction: position / max(1, track.duration), theme: t)
        }
        c.text(times, x: max(x, timeX), y: y, maxWidth: right - x, style: t.secondary)
    }

    static func drawProgress(_ c: inout Canvas, x: Int, y: Int, width: Int, fraction: Double, theme t: Theme) {
        let f = min(max(fraction, 0), 1)
        let filled = Int((Double(width - 1) * f).rounded())
        c.hline(y, from: x, to: x + filled, char: "━", style: Style(fg: t.accent))
        c.hline(y, from: x + filled + 1, to: x + width, char: "━", style: t.dimmed)
        c.text("●", x: x + filled, y: y, style: Style(fg: t.text))
    }

    // MARK: Status bar

    static func drawStatus(_ c: inout Canvas, _ r: Rect, _ s: AppState, _ m: ScreenModel) {
        let t = s.theme
        c.fill(r, style: Style(bg: t.surface))
        var x = r.x + 2

        switch s.mode {
        case .search, .filter, .command:
            let prefix: String = switch s.mode {
            case .search: "/ "
            case .filter: "filter: "
            default: ":"
            }
            let modeLabel = switch s.mode {
            case .search: "SEARCH"
            case .filter: "FILTER"
            default: "COMMAND"
            }
            x += c.text(modeLabel, x: x, y: r.y, style: t.accentStyle) + 2
            if s.mode == .search, r.width >= 32 {
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

        let help = s.keymap.shortcut(for: .help).map { $0 + " keys" } ?? ""
        let helpWidth = min(r.width / 2, textWidth(help))
        let helpX = r.maxX - helpWidth - 2
        c.text(help, x: helpX, y: r.y, maxWidth: helpWidth, style: t.accentStyle)
        let pendingWidth = min(r.width / 4, textWidth(s.pendingKeys))
        let pendingX = helpX - pendingWidth - 2
        c.text(s.pendingKeys, x: pendingX, y: r.y, maxWidth: pendingWidth, style: Style(fg: t.warning))
        let available = pendingX - x - 1

        if let toast = s.toast {
            c.text(toast.message, x: x, y: r.y, maxWidth: available, style: Style(fg: toast.isError ? t.error : t.success))
        } else if s.focus == .views {
            c.text("↑↓ move   Enter open   Esc close", x: x, y: r.y, maxWidth: available, style: t.secondary)
        } else {
            if let key = s.keymap.shortcut(for: .commandMode) {
                let prompt = r.width >= 32 ? key + " command" : key
                x += c.text(prompt, x: x, y: r.y, maxWidth: available, style: t.accentStyle) + 3
            }
            let actions = m.hints.components(separatedBy: "   ")
            for action in actions {
                guard x + textWidth(action) <= pendingX - 1 else { break }
                x += c.text(action, x: x, y: r.y, style: t.secondary) + 3
            }
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
            let keyWidth = min(18, max(5, w / 3))
            let box = Rect(x: (c.width - w) / 2, y: (c.height - h) / 2, width: w, height: h)
            drawBox(&c, box, title: "Keyboard", theme: t)
            for (i, line) in lines.dropFirst(s.helpScroll).prefix(h - 4).enumerated() {
                let y = box.y + 2 + i
                if line.keys.isEmpty {
                    c.text(line.action, x: box.x + 3, y: y, style: Style(fg: t.accentBlue, bold: true))
                } else {
                    c.text(pad(line.keys, to: keyWidth), x: box.x + 2, y: y, style: t.accentStyle)
                    c.text(line.action, x: box.x + keyWidth + 3, y: y, maxWidth: box.width - keyWidth - 5, style: t.secondary)
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

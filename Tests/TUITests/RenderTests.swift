import Foundation
import Testing
@testable import HarmuneCore
@testable import HarmuneDemo
@testable import HarmuneTerminal

@Suite struct CanvasTests {
    @Test func textClipsAndTruncates() {
        var c = Canvas(width: 10, height: 1)
        c.text("Hello, world", x: 0, y: 0)
        #expect(c.plainText == "Hello, wo…")
        c.text("xyz", x: 8, y: 0)
        #expect(c.plainText == "Hello, wx…")
    }

    @Test func wideCharactersTakeTwoCells() {
        var c = Canvas(width: 6, height: 1)
        #expect(c.text("日本", x: 0, y: 0) == 4)
        #expect(c[1, 0].continuation)
        #expect(c.plainText == "日本  ")
    }

    @Test func stylesInheritBackground() {
        var c = Canvas(width: 4, height: 1)
        c.fill(c.bounds, style: Style(bg: .rgb(1, 2, 3)))
        c.text("a", x: 0, y: 0, style: Style(fg: .rgb(9, 9, 9)))
        #expect(c[0, 0].style.bg == .rgb(1, 2, 3))
        #expect(c[0, 0].style.fg == .rgb(9, 9, 9))
    }

    @Test func rendererDiffsOnlyChangedCells() {
        var r = Renderer(colorMode: .truecolor)
        var c = Canvas(width: 20, height: 3)
        _ = r.frame(c)
        c.text("X", x: 5, y: 1)
        let out = r.frame(c)
        #expect(out.contains("\u{1B}[2;6H"))
        #expect(!out.contains("\u{1B}[2J"))
        #expect(out.filter { $0 == "X" }.count == 1)
        // Unchanged frame writes no cells.
        #expect(!r.frame(c).contains("H"))
    }

    @Test func colorModes() {
        let style = Style(fg: .rgb(198, 165, 255))
        #expect(Renderer(colorMode: .truecolor).sgr(style).contains("38;2;198;165;255"))
        #expect(Renderer(colorMode: .ansi256).sgr(style).contains("38;5;"))
        #expect(!Renderer(colorMode: .none).sgr(style).contains("38"))
        #expect(Renderer.ansi256(0, 0, 0) == 16)
        #expect(Renderer.ansi256(255, 255, 255) == 231)
        #expect(Renderer.ansi256(128, 128, 128) >= 232)
    }

    @Test func colorModeDetection() {
        #expect(ColorMode.detect(["NO_COLOR": "1", "COLORTERM": "truecolor"]) == .none)
        #expect(ColorMode.detect(["COLORTERM": "truecolor"]) == .truecolor)
        #expect(ColorMode.detect(["TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"]) == .ansi256)
    }
}

@Suite struct LayoutTests {
    @Test(arguments: [(50, 20), (80, 24), (100, 30), (140, 40), (200, 50)])
    func breakpoints(_ cols: Int, _ rows: Int) {
        let l = ShellLayout(columns: cols, rows: rows)
        // A prompt and footer frame one content area at every size.
        let regions = [l.header, l.content, l.player, l.status]
        #expect(regions.allSatisfy { $0.width == cols })
        #expect(regions.first?.y == 0)
        for (above, below) in zip(regions, regions.dropFirst()) {
            #expect(above.maxY == below.y)
        }
        #expect(regions.last?.maxY == rows)
    }

    @Test func shortTerminalsKeepThePromptAndPlayer() {
        for rows in [6, 10, 24] {
            let layout = ShellLayout(columns: 80, rows: rows)
            #expect(layout.header.height == 1)
            #expect(layout.player.height == 2)
            #expect(layout.status.height == 1)
        }
    }
}

/// Renders every route at every breakpoint and checks the frame is sane.
@MainActor
@Suite struct SnapshotTests {
    static let sizes = [(50, 20), (80, 24), (100, 30), (140, 40), (200, 50)]

    func frame(_ store: AppStore, _ cols: Int, _ rows: Int) -> Canvas {
        let layout = ShellLayout(columns: cols, rows: rows)
        store.listHeight = layout.listHeight(hasHeader: screen(for: store.state.route, in: store.state).header != nil)
        return ShellView.render(store.state, columns: cols, rows: rows, selectedIndex: store.selectedIndex)
    }

    @Test func everyRouteRendersAtEveryBreakpoint() async {
        let store = await makeStore()
        await press(store, "ga<cr><cr>")  // play an album so the player is populated
        let routes: [String] = ["gh", "gl", "ga", "gA", "gp", "gf", "gq", "v", "ga<cr>"]
        for keys in routes {
            await press(store, "<esc>")
            await press(store, keys)
            for (cols, rows) in Self.sizes {
                let c = frame(store, cols, rows)
                let text = c.plainText
                #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == rows)
                #expect(text.contains("? keys"), "help shortcut missing at \(cols)x\(rows) for \(keys)")
                if store.state.route != .nowPlaying {
                    #expect(text.contains(store.state.route.title) || text.contains("Library"),
                            "breadcrumb missing at \(cols)x\(rows) for \(keys)")
                }
            }
            if store.state.route == .nowPlaying { await press(store, "v") }
        }
    }

    @Test func shellKeepsPlaybackAndHelpInDedicatedLines() async throws {
        let store = await makeStore()
        await press(store, "ga<cr>jj<cr>")
        let title = try #require(store.state.playback.track?.title)
        for (columns, rows) in [(50, 20), (80, 24), (160, 40)] {
            let canvas = frame(store, columns, rows)
            let lines = canvas.plainText.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines[0].contains("$ harmune"))
            #expect(!lines[0].contains(title))
            #expect(lines[rows - 2].contains("▶ Playing"))
            #expect(lines[rows - 1].contains("? keys"))
            #expect(!lines.contains { $0.contains("Open a view") })
            #expect(canvas.artworkRequests.isEmpty)
        }
    }

    @Test func viewSwitcherFitsCompactTerminal() async {
        let store = await makeStore()
        await press(store, "ga<cr><tab>G")
        let menu = frame(store, 50, 10).plainText
        #expect(menu.contains("Open a view"))
        #expect(menu.contains("> Settings"))
        await press(store, "<esc>")
        let detail = frame(store, 50, 10).plainText
        #expect(!detail.contains("Open a view"))
        #expect(detail.contains("Library / Albums /"))
    }

    @Test func overlaysRender() async {
        let store = await makeStore()
        await press(store, "?")
        #expect(frame(store, 100, 40).plainText.contains("Keyboard"))
        await press(store, "j")
        await press(store, "ga<cr><cr>gqD")
        #expect(frame(store, 100, 30).plainText.contains("Confirm"))
    }

    @Test func modeLineShowsInput() async {
        let store = await makeStore()
        await press(store, "/")
        await type(store, "neon")
        let text = frame(store, 100, 30).plainText
        #expect(text.contains("SEARCH"))
        #expect(text.contains("Apple Music"))
        #expect(text.contains("/ neon"))
    }

    @Test func immersiveTitleTransitionRespectsReducedMotion() throws {
        var state = AppState()
        state.stack = [.nowPlaying]
        state.playback.track = Track(id: "next", title: "Next song", artist: "Artist", album: "Album", duration: 180)
        state.trackTransition = (state.now, "Previous album")

        func titleIndent() throws -> Int {
            let text = ShellView.render(state, columns: 80, rows: 24, selectedIndex: 0).plainText
            let line = try #require(text.split(separator: "\n").first { $0.contains("NEXT SONG") })
            return line.prefix { $0 == " " }.count
        }

        let sliding = try titleIndent()
        state.prefs.reducedMotion = true
        let centered = try titleIndent()
        #expect(sliding == centered + 4)

        state.prefs.reducedMotion = false
        state.now = state.now.addingTimeInterval(1)
        #expect(try titleIndent() == centered)
    }

    @Test func tinyTerminalDoesNotCrash() async {
        let store = await makeStore()
        for (c, r) in [(1, 1), (10, 3), (20, 6), (30, 8)] {
            _ = frame(store, c, r)
        }
    }

    /// Writes plain-text frames to .build for eyeballing during development.
    @Test func dumpFrames() async throws {
        let store = await makeStore()
        await press(store, "ga<cr>jj<cr>")
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../.build/tui-frames").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (cols, rows) in [(160, 40), (80, 24)] {
            try frame(store, cols, rows).plainText.write(to: dir.appendingPathComponent("album-\(cols)x\(rows).txt"),
                                                         atomically: true, encoding: .utf8)
        }
        await press(store, "gh")
        try frame(store, 160, 40).plainText.write(to: dir.appendingPathComponent("home-160x40.txt"), atomically: true, encoding: .utf8)
        await press(store, "v")
        try frame(store, 100, 32).plainText.write(to: dir.appendingPathComponent("nowplaying-100x32.txt"), atomically: true, encoding: .utf8)
    }
}

import Foundation
import Testing
@testable import HarmuneDemo
@testable import HarmuneTerminal

@Suite struct GraphicsTests {
    @Test func detection() {
        #expect(GraphicsMode.detect(["TERM": "xterm-kitty"], colorMode: .truecolor) == .kitty)
        #expect(GraphicsMode.detect(["TERM_PROGRAM": "ghostty"], colorMode: .truecolor) == .kitty)
        #expect(GraphicsMode.detect(["TERM_PROGRAM": "Apple_Terminal"], colorMode: .ansi256) == .halfblock)
        #expect(GraphicsMode.detect(["TERM": "xterm-kitty", "TMUX": "/tmp/x"], colorMode: .truecolor) == .halfblock)
        #expect(GraphicsMode.detect(["TERM": "xterm-kitty"], colorMode: .none) == .none)
        #expect(GraphicsMode.detect(["HARMUNE_GRAPHICS": "none", "TERM": "xterm-kitty"], colorMode: .truecolor) == .none)
    }

    @Test func kittyTransmitsOncePlacesAndDeletes() {
        var k = KittyGraphics(transmitByPath: true)
        let a = ImagePlacement(path: "/tmp/a.png", rect: Rect(x: 2, y: 3, width: 16, height: 8))
        let first = k.sync([a], fullRedraw: false)
        #expect(first.contains("a=t,f=100,t=f,i=1"))
        #expect(first.contains(Data("/tmp/a.png".utf8).base64EncodedString()))
        #expect(first.contains("\u{1B}[4;3H"))
        #expect(first.contains("a=p,i=1,p=1,c=16,r=8,C=1"))

        // Unchanged frame: nothing to do.
        #expect(k.sync([a], fullRedraw: false).isEmpty)

        // Moved: delete old placement, place new one, no retransmit.
        let moved = ImagePlacement(path: "/tmp/a.png", rect: Rect(x: 2, y: 5, width: 16, height: 8))
        let out = k.sync([moved], fullRedraw: false)
        #expect(out.contains("a=d,d=i,i=1,p=1"))
        #expect(out.contains("a=p,i=1,p=2"))
        #expect(!out.contains("a=t"))

        // Full redraw clears everything first.
        #expect(k.sync([moved], fullRedraw: true).hasPrefix("\u{1B}_Ga=d,d=a"))
        #expect(k.clearAll().contains("d=A"))
    }

    @Test func kittyInlineDataIsChunked() {
        let payload = String(repeating: "A", count: 10_000)
        let out = KittyGraphics.chunked(["a=t", "i=1"], base64: payload)
        let chunks = out.components(separatedBy: "\u{1B}_G").filter { !$0.isEmpty }
        #expect(chunks.count == 3)
        #expect(chunks[0].hasPrefix("a=t,i=1,m=1;"))
        #expect(chunks[1].hasPrefix("m=1;"))
        #expect(chunks[2].hasPrefix("m=0;"))
    }

    @Test func demoArtworkDecodesToHalfBlocks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-art-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("a.png").path
        DemoArtwork.write(try #require(DemoArtwork.render(key: "album-1")), to: path)

        let grid = try #require(PixelGrid.load(path: path, width: 16, height: 16))
        #expect(grid.rgb.count == 16 * 16 * 3)
        #expect(Set(stride(from: 0, to: grid.rgb.count, by: 3).map { grid.rgb[$0] }).count > 4)  // not flat

        var c = Canvas(width: 20, height: 10)
        HalfBlock.draw(&c, Rect(x: 1, y: 1, width: 16, height: 8), grid)
        #expect(c[1, 1].char == "▀")
        #expect(c[1, 1].style.fg != nil && c[1, 1].style.bg != nil)
        #expect(PixelGrid.load(path: "/nonexistent.png", width: 4, height: 4) == nil)
    }

    @Test func artworkFallsBackAndRequests() {
        var c = Canvas(width: 30, height: 10)
        let theme = Theme.midnight
        let rect = Rect(x: 0, y: 0, width: 8, height: 4)

        Artwork.draw(&c, rect, path: "/x.png", seed: "s", theme: theme, art: ArtworkSnapshot(mode: .halfblock))
        #expect(c.artworkRequests == [ArtworkKey(path: "/x.png", columns: 8, rows: 4)])

        c = Canvas(width: 30, height: 10)
        Artwork.draw(&c, rect, path: "/x.png", seed: "s", theme: theme,
                     art: ArtworkSnapshot(mode: .kitty, available: ["/x.png"]))
        #expect(c.imagePlacements == [ImagePlacement(path: "/x.png", rect: rect)])

        c = Canvas(width: 30, height: 10)
        Artwork.draw(&c, rect, path: nil, seed: "s", theme: theme, art: ArtworkSnapshot(mode: .kitty))
        #expect(c.imagePlacements.isEmpty && c.artworkRequests.isEmpty)
    }
}

@MainActor
@Suite struct GridTests {
    @Test func gridNavigationMovesIn2D() async {
        let store = await makeStore()
        await press(store, "ga")
        store.gridColumns = 4
        store.listHeight = 30
        await press(store, "l")
        #expect(store.selectedIndex == 1)
        await press(store, "j")
        #expect(store.selectedIndex == 5)
        await press(store, "2j")
        #expect(store.selectedIndex == 13)
        await press(store, "h")
        #expect(store.selectedIndex == 12)
        await press(store, "k")
        #expect(store.selectedIndex == 8)
    }

    @Test func gridScrollsByTileRows() async {
        let store = await makeStore()
        await press(store, "ga")
        store.gridColumns = 3
        store.listHeight = ShellView.gridTileHeight * 2  // two visible tile rows
        await press(store, "6j")  // row 6
        #expect(store.state.scroll[.albums] == 5)
    }

    @Test func toggleLayout() async {
        let store = await makeStore()
        await press(store, "ga")
        #expect(store.state.albumGrid)
        await press(store, "t")
        #expect(!store.state.albumGrid)
        await press(store, "gl")
        await press(store, "t")
        #expect(store.state.toast?.isError == true)
    }

    @Test func gridRendersTiles() async {
        let store = await makeStore()
        await press(store, "ga")
        let layout = ShellLayout(columns: 140, rows: 40)
        store.gridColumns = ShellView.gridColumns(for: store.state, layout: layout)
        #expect(store.gridColumns >= 4)
        let c = ShellView.render(store.state, columns: 140, rows: 40, selectedIndex: store.selectedIndex)
        let firstAlbum = screen(for: .albums, in: store.state).rows[0].cells[1]
        #expect(c.plainText.contains(firstAlbum))
        #expect(!c.plainText.contains("ALBUM "))  // no table header
    }
}

@Suite struct InlineGraphicsTests {
    func tempPNG() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-inline-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("a.png").path
        DemoArtwork.write(try #require(DemoArtwork.render(key: "album-1")), to: path)
        return path
    }

    @Test func detectsInlineTerminals() {
        #expect(GraphicsMode.detect(["TERM_PROGRAM": "iTerm.app"], colorMode: .truecolor) == .iterm2)
        #expect(GraphicsMode.detect(["TERM_PROGRAM": "WezTerm"], colorMode: .truecolor) == .iterm2)
        #expect(GraphicsMode.detect(["TERM": "foot"], colorMode: .truecolor) == .sixel)
        #expect(GraphicsMode.detect(["TERM_PROGRAM": "iTerm.app", "TMUX": "/x"], colorMode: .truecolor) == .halfblock)
        #expect(GraphicsMode.detect(["HARMUNE_GRAPHICS": "sixel"], colorMode: .truecolor) == .sixel)
    }

    @Test func itermPlacesOnceThenReportsRemovedRects() throws {
        let path = try tempPNG()
        var g = InlineGraphics(format: .iterm2)
        let a = ImagePlacement(path: path, rect: Rect(x: 2, y: 3, width: 16, height: 8))
        let out = g.place([a])
        #expect(out.contains("\u{1B}[4;3H"))
        #expect(out.contains("\u{1B}]1337;File=inline=1;"))
        #expect(out.contains("width=16;height=8;preserveAspectRatio=0"))
        #expect(out.hasSuffix("\u{07}\u{1B}8"))
        #expect(g.removed([a]).isEmpty)
        #expect(g.place([a]).isEmpty)
        #expect(g.removed([]) == [a.rect])
        #expect(!g.place([a]).isEmpty)  // returns after being removed
        g.reset()
        #expect(!g.place([a]).isEmpty)  // the screen was cleared
    }

    @Test func missingFilesAreSkipped() {
        var g = InlineGraphics(format: .iterm2)
        #expect(g.place([ImagePlacement(path: "/nonexistent.png", rect: Rect(x: 0, y: 0, width: 4, height: 2))]).isEmpty)
    }

    @Test func sixelEncodesBandsAndRuns() {
        // 4 wide, 7 tall: red, with the last row in a second band.
        let rgb: [UInt8] = (0..<28).flatMap { _ -> [UInt8] in [255, 0, 0] }
        let out = Sixel.encode(PixelGrid(width: 4, height: 7, rgb: rgb))
        #expect(out.hasPrefix("\u{1B}P0;1;0q\"1;1;4;7"))
        #expect(out.contains("#180;2;100;0;0"))  // cube index 5*36
        #expect(out.contains("#180!4~$-"))       // six rows set, four columns
        #expect(out.contains("#180!4@$-"))       // the one row left over
        #expect(out.hasSuffix("\u{1B}\\"))
    }

    @Test func sixelPlacementUsesCellPixels() throws {
        let path = try tempPNG()
        var g = InlineGraphics(format: .sixel, cellPixels: (8, 16))
        let out = g.place([ImagePlacement(path: path, rect: Rect(x: 0, y: 0, width: 4, height: 2))])
        #expect(out.contains("\"1;1;32;32"))
    }

    @Test func inlineArtworkUsesExactBlankCells() {
        var c = Canvas(width: 10, height: 4)
        c.paint(c.bounds, style: Style(fg: .rgb(9, 9, 9), bold: true))
        let rect = Rect(x: 0, y: 0, width: 4, height: 2)
        Artwork.draw(&c, rect, path: "/x.png", seed: "s", theme: .midnight, art: ArtworkSnapshot(mode: .iterm2, available: ["/x.png"]))
        #expect(c.imagePlacements.count == 1)
        #expect(c[0, 0].style == Style(bg: Theme.midnight.surface))  // nothing inherited from the selection
    }

    @Test func artworkOffShowsPlaceholders() {
        var c = Canvas(width: 10, height: 4)
        Artwork.draw(&c, Rect(x: 0, y: 0, width: 4, height: 2), path: "/x.png", seed: "s", theme: .midnight,
                     art: ArtworkSnapshot(mode: .kitty, available: ["/x.png"], enabled: false))
        #expect(c.imagePlacements.isEmpty && c.artworkRequests.isEmpty)
    }

    @Test func rendererRewritesDamagedCells() {
        var r = Renderer(colorMode: .truecolor)
        var c = Canvas(width: 10, height: 2)
        c.text("hello", x: 0, y: 0)
        _ = r.frame(c)
        #expect(!r.frame(c).contains("hello"))
        r.damage(Rect(x: 0, y: 0, width: 5, height: 1))
        #expect(r.frame(c).contains("hello"))
    }

    @Test func dynamicAccentIsReadableAndSkipsGray() {
        let bg = TermColor(hex: 0x101018)
        let dark: [UInt8] = (0..<16).flatMap { _ -> [UInt8] in [120, 10, 20] }
        let accent = DynamicColor.accent(from: PixelGrid(width: 4, height: 4, rgb: dark), on: bg)
        guard case .rgb(let r, let g, let b)? = accent else { Issue.record("no accent"); return }
        #expect(DynamicColor.contrast(DynamicColor.luminance(Double(r), Double(g), Double(b)),
                                      DynamicColor.luminance(0x10, 0x10, 0x18)) >= 4.5)
        let gray: [UInt8] = (0..<16).flatMap { _ -> [UInt8] in [128, 128, 128] }
        #expect(DynamicColor.accent(from: PixelGrid(width: 4, height: 4, rgb: gray), on: bg) == nil)
    }
}

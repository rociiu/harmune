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

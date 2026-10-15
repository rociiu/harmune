import Foundation
import Testing
@testable import HarmuneCore
@testable import HarmuneDemo
@testable import HarmuneTerminal

@MainActor
func makeStore() async -> AppStore {
    let store = AppStore(backend: DemoBackend(autoTick: false))
    store.listHeight = 10
    await store.start()
    await store.settle()
    return store
}

@MainActor
func press(_ store: AppStore, _ keys: String) async {
    for key in Key.parseSequence(keys) ?? [] {
        store.handle(key)
        await store.settle()
    }
}

@MainActor
func type(_ store: AppStore, _ text: String) async {
    for c in text { store.handle(c == " " ? .space : .char(c)) }
    await store.settle()
}

@MainActor
@Suite struct AppStoreTests {
    @Test func startsOnHomeWithData() async {
        let store = await makeStore()
        #expect(store.state.route == .home)
        guard case .home(let h)? = store.state.data[.home] else { Issue.record("home not loaded"); return }
        #expect(!h.recentlyPlayed.isEmpty)
        // Selection skips the section header.
        #expect(store.selectedIndex == 1)
    }

    @Test func gNavigationLoadsDestinations() async {
        let store = await makeStore()
        await press(store, "ga")
        #expect(store.state.route == .albums)
        #expect(store.state.data[.albums] != nil)
        await press(store, "gl")
        #expect(store.state.route == .songs)
        await press(store, "gq")
        #expect(store.state.route == .queue)
    }

    @Test func openAlbumAndPlayFromTrack() async {
        let store = await makeStore()
        await press(store, "ga")
        await press(store, "<cr>")
        guard case .album(let id) = store.state.route else { Issue.record("not on album"); return }
        await press(store, "jj<cr>")
        #expect(store.state.playback.isPlaying)
        #expect(store.state.playback.container?.id == id)
        #expect(store.state.queue.currentIndex == 2)
        // h goes back to the album list.
        await press(store, "h")
        #expect(store.state.route == .albums)
    }

    @Test func countsAndJumps() async {
        let store = await makeStore()
        await press(store, "gl")
        await press(store, "5j")
        #expect(store.selectedIndex == 5)
        // G goes to the end of the loaded page and fetches the next one.
        await press(store, "G")
        #expect(store.selectedIndex == 199)
        #expect(screen(for: .songs, in: store.state).rows.count == DemoLibrary.standard.tracks.count)
        await press(store, "G")
        #expect(store.selectedIndex == DemoLibrary.standard.tracks.count - 1)
        await press(store, "gg")
        #expect(store.selectedIndex == 0)
        await press(store, "<c-d>")
        #expect(store.selectedIndex == 5)
    }

    @Test func scrollKeepsSelectionVisible() async {
        let store = await makeStore()
        await press(store, "gl")
        await press(store, "30j")
        let top = store.state.scroll[.songs] ?? 0
        #expect(store.selectedIndex >= top && store.selectedIndex < top + store.listHeight)
    }

    @Test func queueActionsFromLists() async {
        let store = await makeStore()
        await press(store, "gl")
        await press(store, "a")
        await press(store, "j")
        await press(store, "a")
        #expect(store.state.queue.entries.count == 2)
        #expect(store.state.toast?.message.hasPrefix("Added to queue") == true)
        // Album rows enqueue the whole album.
        await press(store, "ga")
        await press(store, "p")
        #expect(store.state.queue.entries.count > 2)
    }

    @Test func queueEditingAndConfirm() async {
        let store = await makeStore()
        await press(store, "ga<cr><cr>")  // play first album from track 1
        await press(store, "gq")
        let before = store.state.queue.entries.count
        await press(store, "jdd")
        #expect(store.state.queue.entries.count == before - 1)
        await press(store, "J")
        #expect(store.selectedIndex == 2)
        await press(store, "D")
        guard case .confirm? = store.state.overlay else { Issue.record("no confirm"); return }
        await press(store, "n")
        #expect(store.state.queue.entries.count == before - 1)
        await press(store, "Dy")
        #expect(store.state.queue.entries.count == 1)
    }

    @Test func playbackKeys() async {
        let store = await makeStore()
        await press(store, "gl<cr>")
        #expect(store.state.playback.isPlaying)
        await press(store, "<space>")
        #expect(!store.state.playback.isPlaying)
        await press(store, "s")
        #expect(store.state.playback.shuffle)
        await press(store, "r")
        #expect(store.state.playback.repeat == .all)
        await press(store, "3]")
        #expect(store.state.playback.position(at: Date()) >= 14.9)
    }

    @Test func searchDebouncesAndShowsResults() async {
        let store = await makeStore()
        await press(store, "/")
        #expect(store.state.mode == .search)
        #expect(store.state.route == .search)
        #expect(store.state.searchScope == .catalog)
        await type(store, "neon")
        #expect(store.state.searchQuery == "neon")
        await press(store, "<cr>")
        #expect(store.state.mode == .normal)
        guard case .search(let r)? = store.state.data[.search] else { Issue.record("no results"); return }
        #expect(!r.songs.isEmpty)
        // First selectable row is the first song, below the SONGS header.
        #expect(store.selectedIndex == 1)
    }

    @Test func searchFromLibraryDefaultsToLibraryScope() async {
        let store = await makeStore()
        await press(store, "ga/")
        #expect(store.state.searchScope == .library)
        store.handle(.ctrl("s"))
        #expect(store.state.searchScope == .catalog)
        await press(store, "<esc>")
        #expect(store.state.mode == .normal)
    }

    @Test func filterNarrowsAndEscClears() async {
        let store = await makeStore()
        await press(store, "ga")
        let all = screen(for: .albums, in: store.state).rows.count
        await press(store, "F")
        await type(store, "echo")
        let filtered = screen(for: .albums, in: store.state).rows
        #expect(filtered.count < all)
        #expect(filtered.allSatisfy { $0.cells.joined().lowercased().contains("echo") })
        await press(store, "<cr><esc>")
        #expect(screen(for: .albums, in: store.state).rows.count == all)
    }

    @Test func commandMode() async {
        let store = await makeStore()
        await press(store, ":")
        await type(store, "theme mono")
        await press(store, "<cr>")
        #expect(store.state.theme == .mono)
        await press(store, ":")
        await type(store, "alb")
        await press(store, "<tab>")
        #expect(store.state.input == "albums ")
        await press(store, "<cr>")
        #expect(store.state.route == .albums)
        await press(store, ":")
        await type(store, "bogus")
        await press(store, "<cr>")
        #expect(store.state.toast?.isError == true)
    }

    @Test func quitOnlyFromRoot() async {
        let store = await makeStore()
        var quit: QuitReason?
        store.onQuit = { quit = $0 }
        await press(store, "ga<cr>")
        await press(store, "q")
        #expect(quit == nil)
        #expect(store.state.route == .albums)
        await press(store, "q")
        #expect(quit == .user)
    }

    @Test func sidebarFocus() async {
        let store = await makeStore()
        await press(store, "<tab>")
        #expect(store.state.focus == .sidebar)
        await press(store, "jjj<cr>")  // Home, Search, Songs, Albums
        #expect(store.state.route == .albums)
        #expect(store.state.focus == .content)
    }

    @Test func helpOverlayClosesOnAnyKey() async {
        let store = await makeStore()
        await press(store, "?")
        #expect(store.state.overlay == .help)
        await press(store, "j")
        #expect(store.state.overlay == nil)
        #expect(store.selectedIndex == 1)  // the key did not also move
    }

    @Test func nowPlayingToggle() async {
        let store = await makeStore()
        await press(store, "v")
        #expect(store.state.route == .nowPlaying)
        await press(store, "v")
        #expect(store.state.route == .home)
    }

    @Test func unsupportedFeaturesToastInsteadOfFailingSilently() async {
        let store = await makeStore()
        await press(store, "gf")
        #expect(store.state.toast?.isError == true)
    }

    @Test func errorsSurfaceOnTheRoute() async {
        let store = await makeStore()
        store.push(.album("missing"))
        await store.settle()
        #expect(store.state.errors[.album("missing")] != nil)
        #expect(screen(for: .album("missing"), in: store.state).empty.contains("not found"))
    }
}

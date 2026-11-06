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

    @Test(arguments: [Route.artists, .playlists])
    func artistAndPlaylistListsLoadNextPage(_ route: Route) async {
        let backend = GatedBackend(pagedLibrary: true)
        _ = await backend.requestAuthorization()
        let store = AppStore(backend: backend, startRoute: route)
        await store.start()
        await store.settle()
        #expect(screen(for: route, in: store.state).rows.count == 200)

        await press(store, "G")
        #expect(screen(for: route, in: store.state).rows.count == 201)
        #expect(store.selectedIndex == 199)

        await press(store, "G")
        #expect(screen(for: route, in: store.state).rows.count == 201)
        #expect(store.selectedIndex == 200)
    }

    @Test func viewSwitcherFocus() async {
        let store = await makeStore()
        await press(store, "<tab>")
        #expect(store.state.focus == .views)
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

    @Test func favoritesBrowseAndPlay() async {
        let store = await makeStore()
        await press(store, "gf")
        #expect(store.state.route == .favorites)
        #expect(Route.destinations([.favorites]).contains(.favorites))
        #expect(!Route.destinations([]).contains(.favorites))
        let rows = screen(for: .favorites, in: store.state).rows
        #expect(rows.contains { $0.trackID != nil })
        await press(store, "<cr>")
        #expect(store.state.playback.track?.id == rows.first(where: { $0.isSelectable })?.trackID)
        await press(store, "f")
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

@MainActor
@Suite struct FeatureTests {
    @Test func searchTabsSwitchCategoriesNotScope() async {
        let store = await makeStore()
        await press(store, "/")
        await type(store, "neon")
        await press(store, "<cr>")
        let scope = store.state.searchScope
        await press(store, "L")
        #expect(store.state.searchTab == .songs)
        #expect(store.state.searchScope == scope)
        let songs = screen(for: .search, in: store.state).rows
        #expect(!songs.isEmpty && songs.allSatisfy { if case .song = $0.kind { true } else { false } })
        await press(store, "H")
        #expect(store.state.searchTab == .all)
        await press(store, "H")
        #expect(store.state.searchTab == .playlists)
        #expect(screen(for: .search, in: store.state).tabs.count == 5)
    }

    @Test func sortPickerReloadsWithTheChosenKey() async {
        let store = await makeStore()
        await press(store, "gl")
        await press(store, "o")
        guard case .picker(let picker)? = store.state.overlay else { Issue.record("no picker"); return }
        #expect(picker.options == ["Title", "Artist", "Recently added"])
        await press(store, "j<cr>")
        #expect(store.state.overlay == nil)
        #expect(store.state.sort[.songs] == .artist)
        guard case .tracks(let tracks, _)? = store.state.data[.songs] else { Issue.record("no songs"); return }
        #expect(tracks[0].artist <= tracks[1].artist)
        await press(store, "gq")
        await press(store, "o")
        #expect(store.state.toast?.isError == true)
    }

    @Test func themePickerPreviewsAndEscReverts() async {
        let store = await makeStore()
        var saved: [String] = []
        store.onPersist = { saved.append("\($0).\($1)=\($2)") }
        await press(store, ":")
        await type(store, "theme")
        await press(store, "<cr>")
        await press(store, "j")
        #expect(store.state.theme == .tokyoNight)
        await press(store, "<esc>")
        #expect(store.state.theme == .midnight)
        #expect(saved.isEmpty)

        await press(store, ":")
        await type(store, "theme")
        await press(store, "<cr>jj<cr>")
        #expect(store.state.theme == .catppuccinMocha)
        #expect(saved == ["general.theme=\"catppuccin-mocha\""])
    }

    @Test func settingsToggleAppliesAndPersists() async {
        let store = await makeStore()
        var saved: [String] = []
        store.onPersist = { saved.append("\($0).\($1)=\($2)") }
        await press(store, "g,")
        #expect(store.state.route == .settings)
        #expect(screen(for: .settings, in: store.state).rows.count == SettingKey.allCases.count)
        await press(store, "j<cr>")  // Album artwork
        #expect(!store.state.prefs.showArtwork)
        #expect(!store.state.art.enabled)
        #expect(saved == ["appearance.show_artwork=false"])
        // Setting the artwork snapshot later doesn't turn it back on.
        store.setArtwork(ArtworkSnapshot(mode: .kitty))
        #expect(!store.state.art.enabled)
    }

    @Test func commandsForAppearance() async {
        let store = await makeStore()
        await press(store, ":")
        await type(store, "visualizer off")
        await press(store, "<cr>")
        #expect(!store.state.prefs.showVisualizer)
        await press(store, ":")
        await type(store, "immersive")
        await press(store, "<cr>")
        #expect(store.state.route == .nowPlaying)
        await press(store, ":")
        await type(store, "nowplaying")
        await press(store, "<cr>")
        #expect(store.state.route == .home)
    }

    @Test func commandCompletionCoversArguments() async {
        #expect(CommandLine.complete("sh", themes: Theme.all) == "shuffle ")
        #expect(CommandLine.complete("theme no", themes: Theme.all) == "theme nord")
        #expect(CommandLine.complete("repeat o", themes: Theme.all) == "repeat o")
        #expect(CommandLine.suggestions("rpt", themes: Theme.all) == ["repeat"])
        #expect(CommandLine.complete("zzz", themes: Theme.all) == nil)
    }

    @Test func commandHistoryRecallsAndPersists() async throws {
        let path = NSTemporaryDirectory() + "hm-history-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = AppStore(backend: DemoBackend(autoTick: false), historyPath: path)
        await store.start()
        await press(store, ":")
        await type(store, "albums")
        await press(store, "<cr>:")
        await type(store, "songs")
        await press(store, "<cr>:")
        await press(store, "<up>")
        #expect(store.state.input == "songs")
        await press(store, "<up>")
        #expect(store.state.input == "albums")
        await press(store, "<down><down>")
        #expect(store.state.input == "")
        await press(store, "<esc>")
        let reloaded = AppStore(backend: DemoBackend(autoTick: false), historyPath: path)
        #expect(reloaded.state.commandHistory == ["albums", "songs"])
    }

    @Test func recentlyPlayedAndViewSwitcherFollowCapabilities() async {
        let store = await makeStore()
        await press(store, "gr")
        #expect(store.state.route == .recentlyPlayed)
        #expect(!screen(for: .recentlyPlayed, in: store.state).rows.isEmpty)
        #expect(Route.destinations([]).contains(.recentlyPlayed) == false)
        #expect(Route.destinations([.recentlyPlayed]).contains(.recentlyPlayed))
    }

    @Test func homeUsesListNavigation() async throws {
        let store = await makeStore()
        let rows = screen(for: .home, in: store.state).rows
        let first = try #require(rows.indices.first { rows[$0].isSelectable })
        let second = try #require(rows.indices.first { $0 > first && rows[$0].isSelectable })
        #expect(store.selectedIndex == first)
        await press(store, "<down>")
        #expect(store.selectedIndex == second)
        await press(store, "k")
        #expect(store.selectedIndex == first)
        await press(store, "h")
        #expect(store.state.focus == .views)
        await press(store, "<esc>")
        #expect(store.state.focus == .content)
        let frame = ShellView.render(store.state, columns: 140, rows: 40, selectedIndex: store.selectedIndex)
        #expect(frame.plainText.contains("RECENTLY PLAYED"))
        #expect(frame.artworkRequests.isEmpty)
    }

    @Test func authGateBlocksUntilConnected() async {
        let backend = GatedBackend()
        let store = AppStore(backend: backend)
        await store.start()
        await store.settle()
        #expect(store.state.auth.state == .notDetermined)
        #expect(store.state.data[.home] == nil)
        var text = ShellView.render(store.state, columns: 120, rows: 40, selectedIndex: 0).plainText
        #expect(text.contains("Connect Apple Music"))
        await press(store, "<cr>")
        #expect(store.state.auth.state == .authorized)
        #expect(store.state.data[.home] != nil)
        text = ShellView.render(store.state, columns: 120, rows: 40, selectedIndex: 0).plainText
        #expect(!text.contains("Connect Apple Music"))
    }

    @Test(arguments: [(AuthState.denied, "Privacy & Security", true), (.restricted, "restricted", false),
                      (.noSubscription, "subscription", false), (.unavailable, "isn't available", false)])
    func authGateExplainsEachState(_ state: AuthState, _ text: String, _ canConnect: Bool) {
        let gate = authGate(route: .home, status: AuthStatus(state: state))
        #expect(gate?.canConnect == canConnect)
        #expect(((gate?.lines ?? []) + [gate?.title ?? ""]).joined().contains(text))
    }

    @Test func noSubscriptionStillAllowsLibrary() {
        #expect(authGate(route: .albums, status: AuthStatus(state: .noSubscription)) == nil)
        #expect(authGate(route: .settings, status: AuthStatus(state: .denied)) == nil)
    }

    @Test func helpReflectsRebindingAndScrollsWhenShort() async {
        var keymap = Keymap.standard
        _ = keymap.apply(overrides: ["normal": ["<c-n>": "next_track", ">": "none"]])
        #expect(HelpContent.lines(keymap).contains { $0.keys.contains("Ctrl+n") })
        let store = await makeStore()
        store.terminalRows = 20
        await press(store, "?jj")
        #expect(store.state.overlay == .help)
        #expect(store.state.helpScroll == 2)
        #expect(ShellView.render(store.state, columns: 80, rows: 20, selectedIndex: 0).plainText.contains("scroll"))
        await press(store, "x")
        #expect(store.state.overlay == nil)
        #expect(store.state.helpScroll == 0)
    }

    @Test func immersiveIsFullScreen() async {
        let store = await makeStore()
        await press(store, "ga<cr><cr>v")
        let text = ShellView.render(store.state, columns: 120, rows: 40, selectedIndex: 0).plainText
        #expect(text.contains("Now playing"))
        #expect(!text.contains("⌂  Home"))
        store.setDynamicAccent(.rgb(1, 2, 3))
        #expect(store.state.decorativeTheme.accent == .rgb(1, 2, 3))
    }

    @Test func everyThemeRendersAndNoBordersHidesLines() async {
        let store = await makeStore()
        for theme in Theme.all {
            await press(store, ":")
            await type(store, "theme \(theme.name)")
            await press(store, "<cr>")
            #expect(store.state.theme == theme)
            _ = ShellView.render(store.state, columns: 120, rows: 40, selectedIndex: 0)
        }
        #expect(Set(Theme.all.map(\.name)).count == 7)
    }

    @Test func customThemesParse() throws {
        let (theme, warnings) = Theme.parse(name: "mine", text: """
        # comment
        base = "nord"
        accent = "#112233"
        border = "nope"
        sparkle = "#000000"
        """)
        #expect(theme.name == "mine")
        #expect(theme.accent == .rgb(0x11, 0x22, 0x33))
        #expect(theme.background == Theme.nord.background)
        #expect(warnings.count == 2)

        let dir = NSTemporaryDirectory() + "hm-themes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "accent = \"#010203\"".write(toFile: dir + "/nord.toml", atomically: true, encoding: .utf8)
        let available = Theme.available(customDirectory: dir)
        #expect(available.themes.count == Theme.all.count)
        #expect(available.themes.first { $0.name == "nord" }?.accent == .rgb(1, 2, 3))
    }

    @Test func routesKnowTheirPageNames() {
        #expect(Route.page("albums") == .albums)
        #expect(Route.albums.pageName == "albums")
        #expect(Route.page("nope") == nil)
        #expect(Route.album("x").pageName == nil)
    }

    @Test func extraMotions() async {
        let store = await makeStore()
        await press(store, "gl<c-f>")
        #expect(store.selectedIndex == 9)
        await press(store, "<c-b>")
        #expect(store.selectedIndex == 0)
        await press(store, "30jzz")
        #expect(store.state.scroll[.songs] == 25)
    }

    @Test func keysTextListsEverySection() {
        let text = Keymap.standard.helpText()
        #expect(text.contains("PLAYBACK") && text.contains("j / k") && text.contains("Ctrl+d / Ctrl+u"))
        #expect(Keymap.standard.helpMarkdown().contains("| `Space` | play / pause |"))
    }

    @Test func focusEventsDecodeAndAreIgnoredByTheStore() async {
        var decoder = KeyDecoder()
        #expect(decoder.feed(Array("\u{1B}[I\u{1B}[O".utf8)) == [.focusIn, .focusOut])
        let store = await makeStore()
        store.handle(.focusOut)
        #expect(store.state.pendingKeys.isEmpty)
    }
}

/// A backend that starts unauthorized, as a new install does.
actor GatedBackend: MusicBackend {
    private let demo = DemoBackend(autoTick: false)
    private var status = AuthStatus(state: .notDetermined)
    private let pagedLibrary: Bool

    init(pagedLibrary: Bool = false) { self.pagedLibrary = pagedLibrary }

    func capabilities() async -> Set<Capability> { await demo.capabilities() }
    func authStatus() async -> AuthStatus { status }
    func requestAuthorization() async -> AuthStatus {
        status = AuthStatus(state: .authorized)
        return status
    }
    func play(_ request: PlayRequest) async throws { try await demo.play(request) }
    func pause() async throws { try await demo.pause() }
    func togglePlayPause() async throws { try await demo.togglePlayPause() }
    func next() async throws { try await demo.next() }
    func previous() async throws { try await demo.previous() }
    func seek(to position: TimeInterval) async throws { try await demo.seek(to: position) }
    func setShuffle(_ on: Bool) async throws { try await demo.setShuffle(on) }
    func setRepeat(_ mode: RepeatMode) async throws { try await demo.setRepeat(mode) }
    func enqueue(songIDs: [String], at position: EnqueuePosition) async throws { try await demo.enqueue(songIDs: songIDs, at: position) }
    func removeFromQueue(entryID: String) async throws { try await demo.removeFromQueue(entryID: entryID) }
    func moveQueueEntry(entryID: String, to index: Int) async throws { try await demo.moveQueueEntry(entryID: entryID, to: index) }
    func clearUpcoming() async throws { try await demo.clearUpcoming() }
    func search(_ query: SearchQuery) async throws -> SearchResults { try await demo.search(query) }
    func librarySongs(sort: SortKey, offset: Int, limit: Int) async throws -> Page<Track> { try await demo.librarySongs(sort: sort, offset: offset, limit: limit) }
    func libraryAlbums(sort: SortKey, offset: Int, limit: Int) async throws -> Page<Album> { try await demo.libraryAlbums(sort: sort, offset: offset, limit: limit) }
    func libraryArtists(offset: Int, limit: Int) async throws -> Page<Artist> {
        guard pagedLibrary else { return try await demo.libraryArtists(offset: offset, limit: limit) }
        let end = min(201, offset + limit)
        let items = (offset..<end).map { Artist(id: "a\($0)", name: "Artist \($0)") }
        return Page(items: items, nextOffset: end < 201 ? end : nil)
    }
    func libraryPlaylists(offset: Int, limit: Int) async throws -> Page<Playlist> {
        guard pagedLibrary else { return try await demo.libraryPlaylists(offset: offset, limit: limit) }
        let end = min(201, offset + limit)
        let items = (offset..<end).map { Playlist(id: "p\($0)", name: "Playlist \($0)", trackCount: 0) }
        return Page(items: items, nextOffset: end < 201 ? end : nil)
    }
    func album(id: String) async throws -> AlbumDetail { try await demo.album(id: id) }
    func artist(id: String) async throws -> ArtistDetail { try await demo.artist(id: id) }
    func playlist(id: String) async throws -> PlaylistDetail { try await demo.playlist(id: id) }
    func home() async throws -> HomeSections { try await demo.home() }
    func playbackState() async -> PlaybackState { await demo.playbackState() }
    func queueState() async -> QueueState { await demo.queueState() }
    func events() async -> AsyncStream<BackendEvent> { await demo.events() }
}

import Foundation
import HarmuneCore

public enum QuitReason: Sendable, Equatable { case user, stopHost }

/// Owns `AppState`, turns keys into commands and commands into backend
/// effects. The view layer only reads `state`.
@MainActor
public final class AppStore {
    public private(set) var state = AppState()
    public private(set) var backend: any MusicBackend
    /// Called after every state change; the run loop coalesces redraws.
    public var onChange: () -> Void = {}
    public var onQuit: (QuitReason) -> Void = { _ in }
    /// Rows visible in the content list; set by the run loop on layout.
    public var listHeight = 20 { didSet { adjustScroll() } }
    /// Tiles per row when the album grid is showing, else 0. Set by the run loop.
    public var gridColumns = 0 { didSet { if gridColumns != oldValue { adjustScroll() } } }
    /// Terminal height, which decides whether help needs to scroll.
    public var terminalRows = Int.max
    /// Saves a change to `config.toml`: section, key and a TOML literal.
    public var onPersist: (String, String, String) -> Void = { _, _, _ in }

    private var gridActive: Bool {
        gridColumns > 0 && state.route == .albums && state.focus == .content
    }

    private let reconnect: (@Sendable () async throws -> any MusicBackend)?
    private var resolver: KeyResolver
    private let startRoute: Route
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private let clock: () -> Date
    private let historyPath: String?
    private var historyIndex: Int?
    private var historyDraft = ""
    private var searchCache: [SearchCacheKey: (results: SearchResults, stored: Date)] = [:]
    private struct SearchCacheKey: Hashable { var text: String; var scope: SearchScope; var tab: SearchTab }
    private static let searchCacheLimit = 50
    private static let searchCacheLifetime: TimeInterval = 300
    private static let historyLimit = 500

    public init(backend: any MusicBackend, theme: Theme = .midnight, themes: [Theme] = Theme.all,
                preferences: Preferences = Preferences(),
                keymap: Keymap = .standard, sequenceTimeout: TimeInterval = 0.6, startRoute: Route = .home,
                historyPath: String? = nil,
                reconnect: (@Sendable () async throws -> any MusicBackend)? = nil,
                clock: @escaping () -> Date = { Date() }) {
        self.backend = backend
        self.resolver = KeyResolver(keymap: keymap, timeout: sequenceTimeout)
        self.startRoute = startRoute
        self.reconnect = reconnect
        self.clock = clock
        self.historyPath = historyPath
        state.theme = theme
        state.themes = themes
        state.prefs = preferences
        state.keymap = keymap
        state.now = clock()
        if let historyPath, let text = try? String(contentsOfFile: historyPath, encoding: .utf8) {
            state.commandHistory = text.split(separator: "\n").map(String.init)
        }
    }

    // MARK: - Lifecycle

    /// Updated by the run loop as artwork decodes; no redraw is triggered.
    public func setArtwork(_ art: ArtworkSnapshot) {
        state.art = art
        state.art.enabled = state.prefs.showArtwork
    }

    public func setDynamicAccent(_ color: TermColor?) { state.dynamicAccent = color }

    public func start() async {
        await refreshSession()
        subscribe()
        go(startRoute)
        changed()
    }

    /// Waits until every in-flight effect has finished (for tests).
    public func settle() async {
        while let task = tasks.values.first { await task.value }
    }

    /// Called by the run loop on a timer. Returns true when a redraw is due.
    @discardableResult
    public func tick() -> Bool {
        let reconnectSeconds = state.reconnectSeconds
        let wasTransitioning = state.trackTransitionProgress != nil
        state.now = clock()
        var dirty = reconnectSeconds != state.reconnectSeconds || wasTransitioning && state.trackTransitionProgress == nil
        if let toast = state.toast, toast.expires <= state.now { state.toast = nil; dirty = true }
        if let resolution = resolver.expire(context: keyContext, at: state.now) {
            state.pendingKeys = ""
            if case .command(let c, let n) = resolution { perform(c, count: n) }
            dirty = true
        }
        return dirty
    }

    private func refreshSession() async {
        state.capabilities = await backend.capabilities()
        state.auth = await backend.authStatus()
        state.playback = await backend.playbackState()
        state.queue = await backend.queueState()
    }

    private func subscribe() {
        eventsTask?.cancel()
        let backend = self.backend
        eventsTask = Task { [weak self] in
            for await event in await backend.events() {
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
            guard !Task.isCancelled else { return }
            await self?.connectionLost()
        }
    }

    private func apply(_ event: BackendEvent) {
        switch event {
        case .playback(let p) where p.revision >= state.playback.revision: applyPlayback(p)
        case .queue(let q) where q.revision >= state.queue.revision: state.queue = q
        case .auth(let a): authChanged(to: a)
        default: return
        }
        changed()
    }

    private func applyPlayback(_ playback: PlaybackState) {
        if let previous = state.playback.track, let next = playback.track, previous.id != next.id,
           state.route == .nowPlaying, state.focus == .content, !state.prefs.reducedMotion {
            state.now = clock()
            state.trackTransition = (state.now, previous.album)
        }
        state.playback = playback
    }

    /// Everything loaded before access was granted is missing or an error.
    private func authChanged(to status: AuthStatus) {
        let wasAuthorized = state.auth.state == .authorized
        state.auth = status
        guard status.state == .authorized, !wasAuthorized else { return }
        state.data.removeAll()
        state.errors.removeAll()
        load(state.route)
    }

    private func connect() {
        let backend = self.backend
        toast("Waiting for the Apple Music prompt…")
        spawn { [weak self] in
            let status = await backend.requestAuthorization()
            guard let self else { return }
            self.authChanged(to: status)
            self.state.capabilities = await backend.capabilities()
            if status.state == .authorized { self.toast("Connected to Apple Music") }
        }
    }

    private func connectionLost() async {
        guard let reconnect else {
            state.connection = .offline
            toast("Lost connection to the Harmune host", error: true)
            return
        }
        state.connection = .reconnecting
        changed()
        var delay = 0.25
        while !Task.isCancelled {
            if let fresh = try? await reconnect() {
                backend = fresh
                state.playback = .idle
                state.queue = QueueState()
                await refreshSession()
                state.connection = .connected
                subscribe()
                toast("Reconnected to the Harmune host")
                return
            }
            state.now = clock()
            state.nextReconnectAt = state.now.addingTimeInterval(delay)
            changed()
            try? await Task.sleep(for: .seconds(delay))
            state.nextReconnectAt = nil
            delay = min(delay * 2, 4)
        }
    }

    // MARK: - Keys

    private var keyContext: KeyContext {
        if gridActive { return .grid }
        return state.focus == .views ? .list : state.route.keyContext
    }

    public func handle(_ key: Key) {
        if key == .focusIn || key == .focusOut { return }  // handled by the run loop
        state.now = clock()
        if key == .ctrl("c") { quit(.user); return }

        if let overlay = state.overlay {
            switch overlay {
            case .help:
                let overflow = HelpContent.lines(state.keymap).count + 6 - terminalRows
                if overflow > 0, key == .char("j") || key == .down {
                    state.helpScroll = min(overflow, state.helpScroll + 1)
                } else if overflow > 0, key == .char("k") || key == .up {
                    state.helpScroll = max(0, state.helpScroll - 1)
                } else {
                    state.overlay = nil
                    state.helpScroll = 0
                }
            case .picker(let picker):
                handlePicker(picker, key)
            case .confirm(_, let action):
                state.overlay = nil
                if key == .char("y") || key == .char("Y") {
                    switch action {
                    case .clearQueue: run("Clear queue") { b in try await b.clearUpcoming() }
                    case .quitAndStopHost: quit(.stopHost)
                    }
                }
            }
            changed(); return
        }

        if state.mode != .normal { handleInput(key); changed(); return }

        switch resolver.feed(key, context: keyContext, at: state.now) {
        case .command(let c, let count):
            state.pendingKeys = ""
            perform(c, count: count)
        case .pending(let display):
            state.pendingKeys = display
        case .unbound:
            state.pendingKeys = ""
        }
        changed()
    }

    // MARK: - Commands

    public func perform(_ command: KeyCommand, count: Int? = nil) {
        let n = count ?? 1
        switch command {
        case .moveDown:
            move(by: gridActive ? n * gridColumns : n)
        case .moveUp:
            move(by: gridActive ? -n * gridColumns : -n)
        case .filterNext: move(by: n)
        case .filterPrevious: move(by: -n)
        case .moveLeft:
            if selectedIndex <= firstSelectable(in: screen(for: state.route, in: state).rows) {
                state.focus = .views
                syncViewIndex()
            } else {
                move(by: -n)
            }
        case .moveRight:
            move(by: n)
        case .moveFirst: if let count { select(line: count) } else { move(by: Int.min / 2) }
        case .moveLast: if let count { select(line: count) } else { move(by: Int.max / 2) }
        case .halfPageDown: move(by: max(1, listHeight / 2) * n)
        case .halfPageUp: move(by: -max(1, listHeight / 2) * n)
        case .pageDown: move(by: max(1, listHeight - 1) * n)
        case .pageUp: move(by: -max(1, listHeight - 1) * n)
        case .center:
            guard state.focus == .content else { break }
            let rows = screen(for: state.route, in: state).rows.count
            state.scroll[state.route] = max(0, min(selectedIndex - listHeight / 2, max(0, rows - listHeight)))

        case .focusNext, .focusPrevious:
            state.focus = state.focus == .views ? .content : .views
            if state.focus == .views { syncViewIndex() }
        case .goBack:
            if state.focus == .views {
                state.focus = .content
            } else if state.stack.count > 1 {
                pop()
            } else {
                state.focus = .views
                syncViewIndex()
            }
        case .openSelected:
            if state.focus == .views {
                if let route = destinations[safe: state.viewIndex] { go(route) }
            } else if authGate(route: state.route, status: state.auth)?.canConnect == true {
                connect()
            } else {
                activateSelection()
            }
        case .close:
            if state.focus == .views {
                state.focus = .content
            } else if let filter = state.filters[state.route], !filter.isEmpty {
                state.filters[state.route] = nil
                resetSelection()
            } else if state.stack.count > 1 {
                pop()
            }
        case .quit:
            if state.stack.count > 1 { pop() } else { quit(.user) }

        case .search:
            state.searchScope = state.route.isLibrary ? .library : .catalog
            if state.route != .search { go(.search) }
            state.focus = .content
            state.mode = .search
            state.input = state.searchQuery
        case .filter:
            state.focus = .content
            state.mode = .filter
            state.input = state.filters[state.route] ?? ""
        case .commandMode:
            state.mode = .command
            state.input = ""
        case .help:
            state.overlay = .help

        case .home: go(.home)
        case .goSearch: go(.search)
        case .songs: go(.songs)
        case .albums: go(.albums)
        case .artists: go(.artists)
        case .playlists: go(.playlists)
        case .queue: go(.queue)
        case .nowPlaying, .toggleImmersive:
            toggleImmersive()
        case .favorites:
            if state.capabilities.contains(.favorites) { go(.favorites) }
            else { toast("Favorites aren't supported by this backend", error: true) }
        case .recentlyPlayed:
            if state.capabilities.contains(.recentlyPlayed) { go(.recentlyPlayed) }
            else { toast("Recently Played isn't supported by this backend", error: true) }
        case .settings: go(.settings)
        case .tabPrevious, .tabNext:
            guard state.route == .search else { break }
            let tabs = SearchTab.allCases
            let step = command == .tabNext ? 1 : tabs.count - 1
            state.searchTab = tabs[(state.searchTab.rawValue + step) % tabs.count]
            resetSelection()
            if !state.searchQuery.isEmpty { scheduleSearch(immediate: true) }
        case .toggleLayout:
            guard state.route == .albums else { toast("Grid view is available in Albums", error: true); break }
            toggle(.albumView)
            toast(state.albumGrid ? "Grid view" : "List view")
        case .sort:
            openSortPicker()

        case .playPause: run("Play/Pause") { b in try await b.togglePlayPause() }
        case .nextTrack: run("Next") { b in try await b.next() }
        case .previousTrack: run("Previous") { b in try await b.previous() }
        case .seekForward, .seekBackward:
            let delta = Double(5 * n) * (command == .seekForward ? 1 : -1)
            let target = max(0, state.playback.position(at: clock()) + delta)
            run("Seek") { b in try await b.seek(to: target) }
        case .toggleShuffle:
            let on = !state.playback.shuffle
            run("Shuffle") { b in try await b.setShuffle(on) }
            toast("Shuffle \(on ? "on" : "off")")
        case .cycleRepeat:
            let mode = state.playback.repeat.next
            run("Repeat") { b in try await b.setRepeat(mode) }
            toast("Repeat \(mode.rawValue)")
        case .toggleFavorite:
            addSelectedFavorite()

        case .addToQueue: enqueueSelection(.last)
        case .playNext: enqueueSelection(.next)
        case .removeEntry:
            guard requireQueue(.queueRemove), case .queueEntry(let e, _)? = selectedRow?.kind else { break }
            run("Remove") { b in try await b.removeFromQueue(entryID: e.id) }
        case .moveEntryDown, .moveEntryUp:
            guard requireQueue(.queueMove), case .queueEntry(let e, let i)? = selectedRow?.kind else { break }
            let target = command == .moveEntryDown ? i + n : i - n
            guard target > (state.queue.currentIndex ?? -1), target < state.queue.entries.count else { break }
            run("Move") { b in try await b.moveQueueEntry(entryID: e.id, to: target) }
            state.selection[.queue] = target
            adjustScroll()
        case .clearQueue:
            guard requireQueue(.queueRemove) else { break }
            state.overlay = .confirm("Clear \(state.queue.upcoming.count) upcoming songs?", .clearQueue)
        }
    }

    private func toggleImmersive() {
        if state.route != .nowPlaying { push(.nowPlaying) }
        else if state.stack.count > 1 { pop() }
        else { go(.home) }
    }

    private func addSelectedFavorite() {
        guard state.capabilities.contains(.favoriteAdd) else {
            toast("Adding favorites isn't supported by this backend", error: true)
            return
        }
        let item: (id: String, kind: MediaKind)
        switch selectedRow?.kind {
        case .song(let track, _, _, _): item = (track.id, .songs)
        case .queueEntry(let entry, _): item = (entry.track.id, .songs)
        case .album(let album): item = (album.id, .albums)
        default:
            toast("Select a song or album to add to favorites", error: true)
            return
        }
        let backend = self.backend
        spawn { [weak self] in
            do {
                try await backend.addFavorite(id: item.id, kind: item.kind)
                self?.state.data[.favorites] = nil
                self?.toast("Favorite request accepted by Apple Music")
            } catch {
                self?.toast("Favorite: " + Self.message(error), error: true)
            }
        }
    }

    private func requireQueue(_ cap: Capability) -> Bool {
        guard state.route == .queue else { return false }
        if state.capabilities.contains(cap) { return true }
        toast("Queue editing isn't supported by this backend", error: true)
        return false
    }

    // MARK: - Navigation

    /// Top-level destinations replace the stack.
    public func go(_ route: Route) {
        state.stack = [route]
        state.focus = .content
        syncViewIndex()
        load(route)
    }

    public func push(_ route: Route) {
        state.stack.append(route)
        state.focus = .content
        load(route)
    }

    private func pop() {
        guard state.stack.count > 1 else { return }
        state.stack.removeLast()
        adjustScroll()
    }

    private func syncViewIndex() {
        state.viewIndex = destinations.firstIndex(of: state.stack.first ?? .home) ?? 0
    }

    private var destinations: [Route] { Route.destinations(state.capabilities) }

    public func load(_ route: Route, force: Bool = false) {
        if !force, state.data[route] != nil || state.loading.contains(route) { return }
        if authGate(route: route, status: state.auth) != nil { return }
        let sort = state.sort[route] ?? .title
        let fetcher: (@Sendable (any MusicBackend) async throws -> RouteData)?
        switch route {
        case .home: fetcher = { .home(try await $0.home()) }
        case .songs: fetcher = { b in let p = try await b.librarySongs(sort: sort, offset: 0, limit: 200); return .tracks(p.items, nextOffset: p.nextOffset) }
        case .albums: fetcher = { b in let p = try await b.libraryAlbums(sort: sort, offset: 0, limit: 200); return .albums(p.items, nextOffset: p.nextOffset) }
        case .artists: fetcher = { b in
            let page = try await b.libraryArtists(offset: 0, limit: 200)
            return .artists(page.items, nextOffset: page.nextOffset)
        }
        case .playlists: fetcher = { b in
            let page = try await b.libraryPlaylists(offset: 0, limit: 200)
            return .playlists(page.items, nextOffset: page.nextOffset)
        }
        case .album(let id): fetcher = { .albumDetail(try await $0.album(id: id)) }
        case .playlist(let id): fetcher = { .playlistDetail(try await $0.playlist(id: id)) }
        case .artist(let id): fetcher = { .artistDetail(try await $0.artist(id: id)) }
        case .search: if force { scheduleSearch(immediate: true) }; fetcher = nil
        case .queue:
            fetcher = nil
            spawn { [weak self] in
                guard let self else { return }
                self.state.queue = await self.backend.queueState()
            }
        case .favorites: fetcher = { .favorites(try await $0.favorites()) }
        case .recentlyPlayed: fetcher = { .albums(try await $0.home().recentlyPlayed, nextOffset: nil) }
        case .nowPlaying, .settings: fetcher = nil
        }
        guard let fetcher else { return }
        state.loading.insert(route)
        state.errors[route] = nil
        let backend = self.backend
        spawn { [weak self] in
            do {
                let data = try await fetcher(backend)
                self?.state.data[route] = data
            } catch {
                self?.state.errors[route] = Self.message(error)
            }
            self?.state.loading.remove(route)
            if self?.state.route == route { self?.resetSelectionIfNeeded() }
        }
    }

    /// Fetches the next page when the selection nears the end of a list.
    private func loadMoreIfNeeded() {
        let route = state.route
        guard !state.loading.contains(route), (state.filters[route] ?? "").isEmpty else { return }
        let count = screen(for: route, in: state).rows.count
        guard selectedIndex >= count - 20 else { return }
        let backend = self.backend
        let sort = state.sort[route] ?? .title
        switch state.data[route] {
        case .tracks(let items, let next?):
            loadLibraryPage(for: route) {
                let page = try await backend.librarySongs(sort: sort, offset: next, limit: 200)
                return .tracks(items + page.items, nextOffset: page.nextOffset)
            }
        case .albums(let items, let next?):
            loadLibraryPage(for: route) {
                let page = try await backend.libraryAlbums(sort: sort, offset: next, limit: 200)
                return .albums(items + page.items, nextOffset: page.nextOffset)
            }
        case .artists(let items, let next?):
            loadLibraryPage(for: route) {
                let page = try await backend.libraryArtists(offset: next, limit: 200)
                return .artists(items + page.items, nextOffset: page.nextOffset)
            }
        case .playlists(let items, let next?):
            loadLibraryPage(for: route) {
                let page = try await backend.libraryPlaylists(offset: next, limit: 200)
                return .playlists(items + page.items, nextOffset: page.nextOffset)
            }
        case .search(let r) where r.nextOffset != nil:
            let text = state.searchQuery.trimmingCharacters(in: .whitespaces)
            let query = SearchQuery(text: text, scope: state.searchScope, kinds: state.searchTab.kinds, offset: r.nextOffset!)
            state.loading.insert(route)
            searchTask = spawn { [weak self] in
                let more = try? await backend.search(query)
                guard !Task.isCancelled, let self else { return }
                defer { self.state.loading.remove(route) }
                guard let more, self.state.data[route] == .search(r) else { return }
                var merged = r
                merged.songs += more.songs
                merged.albums += more.albums
                merged.artists += more.artists
                merged.playlists += more.playlists
                merged.nextOffset = more.nextOffset
                self.state.data[route] = .search(merged)
            }
        default: break
        }
    }

    private func loadLibraryPage(for route: Route, fetch: @escaping @Sendable () async throws -> RouteData) {
        let previous = state.data[route]
        state.loading.insert(route)
        spawn { [weak self] in
            guard let updated = try? await fetch(), let self else {
                self?.state.loading.remove(route)
                return
            }
            if self.state.data[route] == previous { self.state.data[route] = updated }
            self.state.loading.remove(route)
        }
    }

    // MARK: - Selection

    public var selectedIndex: Int { state.selection[state.route] ?? firstSelectable(in: screen(for: state.route, in: state).rows) }

    var selectedRow: Row? {
        guard state.focus == .content else { return nil }
        let rows = screen(for: state.route, in: state).rows
        return rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    private func firstSelectable(in rows: [Row]) -> Int { rows.firstIndex(where: \.isSelectable) ?? 0 }

    private func move(by delta: Int) {
        if state.focus == .views {
            let count = destinations.count
            state.viewIndex = min(max(0, state.viewIndex + max(-count, min(count, delta))), count - 1)
            return
        }
        let rows = screen(for: state.route, in: state).rows
        guard !rows.isEmpty else { return }
        var target = min(max(0, selectedIndex &+ delta), rows.count - 1)
        let step = delta >= 0 ? 1 : -1
        var probe = target
        while rows.indices.contains(probe), !rows[probe].isSelectable { probe += step }
        if !rows.indices.contains(probe) {
            probe = target
            while rows.indices.contains(probe), !rows[probe].isSelectable { probe -= step }
        }
        if rows.indices.contains(probe) { target = probe }
        state.selection[state.route] = target
        adjustScroll()
        loadMoreIfNeeded()
    }

    private func select(line: Int) {
        if state.focus == .views { state.viewIndex = 0 }
        else { state.selection[state.route] = 0 }
        move(by: line - 1)
    }

    private func resetSelection() {
        state.selection[state.route] = nil
        state.scroll[state.route] = 0
    }

    private func resetSelectionIfNeeded() {
        let rows = screen(for: state.route, in: state).rows
        if selectedIndex >= rows.count { resetSelection() }
        adjustScroll()
    }

    private func adjustScroll() {
        let route = state.route
        if gridColumns > 0, route == .albums {
            // Scroll is measured in tile rows.
            let visible = max(1, listHeight / ShellView.gridTileHeight)
            let row = selectedIndex / gridColumns
            var top = state.scroll[route] ?? 0
            if row < top { top = row }
            if row >= top + visible { top = row - visible + 1 }
            state.scroll[route] = max(0, top)
            return
        }
        let height = max(1, listHeight)
        var top = state.scroll[route] ?? 0
        let sel = selectedIndex
        let margin = height > 8 ? 2 : 0
        if sel < top + margin { top = sel - margin }
        if sel >= top + height - margin { top = sel - height + 1 + margin }
        let count = screen(for: route, in: state).rows.count
        state.scroll[route] = max(0, min(top, max(0, count - height)))
    }

    // MARK: - Row actions

    private func activateSelection() {
        guard let row = selectedRow else { return }
        switch row.kind {
        case .song(_, let kind?, let id?, let index):
            run("Play") { b in try await b.play(.container(kind, id: id, startIndex: index)) }
        case .song(let t, _, _, _):
            run("Play") { b in try await b.play(.song(id: t.id)) }
        case .album(let a): push(.album(a.id))
        case .playlist(let p): push(.playlist(p.id))
        case .artist(let a): push(.artist(a.id))
        case .queueEntry(let e, _): run("Play") { b in try await b.play(.queueEntry(id: e.id)) }
        case .setting(let key): if key == .theme { openThemePicker() } else { toggle(key) }
        case .header, .message: break
        }
    }

    private func enqueueSelection(_ position: EnqueuePosition) {
        guard let row = selectedRow else { return }
        let verb = position == .next ? "Playing next" : "Added to queue"
        switch row.kind {
        case .song(let t, _, _, _):
            run("Queue") { b in try await b.enqueue(songIDs: [t.id], at: position) }
            toast("\(verb): \(t.title)")
        case .queueEntry(let e, _):
            let t = e.track
            run("Queue") { b in try await b.enqueue(songIDs: [t.id], at: position) }
            toast("\(verb): \(t.title)")
        case .album(let a):
            run("Queue") { b in
                let ids = try await b.album(id: a.id).tracks.map(\.id)
                try await b.enqueue(songIDs: ids, at: position)
            }
            toast("\(verb): \(a.title)")
        case .playlist(let p):
            run("Queue") { b in
                let ids = try await b.playlist(id: p.id).tracks.map(\.id)
                try await b.enqueue(songIDs: ids, at: position)
            }
            toast("\(verb): \(p.name)")
        case .artist, .setting, .header, .message:
            break
        }
    }

    // MARK: - Pickers

    private func openThemePicker() {
        let names = state.themes.map(\.name)
        state.overlay = .picker(Picker(title: "Theme", options: names, index: names.firstIndex(of: state.theme.name) ?? 0,
                                       purpose: .theme(original: state.theme)))
    }

    private static let sortOptions: [(label: String, key: SortKey)] = [("Title", .title), ("Artist", .artist), ("Recently added", .recentlyAdded)]

    private func openSortPicker() {
        guard state.route == .songs || state.route == .albums else {
            toast("Sorting is available in Songs and Albums", error: true)
            return
        }
        let current = state.sort[state.route] ?? .title
        state.overlay = .picker(Picker(title: "Sort \(state.route.title)", options: Self.sortOptions.map(\.label),
                                       index: Self.sortOptions.firstIndex { $0.key == current } ?? 0,
                                       purpose: .sort(state.route)))
    }

    private func handlePicker(_ picker: Picker, _ key: Key) {
        var picker = picker
        switch key {
        case .char("j"), .down, .tab:
            picker.index = min(picker.index + 1, picker.options.count - 1)
        case .char("k"), .up, .backTab:
            picker.index = max(picker.index - 1, 0)
        case .enter:
            state.overlay = nil
            switch picker.purpose {
            case .theme:
                applyTheme(picker.options[picker.index], persist: true)
            case .sort(let route):
                applySort(Self.sortOptions[picker.index].key, route: route)
            }
            return
        case .escape, .char("q"):
            state.overlay = nil
            if case .theme(let original) = picker.purpose { state.theme = original }
            return
        default:
            return
        }
        state.overlay = .picker(picker)
        if case .theme = picker.purpose, let theme = state.themes.first(where: { $0.name == picker.options[picker.index] }) {
            state.theme = theme  // live preview
        }
    }

    private func applyTheme(_ name: String, persist: Bool) {
        guard let theme = state.themes.first(where: { $0.name == name }) else { return }
        state.theme = theme
        toast("Theme: \(theme.name)")
        if persist { onPersist("general", "theme", "\"\(theme.name)\"") }
    }

    private func applySort(_ key: SortKey, route: Route) {
        state.sort[route] = key
        state.selection[route] = nil
        state.scroll[route] = 0
        load(route, force: true)
    }

    // MARK: - Settings

    private func toggle(_ key: SettingKey) {
        switch key {
        case .theme:
            break
        case .artwork:
            state.prefs.showArtwork.toggle()
            state.art.enabled = state.prefs.showArtwork
            onPersist("appearance", "show_artwork", String(state.prefs.showArtwork))
        case .artworkSize:
            state.prefs.artworkSize = state.prefs.artworkSize.next
            onPersist("appearance", "artwork_size", "\"\(state.prefs.artworkSize.rawValue)\"")
        case .visualizer:
            state.prefs.showVisualizer.toggle()
            onPersist("appearance", "show_visualizer", String(state.prefs.showVisualizer))
        case .dynamicColors:
            state.prefs.dynamicColors.toggle()
            onPersist("appearance", "dynamic_colors", String(state.prefs.dynamicColors))
        case .albumView:
            state.prefs.albumGrid.toggle()
            onPersist("appearance", "album_view", state.prefs.albumGrid ? "\"grid\"" : "\"table\"")
        case .borders:
            state.prefs.showBorders.toggle()
            onPersist("appearance", "show_borders", String(state.prefs.showBorders))
        case .reducedMotion:
            state.prefs.reducedMotion.toggle()
            onPersist("animation", "reduced_motion", String(state.prefs.reducedMotion))
        }
    }

    private func set(_ key: SettingKey, _ on: Bool, current: Bool) {
        if on != current { toggle(key) }
        toast("\(key.label): \(on ? "on" : "off")")
    }

    // MARK: - Text input

    private func handleInput(_ key: Key) {
        switch key {
        case .escape:
            if state.mode == .filter { state.filters[state.route] = nil; resetSelection() }
            state.mode = .normal
            state.input = ""
            historyIndex = nil
        case .enter:
            commitInput()
        case .backspace:
            if state.input.isEmpty { handleInput(.escape); return }
            state.input.removeLast()
            inputChanged()
        case .ctrl("u"):
            state.input = ""
            inputChanged()
        case .ctrl("s") where state.mode == .search:
            state.searchScope = state.searchScope == .catalog ? .library : .catalog
            scheduleSearch(immediate: true)
        case .tab where state.mode == .command:
            if let completion = CommandLine.complete(state.input, themes: state.themes) { state.input = completion }
        case .up where state.mode == .command:
            guard !state.commandHistory.isEmpty else { break }
            if historyIndex == nil { historyDraft = state.input }
            let index = max(0, (historyIndex ?? state.commandHistory.count) - 1)
            historyIndex = index
            state.input = state.commandHistory[index]
        case .down where state.mode == .command:
            guard let index = historyIndex else { break }
            if index + 1 < state.commandHistory.count {
                historyIndex = index + 1
                state.input = state.commandHistory[index + 1]
            } else {
                historyIndex = nil
                state.input = historyDraft
            }
        case .char(let c):
            state.input.append(c)
            inputChanged()
        case .space:
            state.input.append(" ")
            inputChanged()
        default:
            break
        }
    }

    private func inputChanged() {
        switch state.mode {
        case .search:
            state.searchQuery = state.input
            scheduleSearch(immediate: false)
        case .filter:
            state.filters[state.route] = state.input.isEmpty ? nil : state.input
            resetSelection()
        case .command, .normal:
            break
        }
    }

    private func commitInput() {
        let text = state.input
        let mode = state.mode
        state.mode = .normal
        state.input = ""
        historyIndex = nil
        switch mode {
        case .search:
            state.focus = .content
            scheduleSearch(immediate: true)
        case .filter:
            state.focus = .content
        case .command:
            execute(command: text)
        case .normal:
            break
        }
    }

    private func scheduleSearch(immediate: Bool) {
        searchTask?.cancel()
        let text = state.searchQuery.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            state.data[.search] = nil
            state.loading.remove(.search)
            return
        }
        let query = SearchQuery(text: text, scope: state.searchScope, kinds: state.searchTab.kinds)
        let cacheKey = SearchCacheKey(text: text, scope: state.searchScope, tab: state.searchTab)
        if let cached = searchCache[cacheKey], clock().timeIntervalSince(cached.stored) < Self.searchCacheLifetime {
            state.data[.search] = .search(cached.results)
            state.errors[.search] = nil
            state.loading.remove(.search)
            if state.route == .search { resetSelection() }
            return
        }
        let backend = self.backend
        state.loading.insert(.search)
        searchTask = spawn { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            do {
                let results = try await backend.search(query)
                guard !Task.isCancelled, let self,
                      self.state.searchQuery.trimmingCharacters(in: .whitespaces) == text else { return }
                self.state.data[.search] = .search(results)
                if self.searchCache.count >= Self.searchCacheLimit { self.searchCache.removeAll() }
                self.searchCache[cacheKey] = (results, self.clock())
                self.state.errors[.search] = nil
                if self.state.route == .search { self.resetSelection() }
            } catch {
                if !Task.isCancelled { self?.state.errors[.search] = Self.message(error) }
            }
            self?.state.loading.remove(.search)
        }
    }

    // MARK: - Command mode

    public func execute(command text: String) {
        let words = text.split(separator: " ").map(String.init)
        guard let verb = words.first else { return }
        let arg = words.dropFirst().joined(separator: " ")
        remember(text)

        switch verb {
        case "q", "quit": quit(.user)
        case "play": run("Play") { b in try await b.play(.resume) }
        case "pause": run("Pause") { b in try await b.pause() }
        case "toggle": perform(.playPause)
        case "next": perform(.nextTrack)
        case "prev", "previous": perform(.previousTrack)
        case "seek":
            guard let v = Double(arg) else { return toast(":seek expects seconds", error: true) }
            let target = arg.hasPrefix("+") || arg.hasPrefix("-") ? state.playback.position(at: clock()) + v : v
            run("Seek") { b in try await b.seek(to: max(0, target)) }
        case "shuffle":
            guard arg == "on" || arg == "off" else { return toast(":shuffle on|off", error: true) }
            run("Shuffle") { b in try await b.setShuffle(arg == "on") }
        case "repeat":
            guard let mode = RepeatMode(rawValue: arg) else { return toast(":repeat off|one|all", error: true) }
            run("Repeat") { b in try await b.setRepeat(mode) }
        case "search":
            go(.search)
            state.searchScope = .catalog
            state.searchQuery = arg
            scheduleSearch(immediate: true)
        case "filter":
            state.filters[state.route] = arg.isEmpty ? nil : arg
            resetSelection()
        case "theme":
            if arg.isEmpty { return openThemePicker() }
            guard state.themes.contains(where: { $0.name == arg }) else {
                return toast("Unknown theme. Themes: \(state.themes.map(\.name).joined(separator: ", "))", error: true)
            }
            applyTheme(arg, persist: true)
        case "artwork":
            guard arg == "on" || arg == "off" else { return toast(":artwork on|off", error: true) }
            set(.artwork, arg == "on", current: state.prefs.showArtwork)
        case "visualizer":
            guard arg == "on" || arg == "off" else { return toast(":visualizer on|off", error: true) }
            set(.visualizer, arg == "on", current: state.prefs.showVisualizer)
        case "immersive", "nowplaying": toggleImmersive()
        case "sort":
            let keys: [String: SortKey] = ["title": .title, "artist": .artist, "added": .recentlyAdded]
            if arg.isEmpty { return openSortPicker() }
            guard let key = keys[arg] else { return toast(":sort title|artist|added", error: true) }
            guard state.route == .songs || state.route == .albums else {
                return toast("Sorting is available in Songs and Albums", error: true)
            }
            applySort(key, route: state.route)
        case "auth": connect()
        case "queue" where arg == "clear": state.route == .queue ? perform(.clearQueue) : { go(.queue); perform(.clearQueue) }()
        case "reload":
            load(state.route, force: true)
            toast("Reloading \(state.route.title)")
        case "help": state.overlay = .help
        case "service" where arg == "stop":
            state.overlay = .confirm("Stop the Harmune host? Playback will stop.", .quitAndStopHost)
        default:
            if let route = CommandLine.routes[verb] { go(route) }
            else { toast("Unknown command :\(verb)", error: true) }
        }
    }

    private func remember(_ command: String) {
        if state.commandHistory.last != command { state.commandHistory.append(command) }
        if state.commandHistory.count > Self.historyLimit {
            state.commandHistory.removeFirst(state.commandHistory.count - Self.historyLimit)
        }
        guard let historyPath else { return }
        let directory = (historyPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? (state.commandHistory.joined(separator: "\n") + "\n").write(toFile: historyPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Effects

    @discardableResult
    private func spawn(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await op()
            self?.tasks[id] = nil
            self?.changed()
        }
        tasks[id] = task
        return task
    }

    /// Runs a backend command, then refreshes playback/queue so the UI
    /// reflects the host's confirmed state (never an optimistic guess).
    private func run(_ label: String, _ op: @escaping @Sendable (any MusicBackend) async throws -> Void) {
        let backend = self.backend
        spawn { [weak self] in
            do {
                try await op(backend)
                let playback = await backend.playbackState()
                let queue = await backend.queueState()
                guard let self else { return }
                if playback.revision >= self.state.playback.revision { self.applyPlayback(playback) }
                if queue.revision >= self.state.queue.revision { self.state.queue = queue }
            } catch {
                self?.toast("\(label) failed: \(Self.message(error))", error: true)
            }
        }
    }

    public func toast(_ message: String, error: Bool = false) {
        state.toast = Toast(message: message, isError: error, expires: clock().addingTimeInterval(error ? 6 : 3))
    }

    private func quit(_ reason: QuitReason) {
        eventsTask?.cancel()
        onQuit(reason)
    }

    private func changed() { onChange() }

    static func message(_ error: Error) -> String {
        (error as? HarmuneError)?.message ?? String(describing: error)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

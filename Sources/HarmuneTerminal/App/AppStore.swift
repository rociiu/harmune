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

    private let reconnect: (@Sendable () async throws -> any MusicBackend)?
    private var resolver = KeyResolver()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private let clock: () -> Date

    public init(backend: any MusicBackend, theme: Theme = .midnight,
                reconnect: (@Sendable () async throws -> any MusicBackend)? = nil,
                clock: @escaping () -> Date = { Date() }) {
        self.backend = backend
        self.reconnect = reconnect
        self.clock = clock
        state.theme = theme
        state.now = clock()
    }

    // MARK: - Lifecycle

    public func start() async {
        await refreshSession()
        subscribe()
        load(.home)
        changed()
    }

    /// Waits until every in-flight effect has finished (for tests).
    public func settle() async {
        while let task = tasks.values.first { await task.value }
    }

    /// Called by the run loop on a timer. Returns true when a redraw is due.
    @discardableResult
    public func tick() -> Bool {
        state.now = clock()
        var dirty = false
        if let toast = state.toast, toast.expires <= state.now { state.toast = nil; dirty = true }
        if let resolution = resolver.expire(context: keyContext, at: state.now) {
            state.pendingKeys = ""
            if case .command(let c, let n) = resolution { perform(c, count: n) }
            dirty = true
        }
        return dirty || state.playback.isPlaying || state.route == .nowPlaying
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
        case .playback(let p) where p.revision >= state.playback.revision: state.playback = p
        case .queue(let q) where q.revision >= state.queue.revision: state.queue = q
        case .auth(let a): state.auth = a
        default: return
        }
        changed()
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
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 4)
        }
    }

    // MARK: - Keys

    private var keyContext: KeyContext {
        state.focus == .sidebar ? .list : state.route.keyContext
    }

    public func handle(_ key: Key) {
        state.now = clock()
        if key == .ctrl("c") { quit(.user); return }

        if let overlay = state.overlay {
            switch overlay {
            case .help:
                state.overlay = nil
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
        case .moveDown, .filterNext: move(by: n)
        case .moveUp, .filterPrevious: move(by: -n)
        case .moveLeft: move(by: -n)
        case .moveRight: move(by: n)
        case .moveFirst: if let count { select(line: count) } else { move(by: Int.min / 2) }
        case .moveLast: if let count { select(line: count) } else { move(by: Int.max / 2) }
        case .halfPageDown: move(by: max(1, listHeight / 2) * n)
        case .halfPageUp: move(by: -max(1, listHeight / 2) * n)

        case .focusNext, .focusPrevious:
            state.focus = state.focus == .sidebar ? .content : .sidebar
            if state.focus == .sidebar { syncSidebarIndex() }
        case .goBack:
            if state.focus == .sidebar { break }
            if state.stack.count > 1 { pop() } else { state.focus = .sidebar; syncSidebarIndex() }
        case .openSelected:
            if state.focus == .sidebar {
                if let route = Route.sidebar.compactMap({ $0 })[safe: state.sidebarIndex] { go(route) }
            } else {
                activateSelection()
            }
        case .close:
            if let filter = state.filters[state.route], !filter.isEmpty {
                state.filters[state.route] = nil
                resetSelection()
            } else if state.stack.count > 1 {
                pop()
            } else if state.focus == .sidebar {
                state.focus = .content
            }
        case .quit:
            if state.stack.count > 1 { pop() } else { quit(.user) }

        case .search:
            state.searchScope = state.route.isLibrary ? .library : .catalog
            if state.route != .search { go(.search) }
            state.mode = .search
            state.input = state.searchQuery
        case .filter:
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
            if state.route == .nowPlaying { pop() } else { push(.nowPlaying) }
        case .favorites, .recentlyPlayed:
            toast("\(command == .favorites ? "Favorites" : "Recently Played") isn't available yet", error: true)
        case .settings:
            toast("Settings arrive in a later release; edit ~/.config/harmune/config.toml", error: false)
        case .tabPrevious, .tabNext:
            if state.route == .search {
                state.searchScope = state.searchScope == .catalog ? .library : .catalog
                scheduleSearch(immediate: true)
                toast("Searching \(state.searchScope == .catalog ? "Apple Music" : "your library")")
            }
        case .sort, .toggleLayout:
            toast("\(command == .sort ? "Sorting" : "Grid view") isn't available yet", error: true)

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
            if !state.capabilities.contains(.favorites) { toast("Favorites aren't supported by this backend", error: true) }
            else { toast("Favorites aren't available yet", error: true) }

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
        syncSidebarIndex()
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

    private func syncSidebarIndex() {
        let items = Route.sidebar.compactMap { $0 }
        if let i = items.firstIndex(of: state.stack.first ?? .home) { state.sidebarIndex = i }
    }

    public func load(_ route: Route, force: Bool = false) {
        if !force, state.data[route] != nil || state.loading.contains(route) { return }
        let fetcher: (@Sendable (any MusicBackend) async throws -> RouteData)?
        switch route {
        case .home: fetcher = { .home(try await $0.home()) }
        case .songs: fetcher = { b in let p = try await b.librarySongs(sort: .title, offset: 0, limit: 200); return .tracks(p.items, nextOffset: p.nextOffset) }
        case .albums: fetcher = { b in let p = try await b.libraryAlbums(sort: .title, offset: 0, limit: 200); return .albums(p.items, nextOffset: p.nextOffset) }
        case .artists: fetcher = { .artists(try await $0.libraryArtists(offset: 0, limit: 200).items) }
        case .playlists: fetcher = { .playlists(try await $0.libraryPlaylists(offset: 0, limit: 200).items) }
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
        case .nowPlaying: fetcher = nil
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
        switch state.data[route] {
        case .tracks(let items, let next?):
            state.loading.insert(route)
            spawn { [weak self] in
                if let p = try? await backend.librarySongs(sort: .title, offset: next, limit: 200) {
                    self?.state.data[route] = .tracks(items + p.items, nextOffset: p.nextOffset)
                }
                self?.state.loading.remove(route)
            }
        case .albums(let items, let next?):
            state.loading.insert(route)
            spawn { [weak self] in
                if let p = try? await backend.libraryAlbums(sort: .title, offset: next, limit: 200) {
                    self?.state.data[route] = .albums(items + p.items, nextOffset: p.nextOffset)
                }
                self?.state.loading.remove(route)
            }
        case .search(let r) where r.nextOffset != nil:
            let query = SearchQuery(text: state.searchQuery, scope: state.searchScope, kinds: [.songs], offset: r.nextOffset!)
            state.loading.insert(route)
            spawn { [weak self] in
                if let more = try? await backend.search(query), self?.state.searchQuery == query.text {
                    var merged = r
                    merged.songs += more.songs
                    merged.nextOffset = more.nextOffset
                    self?.state.data[route] = .search(merged)
                }
                self?.state.loading.remove(route)
            }
        default: break
        }
    }

    // MARK: - Selection

    public var selectedIndex: Int { state.selection[state.route] ?? firstSelectable(in: screen(for: state.route, in: state).rows) }

    var selectedRow: Row? {
        let rows = screen(for: state.route, in: state).rows
        return rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    private func firstSelectable(in rows: [Row]) -> Int { rows.firstIndex(where: \.isSelectable) ?? 0 }

    private func move(by delta: Int) {
        if state.focus == .sidebar {
            let count = Route.sidebar.compactMap { $0 }.count
            state.sidebarIndex = min(max(0, state.sidebarIndex + max(-count, min(count, delta))), count - 1)
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
        state.selection[state.route] = 0
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
        case .artist, .header, .message:
            break
        }
    }

    // MARK: - Text input

    private func handleInput(_ key: Key) {
        switch key {
        case .escape:
            if state.mode == .filter { state.filters[state.route] = nil; resetSelection() }
            state.mode = .normal
            state.input = ""
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
            if let completion = CommandLine.complete(state.input) { state.input = completion }
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
        let query = SearchQuery(text: text, scope: state.searchScope)
        let backend = self.backend
        searchTask = spawn { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            self?.state.loading.insert(.search)
            do {
                let results = try await backend.search(query)
                guard !Task.isCancelled, let self,
                      self.state.searchQuery.trimmingCharacters(in: .whitespaces) == text else { return }
                self.state.data[.search] = .search(results)
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
        state.commandHistory.append(text)

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
            guard let theme = Theme.named(arg) else {
                return toast("Themes: \(Theme.all.map(\.name).joined(separator: ", "))", error: arg.isEmpty ? false : true)
            }
            state.theme = theme
            toast("Theme: \(theme.name)")
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

    enum CommandLine {
        static let routes: [String: Route] = [
            "home": .home, "search": .search, "songs": .songs, "library": .songs, "albums": .albums,
            "artists": .artists, "playlists": .playlists, "queue": .queue, "nowplaying": .nowPlaying,
        ]
        static let verbs = ["quit", "play", "pause", "toggle", "next", "previous", "seek", "shuffle", "repeat",
                            "search", "filter", "theme", "queue", "reload", "help", "service", "home", "songs",
                            "library", "albums", "artists", "playlists", "nowplaying"]

        static func complete(_ input: String) -> String? {
            guard !input.contains(" ") else { return nil }
            let matches = verbs.filter { $0.hasPrefix(input) }
            guard let first = matches.first else { return nil }
            if matches.count == 1 { return first + " " }
            // Longest common prefix.
            var prefix = first
            for m in matches.dropFirst() { while !m.hasPrefix(prefix) { prefix.removeLast() } }
            return prefix
        }
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
                if playback.revision >= self.state.playback.revision { self.state.playback = playback }
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

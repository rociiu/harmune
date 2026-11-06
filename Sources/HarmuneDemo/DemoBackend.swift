import Foundation
import HarmuneCore

/// In-process `MusicBackend` with a simulated playback clock.
///
/// Used by `harmune --demo`, the development host and all UI tests, so
/// contributors never need an Apple Developer account or subscription.
public actor DemoBackend: MusicBackend {
    public let library: DemoLibrary
    private let now: @Sendable () -> Date
    private let latency: Duration

    private var playback = PlaybackState.idle
    private var queue = QueueState()
    private var unshuffledOrder: [String] = []
    private var entryCounter = 0
    private var subscribers: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]
    private var ticker: Task<Void, Never>?

    /// - Parameters:
    ///   - now: injectable clock for tests.
    ///   - latency: simulated network latency for browse calls.
    ///   - autoTick: advance tracks automatically in real time.
    public init(library: DemoLibrary = .standard, now: @escaping @Sendable () -> Date = { Date() },
                latency: Duration = .zero, autoTick: Bool = true) {
        self.library = library
        self.now = now
        self.latency = latency
        if autoTick {
            Task { await self.startTicker() }
            let keys = library.artworkKeys
            Task.detached(priority: .utility) { DemoArtwork.ensureGenerated(keys: keys) }
        }
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.tick()
            }
        }
    }

    // MARK: - Session

    public func capabilities() -> Set<Capability> { Set(Capability.allCases) }
    public func authStatus() -> AuthStatus { AuthStatus(state: .authorized) }
    public func requestAuthorization() -> AuthStatus { AuthStatus(state: .authorized) }

    public func playbackState() -> PlaybackState { playback }
    public func queueState() -> QueueState { queue }

    public func events() -> AsyncStream<BackendEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BackendEvent.self, bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    // MARK: - Clock

    /// Advances to the next track when the current one has ended.
    public func tick() {
        guard playback.isPlaying, let track = playback.track else { return }
        if playback.position(at: now()) >= track.duration - 0.05 {
            trackEnded()
        }
    }

    private func trackEnded() {
        guard let index = queue.currentIndex else { return }
        if playback.repeat == .one {
            setCurrent(index: index, playing: true)
        } else if index + 1 < queue.entries.count {
            setCurrent(index: index + 1, playing: true)
        } else if playback.repeat == .all, !queue.entries.isEmpty {
            setCurrent(index: 0, playing: true)
        } else {
            setCurrent(index: index, playing: false)
        }
    }

    // MARK: - Playback

    public func play(_ request: PlayRequest) async throws {
        switch request {
        case .song(let id):
            guard let track = library.tracksByID[id] else { throw HarmuneError.notFound("Song \(id)") }
            replaceQueue([track], container: nil, start: 0)
        case .container(let kind, let id, let startIndex):
            let tracks: [Track], title: String
            switch kind {
            case .album:
                guard let album = library.albumsByID[id] else { throw HarmuneError.notFound("Album \(id)") }
                tracks = library.tracks(inAlbum: id); title = album.title
            case .playlist:
                guard let p = library.playlists.first(where: { $0.id == id }) else { throw HarmuneError.notFound("Playlist \(id)") }
                tracks = library.tracks(inPlaylist: id); title = p.name
            }
            guard tracks.indices.contains(startIndex) else { throw HarmuneError.invalid("startIndex out of range") }
            replaceQueue(tracks, container: ContainerRef(kind: kind, id: id, title: title), start: startIndex)
        case .queueEntry(let entryID):
            guard let index = queue.entries.firstIndex(where: { $0.id == entryID }) else {
                throw HarmuneError.notFound("Queue entry \(entryID)")
            }
            setCurrent(index: index, playing: true)
        case .resume:
            guard playback.track != nil else { throw HarmuneError.invalid("Nothing to resume") }
            if !playback.isPlaying { updatePlayback { $0.isPlaying = true } }
        }
    }

    public func pause() {
        guard playback.isPlaying else { return }
        updatePlayback { $0.isPlaying = false }
    }

    public func togglePlayPause() async throws {
        if playback.isPlaying { pause() } else { try await play(.resume) }
    }

    public func next() throws {
        guard let index = queue.currentIndex else { throw HarmuneError.invalid("Queue is empty") }
        if index + 1 < queue.entries.count {
            setCurrent(index: index + 1, playing: playback.isPlaying)
        } else if playback.repeat == .all {
            setCurrent(index: 0, playing: playback.isPlaying)
        } else {
            setCurrent(index: index, playing: false)
        }
    }

    public func previous() throws {
        guard let index = queue.currentIndex else { throw HarmuneError.invalid("Queue is empty") }
        if playback.position(at: now()) > 3 || index == 0 {
            updatePlayback { $0.position = 0 }
        } else {
            setCurrent(index: index - 1, playing: playback.isPlaying)
        }
    }

    public func seek(to position: TimeInterval) throws {
        guard let track = playback.track else { throw HarmuneError.invalid("Nothing is playing") }
        updatePlayback { $0.position = min(max(0, position), track.duration) }
    }

    public func setShuffle(_ on: Bool) {
        guard on != playback.shuffle else { return }
        let current = queue.currentIndex ?? -1
        let head = Array(queue.entries.prefix(current + 1))
        var upcoming = Array(queue.entries.dropFirst(current + 1))
        if on {
            unshuffledOrder = queue.entries.map(\.id)
            upcoming.shuffle()
        } else {
            let order = Dictionary(unshuffledOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            upcoming.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        }
        updateQueue { $0.entries = head + upcoming }
        updatePlayback { $0.shuffle = on }
    }

    public func setRepeat(_ mode: RepeatMode) {
        updatePlayback { $0.repeat = mode }
    }

    // MARK: - Queue

    public func enqueue(songIDs: [String], at position: EnqueuePosition) throws {
        let tracks = try songIDs.map { id in
            guard let t = library.tracksByID[id] else { throw HarmuneError.notFound("Song \(id)") }
            return t
        }
        let entries = tracks.map(makeEntry)
        let wasEmpty = queue.entries.isEmpty
        updateQueue { q in
            switch position {
            case .last: q.entries.append(contentsOf: entries)
            case .next: q.entries.insert(contentsOf: entries, at: min((q.currentIndex ?? -1) + 1, q.entries.count))
            }
        }
        unshuffledOrder.append(contentsOf: entries.map(\.id))
        if wasEmpty { setCurrent(index: 0, playing: false) }
    }

    public func removeFromQueue(entryID: String) throws {
        guard let index = queue.entries.firstIndex(where: { $0.id == entryID }) else {
            throw HarmuneError.notFound("Queue entry \(entryID)")
        }
        guard index != queue.currentIndex else { throw HarmuneError.invalid("Cannot remove the playing entry") }
        updateQueue { q in
            q.entries.remove(at: index)
            if let c = q.currentIndex, index < c { q.currentIndex = c - 1 }
        }
    }

    public func moveQueueEntry(entryID: String, to target: Int) throws {
        guard let from = queue.entries.firstIndex(where: { $0.id == entryID }) else {
            throw HarmuneError.notFound("Queue entry \(entryID)")
        }
        let current = queue.currentIndex ?? -1
        guard from > current, target > current, target < queue.entries.count else {
            throw HarmuneError.invalid("Only upcoming entries can be moved")
        }
        updateQueue { q in
            let entry = q.entries.remove(at: from)
            q.entries.insert(entry, at: target)
        }
    }

    public func clearUpcoming() {
        let keep = (queue.currentIndex ?? -1) + 1
        updateQueue { $0.entries = Array($0.entries.prefix(keep)) }
    }

    // MARK: - Browse

    public func search(_ query: SearchQuery) async throws -> SearchResults {
        try await simulateLatency()
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return SearchResults() }
        func matches(_ fields: String...) -> Bool { fields.contains { $0.localizedCaseInsensitiveContains(text) } }

        let songs = library.tracks.filter { matches($0.title, $0.artist, $0.album) }
        let page = Array(songs.dropFirst(query.offset).prefix(query.limit))
        let more = query.offset + page.count < songs.count
        let firstPage = query.offset == 0
        return SearchResults(
            songs: query.kinds.contains(.songs) ? page : [],
            albums: firstPage && query.kinds.contains(.albums) ? library.albums.filter { matches($0.title, $0.artist) } : [],
            artists: firstPage && query.kinds.contains(.artists) ? library.artists.filter { matches($0.name) } : [],
            playlists: firstPage && query.kinds.contains(.playlists) ? library.playlists.filter { matches($0.name) } : [],
            nextOffset: query.kinds.contains(.songs) && more ? query.offset + page.count : nil)
    }

    public func librarySongs(sort: SortKey, offset: Int, limit: Int) async throws -> Page<Track> {
        try await simulateLatency()
        let sorted: [Track] = switch sort {
        case .title: library.tracks.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .artist: library.tracks.sorted { ($0.artist, $0.album, $0.trackNumber ?? 0) < ($1.artist, $1.album, $1.trackNumber ?? 0) }
        case .recentlyAdded: library.tracks.reversed()
        }
        return paginate(sorted, offset: offset, limit: limit)
    }

    public func libraryAlbums(sort: SortKey, offset: Int, limit: Int) async throws -> Page<Album> {
        try await simulateLatency()
        let sorted: [Album] = switch sort {
        case .title: library.albums.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .artist: library.albums.sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
        case .recentlyAdded: library.albums.reversed()
        }
        return paginate(sorted, offset: offset, limit: limit)
    }

    public func libraryArtists(offset: Int, limit: Int) async throws -> Page<Artist> {
        try await simulateLatency()
        return paginate(library.artists.sorted { $0.name < $1.name }, offset: offset, limit: limit)
    }

    public func libraryPlaylists(offset: Int, limit: Int) async throws -> Page<Playlist> {
        try await simulateLatency()
        return paginate(library.playlists, offset: offset, limit: limit)
    }

    public func album(id: String) async throws -> AlbumDetail {
        try await simulateLatency()
        guard let album = library.albumsByID[id] else { throw HarmuneError.notFound("Album \(id)") }
        return AlbumDetail(album: album, tracks: library.tracks(inAlbum: id))
    }

    public func artist(id: String) async throws -> ArtistDetail {
        try await simulateLatency()
        guard let artist = library.artists.first(where: { $0.id == id }) else { throw HarmuneError.notFound("Artist \(id)") }
        let albums = library.albums.filter { $0.artist == artist.name }
        let songs = library.tracks.filter { $0.artist == artist.name }
        return ArtistDetail(artist: artist, topSongs: Array(songs.prefix(10)), albums: albums)
    }

    public func playlist(id: String) async throws -> PlaylistDetail {
        try await simulateLatency()
        guard let p = library.playlists.first(where: { $0.id == id }) else { throw HarmuneError.notFound("Playlist \(id)") }
        return PlaylistDetail(playlist: p, tracks: library.tracks(inPlaylist: id))
    }

    public func favorites() -> Favorites {
        Favorites(songs: Array(library.tracks.prefix(6)), albums: Array(library.albums.suffix(6)))
    }

    public func home() async throws -> HomeSections {
        try await simulateLatency()
        return HomeSections(recentlyPlayed: Array(library.albums.prefix(6)),
                            madeForYou: Array(library.playlists.prefix(5)),
                            favoriteAlbums: Array(library.albums.suffix(6)))
    }

    // MARK: - Helpers

    private func simulateLatency() async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
    }

    private func paginate<T>(_ items: [T], offset: Int, limit: Int) -> Page<T> {
        let slice = Array(items.dropFirst(offset).prefix(limit))
        let end = offset + slice.count
        return Page(items: slice, nextOffset: end < items.count ? end : nil)
    }

    private func makeEntry(_ track: Track) -> QueueEntry {
        entryCounter += 1
        return QueueEntry(id: "q\(entryCounter)", track: track)
    }

    private func replaceQueue(_ tracks: [Track], container: ContainerRef?, start: Int) {
        let entries = tracks.map(makeEntry)
        unshuffledOrder = entries.map(\.id)
        updateQueue { $0.entries = entries; $0.currentIndex = nil }
        updatePlayback { $0.container = container; $0.shuffle = false }
        setCurrent(index: start, playing: true)
    }

    private func setCurrent(index: Int, playing: Bool) {
        if queue.currentIndex != index { updateQueue { $0.currentIndex = index } }
        let track = queue.entries.indices.contains(index) ? queue.entries[index].track : nil
        updatePlayback { s in
            s.track = track
            s.position = 0
            s.isPlaying = playing && track != nil
        }
    }

    /// Re-anchors the clock, applies the change and broadcasts it.
    private func updatePlayback(_ change: (inout PlaybackState) -> Void) {
        let t = now()
        playback.position = playback.position(at: t)
        playback.positionTimestamp = t
        change(&playback)
        playback.rate = playback.isPlaying ? 1 : 0
        playback.revision += 1
        broadcast(.playback(playback))
    }

    private func updateQueue(_ change: (inout QueueState) -> Void) {
        change(&queue)
        queue.revision += 1
        broadcast(.queue(queue))
    }

    private func broadcast(_ event: BackendEvent) {
        for c in subscribers.values { c.yield(event) }
    }
}

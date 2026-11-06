import AppKit
import Combine
import Foundation
import HarmuneCore
// MusicKit's player classes aren't marked Sendable, but their async methods
// are designed to be called like this; every call starts on the main actor.
@preconcurrency import MusicKit

/// `MusicBackend` over Apple's MusicKit, using the app's own
/// `ApplicationMusicPlayer` so playback doesn't depend on Music.app.
///
/// Runs only inside the signed host app. Every call logs its outcome to
/// `HostLog`, because the host has no terminal and these logs are the
/// evidence for the Phase 0 checks.
@MainActor
public final class MusicKitBackend: MusicBackend {
    private let player = ApplicationMusicPlayer.shared
    private let map: Mapping

    private var playback = PlaybackState.idle
    private var queue = QueueState()
    private var container: ContainerRef?
    private var revision: UInt64 = 0
    private var ticks = 0

    private var subscribers: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]
    private var stateObserver: AnyCancellable?
    private var queueObserver: AnyCancellable?
    private weak var observedQueue: ApplicationMusicPlayer.Queue?
    private var refreshScheduled = false
    private var ticker: Task<Void, Never>?

    public init() {
        map = Mapping(artwork: ArtworkStore())
        stateObserver = player.state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        observeQueue()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    // MARK: - Session

    /// Queue removal and reordering stay off until Phase 0 check V11 shows
    /// they work. Favorites have no MusicKit API in this backend yet.
    public func capabilities() -> Set<Capability> {
        [.recommendations, .recentlyPlayed, .librarySearch]
    }

    public func authStatus() async -> AuthStatus {
        let status = MusicAuthorization.currentStatus
        var canPlay: Bool?
        if status == .authorized { canPlay = try? await MusicSubscription.current.canPlayCatalogContent }
        return AuthMapping.state(status: status, canPlayCatalog: canPlay)
    }

    public func requestAuthorization() async -> AuthStatus {
        // The host has no windows, so it must come forward for the system prompt.
        NSApplication.shared.activate()
        let result = await MusicAuthorization.request()
        HostLog.write("auth: request returned \(result)")
        let status = await authStatus()
        emit(.auth(status))
        return status
    }

    private func requireAuthorized() throws {
        guard MusicAuthorization.currentStatus == .authorized else {
            throw HarmuneError(.notAuthorized, "Harmune isn't authorized for Apple Music. Run: harmune auth")
        }
    }

    /// Runs a MusicKit call: checks authorization, logs the timing and
    /// outcome, and turns failures into errors clients can show.
    private func call<T: Sendable>(_ label: String, _ body: @MainActor () async throws -> T) async throws -> T {
        let start = Date()
        do {
            try requireAuthorized()
            let value = try await body()
            HostLog.write("\(label): ok in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            return value
        } catch {
            HostLog.write("\(label): FAILED after \(Int(Date().timeIntervalSince(start) * 1000)) ms: \(String(reflecting: error))")
            throw Self.translate(error, label: label)
        }
    }

    private static func translate(_ error: Error, label: String) -> HarmuneError {
        if let e = error as? HarmuneError { return e }
        if let e = error as? MusicTokenRequestError {
            switch e {
            case .developerTokenRequestFailed:
                let id = Bundle.main.bundleIdentifier ?? "this app"
                return HarmuneError(.unavailable, "Apple refused a developer token. Check that the MusicKit App Service is enabled for \(id), and that the app is signed by the same team.")
            case .userNotSignedIn:
                return HarmuneError(.notAuthorized, "Sign in to your Apple Account in the Music app first.")
            case .privacyAcknowledgementRequired:
                return HarmuneError(.notAuthorized, "Open the Music app once to accept Apple's privacy notice.")
            case .permissionDenied:
                return HarmuneError(.notAuthorized, "Apple Music permission was denied.")
            default:
                return HarmuneError(.unavailable, "Apple Music token error: \(e.localizedDescription)")
            }
        }
        // When Apple answers 401 with an empty body, MusicKit fails to parse it
        // and surfaces a DecodingError. The 401 itself only reaches the system log.
        if error is DecodingError {
            let id = Bundle.main.bundleIdentifier ?? "this app"
            return HarmuneError(.unavailable, "\(label) failed: Apple Music sent an unreadable response, usually because it rejected this app's developer token. Check that MusicKit is enabled for \(id). See docs/PHASE0_SETUP.md.")
        }
        return HarmuneError(.unavailable, "\(label) failed: \(error.localizedDescription)")
    }

    // MARK: - State

    public func playbackState() -> PlaybackState {
        refresh()
        return playback
    }

    public func queueState() -> QueueState {
        refreshQueue()
        return queue
    }

    public func events() -> AsyncStream<BackendEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BackendEvent.self, bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    private func emit(_ event: BackendEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // objectWillChange fires before the value changes, so read a moment later.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            refreshScheduled = false
            refresh()
            refreshQueue()
        }
    }

    private func observeQueue() {
        let current = player.queue
        guard current !== observedQueue else { return }
        observedQueue = current
        queueObserver = current.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    /// The fallback for any change the observers miss, plus a resync every
    /// 5 s while playing so clients' clocks can't drift for long.
    private func tick() {
        ticks += 1
        observeQueue()
        if ticks % 5 == 0 {
            refreshQueue()
            refresh(force: playback.isPlaying)
        } else {
            refresh()
        }
    }

    private func snapshot() -> PlaybackState {
        let status = player.state.playbackStatus
        let isPlaying = status == .playing
        let repeatMode: RepeatMode
        switch player.state.repeatMode {
        case .one: repeatMode = .one
        case .all: repeatMode = .all
        default: repeatMode = .off
        }
        return PlaybackState(track: player.queue.currentEntry.map { map.track($0, fetchArtwork: true) }, isPlaying: isPlaying,
                             position: player.playbackTime, positionTimestamp: Date(), rate: isPlaying ? 1 : 0,
                             shuffle: player.state.shuffleMode == .songs, repeat: repeatMode,
                             container: container, revision: revision)
    }

    private func refresh(force: Bool = false) {
        var next = snapshot()
        guard force || PlaybackDiff.shouldPublish(previous: playback, next: next) else { return }
        revision += 1
        next.revision = revision
        playback = next
        emit(.playback(next))
    }

    private func refreshQueue() {
        let entries = player.queue.entries
        let current = player.queue.currentEntry
        let ids = entries.map(\.id)
        let index = current.flatMap { ids.firstIndex(of: $0.id) }
        guard ids != queue.entries.map(\.id) || index != queue.currentIndex else { return }
        revision += 1
        queue = QueueState(entries: entries.map(map.queueEntry), currentIndex: index, revision: revision)
        emit(.queue(queue))
    }

    private func changed() {
        observeQueue()
        refresh()
        refreshQueue()
    }

    // MARK: - Playback

    public func play(_ request: PlayRequest) async throws {
        try await call("play \(request)") {
            switch request {
            case .song(let id):
                let song = try await song(id)
                player.queue = ApplicationMusicPlayer.Queue(for: [song])
                container = nil
            case .container(let kind, let id, let startIndex):
                let (tracks, title) = try await containerTracks(kind, id)
                guard tracks.indices.contains(startIndex) else { throw HarmuneError.invalid("Track number out of range") }
                player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: tracks[startIndex])
                container = ContainerRef(kind: kind, id: id, title: title)
            case .queueEntry(let entryID):
                guard let entry = player.queue.entries.first(where: { $0.id == entryID }) else {
                    throw HarmuneError.notFound("Queue entry \(entryID)")
                }
                player.queue.currentEntry = entry
            case .resume:
                guard player.queue.currentEntry != nil else { throw HarmuneError.invalid("Nothing to resume") }
            }
            try await player.play()
            changed()
        }
    }

    public func pause() async throws {
        try await call("pause") {
            player.pause()
            changed()
        }
    }

    public func togglePlayPause() async throws {
        if player.state.playbackStatus == .playing {
            try await pause()
        } else {
            try await play(.resume)
        }
    }

    public func next() async throws {
        try await call("next") {
            try await player.skipToNextEntry()
            changed()
        }
    }

    public func previous() async throws {
        try await call("previous") {
            try await player.skipToPreviousEntry()
            changed()
        }
    }

    public func seek(to position: TimeInterval) async throws {
        try await call("seek") {
            player.playbackTime = max(0, position)
            changed()
        }
    }

    public func setShuffle(_ on: Bool) async throws {
        try await call("shuffle") {
            player.state.shuffleMode = on ? .songs : .off
            changed()
        }
    }

    public func setRepeat(_ mode: RepeatMode) async throws {
        try await call("repeat") {
            switch mode {
            case .off: player.state.repeatMode = MusicPlayer.RepeatMode.none
            case .one: player.state.repeatMode = .one
            case .all: player.state.repeatMode = .all
            }
            changed()
        }
    }

    // MARK: - Queue

    public func enqueue(songIDs: [String], at position: EnqueuePosition) async throws {
        try await call("enqueue") {
            var songs: [MusicKit.Song] = []
            for id in songIDs { songs.append(try await song(id)) }
            if player.queue.entries.isEmpty {
                player.queue = ApplicationMusicPlayer.Queue(for: songs)
            } else {
                try await player.queue.insert(songs, position: position == .next ? .afterCurrentEntry : .tail)
            }
            changed()
        }
    }

    public func removeFromQueue(entryID: String) async throws { throw HarmuneError.unsupported("Removing from the queue") }
    public func moveQueueEntry(entryID: String, to index: Int) async throws { throw HarmuneError.unsupported("Reordering the queue") }
    public func clearUpcoming() async throws { throw HarmuneError.unsupported("Clearing the queue") }

    // MARK: - Browse

    public func search(_ q: SearchQuery) async throws -> SearchResults {
        try await call("search \(q.scope.rawValue)") {
            q.scope == .catalog ? try await catalogSearch(q) : try await librarySearch(q)
        }
    }

    private func catalogSearch(_ q: SearchQuery) async throws -> SearchResults {
        var types: [any MusicCatalogSearchable.Type] = []
        if q.kinds.contains(.songs) { types.append(MusicKit.Song.self) }
        if q.kinds.contains(.albums) { types.append(MusicKit.Album.self) }
        if q.kinds.contains(.artists) { types.append(MusicKit.Artist.self) }
        if q.kinds.contains(.playlists) { types.append(MusicKit.Playlist.self) }
        var request = MusicCatalogSearchRequest(term: q.text, types: types)
        request.limit = min(q.limit, 25)
        request.offset = q.offset
        let r = try await request.response()
        return SearchResults(songs: r.songs.map { map.track($0, .catalog) }, albums: r.albums.map { map.album($0, .catalog) },
                             artists: r.artists.map { map.artist($0, .catalog) },
                             playlists: r.playlists.map { map.playlist($0, .catalog) },
                             nextOffset: r.songs.hasNextBatch || r.albums.hasNextBatch || r.artists.hasNextBatch || r.playlists.hasNextBatch
                                ? q.offset + min(q.limit, 25) : nil)
    }

    private func librarySearch(_ q: SearchQuery) async throws -> SearchResults {
        var types: [any MusicLibrarySearchable.Type] = []
        if q.kinds.contains(.songs) { types.append(MusicKit.Song.self) }
        if q.kinds.contains(.albums) { types.append(MusicKit.Album.self) }
        if q.kinds.contains(.artists) { types.append(MusicKit.Artist.self) }
        if q.kinds.contains(.playlists) { types.append(MusicKit.Playlist.self) }
        var request = MusicLibrarySearchRequest(term: q.text, types: types)
        request.limit = q.limit
        let r = try await request.response()
        return SearchResults(songs: r.songs.map { map.track($0, .library) }, albums: r.albums.map { map.album($0, .library) },
                             artists: r.artists.map { map.artist($0, .library) },
                             playlists: r.playlists.map { map.playlist($0, .library) })
    }

    private func page<T: Codable & Sendable & Hashable>(_ items: [T], offset: Int, limit: Int) -> Page<T> {
        Page(items: items, nextOffset: items.count == limit ? offset + limit : nil)
    }

    public func librarySongs(sort: SortKey, offset: Int, limit: Int) async throws -> Page<HarmuneCore.Track> {
        try await call("library songs offset=\(offset)") {
            var request = MusicLibraryRequest<MusicKit.Song>()
            request.limit = limit
            request.offset = offset
            switch sort {
            case .title: request.sort(by: \.title, ascending: true)
            case .artist: request.sort(by: \.artistName, ascending: true)
            case .recentlyAdded: request.sort(by: \.libraryAddedDate, ascending: false)
            }
            return page(try await request.response().items.map { map.track($0, .library) }, offset: offset, limit: limit)
        }
    }

    public func libraryAlbums(sort: SortKey, offset: Int, limit: Int) async throws -> Page<HarmuneCore.Album> {
        try await call("library albums offset=\(offset)") {
            var request = MusicLibraryRequest<MusicKit.Album>()
            request.limit = limit
            request.offset = offset
            switch sort {
            case .title: request.sort(by: \.title, ascending: true)
            case .artist: request.sort(by: \.artistName, ascending: true)
            case .recentlyAdded: request.sort(by: \.libraryAddedDate, ascending: false)
            }
            var albums: [HarmuneCore.Album] = []
            for item in try await request.response().items {
                var album = map.album(item, .library)
                if item.title.isEmpty {
                    let first = try? await item.with([.tracks]).tracks?.first?.title
                    album.title = Mapping.untitledAlbumName(firstTrack: first)
                }
                albums.append(album)
            }
            return page(albums, offset: offset, limit: limit)
        }
    }

    public func libraryArtists(offset: Int, limit: Int) async throws -> Page<HarmuneCore.Artist> {
        try await call("library artists offset=\(offset)") {
            var request = MusicLibraryRequest<MusicKit.Artist>()
            request.limit = limit
            request.offset = offset
            request.sort(by: \.name, ascending: true)
            return page(try await request.response().items.map { map.artist($0, .library) }, offset: offset, limit: limit)
        }
    }

    public func libraryPlaylists(offset: Int, limit: Int) async throws -> Page<HarmuneCore.Playlist> {
        try await call("library playlists offset=\(offset)") {
            var request = MusicLibraryRequest<MusicKit.Playlist>()
            request.limit = limit
            request.offset = offset
            request.sort(by: \.name, ascending: true)
            return page(try await request.response().items.map { map.playlist($0, .library) }, offset: offset, limit: limit)
        }
    }

    public func album(id: String) async throws -> AlbumDetail {
        try await call("album") {
            let parsed = try parse(id)
            let album = try await albumItem(parsed).with([.tracks])
            let tracks = try await allTracks(album.tracks)
            return AlbumDetail(album: map.album(album, parsed.source), tracks: tracks.map { map.track($0, parsed.source) })
        }
    }

    public func artist(id: String) async throws -> ArtistDetail {
        try await call("artist") {
            let parsed = try parse(id)
            switch parsed.source {
            case .catalog:
                var request = MusicCatalogResourceRequest<MusicKit.Artist>(matching: \.id, equalTo: parsed.itemID)
                request.limit = 1
                guard let found = try await request.response().items.first else { throw HarmuneError.notFound("Artist \(id)") }
                let artist = try await found.with([.topSongs, .albums])
                return ArtistDetail(artist: map.artist(artist, .catalog),
                                    topSongs: (artist.topSongs ?? []).map { map.track($0, .catalog) },
                                    albums: (artist.albums ?? []).map { map.album($0, .catalog) })
            case .library:
                var request = MusicLibraryRequest<MusicKit.Artist>()
                request.filter(matching: \.id, equalTo: parsed.itemID)
                guard let found = try await request.response().items.first else { throw HarmuneError.notFound("Artist \(id)") }
                let artist = try await found.with([.albums])
                return ArtistDetail(artist: map.artist(artist, .library), topSongs: [],
                                    albums: (artist.albums ?? []).map { map.album($0, .library) })
            }
        }
    }

    public func playlist(id: String) async throws -> PlaylistDetail {
        try await call("playlist") {
            let parsed = try parse(id)
            let playlist = try await playlistItem(parsed).with([.tracks])
            let tracks = try await allTracks(playlist.tracks)
            return PlaylistDetail(playlist: map.playlist(playlist, parsed.source, trackCount: tracks.count, fetchArtwork: true),
                                  tracks: tracks.map { map.track($0, parsed.source) })
        }
    }

    /// Each row is optional: a request that isn't available on this Mac is
    /// logged (Phase 0 check V10) and its row is left out.
    public func home() async throws -> HomeSections {
        try await call("home") {
            var recent: [HarmuneCore.Album] = []
            do {
                var request = MusicRecentlyPlayedRequest<RecentlyPlayedMusicItem>()
                request.limit = 10  // Apple's maximum for this request
                recent = try await request.response().items.compactMap { item in
                    if case .album(let album) = item { return map.album(album, .catalog) }
                    return nil
                }
            } catch {
                HostLog.write("home: recently played FAILED: \(String(reflecting: error))")
            }
            var madeForYou: [HarmuneCore.Playlist] = []
            do {
                var request = MusicPersonalRecommendationsRequest()
                request.limit = 6
                madeForYou = try await request.response().recommendations.flatMap { $0.playlists }.map { map.playlist($0, .catalog, fetchArtwork: true) }
            } catch {
                HostLog.write("home: recommendations FAILED: \(String(reflecting: error))")
            }
            return HomeSections(recentlyPlayed: recent, madeForYou: madeForYou, favoriteAlbums: [])
        }
    }

    // MARK: - Lookups

    private func parse(_ id: String) throws -> MusicID {
        guard let parsed = MusicID(id) else { throw HarmuneError.invalid("Invalid ID '\(id)'") }
        return parsed
    }

    private func song(_ id: String) async throws -> MusicKit.Song {
        let parsed = try parse(id)
        let found: MusicKit.Song?
        switch parsed.source {
        case .catalog:
            var request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: parsed.itemID)
            request.limit = 1
            found = try await request.response().items.first
        case .library:
            var request = MusicLibraryRequest<MusicKit.Song>()
            request.filter(matching: \.id, equalTo: parsed.itemID)
            found = try await request.response().items.first
        }
        guard let found else { throw HarmuneError.notFound("Song \(id)") }
        return found
    }

    private func albumItem(_ id: MusicID) async throws -> MusicKit.Album {
        let found: MusicKit.Album?
        switch id.source {
        case .catalog:
            var request = MusicCatalogResourceRequest<MusicKit.Album>(matching: \.id, equalTo: id.itemID)
            request.limit = 1
            found = try await request.response().items.first
        case .library:
            var request = MusicLibraryRequest<MusicKit.Album>()
            request.filter(matching: \.id, equalTo: id.itemID)
            found = try await request.response().items.first
        }
        guard let found else { throw HarmuneError.notFound("Album \(id)") }
        return found
    }

    private func playlistItem(_ id: MusicID) async throws -> MusicKit.Playlist {
        let found: MusicKit.Playlist?
        switch id.source {
        case .catalog:
            var request = MusicCatalogResourceRequest<MusicKit.Playlist>(matching: \.id, equalTo: id.itemID)
            request.limit = 1
            found = try await request.response().items.first
        case .library:
            var request = MusicLibraryRequest<MusicKit.Playlist>()
            request.filter(matching: \.id, equalTo: id.itemID)
            found = try await request.response().items.first
        }
        guard let found else { throw HarmuneError.notFound("Playlist \(id)") }
        return found
    }

    private func containerTracks(_ kind: ContainerRef.Kind, _ id: String) async throws -> (tracks: [MusicKit.Track], title: String) {
        let parsed = try parse(id)
        switch kind {
        case .album:
            let album = try await albumItem(parsed).with([.tracks])
            return (try await allTracks(album.tracks), album.title)
        case .playlist:
            let playlist = try await playlistItem(parsed).with([.tracks])
            return (try await allTracks(playlist.tracks), playlist.name)
        }
    }

    /// Follows pagination, because long playlists arrive in batches.
    private func allTracks(_ first: MusicItemCollection<MusicKit.Track>?) async throws -> [MusicKit.Track] {
        guard var batch = first else { return [] }
        var all = Array(batch)
        while all.count < 5000, let next = try await batch.nextBatch() {
            all += next
            batch = next
        }
        return all
    }
}

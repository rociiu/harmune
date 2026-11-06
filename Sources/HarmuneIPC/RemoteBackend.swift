import Foundation
import HarmuneCore

/// `MusicBackend` implemented over IPC, so the TUI and CLI can treat the
/// host exactly like an in-process backend.
///
/// Reconnection is the caller's job for now: on `.disconnected`, create a
/// new `RemoteBackend` and re-read the snapshot.
public final class RemoteBackend: MusicBackend {
    public let client: IPCClient
    public let welcome: Welcome

    public static func connect(path: String = HarmunePaths.socketPath(), client kind: Hello.Client) async throws -> RemoteBackend {
        let client = try IPCClient.connect(path: path)
        do {
            return RemoteBackend(client: client, welcome: try await client.hello(client: kind))
        } catch {
            client.close()
            throw error
        }
    }

    private init(client: IPCClient, welcome: Welcome) {
        self.client = client
        self.welcome = welcome
    }

    private func send(_ action: String, _ payload: some Encodable) async throws {
        try await client.request(action, payload: JSONValue(encoding: payload))
    }

    private func send(_ action: String) async throws { try await client.request(action) }

    private func fetch<T: Decodable>(_ action: String, _ payload: some Encodable, as: T.Type) async throws -> T {
        try await client.request(action, payload: JSONValue(encoding: payload), as: T.self, timeout: IPCClient.slowTimeout)
    }

    public func capabilities() async -> Set<Capability> { Set(welcome.capabilities) }

    public func authStatus() async -> AuthStatus {
        (try? await client.request(Action.authStatus, as: AuthStatus.self))
            ?? AuthStatus(state: .unavailable, detail: "Host unreachable")
    }

    public func requestAuthorization() async -> AuthStatus {
        (try? await client.request(Action.authRequest, as: AuthStatus.self, timeout: .seconds(300)))
            ?? AuthStatus(state: .unavailable, detail: "Host unreachable")
    }

    public func play(_ request: PlayRequest) async throws { try await send(Action.play, request) }
    public func pause() async throws { try await send(Action.pause) }
    public func togglePlayPause() async throws { try await send(Action.toggle) }
    public func next() async throws { try await send(Action.next) }
    public func previous() async throws { try await send(Action.previous) }
    public func seek(to position: TimeInterval) async throws { try await send(Action.seek, SeekPayload(position: position)) }
    public func setShuffle(_ on: Bool) async throws { try await send(Action.shuffle, BoolPayload(on: on)) }
    public func setRepeat(_ mode: RepeatMode) async throws { try await send(Action.repeat, RepeatPayload(mode: mode)) }

    public func enqueue(songIDs: [String], at position: EnqueuePosition) async throws {
        try await send(Action.enqueue, EnqueuePayload(songIDs: songIDs, position: position))
    }
    public func removeFromQueue(entryID: String) async throws {
        try await send(Action.queueRemove, EntryPayload(entryID: entryID, index: nil))
    }
    public func moveQueueEntry(entryID: String, to index: Int) async throws {
        try await send(Action.queueMove, EntryPayload(entryID: entryID, index: index))
    }
    public func clearUpcoming() async throws { try await send(Action.queueClear) }

    public func search(_ query: SearchQuery) async throws -> SearchResults {
        try await fetch(Action.search, query, as: SearchResults.self)
    }
    public func librarySongs(sort: SortKey, offset: Int, limit: Int) async throws -> Page<Track> {
        try await fetch(Action.librarySongs, PagePayload(sort: sort, offset: offset, limit: limit), as: Page<Track>.self)
    }
    public func libraryAlbums(sort: SortKey, offset: Int, limit: Int) async throws -> Page<Album> {
        try await fetch(Action.libraryAlbums, PagePayload(sort: sort, offset: offset, limit: limit), as: Page<Album>.self)
    }
    public func libraryArtists(offset: Int, limit: Int) async throws -> Page<Artist> {
        try await fetch(Action.libraryArtists, PagePayload(sort: nil, offset: offset, limit: limit), as: Page<Artist>.self)
    }
    public func libraryPlaylists(offset: Int, limit: Int) async throws -> Page<Playlist> {
        try await fetch(Action.libraryPlaylists, PagePayload(sort: nil, offset: offset, limit: limit), as: Page<Playlist>.self)
    }
    public func album(id: String) async throws -> AlbumDetail { try await fetch(Action.album, IDPayload(id: id), as: AlbumDetail.self) }
    public func artist(id: String) async throws -> ArtistDetail { try await fetch(Action.artist, IDPayload(id: id), as: ArtistDetail.self) }
    public func playlist(id: String) async throws -> PlaylistDetail { try await fetch(Action.playlist, IDPayload(id: id), as: PlaylistDetail.self) }
    public func home() async throws -> HomeSections { try await client.request(Action.home, as: HomeSections.self, timeout: IPCClient.slowTimeout) }

    public func addFavorite(id: String, kind: MediaKind) async throws {
        try await send(Action.favoriteAdd, FavoritePayload(id: id, kind: kind))
    }

    public func favorites() async throws -> Favorites {
        try await client.request(Action.favorites, as: Favorites.self, timeout: IPCClient.slowTimeout)
    }

    public func playbackState() async -> PlaybackState {
        (try? await client.request(Action.state, as: PlaybackState.self)) ?? .idle
    }

    public func queueState() async -> QueueState {
        (try? await client.request(Action.queue, as: QueueState.self)) ?? QueueState()
    }

    /// Subscribes once; the host's event stream is shared, so call this once
    /// per `RemoteBackend`.
    public func events() async -> AsyncStream<BackendEvent> {
        try? await client.subscribe()
        let source = client.events
        return AsyncStream { continuation in
            let task = Task {
                for await envelope in source {
                    guard let data = envelope.data else { continue }
                    switch envelope.event {
                    case EventName.playbackChanged:
                        if let s = try? data.decode(PlaybackState.self) { continuation.yield(.playback(s)) }
                    case EventName.queueChanged:
                        if let q = try? data.decode(QueueState.self) { continuation.yield(.queue(q)) }
                    case EventName.authorizationChanged:
                        if let a = try? data.decode(AuthStatus.self) { continuation.yield(.auth(a)) }
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Service

    public func serviceStatus() async throws -> ServiceStatus {
        try await client.request(Action.serviceStatus, as: ServiceStatus.self)
    }

    public func stopService(force: Bool) async throws {
        try await send(Action.serviceStop, StopPayload(force: force))
    }
}

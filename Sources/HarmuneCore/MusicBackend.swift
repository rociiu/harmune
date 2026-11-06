import Foundation

/// The single seam between the UI and a music source.
///
/// Implementations: `DemoBackend` (in-process fixtures), `RemoteBackend`
/// (IPC client to the host) and, inside the signed host, `MusicKitBackend`.
/// The TUI must not be able to tell them apart.
public protocol MusicBackend: Sendable {
    func capabilities() async -> Set<Capability>
    func authStatus() async -> AuthStatus
    func requestAuthorization() async -> AuthStatus

    // Playback
    func play(_ request: PlayRequest) async throws
    func pause() async throws
    func togglePlayPause() async throws
    func next() async throws
    func previous() async throws
    func seek(to position: TimeInterval) async throws
    func setShuffle(_ on: Bool) async throws
    func setRepeat(_ mode: RepeatMode) async throws

    // Queue
    func enqueue(songIDs: [String], at position: EnqueuePosition) async throws
    func removeFromQueue(entryID: String) async throws
    func moveQueueEntry(entryID: String, to index: Int) async throws
    func clearUpcoming() async throws

    // Browse
    func search(_ query: SearchQuery) async throws -> SearchResults
    func librarySongs(sort: SortKey, offset: Int, limit: Int) async throws -> Page<Track>
    func libraryAlbums(sort: SortKey, offset: Int, limit: Int) async throws -> Page<Album>
    func libraryArtists(offset: Int, limit: Int) async throws -> Page<Artist>
    func libraryPlaylists(offset: Int, limit: Int) async throws -> Page<Playlist>
    func album(id: String) async throws -> AlbumDetail
    func artist(id: String) async throws -> ArtistDetail
    func playlist(id: String) async throws -> PlaylistDetail
    func home() async throws -> HomeSections
    func favorites() async throws -> Favorites
    func addFavorite(id: String, kind: MediaKind) async throws

    // State
    func playbackState() async -> PlaybackState
    func queueState() async -> QueueState
    /// Each call returns a new independent stream of changes.
    func events() async -> AsyncStream<BackendEvent>
}

public extension MusicBackend {
    func favorites() async throws -> Favorites { throw HarmuneError.unsupported("Favorites") }
    func addFavorite(id: String, kind: MediaKind) async throws { throw HarmuneError.unsupported("Adding favorites") }
}

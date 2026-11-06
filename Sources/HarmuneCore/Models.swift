import Foundation

// MARK: - Media items

public struct RGB: Codable, Sendable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// Reference to artwork. The host fills `path` with a local cache file;
/// artwork bytes never travel over IPC.
public struct ArtworkRef: Codable, Sendable, Hashable {
    public var key: String
    public var averageColor: RGB?
    public var path: String?
    public init(key: String, averageColor: RGB? = nil, path: String? = nil) {
        self.key = key; self.averageColor = averageColor; self.path = path
    }
}

public struct Track: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumID: String?
    public var duration: TimeInterval
    public var trackNumber: Int?
    public var artwork: ArtworkRef?
    public init(id: String, title: String, artist: String, album: String, albumID: String? = nil,
                duration: TimeInterval, trackNumber: Int? = nil, artwork: ArtworkRef? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album; self.albumID = albumID
        self.duration = duration; self.trackNumber = trackNumber; self.artwork = artwork
    }
}

public struct Album: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var genre: String?
    public var trackCount: Int
    public var artwork: ArtworkRef?
    public init(id: String, title: String, artist: String, year: Int? = nil, genre: String? = nil,
                trackCount: Int, artwork: ArtworkRef? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.year = year; self.genre = genre
        self.trackCount = trackCount; self.artwork = artwork
    }
}

public struct Artist: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var artwork: ArtworkRef?
    public init(id: String, name: String, artwork: ArtworkRef? = nil) {
        self.id = id; self.name = name; self.artwork = artwork
    }
}

public struct Playlist: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var curator: String?
    public var trackCount: Int
    public var artwork: ArtworkRef?
    public init(id: String, name: String, curator: String? = nil, trackCount: Int, artwork: ArtworkRef? = nil) {
        self.id = id; self.name = name; self.curator = curator; self.trackCount = trackCount; self.artwork = artwork
    }
}

public struct AlbumDetail: Codable, Sendable, Hashable {
    public var album: Album
    public var tracks: [Track]
    public init(album: Album, tracks: [Track]) { self.album = album; self.tracks = tracks }
}

public struct ArtistDetail: Codable, Sendable, Hashable {
    public var artist: Artist
    public var topSongs: [Track]
    public var albums: [Album]
    public init(artist: Artist, topSongs: [Track], albums: [Album]) {
        self.artist = artist; self.topSongs = topSongs; self.albums = albums
    }
}

public struct PlaylistDetail: Codable, Sendable, Hashable {
    public var playlist: Playlist
    public var tracks: [Track]
    public init(playlist: Playlist, tracks: [Track]) { self.playlist = playlist; self.tracks = tracks }
}

public struct HomeSections: Codable, Sendable, Hashable {
    public var recentlyPlayed: [Album]
    public var madeForYou: [Playlist]
    public var favoriteAlbums: [Album]
    public init(recentlyPlayed: [Album], madeForYou: [Playlist], favoriteAlbums: [Album]) {
        self.recentlyPlayed = recentlyPlayed; self.madeForYou = madeForYou; self.favoriteAlbums = favoriteAlbums
    }
}

// MARK: - Browsing

public enum SearchScope: String, Codable, Sendable, CaseIterable { case catalog, library }
public enum MediaKind: String, Codable, Sendable, CaseIterable { case songs, albums, artists, playlists }
public enum SortKey: String, Codable, Sendable, CaseIterable { case title, artist, recentlyAdded }

public struct SearchQuery: Codable, Sendable, Hashable {
    public var text: String
    public var scope: SearchScope
    public var kinds: [MediaKind]
    public var offset: Int
    public var limit: Int
    public init(text: String, scope: SearchScope = .catalog, kinds: [MediaKind] = MediaKind.allCases,
                offset: Int = 0, limit: Int = 25) {
        self.text = text; self.scope = scope; self.kinds = kinds; self.offset = offset; self.limit = limit
    }
}

public struct Favorites: Codable, Sendable, Equatable {
    public var songs: [Track]
    public var albums: [Album]
    public init(songs: [Track], albums: [Album]) { self.songs = songs; self.albums = albums }
}

public struct SearchResults: Codable, Sendable, Hashable {
    public var songs: [Track]
    public var albums: [Album]
    public var artists: [Artist]
    public var playlists: [Playlist]
    /// Offset for the next page, or nil when exhausted.
    public var nextOffset: Int?
    public init(songs: [Track] = [], albums: [Album] = [], artists: [Artist] = [], playlists: [Playlist] = [],
                nextOffset: Int? = nil) {
        self.songs = songs; self.albums = albums; self.artists = artists; self.playlists = playlists
        self.nextOffset = nextOffset
    }
}

public struct Page<Item: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var items: [Item]
    public var nextOffset: Int?
    public init(items: [Item], nextOffset: Int?) { self.items = items; self.nextOffset = nextOffset }
}

// MARK: - Playback

public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, one, all
    public var next: RepeatMode {
        switch self { case .off: .all; case .all: .one; case .one: .off }
    }
}

public struct ContainerRef: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case album, playlist }
    public var kind: Kind
    public var id: String
    public var title: String
    public init(kind: Kind, id: String, title: String) { self.kind = kind; self.id = id; self.title = title }
}

public struct PlaybackState: Codable, Sendable, Equatable {
    public var track: Track?
    public var isPlaying: Bool
    /// Position at `positionTimestamp`.
    public var position: TimeInterval
    public var positionTimestamp: Date
    /// 1 while playing, 0 while paused.
    public var rate: Double
    public var shuffle: Bool
    public var `repeat`: RepeatMode
    public var container: ContainerRef?
    public var revision: UInt64

    public init(track: Track? = nil, isPlaying: Bool = false, position: TimeInterval = 0,
                positionTimestamp: Date = Date(), rate: Double = 0, shuffle: Bool = false,
                repeat: RepeatMode = .off, container: ContainerRef? = nil, revision: UInt64 = 0) {
        self.track = track; self.isPlaying = isPlaying; self.position = position
        self.positionTimestamp = positionTimestamp; self.rate = rate; self.shuffle = shuffle
        self.repeat = `repeat`; self.container = container; self.revision = revision
    }

    public static let idle = PlaybackState()

    /// Extrapolates the position locally so clients never poll the host.
    public func position(at now: Date) -> TimeInterval {
        let elapsed = max(0, now.timeIntervalSince(positionTimestamp)) * rate
        let value = position + elapsed
        guard let duration = track?.duration else { return max(0, value) }
        return min(max(0, value), duration)
    }
}

public struct QueueEntry: Codable, Sendable, Hashable, Identifiable {
    /// Stable per-entry id; the same track can appear twice.
    public var id: String
    public var track: Track
    public init(id: String, track: Track) { self.id = id; self.track = track }
}

public struct QueueState: Codable, Sendable, Equatable {
    public var entries: [QueueEntry]
    public var currentIndex: Int?
    public var revision: UInt64
    public init(entries: [QueueEntry] = [], currentIndex: Int? = nil, revision: UInt64 = 0) {
        self.entries = entries; self.currentIndex = currentIndex; self.revision = revision
    }
    public var upcoming: ArraySlice<QueueEntry> {
        guard let i = currentIndex else { return entries[...] }
        return entries[min(i + 1, entries.count)...]
    }
}

public enum PlayRequest: Codable, Sendable, Hashable {
    /// Play a single song, replacing the queue.
    case song(id: String)
    /// Play an album or playlist, starting at `startIndex`.
    case container(ContainerRef.Kind, id: String, startIndex: Int)
    /// Jump to an existing queue entry.
    case queueEntry(id: String)
    /// Resume the current item.
    case resume
}

public enum EnqueuePosition: String, Codable, Sendable { case next, last }

// MARK: - Session

public enum Capability: String, Codable, Sendable, CaseIterable {
    case queueRemove = "queue.remove"
    case queueMove = "queue.move"
    case favorites
    case recommendations
    case recentlyPlayed
    case librarySearch = "library.search"
}

public enum AuthState: String, Codable, Sendable {
    case notDetermined, authorized, denied, restricted, noSubscription, unavailable
}

public struct AuthStatus: Codable, Sendable, Equatable {
    public var state: AuthState
    public var detail: String?
    public init(state: AuthState, detail: String? = nil) { self.state = state; self.detail = detail }
}

public enum BackendEvent: Sendable, Equatable {
    case playback(PlaybackState)
    case queue(QueueState)
    case auth(AuthStatus)
}

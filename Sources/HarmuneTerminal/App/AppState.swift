import Foundation
import HarmuneCore

public enum Route: Hashable, Sendable {
    case home, search, songs, albums, artists, playlists, queue, nowPlaying
    case album(String), playlist(String), artist(String)

    /// Sidebar order (spec §4.1). Favorites/Recently Played stay hidden
    /// until the backend supports them.
    static let sidebar: [Route?] = [.home, .search, nil, .songs, .albums, .artists, .playlists, nil, .queue]

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        case .queue: "Queue"
        case .nowPlaying: "Now Playing"
        case .album: "Album"
        case .playlist: "Playlist"
        case .artist: "Artist"
        }
    }

    var isLibrary: Bool {
        switch self {
        case .songs, .albums, .artists, .playlists, .album, .playlist, .artist: true
        default: false
        }
    }

    var keyContext: KeyContext { self == .queue ? .queue : .list }
}

public enum Focus: Sendable { case sidebar, content }

public enum InputMode: Sendable, Equatable { case normal, search, filter, command }

/// A selectable line in the content list.
public struct Row: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `container` lets Enter play the whole album/playlist from here.
        case song(Track, container: ContainerRef.Kind?, containerID: String?, index: Int)
        case album(Album)
        case artist(Artist)
        case playlist(Playlist)
        case queueEntry(QueueEntry, index: Int)
        case header(String)
        case message(String)
    }

    public var kind: Kind
    public var cells: [String]

    var isSelectable: Bool {
        switch kind { case .header, .message: false; default: true }
    }

    var trackID: String? {
        switch kind {
        case .song(let t, _, _, _): t.id
        case .queueEntry(let e, _): e.track.id
        default: nil
        }
    }
}

public struct Column: Sendable, Equatable {
    public var title: String
    public var width: Int
    public var flex: Int
    public var alignRight: Bool
    /// Hidden when the content area is narrower than this.
    public var minContentWidth: Int

    static func fixed(_ title: String, _ width: Int, right: Bool = false, minContent: Int = 0) -> Column {
        Column(title: title, width: width, flex: 0, alignRight: right, minContentWidth: minContent)
    }
    static func flex(_ title: String, _ weight: Int = 1, minContent: Int = 0) -> Column {
        Column(title: title, width: 0, flex: weight, alignRight: false, minContentWidth: minContent)
    }
}

/// Header shown above album/playlist/artist track lists.
public struct DetailHeader: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var meta: String
}

/// Data loaded for a route.
public enum RouteData: Sendable, Equatable {
    case tracks([Track], nextOffset: Int?)
    case albums([Album], nextOffset: Int?)
    case artists([Artist])
    case playlists([Playlist])
    case albumDetail(AlbumDetail)
    case playlistDetail(PlaylistDetail)
    case artistDetail(ArtistDetail)
    case home(HomeSections)
    case search(SearchResults)
}

public struct Toast: Sendable, Equatable {
    public var message: String
    public var isError: Bool
    public var expires: Date
}

public enum Overlay: Sendable, Equatable {
    case help
    case confirm(String, ConfirmAction)
}

public enum ConfirmAction: Sendable, Equatable { case clearQueue, quitAndStopHost }

public enum ConnectionState: Sendable, Equatable { case connected, reconnecting, offline }

/// Everything needed to draw a frame. Pure value; views never mutate it.
public struct AppState: Sendable {
    // Remote (mirrored from the backend)
    public var playback = PlaybackState.idle
    public var queue = QueueState()
    public var auth = AuthStatus(state: .notDetermined)
    public var capabilities: Set<Capability> = []
    public var connection = ConnectionState.connected

    // Navigation
    public var stack: [Route] = [.home]
    public var focus = Focus.content
    public var sidebarIndex = 0
    public var selection: [Route: Int] = [:]
    public var scroll: [Route: Int] = [:]

    // Data
    public var data: [Route: RouteData] = [:]
    public var loading: Set<Route> = []
    public var errors: [Route: String] = [:]

    // Input
    public var mode = InputMode.normal
    public var input = ""
    public var searchQuery = ""
    public var searchScope = SearchScope.catalog
    public var filters: [Route: String] = [:]
    public var pendingKeys = ""
    public var commandHistory: [String] = []

    // Chrome
    public var overlay: Overlay?
    public var toast: Toast?
    public var theme = Theme.midnight
    public var now = Date()

    public init() {}

    public var route: Route { stack.last ?? .home }
}

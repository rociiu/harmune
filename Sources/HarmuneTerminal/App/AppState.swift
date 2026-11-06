import Foundation
import HarmuneCore

public enum Route: Hashable, Sendable {
    case home, search, songs, albums, artists, playlists, favorites, recentlyPlayed, queue, nowPlaying, settings
    case album(String), playlist(String), artist(String)

    /// Destinations available in the view switcher.
    static func destinations(_ capabilities: Set<Capability>) -> [Route] {
        var routes: [Route] = [.home, .search, .songs, .albums, .artists, .playlists]
        if capabilities.contains(.favorites) { routes.append(.favorites) }
        if capabilities.contains(.recentlyPlayed) { routes.append(.recentlyPlayed) }
        return routes + [.queue, .settings]
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        case .favorites: "Favorites"
        case .recentlyPlayed: "Recently Played"
        case .queue: "Queue"
        case .nowPlaying: "Now Playing"
        case .settings: "Settings"
        case .album: "Album"
        case .playlist: "Playlist"
        case .artist: "Artist"
        }
    }

    var isLibrary: Bool {
        switch self {
        case .songs, .albums, .artists, .playlists, .favorites, .recentlyPlayed, .album, .playlist, .artist: true
        default: false
        }
    }

    var keyContext: KeyContext { self == .queue ? .queue : .list }

    /// The name `general.start_page` and the saved last view use.
    public var pageName: String? {
        switch self {
        case .home: "home"
        case .search: "search"
        case .songs: "songs"
        case .albums: "albums"
        case .artists: "artists"
        case .playlists: "playlists"
        case .queue: "queue"
        default: nil
        }
    }

    public static func page(_ name: String) -> Route? {
        [Route.home, .search, .songs, .albums, .artists, .playlists, .queue].first { $0.pageName == name }
    }
}

public enum Focus: Sendable { case views, content }

public enum InputMode: Sendable, Equatable { case normal, search, filter, command }

/// Result categories in Search (spec §8.2).
public enum SearchTab: Int, CaseIterable, Sendable {
    case all, songs, albums, artists, playlists

    var title: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }

    var kinds: [MediaKind] {
        switch self {
        case .all: MediaKind.allCases
        case .songs: [.songs]
        case .albums: [.albums]
        case .artists: [.artists]
        case .playlists: [.playlists]
        }
    }

    func shows(_ kind: MediaKind) -> Bool { kinds.contains(kind) }
}

public enum ArtworkSize: String, CaseIterable, Sendable {
    case small, medium, large

    /// Share of the immersive view's height the cover takes.
    var fraction: Double {
        switch self {
        case .small: 0.35
        case .medium: 0.5
        case .large: 0.65
        }
    }

    var next: ArtworkSize {
        switch self {
        case .small: .medium
        case .medium: .large
        case .large: .small
        }
    }
}

/// What the person can change in Settings or `config.toml`.
public struct Preferences: Sendable, Equatable {
    public var showArtwork = true
    public var showVisualizer = true
    public var showBorders = true
    public var dynamicColors = true
    public var reducedMotion = false
    public var albumGrid = false
    public var showProgress = true
    public var showDuration = true
    public var artworkSize = ArtworkSize.medium
    public var maxFPS = 20
    public init() {}
}

/// A row in Settings.
public enum SettingKey: String, CaseIterable, Sendable {
    case theme, artwork, artworkSize, visualizer, dynamicColors, albumView, borders, reducedMotion

    var label: String {
        switch self {
        case .theme: "Theme"
        case .artwork: "Album artwork"
        case .artworkSize: "Immersive artwork size"
        case .visualizer: "Decorative visualizer"
        case .dynamicColors: "Colors from artwork"
        case .albumView: "Albums view"
        case .borders: "Borders"
        case .reducedMotion: "Reduced motion"
        }
    }
}

/// A selectable line in the content list.
public struct Row: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `container` lets Enter play the whole album/playlist from here.
        case song(Track, container: ContainerRef.Kind?, containerID: String?, index: Int)
        case album(Album)
        case artist(Artist)
        case playlist(Playlist)
        case queueEntry(QueueEntry, index: Int)
        case setting(SettingKey)
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
    case artists([Artist], nextOffset: Int?)
    case playlists([Playlist], nextOffset: Int?)
    case albumDetail(AlbumDetail)
    case playlistDetail(PlaylistDetail)
    case artistDetail(ArtistDetail)
    case home(HomeSections)
    case favorites(Favorites)
    case search(SearchResults)
}

public struct Toast: Sendable, Equatable {
    public var message: String
    public var isError: Bool
    public var expires: Date
}

/// A list to choose from. Theme pickers preview as the selection moves.
public struct Picker: Sendable, Equatable {
    public enum Purpose: Sendable, Equatable {
        case theme(original: Theme)
        case sort(Route)
    }
    public var title: String
    public var options: [String]
    public var index: Int
    public var purpose: Purpose
}

public enum Overlay: Sendable, Equatable {
    case help
    case confirm(String, ConfirmAction)
    case picker(Picker)
}

public enum ConfirmAction: Sendable, Equatable { case clearQueue, quitAndStopHost }

public enum ConnectionState: Sendable, Equatable { case connected, reconnecting, offline }

/// Everything needed to draw a frame. Pure value; views never mutate it.
public struct AppState: Sendable {
    // Remote (mirrored from the backend)
    public var playback = PlaybackState.idle
    public var queue = QueueState()
    public var auth = AuthStatus(state: .authorized)
    public var capabilities: Set<Capability> = []
    public var connection = ConnectionState.connected
    var nextReconnectAt: Date?
    var reconnectSeconds: Int? {
        guard connection == .reconnecting, let nextReconnectAt, nextReconnectAt > now else { return nil }
        return Int(nextReconnectAt.timeIntervalSince(now).rounded(.up))
    }

    // Navigation
    public var stack: [Route] = [.home]
    public var focus = Focus.content
    public var viewIndex = 0
    public var selection: [Route: Int] = [:]
    public var scroll: [Route: Int] = [:]

    // Data
    public var data: [Route: RouteData] = [:]
    public var loading: Set<Route> = []
    public var errors: [Route: String] = [:]
    public var sort: [Route: SortKey] = [:]

    // Input
    public var mode = InputMode.normal
    public var input = ""
    public var searchQuery = ""
    public var searchScope = SearchScope.catalog
    public var searchTab = SearchTab.all
    public var filters: [Route: String] = [:]
    public var pendingKeys = ""
    public var commandHistory: [String] = []

    // Chrome
    public var overlay: Overlay?
    public var helpScroll = 0
    public var toast: Toast?
    public var theme = Theme.midnight
    public var themes = Theme.all
    public var keymap = Keymap.standard
    var trackTransition: (startedAt: Date, previousAlbum: String)?
    var trackTransitionProgress: Double? {
        guard route == .nowPlaying, focus == .content, !prefs.reducedMotion, let trackTransition else { return nil }
        let elapsed = now.timeIntervalSince(trackTransition.startedAt)
        return elapsed < 0.2 ? max(0, elapsed / 0.2) : nil
    }
    public var now = Date()
    public var prefs = Preferences()
    /// Picked from the current cover; only decorative elements use it.
    public var dynamicAccent: TermColor?
    /// Graphics mode and decoded artwork, maintained by the run loop.
    public var art = ArtworkSnapshot()

    public init() {}

    public var route: Route { stack.last ?? .home }

    /// Album list as an artwork grid (`t` toggles).
    public var albumGrid: Bool {
        get { prefs.albumGrid }
        set { prefs.albumGrid = newValue }
    }

    /// The theme for decorative elements: the cover's accent when there is one.
    var decorativeTheme: Theme {
        guard prefs.dynamicColors, let dynamicAccent, !theme.usesReverseSelection else { return theme }
        var t = theme
        t.accent = dynamicAccent
        t.accentPink = dynamicAccent
        return t
    }
}

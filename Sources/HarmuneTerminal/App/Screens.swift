import Foundation
import HarmuneCore

/// What the content area shows for a route. Built from state, so the store
/// and the view always agree on which row is which.
public struct ScreenModel: Sendable, Equatable {
    public var breadcrumb: String
    public var columns: [Column]
    public var rows: [Row]
    public var header: DetailHeader?
    public var empty: String
    public var hints: String
    public var footer: String?
    /// Category tabs drawn beside the breadcrumb.
    public var tabs: [String] = []
    public var activeTab = 0
}

/// What stands between the person and their music, per spec §3.
public struct AuthGate: Sendable, Equatable {
    public var title: String
    public var lines: [String]
    public var canConnect: Bool
}

func authGate(route: Route, status: AuthStatus) -> AuthGate? {
    if route == .settings || route == .nowPlaying { return nil }
    switch status.state {
    case .authorized:
        return nil
    case .notDetermined:
        return AuthGate(title: "Welcome to Harmune", lines: ["Your music. Your terminal.", "", "Connect your Apple Music account to begin.", "",
                                                             "Enter  Connect Apple Music", "?      Learn keyboard shortcuts"], canConnect: true)
    case .denied:
        return AuthGate(title: "Apple Music access is off", lines: ["Harmune needs permission to use Apple Music.", "",
                                                                    "Open System Settings > Privacy & Security > Media & Apple Music,",
                                                                    "turn on Harmune, then press Enter."], canConnect: true)
    case .restricted:
        return AuthGate(title: "Apple Music is restricted on this Mac", lines: ["A device management profile or Screen Time setting blocks it.", "",
                                                                                "Change that setting, then restart Harmune."], canConnect: false)
    case .noSubscription:
        guard route == .home else { return nil }
        return AuthGate(title: "Apple Music subscription needed", lines: ["This account can't play the Apple Music catalog.", "",
                                                                          "Songs you've added or imported may still work: try gl or ga.",
                                                                          "Subscribe in the Music app to unlock everything."], canConnect: false)
    case .unavailable:
        return AuthGate(title: "Apple Music isn't available", lines: [status.detail ?? "MusicKit reported no details.", "",
                                                                      "See ~/Library/Logs/Harmune/host.log for details."], canConnect: false)
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

private let songColumns: [Column] = [
    .fixed("#", 4, right: true), .flex("TITLE", 3), .flex("ARTIST", 2, minContent: 50),
    .flex("ALBUM", 2, minContent: 80), .fixed("TIME", 6, right: true),
]

private func songRow(_ t: Track, _ i: Int, container: ContainerRef.Kind? = nil, id: String? = nil, number: Int? = nil) -> Row {
    Row(kind: .song(t, container: container, containerID: id, index: i),
        cells: [String(number ?? i + 1), t.title, t.artist, t.album, formatTime(t.duration)])
}

private func onOff(_ value: Bool) -> String { value ? "on" : "off" }

private func settingValue(_ key: SettingKey, _ s: AppState) -> String {
    switch key {
    case .theme: s.theme.name
    case .artwork: onOff(s.prefs.showArtwork)
    case .artworkSize: s.prefs.artworkSize.rawValue
    case .visualizer: onOff(s.prefs.showVisualizer)
    case .dynamicColors: onOff(s.prefs.dynamicColors)
    case .albumView: s.prefs.albumGrid ? "grid" : "list"
    case .borders: onOff(s.prefs.showBorders)
    case .reducedMotion: onOff(s.prefs.reducedMotion)
    }
}

private func sortLabel(_ s: AppState, _ route: Route) -> String {
    switch s.sort[route] ?? .title {
    case .title: ""
    case .artist: " · by artist"
    case .recentlyAdded: " · recently added first"
    }
}

private let songHints = "Enter play   p next   a queue   / search   F filter"

public func screen(for route: Route, in s: AppState) -> ScreenModel {
    let data = s.data[route]
    var model: ScreenModel

    switch route {
    case .home:
        var rows: [Row] = []
        if case .home(let h) = data {
            if !h.recentlyPlayed.isEmpty {
                rows.append(Row(kind: .header("RECENTLY PLAYED"), cells: []))
                rows += h.recentlyPlayed.map { Row(kind: .album($0), cells: [$0.title, $0.artist, $0.year.map(String.init) ?? ""]) }
            }
            if !h.madeForYou.isEmpty {
                rows.append(Row(kind: .header("MADE FOR YOU"), cells: []))
                rows += h.madeForYou.map { Row(kind: .playlist($0), cells: [$0.name, $0.curator ?? "", $0.trackCount > 0 ? "\($0.trackCount) songs" : ""]) }
            }
            if !h.favoriteAlbums.isEmpty {
                rows.append(Row(kind: .header("FAVORITE ALBUMS"), cells: []))
                rows += h.favoriteAlbums.map { Row(kind: .album($0), cells: [$0.title, $0.artist, $0.year.map(String.init) ?? ""]) }
            }
        }
        model = ScreenModel(breadcrumb: "Home", columns: [.flex("", 3), .flex("", 2, minContent: 50), .fixed("", 10, right: true, minContent: 70)],
                            rows: rows, header: nil,
                            empty: "Welcome to Harmune\n\nYour music lives here.\n\nPress / to discover something new.",
                            hints: "Enter open   / search   gl songs   ga albums")

    case .search:
        var rows: [Row] = []
        let tab = s.searchTab
        func section(_ title: String, _ kind: MediaKind, _ items: [Row]) {
            guard tab.shows(kind), !items.isEmpty else { return }
            if tab == .all { rows.append(Row(kind: .header(title), cells: [])) }
            rows += items
        }
        if case .search(let r) = data {
            section("SONGS", .songs, r.songs.enumerated().map { songRow($1, $0) })
            section("ALBUMS", .albums, r.albums.map { Row(kind: .album($0), cells: ["", $0.title, $0.artist, $0.year.map(String.init) ?? "", ""]) })
            section("ARTISTS", .artists, r.artists.map { Row(kind: .artist($0), cells: ["", $0.name, "", "", ""]) })
            section("PLAYLISTS", .playlists, r.playlists.map { Row(kind: .playlist($0), cells: ["", $0.name, $0.curator ?? "", "", ""]) })
        }
        let scope = s.searchScope == .catalog ? "Apple Music" : "Library"
        model = ScreenModel(breadcrumb: s.searchQuery.isEmpty ? "Search" : "Search / \(s.searchQuery)",
                            columns: songColumns, rows: rows, header: nil,
                            empty: s.searchQuery.isEmpty ? "Press / to search \(scope)." : "No \(tab == .all ? "results" : tab.title.lowercased()) for “\(s.searchQuery)”.",
                            hints: "H/L category   " + songHints,
                            tabs: SearchTab.allCases.map(\.title), activeTab: tab.rawValue)

    case .songs:
        var rows: [Row] = []
        if case .tracks(let tracks, _) = data { rows = tracks.enumerated().map { songRow($1, $0) } }
        model = ScreenModel(breadcrumb: "Library / Songs", columns: songColumns, rows: rows, header: nil,
                            empty: "Your library has no songs yet.", hints: "o sort   " + songHints,
                            footer: rows.isEmpty ? nil : "\(rows.count) songs\(sortLabel(s, .songs))")

    case .albums:
        var rows: [Row] = []
        if case .albums(let albums, _) = data {
            rows = albums.enumerated().map { i, a in
                Row(kind: .album(a), cells: [String(i + 1), a.title, a.artist, a.year.map(String.init) ?? ""])
            }
        }
        model = ScreenModel(breadcrumb: "Library / Albums",
                            columns: [.fixed("#", 4, right: true), .flex("ALBUM", 3), .flex("ARTIST", 2, minContent: 45), .fixed("YEAR", 6, right: true, minContent: 60)],
                            rows: rows, header: nil, empty: "No albums in your library.",
                            hints: "Enter open   p next   a queue   t grid/list   o sort   F filter",
                            footer: rows.isEmpty ? nil : "\(rows.count) albums\(sortLabel(s, .albums))")

    case .recentlyPlayed:
        var rows: [Row] = []
        if case .albums(let albums, _) = data {
            rows = albums.enumerated().map { i, a in
                Row(kind: .album(a), cells: [String(i + 1), a.title, a.artist, a.year.map(String.init) ?? ""])
            }
        }
        model = ScreenModel(breadcrumb: "Library / Recently Played",
                            columns: [.fixed("#", 4, right: true), .flex("ALBUM", 3), .flex("ARTIST", 2, minContent: 45), .fixed("YEAR", 6, right: true, minContent: 60)],
                            rows: rows, header: nil, empty: "Nothing played recently.\n\nPress / to find something.",
                            hints: "Enter open   p next   a queue")

    case .settings:
        let rows = SettingKey.allCases.map { Row(kind: .setting($0), cells: [$0.label, settingValue($0, s)]) }
        model = ScreenModel(breadcrumb: "Settings", columns: [.flex("SETTING", 3), .flex("VALUE", 2)], rows: rows, header: nil, empty: "",
                            hints: "Enter change   saved to config.toml")

    case .artists:
        var rows: [Row] = []
        if case .artists(let artists) = data { rows = artists.map { Row(kind: .artist($0), cells: [$0.name]) } }
        model = ScreenModel(breadcrumb: "Library / Artists", columns: [.flex("ARTIST")], rows: rows, header: nil,
                            empty: "No artists in your library.", hints: "Enter open   F filter",
                            footer: rows.isEmpty ? nil : "\(rows.count) artists")

    case .playlists:
        var rows: [Row] = []
        if case .playlists(let p) = data {
            rows = p.map { Row(kind: .playlist($0), cells: [$0.name, $0.curator ?? "", $0.trackCount > 0 ? "\($0.trackCount)" : ""]) }
        }
        model = ScreenModel(breadcrumb: "Library / Playlists",
                            columns: [.flex("PLAYLIST", 3), .flex("CURATOR", 2, minContent: 50), .fixed("SONGS", 7, right: true)],
                            rows: rows, header: nil, empty: "No playlists yet.",
                            hints: "Enter open   p next   a queue", footer: rows.isEmpty ? nil : "\(rows.count) playlists")

    case .queue:
        let rows = s.queue.entries.enumerated().map { i, e in
            Row(kind: .queueEntry(e, index: i), cells: [String(i + 1), e.track.title, e.track.artist, e.track.album, formatTime(e.track.duration)])
        }
        let canEdit = s.capabilities.contains(.queueRemove)
        let canMove = s.capabilities.contains(.queueMove)
        let hints = ["Enter play", canEdit ? "dd remove" : nil, canMove ? "J/K move" : nil, canEdit ? "D clear" : nil]
            .compactMap { $0 }.joined(separator: "   ")
        let upcoming = s.queue.upcoming.count
        model = ScreenModel(breadcrumb: "Queue", columns: songColumns, rows: rows, header: nil,
                            empty: "The queue is empty.\n\nPress a on any song to add it.", hints: hints,
                            footer: rows.isEmpty ? nil : "\(rows.count) songs · \(upcoming) up next")

    case .nowPlaying:
        model = ScreenModel(breadcrumb: "Now Playing", columns: [], rows: [], header: nil, empty: "",
                            hints: "v exit   Space pause   [ ] seek   s shuffle   r repeat")

    case .album(let id):
        var rows: [Row] = [], header: DetailHeader?
        if case .albumDetail(let d) = data {
            rows = d.tracks.enumerated().map { songRow($1, $0, container: .album, id: id, number: $1.trackNumber) }
            let total = d.tracks.reduce(0) { $0 + $1.duration }
            header = DetailHeader(title: d.album.title, subtitle: d.album.artist,
                                  meta: [d.album.year.map(String.init), d.album.genre, "\(d.tracks.count) songs", formatTime(total)]
                                    .compactMap { $0 }.joined(separator: " · "),
                                  artworkPath: d.album.artwork?.path)
        }
        model = ScreenModel(breadcrumb: "Library / Albums / \(header?.title ?? "…")",
                            columns: [.fixed("#", 4, right: true), .flex("TITLE", 3), .flex("ARTIST", 2, minContent: 70),
                                      .flex("ALBUM", 1, minContent: .max), .fixed("TIME", 6, right: true)],
                            rows: rows, header: header, empty: "", hints: songHints)

    case .playlist(let id):
        var rows: [Row] = [], header: DetailHeader?
        if case .playlistDetail(let d) = data {
            rows = d.tracks.enumerated().map { songRow($1, $0, container: .playlist, id: id) }
            header = DetailHeader(title: d.playlist.name, subtitle: d.playlist.curator ?? "",
                                  meta: "\(d.tracks.count) songs · \(formatTime(d.tracks.reduce(0) { $0 + $1.duration }))",
                                  artworkPath: d.playlist.artwork?.path)
        }
        model = ScreenModel(breadcrumb: "Library / Playlists / \(header?.title ?? "…")", columns: songColumns,
                            rows: rows, header: header, empty: "", hints: songHints)

    case .artist:
        var rows: [Row] = [], header: DetailHeader?
        if case .artistDetail(let d) = data {
            rows.append(Row(kind: .header("TOP SONGS"), cells: []))
            rows += d.topSongs.enumerated().map { songRow($1, $0) }
            rows.append(Row(kind: .header("ALBUMS"), cells: []))
            rows += d.albums.map { Row(kind: .album($0), cells: ["", $0.title, $0.year.map(String.init) ?? "", "", ""]) }
            header = DetailHeader(title: d.artist.name, subtitle: "Artist", meta: "\(d.albums.count) albums",
                                  artworkPath: d.albums.first?.artwork?.path)
        }
        model = ScreenModel(breadcrumb: "Library / Artists / \(header?.title ?? "…")", columns: songColumns,
                            rows: rows, header: header, empty: "", hints: songHints)
    }

    if let filter = s.filters[route], !filter.isEmpty {
        let f = filter.lowercased()
        model.rows = model.rows.filter { $0.isSelectable && $0.cells.joined(separator: " ").lowercased().contains(f) }
        model.footer = "\(model.rows.count) matching “\(filter)”"
        if model.rows.isEmpty { model.empty = "Nothing matches “\(filter)”. Esc clears the filter." }
    }
    if let gate = authGate(route: route, status: s.auth) {
        model.rows = []
        model.footer = nil
        model.hints = gate.canConnect ? "Enter connect" : ""
    }
    if let error = s.errors[route], model.rows.isEmpty { model.empty = "⚠ \(error)\n\nPress :reload to retry." }
    return model
}

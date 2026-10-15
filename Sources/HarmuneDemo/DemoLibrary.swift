import Foundation
import HarmuneCore

/// Deterministic fictional library used by `--demo`, tests and snapshots.
/// All names are invented; no real catalog data ships in the repo.
public struct DemoLibrary: Sendable {
    public let artists: [Artist]
    public let albums: [Album]
    public let tracks: [Track]
    public let playlists: [Playlist]
    public let playlistTrackIDs: [String: [String]]

    public let tracksByID: [String: Track]
    public let albumsByID: [String: Album]

    public func tracks(inAlbum id: String) -> [Track] {
        tracks.filter { $0.albumID == id }.sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    }

    public func tracks(inPlaylist id: String) -> [Track] {
        (playlistTrackIDs[id] ?? []).compactMap { tracksByID[$0] }
    }

    public static let standard = DemoLibrary(seed: 0x4841524D)

    public var artworkKeys: [String] {
        albums.compactMap(\.artwork?.key) + playlists.compactMap(\.artwork?.key) + artists.compactMap(\.artwork?.key)
    }

    public init(seed: UInt64, artistCount: Int = 12, albumCount: Int = 30, playlistCount: Int = 8) {
        var rng = SplitMix64(seed: seed)

        let artistNames = [
            "Neon Harbor", "The Quiet Static", "Luma Vale", "Midnight Cartography", "Orchid Engine",
            "Paper Satellites", "Velvet Circuit", "Hollow Pines", "Saffron Tides", "Glass Meridian",
            "Kite & Comet", "Low Orbit Choir",
        ]
        let firstWords = ["Electric", "Silent", "Golden", "Hidden", "Broken", "Endless", "Violet", "Paper",
                          "Distant", "Northern", "Crystal", "Midnight", "Slow", "Burning", "Hollow", "Neon"]
        let secondWords = ["Rivers", "Signals", "Gardens", "Cities", "Echoes", "Satellites", "Summers", "Lights",
                           "Waves", "Mirrors", "Engines", "Horizons", "Letters", "Arcades", "Tides", "Orbits"]
        let genres = ["Alternative", "Electronic", "Indie Pop", "Ambient", "Synthwave", "Dream Pop", "Post-Rock"]
        let palette: [RGB] = [
            RGB(r: 198, g: 165, b: 255), RGB(r: 243, g: 166, b: 200), RGB(r: 148, g: 191, b: 255),
            RGB(r: 166, g: 227, b: 161), RGB(r: 249, g: 213, b: 139), RGB(r: 243, g: 139, b: 168),
        ]

        func title() -> String {
            "\(firstWords[rng.next(firstWords.count)]) \(secondWords[rng.next(secondWords.count)])"
        }

        let artists = artistNames.prefix(artistCount).enumerated().map { i, name in
            Artist(id: "ar\(i + 1)", name: name, artwork: ArtworkRef(key: "artist-\(i + 1)", averageColor: palette[i % palette.count], path: DemoArtwork.path(for: "artist-\(i + 1)")))
        }

        var albums: [Album] = []
        var tracks: [Track] = []
        var usedTitles = Set<String>()
        for a in 0..<albumCount {
            let artist = artists[a % artists.count]
            var albumTitle = title()
            while usedTitles.contains(albumTitle) { albumTitle = title() }
            usedTitles.insert(albumTitle)
            let albumID = "al\(a + 1)"
            let count = 8 + rng.next(5)
            let art = ArtworkRef(key: "album-\(a + 1)", averageColor: palette[rng.next(palette.count)], path: DemoArtwork.path(for: "album-\(a + 1)"))
            albums.append(Album(id: albumID, title: albumTitle, artist: artist.name, year: 1995 + rng.next(31),
                                genre: genres[rng.next(genres.count)], trackCount: count, artwork: art))
            for t in 0..<count {
                tracks.append(Track(id: "\(albumID)t\(t + 1)", title: title(), artist: artist.name, album: albumTitle,
                                    albumID: albumID, duration: TimeInterval(120 + rng.next(300)),
                                    trackNumber: t + 1, artwork: art))
            }
        }

        let playlistNames = ["Chill Mix", "New Music Mix", "Favorites Mix", "Get Up! Mix", "Discovery Station",
                             "Late Night Focus", "Rainy Day", "Deep Work"]
        var playlists: [Playlist] = []
        var playlistTrackIDs: [String: [String]] = [:]
        for p in 0..<min(playlistCount, playlistNames.count) {
            let id = "pl\(p + 1)"
            var ids: [String] = []
            let count = 12 + rng.next(14)
            while ids.count < count {
                let candidate = tracks[rng.next(tracks.count)].id
                if !ids.contains(candidate) { ids.append(candidate) }
            }
            playlistTrackIDs[id] = ids
            playlists.append(Playlist(id: id, name: playlistNames[p], curator: "Harmune Demo", trackCount: count,
                                      artwork: ArtworkRef(key: "playlist-\(p + 1)", averageColor: palette[p % palette.count], path: DemoArtwork.path(for: "playlist-\(p + 1)"))))
        }

        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
        self.playlistTrackIDs = playlistTrackIDs
        self.tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        self.albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
    }
}

/// Small deterministic PRNG so fixtures are identical on every machine.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
}

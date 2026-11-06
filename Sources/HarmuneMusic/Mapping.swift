import Foundation
import HarmuneCore
import MusicKit

/// Converts MusicKit items into Harmune's models, tagging IDs with their source.
///
/// Artwork is only fetched for what the UI draws: albums, playlist details and
/// the current track. Other rows report a cover only if it's already cached.
struct Mapping {
    let artwork: ArtworkStore

    static let unknownAlbum = "Unknown Album"
    static let unknownArtist = "Unknown Artist"

    /// Imported files can have no tags at all, and MusicKit reports those
    /// fields as empty strings.
    static func named(_ value: String?, or fallback: String) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return fallback }
        return value
    }

    /// Untagged albums would all read "Unknown Album", so their first track
    /// tells them apart.
    static func untitledAlbumName(firstTrack: String?) -> String {
        let track = named(firstTrack, or: "")
        return track.isEmpty ? unknownAlbum : "\(unknownAlbum) (\(track))"
    }

    private func tag(_ id: MusicItemID, _ source: MusicSource) -> String {
        MusicID(source: source, raw: id.rawValue).description
    }

    func track(_ s: MusicKit.Song, _ source: MusicSource, fetchArtwork: Bool = false) -> HarmuneCore.Track {
        let id = tag(s.id, source)
        return HarmuneCore.Track(id: id, title: s.title, artist: Self.named(s.artistName, or: Self.unknownArtist),
                                 album: Self.named(s.albumTitle, or: Self.unknownAlbum),
                                 duration: s.duration ?? 0, trackNumber: s.trackNumber,
                                 artwork: artwork.reference(for: s.artwork, key: id, fetch: fetchArtwork))
    }

    func track(_ t: MusicKit.Track, _ source: MusicSource) -> HarmuneCore.Track {
        let id = tag(t.id, source)
        return HarmuneCore.Track(id: id, title: t.title, artist: Self.named(t.artistName, or: Self.unknownArtist),
                                 album: Self.named(t.albumTitle, or: Self.unknownAlbum),
                                 duration: t.duration ?? 0, trackNumber: t.trackNumber,
                                 artwork: artwork.reference(for: t.artwork, key: id, fetch: false))
    }

    func album(_ a: MusicKit.Album, _ source: MusicSource) -> HarmuneCore.Album {
        let id = tag(a.id, source)
        return HarmuneCore.Album(id: id, title: Self.named(a.title, or: Self.unknownAlbum),
                                 artist: Self.named(a.artistName, or: Self.unknownArtist),
                                 year: a.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
                                 genre: a.genreNames.first, trackCount: a.trackCount,
                                 artwork: artwork.reference(for: a.artwork, key: id, fetch: true))
    }

    func artist(_ a: MusicKit.Artist, _ source: MusicSource) -> HarmuneCore.Artist {
        let id = tag(a.id, source)
        return HarmuneCore.Artist(id: id, name: a.name, artwork: artwork.reference(for: a.artwork, key: id, fetch: false))
    }

    /// MusicKit only knows a playlist's size once its tracks are loaded, so
    /// browse results use a count of 0, which the UI leaves blank.
    func playlist(_ p: MusicKit.Playlist, _ source: MusicSource, trackCount: Int = 0, fetchArtwork: Bool = false) -> HarmuneCore.Playlist {
        let id = tag(p.id, source)
        return HarmuneCore.Playlist(id: id, name: p.name, curator: p.curatorName, trackCount: trackCount,
                                    artwork: artwork.reference(for: p.artwork, key: id, fetch: fetchArtwork))
    }

    /// The player doesn't say whether an entry came from the catalog or the
    /// library, so queue tracks are tagged as catalog items for display.
    func track(_ entry: MusicPlayer.Queue.Entry, fetchArtwork: Bool = false) -> HarmuneCore.Track {
        switch entry.item {
        case .song(let song):
            return track(song, .catalog, fetchArtwork: fetchArtwork)
        default:
            return HarmuneCore.Track(id: entry.id, title: entry.title, artist: Self.named(entry.subtitle, or: Self.unknownArtist),
                                     album: Self.unknownAlbum, duration: (entry.endTime ?? 0) - (entry.startTime ?? 0),
                                     artwork: artwork.reference(for: entry.artwork, key: entry.id, fetch: fetchArtwork))
        }
    }

    func queueEntry(_ entry: MusicPlayer.Queue.Entry) -> QueueEntry {
        QueueEntry(id: entry.id, track: track(entry))
    }
}

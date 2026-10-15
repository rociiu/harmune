import Foundation
import HarmuneCore
import HarmuneIPC

enum Format {
    static func time(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func status(_ s: PlaybackState) -> String {
        guard let t = s.track else { return "■ Nothing playing" }
        let icon = s.isPlaying ? "▶" : "⏸"
        let pos = s.position(at: Date())
        var lines = ["\(icon) \(t.title) — \(t.artist)", "  \(t.album)"]
        lines.append("  \(bar(pos / max(t.duration, 1), width: 30)) \(time(pos)) / \(time(t.duration))")
        lines.append("  shuffle \(s.shuffle ? "on" : "off") · repeat \(s.repeat.rawValue)"
                     + (s.container.map { " · from \($0.kind.rawValue) “\($0.title)”" } ?? ""))
        return lines.joined(separator: "\n")
    }

    static func bar(_ fraction: Double, width: Int) -> String {
        let filled = Int((min(max(fraction, 0), 1) * Double(width)).rounded())
        return String(repeating: "━", count: filled) + "●" + String(repeating: "─", count: max(0, width - filled))
    }

    static func queue(_ q: QueueState) -> String {
        guard !q.entries.isEmpty else { return "Queue is empty" }
        return q.entries.enumerated().map { i, e in
            let marker = i == q.currentIndex ? "▶" : " "
            return "\(marker) \(pad(String(i + 1), 3)) \(pad(e.track.title, 32)) \(pad(e.track.artist, 22)) \(time(e.track.duration))  [\(e.id)]"
        }.joined(separator: "\n") + "\n\n\(q.entries.count) entries"
    }

    static func tracks(_ tracks: [Track]) -> String {
        tracks.map { "  \(pad($0.id, 9)) \(pad($0.title, 32)) \(pad($0.artist, 22)) \(time($0.duration))" }
            .joined(separator: "\n")
    }

    static func albums(_ albums: [Album]) -> String {
        albums.map { "  \(pad($0.id, 6)) \(pad($0.title, 30)) \(pad($0.artist, 22)) \($0.year.map(String.init) ?? "")" }
            .joined(separator: "\n")
    }

    static func search(_ r: SearchResults) -> String {
        var out: [String] = []
        if !r.songs.isEmpty { out += ["SONGS", tracks(r.songs)] }
        if !r.albums.isEmpty { out += ["", "ALBUMS", albums(r.albums)] }
        if !r.artists.isEmpty { out += ["", "ARTISTS"] + r.artists.map { "  \(pad($0.id, 6)) \($0.name)" } }
        if !r.playlists.isEmpty { out += ["", "PLAYLISTS"] + r.playlists.map { "  \(pad($0.id, 6)) \($0.name)" } }
        return out.isEmpty ? "No results" : out.joined(separator: "\n")
    }

    static func pad(_ s: String, _ width: Int) -> String {
        s.count > width ? String(s.prefix(width - 1)) + "…" : s.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }
}

/// `harmune status --json` shape from product_spec.md §16.5, plus detail.
struct StatusJSON: Encodable {
    var playing: Bool
    var track: String?
    var artist: String?
    var album: String?
    var trackID: String?
    var position: Double
    var duration: Double?
    var shuffle: Bool
    var `repeat`: RepeatMode

    init(_ s: PlaybackState) {
        playing = s.isPlaying
        track = s.track?.title; artist = s.track?.artist; album = s.track?.album; trackID = s.track?.id
        position = (s.position(at: Date()) * 10).rounded() / 10
        duration = s.track?.duration
        shuffle = s.shuffle; self.repeat = s.repeat
    }
}

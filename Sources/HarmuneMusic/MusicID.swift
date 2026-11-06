import HarmuneCore
import MusicKit

/// Where an item lives. MusicKit looks up catalog and library items through
/// different requests, and library IDs can't be told apart from catalog IDs
/// by their shape, so Harmune's IDs carry the source: `c:1440…` or `l:i.ab…`.
public enum MusicSource: String, Sendable {
    case catalog = "c", library = "l"
}

public struct MusicID: Hashable, Sendable, CustomStringConvertible {
    public var source: MusicSource
    public var raw: String

    public init(source: MusicSource, raw: String) {
        self.source = source
        self.raw = raw
    }

    /// Parses a Harmune ID. An untagged ID is treated as a catalog ID, so an
    /// ID copied from an Apple Music URL works from the CLI.
    public init?(_ string: String) {
        if let colon = string.firstIndex(of: ":"), let source = MusicSource(rawValue: String(string[..<colon])) {
            raw = String(string[string.index(after: colon)...])
            self.source = source
        } else {
            raw = string
            source = .catalog
        }
        if raw.isEmpty { return nil }
    }

    public var description: String { "\(source.rawValue):\(raw)" }
    var itemID: MusicItemID { MusicItemID(raw) }
}

enum AuthMapping {
    static func state(status: MusicAuthorization.Status, canPlayCatalog: Bool?) -> AuthStatus {
        switch status {
        case .notDetermined:
            return AuthStatus(state: .notDetermined, detail: "Run: harmune auth")
        case .denied:
            return AuthStatus(state: .denied, detail: "Allow Harmune in System Settings > Privacy & Security > Media & Apple Music")
        case .restricted:
            return AuthStatus(state: .restricted, detail: "Apple Music access is restricted on this Mac")
        case .authorized:
            if canPlayCatalog == false {
                return AuthStatus(state: .noSubscription, detail: "This Apple Account can't play Apple Music catalog content")
            }
            return AuthStatus(state: .authorized)
        @unknown default:
            return AuthStatus(state: .unavailable, detail: "Unknown authorization status")
        }
    }
}

/// Decides when a new player snapshot is worth sending to clients. Clients
/// extrapolate the position, so steady playback needs no updates.
enum PlaybackDiff {
    static let driftTolerance = 1.0

    static func shouldPublish(previous: PlaybackState, next: PlaybackState) -> Bool {
        if previous.track?.id != next.track?.id || previous.isPlaying != next.isPlaying
            || previous.shuffle != next.shuffle || previous.repeat != next.repeat
            || previous.container != next.container {
            return true
        }
        let expected = previous.position(at: next.positionTimestamp)
        return abs(expected - next.position) > driftTolerance
    }
}

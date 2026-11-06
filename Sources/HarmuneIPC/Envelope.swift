import Foundation
import HarmuneCore

/// One NDJSON frame. See docs/PROTOCOL.md.
public struct Envelope: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case command, response, event }

    public var version: Int
    public var type: Kind
    public var id: String?
    // command
    public var action: String?
    public var payload: JSONValue?
    // response
    public var success: Bool?
    public var result: JSONValue?
    public var error: HarmuneError?
    // event
    public var event: String?
    public var revision: UInt64?
    public var data: JSONValue?

    public init(version: Int = HarmuneVersion.protocolVersion, type: Kind, id: String? = nil,
                action: String? = nil, payload: JSONValue? = nil, success: Bool? = nil,
                result: JSONValue? = nil, error: HarmuneError? = nil, event: String? = nil,
                revision: UInt64? = nil, data: JSONValue? = nil) {
        self.version = version; self.type = type; self.id = id; self.action = action; self.payload = payload
        self.success = success; self.result = result; self.error = error; self.event = event
        self.revision = revision; self.data = data
    }

    public static func command(id: String, action: String, payload: JSONValue = .empty) -> Envelope {
        Envelope(type: .command, id: id, action: action, payload: payload)
    }

    public static func success(id: String?, result: JSONValue? = nil) -> Envelope {
        Envelope(type: .response, id: id, success: true, result: result)
    }

    public static func failure(id: String?, _ error: HarmuneError) -> Envelope {
        Envelope(type: .response, id: id, success: false, error: error)
    }

    public static func event(_ name: String, revision: UInt64? = nil, data: JSONValue) -> Envelope {
        Envelope(type: .event, event: name, revision: revision, data: data)
    }

    public func encoded() throws -> Data {
        var data = try WireCoding.encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ frame: Data) throws -> Envelope {
        try WireCoding.decoder.decode(Envelope.self, from: frame)
    }
}

/// Action and event names. Keep in sync with docs/PROTOCOL.md.
public enum Action {
    public static let hello = "session.hello"
    public static let subscribe = "session.subscribe"

    public static let authStatus = "auth.status"
    public static let authRequest = "auth.request"

    public static let state = "playback.state"
    public static let play = "playback.play"
    public static let pause = "playback.pause"
    public static let toggle = "playback.toggle"
    public static let next = "playback.next"
    public static let previous = "playback.previous"
    public static let seek = "playback.seek"
    public static let shuffle = "playback.shuffle"
    public static let `repeat` = "playback.repeat"

    public static let queue = "queue.get"
    public static let enqueue = "queue.add"
    public static let queueRemove = "queue.remove"
    public static let queueMove = "queue.move"
    public static let queueClear = "queue.clear"

    public static let search = "catalog.search"
    public static let librarySongs = "library.songs"
    public static let libraryAlbums = "library.albums"
    public static let libraryArtists = "library.artists"
    public static let libraryPlaylists = "library.playlists"
    public static let album = "browse.album"
    public static let artist = "browse.artist"
    public static let playlist = "browse.playlist"
    public static let home = "browse.home"

    public static let serviceStatus = "service.status"
    public static let serviceStop = "service.stop"
}

public enum EventName {
    public static let playbackChanged = "playback.changed"
    public static let queueChanged = "queue.changed"
    public static let authorizationChanged = "authorization.changed"
}

public enum Topic: String, Codable, Sendable, CaseIterable { case playback, queue, authorization }

// MARK: - Typed payloads

public struct Hello: Codable, Sendable {
    public enum Client: String, Codable, Sendable { case tui, cli }
    public var protocolVersion: Int
    public var client: Client
    public var pid: Int32
    public init(protocolVersion: Int = HarmuneVersion.protocolVersion, client: Client, pid: Int32 = getpid()) {
        self.protocolVersion = protocolVersion; self.client = client; self.pid = pid
    }
}

public struct Welcome: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var hostVersion: String
    public var capabilities: [Capability]
    public init(protocolVersion: Int, hostVersion: String, capabilities: [Capability]) {
        self.protocolVersion = protocolVersion; self.hostVersion = hostVersion; self.capabilities = capabilities
    }
}

public struct SubscribePayload: Codable, Sendable { public var topics: [Topic] }
public struct SeekPayload: Codable, Sendable { public var position: TimeInterval }
public struct BoolPayload: Codable, Sendable { public var on: Bool }
public struct RepeatPayload: Codable, Sendable { public var mode: RepeatMode }
public struct EnqueuePayload: Codable, Sendable { public var songIDs: [String]; public var position: EnqueuePosition }
public struct EntryPayload: Codable, Sendable { public var entryID: String; public var index: Int? }
public struct IDPayload: Codable, Sendable { public var id: String }
public struct PagePayload: Codable, Sendable {
    public var sort: SortKey?
    public var offset: Int
    public var limit: Int
}

public struct ServiceStatus: Codable, Sendable, Equatable {
    public var pid: Int32
    public var hostVersion: String
    public var backend: String
    public var uptime: TimeInterval
    public var clients: Int
    public var isPlaying: Bool
    public init(pid: Int32, hostVersion: String, backend: String, uptime: TimeInterval, clients: Int, isPlaying: Bool) {
        self.pid = pid; self.hostVersion = hostVersion; self.backend = backend; self.uptime = uptime
        self.clients = clients; self.isPlaying = isPlaying
    }
}

public struct StopPayload: Codable, Sendable { public var force: Bool }

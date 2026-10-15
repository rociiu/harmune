import Foundation
import HarmuneCore

/// Maps wire commands to `MusicBackend` calls. Session-level actions
/// (hello, subscribe, service.*) are handled by `IPCServer`.
public struct CommandDispatcher: Sendable {
    public let backend: any MusicBackend
    public init(backend: any MusicBackend) { self.backend = backend }

    public func handle(action: String, payload: JSONValue) async throws -> JSONValue? {
        let b = backend
        switch action {
        case Action.authStatus: return try JSONValue(encoding: await b.authStatus())
        case Action.authRequest: return try JSONValue(encoding: await b.requestAuthorization())

        case Action.state: return try JSONValue(encoding: await b.playbackState())
        case Action.play: try await b.play(payload.decode(PlayRequest.self))
        case Action.pause: try await b.pause()
        case Action.toggle: try await b.togglePlayPause()
        case Action.next: try await b.next()
        case Action.previous: try await b.previous()
        case Action.seek:
            let p = try payload.decode(SeekPayload.self)
            guard p.position.isFinite, p.position >= 0 else { throw HarmuneError.invalid("position must be >= 0") }
            try await b.seek(to: p.position)
        case Action.shuffle: try await b.setShuffle(payload.decode(BoolPayload.self).on)
        case Action.repeat: try await b.setRepeat(payload.decode(RepeatPayload.self).mode)

        case Action.queue: return try JSONValue(encoding: await b.queueState())
        case Action.enqueue:
            let p = try payload.decode(EnqueuePayload.self)
            guard !p.songIDs.isEmpty, p.songIDs.count <= 500 else { throw HarmuneError.invalid("songIDs must have 1–500 items") }
            try await b.enqueue(songIDs: p.songIDs, at: p.position)
        case Action.queueRemove: try await b.removeFromQueue(entryID: payload.decode(EntryPayload.self).entryID)
        case Action.queueMove:
            let p = try payload.decode(EntryPayload.self)
            guard let index = p.index else { throw HarmuneError.invalid("index is required") }
            try await b.moveQueueEntry(entryID: p.entryID, to: index)
        case Action.queueClear: try await b.clearUpcoming()

        case Action.search:
            var q = try payload.decode(SearchQuery.self)
            q.limit = min(max(q.limit, 1), 100)
            return try JSONValue(encoding: await b.search(q))
        case Action.librarySongs:
            let p = try page(payload)
            return try JSONValue(encoding: await b.librarySongs(sort: p.sort ?? .title, offset: p.offset, limit: p.limit))
        case Action.libraryAlbums:
            let p = try page(payload)
            return try JSONValue(encoding: await b.libraryAlbums(sort: p.sort ?? .title, offset: p.offset, limit: p.limit))
        case Action.libraryArtists:
            let p = try page(payload)
            return try JSONValue(encoding: await b.libraryArtists(offset: p.offset, limit: p.limit))
        case Action.libraryPlaylists:
            let p = try page(payload)
            return try JSONValue(encoding: await b.libraryPlaylists(offset: p.offset, limit: p.limit))
        case Action.album: return try JSONValue(encoding: await b.album(id: payload.decode(IDPayload.self).id))
        case Action.artist: return try JSONValue(encoding: await b.artist(id: payload.decode(IDPayload.self).id))
        case Action.playlist: return try JSONValue(encoding: await b.playlist(id: payload.decode(IDPayload.self).id))
        case Action.home: return try JSONValue(encoding: await b.home())

        default:
            throw HarmuneError.unsupported("Action '\(action)'")
        }
        return nil
    }

    private func page(_ payload: JSONValue) throws -> PagePayload {
        var p = try payload.decode(PagePayload.self)
        p.offset = max(0, p.offset)
        p.limit = min(max(p.limit, 1), 200)
        return p
    }
}

import Foundation
import Synchronization
import Testing
@testable import HarmuneCore
@testable import HarmuneDemo

/// Manually advanced clock.
final class TestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 0))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@Suite struct DemoBackendTests {
    let clock = TestClock()
    var backend: DemoBackend { DemoBackend(now: { [clock] in clock.now }, autoTick: false) }

    @Test func libraryIsDeterministic() {
        let a = DemoLibrary(seed: 1), b = DemoLibrary(seed: 1)
        #expect(a.albums == b.albums)
        #expect(a.tracks.count == b.tracks.count)
        #expect(DemoLibrary.standard.albums.count == 30)
        #expect(Set(DemoLibrary.standard.albums.map(\.title)).count == 30)
    }

    @Test func playAlbumFromTrack() async throws {
        let b = backend
        try await b.play(.container(.album, id: "al1", startIndex: 2))
        let s = await b.playbackState(), q = await b.queueState()
        #expect(s.isPlaying)
        #expect(s.track?.id == "al1t3")
        #expect(s.container?.id == "al1")
        #expect(q.currentIndex == 2)
        #expect(q.entries.count == DemoLibrary.standard.tracks(inAlbum: "al1").count)
    }

    @Test func autoAdvanceAndStopAtEnd() async throws {
        let b = backend
        let lib = DemoLibrary.standard
        let tracks = lib.tracks(inAlbum: "al1")
        try await b.play(.container(.album, id: "al1", startIndex: tracks.count - 1))
        clock.advance(tracks.last!.duration + 1)
        await b.tick()
        let s = await b.playbackState()
        #expect(!s.isPlaying)
        #expect(s.track?.id == tracks.last!.id)
    }

    @Test func repeatAllWrapsAndRepeatOneRestarts() async throws {
        let b = backend
        let tracks = DemoLibrary.standard.tracks(inAlbum: "al1")
        try await b.play(.container(.album, id: "al1", startIndex: tracks.count - 1))
        await b.setRepeat(.all)
        clock.advance(tracks.last!.duration)
        await b.tick()
        #expect(await b.playbackState().track?.id == tracks[0].id)

        await b.setRepeat(.one)
        clock.advance(tracks[0].duration)
        await b.tick()
        let s = await b.playbackState()
        #expect(s.track?.id == tracks[0].id)
        #expect(s.position(at: clock.now) == 0)
    }

    @Test func pauseFreezesPosition() async throws {
        let b = backend
        try await b.play(.song(id: "al1t1"))
        clock.advance(10)
        await b.pause()
        clock.advance(100)
        #expect(await b.playbackState().position(at: clock.now) == 10)
    }

    @Test func previousRestartsAfterThreeSeconds() async throws {
        let b = backend
        try await b.play(.container(.album, id: "al1", startIndex: 1))
        clock.advance(10)
        try await b.previous()
        #expect(await b.playbackState().track?.id == "al1t2")
        try await b.previous()
        #expect(await b.playbackState().track?.id == "al1t1")
    }

    @Test func enqueueNextAndLast() async throws {
        let b = backend
        try await b.play(.container(.album, id: "al1", startIndex: 0))
        try await b.enqueue(songIDs: ["al2t1"], at: .next)
        try await b.enqueue(songIDs: ["al2t2"], at: .last)
        let q = await b.queueState()
        #expect(q.entries[1].track.id == "al2t1")
        #expect(q.entries.last?.track.id == "al2t2")
    }

    @Test func enqueueOnEmptyQueueSelectsFirst() async throws {
        let b = backend
        try await b.enqueue(songIDs: ["al3t1"], at: .last)
        #expect(await b.playbackState().track?.id == "al3t1")
        #expect(await b.playbackState().isPlaying == false)
    }

    @Test func removeAndMove() async throws {
        let b = backend
        try await b.play(.container(.album, id: "al1", startIndex: 0))
        var q = await b.queueState()
        let current = q.entries[0].id
        await #expect(throws: HarmuneError.self) { try await b.removeFromQueue(entryID: current) }

        let third = q.entries[2].id
        try await b.moveQueueEntry(entryID: third, to: 1)
        q = await b.queueState()
        #expect(q.entries[1].id == third)

        try await b.removeFromQueue(entryID: third)
        q = await b.queueState()
        #expect(!q.entries.contains { $0.id == third })
        await #expect(throws: HarmuneError.self) { try await b.moveQueueEntry(entryID: current, to: 2) }
    }

    @Test func shuffleKeepsCurrentAndRestoresOrder() async throws {
        let b = backend
        try await b.play(.container(.album, id: "al1", startIndex: 1))
        let original = await b.queueState().entries.map(\.id)
        await b.setShuffle(true)
        let shuffled = await b.queueState().entries.map(\.id)
        #expect(Array(shuffled.prefix(2)) == Array(original.prefix(2)))
        #expect(Set(shuffled) == Set(original))
        await b.setShuffle(false)
        #expect(await b.queueState().entries.map(\.id) == original)
    }

    @Test func clearUpcomingKeepsHistoryAndCurrent() async throws {
        let b = backend
        try await b.play(.container(.album, id: "al1", startIndex: 2))
        await b.clearUpcoming()
        #expect(await b.queueState().entries.count == 3)
    }

    @Test func searchPaginates() async throws {
        let b = backend
        let first = try await b.search(SearchQuery(text: "e", limit: 10))
        #expect(first.songs.count == 10)
        let offset = try #require(first.nextOffset)
        let second = try await b.search(SearchQuery(text: "e", offset: offset, limit: 10))
        #expect(Set(first.songs.map(\.id)).isDisjoint(with: second.songs.map(\.id)))
        #expect(second.albums.isEmpty)  // non-song kinds only on page one
    }

    @Test func libraryPagination() async throws {
        let b = backend
        let page = try await b.libraryAlbums(sort: .title, offset: 25, limit: 10)
        #expect(page.items.count == 5)
        #expect(page.nextOffset == nil)
    }

    @Test func emitsEvents() async throws {
        let b = backend
        let stream = await b.events()
        try await b.play(.song(id: "al1t1"))
        var sawPlayback = false, sawQueue = false
        for await event in stream {
            switch event {
            case .playback(let s) where s.isPlaying: sawPlayback = true
            case .queue(let q) where !q.entries.isEmpty: sawQueue = true
            default: break
            }
            if sawPlayback && sawQueue { break }
        }
        #expect(sawPlayback && sawQueue)
    }

    @Test func notFoundErrors() async {
        let b = backend
        await #expect(throws: HarmuneError.notFound("Song nope")) { try await b.play(.song(id: "nope")) }
        await #expect(throws: HarmuneError.self) { try await b.album(id: "nope") }
    }
}

import Foundation
import Testing
@testable import HarmuneCore

@Suite struct PathsTests {
    @Test func currentExecutableIsTheRealFile() throws {
        let exe = HarmunePaths.currentExecutable()
        #expect(exe.path.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: exe.path))
        let values = try exe.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == false)
    }
}

@Suite struct PlaybackStateTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let track = Track(id: "t", title: "T", artist: "A", album: "Al", duration: 100)

    @Test func extrapolatesWhilePlaying() {
        let s = PlaybackState(track: track, isPlaying: true, position: 10, positionTimestamp: t0, rate: 1)
        #expect(s.position(at: t0.addingTimeInterval(5)) == 15)
    }

    @Test func frozenWhilePaused() {
        let s = PlaybackState(track: track, isPlaying: false, position: 10, positionTimestamp: t0, rate: 0)
        #expect(s.position(at: t0.addingTimeInterval(50)) == 10)
    }

    @Test func clampsToDurationAndZero() {
        let s = PlaybackState(track: track, isPlaying: true, position: 95, positionTimestamp: t0, rate: 1)
        #expect(s.position(at: t0.addingTimeInterval(60)) == 100)
        #expect(s.position(at: t0.addingTimeInterval(-60)) == 95)
    }

    @Test func repeatCycles() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
    }

    @Test func playRequestRoundTrips() throws {
        let requests: [PlayRequest] = [.song(id: "a"), .container(.album, id: "b", startIndex: 2), .queueEntry(id: "q1"), .resume]
        for r in requests {
            let decoded = try JSONDecoder().decode(PlayRequest.self, from: JSONEncoder().encode(r))
            #expect(decoded == r)
        }
    }

    @Test func upcomingSlice() {
        let e = (1...4).map { QueueEntry(id: "q\($0)", track: track) }
        #expect(QueueState(entries: e, currentIndex: 1).upcoming.map(\.id) == ["q3", "q4"])
        #expect(QueueState(entries: e, currentIndex: 3).upcoming.isEmpty)
        #expect(QueueState(entries: e, currentIndex: nil).upcoming.count == 4)
    }

    @Test func socketPathOverrideAndFallback() {
        #expect(HarmunePaths.socketPath(environment: ["HARMUNE_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(HarmunePaths.socketPath(environment: [:]).utf8.count <= HarmunePaths.maxSocketPathLength)
        #expect(HarmunePaths.lockPath(forSocket: "/a/host.sock") == "/a/host.lock")
    }
}

import Darwin
import Foundation
import Testing
@testable import HarmuneCore
@testable import HarmuneDemo
@testable import HarmuneIPC

@Suite struct FramingTests {
    @Test func splitsAcrossChunks() throws {
        var s = FrameSplitter()
        #expect(try s.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(try s.append(Data(":2}\n\n".utf8)) == [Data("{\"b\":2}".utf8)])
    }

    @Test func rejectsOversizedFrame() {
        var s = FrameSplitter()
        #expect(throws: FrameSplitter.SplitError.self) {
            _ = try s.append(Data(repeating: 0x61, count: FrameSplitter.maxFrameSize + 1))
        }
    }

    @Test func envelopeRoundTrip() throws {
        let state = PlaybackState(track: Track(id: "1", title: "T", artist: "A", album: "B", duration: 200),
                                  isPlaying: true, position: 12.5,
                                  positionTimestamp: Date(timeIntervalSince1970: 1_760_000_000.25), rate: 1, revision: 7)
        let env = Envelope.event(EventName.playbackChanged, revision: 7, data: try JSONValue(encoding: state))
        let data = try env.encoded()
        #expect(data.last == 0x0A)
        let decoded = try Envelope.decode(data.dropLast())
        #expect(decoded == env)
        #expect(try decoded.data?.decode(PlaybackState.self) == state)
    }

    @Test func matchesSpecCommandShape() throws {
        let json = #"{"version":1,"id":"123","type":"command","action":"playback.pause","payload":{}}"#
        let env = try Envelope.decode(Data(json.utf8))
        #expect(env.type == .command && env.action == Action.pause && env.id == "123")
    }
}

@Suite(.serialized) struct ServerClientTests {
    func makeServer() throws -> (IPCServer, DemoBackend, String) {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("hm-\(UUID().uuidString.prefix(8)).sock")
        let backend = DemoBackend(autoTick: false)
        let server = IPCServer(socketPath: path, backend: backend, backendName: "demo")
        server.onStopRequested = {}
        try server.start()
        return (server, backend, path)
    }

    @Test func helloAndCapabilities() async throws {
        let (server, _, path) = try makeServer()
        defer { server.stop() }
        let remote = try await RemoteBackend.connect(path: path, client: .tui)
        #expect(remote.welcome.protocolVersion == HarmuneVersion.protocolVersion)
        #expect(await remote.capabilities() == Set(Capability.allCases))
    }

    @Test func commandsRequireHello() async throws {
        let (server, _, path) = try makeServer()
        defer { server.stop() }
        let client = try IPCClient.connect(path: path)
        await #expect(throws: HarmuneError.self) { try await client.request(Action.pause) }
    }

    @Test func playbackAndBrowseOverSocket() async throws {
        let (server, _, path) = try makeServer()
        defer { server.stop() }
        let remote = try await RemoteBackend.connect(path: path, client: .cli)
        try await remote.play(.container(.album, id: "al2", startIndex: 1))
        let s = await remote.playbackState()
        #expect(s.track?.id == "al2t2" && s.isPlaying)
        try await remote.enqueue(songIDs: ["al3t1"], at: .next)
        #expect(await remote.queueState().entries[2].track.id == "al3t1")
        let album = try await remote.album(id: "al2")
        #expect(album.tracks.count == album.album.trackCount)
        let results = try await remote.search(SearchQuery(text: "neon"))
        #expect(!results.artists.isEmpty)
    }

    @Test func errorsAreTyped() async throws {
        let (server, _, path) = try makeServer()
        defer { server.stop() }
        let remote = try await RemoteBackend.connect(path: path, client: .cli)
        do {
            try await remote.play(.song(id: "missing"))
            Issue.record("Expected an error")
        } catch let e as HarmuneError {
            #expect(e.code == .notFound)
        }
        do {
            try await remote.client.request("bogus.action")
            Issue.record("Expected an error")
        } catch let e as HarmuneError {
            #expect(e.code == .unsupported)
        }
        do {
            try await remote.client.request(Action.seek, payload: .object(["position": .number(-5)]))
            Issue.record("Expected an error")
        } catch let e as HarmuneError {
            #expect(e.code == .invalidArgument)
        }
    }

    @Test func eventsFanOutToSubscribers() async throws {
        let (server, backend, path) = try makeServer()
        defer { server.stop() }
        let a = try await RemoteBackend.connect(path: path, client: .tui)
        let b = try await RemoteBackend.connect(path: path, client: .tui)
        let streamA = await a.events(), streamB = await b.events()
        try await backend.play(.song(id: "al5t1"))

        func firstPlaying(_ s: AsyncStream<BackendEvent>) async -> String? {
            for await e in s { if case .playback(let p) = e, p.isPlaying { return p.track?.id } }
            return nil
        }
        async let ta = firstPlaying(streamA)
        async let tb = firstPlaying(streamB)
        #expect(await ta == "al5t1")
        #expect(await tb == "al5t1")
    }

    @Test func malformedFramesDoNotKillServer() async throws {
        let (server, _, path) = try makeServer()
        defer { server.stop() }
        let fd = try UnixSocket.connect(path: path)
        // The server may hang up partway through, which must not kill this process.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        for junk in ["not json\n", "{\"version\":1}\n", "[1,2,3]\n", String(repeating: "x", count: 5000) + "\n"] {
            _ = junk.withCString { write(fd, $0, strlen($0)) }
        }
        close(fd)
        let remote = try await RemoteBackend.connect(path: path, client: .cli)
        #expect(await remote.authStatus().state == .authorized)
    }

    @Test func singleInstanceLock() throws {
        let (server, backend, path) = try makeServer()
        defer { server.stop() }
        let second = IPCServer(socketPath: path, backend: backend, backendName: "demo")
        #expect(throws: IPCError.self) { try second.start() }
    }

    @Test func socketIsPrivate() throws {
        let (server, _, path) = try makeServer()
        defer { server.stop() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func serviceStopRefusesWhilePlayingUnlessForced() async throws {
        let (server, _, path) = try makeServer()
        defer { server.stop() }
        let remote = try await RemoteBackend.connect(path: path, client: .cli)
        try await remote.play(.song(id: "al1t1"))
        await #expect(throws: HarmuneError.self) { try await remote.stopService(force: false) }
        try await remote.stopService(force: true)
    }
}

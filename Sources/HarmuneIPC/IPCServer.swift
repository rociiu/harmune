import Darwin
import Foundation
import HarmuneCore

/// The host side of the socket: accepts clients, answers commands and
/// fans backend events out to subscribed clients.
public final class IPCServer: @unchecked Sendable {
    public static let maxClients = 16

    public let socketPath: String
    private let dispatcher: CommandDispatcher
    private let backendName: String
    private let startedAt = Date()
    private let queue = DispatchQueue(label: "harmune.server")
    private var listenFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var eventTask: Task<Void, Never>?
    private let idleTimeout: TimeInterval?
    private var idleSince: Date?

    /// Called when a client asks the host to stop. Default: exit(0).
    public var onStopRequested: @Sendable () -> Void = { exit(0) }
    /// Called whenever the number of clients changes (for idle exit).
    public var onClientCountChanged: @Sendable (Int) -> Void = { _ in }

    final class Session: @unchecked Sendable {
        let connection: FramedConnection
        var greeted = false
        var topics: Set<Topic> = []
        init(_ c: FramedConnection) { connection = c }
    }

    public init(socketPath: String, backend: any MusicBackend, backendName: String, idleMinutes: Double = 0) {
        self.socketPath = socketPath
        self.dispatcher = CommandDispatcher(backend: backend)
        self.backendName = backendName
        let timeout = idleMinutes * 60
        idleTimeout = timeout.isFinite && timeout > 0 ? timeout : nil
    }

    // deinit can run on `queue` (when a queued block drops the last
    // reference), so it must not `queue.sync`. No other references exist.
    deinit { teardown { $0() } }

    public func start() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        // Single-instance guard.
        lockFD = open(HarmunePaths.lockPath(forSocket: socketPath), O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
            throw IPCError.alreadyRunning
        }

        unlink(socketPath)
        let fd = try UnixSocket.makeSocket()
        var addr = try UnixSocket.address(socketPath)
        let oldMask = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard rc == 0, listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw IPCError.socket("bind/listen \(socketPath): \(message)")
        }
        chmod(socketPath, 0o600)
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptClient() }
        src.resume()
        acceptSource = src

        let backend = dispatcher.backend
        eventTask = Task { [weak self] in
            for await event in await backend.events() {
                self?.broadcast(event)
            }
        }
    }

    /// Stops listening and disconnects clients. Must not be called from
    /// the server's own callbacks.
    public func stop() { teardown { queue.sync(execute: $0) } }

    private func teardown(_ onQueue: (() -> Void) -> Void) {
        eventTask?.cancel()
        eventTask = nil
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1; unlink(socketPath) }
        onQueue { for s in sessions.values { s.connection.close() }; sessions.removeAll() }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
    }

    public var clientCount: Int { queue.sync { sessions.count } }

    func idleTimedOut(isPlaying: Bool) -> Bool {
        queue.sync {
            guard let idleTimeout, !isPlaying, sessions.isEmpty else {
                idleSince = nil
                return false
            }
            let now = Date()
            let since = idleSince ?? now
            idleSince = since
            return now.timeIntervalSince(since) >= idleTimeout
        }
    }

    // MARK: - Connections

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let connection = FramedConnection(fd: fd, label: "server.\(fd)")
        // Only the same user may control playback.
        guard connection.peerUID == getuid(), sessions.count < Self.maxClients else {
            connection.close(); return
        }
        let session = Session(connection)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        onClientCountChanged(sessions.count)
        connection.start(
            onFrame: { [weak self] frame in self?.received(frame, from: key) },
            onClose: { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.sessions[key] = nil
                    self.onClientCountChanged(self.sessions.count)
                }
            })
    }

    private func received(_ frame: Data, from key: ObjectIdentifier) {
        let envelope: Envelope
        do { envelope = try Envelope.decode(frame) } catch {
            queue.async { [self] in
                sessions[key]?.connection.send(.failure(id: nil, .invalid("Malformed frame")))
            }
            return
        }
        guard envelope.type == .command, let action = envelope.action else {
            queue.async { [self] in
                sessions[key]?.connection.send(.failure(id: envelope.id, .invalid("Expected a command")))
            }
            return
        }
        let payload = envelope.payload ?? .empty
        let id = envelope.id

        if action != Action.hello, !queue.sync(execute: { sessions[key]?.greeted ?? false }) {
            reply(key, .failure(id: id, .invalid("Send \(Action.hello) first")))
            return
        }

        switch action {
        case Action.hello:
            handleHello(id: id, payload: payload, key: key)
        case Action.subscribe:
            queue.async { [self] in
                guard let session = sessions[key] else { return }
                do {
                    session.topics = Set(try payload.decode(SubscribePayload.self).topics)
                    session.connection.send(.success(id: id))
                } catch {
                    session.connection.send(.failure(id: id, .invalid("Bad subscribe payload")))
                }
            }
        case Action.serviceStatus:
            Task { [self] in
                let playing = await dispatcher.backend.playbackState().isPlaying
                let status = queue.sync {
                    let now = Date()
                    // A status request is itself a client. Estimate the time
                    // remaining once this caller disconnects.
                    let idleExitIn = !playing && sessions.count == 1 ? idleTimeout.map {
                        max(0, $0 - now.timeIntervalSince(idleSince ?? now))
                    } : nil
                    return ServiceStatus(pid: getpid(), hostVersion: HarmuneVersion.current, backend: backendName,
                                         uptime: now.timeIntervalSince(startedAt), clients: sessions.count,
                                         isPlaying: playing, idleExitIn: idleExitIn)
                }
                reply(key, .success(id: id, result: try? JSONValue(encoding: status)))
            }
        case Action.serviceStop:
            Task { [self] in
                let force = (try? payload.decode(StopPayload.self).force) ?? false
                if !force, await dispatcher.backend.playbackState().isPlaying {
                    reply(key, .failure(id: id, .init(.invalidArgument, "Music is playing; pass force to stop")))
                    return
                }
                reply(key, .success(id: id))
                try? await Task.sleep(for: .milliseconds(100))
                onStopRequested()
            }
        default:
            Task { [self] in
                do {
                    let result = try await dispatcher.handle(action: action, payload: payload)
                    reply(key, .success(id: id, result: result))
                } catch let error as HarmuneError {
                    reply(key, .failure(id: id, error))
                } catch is DecodingError {
                    reply(key, .failure(id: id, .invalid("Invalid payload for \(action)")))
                } catch {
                    reply(key, .failure(id: id, .init(.internal, String(describing: error))))
                }
            }
        }
    }

    private func handleHello(id: String?, payload: JSONValue, key: ObjectIdentifier) {
        Task { [self] in
            guard let hello = try? payload.decode(Hello.self) else {
                reply(key, .failure(id: id, .invalid("Bad hello payload"))); return
            }
            guard hello.protocolVersion == HarmuneVersion.protocolVersion else {
                reply(key, .failure(id: id, .init(.unsupported,
                    "Protocol \(hello.protocolVersion) unsupported; host speaks \(HarmuneVersion.protocolVersion)",
                    recoverable: false)))
                return
            }
            let caps = await dispatcher.backend.capabilities().sorted { $0.rawValue < $1.rawValue }
            let welcome = Welcome(protocolVersion: HarmuneVersion.protocolVersion,
                                  hostVersion: HarmuneVersion.current, capabilities: caps)
            queue.async { [self] in self.sessions[key]?.greeted = true }
            reply(key, .success(id: id, result: try? JSONValue(encoding: welcome)))
        }
    }

    private func reply(_ key: ObjectIdentifier, _ envelope: Envelope) {
        queue.async { [self] in sessions[key]?.connection.send(envelope) }
    }

    private func broadcast(_ event: BackendEvent) {
        let topic: Topic, envelope: Envelope
        switch event {
        case .playback(let s):
            topic = .playback
            envelope = .event(EventName.playbackChanged, revision: s.revision, data: (try? JSONValue(encoding: s)) ?? .null)
        case .queue(let q):
            topic = .queue
            envelope = .event(EventName.queueChanged, revision: q.revision, data: (try? JSONValue(encoding: q)) ?? .null)
        case .auth(let a):
            topic = .authorization
            envelope = .event(EventName.authorizationChanged, data: (try? JSONValue(encoding: a)) ?? .null)
        }
        guard let data = try? envelope.encoded() else { return }
        queue.async { [self] in
            for s in sessions.values where s.topics.contains(topic) { s.connection.send(data) }
        }
    }
}

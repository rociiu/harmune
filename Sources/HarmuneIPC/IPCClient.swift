import Foundation
import HarmuneCore
import Synchronization

/// Client side of the socket: request/response correlation, timeouts and
/// an event stream.
public final class IPCClient: Sendable {
    public static let defaultTimeout: Duration = .seconds(5)
    public static let slowTimeout: Duration = .seconds(30)

    private let connection: FramedConnection
    private let state = Mutex(State())
    private let eventContinuation: AsyncStream<Envelope>.Continuation
    /// Events pushed by the host. Finishes when the connection closes.
    public let events: AsyncStream<Envelope>

    private struct State {
        var nextID: UInt64 = 1
        var pending: [String: CheckedContinuation<Envelope, Error>] = [:]
        var closed = false
    }

    public static func connect(path: String = HarmunePaths.socketPath()) throws -> IPCClient {
        IPCClient(fd: try UnixSocket.connect(path: path))
    }

    private init(fd: Int32) {
        connection = FramedConnection(fd: fd, label: "client")
        (events, eventContinuation) = AsyncStream.makeStream(of: Envelope.self, bufferingPolicy: .bufferingNewest(256))
        connection.start(
            onFrame: { [weak self] frame in self?.received(frame) },
            onClose: { [weak self] in self?.closed() })
    }

    deinit { connection.close() }

    public func close() { connection.close() }

    /// Sends a command and returns its `result` (or throws its error).
    @discardableResult
    public func request(_ action: String, payload: JSONValue = .empty,
                        timeout: Duration = IPCClient.defaultTimeout) async throws -> JSONValue? {
        let id = state.withLock { s -> String in defer { s.nextID += 1 }; return String(s.nextID) }
        let response: Envelope = try await withCheckedThrowingContinuation { cont in
            let accepted = state.withLock { s -> Bool in
                if s.closed { return false }
                s.pending[id] = cont
                return true
            }
            guard accepted else {
                cont.resume(throwing: HarmuneError(.disconnected, "Not connected to the Harmune host")); return
            }
            connection.send(.command(id: id, action: action, payload: payload))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.fail(id, HarmuneError(.timeout, "\(action) timed out"))
            }
        }
        if response.success == true { return response.result }
        throw response.error ?? HarmuneError(.internal, "Malformed response")
    }

    public func request<T: Decodable>(_ action: String, payload: JSONValue = .empty, as: T.Type,
                                      timeout: Duration = IPCClient.defaultTimeout) async throws -> T {
        guard let result = try await request(action, payload: payload, timeout: timeout) else {
            throw HarmuneError(.internal, "\(action) returned no result")
        }
        return try result.decode(T.self)
    }

    public func hello(client: Hello.Client) async throws -> Welcome {
        try await request(Action.hello, payload: JSONValue(encoding: Hello(client: client)), as: Welcome.self)
    }

    public func subscribe(_ topics: [Topic] = Topic.allCases) async throws {
        try await request(Action.subscribe, payload: JSONValue(encoding: SubscribePayload(topics: topics)))
    }

    // MARK: - Private

    private func received(_ frame: Data) {
        guard let envelope = try? Envelope.decode(frame) else { return }
        switch envelope.type {
        case .event: eventContinuation.yield(envelope)
        case .response:
            guard let id = envelope.id else { return }
            let cont = state.withLock { $0.pending.removeValue(forKey: id) }
            cont?.resume(returning: envelope)
        case .command: break
        }
    }

    private func fail(_ id: String, _ error: Error) {
        let cont = state.withLock { $0.pending.removeValue(forKey: id) }
        cont?.resume(throwing: error)
    }

    private func closed() {
        let pending = state.withLock { s -> [CheckedContinuation<Envelope, Error>] in
            s.closed = true
            defer { s.pending.removeAll() }
            return Array(s.pending.values)
        }
        for cont in pending { cont.resume(throwing: HarmuneError(.disconnected, "Connection to host closed")) }
        eventContinuation.finish()
    }
}

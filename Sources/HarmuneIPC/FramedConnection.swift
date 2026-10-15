import Darwin
import Foundation

/// Splits a byte stream into newline-delimited frames.
public struct FrameSplitter: Sendable {
    public static let maxFrameSize = 1 << 20  // 1 MiB

    private var buffer = Data()
    public init() {}

    public enum SplitError: Error { case frameTooLarge }

    /// Appends bytes and returns every complete frame (without the newline).
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[buffer.startIndex..<newline]
            if !frame.isEmpty { frames.append(Data(frame)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > Self.maxFrameSize { throw SplitError.frameTooLarge }
        return frames
    }
}

/// A Unix socket connection exchanging NDJSON frames.
///
/// All state is confined to `queue`. Reads are event-driven; writes are
/// performed synchronously on the queue.
public final class FramedConnection: @unchecked Sendable {
    public let peerUID: uid_t?
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var splitter = FrameSplitter()
    private var closed = false

    private var onFrame: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?

    init(fd: Int32, label: String) {
        self.fd = fd
        self.queue = DispatchQueue(label: "harmune.conn.\(label)")
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var uid: uid_t = 0, gid: gid_t = 0
        peerUID = getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    public func start(onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.onFrame = onFrame
            self.onClose = onClose
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.readAvailable() }
            src.setCancelHandler { [fd] in Darwin.close(fd) }
            source = src
            src.resume()
        }
    }

    public func send(_ envelope: Envelope) {
        guard let data = try? envelope.encoded() else { return }
        send(data)
    }

    public func send(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            let ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    return false
                }
                return true
            }
            if !ok { closeOnQueue() }
        }
    }

    public func close() { queue.async { [self] in closeOnQueue() } }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 {
            if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
            closeOnQueue(); return
        }
        do {
            for frame in try splitter.append(Data(buf[0..<n])) { onFrame?(frame) }
        } catch {
            closeOnQueue()
        }
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        if source == nil { Darwin.close(fd) }
        let handler = onClose
        onFrame = nil; onClose = nil
        handler?()
    }
}

// MARK: - Socket helpers

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            throw IPCError.socket("Socket path too long (\(bytes.count) bytes): \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socket("socket(): \(String(cString: strerror(errno)))") }
        return fd
    }

    static func connect(path: String) throws -> Int32 {
        let fd = try makeSocket()
        var addr = try address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            Darwin.close(fd)
            throw IPCError.connectFailed(errno: code)
        }
        return fd
    }
}

public enum IPCError: Error, CustomStringConvertible {
    case socket(String)
    case connectFailed(errno: Int32)
    case alreadyRunning

    public var description: String {
        switch self {
        case .socket(let m): m
        case .connectFailed(let e): "connect(): \(String(cString: strerror(e)))"
        case .alreadyRunning: "Another Harmune host is already running"
        }
    }

    public var isHostNotRunning: Bool {
        if case .connectFailed(let e) = self { return e == ENOENT || e == ECONNREFUSED }
        return false
    }
}

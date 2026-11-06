import Foundation

/// The app host has no terminal, so its output goes to a file:
/// `~/Library/Logs/Harmune/host.log`. Phase 0 uses this log as evidence.
public enum HostLog {
    private static let maxSize = 5_000_000
    private static let lock = NSLock()

    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Harmune/host.log")
    }

    public static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}

import Foundation

/// Filesystem locations shared by the CLI, TUI and host.
public enum HarmunePaths {
    /// `sockaddr_un.sun_path` is 104 bytes including the terminator.
    public static let maxSocketPathLength = 103

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Harmune", isDirectory: true)
    }

    public static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Harmune", isDirectory: true)
    }

    /// `HARMUNE_SOCKET` overrides the default, e.g. for tests.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["HARMUNE_SOCKET"], !override.isEmpty { return override }
        let preferred = supportDirectory.appendingPathComponent("host.sock").path
        if preferred.utf8.count <= maxSocketPathLength { return preferred }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("harmune-\(getuid()).sock")
    }

    public static func lockPath(forSocket socket: String) -> String {
        (socket as NSString).deletingPathExtension + ".lock"
    }
}

public enum HarmuneVersion {
    public static let current = "0.1.0"
    public static let protocolVersion = 1
}

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

    public static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Harmune/host.log")
    }

    /// Command history and the last view. `XDG_STATE_HOME` overrides the base.
    public static func stateDirectory(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let xdg = env["XDG_STATE_HOME"], !xdg.isEmpty { return xdg + "/harmune" }
        return NSHomeDirectory() + "/.local/state/harmune"
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

    /// The running executable with symlinks resolved. `argv[0]` can't be used:
    /// it's only `harmune` when the shell finds the command through `PATH`.
    public static func currentExecutable() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath()
    }
}

public enum HarmuneVersion {
    public static let current = "0.1.0"
    public static let protocolVersion = 1
}

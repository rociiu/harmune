import Darwin
import Foundation
import HarmuneCore
import HarmuneIPC

/// Finds and starts the host so it outlives the terminal.
///
/// - A signed `Harmune.app` is opened through LaunchServices (`open -g -j`),
///   so it is not in the terminal's session and TCC attributes permissions
///   to Harmune rather than the terminal.
/// - The development `harmune-host` binary is spawned in a new session
///   (`setsid`) with `--demo`.
enum HostLauncher {
    enum Target { case app(URL), devHost(URL) }

    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> Target? {
        let fm = FileManager.default
        if let path = environment["HARMUNE_HOST_APP"], fm.fileExists(atPath: path) {
            return .app(URL(fileURLWithPath: path))
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // CLI installed inside Harmune.app/Contents/Resources/bin/harmune.
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" { return .app(bundle) }
        for dir in ["/Applications", "\(NSHomeDirectory())/Applications"] {
            let app = URL(fileURLWithPath: dir).appendingPathComponent("Harmune.app")
            if fm.fileExists(atPath: app.path) { return .app(app) }
        }
        let sibling = exe.deletingLastPathComponent().appendingPathComponent("harmune-host")
        if fm.isExecutableFile(atPath: sibling.path) { return .devHost(sibling) }
        return nil
    }

    static func launch(socketPath: String) throws {
        guard let target = locate() else {
            throw HarmuneError(.unavailable, "Harmune host not found. Install Harmune.app or build harmune-host.",
                               recoverable: false)
        }
        switch target {
        case .app(let url):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-j", "-a", url.path]
            try p.run()
            p.waitUntilExit()
        case .devHost(let url):
            try spawnDetached(url.path, ["--demo", "--socket", socketPath])
        }
    }

    private static func spawnDetached(_ path: String, _ args: [String]) throws {
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }

        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        guard rc == 0 else { throw HarmuneError(.internal, "posix_spawn: \(String(cString: strerror(rc)))") }
    }

    /// Connects, starting the host first if it isn't running.
    static func connect(socketPath: String, autoStart: Bool) async throws -> RemoteBackend {
        do {
            return try await RemoteBackend.connect(path: socketPath, client: .cli)
        } catch let error as IPCError where error.isHostNotRunning && autoStart {
            try launch(socketPath: socketPath)
            let deadline = Date().addingTimeInterval(3)
            var delay = 0.05
            while Date() < deadline {
                try await Task.sleep(for: .seconds(delay))
                if let backend = try? await RemoteBackend.connect(path: socketPath, client: .cli) { return backend }
                delay = min(delay * 2, 0.4)
            }
            throw HarmuneError(.unavailable, "Harmune host did not start within 3 s")
        } catch let error as IPCError where error.isHostNotRunning {
            throw HarmuneError(.unavailable, "Harmune host is not running (harmune service start)")
        }
    }
}

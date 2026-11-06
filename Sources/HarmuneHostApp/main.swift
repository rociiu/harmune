import AppKit
import Darwin
import Foundation
import HarmuneCore
import HarmuneIPC
import HarmuneMusic

// The MusicKit host: the executable inside Harmune.app. It has no windows or
// Dock icon (LSUIElement) and serves the same socket as the development host.

var socketPath = HarmunePaths.socketPath()
var idleMinutes = 30.0
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--socket": socketPath = arguments.popFirst() ?? socketPath
    case "--idle-exit-minutes": idleMinutes = arguments.popFirst().flatMap(Double.init) ?? idleMinutes
    default: HostLog.write("host: ignoring argument \(argument)")  // e.g. -psn_ from LaunchServices
    }
}

signal(SIGPIPE, SIG_IGN)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let backend = MusicKitBackend()
let server = IPCServer(socketPath: socketPath, backend: backend, backendName: "musickit", idleMinutes: idleMinutes)
do {
    try server.start()
} catch IPCError.alreadyRunning {
    HostLog.write("host: another instance is running, exiting")
    exit(75)
} catch {
    HostLog.write("host: failed to start: \(error)")
    exit(1)
}

let bundleID = Bundle.main.bundleIdentifier ?? "none"
HostLog.write("host: \(HarmuneVersion.current) started pid=\(getpid()) ppid=\(getppid()) bundle=\(bundleID) socket=\(socketPath)")
HostRuntime.install(server: server, backend: backend, idleMinutes: idleMinutes) { HostLog.write("host: \($0)") }
application.run()

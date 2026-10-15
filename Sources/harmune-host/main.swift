import Darwin
import Foundation
import HarmuneCore
import HarmuneDemo
import HarmuneIPC

// Development host: serves DemoBackend over the Harmune socket.
// The production host is the signed Harmune.app (MusicKitBackend), which
// runs the same IPCServer.

let usage = """
usage: harmune-host --demo [--socket <path>] [--idle-exit-minutes <n>]

  --demo                 Serve the fictional demo library (required until the MusicKit host lands)
  --socket <path>        Socket path (default: \(HarmunePaths.socketPath()))
  --idle-exit-minutes n  Quit after n minutes paused with no clients (0 = never, default 30)
"""

var demo = false
var socketPath = HarmunePaths.socketPath()
var idleMinutes = 30.0
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--demo": demo = true
    case "--socket": socketPath = args.popFirst() ?? socketPath
    case "--idle-exit-minutes": idleMinutes = args.popFirst().flatMap(Double.init) ?? idleMinutes
    case "-h", "--help": print(usage); exit(0)
    default: FileHandle.standardError.write(Data("Unknown option \(arg)\n\(usage)\n".utf8)); exit(64)
    }
}

guard demo else {
    FileHandle.standardError.write(Data("""
    The MusicKit host ships as the signed Harmune.app (see docs/IMPLEMENTATION_PLAN.md, Phase 0).
    Run `harmune-host --demo` for the demo library.\n
    """.utf8))
    exit(64)
}

signal(SIGPIPE, SIG_IGN)
let backend = DemoBackend()
let server = IPCServer(socketPath: socketPath, backend: backend, backendName: "demo")
do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("harmune-host: \(error)\n".utf8))
    if case IPCError.alreadyRunning = error { exit(75) }
    exit(1)
}
print("harmune-host \(HarmuneVersion.current) (demo) listening on \(socketPath)")

// Clean shutdown on SIGINT/SIGTERM.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { server.stop(); exit(0) }
    source.resume()
    signalSources.append(source)
}
server.onStopRequested = { server.stop(); exit(0) }

// Idle exit: paused (or empty) with no clients for `idleMinutes`.
if idleMinutes > 0 {
    Task {
        var idleSince: Date?
        while true {
            try? await Task.sleep(for: .seconds(15))
            let playing = await backend.playbackState().isPlaying
            let idle = !playing && server.clientCount == 0
            if !idle { idleSince = nil } else if idleSince == nil { idleSince = Date() }
            if let since = idleSince, Date().timeIntervalSince(since) >= idleMinutes * 60 {
                print("harmune-host: idle for \(Int(idleMinutes)) min, exiting")
                server.stop()
                exit(0)
            }
        }
    }
}

dispatchMain()

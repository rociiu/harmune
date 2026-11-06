import Darwin
import Foundation
import HarmuneConfig
import HarmuneCore
import HarmuneDemo
import HarmuneIPC
import HarmuneTerminal

let usage = """
harmune \(HarmuneVersion.current) — your music, your terminal.

USAGE
  harmune                         Start the TUI (starts the host if needed)
  harmune --demo                  Start the TUI on an in-process demo library
  harmune <command> [options]

PLAYBACK
  status [--json] [--watch]       Show what's playing (--watch streams NDJSON events)
  play [<song-id>]                Resume, or play a song
  play --album <id> [--track n]   Play an album from track n (1-based)
  play --playlist <id> [--track n]
  pause | toggle | next | previous
  seek <seconds|+n|-n>
  shuffle on|off
  repeat off|one|all

QUEUE
  queue [--json]                  Show the queue
  add <song-id>... [--next]       Add songs to the end (or play next)

BROWSE
  search <query> [--library] [--json]
  library songs|albums|artists|playlists [--json]
  album <id> | playlist <id> | artist <id>

SERVICE
  service status|start|stop [--force]
  auth [status] [--json]          Ask for Apple Music access, or show its status

CONFIG
  config path                     Print the config file location
  config check                    Validate the config file

OPTIONS
  --socket <path>                 Host socket (env HARMUNE_SOCKET)
  --theme <name>                  harmune-midnight (default) or mono
  --config <path>                 Config file (default: \(HarmuneConfig.defaultPath()))
  --version, --help
"""

struct CLIError: Error, CustomStringConvertible {
    var description: String
    var code: Int32 = 1
    init(_ d: String, code: Int32 = 1) { description = d; self.code = code }
}

/// Minimal argument cursor: positional args plus `--flag` / `--opt value`.
struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]
    static let valued: Set<String> = ["--socket", "--album", "--playlist", "--track", "--theme", "--config"]

    init(_ raw: ArraySlice<String>) {
        var it = raw.makeIterator()
        while let a = it.next() {
            if a == "-h" { flags.insert("--help") }
            else if Args.valued.contains(a) { options[a] = it.next() ?? "" }
            else if a.hasPrefix("--") { flags.insert(a) }
            else { positional.append(a) }
        }
    }

    mutating func next(_ what: String) throws -> String {
        guard !positional.isEmpty else { throw CLIError("Missing \(what)", code: 64) }
        return positional.removeFirst()
    }
}

func run() async throws {
    var args = Args(CommandLine.arguments.dropFirst())
    if args.flags.contains("--version") { print("harmune \(HarmuneVersion.current)"); return }
    if args.flags.contains("--help") { print(usage); return }
    let socket = args.options["--socket"] ?? HarmunePaths.socketPath()
    let json = args.flags.contains("--json")

    let configPath = args.options["--config"] ?? HarmuneConfig.defaultPath()
    guard let command = args.positional.first else {
        try await runTUI(demo: args.flags.contains("--demo"), socket: socket, themeName: args.options["--theme"],
                         configPath: configPath)
        return
    }
    args.positional.removeFirst()

    if command == "service" {
        try await service(try args.next("service subcommand"), args: args, socket: socket)
        return
    }
    if command == "help" { print(usage); return }
    if command == "config" {
        switch try args.next("path|check") {
        case "path":
            print(configPath)
        case "check":
            let (config, warnings) = HarmuneConfig.load(path: configPath)
            let resolved = resolveTUIOptions(config)
            let all = warnings + resolved.warnings
            if !FileManager.default.fileExists(atPath: configPath) {
                print("No config file at \(configPath); using defaults.")
            } else if all.isEmpty {
                print("\(configPath): OK")
            } else {
                all.forEach { print("warning: \($0)") }
                throw CLIError("\(all.count) problem(s) in \(configPath)")
            }
        default:
            throw CLIError("config expects path|check", code: 64)
        }
        return
    }

    let backend = try await HostLauncher.connect(socketPath: socket, autoStart: true)

    switch command {
    case "auth":
        let status: AuthStatus
        switch args.positional.first {
        case nil: status = await backend.requestAuthorization()
        case "status": status = await backend.authStatus()
        default: throw CLIError("auth expects no argument, or status", code: 64)
        }
        if json {
            print(Format.json(status))
        } else {
            print("Apple Music: \(status.state.rawValue)" + (status.detail.map { " (\($0))" } ?? ""))
        }

    case "status":
        if args.flags.contains("--watch") {
            for await event in await backend.events() {
                if case .playback(let s) = event { print(Format.json(StatusJSON(s)).replacingOccurrences(of: "\n", with: "")) }
            }
            return
        }
        let s = await backend.playbackState()
        print(json ? Format.json(StatusJSON(s)) : Format.status(s))

    case "play":
        let track = args.options["--track"].flatMap(Int.init).map { $0 - 1 } ?? 0
        if let album = args.options["--album"] {
            try await backend.play(.container(.album, id: album, startIndex: track))
        } else if let playlist = args.options["--playlist"] {
            try await backend.play(.container(.playlist, id: playlist, startIndex: track))
        } else if let song = args.positional.first {
            try await backend.play(.song(id: song))
        } else {
            try await backend.play(.resume)
        }
        print(Format.status(await backend.playbackState()))

    case "pause": try await backend.pause()
    case "toggle": try await backend.togglePlayPause()
    case "next":
        try await backend.next()
        print(Format.status(await backend.playbackState()))
    case "previous":
        try await backend.previous()
        print(Format.status(await backend.playbackState()))

    case "seek":
        let raw = try args.next("seconds")
        guard let value = Double(raw) else { throw CLIError("seek expects seconds, +n or -n", code: 64) }
        let current = await backend.playbackState().position(at: Date())
        let target = raw.hasPrefix("+") || raw.hasPrefix("-") ? current + value : value
        try await backend.seek(to: max(0, target))

    case "shuffle":
        switch try args.next("on|off") {
        case "on": try await backend.setShuffle(true)
        case "off": try await backend.setShuffle(false)
        default: throw CLIError("shuffle expects on|off", code: 64)
        }

    case "repeat":
        guard let mode = RepeatMode(rawValue: try args.next("off|one|all")) else {
            throw CLIError("repeat expects off|one|all", code: 64)
        }
        try await backend.setRepeat(mode)

    case "queue":
        let q = await backend.queueState()
        print(json ? Format.json(q) : Format.queue(q))

    case "add":
        guard !args.positional.isEmpty else { throw CLIError("add expects one or more song ids", code: 64) }
        try await backend.enqueue(songIDs: args.positional, at: args.flags.contains("--next") ? .next : .last)
        print("Added \(args.positional.count) song(s)")

    case "search":
        let text = args.positional.joined(separator: " ")
        guard !text.isEmpty else { throw CLIError("search expects a query", code: 64) }
        let r = try await backend.search(SearchQuery(text: text, scope: args.flags.contains("--library") ? .library : .catalog))
        print(json ? Format.json(r) : Format.search(r))

    case "library":
        switch try args.next("songs|albums|artists|playlists") {
        case "songs":
            let p = try await backend.librarySongs(sort: .title, offset: 0, limit: 200)
            print(json ? Format.json(p) : Format.tracks(p.items))
        case "albums":
            let p = try await backend.libraryAlbums(sort: .title, offset: 0, limit: 200)
            print(json ? Format.json(p) : Format.albums(p.items))
        case "artists":
            let p = try await backend.libraryArtists(offset: 0, limit: 200)
            print(json ? Format.json(p) : p.items.map { "  \(Format.id($0.id, 6)) \($0.name)" }.joined(separator: "\n"))
        case "playlists":
            let p = try await backend.libraryPlaylists(offset: 0, limit: 200)
            print(json ? Format.json(p) : p.items.map { "  \(Format.id($0.id, 6)) \(Format.pad($0.name, 24)) \(Format.songCount($0.trackCount))" }.joined(separator: "\n"))
        default: throw CLIError("library expects songs|albums|artists|playlists", code: 64)
        }

    case "album":
        let d = try await backend.album(id: try args.next("album id"))
        if json { print(Format.json(d)) } else {
            print("\(d.album.title) — \(d.album.artist)  \(d.album.year.map(String.init) ?? "") · \(d.album.genre ?? "")\n")
            print(Format.tracks(d.tracks))
        }
    case "playlist":
        let d = try await backend.playlist(id: try args.next("playlist id"))
        if json { print(Format.json(d)) } else { print("\(d.playlist.name)\n"); print(Format.tracks(d.tracks)) }
    case "artist":
        let d = try await backend.artist(id: try args.next("artist id"))
        if json { print(Format.json(d)) } else {
            print("\(d.artist.name)\n\nTOP SONGS\n\(Format.tracks(d.topSongs))\n\nALBUMS\n\(Format.albums(d.albums))")
        }

    default:
        throw CLIError("Unknown command '\(command)'. See harmune --help.", code: 64)
    }
}

/// TUI settings derived from the config file.
struct TUIOptions {
    var theme = Theme.midnight
    var graphics: GraphicsMode?
    var reducedMotion = false
    var albumGrid = true
    var keymap = Keymap.standard
    var sequenceTimeout = 0.6
    var startRoute = Route.home
    var warnings: [String] = []
}

func resolveTUIOptions(_ config: HarmuneConfig) -> TUIOptions {
    var o = TUIOptions()
    if let theme = Theme.named(config.theme) { o.theme = theme }
    else { o.warnings.append("unknown theme \"\(config.theme)\"; available: \(Theme.all.map(\.name).joined(separator: ", "))") }
    o.graphics = !config.showArtwork ? GraphicsMode.none : GraphicsMode(rawValue: config.graphics)
    o.reducedMotion = config.reducedMotion || !config.animations
    o.albumGrid = config.albumView == "grid"
    o.sequenceTimeout = Double(config.sequenceTimeoutMs) / 1000
    o.warnings += o.keymap.apply(overrides: config.keybindings)
    let routes: [String: Route] = ["home": .home, "search": .search, "songs": .songs, "albums": .albums,
                                   "artists": .artists, "playlists": .playlists, "queue": .queue]
    o.startRoute = routes[config.startPage] ?? .home
    return o
}

@MainActor
func runTUI(demo: Bool, socket: String, themeName: String?, configPath: String) async throws {
    guard TerminalIO.isInteractive else {
        throw CLIError("The TUI needs an interactive terminal. Use subcommands (harmune --help) in scripts.", code: 64)
    }
    let (config, configWarnings) = HarmuneConfig.load(path: configPath)
    var options = resolveTUIOptions(config)
    options.warnings = configWarnings + options.warnings
    if let themeName {
        guard let t = Theme.named(themeName) else {
            throw CLIError("Unknown theme '\(themeName)'. Available: \(Theme.all.map(\.name).joined(separator: ", "))", code: 64)
        }
        options.theme = t
    }

    func makeApp(_ backend: any MusicBackend,
                 reconnect: (@Sendable () async throws -> any MusicBackend)? = nil) -> TUIApp {
        let app = TUIApp(backend: backend, theme: options.theme, reconnect: reconnect, graphics: options.graphics,
                         reducedMotion: options.reducedMotion, albumGrid: options.albumGrid, keymap: options.keymap,
                         sequenceTimeout: options.sequenceTimeout, startRoute: options.startRoute)
        if let first = options.warnings.first {
            let more = options.warnings.count > 1 ? " (+\(options.warnings.count - 1) more; run harmune config check)" : ""
            app.notify("Config: \(first)\(more)", error: true)
        }
        return app
    }

    if demo {
        let app = makeApp(DemoBackend())
        _ = try await app.run()
        print("Harmune demo closed.")
        return
    }

    let remote = try await HostLauncher.connect(socketPath: socket, autoStart: true, client: .tui)
    let app = makeApp(remote, reconnect: {
        try await HostLauncher.connect(socketPath: socket, autoStart: true, client: .tui)
    })
    let reason = try await app.run()

    // Reconnects may have replaced the backend; ask the host fresh.
    let current = try? await HostLauncher.connect(socketPath: socket, autoStart: false)
    switch reason {
    case .stopHost:
        try? await current?.stopService(force: true)
        print("Harmune host stopped.")
    case .user:
        if let current, await current.playbackState().isPlaying {
            print("Harmune closed — music still playing (harmune service stop to stop it).")
        }
    }
}

func service(_ sub: String, args: Args, socket: String) async throws {
    switch sub {
    case "status":
        guard let backend = try? await HostLauncher.connect(socketPath: socket, autoStart: false) else {
            print("Harmune host: not running"); return
        }
        let s = try await backend.serviceStatus()
        if args.flags.contains("--json") { print(Format.json(s)); return }
        print("""
        Harmune host: running
          pid       \(s.pid)
          version   \(s.hostVersion)
          backend   \(s.backend)
          uptime    \(Format.time(s.uptime))
          clients   \(s.clients)
          playing   \(s.isPlaying ? "yes" : "no")
          socket    \(socket)
        """)
    case "start":
        _ = try await HostLauncher.connect(socketPath: socket, autoStart: true)
        print("Harmune host is running")
    case "stop":
        guard let backend = try? await HostLauncher.connect(socketPath: socket, autoStart: false) else {
            print("Harmune host: not running"); return
        }
        do {
            try await backend.stopService(force: args.flags.contains("--force"))
            // Wait until it's gone, so a `service start` right after this
            // can't connect to the host that is still exiting.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, (try? await RemoteBackend.connect(path: socket, client: .cli)) != nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            print("Harmune host stopped")
        } catch let e as HarmuneError where e.code == .invalidArgument {
            throw CLIError("Music is playing. Stopping the host will interrupt playback; re-run with --force.")
        }
    default:
        throw CLIError("service expects status|start|stop", code: 64)
    }
}

signal(SIGPIPE, SIG_IGN)
do {
    try await run()
} catch let e as CLIError {
    FileHandle.standardError.write(Data("harmune: \(e.description)\n".utf8))
    exit(e.code)
} catch let e as HarmuneError {
    FileHandle.standardError.write(Data("harmune: \(e.message)\n".utf8))
    exit(e.code == .unavailable ? 69 : 1)
} catch {
    FileHandle.standardError.write(Data("harmune: \(error)\n".utf8))
    exit(1)
}

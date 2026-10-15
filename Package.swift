// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harmune",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "harmune", targets: ["harmune"]),
        .executable(name: "harmune-host", targets: ["harmune-host"]),
        .library(name: "HarmuneCore", targets: ["HarmuneCore"]),
        .library(name: "HarmuneIPC", targets: ["HarmuneIPC"]),
    ],
    targets: [
        // Domain models and the MusicBackend protocol. No dependencies.
        .target(name: "HarmuneCore"),
        // Wire protocol, NDJSON framing, Unix socket server/client, RemoteBackend.
        .target(name: "HarmuneIPC", dependencies: ["HarmuneCore"]),
        // In-process fixture backend for contributors, CI and `--demo`.
        .target(name: "HarmuneDemo", dependencies: ["HarmuneCore"]),
        // TUI. Currently: keymap engine and key decoding.
        .target(name: "HarmuneTerminal", dependencies: ["HarmuneCore"]),
        .executableTarget(name: "harmune", dependencies: ["HarmuneCore", "HarmuneIPC", "HarmuneDemo", "HarmuneTerminal"]),
        // Development host serving DemoBackend over the socket.
        // The real MusicKit host is a signed app bundle (Apps/HarmuneHost).
        .executableTarget(name: "harmune-host", dependencies: ["HarmuneCore", "HarmuneIPC", "HarmuneDemo"]),

        .testTarget(name: "CoreTests", dependencies: ["HarmuneCore"]),
        .testTarget(name: "IPCTests", dependencies: ["HarmuneIPC", "HarmuneDemo"]),
        .testTarget(name: "DemoTests", dependencies: ["HarmuneDemo"]),
        .testTarget(name: "KeymapTests", dependencies: ["HarmuneTerminal"]),
    ]
)

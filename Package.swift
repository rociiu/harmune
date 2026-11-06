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
        // TUI: renderer, store, views, keymap and the run loop.
        .target(name: "HarmuneTerminal", dependencies: ["HarmuneCore"]),
        // config.toml loading and validation. No dependencies.
        .target(name: "HarmuneConfig"),
        .executableTarget(name: "harmune", dependencies: ["HarmuneCore", "HarmuneIPC", "HarmuneDemo", "HarmuneTerminal", "HarmuneConfig"]),
        // Development host serving DemoBackend over the socket.
        .executableTarget(name: "harmune-host", dependencies: ["HarmuneCore", "HarmuneIPC", "HarmuneDemo"]),
        // MusicKitBackend. Linked only by the app host.
        .target(name: "HarmuneMusic", dependencies: ["HarmuneCore"]),
        // The executable inside Harmune.app (see Scripts/build-host.sh).
        .executableTarget(name: "HarmuneHostApp", dependencies: ["HarmuneCore", "HarmuneIPC", "HarmuneMusic"]),

        .testTarget(name: "CoreTests", dependencies: ["HarmuneCore"]),
        .testTarget(name: "IPCTests", dependencies: ["HarmuneIPC", "HarmuneDemo"]),
        .testTarget(name: "DemoTests", dependencies: ["HarmuneDemo"]),
        .testTarget(name: "KeymapTests", dependencies: ["HarmuneTerminal"]),
        .testTarget(name: "TUITests", dependencies: ["HarmuneTerminal", "HarmuneDemo"]),
        .testTarget(name: "ConfigTests", dependencies: ["HarmuneConfig", "HarmuneTerminal"]),
        .testTarget(name: "MusicTests", dependencies: ["HarmuneMusic", "HarmuneCore"]),
    ]
)

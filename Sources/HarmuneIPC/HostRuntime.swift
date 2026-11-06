import Darwin
import Foundation
import HarmuneCore

/// Lifecycle shared by the development host and the app host: clean shutdown
/// on signals or a client's stop request, and exit after a stretch of idling.
public enum HostRuntime {
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    /// Must be called on the main thread. The handlers run on the main queue,
    /// so the host must be running `dispatchMain()` or `NSApplication.run()`.
    public static func install(server: IPCServer, backend: any MusicBackend, idleMinutes: Double,
                               log: @escaping @Sendable (String) -> Void) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { server.stop(); exit(0) }
            source.resume()
            signalSources.append(source)
        }
        server.onStopRequested = { server.stop(); exit(0) }

        guard idleMinutes.isFinite, idleMinutes > 0 else { return }
        Task {
            while true {
                try? await Task.sleep(for: .seconds(15))
                let playing = await backend.playbackState().isPlaying
                if server.idleTimedOut(isPlaying: playing) {
                    log("idle for \(Int(idleMinutes)) min, exiting")
                    server.stop()
                    exit(0)
                }
            }
        }
    }
}

import CoreGraphics
import Foundation
import HarmuneCore
import ImageIO
import MusicKit
import UniformTypeIdentifiers

/// Fetches cover art into the cache as PNG, the format the terminal graphics
/// code expects. A `path` may name a file that is still on its way: the TUI
/// keeps checking for it, so covers appear as they arrive.
actor ArtworkStore {
    static let maxConcurrent = 4
    static let pixels = 300
    static let missLifetime: TimeInterval = 7 * 24 * 3600

    private let directory: URL
    private var pending: [(url: URL, destination: URL)] = []
    private var pendingRenders: [(artwork: MusicKit.Artwork, destination: URL)] = []
    private var known: Set<String> = []
    private var running = 0
    private var rendering = false

    init(directory: URL = HarmunePaths.cacheDirectory.appendingPathComponent("artwork", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated func destination(forKey key: String) -> URL {
        directory.appendingPathComponent(Self.fileName(forKey: key))
    }

    static func fileName(forKey key: String) -> String {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return String(safe) + ".png"
    }

    static func missMarker(for destination: URL) -> URL {
        destination.appendingPathExtension("none")
    }

    /// A miss could have been a slow load or a cover added later, so it's
    /// only remembered for a while.
    static func missIsCurrent(modified: Date?, now: Date = Date()) -> Bool {
        guard let modified else { return false }
        return now.timeIntervalSince(modified) < missLifetime
    }

    /// Builds the reference for an item. With `fetch`, also queues the image
    /// if it isn't cached. Rows that never show artwork pass false, because a
    /// list of songs would otherwise fetch hundreds of images.
    nonisolated func reference(for artwork: MusicKit.Artwork?, key: String, fetch: Bool) -> ArtworkRef? {
        guard let artwork else { return nil }
        let file = destination(forKey: key)
        var available = FileManager.default.fileExists(atPath: file.path)
        let marker = Self.missMarker(for: file).path
        let modified = (try? FileManager.default.attributesOfItem(atPath: marker))?[.modificationDate] as? Date
        if !available, fetch, !Self.missIsCurrent(modified: modified),
           let url = artwork.url(width: Self.pixels, height: Self.pixels) {
            Task { await self.enqueue(url, artwork: artwork, destination: file) }
            available = true
        }
        return ArtworkRef(key: key, averageColor: artwork.backgroundColor.flatMap(Self.rgb), path: available ? file.path : nil)
    }

    private func enqueue(_ url: URL, artwork: MusicKit.Artwork, destination: URL) {
        guard known.insert(destination.path).inserted else { return }
        guard url.scheme == "https" || url.scheme == "http" else {
            // Library artwork has a private URL that URLSession can't load.
            pendingRenders.append((artwork, destination))
            pumpRenders()
            return
        }
        pending.append((url, destination))
        pump()
    }

    private func pumpRenders() {
        guard !rendering, !pendingRenders.isEmpty else { return }
        rendering = true
        let job = pendingRenders.removeFirst()
        Task.detached(priority: .utility) { [weak self] in
            let rendered = await ArtworkRenderer.shared.render(job.artwork)
            if let png = rendered.flatMap({ Self.png(from: $0) }) {
                do {
                    try png.write(to: job.destination, options: .atomic)
                } catch {
                    HostLog.write("artwork: \(job.destination.lastPathComponent): \(error.localizedDescription)")
                }
            } else {
                // Usually an item with no cover. Nothing about the artwork says
                // so in advance, so remember it instead of waiting again.
                FileManager.default.createFile(atPath: Self.missMarker(for: job.destination).path, contents: nil)
            }
            await self?.renderFinished()
        }
    }

    private func renderFinished() {
        rendering = false
        pumpRenders()
    }

    private func pump() {
        while running < Self.maxConcurrent, !pending.isEmpty {
            let job = pending.removeFirst()
            running += 1
            Task.detached(priority: .utility) { [weak self] in
                await Self.download(job.url, to: job.destination)
                await self?.finished()
            }
        }
    }

    private func finished() {
        running -= 1
        pump()
    }

    private static func download(_ url: URL, to destination: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let png = png(from: data) else {
                HostLog.write("artwork: couldn't decode image for \(destination.lastPathComponent)")
                return
            }
            try png.write(to: destination, options: .atomic)
        } catch {
            HostLog.write("artwork: \(destination.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Decodes any image and re-encodes it as PNG, no larger than `pixels`.
    static func png(from data: Data) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    private static func rgb(_ color: CGColor) -> RGB? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, c.count >= 3 else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return RGB(r: byte(c[0]), g: byte(c[1]), b: byte(c[2]))
    }
}

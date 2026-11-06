import AppKit
@preconcurrency import MusicKit
import SwiftUI

/// Library artwork has a private `musicKit` URL that only MusicKit's own
/// `ArtworkImage` view can load. This draws that view in an invisible window
/// and captures the pixels, one image at a time.
@MainActor
final class ArtworkRenderer {
    static let shared = ArtworkRenderer()

    private let size: CGFloat = 300
    // Covers measured about 140 ms on the first test library. Cover-less items
    // never finish, so each one costs this whole wait once.
    private let attempts = 15
    private let interval: Duration = .milliseconds(100)
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?

    /// Returns PNG data, or nil if nothing but a flat placeholder ever appears.
    func render(_ artwork: MusicKit.Artwork) async -> Data? {
        let host = prepareHost()
        host.rootView = AnyView(ArtworkImage(artwork, width: size, height: size))
        for _ in 0..<attempts {
            try? await Task.sleep(for: interval)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if !Self.isFlat(rep) { return rep.representation(using: .png, properties: [:]) }
        }
        return nil
    }

    private func prepareHost() -> NSHostingView<AnyView> {
        if let host { return host }
        let frame = NSRect(x: -20_000, y: -20_000, width: size, height: size)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        window.contentView = host
        window.orderFrontRegardless()  // SwiftUI only loads the image in a window on screen
        self.window = window
        self.host = host
        return host
    }

    /// While loading, the view shows one solid color. Samples a coarse grid,
    /// so a real cover that is one solid color never counts as loaded.
    nonisolated static func isFlat(_ rep: NSBitmapImageRep) -> Bool {
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return true }
        var seen: (r: CGFloat, g: CGFloat, b: CGFloat)?
        for gx in 1..<8 {
            for gy in 1..<8 {
                guard let color = rep.colorAt(x: rep.pixelsWide * gx / 8, y: rep.pixelsHigh * gy / 8)?
                    .usingColorSpace(.sRGB) else { continue }
                let c = (r: color.redComponent, g: color.greenComponent, b: color.blueComponent)
                guard let first = seen else { seen = c; continue }
                if abs(first.r - c.r) + abs(first.g - c.g) + abs(first.b - c.b) > 0.02 { return false }
            }
        }
        return true
    }
}

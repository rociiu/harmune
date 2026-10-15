import CoreGraphics
import Foundation
import HarmuneCore
import ImageIO
import UniformTypeIdentifiers

/// Generates license-free abstract cover art for the demo library, so the
/// artwork pipeline has real PNG files to display.
public enum DemoArtwork {
    public static let size = 300

    /// `HARMUNE_CACHE_DIR` overrides the cache root (tests).
    public static var directory: URL {
        let root = ProcessInfo.processInfo.environment["HARMUNE_CACHE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? HarmunePaths.cacheDirectory
        return root.appendingPathComponent("artwork", isDirectory: true)
    }

    public static func path(for key: String) -> String {
        directory.appendingPathComponent("demo-\(key)-\(size).png").path
    }

    /// Writes any missing images. Safe to call repeatedly.
    public static func ensureGenerated(keys: [String]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for key in keys where !FileManager.default.fileExists(atPath: path(for: key)) {
            if let image = render(key: key) { write(image, to: path(for: key)) }
        }
    }

    static func render(key: String) -> CGImage? {
        let s = size
        guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rng = SplitMix64(seed: fnv(key))
        let palettes: [[(CGFloat, CGFloat, CGFloat)]] = [
            [(0.78, 0.65, 1.0), (0.95, 0.65, 0.78), (0.10, 0.08, 0.20)],
            [(0.58, 0.75, 1.0), (0.65, 0.89, 0.63), (0.05, 0.10, 0.18)],
            [(0.98, 0.84, 0.55), (0.95, 0.55, 0.66), (0.18, 0.06, 0.12)],
            [(0.45, 0.35, 0.85), (0.30, 0.80, 0.90), (0.04, 0.04, 0.12)],
            [(0.95, 0.45, 0.35), (0.98, 0.80, 0.45), (0.12, 0.05, 0.08)],
            [(0.40, 0.90, 0.75), (0.30, 0.45, 0.95), (0.03, 0.08, 0.10)],
        ]
        let p = palettes[rng.next(palettes.count)]
        func color(_ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat = 1) -> CGColor {
            CGColor(red: c.0, green: c.1, blue: c.2, alpha: a)
        }

        // Background gradient.
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [color(p[2]), color(p[0], 0.9)] as CFArray, locations: [0, 1])!
        let angle = Double(rng.next(360)) * .pi / 180
        let c = CGFloat(s) / 2
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: c - cos(angle) * c, y: c - sin(angle) * c),
                               end: CGPoint(x: c + cos(angle) * c, y: c + sin(angle) * c),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // A few soft shapes.
        let style = rng.next(3)
        for i in 0..<(4 + rng.next(4)) {
            let r = CGFloat(30 + rng.next(110))
            let x = CGFloat(rng.next(s)), y = CGFloat(rng.next(s))
            ctx.setFillColor(color(i % 2 == 0 ? p[1] : p[0], 0.25 + CGFloat(rng.next(40)) / 100))
            switch style {
            case 0: ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            case 1: ctx.fill(CGRect(x: x - r, y: y - r / 3, width: r * 2, height: r / 1.5))
            default:
                ctx.setStrokeColor(color(p[1], 0.7))
                ctx.setLineWidth(CGFloat(4 + rng.next(10)))
                ctx.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }
        // Horizontal "sound wave" band.
        ctx.setFillColor(color(p[1], 0.85))
        let bars = 24
        for b in 0..<bars {
            let h = CGFloat(8 + rng.next(60))
            ctx.fill(CGRect(x: CGFloat(b) * CGFloat(s) / CGFloat(bars) + 2, y: CGFloat(s) * 0.18,
                            width: CGFloat(s) / CGFloat(bars) - 4, height: h))
        }
        return ctx.makeImage()
    }

    static func write(_ image: CGImage, to path: String) {
        let tmp = path + ".tmp"
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: tmp) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
            _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        }
    }

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

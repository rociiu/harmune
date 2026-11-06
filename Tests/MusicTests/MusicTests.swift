import AppKit
import CoreGraphics
import Foundation
import HarmuneCore
import ImageIO
import MusicKit
import Testing
import UniformTypeIdentifiers
@testable import HarmuneMusic

// Only the logic that needs no Apple Music session. The live checks are in
// Scripts/validate-phase0.sh.
@Suite struct MusicIDTests {
    @Test func parsesTaggedIDs() throws {
        let catalog = try #require(MusicID("c:1440857781"))
        #expect(catalog.source == .catalog && catalog.raw == "1440857781")
        let library = try #require(MusicID("l:i.abc:def"))
        #expect(library.source == .library && library.raw == "i.abc:def")
        #expect(library.description == "l:i.abc:def")
    }

    @Test func untaggedIDsAreCatalog() throws {
        let id = try #require(MusicID("pl.u-123"))
        #expect(id.source == .catalog && id.raw == "pl.u-123")
        #expect(try #require(MusicID("x:1")).raw == "x:1")  // unknown tag isn't stripped
    }

    @Test func rejectsEmptyIDs() {
        #expect(MusicID("") == nil)
        #expect(MusicID("c:") == nil)
    }
}

@Suite struct AuthMappingTests {
    @Test func mapsStatus() {
        #expect(AuthMapping.state(status: .notDetermined, canPlayCatalog: nil).state == .notDetermined)
        #expect(AuthMapping.state(status: .denied, canPlayCatalog: nil).state == .denied)
        #expect(AuthMapping.state(status: .restricted, canPlayCatalog: nil).state == .restricted)
        #expect(AuthMapping.state(status: .authorized, canPlayCatalog: true).state == .authorized)
        #expect(AuthMapping.state(status: .authorized, canPlayCatalog: false).state == .noSubscription)
    }

    @Test func unknownSubscriptionDoesNotBlock() {
        // A failed subscription lookup shouldn't claim the user has no subscription.
        #expect(AuthMapping.state(status: .authorized, canPlayCatalog: nil).state == .authorized)
    }
}

@Suite struct PlaybackDiffTests {
    private let start = Date(timeIntervalSince1970: 1000)
    private let track = HarmuneCore.Track(id: "c:1", title: "T", artist: "A", album: "B", duration: 300)

    private func playing(at position: TimeInterval, time: TimeInterval) -> PlaybackState {
        PlaybackState(track: track, isPlaying: true, position: position,
                      positionTimestamp: start.addingTimeInterval(time), rate: 1)
    }

    @Test func steadyPlaybackIsQuiet() {
        #expect(!PlaybackDiff.shouldPublish(previous: playing(at: 10, time: 0), next: playing(at: 40.2, time: 30)))
    }

    @Test func seekingPublishes() {
        #expect(PlaybackDiff.shouldPublish(previous: playing(at: 10, time: 0), next: playing(at: 100, time: 1)))
    }

    @Test func stateChangesPublish() {
        let base = playing(at: 10, time: 0)
        var paused = base; paused.isPlaying = false; paused.rate = 0
        var shuffled = base; shuffled.shuffle = true
        var repeating = base; repeating.repeat = .all
        var other = base; other.track?.id = "c:2"
        #expect(PlaybackDiff.shouldPublish(previous: base, next: paused))
        #expect(PlaybackDiff.shouldPublish(previous: base, next: shuffled))
        #expect(PlaybackDiff.shouldPublish(previous: base, next: repeating))
        #expect(PlaybackDiff.shouldPublish(previous: base, next: other))
    }

    @Test func pausedPositionDoesNotExtrapolate() {
        let paused = PlaybackState(track: track, isPlaying: false, position: 10, positionTimestamp: start, rate: 0)
        var later = paused; later.positionTimestamp = start.addingTimeInterval(60)
        #expect(!PlaybackDiff.shouldPublish(previous: paused, next: later))
    }
}

@Suite struct UntaggedItemTests {
    @Test func blankFieldsGetAFallback() {
        #expect(Mapping.named("", or: "X") == "X")
        #expect(Mapping.named("  ", or: "X") == "X")
        #expect(Mapping.named(nil, or: "X") == "X")
        #expect(Mapping.named("起风了", or: "X") == "起风了")
    }

    @Test func untitledAlbumsUseTheirFirstTrack() {
        #expect(Mapping.untitledAlbumName(firstTrack: "bensound-ukulele") == "Unknown Album (bensound-ukulele)")
        #expect(Mapping.untitledAlbumName(firstTrack: "") == "Unknown Album")
        #expect(Mapping.untitledAlbumName(firstTrack: nil) == "Unknown Album")
    }
}

@Suite struct ArtworkTests {
    @Test func fileNamesAreSafe() {
        #expect(ArtworkStore.fileName(forKey: "l:i.a/b") == "l_i_a_b.png")
    }

    private func bitmap(_ draw: (CGContext) -> Void) throws -> NSBitmapImageRep {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        let image = try #require(context.makeImage())
        return NSBitmapImageRep(cgImage: image)
    }

    @Test func missesExpire() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!ArtworkStore.missIsCurrent(modified: nil, now: now))
        #expect(ArtworkStore.missIsCurrent(modified: now.addingTimeInterval(-3600), now: now))
        #expect(!ArtworkStore.missIsCurrent(modified: now.addingTimeInterval(-ArtworkStore.missLifetime - 1), now: now))
    }

    @Test func largeImagesAreShrunk() throws {
        let context = try #require(CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let large = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let out = try #require(ArtworkStore.png(from: large))
        let rep = try #require(NSBitmapImageRep(data: out))
        #expect(rep.pixelsWide == ArtworkStore.pixels && rep.pixelsHigh == ArtworkStore.pixels)
    }

    @Test func placeholdersCountAsFlat() throws {
        let flat = try bitmap {
            $0.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
            $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        #expect(ArtworkRenderer.isFlat(flat))
    }

    @Test func realImagesDoNot() throws {
        let image = try bitmap {
            $0.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
            $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            $0.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            $0.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        #expect(!ArtworkRenderer.isFlat(image))
    }

    @Test func transcodesJPEGToPNG() throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let png = try #require(ArtworkStore.png(from: out as Data))
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(ArtworkStore.png(from: Data("not an image".utf8)) == nil)
    }
}

@Suite struct ArtworkCacheTests {
    @Test func pruneDeletesOldestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-prune-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, name) in ["old", "middle", "new"].enumerated() {
            let file = dir.appendingPathComponent(name)
            try Data(count: 100).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 3) * 1000)], ofItemAtPath: file.path)
        }
        #expect(ArtworkStore.prune(directory: dir, limit: 1000) == 0)
        #expect(ArtworkStore.prune(directory: dir, limit: 150) == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["new"])
    }
}

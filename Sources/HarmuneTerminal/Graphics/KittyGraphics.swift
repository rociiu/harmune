import Foundation

/// Keeps Kitty-protocol images in sync with the frame.
///
/// Each image file is transmitted once (by file path when local, inline
/// over SSH) and then placed by ID. Every frame, placements that moved or
/// disappeared are deleted and new ones are placed, so unchanged artwork
/// is never retransmitted (product_spec.md §11.2).
public struct KittyGraphics: Sendable {
    public var transmitByPath: Bool
    private var imageIDs: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var placed: [ImagePlacement: UInt32] = [:]  // placement -> placement id
    private var nextPlacementID: UInt32 = 1

    public init(transmitByPath: Bool) { self.transmitByPath = transmitByPath }

    /// SSH sessions can't read our files, so send pixels inline there.
    public static func canTransmitByPath(_ env: [String: String]) -> Bool {
        env["SSH_CONNECTION"] == nil && env["SSH_TTY"] == nil
    }

    /// Escape sequences that bring the terminal's placements in line with
    /// `wanted`. Call after writing the frame's cells.
    /// - Parameter fullRedraw: the screen was cleared, so nothing is placed.
    public mutating func sync(_ wanted: [ImagePlacement], fullRedraw: Bool) -> String {
        var out = ""
        if fullRedraw && !placed.isEmpty {
            out += Self.command(["a=d", "d=a", "q=2"])
            placed.removeAll()
        }
        let wantedSet = Set(wanted)
        for (placement, pid) in placed where !wantedSet.contains(placement) {
            if let id = imageIDs[placement.path] {
                out += Self.command(["a=d", "d=i", "i=\(id)", "p=\(pid)", "q=2"])
            }
            placed[placement] = nil
        }
        for placement in wanted where placed[placement] == nil {
            guard let id = transmitIfNeeded(placement.path, into: &out) else { continue }
            let pid = nextPlacementID
            nextPlacementID = nextPlacementID % 0xFFFF + 1
            out += "\u{1B}7\u{1B}[\(placement.rect.y + 1);\(placement.rect.x + 1)H"
            out += Self.command(["a=p", "i=\(id)", "p=\(pid)", "c=\(placement.rect.width)",
                                 "r=\(placement.rect.height)", "C=1", "q=2"])
            out += "\u{1B}8"
            placed[placement] = pid
        }
        return out
    }

    /// Deletes every image (on exit).
    public mutating func clearAll() -> String {
        placed.removeAll()
        imageIDs.removeAll()
        return Self.command(["a=d", "d=A", "q=2"])
    }

    private mutating func transmitIfNeeded(_ path: String, into out: inout String) -> UInt32? {
        if let id = imageIDs[path] { return id }
        let id = nextID
        if transmitByPath {
            out += Self.command(["a=t", "f=100", "t=f", "i=\(id)", "q=2"],
                                payload: Data(path.utf8).base64EncodedString())
        } else {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            out += Self.chunked(["a=t", "f=100", "t=d", "i=\(id)", "q=2"], base64: data.base64EncodedString())
        }
        imageIDs[path] = id
        nextID += 1
        return id
    }

    static func command(_ keys: [String], payload: String = "") -> String {
        "\u{1B}_G" + keys.joined(separator: ",") + (payload.isEmpty ? "" : ";" + payload) + "\u{1B}\\"
    }

    /// Inline data must be sent in chunks of at most 4096 bytes.
    static func chunked(_ keys: [String], base64: String) -> String {
        let bytes = Array(base64.utf8)
        var out = "", offset = 0
        repeat {
            let end = min(offset + 4096, bytes.count)
            let chunk = String(decoding: bytes[offset..<end], as: UTF8.self)
            let more = end < bytes.count ? 1 : 0
            let k = offset == 0 ? keys + ["m=\(more)"] : ["m=\(more)"]
            out += command(k, payload: chunk)
            offset = end
        } while offset < bytes.count
        return out
    }
}

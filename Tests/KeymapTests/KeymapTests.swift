import Foundation
import Testing
@testable import HarmuneTerminal

@Suite struct KeymapTests {
    let t0 = Date(timeIntervalSince1970: 0)

    /// CONTRIBUTING.md: regenerate this file with `harmune keys --markdown`.
    @Test func keybindingsDocMatchesTheDefaults() throws {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/KEYBINDINGS.md")
        #expect(try String(contentsOf: doc, encoding: .utf8).contains(Keymap.standard.helpMarkdown()))
    }

    func run(_ sequence: String, context: KeyContext = .global) -> [KeyResolution] {
        var r = KeyResolver()
        return Key.parseSequence(sequence)!.map { r.feed($0, context: context, at: t0) }
    }

    /// Every default binding from the spec resolves to its command.
    @Test(arguments: [
        ("j", KeyCommand.moveDown), ("k", .moveUp), ("h", .goBack), ("l", .openSelected), ("<cr>", .openSelected),
        ("G", .moveLast), ("<c-d>", .halfPageDown), ("<c-u>", .halfPageUp), ("<tab>", .focusNext),
        ("<s-tab>", .focusPrevious), ("<esc>", .close), ("q", .quit), ("/", .search), ("F", .filter),
        (":", .commandMode), ("?", .help), ("<space>", .playPause), (">", .nextTrack), ("<", .previousTrack),
        ("]", .seekForward), ("[", .seekBackward), ("s", .toggleShuffle), ("r", .cycleRepeat),
        ("f", .toggleFavorite), ("v", .toggleImmersive), ("a", .addToQueue), ("p", .playNext),
        ("o", .sort), ("t", .toggleLayout), ("H", .tabPrevious), ("L", .tabNext),
    ])
    func singleKeys(_ seq: String, _ command: KeyCommand) {
        guard case .command(let c, _) = run(seq).last else { Issue.record("\(seq) unresolved"); return }
        #expect(c == command)
    }

    @Test(arguments: [
        ("gg", KeyCommand.moveFirst), ("gh", .home), ("gs", .goSearch), ("gl", .songs), ("ga", .albums),
        ("gA", .artists), ("gp", .playlists), ("gf", .favorites), ("gr", .recentlyPlayed), ("gq", .queue),
        ("gn", .nowPlaying), ("g,", .settings),
    ])
    func gSequences(_ seq: String, _ command: KeyCommand) {
        let results = run(seq)
        #expect(results.first == .pending(display: "g"))
        #expect(results.last == .command(command, count: command.acceptsCount ? nil : nil))
    }

    @Test func countPrefix() {
        #expect(run("5j").last == .command(.moveDown, count: 5))
        #expect(run("12k").last == .command(.moveUp, count: 12))
        #expect(run("10j").last == .command(.moveDown, count: 10))
    }

    @Test func zeroCannotStartCount() {
        #expect(run("0").last == .unbound([.char("0")]))
    }

    @Test func countIgnoredForNonCountableCommands() {
        #expect(run("3<space>").last == .command(.playPause, count: nil))
    }

    @Test func pendingDisplayShowsCountAndKeys() {
        var r = KeyResolver()
        _ = r.feed(.char("3"), at: t0)
        #expect(r.feed(.char("g"), at: t0) == .pending(display: "3g"))
    }

    @Test func queueContextBindings() {
        #expect(run("dd", context: .queue).last == .command(.removeEntry, count: nil))
        #expect(run("J", context: .queue).last == .command(.moveEntryDown, count: nil))
        #expect(run("K", context: .queue).last == .command(.moveEntryUp, count: nil))
        #expect(run("D", context: .queue).last == .command(.clearQueue, count: nil))
        // Outside the queue `dd` does nothing.
        #expect(run("dd", context: .list).last == .unbound([.char("d")]))
        // Global bindings still work in the queue.
        #expect(run("j", context: .queue).last == .command(.moveDown, count: nil))
    }

    @Test func gridOverridesHorizontalKeys() {
        #expect(run("h", context: .grid).last == .command(.moveLeft, count: nil))
        #expect(run("3l", context: .grid).last == .command(.moveRight, count: 3))
        #expect(run("h", context: .list).last == .command(.goBack, count: nil))
    }

    /// Collisions fixed in the spec review: s=shuffle, q=close, o=sort.
    @Test func reviewedCollisions() {
        #expect(run("s", context: .grid).last == .command(.toggleShuffle, count: nil))
        #expect(run("q", context: .queue).last == .command(.quit, count: nil))
    }

    @Test func deadEndRetriesKeyAlone() {
        // `gj` is unbound: the `j` should still move down.
        #expect(run("gj").last == .command(.moveDown, count: nil))
    }

    @Test func escapeCancelsPending() {
        var r = KeyResolver()
        _ = r.feed(.char("g"), at: t0)
        #expect(r.feed(.escape, at: t0) == .unbound([.escape]))
        #expect(!r.isPending)
    }

    @Test func timeoutDropsStaleSequence() {
        var r = KeyResolver(timeout: 0.6)
        _ = r.feed(.char("g"), at: t0)
        #expect(r.expire(at: t0.addingTimeInterval(0.3)) == nil)
        #expect(r.expire(at: t0.addingTimeInterval(0.7)) == .unbound([.char("g")]))
        // After a timeout, `g` then `g` much later is not `gg`.
        _ = r.feed(.char("g"), at: t0)
        #expect(r.feed(.char("g"), at: t0.addingTimeInterval(1)) == .pending(display: "g"))
    }

    @Test func timeoutResolvesExactPrefixBinding() {
        var map = Keymap.standard
        map.bind("g", to: .home)
        var r = KeyResolver(keymap: map)
        #expect(r.feed(.char("g"), at: t0) == .pending(display: "g"))
        #expect(r.expire(at: t0.addingTimeInterval(1)) == .command(.home, count: nil))
    }

    @Test func parseNotation() {
        #expect(Key.parseSequence("<c-d>") == [.ctrl("d")])
        #expect(Key.parseSequence("<space>") == [.space])
        #expect(Key.parseSequence("<") == [.char("<")])
        #expect(Key.parseSequence("g,") == [.char("g"), .char(",")])
        #expect(Key.parseSequence("<bogus>") == nil)
        #expect(Key.parseSequence("space") == [.space])
        #expect(Key.parseSequence("Enter") == [.enter])
        #expect(Key.parseSequence("gs") == [.char("g"), .char("s")])
    }

    @Test func everyCommandNameIsUnique() {
        #expect(Set(KeyCommand.allCases.map(\.rawValue)).count == KeyCommand.allCases.count)
    }
}

@Suite struct KeyDecoderTests {
    @Test func decodesPlainAndControl() {
        var d = KeyDecoder()
        #expect(d.feed(Array("jG ".utf8)) == [.char("j"), .char("G"), .space])
        #expect(d.feed([0x04, 0x15, 0x0D, 0x09, 0x7F]) == [.ctrl("d"), .ctrl("u"), .enter, .tab, .backspace])
    }

    @Test func decodesEscapeSequences() {
        var d = KeyDecoder()
        #expect(d.feed(Array("\u{1B}[A\u{1B}[B\u{1B}OC\u{1B}[D\u{1B}[Z".utf8)) == [.up, .down, .right, .left, .backTab])
    }

    @Test func splitSequenceWaitsForMoreBytes() {
        var d = KeyDecoder()
        #expect(d.feed([0x1B, 0x5B]) == [])
        #expect(d.feed([0x41]) == [.up])
    }

    @Test func loneEscapeFlushes() {
        var d = KeyDecoder()
        #expect(d.feed([0x1B]) == [])
        #expect(d.flushEscape() == [.escape])
    }

    @Test func decodesUTF8() {
        var d = KeyDecoder()
        let bytes = Array("é".utf8)
        #expect(d.feed([bytes[0]]) == [])
        #expect(d.feed([bytes[1]]) == [.char("é")])
    }
}

/// One line of keyboard help: the commands it covers and what they do.
struct HelpEntry: Sendable {
    var commands: [KeyCommand]
    var action: String
    init(_ commands: KeyCommand..., action: String) { self.commands = commands; self.action = action }
}

extension Keymap {
    /// The source for the `?` overlay, `harmune keys` and docs/KEYBINDINGS.md.
    /// Keys come from the live keymap, so rebinding a key updates all three.
    static let helpSections: [(title: String, entries: [HelpEntry])] = [
        ("NAVIGATION", [
            HelpEntry(.moveDown, .moveUp, action: "move down / up (5j moves five)"),
            HelpEntry(.moveFirst, .moveLast, action: "first / last item"),
            HelpEntry(.halfPageDown, .halfPageUp, action: "half page down / up"),
            HelpEntry(.pageDown, .pageUp, action: "full page down / up"),
            HelpEntry(.center, action: "center the selection"),
            HelpEntry(.openSelected, action: "open or play the selection"),
            HelpEntry(.goBack, action: "back"),
            HelpEntry(.focusNext, action: "open or close the view switcher"),
            HelpEntry(.close, action: "close, clear the filter, or go back"),
            HelpEntry(.quit, action: "back; quit from the root (music keeps playing)"),
        ]),
        ("GO TO", [
            HelpEntry(.home, action: "Home"),
            HelpEntry(.goSearch, action: "Search"),
            HelpEntry(.songs, action: "Songs"),
            HelpEntry(.albums, action: "Albums"),
            HelpEntry(.artists, action: "Artists"),
            HelpEntry(.playlists, action: "Playlists"),
            HelpEntry(.recentlyPlayed, action: "Recently Played"),
            HelpEntry(.queue, action: "Queue"),
            HelpEntry(.nowPlaying, action: "Now Playing"),
            HelpEntry(.settings, action: "Settings"),
        ]),
        ("PLAYBACK", [
            HelpEntry(.playPause, action: "play / pause"),
            HelpEntry(.nextTrack, .previousTrack, action: "next / previous track"),
            HelpEntry(.seekForward, .seekBackward, action: "seek forward / back 5 seconds"),
            HelpEntry(.toggleShuffle, action: "shuffle"),
            HelpEntry(.cycleRepeat, action: "cycle repeat"),
            HelpEntry(.toggleImmersive, action: "immersive Now Playing"),
        ]),
        ("QUEUE", [
            HelpEntry(.addToQueue, .playNext, action: "add to queue / play next"),
            HelpEntry(.removeEntry, action: "remove the entry (in Queue, if supported)"),
            HelpEntry(.moveEntryDown, .moveEntryUp, action: "move the entry (in Queue, if supported)"),
            HelpEntry(.clearQueue, action: "clear upcoming (in Queue, if supported)"),
        ]),
        ("LISTS", [
            HelpEntry(.search, action: "search (Ctrl+S switches Apple Music / Library)"),
            HelpEntry(.tabPrevious, .tabNext, action: "previous / next search category"),
            HelpEntry(.filter, action: "filter the current list"),
            HelpEntry(.filterNext, .filterPrevious, action: "next / previous match"),
            HelpEntry(.sort, action: "sort Songs or Albums"),
            HelpEntry(.toggleLayout, action: "grid or list (Albums)"),
            HelpEntry(.commandMode, action: "command (:theme, :seek 90, :q)"),
            HelpEntry(.help, action: "this help"),
        ]),
    ]

    /// Sequences bound to a command, typed keys first, in a stable order.
    func sequences(for command: KeyCommand) -> [[Key]] {
        var found: [[Key]] = []
        for context in KeyContext.allCases {
            for (keys, bound) in bindings[context] ?? [:] where bound == command && !found.contains(keys) {
                found.append(keys)
            }
        }
        func rank(_ keys: [Key]) -> Int {
            switch keys.first {
            case .up?, .down?, .left?, .right?: 2
            case .char?: 0
            default: 1
            }
        }
        return found.sorted { (rank($0), $0.count, Self.display($0)) < (rank($1), $1.count, Self.display($1)) }
    }

    func shortcut(for command: KeyCommand) -> String? {
        sequences(for: command).first.map(Self.display)
    }

    static func display(_ keys: [Key]) -> String {
        keys.map { key in
            switch key {
            case .ctrl(let c): "Ctrl+\(c)"
            case .enter: "Enter"
            case .escape: "Esc"
            case .tab: "Tab"
            case .backTab: "Shift+Tab"
            case .backspace: "Backspace"
            case .space: "Space"
            case .up: "↑"
            case .down: "↓"
            case .left: "←"
            case .right: "→"
            default: key.description
            }
        }.joined()
    }

    /// Keys for a help line, such as "j / k". Empty when every command in it
    /// has been unbound.
    func keysLabel(for entry: HelpEntry) -> String {
        let labels: [String]
        if entry.commands.count == 1 {
            labels = sequences(for: entry.commands[0]).prefix(2).map(Self.display)
        } else {
            labels = entry.commands.compactMap { sequences(for: $0).first }.map(Self.display)
        }
        return labels.joined(separator: " / ")
    }

    /// Plain text for `harmune keys`.
    public func helpText() -> String {
        Self.helpSections.map { section in
            let lines = section.entries.compactMap { entry -> String? in
                let keys = keysLabel(for: entry)
                return keys.isEmpty ? nil : "  " + pad(keys, to: 20) + " " + entry.action
            }
            return ([section.title] + lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// A Markdown table per section, for docs/KEYBINDINGS.md.
    public func helpMarkdown() -> String {
        Self.helpSections.map { section in
            let rows = section.entries.compactMap { entry -> String? in
                let keys = keysLabel(for: entry)
                guard !keys.isEmpty else { return nil }
                let cells = keys.components(separatedBy: " / ").map { "`\($0.replacingOccurrences(of: "|", with: "\\|"))`" }
                return "| \(cells.joined(separator: " / ")) | \(entry.action) |"
            }
            return (["## \(section.title.capitalized)", "", "| Keys | Action |", "|---|---|"] + rows).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

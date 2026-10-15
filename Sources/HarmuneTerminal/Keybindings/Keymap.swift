import Foundation

/// Every action a key can trigger. Raw values are the names used in
/// `config.toml` keybinding tables.
public enum KeyCommand: String, Sendable, CaseIterable, Hashable {
    // Movement
    case moveDown = "move_down", moveUp = "move_up", moveLeft = "move_left", moveRight = "move_right"
    case moveFirst = "move_first", moveLast = "move_last"
    case halfPageDown = "half_page_down", halfPageUp = "half_page_up"
    case goBack = "go_back", openSelected = "open_selected"
    case focusNext = "focus_next", focusPrevious = "focus_previous"
    case close = "close"
    /// Close the current view; quit from the root view (`q`).
    case quit = "quit"
    case search = "search", filter = "filter", filterNext = "filter_next", filterPrevious = "filter_previous"
    case commandMode = "command_mode", help = "help"
    case tabPrevious = "tab_previous", tabNext = "tab_next"
    case sort = "sort", toggleLayout = "toggle_layout"
    // Destinations
    case home, goSearch = "go_search", songs, albums, artists, playlists
    case favorites, recentlyPlayed = "recently_played", queue, nowPlaying = "now_playing", settings
    // Playback
    case playPause = "play_pause", nextTrack = "next_track", previousTrack = "previous_track"
    case seekForward = "seek_forward", seekBackward = "seek_backward"
    case toggleShuffle = "toggle_shuffle", cycleRepeat = "cycle_repeat"
    case toggleFavorite = "toggle_favorite", toggleImmersive = "toggle_immersive"
    // Queue
    case addToQueue = "add_to_queue", playNext = "play_next"
    case removeEntry = "remove_entry", moveEntryDown = "move_entry_down", moveEntryUp = "move_entry_up"
    case clearQueue = "clear_queue"

    /// Whether a count prefix (`5j`) repeats or scales this command.
    public var acceptsCount: Bool {
        switch self {
        case .moveDown, .moveUp, .moveLeft, .moveRight, .halfPageDown, .halfPageUp,
             .seekForward, .seekBackward, .moveEntryDown, .moveEntryUp, .moveLast, .moveFirst:
            true
        default: false
        }
    }
}

/// Where the keys are being pressed. Context bindings take precedence over
/// global ones.
public enum KeyContext: String, Sendable, CaseIterable, Hashable {
    case global, list, grid, queue
}

public struct Keymap: Sendable {
    public private(set) var bindings: [KeyContext: [[Key]: KeyCommand]]

    public init(bindings: [KeyContext: [[Key]: KeyCommand]] = [:]) { self.bindings = bindings }

    public mutating func bind(_ sequence: String, to command: KeyCommand, in context: KeyContext = .global) {
        guard let keys = Key.parseSequence(sequence) else {
            preconditionFailure("Invalid key sequence '\(sequence)'")
        }
        bindings[context, default: [:]][keys] = command
    }

    public mutating func unbind(_ sequence: [Key], in context: KeyContext) {
        bindings[context]?[sequence] = nil
    }

    func command(for keys: [Key], in context: KeyContext) -> KeyCommand? {
        bindings[context]?[keys] ?? (context == .global ? nil : bindings[.global]?[keys])
    }

    func isPrefix(_ keys: [Key], in context: KeyContext) -> Bool {
        let contexts: [KeyContext] = context == .global ? [.global] : [context, .global]
        return contexts.contains { ctx in
            bindings[ctx]?.keys.contains { $0.count > keys.count && Array($0.prefix(keys.count)) == keys } ?? false
        }
    }

    /// The default bindings from product_spec.md §6 (revised 1.1).
    public static let standard: Keymap = {
        var m = Keymap()
        let global: [(String, KeyCommand)] = [
            ("j", .moveDown), ("<down>", .moveDown), ("k", .moveUp), ("<up>", .moveUp),
            ("h", .goBack), ("<left>", .goBack), ("l", .openSelected), ("<right>", .openSelected),
            ("<cr>", .openSelected), ("gg", .moveFirst), ("G", .moveLast),
            ("<c-d>", .halfPageDown), ("<c-u>", .halfPageUp),
            ("<tab>", .focusNext), ("<s-tab>", .focusPrevious), ("<esc>", .close), ("q", .quit), ("<c-c>", .quit),
            ("/", .search), ("F", .filter), ("n", .filterNext), ("N", .filterPrevious),
            (":", .commandMode), ("?", .help), ("H", .tabPrevious), ("L", .tabNext),
            ("o", .sort), ("t", .toggleLayout),
            ("gh", .home), ("gs", .goSearch), ("gl", .songs), ("ga", .albums), ("gA", .artists),
            ("gp", .playlists), ("gf", .favorites), ("gr", .recentlyPlayed), ("gq", .queue),
            ("gn", .nowPlaying), ("g,", .settings),
            ("<space>", .playPause), (">", .nextTrack), ("<", .previousTrack),
            ("]", .seekForward), ("[", .seekBackward), ("s", .toggleShuffle), ("r", .cycleRepeat),
            ("f", .toggleFavorite), ("v", .toggleImmersive),
            ("a", .addToQueue), ("p", .playNext),
        ]
        for (seq, cmd) in global { m.bind(seq, to: cmd) }
        // Grid views move in 2D.
        m.bind("h", to: .moveLeft, in: .grid)
        m.bind("l", to: .moveRight, in: .grid)
        m.bind("<left>", to: .moveLeft, in: .grid)
        m.bind("<right>", to: .moveRight, in: .grid)
        // Queue editing.
        m.bind("dd", to: .removeEntry, in: .queue)
        m.bind("J", to: .moveEntryDown, in: .queue)
        m.bind("K", to: .moveEntryUp, in: .queue)
        m.bind("D", to: .clearQueue, in: .queue)
        return m
    }()
}

/// Result of feeding a key to the resolver.
public enum KeyResolution: Equatable, Sendable {
    /// A command, with an optional count prefix.
    case command(KeyCommand, count: Int?)
    /// Waiting for more keys; `display` is shown in the status bar.
    case pending(display: String)
    case unbound([Key])
}

/// Resolves key presses to commands, centrally for every view: count
/// prefixes, multi-key sequences and the sequence timeout.
public struct KeyResolver: Sendable {
    public var keymap: Keymap
    public var timeout: TimeInterval

    private var count: String = ""
    private var pending: [Key] = []
    private var lastKeyTime: Date?

    public init(keymap: Keymap = .standard, timeout: TimeInterval = 0.6) {
        self.keymap = keymap
        self.timeout = timeout
    }

    public var isPending: Bool { !pending.isEmpty || !count.isEmpty }
    public var pendingDisplay: String { count + pending.map(\.description).joined() }

    public mutating func reset() {
        count = ""; pending = []; lastKeyTime = nil
    }

    public mutating func feed(_ key: Key, context: KeyContext = .global, at now: Date = Date()) -> KeyResolution {
        // A stale sequence is discarded. The UI's timer calls `expire` to
        // emit any command it completed, so nothing is lost here.
        if isPending, let last = lastKeyTime, now.timeIntervalSince(last) >= timeout { reset() }
        lastKeyTime = now

        if key == .escape, isPending {
            reset()
            return .unbound([.escape])
        }

        // Count prefix: 1–9 start it, 0 only continues it.
        if pending.isEmpty, let d = key.digit, d != 0 || !count.isEmpty {
            count.append(String(d))
            return .pending(display: pendingDisplay)
        }

        let sequence = pending + [key]
        let exact = keymap.command(for: sequence, in: context)
        let longer = keymap.isPrefix(sequence, in: context)

        if let exact, !longer {
            return finish(exact)
        }
        if longer {
            pending = sequence
            return .pending(display: pendingDisplay)
        }
        // Dead end. If we were mid-sequence, retry this key on its own.
        let hadPending = !pending.isEmpty
        let savedCount = count
        reset()
        if hadPending {
            count = savedCount
            return feed(key, context: context, at: now)
        }
        return .unbound(sequence)
    }

    /// Call periodically (or before the next key) to resolve a sequence
    /// that has waited past `timeout`, e.g. `g` alone if it were bound.
    public mutating func expire(context: KeyContext = .global, at now: Date = Date()) -> KeyResolution? {
        guard isPending, let last = lastKeyTime, now.timeIntervalSince(last) >= timeout else { return nil }
        if !pending.isEmpty, let exact = keymap.command(for: pending, in: context) {
            return finish(exact)
        }
        let dropped = pending
        reset()
        return .unbound(dropped)
    }

    private mutating func finish(_ command: KeyCommand) -> KeyResolution {
        let n = Int(count)
        reset()
        return .command(command, count: command.acceptsCount ? n : nil)
    }
}

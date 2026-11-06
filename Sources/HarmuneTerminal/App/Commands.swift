import HarmuneCore

/// Command-mode vocabulary: top-level routes, completion and suggestions.
enum CommandLine {
    static let routes: [String: Route] = [
        "home": .home, "search": .search, "songs": .songs, "library": .songs, "albums": .albums,
        "artists": .artists, "playlists": .playlists, "queue": .queue, "recent": .recentlyPlayed,
        "settings": .settings,
    ]
    static let verbs = ["quit", "play", "pause", "toggle", "next", "previous", "seek", "shuffle", "repeat",
                        "search", "filter", "sort", "theme", "artwork", "visualizer", "immersive", "queue", "reload",
                        "help", "service", "auth", "home", "songs", "library", "albums", "artists", "playlists",
                        "recent", "nowplaying", "settings"]

    static func arguments(for verb: String, themes: [Theme]) -> [String] {
        switch verb {
        case "shuffle", "artwork", "visualizer": ["on", "off"]
        case "repeat": RepeatMode.allCases.map(\.rawValue)
        case "theme": themes.map(\.name)
        case "queue": ["clear"]
        case "service": ["stop"]
        case "sort": ["title", "artist", "added"]
        default: []
        }
    }

    /// Candidates for what's typed: prefix matches first, then any word that
    /// contains the typed letters in order.
    static func suggestions(_ input: String, themes: [Theme]) -> [String] {
        let trimmed = input.drop { $0 == " " }
        guard let space = trimmed.firstIndex(of: " ") else {
            return ranked(verbs, matching: String(trimmed))
        }
        let verb = String(trimmed[..<space])
        let typed = trimmed[trimmed.index(after: space)...].trimmingPrefix(" ")
        return ranked(arguments(for: verb, themes: themes), matching: String(typed)).map { "\(verb) \($0)" }
    }

    private static func ranked(_ words: [String], matching typed: String) -> [String] {
        let prefix = words.filter { $0.hasPrefix(typed) }
        let fuzzy = words.filter { !$0.hasPrefix(typed) && isSubsequence(typed, of: $0) }
        return prefix + fuzzy
    }

    private static func isSubsequence(_ needle: String, of word: String) -> Bool {
        var remaining = Substring(needle)
        for c in word where c == remaining.first { remaining.removeFirst() }
        return remaining.isEmpty
    }

    /// What Tab turns the input into, or nil when nothing matches.
    static func complete(_ input: String, themes: [Theme]) -> String? {
        let matches = suggestions(input, themes: themes)
        guard let first = matches.first else { return nil }
        let prefixed = matches.filter { $0.hasPrefix(input) }
        if prefixed.count == 1 { return prefixed[0] + (input.contains(" ") ? "" : " ") }
        if prefixed.isEmpty { return matches.count == 1 ? first + (input.contains(" ") ? "" : " ") : nil }
        var common = prefixed[0]
        for m in prefixed.dropFirst() { while !m.hasPrefix(common) { common.removeLast() } }
        return common
    }
}

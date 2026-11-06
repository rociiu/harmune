/// Shell completion scripts for `harmune completions <shell>`.
enum Completions {
    static let commands = ["status", "play", "pause", "toggle", "next", "previous", "seek", "shuffle", "repeat",
                           "queue", "add", "search", "library", "album", "playlist", "artist", "service", "auth",
                           "config", "keys", "completions", "cache", "help"]
    static let subcommands: [(String, [String])] = [
        ("shuffle", ["on", "off"]), ("repeat", ["off", "one", "all"]), ("queue", ["add"]),
        ("library", ["songs", "albums", "artists", "playlists"]), ("service", ["status", "start", "stop"]),
        ("auth", ["status"]), ("config", ["path", "check"]), ("completions", ["zsh", "bash", "fish"]),
        ("cache", ["path", "size", "clear"]),
    ]

    static func script(for shell: String) -> String? {
        switch shell {
        case "zsh": zsh
        case "bash": bash
        case "fish": fish
        default: nil
        }
    }

    private static var zsh: String {
        let cases = subcommands.map { "    \($0.0)) compadd \($0.1.joined(separator: " ")) ;;" }.joined(separator: "\n")
        return """
        #compdef harmune
        _harmune() {
          if (( CURRENT == 2 )); then
            compadd \(commands.joined(separator: " "))
            return
          fi
          case "$words[2]" in
        \(cases)
          esac
        }
        compdef _harmune harmune
        """
    }

    private static var bash: String {
        let cases = subcommands.map { "    \($0.0)) COMPREPLY=($(compgen -W \"\($0.1.joined(separator: " "))\" -- \"$cur\")) ;;" }.joined(separator: "\n")
        return """
        _harmune() {
          local cur="${COMP_WORDS[COMP_CWORD]}"
          if [ "$COMP_CWORD" -eq 1 ]; then
            COMPREPLY=($(compgen -W "\(commands.joined(separator: " "))" -- "$cur"))
            return
          fi
          case "${COMP_WORDS[1]}" in
        \(cases)
          esac
        }
        complete -F _harmune harmune
        """
    }

    private static var fish: String {
        let top = "complete -c harmune -f -n __fish_use_subcommand -a '\(commands.joined(separator: " "))'"
        let subs = subcommands.map { "complete -c harmune -f -n '__fish_seen_subcommand_from \($0.0)' -a '\($0.1.joined(separator: " "))'" }
        return ([top] + subs).joined(separator: "\n")
    }
}

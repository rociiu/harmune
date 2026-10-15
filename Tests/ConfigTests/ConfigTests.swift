import Testing
@testable import HarmuneConfig
@testable import HarmuneTerminal

@Suite struct ConfigTests {
    @Test func specExampleParsesCleanly() {
        // The example from product_spec.md §17.2.
        let text = """
        [general]
        theme = "harmune-midnight"
        start_page = "home"
        restore_last_view = true

        [appearance]
        show_artwork = true
        artwork_size = "medium"
        show_visualizer = true
        show_borders = true
        dynamic_colors = true

        [animation]
        enabled = true
        reduced_motion = false
        max_fps = 20

        [player]
        show_progress = true
        show_duration = true

        [keybindings.normal]
        "j" = "move_down"
        "k" = "move_up"
        "h" = "go_back"
        "l" = "open_selected"
        "gg" = "move_first"
        "G" = "move_last"
        "space" = "play_pause"
        ">" = "next_track"
        "<" = "previous_track"
        "v" = "toggle_immersive"

        [keybindings.navigation]
        "gh" = "home"
        "gl" = "songs"
        "gs" = "go_search"
        "gq" = "queue"
        "gn" = "now_playing"
        """
        let (config, warnings) = HarmuneConfig.parse(text)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(config.theme == "harmune-midnight")
        #expect(config.keybindings["normal"]?["gg"] == "move_first")
        var keymap = Keymap.standard
        let keyWarnings = keymap.apply(overrides: config.keybindings)
        #expect(keyWarnings.isEmpty, "\(keyWarnings)")
        // Bare "space" is the Space key, so `s` (shuffle) is not turned into a sequence prefix.
        var r = KeyResolver(keymap: keymap)
        #expect(r.feed(.space) == .command(.playPause, count: nil))
        #expect(r.feed(.char("s")) == .command(.toggleShuffle, count: nil))
    }

    @Test func invalidValuesWarnAndFallBack() {
        let (config, warnings) = HarmuneConfig.parse("""
        [general]
        start_page = "nowhere"
        [appearance]
        show_artwork = "yes"
        album_view = "table"
        graphics = "sixel"
        [animation]
        reduced_motion = true
        bogus = 1
        [keys]
        sequence_timeout_ms = 10
        """)
        #expect(config.startPage == "home")
        #expect(config.showArtwork == true)
        #expect(config.albumView == "table")
        #expect(config.graphics == "auto")
        #expect(config.reducedMotion)
        #expect(config.sequenceTimeoutMs == 600)
        #expect(warnings.count == 5, "\(warnings)")
        #expect(warnings.contains { $0.contains("unknown setting animation.bogus") })
        #expect(warnings.allSatisfy { $0.hasPrefix("line ") })
    }

    @Test func syntaxErrors() {
        let (_, warnings) = HarmuneConfig.parse("""
        # comment
        [general
        theme
        theme = [1, 2]
        name = "a # not a comment" # real comment
        [[array]]
        """)
        #expect(warnings.count == 5, "\(warnings)")  // bad table, missing =, array value, unknown key, [[ ]]
    }

    @Test func stringEscapesAndComments() {
        #expect(TOMLLite.parseValue("\"a\\\"b\"") == .string("a\"b"))
        #expect(TOMLLite.stripComment("x = \"#nope\" # yes") == "x = \"#nope\" ")
        #expect(TOMLLite.parseValue("1_000") == .int(1000))
    }

    @Test func keybindingOverrides() {
        var keymap = Keymap.standard
        let warnings = keymap.apply(overrides: [
            "normal": ["<c-n>": "next_track", "x": "explode", "<bad>": "home", "s": "none", "5x": "home"],
            "queue": ["x": "remove_entry"],
            "weird": ["a": "home"],
        ])
        #expect(warnings.count == 4, "\(warnings)")
        var r = KeyResolver(keymap: keymap)
        #expect(r.feed(.ctrl("n")) == .command(.nextTrack, count: nil))
        #expect(r.feed(.char("s")) == .unbound([.char("s")]))
        #expect(r.feed(.char("x"), context: .queue) == .command(.removeEntry, count: nil))
    }

    @Test func warnsWhenASingleKeyBecomesAPrefix() {
        var keymap = Keymap.standard
        #expect(keymap.conflicts().isEmpty)  // defaults are conflict-free
        let warnings = keymap.apply(overrides: ["normal": ["sx": "home"]])
        #expect(warnings.count == 1 && warnings[0].contains("\"s\""), "\(warnings)")
    }
}

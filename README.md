# Harmune

Your music. Your terminal. A keyboard-first Apple Music player for macOS.

- Product spec: [product_spec.md](product_spec.md)
- Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Development and releasing: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- IPC protocol: [docs/PROTOCOL.md](docs/PROTOCOL.md)
- Review notes: [docs/SPEC_REVIEW.md](docs/SPEC_REVIEW.md)
- Implementation plan: [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)

## Status

Harmune plays Apple Music from a signed host with Music.app closed, and keeps playing after the terminal closes ([test results](docs/PHASE0_RESULTS.md)). It hasn't been released yet: a public build needs a Developer ID certificate and notarization, so for now you build it yourself.

**What's in it**

- **TUI:** Home, Search, Songs, Albums (artwork grid or list), Artists, Playlists, Recently Played, album, artist and playlist pages, Queue, immersive Now Playing, Settings, help and command mode
- **Themes:** harmune-midnight, tokyo-night, catppuccin-mocha, gruvbox-dark, nord, dracula, mono, and your own
- **Artwork:** Kitty graphics (Kitty, Ghostty), iTerm2 inline images (iTerm2, WezTerm), Sixel, or half-blocks everywhere else
- **CLI:** playback, queue, search, library, service, config, key list, shell completions and cache

**Known limitations**

- Favorites aren't supported.
- The visualizer is decorative, because MusicKit doesn't expose audio.
- There's no volume control, because MusicKit has no API for it on macOS.
- Inside tmux, artwork uses half-blocks.
- Kitty, iTerm2 and Sixel image output is tested by its bytes, but hasn't been checked by eye in those terminals yet.
- The blurred artwork background from the spec isn't built.

## Try it

The demo library is fictional, so you don't need an Apple account.

```bash
swift build
```

```bash
.build/debug/harmune --demo
```

Use `↑` and `↓` to move, `Enter` to open or play, and `Space` to pause or resume. Press `Tab` to switch views, `/` to search, `:` to run a command, or `?` for [keyboard shortcuts](docs/KEYBINDINGS.md).

## Use it with Apple Music

You need an Apple Developer account for signing and an Apple Music subscription. Set up your App ID using [docs/PHASE0_SETUP.md](docs/PHASE0_SETUP.md), then build:

```bash
Scripts/build-host.sh
```

```bash
build/Harmune.app/Contents/Resources/bin/harmune
```

The first run asks you to connect Apple Music. Music keeps playing when you quit, and the host exits after 30 idle minutes. To stop it yourself:

```bash
build/Harmune.app/Contents/Resources/bin/harmune service stop
```

The CLI uses the same host:

```bash
build/Harmune.app/Contents/Resources/bin/harmune search "In Rainbows"
```

```bash
build/Harmune.app/Contents/Resources/bin/harmune play --search "Reckoner"
```

```bash
build/Harmune.app/Contents/Resources/bin/harmune status --json
```

Run `harmune --help` for everything else. For shell completions, add this to `~/.zshrc`:

```bash
eval "$(harmune completions zsh)"
```

## Configuration

Harmune reads `~/.config/harmune/config.toml` (or `$XDG_CONFIG_HOME/harmune/config.toml`, or `--config <path>`). A problem in the file never stops the app: it shows a warning and uses the default.

```toml
[general]
theme = "harmune-midnight"   # or tokyo-night, catppuccin-mocha, gruvbox-dark, nord, dracula, mono
start_page = "albums"        # home, search, songs, albums, artists, playlists, queue
restore_last_view = false

[appearance]
show_artwork = true
graphics = "auto"            # auto, kitty, iterm2, sixel, halfblock, none
album_view = "table"         # table or artwork grid
artwork_size = "medium"      # small, medium, large (immersive view)
show_visualizer = true
show_borders = true
dynamic_colors = true        # accent colors from the current cover

[animation]
enabled = true
reduced_motion = false
max_fps = 20

[player]
show_progress = true
show_duration = true

[keys]
sequence_timeout_ms = 600

[keybindings.normal]
"<c-n>" = "next_track"
"s" = "none"                 # unbind
```

Settings (`g,`), the theme picker (`:theme`) and `t` in Albums save their changes here, and leave the rest of the file as you wrote it.

### Custom themes

Add a file such as `~/.config/harmune/themes/my-theme.toml`. Anything you leave out comes from `base`:

```toml
base = "nord"
accent = "#C6A5FF"
background = "#101018"
```

Tokens: `background`, `surface`, `elevated`, `text`, `text_secondary`, `muted`, `accent`, `accent_pink`, `accent_blue`, `success`, `warning`, `error`, `border`.

Check a config file:

```bash
harmune config check
```

## Tests

```bash
swift test
```

## License

MIT. See [LICENSE](LICENSE).

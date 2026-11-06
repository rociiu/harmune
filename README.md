# Harmune

Your music. Your terminal. A keyboard-first Apple Music player for macOS.

- Product spec: [product_spec.md](product_spec.md)
- Review notes: [docs/SPEC_REVIEW.md](docs/SPEC_REVIEW.md)
- Implementation plan: [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)

## Status

Phase 1 MVP slices (plan M1.1–M1.6, running on the demo backend):

| Module | What's there |
|---|---|
| `HarmuneCore` | Domain models, the `MusicBackend` protocol, playback clock extrapolation, typed errors, paths |
| `HarmuneIPC` | NDJSON wire protocol, Unix socket server/client (0600, same-UID peer check, single-instance lock), `RemoteBackend` |
| `HarmuneDemo` | `DemoBackend`: deterministic fictional library with generated cover art, simulated playback clock, queue/shuffle/repeat |
| `HarmuneTerminal` | The TUI. A small renderer of our own (cell canvas + diffed ANSI output, truecolor/256/`NO_COLOR`), store, keymap, and screens: Home, Search, Songs, Albums (artwork grid or list, `t`), Artists, Playlists, album/playlist/artist detail, Queue, Now Playing, help, command line. Artwork via the Kitty graphics protocol (Kitty, Ghostty) or half-block pixels elsewhere |
| `HarmuneConfig` | `config.toml` parsing and validation with line-numbered warnings; custom keybindings |
| `harmune` | Launches the TUI with no arguments, plus CLI subcommands for playback, queue, search, library and `service` management. Auto-starts the host detached from the terminal |
| `harmune-host` | Development host that serves `DemoBackend` over the socket |
| `HarmuneMusic`, `HarmuneHostApp` | `MusicKitBackend` and the host app that serves it, packaged as `build/Harmune.app`. Plays Apple Music with Music.app closed |

**Phase 0 status:** playback works from an Apple Development build with no provisioning profile ([results](docs/PHASE0_RESULTS.md), [how to run the checks](docs/PHASE0_SETUP.md)). Still to check: music surviving a closed terminal window, the TUI against Apple Music, and a notarized Developer ID build.
Not built yet:
- iTerm2 and Sixel image protocols, tmux passthrough, and querying the terminal for graphics support (detection is by terminal name; `HARMUNE_GRAPHICS=kitty|halfblock|none` overrides it)
- sorting, favorites, and themes beyond `harmune-midnight` and `mono`
- queue removal and reordering on the MusicKit backend (off until Phase 0 check V11 shows they work)
- an authorization flow in the TUI (use `harmune auth`)

**UI framework decision:** instead of the beta SwiftTUI, Harmune uses a small renderer of its own, the fallback in the plan's Phase 0. Views only draw into a `Canvas`, so this can be revisited later.

## Try it

The demo library is fictional, so you don't need an Apple account.

```bash
swift build
```

Run the TUI against an in-process demo library:

```bash
.build/debug/harmune --demo
```

Or run it against the background host, so music keeps playing after you quit:

```bash
.build/debug/harmune
```

Press `?` inside the app for keys. The CLI also works against the same host:

```bash
.build/debug/harmune library albums
```

```bash
.build/debug/harmune play --album al1 --track 2
```

```bash
.build/debug/harmune status --json
```

```bash
.build/debug/harmune service stop --force
```

The first command that needs the host starts `harmune-host --demo` in its own session, so it keeps running after the terminal closes. The host exits after 30 idle minutes. Set `HARMUNE_SOCKET=/tmp/x.sock` to use an isolated socket.

## Configuration

Harmune reads `~/.config/harmune/config.toml` (or `$XDG_CONFIG_HOME/harmune/config.toml`, or `--config <path>`). A problem in the file never stops the app: it shows a warning and uses the default.

```toml
[general]
theme = "harmune-midnight"   # or "mono"
start_page = "albums"        # home, search, songs, albums, artists, playlists, queue

[appearance]
show_artwork = true
graphics = "auto"            # auto, kitty, halfblock, none
album_view = "grid"          # grid or table

[animation]
reduced_motion = false

[keys]
sequence_timeout_ms = 600

[keybindings.normal]
"<c-n>" = "next_track"
"s" = "none"                 # unbind
```

Check a config file:

```bash
.build/debug/harmune config check
```

## Tests

```bash
swift test
```

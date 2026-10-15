# Harmune

Your music. Your terminal. A keyboard-first Apple Music player for macOS.

- Product spec: [product_spec.md](product_spec.md)
- Review notes: [docs/SPEC_REVIEW.md](docs/SPEC_REVIEW.md)
- Implementation plan: [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)

## Status

Phase 1 foundations (plan M1.1–M1.3, plus a first pass of M1.5 screens):

| Module | What's there |
|---|---|
| `HarmuneCore` | Domain models, the `MusicBackend` protocol, playback clock extrapolation, typed errors, paths |
| `HarmuneIPC` | NDJSON wire protocol, Unix socket server/client (0600, same-UID peer check, single-instance lock), `RemoteBackend` |
| `HarmuneDemo` | `DemoBackend`: deterministic fictional library, simulated playback clock, queue/shuffle/repeat |
| `HarmuneTerminal` | The TUI. A small renderer of our own (cell canvas + diffed ANSI output, truecolor/256/`NO_COLOR`), store, keymap, and screens: Home, Search, Songs, Albums, Artists, Playlists, album/playlist/artist detail, Queue, Now Playing, help, command line |
| `harmune` | Launches the TUI with no arguments, plus CLI subcommands for playback, queue, search, library and `service` management. Auto-starts the host detached from the terminal |
| `harmune-host` | Development host that serves `DemoBackend` over the socket |

Not built yet:
- real terminal artwork (Kitty / iTerm2 / Sixel): album art is currently a half-block gradient placeholder
- the album grid view, sorting and favorites
- `config.toml` and themes beyond `harmune-midnight` and `mono`
- the signed MusicKit host app (Phase 0 needs an Apple Developer account)

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

## Tests

```bash
swift test
```

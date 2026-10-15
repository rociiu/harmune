# Harmune

Your music. Your terminal. A keyboard-first Apple Music player for macOS.

- Product spec: [product_spec.md](product_spec.md)
- Review notes: [docs/SPEC_REVIEW.md](docs/SPEC_REVIEW.md)
- Implementation plan: [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)

## Status

The first slice of the implementation plan (M1.1–M1.2, plus the keymap from M1.3):

| Module | What's there |
|---|---|
| `HarmuneCore` | Domain models, the `MusicBackend` protocol, playback clock extrapolation, typed errors, paths |
| `HarmuneIPC` | NDJSON wire protocol, Unix socket server/client (0600, same-UID peer check, single-instance lock), `RemoteBackend` |
| `HarmuneDemo` | `DemoBackend`: deterministic fictional library, simulated playback clock, queue/shuffle/repeat |
| `HarmuneTerminal` | Keymap engine (counts, `gg`/`dd` sequences, timeout, per-context bindings) and raw key decoding |
| `harmune` | CLI: playback, queue, search, library, `service` management. Auto-starts the host detached from the terminal |
| `harmune-host` | Development host that serves `DemoBackend` over the socket |

Not built yet: the TUI screens, terminal graphics, and the signed MusicKit host app (Phase 0 needs an Apple Developer account).

## Try it

The demo library is fictional, so you don't need an Apple account.

```bash
swift build
```

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

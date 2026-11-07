# Contributing

You don't need an Apple Developer account or an Apple Music subscription for most work. `harmune --demo` runs the whole TUI on a fictional library.

```bash
swift build
```

```bash
swift test
```

```bash
.build/debug/harmune --demo
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for how to build the real host and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the parts fit.

## Pull requests

- Add tests with the change. UI behavior is tested through `AppStore` and `ShellView.render`, on `DemoBackend`.
- If you change default keys, regenerate the key reference:

  ```bash
  .build/debug/harmune keys --markdown
  ```

  Put the output below the introduction in `docs/KEYBINDINGS.md`. A test fails if they differ.
- If you change the IPC protocol, update `docs/PROTOCOL.md`.
- Don't add third-party dependencies without discussing it in an issue first. The project has none so far.
- `HarmuneTerminal` must not import MusicKit. Only `HarmuneMusic` does.

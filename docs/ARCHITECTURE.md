# Architecture

Harmune is two processes. The one you see comes and goes, and the one playing music stays.

```text
Terminal                         Background
┌───────────────────┐  Unix      ┌────────────────────────┐
│ harmune           │  socket    │ Harmune.app (host)     │
│  TUI or CLI       │◄──────────►│  MusicKitBackend       │──► Apple Music
│  RemoteBackend    │  NDJSON    │  ApplicationMusicPlayer│
└───────────────────┘            └────────────────────────┘
```

The host exists for two reasons. Music keeps playing when the terminal closes, and macOS attributes Apple Music permission to Harmune rather than to the terminal, because the host is launched through LaunchServices.

## Modules

| Module | Role | May use |
|---|---|---|
| `HarmuneCore` | Models, the `MusicBackend` protocol, errors, paths | Foundation |
| `HarmuneIPC` | Wire protocol, socket server and client, `RemoteBackend` | Core |
| `HarmuneDemo` | `DemoBackend`: fictional library and simulated playback | Core |
| `HarmuneMusic` | `MusicKitBackend`, artwork cache | Core, MusicKit |
| `HarmuneTerminal` | The TUI | Core |
| `HarmuneConfig` | `config.toml` parsing and saving | Foundation |
| `harmune` | CLI and TUI entry point, host launcher | all but Music |
| `HarmuneHostApp` | Executable inside `Harmune.app` | Core, IPC, Music |
| `harmune-host` | Development host that serves `DemoBackend` | Core, IPC, Demo |

## The backend seam

The TUI only talks to `MusicBackend`. It gets `RemoteBackend` normally and `DemoBackend` with `--demo`, and it can't tell them apart. That's why nearly everything can be tested without an Apple account.

## TUI

State flows one way:

```text
key → KeyResolver → KeyCommand → AppStore → AppState → ShellView → Canvas → Renderer → terminal
                                     ↕
                               MusicBackend
```

- **`KeyResolver`** handles counts, sequences and timeouts for every view, using one keymap.
- **`AppStore`** owns `AppState` and runs backend calls. After a queue or playback command, it shows what the host confirms, never a guess.
- **`screen(for:in:)`** turns state into a `ScreenModel`, so the store and the view agree on which row is which.
- **`ShellView`** draws state into a `Canvas` and has no side effects, so frames can be tested as plain text.
- **`Renderer`** writes only the cells that changed.

## Artwork

Artwork bytes never cross the socket. The host saves a PNG to `~/Library/Caches/Harmune/artwork` and sends its path. A path can name a file that doesn't exist yet: the TUI keeps checking, so covers appear as they arrive.

Library covers have private `musicKit://` URLs that can't be downloaded, so the host draws them with SwiftUI's `ArtworkImage` in an invisible window and saves the result.

The TUI then draws the file in the best way the terminal supports:

| Mode | Terminals | How it stays correct |
|---|---|---|
| `kitty` | Kitty, Ghostty | Images are layered above text, and placed and deleted by ID |
| `iterm2` | iTerm2, WezTerm | Images replace cells, so the renderer rewrites them when an image goes away |
| `sixel` | foot, mlterm, contour | As `iterm2` |
| `halfblock` | everything else, and tmux | Ordinary cells with colors |

## Why there's no sandbox

App Sandbox stays off, because MusicKit playback is reported to fail inside it on macOS. The app uses the hardened runtime and is notarized for distribution.

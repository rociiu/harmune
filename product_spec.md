# Harmune — Product Specification

**Tagline:** Your music. Your terminal.  
**Version:** 1.1 Draft (revised — see docs/SPEC_REVIEW.md)  
**Date:** October 15, 2026  
**Platform:** macOS  
**Language:** Swift 6  
**UI Framework:** SwiftTUI  
**Music Engine:** Apple MusicKit  
**Product Type:** Native, open-source terminal music player  
**Distribution:** GitHub Releases + Homebrew

---

## 1. Product Overview

### 1.1 Vision

**Harmune** is a beautifully designed, keyboard-first Apple Music player built natively for the macOS terminal.

It combines the speed and efficiency of developer tools like Neovim, Lazygit, and Yazi with the visual richness of a modern music player.

Harmune is not simply a terminal interface controlling Apple Music.app. It aims to be an independent music player with its own playback engine, music library interface, and persistent playback service.

The experience should feel natural to developers who spend much of their day inside a terminal.

### 1.2 Product Philosophy

Harmune is built around five principles.

**1. Keyboard First**

Every feature must be accessible without using a mouse.

Vim-inspired navigation is the default interaction model, but users should not need to understand Vim to use Harmune.

**2. Beautiful by Default**

A terminal interface does not have to be visually primitive.

Harmune should feature real album artwork, carefully selected colors, clean typography, elegant layouts, and subtle animations.

**3. Native and Independent**

Harmune should play Apple Music through MusicKit without requiring Music.app, Chromium, or another third-party music player to run.

**4. Fast and Lightweight**

The interface should launch quickly, react instantly to keyboard input, and avoid unnecessary rendering or network activity.

**5. Music Should Keep Playing**

Closing the terminal should not stop playback.

Harmune uses a lightweight native macOS playback host that operates independently of the terminal interface.

### 1.3 Product Positioning

> Harmune is a beautifully crafted, keyboard-first music player for developers who live in the terminal.

Unlike traditional terminal music players, Harmune emphasizes both usability and visual experience.

Its defining combination is:

- Native Apple Music playback.
- Vim-inspired keyboard navigation.
- Rich terminal artwork and animations.
- Independent background playback.
- Powerful command-line integration.
- A polished, customizable interface.

### 1.4 Target Users

**Primary audience:** Developers and terminal enthusiasts using macOS.

Typical characteristics:

- Regularly use Terminal, Ghostty, Kitty, or iTerm2.
- Prefer keyboard navigation.
- Enjoy applications such as Neovim, Lazygit, and Yazi.
- Subscribe to Apple Music.
- Want to control music without switching to a desktop application.
- Appreciate aesthetically polished developer tools.

**Secondary audience:** Power users who prefer lightweight, distraction-free music applications.

---

# 2. Platform and Technical Requirements

## 2.1 Supported Platform

| Requirement | Specification |
|---|---|
| Operating system | macOS 15+ |
| Architecture | Apple Silicon; Intel if supported by dependencies |
| Programming language | Swift 6 |
| Swift toolchain | Swift 6.2+ / Xcode 26+ (raise only if the UI framework requires it) |
| UI framework | SwiftTUI |
| Music integration | MusicKit for Swift |
| Apple Music subscription | Required for catalog streaming |
| Apple Music.app | Not required |
| Apple Developer account | Required to configure and distribute Harmune's MusicKit-enabled host |
| Internet | Required for streaming and online catalog |
| Terminal graphics | Optional, with graceful fallback |

The minimum deployment target is provisional and must be validated against the selected SwiftTUI release and MusicKit APIs.

SwiftTUI currently supports declarative views, animations, terminal capability detection, Kitty/Sixel images, and terminal-compatible fallback rendering. Its API is still in public beta. [GitHub](https://github.com/SwiftTUI/swift-tui)

> **Revision 1.1 — UI framework risk.** Two unrelated projects are named "SwiftTUI". The image-capable one is beta and was not verified from its own repository. Adopting it is gated on a one-week spike, with these go/no-go criteria:
> - a 3-pane layout
> - resize without artifacts
> - 12 Kitty images in a scrolling grid
> - raw key sequences (`gg`, `5j`, `Ctrl+d`)
> - headless frame snapshots
>
> All image output goes through Harmune's own `TerminalGraphics` module, never through the framework directly. Views are built from a small Harmune component layer, so switching to another framework stays a bounded job.

> **Revision 1.1 — Host signing.** The host is a **non-sandboxed, Developer ID–signed, hardened-runtime, notarized** app whose App ID has the **MusicKit App Service** enabled. MusicKit has no entitlement of its own; whether the app also needs an embedded provisioning profile is being tested in Phase 0. People have reported `ApplicationMusicPlayer` playback failing with permission errors in sandboxed macOS apps. `SystemMusicPlayer` is unavailable on macOS.

## 2.2 Supported Terminals

| Terminal | Priority | Rendering |
|---|---|---|
| Ghostty | P0 | Rich graphics |
| Kitty | P0 | Rich graphics |
| iTerm2 | P1 | Best supported image protocol |
| WezTerm | P1 | Capability-dependent graphics |
| Terminal.app | P1 | ANSI/Unicode fallback |
| VS Code Terminal | P2 | Capability-dependent |
| SSH sessions | P2 | Client capability-dependent |

Harmune must remain usable in terminals that cannot display images.

The selected graphics implementation must negotiate terminal capabilities instead of relying solely on terminal application names.

---

# 3. Core User Experience

## 3.1 Application Launch

Users launch Harmune using:

```bash
harmune
```

On launch, the application:

1. Detects the current terminal capabilities.
2. Checks whether the Harmune playback host is running.
3. Starts the host if necessary.
4. Establishes a local IPC connection.
5. Loads the current playback state.
6. Displays the main interface.

If music is already playing, the interface immediately displays the current track.

If the user has never configured Harmune, the application starts an onboarding flow.

### First Launch

```text
╭─────────────────────────────────────────────────╮
│                                                 │
│   ◈ HARMUNE                                     │
│                                                 │
│   Your music. Your terminal.                    │
│                                                 │
│   Welcome to Harmune.                           │
│                                                 │
│   Connect your Apple Music account to begin.    │
│                                                 │
│   [ Enter ] Connect Apple Music                 │
│                                                 │
│   [ ? ]     Learn keyboard shortcuts            │
│                                                 │
╰─────────────────────────────────────────────────╯
```

The connection action launches the signed macOS host, which handles Apple Music authorization.

Harmune should never ask users to enter their Apple ID password directly into the terminal.

### Authorization States

| State | UI Behavior |
|---|---|
| Not determined | Show Connect Apple Music |
| Authorized | Continue to application |
| Denied | Explain how to grant access |
| Restricted | Explain system restriction |
| No subscription | Explain subscription requirement |
| Network unavailable | Display recoverable connection error |
| MusicKit unavailable | Show diagnostic information |

The application must distinguish Apple Music permission from subscription eligibility.

MusicKit provides both authorization and subscription capability APIs. [Apple Developer](https://developer.apple.com/documentation/musickit)

---

# 4. Information Architecture

## 4.1 Primary Navigation

The sidebar is grouped. It matches the approved design.

```text
Home                 gh
Search               gs
── LIBRARY ──
Songs                gl   (was "Library")
Albums               ga
Artists              gA
Playlists            gp
Favorites            gf   (P1 — hidden until supported)
Recently Played      gr   (P1 — hidden until supported)
──
Queue                gq
Settings             g,
```

| Section | Purpose |
|---|---|
| Home | Personalized listening dashboard |
| Search | Search Apple Music or your library |
| Songs | All saved songs in the library |
| Albums | Saved albums (grid or table) |
| Artists | Saved artists |
| Playlists | User playlists |
| Favorites | Favorited items (P1) |
| Recently Played | Recent containers and tracks (P1) |
| Queue | Manage upcoming playback |
| Settings | Preferences (P1, simple form over `config.toml`) |

Additional views, not in the sidebar:

- Now Playing / Immersive (`gn`, `v`)
- Album Detail
- Artist Detail
- Playlist Detail
- Keyboard Help (`?`)

Sidebar entries for features that aren't implemented yet are hidden. Dead entries never ship.

## 4.2 Main Layout

The interface uses a responsive, three-region layout.

```text
╭────────────────────────────────────────────────────────────────────────╮
│  ◈ harmune                                      ● Playing   ♫ Music    │
├────────────────┬───────────────────────────────────────────────────────┤
│                │                                                       │
│   Home         │  Library / Albums                                     │
│   Search       │                                                       │
│ > Library      │  #   ALBUM                    ARTIST          YEAR    │
│   Albums       │  ─────────────────────────────────────────────────    │
│   Artists      │                                                       │
│   Playlists    │  >   In Rainbows              Radiohead       2007    │
│   Queue        │      Random Access Memories   Daft Punk       2013    │
│                │      Currents                 Tame Impala     2015    │
│                │      Melodrama                Lorde           2017    │
│                │      OK Computer              Radiohead       1997    │
│                │                                                       │
│                │                                                       │
│                │  5 albums                                             │
│                │                                                       │
├────────────────┴───────────────────────────────────────────────────────┤
│                                                                        │
│  [ ARTWORK ]  Reckoner — Radiohead                                    │
│                                                                        │
│               ━━━━━━━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━  02:34 / 04:50     │
│                                                                        │
├────────────────────────────────────────────────────────────────────────┤
│  NORMAL │ LIBRARY                         / Search   : Command   ? Help│
╰────────────────────────────────────────────────────────────────────────╯
```

### Layout Regions

**Header**

Displays application name, connection state, and playback status.

**Sidebar**

Provides navigation between major application sections.

**Content**

Displays albums, songs, artists, playlists, search results, or queue entries.

**Persistent Player**

Shows current artwork, title, artist, playback progress, and compact controls.

**Status Bar**

Displays input mode, active section, command feedback, keyboard hints, and error notifications.

---

# 5. Responsive Terminal Layout

Harmune must dynamically adapt to terminal dimensions.

| Terminal Width | Layout |
|---|---|
| Under 60 columns | Compact single-column |
| 60–89 columns | Main content + compact player |
| 90–119 columns | Sidebar + content |
| 120+ columns | Sidebar + content + optional detail panel |

The terminal dimensions should never cause content to render outside visible bounds.

Height breakpoints:

| Terminal Height | Behavior |
|---|---|
| Under 12 rows | Header hidden; player bar is 1 line |
| 12–19 rows | Player bar is 1 line, no artwork thumbnail |
| 20+ rows | Full 3-row player bar with artwork thumbnail |

At 120+ columns, the **right-hand Now Playing panel** shows:
- current artwork
- title / artist / album (year)
- a favorite indicator
- a mini decorative spectrum
- the tracklist of the **current container** (album or playlist), with the playing track highlighted

It is focusable with `Tab`. It shows the current container, not the queue.

## 5.1 Wide Layout

At sufficient width:

```text
┌────────────┬───────────────────────────┬────────────────────┐
│ Navigation │ Music Library             │ Now Playing        │
│            │                           │                    │
│ Home       │ Albums / Songs            │ Album Artwork      │
│ Search     │                           │                    │
│ Library    │ > Song 1                  │ Track Information  │
│ Queue      │   Song 2                  │                    │
│            │   Song 3                  │ Queue Preview      │
└────────────┴───────────────────────────┴────────────────────┘
│ Persistent Playback Bar                                   │
└───────────────────────────────────────────────────────────┘
```

## 5.2 Compact Layout

For smaller terminals:

```text
╭───────────────────────────────╮
│ ◈ harmune           ♪ Playing │
├───────────────────────────────┤
│ Library / Albums              │
│                               │
│ > In Rainbows                 │
│   Currents                    │
│   Melodrama                   │
│   OK Computer                 │
│                               │
├───────────────────────────────┤
│ ♪ Reckoner — Radiohead        │
│ ━━━━━━━●━━━━━━━━  02:34       │
├───────────────────────────────┤
│ NORMAL  /  :  ?               │
╰───────────────────────────────╯
```

The compact interface prioritizes navigation and music controls.

Artwork and secondary information may be hidden automatically.

---

# 6. Keyboard Interaction System

## 6.1 Design Principles

Harmune uses Vim-inspired navigation, but it is not a Vim emulator.

The interaction system should be predictable, discoverable, and consistent across the application.

Users should be able to navigate without learning complicated commands.

Advanced users can take advantage of motions, command mode, and keyboard sequences.

## 6.2 Input Modes

Three primary modes are supported.

| Mode | Purpose |
|---|---|
| NORMAL | Navigation and music control |
| SEARCH | Enter search queries |
| COMMAND | Execute application commands |

### Normal Mode

Default application mode.

Keyboard shortcuts navigate lists, open views, and control playback.

### Search Mode

Activated using `/`. `F` activates the in-place **filter** variant.

Text input takes priority over navigation bindings.

Pressing `Esc` exits Search mode. `Enter` commits the query and returns focus to the results.

### Key Sequences

- Multi-key sequences (`gg`, `gh`, `dd`) time out after 600 ms (configurable).
- Pending keys are shown in the status bar.
- A count prefix (`5j`) cannot start with `0`.
- Sequences are resolved by one central keymap trie, never per view.

### Command Mode

Activated using `:`.

Provides a command input similar to Vim.

Example:

```text
:play
```

Command mode supports:

- Command completion.
- Command history.
- Argument suggestions.
- Error messages.
- Keyboard navigation.

## 6.3 Global Navigation

| Key | Action |
|---|---|
| `j` | Move down |
| `k` | Move up |
| `h` | Navigate back / parent |
| `l` | Open selected item |
| `Enter` | Open selected item |
| `gg` | Jump to first item |
| `G` | Jump to last item |
| `5j` | Move down five items |
| `Ctrl+d` | Scroll down half page |
| `Ctrl+u` | Scroll up half page |
| `Tab` | Focus next panel |
| `Shift+Tab` | Focus previous panel |
| `Esc` | Close current overlay / go back |
| `/` | Search (scope shown in input, see §8.2) |
| `F` | Filter the current list in place |
| `n` / `N` | Next / previous filter match |
| `H` / `L` | Previous / next tab (e.g. search categories) |
| `o` | Sort / order current list |
| `t` | Toggle grid / table (album views) |
| `:` | Command mode |
| `?` | Keyboard help |
| `q` | Close current view; quit from root |

### Navigation Sequences

Support common Vim-style motions:

```text
gg     First item
G      Last item
10j    Move down 10 entries
5k     Move up 5 entries
```

Sequences must be interpreted centrally rather than separately in every view.

## 6.4 Navigation Shortcuts

| Shortcut | Destination |
|---|---|
| `gh` | Home |
| `gs` | Search |
| `gl` | Songs (library) |
| `ga` | Albums |
| `gA` | Artists |
| `gp` | Playlists |
| `gf` | Favorites (P1) |
| `gr` | Recently Played (P1) |
| `gq` | Queue |
| `gn` | Now Playing |
| `g,` | Settings |

## 6.5 Playback Shortcuts

| Key | Action |
|---|---|
| `Space` | Play / Pause |
| `>` | Next track |
| `<` | Previous track |
| `]` | Seek forward 5 seconds |
| `[` | Seek backward 5 seconds |
| `s` | Toggle shuffle |
| `r` | Cycle repeat mode |
| `f` | Toggle favorite, when supported |
| `v` | Toggle immersive Now Playing |

Shortcuts apply only when they do not conflict with an active text-entry context.

**Volume is not supported in v1.** `ApplicationMusicPlayer` exposes no volume API on macOS. Controlling system output volume would affect every app. `+`/`-` are intentionally unbound. An opt-in, clearly labelled "System volume" control is P2.

`f` is only bound when the host advertises the `favorites` capability.

## 6.6 Queue Shortcuts

| Key | Action |
|---|---|
| `a` | Add selection to queue |
| `p` | Play selected item next |
| `dd` | Remove selected queue entry |
| `J` | Move queue entry down |
| `K` | Move queue entry up |
| `D` | Clear upcoming queue (with confirmation) |
| `Enter` | Play selected entry |

`q` never clears the queue. It always means close/quit.

Queue removal and reordering require backend capability validation. Unsupported actions must be visibly disabled, rather than silently modifying an incorrect queue.

Destructive actions must not delete songs from the user's Apple Music library.

---

# 7. Command System

Harmune should provide a powerful command interface for developers.

Press `:` to enter command mode.

## 7.1 Playback Commands

```vim
:play
:pause
:toggle
:next
:previous
:seek 120
:shuffle on
:shuffle off
:repeat off
:repeat one
:repeat all
```

## 7.2 Navigation Commands

```vim
:home
:search radiohead
:library
:albums
:artists
:playlists
:queue
:nowplaying
```

## 7.3 Appearance Commands

`:theme` with no argument opens a picker. Moving the selection **previews** the theme live. `Enter` applies and persists it. `Esc` reverts.

```vim
:theme harmune-midnight
:theme tokyo-night
:theme catppuccin-mocha
:theme gruvbox-dark
:theme nord
:theme dracula
:theme mono

:artwork on
:artwork off

:visualizer on
:visualizer off

:immersive
```

## 7.4 Application Commands

```vim
:help
:settings
:reload
:quit            " alias :q — closes TUI, music keeps playing
:queue clear     " asks for confirmation
:filter <text>
:service stop    " stops the host, asks for confirmation if playing
```

A separate service-control command should be available to deliberately stop the playback host.

Closing the TUI with `:quit` must not stop the music.

---

# 8. Feature Specifications

## 8.1 Home

**Priority: P1**

Home provides quick access to a user's music.

### Components

**Continue Listening**

Displays the most recent album or playlist when available.

**Recently Played**

Shows recent tracks or albums supported by the authorized Apple Music APIs.

**Favorite Albums**

Displays favorited or frequently accessed albums.

**Recommendations**

Displays personalized music recommendations when available.

**Quick Actions**

Provides shortcuts to Search, Library, Playlists, and Queue.

### Empty State

For users with limited history:

```text
Welcome to Harmune

Your music lives here.

Press / to discover something new.
```

Home should not depend on the recommendation service being available.

### Layout (revised 1.1)

Home is a vertical list of **horizontal artwork rows**:
- "Recently Played"
- "Made For You" (personal recommendations)
- "Favorite Albums"

Keys:
- `j/k` move between rows.
- `h/l` move within a row.
- `Enter` on an item opens it.
- `Enter` on a row header opens "See All".

Rows whose data source fails or is unsupported are omitted, not shown empty.

---

## 8.2 Search

**Priority: P0**

Search allows users to find music in the Apple Music catalog.

### Search Categories

- Songs
- Albums
- Artists
- Playlists

### Behavior

Press `/` in the dedicated Search view to enter a query.

Search requests should:

- Use a short debounce.
- Cancel superseded requests.
- Display loading feedback.
- Support pagination.
- Cache recent results.
- Handle network errors.

Search results should be fully keyboard navigable.

### Example

```text
╭─────────────────────────────────────────────────────╮
│ Search                                              │
│                                                     │
│ / radiohead                                         │
│                                                     │
│ SONGS                                               │
│                                                     │
│ > Reckoner                  Radiohead                │
│   Weird Fishes              Radiohead                │
│   No Surprises              Radiohead                │
│   Karma Police              Radiohead                │
│                                                     │
│ ALBUMS                                              │
│                                                     │
│   In Rainbows                                       │
│   OK Computer                                       │
│   Kid A                                             │
│                                                     │
│ Enter Open   p Play Next   a Queue                  │
╰─────────────────────────────────────────────────────╯
```

### Search Semantics (revised 1.1)

`/` **always opens search input**. The input always shows its scope:

| Invoked from | Default scope |
|---|---|
| Home, Search, Now Playing, Queue | `Apple Music` (catalog) |
| Songs, Albums, Artists, Playlists, Favorites | `Library` |

- `Ctrl+s` inside the input toggles the scope.
- Result categories (`All · Songs · Albums · Artists · Playlists`) are tabs switched with `H` / `L`. `All` shows grouped sections.
- `F` filters the **current list in place** (no network). `n`/`N` cycle matches.
- `:search <query>` = catalog search. `:filter <query>` = in-place filter.

---

## 8.3 Library

**Priority: P0**

Library displays music associated with the user's Apple Music account.

### Features

- Browse saved songs.
- Browse saved albums.
- Browse artists.
- Browse playlists.
- Open album details.
- Open artist details.
- Start playback.
- Add songs to the queue.

### Album Grid

Albums (library and artist detail) render as an **artwork grid** when the terminal supports images and is ≥ 90 columns. Otherwise they render as a table. `t` toggles the mode, and the choice is persisted per view. Grid navigation: `h/j/k/l` moves in 2D.

### Sorting

Sorting is opened with `o`. Initially support:

- Title.
- Artist.
- Recently added, where metadata is available.

Additional sorting options may be introduced later.

### Performance

Large libraries must not block the terminal UI.

Use lazy rendering and paginated MusicKit requests where supported.

---

## 8.4 Album Detail

**Priority: P0**

The album detail screen combines artwork with track information.

### Layout

```text
╭────────────────────────────────────────────────────────────╮
│ Library / Albums / In Rainbows                             │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  ┌──────────────────┐   IN RAINBOWS                        │
│  │                  │                                      │
│  │   ALBUM ART      │   Radiohead                          │
│  │                  │   2007 · Alternative                 │
│  │                  │                                      │
│  └──────────────────┘   [Enter] Play Album                 │
│                                                            │
│  #    TITLE                                  DURATION       │
│  ─────────────────────────────────────────────────────     │
│  01   15 Step                                  3:57        │
│  02   Bodysnatchers                            4:02        │
│  03   Nude                                     4:15        │
│  04 > Weird Fishes / Arpeggi                   5:18        │
│  05   All I Need                               3:48        │
│  06   Faust Arp                                2:09        │
│  07   Reckoner                                 4:50        │
│                                                            │
│  j/k Navigate   Enter Play   p Next   a Queue             │
╰────────────────────────────────────────────────────────────╯
```

### Features

- Large album artwork.
- Album metadata.
- Track list.
- Play album.
- Play selected track.
- Add tracks to queue.
- Favorite album when supported.

---

## 8.5 Playlists

**Priority: P1**

Users can browse and play their Apple Music playlists.

### MVP Features

- List user playlists.
- Open playlist.
- Browse songs.
- Play selected song.
- Play entire playlist.
- Add playlist songs to the queue.

### Future Features

- Create playlists.
- Rename playlists.
- Add/remove songs.
- Reorder playlist tracks.

Playlist modification requires careful handling to avoid accidental changes to user data.

---

## 8.6 Playback Queue

**Priority: P0 for viewing and insertion; P1 for editing**

The queue screen displays upcoming music.

### Features

- Show current track.
- Show upcoming tracks.
- Play selected entry.
- Add a track to the end.
- Play a track next.
- Remove an entry, if supported.
- Reorder entries, if supported.
- Display queue position.

### Queue Ownership

The playback host owns the authoritative queue.

The TUI must never assume a queue operation succeeded until the backend confirms it.

### Queue State

Queue updates must broadcast to every connected Harmune client.

---

# 9. Now Playing Experience

## 9.1 Compact Player

**Priority: P0**

The compact player remains visible throughout normal navigation.

### Required Information

- Current artwork.
- Song title.
- Artist.
- Playback status.
- Progress.
- Track duration.
- Shuffle/repeat indicators when space allows.

Progress should update visually without continuously requesting state from MusicKit.

## 9.2 Immersive Now Playing

**Priority: P1**

This is Harmune's signature visual experience.

Press:

```text
v
```

to enter Immersive Mode.

### Layout

```text
╭───────────────────────────────────────────────────────────╮
│  ◈ harmune                                  ♪ NOW PLAYING  │
│                                                           │
│                    ┌─────────────────┐                    │
│                    │                 │                    │
│                    │                 │                    │
│                    │    ALBUM ART    │                    │
│                    │                 │                    │
│                    │                 │                    │
│                    └─────────────────┘                    │
│                                                           │
│                         RECKONER                          │
│                         Radiohead                         │
│                                                           │
│                 ━━━━━━━━━━●━━━━━━━━━━━━                  │
│                 02:34             04:50                   │
│                                                           │
│                    ▂▄▆▃▇▅▄▂▅▇▆▃▂▄                         │
│                                                           │
│                  ◀◀       Ⅱ       ▶▶                      │
│                                                           │
│  NORMAL      v Exit      Space Pause      ? Help          │
╰───────────────────────────────────────────────────────────╯
```

### Visual Features

**Large Artwork**

Display high-quality album artwork using the best supported terminal graphics protocol.

**Dynamic Color Theme**

Extract representative colors from the album artwork and apply them selectively to decorative elements.

**Background Atmosphere**

Optionally display a darkened and blurred version of the artwork behind the interface.

**Visualizer**

Show animated decorative spectrum-style bars.

**Playback Animation**

Animate progress smoothly while music is playing.

**Track Transitions**

Use subtle transitions between tracks, respecting terminal capabilities.

### Important Limitation

MusicKit does not expose unrestricted decoded Apple Music audio for FFT analysis.

The initial visualizer is therefore **decorative rather than genuinely audio-reactive**.

A future real-audio visualizer would require a separate, permission-aware audio-capture implementation.

---

# 10. Visual Design System

## 10.1 Design Direction

Harmune should look like a refined modern developer tool, not a traditional text-heavy music player.

Visual inspiration:

- Neovim.
- Lazygit.
- Yazi.
- Ghostty.
- Catppuccin.
- Modern minimalist music interfaces.

The design should be visually appealing without sacrificing readability.

## 10.2 Default Theme

**Theme name:** Harmune Midnight

### Color Palette

| Token | Color | Usage |
|---|---|---|
| Background | `#101018` | Primary background |
| Surface | `#181824` | Panels |
| Elevated | `#222235` | Selected sections |
| Primary Text | `#EAEAF2` | Song titles |
| Secondary Text | `#A1A1B5` | Artist, metadata |
| Muted | `#69697D` | Inactive text |
| Accent | `#C6A5FF` | Active selection |
| Accent Pink | `#F3A6C8` | Secondary accents |
| Accent Blue | `#94BFFF` | Supporting accents |
| Success | `#A6E3A1` | Connected/playing |
| Warning | `#F9D58B` | Warnings |
| Error | `#F38BA8` | Failures |
| Border | `#343446` | Panel boundaries |

### Color Rules

- Avoid excessively saturated backgrounds.
- Use bright colors primarily for active elements.
- Album artwork should be the main source of visual richness.
- Active panels must remain distinguishable.
- Text contrast must take priority over decorative effects.

## 10.3 Additional Themes

**Priority: P1**

Initial theme presets:

1. Harmune Midnight (default).
2. Tokyo Night.
3. Catppuccin Mocha.
4. Gruvbox Dark.
5. Nord.
6. Dracula.
7. Mono (also used automatically when `NO_COLOR` is set).

Solarized is P2.

Custom themes should be supported through configuration.

## 10.4 Typography

Use the terminal's configured monospace font.

Harmune must not require users to install a custom font.

Nerd Fonts may improve icon appearance but must not be mandatory.

Fallback glyphs must be available for unsupported characters.

## 10.5 Borders and Spacing

Use Unicode box-drawing characters where supported.

Recommended characteristics:

- Minimal separators.
- Consistent internal padding.
- One clear active panel.
- Subtle selection highlights.
- Limited visual noise.
- No unnecessary borders around every component.

## 10.6 Artwork Rendering

Rendering priority:

1. Kitty Graphics Protocol. Prefer **Unicode placeholders** (`U+10EEEE`) so images occupy normal cells, survive diff-based redraws and scrolling, and work through tmux. Use direct placement where placeholders are unsupported.
2. iTerm2 inline images (OSC 1337), for iTerm2 and WezTerm.
3. Sixel, when supported.
4. Half-block (`▀`) approximation. Truecolor when `COLORTERM=truecolor`, otherwise quantized to 256 colors.
5. Unicode or ASCII placeholder.

If image rendering fails, Harmune must continue functioning.

### Artwork Pipeline

- The **host** resolves and fetches artwork bytes. Library items may return `musickit://` URLs that only MusicKit can resolve. It writes PNGs to `~/Library/Caches/Harmune/artwork/<id>-<px>.png`, and IPC carries the path, never the bytes.
- The TUI transmits each image to the terminal **once per image ID** and re-places it cheaply. Off-screen images are evicted with an LRU.
- File transmission (`t=f`) only for local sessions. Direct transmission over SSH.
- At most 4 concurrent fetch/decode jobs. Visible cells first.
- The immersive blurred background requires negative z-index images *and* default-background cells. It is P2 and limited to Kitty/Ghostty.

A custom graphics layer may be required for background image layering, image caching, and reliable cleanup when views change.

---

# 11. Terminal Animation System

## 11.1 Goals

Animations should make Harmune feel alive without reducing performance.

### Supported Effects

| Effect | Priority |
|---|---|
| Playback progress | P0 |
| Loading indicator | P0 |
| Active song indicator | P0 |
| Subtle selection changes | P1 |
| Decorative spectrum | P1 |
| Album artwork transitions | P1 |
| Artwork-derived background | P2 |
| Immersive ambient effects | P2 |

## 11.2 Animation Principles

- Avoid redrawing the entire screen unnecessarily.
- Respect terminal capabilities.
- Stop animations when playback is paused where appropriate.
- Reduce rendering frequency when the terminal is inactive.
- Provide a reduced-motion setting.
- Never sacrifice keyboard responsiveness for visual effects.

The terminal should not continuously download or retransmit unchanged artwork.

---

# 12. System Architecture

## 12.1 Recommended Architecture

Harmune consists of two primary processes.

```text
┌────────────────────────────────────────────────────┐
│                   Harmune TUI                      │
│                                                    │
│  SwiftTUI                                           │
│                                                    │
│  ├── Navigation                                    │
│  ├── Keyboard Engine                               │
│  ├── Search UI                                     │
│  ├── Library UI                                    │
│  ├── Queue UI                                      │
│  ├── Now Playing UI                                │
│  └── Terminal Graphics                             │
│                                                    │
└──────────────────────┬─────────────────────────────┘
                       │
                       │ Unix Domain Socket
                       │
┌──────────────────────▼─────────────────────────────┐
│                  Harmune Host                      │
│                                                    │
│  Native macOS Application                          │
│                                                    │
│  ├── MusicKit Authorization                        │
│  ├── Playback Coordinator                          │
│  ├── ApplicationMusicPlayer                        │
│  ├── Catalog Service                               │
│  ├── Library Service                               │
│  ├── Queue Service                                 │
│  ├── Artwork Cache                                 │
│  └── IPC Server                                    │
│                                                    │
└──────────────────────┬─────────────────────────────┘
                       │
                       │ MusicKit
                       ▼
                Apple Music Service
                       │
                       ▼
                   Audio Output
```

## 12.2 Why Separate Processes?

The playback host must survive TUI termination.

Expected behavior:

```text
harmune
   ↓
Start playing music
   ↓
Close terminal
   ↓
Music continues
   ↓
Open terminal
   ↓
harmune
   ↓
Reconnect to existing playback
```

The host owns playback, authorization, library access, and service state.

The TUI owns rendering, keyboard interaction, and navigation.

## 12.3 Playback Host

The backend runs as a signed macOS application.

### Responsibilities

- MusicKit authorization.
- Subscription capability checks.
- Apple Music playback.
- Queue management.
- Catalog requests.
- Library requests.
- State synchronization.
- Artwork caching.
- IPC communication.

### Application Mode

The host should operate without a visible application window during normal playback.

A lightweight AppKit agent application using `LSUIElement` is the preferred candidate.

For first-run authorization, the host may temporarily need to present a native macOS window.

### Playback Engine

Use:

```swift
ApplicationMusicPlayer.shared
```

Apple documents `ApplicationMusicPlayer` as independent of Music.app playback state. [Apple Developer](https://developer.apple.com/documentation/musickit/applicationmusicplayer)

### Launch and Lifecycle (revised 1.1)

- The TUI/CLI launches the host **through LaunchServices** (`NSWorkspace.openApplication`, `activates = false`), never by spawning the binary directly. A direct spawn would:
  - put the host in the terminal's session (SIGHUP on close)
  - make TCC treat the terminal as the responsible process
- `SMAppService.agent` with launchd socket activation is evaluated in Phase 0 as an alternative.
- **Single instance:** the host takes an exclusive `flock` on `~/Library/Application Support/Harmune/host.lock`.
- **Idle exit:** the host quits after 30 minutes paused with no connected clients (configurable; `0` = never).
- **System integration:** media keys and Control Center Now Playing must work. Verify that `ApplicationMusicPlayer` publishes Now Playing info. If it doesn't, publish via `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`.
- On `:quit`, after restoring the terminal, the TUI prints: `Harmune closed — music still playing (harmune service stop to stop it).`

### Critical Validation Requirement

Before completing the full application, verify:

- Playback works with Music.app completely quit.
- Authorization works in the signed host.
- Audio continues when the host is hidden.
- Closing the TUI does not stop playback.
- Reconnecting restores the correct state.
- Playback behaves correctly when the screen locks.
- The selected host lifecycle is reliable on the minimum supported macOS version.
- Music.app is **not auto-launched** by playback (`pgrep -x Music` stays empty).
- All of the above holds in a **Developer ID–signed, notarized** build, not only a debug build.
- Library-item artwork bytes can be obtained by the host.
- `MusicLibraryRequest`, `MusicRecentlyPlayedRequest` and `MusicPersonalRecommendationsRequest` work on macOS.
- Media keys and Control Center Now Playing work.

**Fallback decision:** if audio cannot render without Music.app, the gate fails. The team must then explicitly choose between pivoting to a Music.app-backed controller and stopping. Do not discover this later.

This independent playback architecture is the product's primary technical requirement and must be proven early.

---

# 13. IPC Protocol

## 13.1 Transport

Use a Unix domain socket for communication between the terminal client and playback host.

Recommended characteristics:

- Local communication only.
- Per-user socket.
- Restrictive filesystem permissions.
- Versioned messages.
- JSON serialization.
- Bidirectional communication.
- Automatic reconnection.

## 13.1a Contract Details (revised 1.1)

- **Framing:** newline-delimited JSON, max frame 1 MiB. Binary data (artwork) never goes over the socket. Cache file paths are sent instead.
- **Socket:** `~/Library/Application Support/Harmune/host.sock`, mode `0600` in a `0700` directory. Fall back to `$TMPDIR/harmune-<uid>.sock` if the path exceeds the 104-byte `sun_path` limit.
- **Peer check:** `getpeereid()`. Reject any other UID.
- **Handshake:** client sends `hello {protocolVersion, client: "tui"|"cli", pid}`. Host replies `welcome {protocolVersion, hostVersion, capabilities: [...]}`. Capabilities are things like `queue.remove`, `queue.move`, `favorites`, `recommendations`, `recentlyPlayed`. The UI disables any feature whose capability is absent.
- **Subscription:** `subscribe {topics}`. One-shot CLI calls skip it.
- **Clock:** playback state carries `position`, `positionTimestamp`, `rate` and `duration`. Clients extrapolate locally. The host re-emits every 5 s while playing and on every seek/state change.
- **Errors:** `{success: false, error: {code, message, recoverable}}`. `code` is one of `notAuthorized`, `noSubscription`, `network`, `unavailable`, `unsupported`, `invalidArgument`, `internal`.
- **Timeouts:** commands time out client-side after 5 s (30 s for search/library pages).

## 13.2 Message Types

Three main message types:

```text
Command
Response
Event
```

### Example Command

```json
{
  "version": 1,
  "id": "123",
  "type": "command",
  "action": "playback.pause",
  "payload": {}
}
```

### Example Response

```json
{
  "version": 1,
  "id": "123",
  "type": "response",
  "success": true
}
```

### Example Playback Event

```json
{
  "version": 1,
  "type": "event",
  "event": "playback.changed",
  "revision": 42,
  "data": {
    "trackID": "12345",
    "title": "Reckoner",
    "artist": "Radiohead",
    "duration": 290,
    "position": 154,
    "positionTimestamp": "2026-10-15T10:21:04.120Z",
    "rate": 1,
    "isPlaying": true,
    "shuffle": false,
    "repeat": "off",
    "artworkPath": "~/Library/Caches/Harmune/artwork/12345-600.png"
  }
}
```

## 13.3 Event Categories

```text
playback.changed
queue.changed
authorization.changed
library.changed
connection.changed
error.occurred
```

The protocol should use command IDs for request/response correlation and revision numbers for state synchronization.

## 13.4 Reconnection

When the terminal reconnects:

1. Establish socket connection.
2. Negotiate protocol version.
3. Retrieve current playback snapshot.
4. Retrieve queue state when required.
5. Subscribe to updates.
6. Resume rendering.

Music should not be interrupted by the reconnection process.

---

# 14. State Management

## 14.1 State Categories

Separate state into three domains.

### Playback State

Owned by the backend.

Contains:

- Current track.
- Playback status.
- Current position.
- Duration.
- Queue.
- Repeat mode.
- Shuffle mode.

### UI State

Owned by the TUI.

Contains:

- Current page.
- Focused panel.
- Selected item.
- Scroll position.
- Active input mode.
- Search query.
- Active overlay.

### Configuration State

Stored locally.

Contains:

- Theme.
- Keybindings.
- Artwork preferences.
- Animation preferences.
- Layout preferences.

## 14.2 Concurrency

Use Swift Concurrency.

Suggested structure:

```text
MusicPlaybackCoordinator
    @MainActor
         │
         ├── MusicKit
         └── Playback State

IPC Server Actor
         │
         ├── Client Sessions
         └── Event Broadcasting

Catalog Service
         │
         ├── Search Requests
         └── Caching

TUI State Controller
         │
         ├── Navigation
         ├── Keyboard Modes
         └── Rendering
```

MusicKit operations must be isolated appropriately to their required actor context.

Network operations and artwork processing must not block terminal input.

---

# 15. Application Structure

Recommended repository layout:

```text
Harmune/
│
├── README.md
├── LICENSE
├── Package.swift
├── Package.resolved
│
├── Apps/
│   └── HarmuneHost/
│       ├── HarmuneHost.xcodeproj
│       ├── Info.plist
│       └── HarmuneHostApp.swift
│
├── Sources/
│   │
│   ├── HarmuneCore/
│   │   ├── Models/
│   │   ├── Protocols/
│   │   ├── IPC/
│   │   └── Errors/
│   │
│   ├── HarmuneMusic/
│   │   ├── Authorization/
│   │   ├── Playback/
│   │   ├── Catalog/
│   │   ├── Library/
│   │   ├── Queue/
│   │   └── Artwork/
│   │
│   ├── HarmuneTerminal/
│   │   ├── App/
│   │   ├── Views/
│   │   │   ├── Home/
│   │   │   ├── Search/
│   │   │   ├── Library/
│   │   │   ├── Albums/
│   │   │   ├── Artists/
│   │   │   ├── Playlists/
│   │   │   ├── Queue/
│   │   │   └── NowPlaying/
│   │   │
│   │   ├── Components/
│   │   ├── Navigation/
│   │   ├── Keybindings/
│   │   ├── Themes/
│   │   ├── Graphics/
│   │   └── IPC/
│   │
│   └── HarmuneCLI/
│       ├── Commands/
│       └── Main.swift
│
├── Tests/
│   ├── CoreTests/
│   ├── MusicTests/
│   ├── IPCTests/
│   ├── KeyboardTests/
│   └── UITests/
│
├── Resources/
│   ├── Themes/
│   ├── Artwork/
│   └── DemoData/        # fixtures for DemoBackend (`harmune --demo`)
│
├── Scripts/
│   ├── build.sh
│   ├── sign.sh
│   └── package.sh
│
└── Docs/
    ├── ARCHITECTURE.md
    ├── DESIGN.md
    ├── KEYBINDINGS.md
    └── DEVELOPMENT.md
```

All packages should share common domain models without introducing circular dependencies.

### Contributor Mode (revised 1.1)

`HarmuneCore` defines a `MusicBackend` protocol with two implementations:

- `MusicKitBackend`, inside the host. It needs an Apple Developer account, a MusicKit-enabled App ID and a subscription.
- `DemoBackend`, which runs in-process. It uses fixture data, a simulated clock and bundled placeholder artwork.

`harmune --demo` runs the full TUI with no host and no Apple account. CI and UI snapshot tests use `DemoBackend`. Building your own host uses a git-ignored `Config/Local.xcconfig` (Team ID, bundle ID).

---

# 16. Command-Line Interface

Harmune should support both interactive and noninteractive operation.

## 16.1 Interactive Mode

```bash
harmune
```

Starts the full TUI.

## 16.2 Playback Commands

```bash
harmune play
harmune pause
harmune toggle
harmune next
harmune previous
harmune status
```

## 16.3 Search

```bash
harmune search "Radiohead"
```

Displays terminal-friendly search results.

The initial CLI search may be read-only. Starting playback by ID can be added after catalog and queue operations are stable.

## 16.4 Service Management

```bash
harmune service status
harmune service start
harmune service stop
```

Service stop should explicitly warn if it will interrupt playback.

## 16.5 Machine-Readable Output

**Priority: P1**

Support:

```bash
harmune status --json
```

Example:

```json
{
  "playing": true,
  "track": "Reckoner",
  "artist": "Radiohead",
  "position": 154
}
```

This makes Harmune useful for shell scripts, developer automation, and custom desktop integrations.

---

# 17. Configuration

## 17.1 Configuration File

Use:

```text
~/.config/harmune/config.toml
```

The format should support readable, manually editable configuration.

## 17.2 Example

```toml
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
"gs" = "search"
"gq" = "queue"
"gn" = "now_playing"
```

Configuration loading must validate unknown or conflicting keybindings.

Invalid settings should produce a useful warning and fall back to safe defaults.

---

# 18. Performance Requirements

The following are engineering targets, not guaranteed MusicKit or network latencies.

| Metric | Target |
|---|---|
| TUI startup with running host | Under 300 ms to first frame |
| TUI startup with cold host | Under 2 s to first frame (skeleton UI while waiting) |
| Local navigation response | Under 50 ms |
| Local playback command acknowledgment | Under 150 ms |
| Search input debounce | 300 ms |
| Default decorative animation | Up to 20 FPS |
| Idle terminal rendering | Near-zero unnecessary updates |
| Artwork loading | Asynchronous |
| Memory use | Minimize unnecessary copies and cache growth |
| Terminal resize | No broken layout or stale artwork |

Actual playback start times depend on network conditions and MusicKit.

### Performance Principles

- Never block keyboard input while searching.
- Avoid loading an entire music library at once.
- Cache album artwork.
- Use incremental rendering.
- Suspend invisible animations.
- Limit concurrent artwork downloads.
- Prevent unbounded memory growth.

---

# 19. Privacy and Security

## 19.1 Privacy Principles

Harmune should operate locally wherever possible.

The application should not require:

- A Harmune account.
- A proprietary backend server.
- User registration.
- Analytics tracking.
- Third-party authentication.

Apple Music authorization is handled by MusicKit.

MusicKit automatically manages the relevant Apple Music tokens for native Apple-platform integrations. [Apple Developer](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit)

## 19.2 Data Storage

Store only data necessary for operation:

- User preferences.
- Theme configuration.
- Keybindings.
- Cached artwork.
- Non-sensitive music metadata.
- Optional local history.

Avoid storing Apple Music credentials or tokens manually.

## 19.3 IPC Security

- Use per-user sockets.
- Restrict filesystem permissions.
- Validate local client identity.
- Limit message sizes.
- Validate command arguments.
- Avoid exposing the service over the network.
- Prevent one local client from corrupting shared playback state.

## 19.4 Diagnostic Logging

Logs should exclude authentication credentials and sensitive tokens.

Diagnostic logging should be disabled or minimal by default.

Users should be able to clear local caches and logs.

---

# 20. Error Handling

Harmune should handle common failures without crashing.

| Scenario | Expected Behavior |
|---|---|
| No Apple Music subscription | Explain requirement |
| Permission denied | Explain recovery steps |
| Network disconnected | Display offline status |
| Song unavailable | Show error and retain usable UI |
| Host disconnected | Attempt bounded reconnection |
| MusicKit playback error | Display actionable message |
| Unsupported terminal graphics | Use fallback rendering |
| Terminal resized | Recalculate layout |
| Invalid config | Warn and use defaults |
| Empty library | Show onboarding-style empty state |

### Error Presentation

Use the status bar for minor errors.

Use a focused modal only when the user must make a decision.

Avoid interrupting music playback because of unrelated UI errors.

---

# 21. Installation and Distribution

## 21.1 Distribution Format

The release should contain:

- Signed macOS playback host.
- Compiled Harmune CLI executable.
- Required resources.
- Default configuration.
- Necessary documentation.

The host should be signed and notarized for direct macOS distribution.

## 21.2 Homebrew

Target installation experience:

```bash
brew install --cask harmune
```

Then:

```bash
harmune
```

This is the planned distribution interface, not a currently published Homebrew package.

Because Harmune contains a signed app bundle and CLI executable, a Homebrew cask may be more appropriate than a simple formula.

## 21.3 GitHub Releases

Publish release artifacts for supported architectures.

Each release should include:

- Version number.
- Changelog.
- Installation instructions.
- Minimum macOS version.
- Checksums.
- Known limitations.

## 21.4 Open Source

Recommended licensing direction: **MIT**, subject to final dependency and asset-license review.

The repository should include:

- README.
- CONTRIBUTING.md.
- Architecture documentation.
- Build instructions.
- Issue templates.
- CI checks.

---

# 22. Testing Strategy

## 22.1 Unit Tests

Test:

- Keyboard sequence parsing.
- Navigation behavior.
- Command parsing.
- Configuration validation.
- Playback state calculations.
- Queue state handling.
- IPC serialization.
- Artwork-cache policies.

## 22.2 Integration Tests

Test:

- Host launch.
- IPC connection.
- Command acknowledgment.
- Event delivery.
- Reconnection.
- Multiple clients.
- Host shutdown.
- Permission errors.

## 22.3 MusicKit Validation

Test on an actual Mac with an active Apple Music subscription.

Required scenarios:

1. Music.app completely quit.
2. Harmune authorization requested.
3. Catalog search succeeds.
4. Track playback starts.
5. Pause and resume work.
6. Next/previous track work.
7. Playback continues when TUI closes.
8. Playback continues while host is hidden.
9. Reconnection restores playback state.
10. Playback survives display lock when supported by the validated host configuration.

## 22.4 Terminal Compatibility

Test:

- Ghostty.
- Kitty.
- iTerm2.
- Terminal.app.
- Narrow and wide terminals.
- Terminals without image support.
- Terminal resize.
- Truecolor and reduced-color environments.
- Reduced-motion mode.
- Unsupported glyphs.

Automated UI snapshot tests should verify layout consistency.

SwiftTUI supports rendering terminal frames for testing without requiring an attached terminal. [GitHub](https://github.com/SwiftTUI/swift-tui)

---

# 23. Development Roadmap

## Phase 0 — Technical Feasibility

**Goal:** Prove the independent Apple Music playback architecture.

### Deliverables

- Signed macOS host prototype.
- MusicKit authorization.
- Subscription validation.
- Catalog search.
- Independent playback.
- Background/hidden playback testing.
- Terminal-to-host communication prototype.
- Minimal CLI: `harmune play <catalog-id>|pause|next|status`. This is the exit test.
- UI framework spike (go/no-go, see §2.1).
- Library-artwork, recently-played and recommendations API probes on macOS.

### Exit Criteria

A minimal terminal command can start Apple Music playback through the Harmune host while Music.app is not running.

Closing the terminal does not stop playback.

**This is a blocking milestone.** If it fails, the architecture must be revised before committing to the complete product.

---

## Phase 1 — Functional MVP

**Goal:** Deliver a usable keyboard-driven Apple Music player.

### Features

- `DemoBackend` and headless snapshot-test harness (first).
- SwiftTUI application.
- Main responsive layout.
- Minimal `config.toml` (theme, artwork, motion).
- Keyboard navigation.
- Search.
- Library browsing.
- Album detail.
- Playback controls.
- Basic queue display and insertion.
- Compact now-playing bar.
- Terminal artwork.
- IPC state synchronization.
- Error handling.

### Exit Criteria

A user can launch Harmune, search for an album, play it, navigate the library, and control playback entirely through the keyboard.

---

## Phase 2 — Visual Experience

**Goal:** Make Harmune visually distinctive.

### Features

- Harmune Midnight theme.
- High-quality Kitty artwork.
- Artwork color extraction.
- Immersive Now Playing.
- Animated progress.
- Decorative spectrum.
- Improved transitions.
- Additional themes.
- Graceful rendering fallback.
- Basic `:` command mode (`:q`, `:theme` picker with live preview, playback verbs).

### Exit Criteria

The core interface closely matches the approved product design in Ghostty, while remaining usable in a basic terminal.

---

## Phase 3 — Developer Experience

**Goal:** Make Harmune feel like a mature developer tool.

### Features

- Command mode.
- Advanced Vim motions.
- Custom keybindings.
- CLI subcommands.
- JSON output.
- Command completion.
- Configuration file.
- Multiple TUI clients.
- Robust service management.

### Exit Criteria

Users can control Harmune without opening its full TUI, and keyboard interaction remains consistent across all views.

---

## Phase 4 — Release

**Goal:** Public open-source release.

### Deliverables

- Signed application.
- Notarized release package.
- Homebrew cask.
- GitHub Actions CI.
- Automated tests.
- Documentation.
- Screenshots.
- Demo video.
- GitHub release.

### Exit Criteria

A new user can install Harmune, authorize Apple Music, and begin playback without compiling source code.

---

# 24. MVP Scope

To prevent unnecessary complexity, the initial release should focus on the following.

## Must Have — P0

- Independent MusicKit playback.
- Signed macOS host.
- TUI-to-host IPC.
- MusicKit authorization.
- Apple Music search.
- Library browsing.
- Album detail.
- Playback controls.
- Basic queue.
- Now-playing information.
- Vim-style navigation.
- Responsive layout.
- Real album artwork.
- Default theme.
- Basic configuration.
- Error handling.

## Should Have — P1

- Immersive Now Playing.
- Playlist browsing.
- Favorites.
- Recently Played.
- Dynamic artwork colors.
- Multiple themes.
- Decorative visualizer.
- Advanced command mode.
- Queue editing, subject to API support.
- CLI scripting.
- Configurable keybindings.

## Future — P2

- Real audio-reactive visualizer.
- Synchronized lyrics.
- Advanced personalized recommendations.
- Smart playlists.
- Multiple music providers.
- Plugin system.
- Native menu bar companion.
- Optional remote control.
- Advanced animation themes.

---

# 25. Non-Goals

The initial release will not attempt to:

- Replace the Apple Music streaming service.
- Download or decrypt Apple Music audio.
- Implement an independent DRM system.
- Support Spotify.
- Support Windows or Linux playback.
- Implement music purchasing.
- Provide social networking features.
- Build a cloud account system.
- Require a browser-based player.
- Depend on Music.app or AppleScript.
- Provide an unrestricted system-audio capture engine.

These exclusions keep the initial implementation focused.

---

# 26. Product Success Criteria

Harmune succeeds when it provides an experience that developers genuinely prefer over switching to a conventional music application.

### Functional Success

- Music.app is not required.
- Playback continues after closing the terminal.
- Search and playback work reliably.
- The user's library is accessible.
- Queue and playback state remain synchronized.
- Core workflows require no mouse.

### Experience Success

- Navigation feels immediate.
- The interface remains readable at different terminal sizes.
- Artwork renders correctly in compatible terminals.
- Keyboard shortcuts are predictable.
- Visual effects enhance rather than obstruct usability.
- First-time setup is understandable.

### Engineering Success

- Clear separation between UI and backend.
- Testable components.
- Stable IPC protocol.
- Safe local state management.
- Low idle resource usage.
- Reproducible signed builds.
- Straightforward Homebrew installation.

---

# 27. Competitive Differentiation

Harmune enters an existing category with projects such as Yatoro, MusicTUI, and Muse.

Its differentiation should come from execution rather than merely supporting Apple Music in a terminal.

| Capability | Harmune Direction |
|---|---|
| Independent MusicKit playback | Core requirement |
| Music.app independence | Core requirement |
| Persistent playback host | Core differentiator |
| Swift-native architecture | Core architecture |
| Consistent keyboard navigation | Core experience |
| High-quality terminal artwork | Core visual feature |
| Immersive Now Playing | Signature visual feature |
| Modern themes | Core customization |
| Terminal capability fallback | Core compatibility |
| Shell scripting | Developer-focused capability |
| Multiple frontend sessions | Architectural advantage |

The project should prioritize polish, reliability, and visual quality over accumulating features.

---

# 28. Reference Documentation

### Apple

- [MusicKit Framework](https://developer.apple.com/documentation/musickit)
- [ApplicationMusicPlayer](https://developer.apple.com/documentation/musickit/applicationmusicplayer)
- [MusicAuthorization](https://developer.apple.com/documentation/musickit/musicauthorization)
- [Apple MusicKit](https://developer.apple.com/musickit/)
- [Apple ServiceManagement](https://developer.apple.com/documentation/servicemanagement)

### Terminal UI

- [SwiftTUI](https://github.com/SwiftTUI/swift-tui)
- [SwiftTUI Documentation](https://swifttui.sh/)
- [Kitty Graphics Protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
- [Ghostty](https://ghostty.org/)

### Existing Projects

- [Yatoro](https://github.com/jayadamsmorgan/Yatoro)
- [MusicTUI](https://github.com/anthonymaley/MusicTUI)
- [Muse](https://github.com/jrf/muse)

---

# 29. Final Product Definition

## Harmune

**Your music. Your terminal.**

Harmune is a native macOS terminal music player that brings Apple Music into the developer's workspace.

It combines independent MusicKit playback, keyboard-first navigation, beautiful album artwork, a customizable terminal interface, and persistent background playback.

The product should feel as natural to operate as Neovim, as polished as a modern music application, and as lightweight as a good command-line tool.

### Release 1.0 Definition

A successful Harmune 1.0 allows users to:

1. Install the application using Homebrew.
2. Authorize their Apple Music account.
3. Browse and search their music.
4. Play music without opening Music.app.
5. Navigate entirely using the keyboard.
6. Enjoy real album artwork and a polished terminal interface.
7. Close the terminal without interrupting playback.
8. Reopen Harmune and immediately reconnect to the current song.

**The defining experience: open your terminal, type `harmune`, and your music is right where you work.**

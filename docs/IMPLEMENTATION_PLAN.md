# Harmune — Implementation Plan

**Based on:** `product_spec.md` v1.1 (see `docs/SPEC_REVIEW.md` for what changed and why)
**Team assumption:** 1–2 engineers. Estimates are for one experienced Swift engineer, in focused weeks.
**Total to 1.0:** ~20–24 weeks. Phase 0 is a hard go/no-go gate.

> **What changed during implementation.** The checkboxes below are the original plan and aren't kept up to date; see the README for status.
> - **UI:** a small custom renderer, not SwiftTUI, and no third-party dependencies (no ArgumentParser or TOMLKit).
> - **Order:** the UI was built on the demo backend before Phase 0, so the gate is still open. See `docs/PHASE0_SETUP.md`.
> - **Host:** an SPM executable that `Scripts/build-host.sh` assembles and signs into `build/Harmune.app`, not an Xcode project. This keeps signing explicit, including whether a profile is embedded.
> - **MusicKit access:** comes from the App Service on the App ID. The `com.apple.developer.musickit` entitlement in §0.1 and §1 doesn't exist.

---

## 0. Guiding decisions

| Decision | Choice | Why |
|---|---|---|
| Processes | `harmune` (CLI + TUI, one executable) and `Harmune.app` (LSUIElement host) | One user-facing binary. Host survives the terminal closing. |
| Host launch | LaunchServices (`NSWorkspace.openApplication`, background) | Avoids SIGHUP and the TCC attributing permissions to the terminal. |
| Signing | Developer ID, hardened runtime, **not sandboxed**, notarized | MusicKit playback is reported to fail in sandboxed macOS apps. |
| IPC | Unix socket, NDJSON, versioned, capability-negotiated | Simple, debuggable (`nc -U`), scriptable. |
| Backend seam | `MusicBackend` protocol: `MusicKitBackend` (host) and `DemoBackend` (in-process) | Contributors and CI run without Apple accounts. |
| UI | SwiftTUI **behind a Harmune component layer**. Images are owned by Harmune's `TerminalGraphics` | The framework is beta. Image placement is too critical to delegate. |
| Images | Kitty Unicode placeholders → Kitty direct → iTerm2 OSC 1337 → Sixel → half-block | Placeholders survive diffing, scrolling and tmux. |
| Config | TOML at `~/.config/harmune/config.toml` | Matches the spec. |
| Min OS / toolchain | macOS 15, Swift 6.2+, Xcode 26+ | Raise only if a dependency requires it. |

---

## 1. Repository and module layout

```text
HarmuneApp/
├── Package.swift                     # SPM: Core, IPC, Music, Terminal, CLI, Demo, tests
├── Apps/HarmuneHost/                 # Xcode project (app bundle, entitlements, signing)
│   ├── HarmuneHost.xcodeproj
│   ├── HarmuneHost/HostApp.swift     # NSApplication, LSUIElement, auth window
│   ├── HarmuneHost.entitlements      # com.apple.developer.musickit, hardened runtime
│   └── Config/{Base,Release}.xcconfig + Local.xcconfig (git-ignored: TEAM_ID, BUNDLE_ID)
├── Sources/
│   ├── HarmuneCore/        # Models, MusicBackend protocol, errors, Capabilities. No deps.
│   ├── HarmuneIPC/         # Wire types, NDJSON codec, socket server/client, handshake
│   ├── HarmuneMusic/       # MusicKitBackend, PlaybackCoordinator, catalog, library, artwork (host only)
│   ├── HarmuneDemo/        # DemoBackend + fixtures + simulated clock
│   ├── HarmuneTerminal/    # TUI: App, Store, Keymap, Views, Components, Themes, Graphics
│   │   └── Graphics/       # TerminalGraphics: capability probe, kitty/iterm/sixel/halfblock
│   ├── HarmuneConfig/      # TOML load/validate/merge, keybinding parse
│   └── harmune/            # main.swift: ArgumentParser root → TUI or subcommands
├── Tests/
│   ├── CoreTests  IPCTests  KeymapTests  ConfigTests  GraphicsTests
│   ├── SnapshotTests       # headless frames over DemoBackend, per breakpoint
│   └── HostIntegrationTests (manual/opt-in; needs signed host + subscription)
├── Resources/{Themes,DemoData,Artwork}
├── Scripts/{build.sh, sign.sh, notarize.sh, package.sh}
└── Docs/{ARCHITECTURE, DESIGN, KEYBINDINGS, DEVELOPMENT, PROTOCOL}.md
```

**Dependency rule** (enforced by SPM targets):
- `Core` ← `IPC` ← (`Music`, `Terminal`, `CLI`)
- `Demo` depends only on `Core`
- `Terminal` never imports `MusicKit`
- `Music` is linked only by the host app

**Third-party dependencies** (keep minimal):
- `swift-argument-parser`
- `TOMLKit` (or equivalent)
- the UI framework
- `swift-snapshot-testing` (test only)

---

## 2. Core domain model (HarmuneCore)

```swift
public struct TrackID: Hashable, Codable, Sendable { public let raw: String; public let source: Source } // .catalog | .library
public struct Track: Codable, Sendable { id, title, artist, album, albumID?, duration: TimeInterval, trackNumber?, artwork: ArtworkRef?, isPlayable }
public struct Album, Artist, Playlist  // similar; Album has year, genre, trackCount
public struct ArtworkRef: Codable, Sendable { let key: String; let averageColor: RGB?; let path: String? } // path filled by host cache

public enum RepeatMode: String, Codable { case off, one, all }
public struct PlaybackState: Codable, Sendable, Equatable {
  var track: Track?; var isPlaying: Bool; var position: TimeInterval
  var positionTimestamp: Date; var rate: Double; var shuffle: Bool; var repeat: RepeatMode
  var container: ContainerRef?   // album/playlist the queue came from (for right panel)
  var revision: UInt64
  func position(at now: Date) -> TimeInterval  // extrapolation; clamped to [0, duration]
}
public struct QueueState: Codable, Sendable { var entries: [QueueEntry]; var currentIndex: Int?; var revision: UInt64 }
public struct Capabilities: OptionSet, Codable { queueRemove, queueMove, favorites, recommendations, recentlyPlayed, librarySearch }
public enum AuthState: Codable { notDetermined, authorized, denied, restricted, noSubscription, unavailable(reason) }

public protocol MusicBackend: Sendable {
  var capabilities: Capabilities { get async }
  func authState() async -> AuthState
  func requestAuthorization() async -> AuthState
  // playback
  func play(_ request: PlayRequest) async throws   // .item(id) | .container(id, startAt) | .resume
  func pause() async throws; func next() async throws; func previous() async throws
  func seek(to: TimeInterval) async throws; func setShuffle(Bool) async throws; func setRepeat(RepeatMode) async throws
  // queue
  func enqueue(_ ids: [TrackID], position: EnqueuePosition) async throws  // .next | .last
  func removeFromQueue(entryID: String) async throws; func moveQueueEntry(entryID: String, to: Int) async throws
  // browse
  func search(_ q: SearchQuery) async throws -> SearchPage   // scope, types, offset, limit
  func library(_ kind: LibraryKind, sort: SortKey, page: PageToken?) async throws -> Page<LibraryItem>
  func album(_ id: AlbumID) async throws -> AlbumDetail
  func artist(_ id: ArtistID) async throws -> ArtistDetail
  func playlist(_ id: PlaylistID) async throws -> PlaylistDetail
  func home() async throws -> HomeSections
  func artwork(_ ref: ArtworkRef, px: Int) async throws -> URL  // local file path
  // state streams
  func playbackUpdates() -> AsyncStream<PlaybackState>
  func queueUpdates() -> AsyncStream<QueueState>
}
```

The TUI talks to a `MusicBackend`. In normal mode that is `RemoteBackend` (an IPC client that implements the same protocol). In `--demo` mode it is `DemoBackend`. **The TUI cannot tell which one it has.**

---

## 3. Phase 0 — Technical feasibility (weeks 1–3) · BLOCKING GATE

**Goal:** prove independent playback, the host lifecycle and the UI framework, before building product.

### 0.1 Apple setup (day 1)
- [ ] Register App ID `com.orinbyte.harmune` with the **MusicKit** App Service. Create a Developer ID Application certificate.
- [ ] Xcode project `HarmuneHost`:
  - macOS 15 target
  - `LSUIElement = YES`
  - `NSAppleMusicUsageDescription`
  - hardened runtime
  - **App Sandbox OFF**
  - MusicKit entitlement
- [ ] `Scripts/sign.sh` + `notarize.sh` using `notarytool` with a keychain profile. Notarize a hello-world build on day 1, so signing problems surface early.

### 0.2 MusicKit probe host (days 2–5)
- [ ] A host app with a temporary debug window. Buttons:
  - Authorize
  - Check subscription (`MusicSubscription.current.canPlayCatalogContent`)
  - Search "Radiohead"
  - Play first song
  - Pause / Next
  - Library albums
  - Recently played
  - Recommendations
  - Fetch library artwork
- [ ] Write a validation matrix to `Docs/PHASE0_RESULTS.md`. Every row has evidence (screenshot or log):

| # | Check | How |
|---|---|---|
| V1 | Audio plays with Music.app quit and **not relaunched** | `pgrep -x Music` before/during/after |
| V2 | Works from a Developer ID–signed + notarized build | Install to /Applications, launch via Finder |
| V3 | Works when launched hidden via `open -g -j -a Harmune` | No window, audio OK |
| V4 | Survives closing the launching terminal window | Launch from Ghostty, ⌘W, audio continues |
| V5 | Survives screen lock / display sleep for 10 min | Manual |
| V6 | TCC prompt names **Harmune**, not the terminal | Screenshot of the prompt |
| V7 | Media keys + Control Center Now Playing | Manual |
| V8 | `MusicLibraryRequest<Album>` pagination on a 2k+ album library | Timing log |
| V9 | Library artwork: `url(width:height:)` scheme, and fetchable? | Log URL scheme. Try catalog fallback. |
| V10 | `MusicRecentlyPlayedRequest`, `MusicPersonalRecommendationsRequest` availability | Result or error |
| V11 | Queue mutability (`insert(.afterCurrentEntry/.tail)`, removal, move) | Which work |
| V12 | Playback state observation: does `state`/`queue` publish changes? Latency? | Log timestamps |

### 0.3 Lifecycle + IPC prototype (days 6–9)
- [ ] `HarmuneIPC` v0:
  - NDJSON codec
  - `SocketServer` (an actor using `DispatchSource` read/write on a non-blocking fd; or `Network.framework` `NWListener` with `.unix` endpoint)
  - `SocketClient`
- [ ] Host: single-instance `flock`, socket creation with correct permissions, `getpeereid` check.
- [ ] CLI `harmune` (ArgumentParser) with `play <catalog-id>`, `pause`, `next`, `status [--json]`, `service status|start|stop`.
- [ ] `HostLauncher` in the CLI:
  1. Try to connect.
  2. On `ENOENT`/`ECONNREFUSED`, locate `Harmune.app`. Search order: `$HARMUNE_HOST_APP`, then the app bundle containing the CLI (when the CLI is installed inside it), then `/Applications`, `~/Applications`, `mdfind kMDItemCFBundleIdentifier`.
  3. Run `NSWorkspace.openApplication` with `activates=false`.
  4. Retry with backoff for up to 3 s.
- [ ] Spike alternative: `SMAppService.agent` + launchd `Sockets` activation. Record the trade-off; LaunchServices is the default.

### 0.4 UI framework spike (days 10–14, in parallel if 2 engineers)
Build a throwaway TUI against fake data. Go/no-go criteria:
- [ ] 3-pane layout (sidebar / list / right panel) + player bar + status bar. Correct resize at 60–200 cols.
- [ ] Raw key events: distinguish `g` then `g`, `G`, `Ctrl+d`, `Esc` (without a 1 s escape delay), `Shift+Tab`.
- [ ] 12 album covers in a scrolling grid using Kitty **Unicode placeholders** written as cell text with the framework's normal styling. Scroll 200 rows; no ghost images; resize clears correctly.
- [ ] Same grid on iTerm2 (OSC 1337) and Terminal.app (half-block).
- [ ] Headless render → string snapshot.
- [ ] Idle CPU < 1% with a 1 Hz progress tick. 20 fps animation < 5% CPU.

**If the framework fails 2+ criteria:** fall back to a thin custom renderer. That is a cell buffer, a diff and ANSI output, with Harmune's own small layout set (HStack/VStack/List/Grid/Text/Image). Budget +3 weeks. Decide by the end of week 3.

### Phase 0 exit gate
- V1–V4, V6 pass, **and** the CLI can `harmune play <id>` → close terminal → music continues → `harmune status` from a new terminal reports the right track.
- UI framework decision recorded.
- **If V1 fails:** stop. Write the pivot proposal (Music.app-backed controller) for an explicit product decision.

---

## 4. Phase 1 — Functional MVP (weeks 4–11)

### M1.1 Foundations (week 4)
- [ ] `HarmuneCore` models + `MusicBackend` protocol (as in §2). Unit tests for `PlaybackState.position(at:)`.
- [ ] `HarmuneDemo.DemoBackend`:
  - 30 albums, 300 tracks, 8 playlists in JSON fixtures; placeholder PNG artwork (generated gradients, license-free)
  - simulated clock that advances position, auto-advances tracks and honours shuffle/repeat
  - configurable latency and failure injection
- [ ] `SnapshotTests` harness: `render(view, cols, rows, capabilities) -> String`. Golden files per breakpoint (50×20, 80×24, 100×30, 140×40, 200×50).
- [ ] CI (GitHub Actions, macos-15 runner): `swift build`, `swift test`, SwiftLint/SwiftFormat check. No signing in CI for PRs.

### M1.2 IPC v1 + host services (weeks 4–5)
- [ ] Wire protocol v1 per spec §13.1a: `hello/welcome`, `subscribe`, `command/response`, `event`. Codable enums with an `action` discriminator. Unknown actions → `unsupported`.
- [ ] `RemoteBackend` (client) implements `MusicBackend`:
  - request correlation by `id`
  - timeouts (5 s / 30 s)
  - events → `AsyncStream`s
  - automatic reconnect with backoff (0.25 → 4 s, capped)
  - re-handshake and fresh snapshot after reconnect
- [ ] Host `PlaybackCoordinator` (`@MainActor`):
  - wraps `ApplicationMusicPlayer.shared`
  - observes `state` and `queue` (Combine `objectWillChange` → debounced 50 ms snapshot)
  - bumps `revision`
  - emits a periodic 5 s resync while playing
- [ ] Host `IPCServer` actor: client sessions, per-topic fan-out, max 16 clients, 1 MiB frame cap, drops slow clients when their buffer exceeds 4 MiB.
- [ ] Host `CatalogService` / `LibraryService`:
  - pagination via `MusicCatalogSearchRequest` (offset/limit)
  - `MusicLibraryRequest` with `limit`/`offset`
  - in-memory LRU result cache (search: 50 queries, 5 min TTL)
- [ ] Host `ArtworkService`:
  - resolve → fetch → downscale to 64/300/600 px PNG via ImageIO
  - write to `~/Library/Caches/Harmune/artwork/`
  - 4 concurrent jobs, coalescing duplicate requests
  - disk LRU at 500 MB
  - compute `averageColor` for dynamic theming later
- [ ] Host idle-exit timer and `service.stop` (with `playing` warning flag in the response).
- [ ] IPC tests:
  - round-trip encoding of every message
  - fuzzed malformed frames never crash the server
  - multi-client fan-out
  - reconnect mid-stream. Run the server with `DemoBackend` so the tests don't need MusicKit.

### M1.3 TUI architecture (week 6)
- [ ] **Store** (unidirectional, `@MainActor @Observable AppStore`):
  - `UIState { route stack, focus: Panel, mode: InputMode, selection per route, scroll per route, overlay, statusMessage, pendingKeys }`
  - `RemoteState { playback, queue, auth, capabilities, connection }`, mirrored from backend streams
  - `Action` enum → `reduce` (pure, unit-tested) + `Effect`s (async backend calls)
- [ ] **Keymap engine** (`HarmuneTerminal/Keybindings`):
  - `KeyEvent` normalisation (ESC sequences, Ctrl, Shift)
  - **trie** of bindings per `(mode, context)` with a global fallback
  - count prefix parser
  - 600 ms sequence timeout
  - outputs a `Command` (e.g. `.move(.down, count: 5)`, `.go(.albums)`, `.playPause`)
  - contexts: `global`, `list`, `grid`, `queue`, `search-input`, `command-input`, `overlay`
- [ ] Keymap tests: table-driven, covering every row of spec §6, `5j`, `gg` vs `g` timeout, `dd`, the `0` count rule, and the collisions from the review (`s`, `q`, `o`, `t`).
- [ ] **Layout engine:** `LayoutClass` from (cols, rows) per spec §5 + height breakpoints. Each view declares what it hides per class.
- [ ] **Component layer:**
  - `Panel` (titled, focus-aware border)
  - `SelectableList<T>` (virtualised: renders only visible rows, keeps a selection-centred scroll offset)
  - `ArtworkGrid`
  - `CarouselRow`
  - `ProgressBar` (sub-cell precision with `━`/`╸`)
  - `StatusBar`
  - `Header`
  - `TabChips`
  - `Toast`
  - `Modal`
  - `Spinner`
  - `EmptyState`

### M1.4 TerminalGraphics v1 (week 7)
- [ ] **Capability probe** at startup, ≤ 150 ms total, async with a fallback:
  - `COLORTERM`, `TERM`, `TERM_PROGRAM`
  - Kitty graphics query `ESC_Ga=q,i=31…` followed by DA1 (`ESC[c`) as a sentinel
  - XTVERSION
  - Sixel via DA1 attribute `4`
  - cell pixel size via `ESC[16t` (fallback `TIOCGWINSZ` `ws_xpixel`)
  - tmux detection → passthrough wrapping
- [ ] `ImageRenderer` protocol: `prepare(image, id, cells) -> Placement`, `cellsText(for placement) -> [StyledRun]`, `evict(id)`.
  - `KittyPlaceholderRenderer`: transmits once (`a=t,f=100,t=f|d,i=<id>,q=2`) and creates a virtual placement (`U=1`). The view emits `U+10EEEE` + row/column diacritics with fg color = image id.
  - `KittyDirectRenderer` / `ITerm2Renderer` / `SixelRenderer`: post-frame overlay pass at known cell rects. Clear on route change/resize.
  - `HalfBlockRenderer`: downsample to cols×(rows·2), emit `▀` with fg/bg; 256-color quantisation when not truecolor.
- [ ] `ImageCache` (TUI side): decoded/encoded per (key, cells) LRU; terminal-side ID LRU (evict > 64 images).
- [ ] Tests:
  - probe parser against recorded responses (Ghostty, Kitty, iTerm2, WezTerm, Terminal.app, tmux)
  - half-block golden output
  - Kitty escape encoder chunking (4096-byte base64 chunks)

### M1.5 Screens (weeks 8–10)
Build in this order. Each screen ships with snapshot goldens for 3 breakpoints and DemoBackend-driven tests.

1. [ ] **Shell:**
   - header (logo, connection dot, "● Playing Title — Artist")
   - sidebar (grouped, per spec §4.1)
   - content outlet
   - player bar (thumbnail, title/artist·album, progress, time, shuffle/repeat glyphs)
   - status bar (mode, breadcrumb, contextual hints, pending keys)
   - `Tab`/`Shift+Tab` focus cycle
   - `h` at content root → focus sidebar
2. [ ] **Onboarding / auth states:** every row of spec §3 Authorization States. "Connect" sends `auth.request`, which brings up the host's native prompt.
3. [ ] **Search:**
   - input with scope pill (`Apple Music`/`Library`, `Ctrl+s`)
   - 300 ms debounce
   - cancel superseded requests (`Task` cancellation + request id check)
   - tabs All/Songs/Albums/Artists/Playlists (`H/L`)
   - "load more" pagination when the selection nears the end
   - per-row actions `Enter` / `p` / `a`
4. [ ] **Library: Songs, Albums (grid/table, `t`), Artists, Playlists:**
   - paged loading of 100 per page, prefetching at 80%
   - sort menu `o`
   - in-place filter `F` with `n/N`
5. [ ] **Album detail:** artwork + metadata header, tracklist, `Enter` plays from the track (container play), `p`/`a`, "Play Album" when the header is focused.
6. [ ] **Artist detail:** top songs + albums grid.
7. [ ] **Playlist detail:** same as album, with a different header.
8. [ ] **Queue:**
   - current + upcoming, with position
   - `Enter` = skip to entry
   - `p`/`a` from elsewhere insert here
   - `dd`/`J`/`K`/`D` bound only if the capability is advertised, otherwise shown dimmed with "not supported" in the hint
   - optimistic UI is **not** used. Show a pending spinner until the `queue.changed` revision arrives.
9. [ ] **Help overlay `?`:** generated from the live keymap, so it never drifts from the bindings.
10. [ ] **Home (P1, but its skeleton ships in the MVP):** carousels for Recently Played / Made For You / Favorite Albums. Rows whose data source is unsupported are omitted.

### M1.6 Config v1 + errors (week 11)
- [ ] `HarmuneConfig`:
  - load `config.toml` (sections `general`, `appearance`, `animation`, `player`)
  - unknown keys → warning toast
  - invalid values → default + warning
  - `--config <path>` flag
  - `harmune config path|check`
- [ ] Error presentation per spec §20:
  - status-bar toasts (auto-dismiss 4 s; errors persist until the next key)
  - modal only for auth/subscription/service-stop
  - connection-lost banner with reconnect countdown
- [ ] Terminal hygiene:
  - alternate screen
  - raw mode
  - bracketed paste off
  - restore on `SIGINT`/`SIGTERM`/`SIGHUP`/crash (`atexit` + signal handlers)
  - `SIGWINCH` → relayout
  - `SIGTSTP`/`SIGCONT` (Ctrl+Z) handled
  - delete all Kitty images on exit (`a=d,d=A`)
  - print the "music still playing" line

### Phase 1 exit
- Scripted manual test on Ghostty + Terminal.app, with keyboard only: launch → search "In Rainbows" → open album → play → queue 2 songs (`a`) → navigate Albums grid → pause/seek/next → quit → music continues → relaunch → state restored in < 300 ms.
- All snapshot and unit tests green in CI.

---

## 5. Phase 2 — Visual experience (weeks 12–15)

- [ ] **Theme system:**
  - `Theme` = the 13 tokens from spec §10.2 + derived (selectionBg, focusBorder…)
  - themes are TOML files in `Resources/Themes`
  - custom themes loaded from `~/.config/harmune/themes/*.toml`
  - ships midnight, tokyo-night, catppuccin-mocha, gruvbox-dark, nord, dracula, mono
  - `NO_COLOR` → mono
  - 256-color downgrade map per theme
- [ ] **Basic command mode:** `:` input line with a fuzzy-matched command list (the palette in the design). Commands: `:q`, `:play…`, `:theme` picker with **live preview** and `Esc` revert, `:artwork on|off`, `:visualizer on|off`, `:immersive`, `:queue clear`, `:filter`, `:search`, `:service stop`.
- [ ] **Animation scheduler:**
  - one frame clock, demand-driven: animations register while active
  - global cap `max_fps` (default 20)
  - progress bar ticks at 1 Hz when nothing else animates
  - pauses when playback is paused
  - stops when the terminal reports focus-out (`ESC[?1004h` focus events) unless immersive
  - `reduced_motion` disables everything except progress
- [ ] **Decorative visualizer:** a deterministic pseudo-spectrum (seeded by track id plus smoothed noise, with a beat-ish envelope at a fixed tempo guess). Uses `▁▂▃▄▅▆▇█` with a gradient from accent → accentPink. Labelled "decorative" in settings.
- [ ] **Immersive Now Playing (`v`):** large centred artwork sized to the largest square fitting 60% of the height; title/artist/album; progress with times; transport glyphs; visualizer; hint bar.
- [ ] **Dynamic color:** host-computed `averageColor` + a 3-color k-means palette (host side, cached with the artwork) → overrides `accent` / `accentPink` in immersive and the player bar only. Contrast-checked against the background (WCAG ≥ 4.5 for text uses, otherwise fall back to the theme accent).
- [ ] **Track transitions:** cross-fade the artwork placeholder (2-frame swap) + title slide-in. Disabled under reduced motion.
- [ ] **Right-hand Now Playing panel (≥ 120 cols):** current-container tracklist + mini visualizer.
- [ ] Visual QA pass against the design PNG in Ghostty at 200×50. Record differences in `Docs/DESIGN.md`.

**Exit:** the core interface matches the approved design in Ghostty and stays fully usable in Terminal.app at 80×24.

---

## 6. Phase 3 — Developer experience (weeks 16–19)

- [ ] **Command mode:** completion (`Tab`, argument suggestions from the live state, e.g. theme names, repeat modes), history (`↑/↓`, persisted to `~/.local/state/harmune/history`, last 500), inline error rendering.
- [ ] **Advanced motions:** counts on all list motions, `Ctrl+d/u/f/b`, `zz` (centre), `H/M/L` only in contexts where `H/L` aren't tab switches (otherwise skip). Document the choice.
- [ ] **Custom keybindings:** `[keybindings.<mode>]` tables. Validation:
  - unknown action
  - unparsable key
  - prefix conflicts (binding `g` alone while `gg` exists)
  - duplicates
  Each produces a precise warning. `harmune keys` prints the effective keymap.
- [ ] **CLI completeness:**
  - `play [--id <id> | --search "<q>" --first]`
  - `pause`, `toggle`, `next`, `previous`
  - `seek <sec|+n|-n>`
  - `shuffle on|off`, `repeat off|one|all`
  - `queue [--json]`, `queue add <id>`
  - `search "<q>" [--type songs] [--json]`
  - `status [--json] [--watch]`: `--watch` streams NDJSON events, which is useful for status bars like sketchybar/tmux
  - shell completions (`harmune --generate-completion-script zsh`)
- [ ] **Multi-client:** two TUIs + CLI concurrently. Revision-based state; last command wins. Tests cover it.
- [ ] **Service management hardening:** `service status` shows pid, uptime, version, clients and idle-exit ETA. `service stop` asks for confirmation if playing (`--force`). Host version mismatch → CLI offers a restart.
- [ ] **Settings view:** simple form over the config with live apply.

**Exit:** every playback/queue action is possible from the CLI; keyboard behaviour is consistent across views; keymap tests cover 100% of the default bindings.

---

## 7. Phase 4 — Release (weeks 20–22)

- [ ] **Packaging:**
  - `Harmune.app` contains the host + `Contents/Resources/bin/harmune` (CLI, codesigned with the same Team ID)
  - universal binary (arm64 + x86_64 if MusicKit/framework allow)
  - `Scripts/package.sh` → `.zip` + `.dmg` + SHA-256 checksums
- [ ] **Notarization in CI:**
  - tag-triggered workflow
  - secrets: Developer ID cert (p12), notarytool API key
  - steps: staple, verify with `spctl -a -vv` and `codesign --verify --deep --strict`
- [ ] **Homebrew cask** (own tap first, `homebrew-harmune`):
  - `app "Harmune.app"`
  - `binary "#{appdir}/Harmune.app/Contents/Resources/bin/harmune"`
  - `zap` stanza for caches/config/socket
- [ ] **First-run polish:** `harmune` with no host installed → a clear message. Auth flow tested on a fresh macOS user account.
- [ ] **Docs:**
  - README with GIF/screenshots
  - KEYBINDINGS (generated from the keymap)
  - PROTOCOL.md (for third-party clients)
  - DEVELOPMENT.md (demo mode, building your own host with `Local.xcconfig`)
  - CONTRIBUTING, issue templates
- [ ] **Release checklist:** run the full MusicKit validation matrix (spec §22.3) + terminal matrix (§22.4) on a clean machine.

**Exit:** a new user runs `brew install --cask <tap>/harmune && harmune`, authorizes, and plays music without compiling anything.

---

## 8. Cross-cutting test plan

| Layer | Tooling | Runs in CI |
|---|---|---|
| Reducers, keymap, config, position math, command parser | XCTest / Swift Testing, table-driven | ✅ |
| IPC codec + server/client | In-process server over `DemoBackend`, fuzzing malformed frames | ✅ |
| Graphics encoders + probe parser | Golden byte strings, recorded terminal responses | ✅ |
| UI | Headless snapshots × 5 breakpoints × {kitty, halfblock-256, no-image} | ✅ |
| Host + MusicKit | `HostIntegrationTests` (opt-in, `HARMUNE_LIVE=1`) + manual matrix | ❌ (manual per release) |
| Performance | Benchmarks: render 10k-row list, keypress → frame latency, idle CPU sampling | ✅ (thresholds as warnings) |

---

## 9. Risk register

| # | Risk | Likelihood | Impact | Mitigation | Owner/When |
|---|---|---|---|---|---|
| 1 | `ApplicationMusicPlayer` on macOS needs Music.app or fails outside the sandbox/TCC context | Med | **Fatal** | Phase 0 V1–V3 gate; pivot proposal ready | Wk 1–2 |
| 2 | UI framework immature (images, key handling, perf) | High | High | Spike + own `TerminalGraphics` + component seam; custom renderer fallback (+3 wks) | Wk 2–3 |
| 3 | Library artwork not fetchable | Med | Med | Catalog-equivalent lookup; render via MusicKit in the host; placeholder fallback | Wk 1 |
| 4 | Queue edit APIs limited | High | Low | Capability flags; hide or dim actions | Wk 2 |
| 5 | Favorites / recommendations APIs missing on macOS | Med | Low | Capability flags; omit Home rows | Wk 2 |
| 6 | Notarization/MusicKit entitlement issues with Developer ID | Low–Med | High | Notarize on day 1 | Wk 1 |
| 7 | Terminal image bugs (ghosting, tmux, resize) | High | Med | Unicode placeholders; aggressive clear on resize/route; terminal matrix | Ongoing |
| 8 | OSS contributors blocked by Apple requirements | High | Med | DemoBackend, `Local.xcconfig`, CI without signing | Wk 4 |
| 9 | Escape-key latency (ESC vs Alt sequences) | Med | Med | 25 ms ESC disambiguation timer; kitty keyboard protocol when available | Wk 6 |

---

## 10. Schedule summary

| Weeks | Milestone | Key deliverable |
|---|---|---|
| 1–3 | **Phase 0 gate** | Validation matrix, CLI plays through the host, UI framework decision |
| 4–5 | M1.1–M1.2 | DemoBackend, snapshot harness, IPC v1, host services |
| 6–7 | M1.3–M1.4 | Store, keymap, layout, components, TerminalGraphics |
| 8–10 | M1.5 | All MVP screens |
| 11 | M1.6 | Config, error UX, terminal hygiene → **MVP** |
| 12–15 | Phase 2 | Themes, command palette, animation, immersive, dynamic color |
| 16–19 | Phase 3 | Full command mode, custom keys, CLI, multi-client |
| 20–22 | Phase 4 | Signed/notarized release, Homebrew cask, docs → **1.0** |

---

## 11. First week — concrete task list

1. Create the Apple App ID with MusicKit + the Developer ID cert. Notarize an empty LSUIElement app.
2. `swift package init`. Add targets per §1 and an empty `HarmuneHost` Xcode project that links `HarmuneCore`/`HarmuneIPC`/`HarmuneMusic` as local package products.
3. Probe host with debug window. Run V1, V3, V4, V6 (most decisive first).
4. In parallel: UI framework spike repo (`Spikes/ui-framework/`), working the go/no-go list.
5. Friday: review `Docs/PHASE0_RESULTS.md` draft. Go / adjust / pivot.

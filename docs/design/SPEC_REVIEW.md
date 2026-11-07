# Harmune — Spec & Design Review

**Reviewed:** `product_spec.md` (v1.0 Draft) and the original concept image (no longer in the repository)
**Date:** 2026-10-15
**Outcome:** The product makes sense and the architecture is basically sound. The spec is unusually honest about risk (Phase 0, the decorative visualizer, queue-editing caveats). But several things in it are unverified, and the spec and the design disagree in places. These are fixed in `product_spec.md` v1.1. The original is kept at `docs/product_spec.v1.0-original.md`.

---

## 1. Verdict by area

| Area | Verdict | Notes |
|---|---|---|
| Vision / positioning | ✅ Sound | Clear wedge: independent playback, persistent host, polish. |
| Two-process architecture | ✅ Sound, with gaps | Host lifecycle, launch method and TCC attribution are unspecified (see R1, R2). |
| UI framework choice (SwiftTUI) | ⚠️ High risk | There are two projects named "SwiftTUI". The one the spec cites (image support, public beta) could not be confirmed from its own repo. Needs a spike and an abstraction seam (R3). |
| MusicKit feasibility on macOS | ⚠️ High risk | `ApplicationMusicPlayer` on macOS is under-documented. There are public reports of permission errors in sandboxed apps (R1). The Phase 0 gate is correct and must be widened. |
| Design ↔ spec consistency | ❌ Several conflicts | Volume, sidebar items, `/` semantics, key collisions, theme list (R5–R9). |
| Keyboard model | ⚠️ Collisions | `s` is both shuffle and sort; `q` is both quit and "clear queue" (R6). |
| IPC protocol | ⚠️ Underspecified | No framing, no position timestamp, no snapshot/subscribe contract (R10). |
| Artwork pipeline | ⚠️ Underspecified | Library artwork URLs may not be fetchable outside MusicKit. iTerm2's own protocol is missing. Grid views need many images at once (R11). |
| OSS contributor story | ❌ Missing | Contributors can't run the host without their own MusicKit-enabled App ID. A mock backend is required (R4). |
| Roadmap | ⚠️ Reorder | CLI playback commands are needed for the Phase 0 exit test. Config/themes are needed earlier than Phase 3 (R13). |

---

## 2. Findings and revisions

### R1. MusicKit on macOS is the #1 risk. Widen the Phase 0 gate.
- `SystemMusicPlayer` is not available on macOS. Only `ApplicationMusicPlayer` (macOS 14+) can be used.
- There are public reports of `ApplicationMusicPlayer.play()` failing with a *permission* error even after authorization succeeded, in a **sandboxed** macOS app.
- Some existing CLI tools embed a bundle ID and the MusicKit entitlement in a bare binary. It is unclear whether their audio actually renders in-process or is routed through Music.app.

**Revision:**
- The host is a **non-sandboxed, Developer ID–signed, hardened-runtime, notarized** `.app` whose App ID has the MusicKit App Service enabled. (Corrected: this review first called for a `com.apple.developer.musickit` entitlement, which doesn't exist. Apple DTS called the similar `com.apple.developer.music-kit` made up in the forum thread cited below.)
- Phase 0 must explicitly prove all of the following:
  - (a) audio renders with **Music.app not running, and Music.app is not auto-launched** (check with `pgrep Music`)
  - (b) it works in a Developer ID build, not only a debug build
  - (c) it works when launched by LaunchServices in the background
  - (d) Control Center Now Playing and media keys work
  - (e) library-item artwork can be fetched (see R11)
  - (f) `MusicLibraryRequest`, `MusicRecentlyPlayedRequest` and `MusicPersonalRecommendationsRequest` work on macOS
- **Fallback if (a) fails:** Harmune becomes "Music.app-backed" (ScriptingBridge/MediaRemote). That is a product-level pivot that must be decided at the gate, not discovered later.

### R2. The host lifecycle and launch method are unspecified, and that affects permissions.
If the TUI spawns the host binary directly (`Process`/`posix_spawn`), the host:
1. Is in the terminal's process group, so it gets SIGHUP when the terminal window closes.
2. Is treated by TCC as the **terminal's responsible process**, so permission prompts and grants attach to Ghostty/iTerm instead of Harmune.

**Revision:**
- Launch the host via **LaunchServices** (`NSWorkspace.openApplication` with `activates = false`, `addsToRecentItems = false`, or `open -g -j -a`). Then it is its own responsible process and is not in the TTY's session.
- Evaluate `SMAppService.agent` with launchd socket activation in Phase 0 as the alternative.
- Add a host **idle policy**: quit after N minutes (default 30) when paused, with no connected clients. Configurable; `0` means never.
- Add a **single-instance guard**: an exclusive `flock` on a lock file next to the socket.

### R3. Choosing SwiftTUI needs a spike and an exit path.
There are two "SwiftTUI" projects. `rensbreur/SwiftTUI` is established but unmaintained and has no image support. A newer one is announced on Swift Forums with Kitty/Sixel probing, but its repo/README could not be verified. Its API is beta either way. Image placement inside a diffing, cell-based renderer is the hardest part of this UI, and most frameworks get it wrong.

**Revision:**
- Week 1 spike, with go/no-go criteria:
  - render a 3-pane layout at 60 fps
  - resize without artifacts
  - place and remove 12 Kitty images in a scrolling grid
  - handle raw key sequences such as `gg`, `5j`, `Ctrl+d`
  - snapshot-test a frame headlessly
- All terminal graphics go through Harmune's own `TerminalGraphics` module. Use **Kitty Unicode placeholders** (`U+10EEEE`) where supported. Images then occupy normal cells, survive the framework's diffing, scroll correctly and work through tmux. Direct placement, iTerm2 OSC 1337 and Sixel are fallbacks.
- Keep views dependent on a small `HarmuneUI` component layer, not raw framework types everywhere. A framework swap (e.g. to a thin custom renderer) is then a bounded job.
- Drop "Swift 6.4+". Require **Swift 6.2+ / Xcode 26+** unless the chosen UI framework needs newer.

### R4. Open-source contributors can't run the product. Add a mock backend.
Running the real host requires an Apple Developer account, an App ID with the MusicKit service, signing, and an Apple Music subscription. Most contributors have none of these.

**Revision:**
- Define a `MusicBackend` protocol in `HarmuneCore`. It has two implementations:
  - `MusicKitBackend`, in the host
  - `DemoBackend`: fixture library, a simulated playback clock, local placeholder artwork
- `harmune --demo` runs the TUI against an in-process `DemoBackend`. No host and no Apple account are needed.
- Snapshot tests and CI use `DemoBackend`.
- Document how to build the host with your own Team ID and bundle ID (`Config/Local.xcconfig`, git-ignored).

### R5. Volume is in the design but MusicKit doesn't support it.
The design shows `🔊 80%` and `+/-: volume`. `ApplicationMusicPlayer` exposes no volume API on macOS. The only option is system output volume (CoreAudio), which surprises users and affects every app.

**Revision:** Remove the volume control from v1 UI. `+`/`-` are unbound. A system-volume option can come back later as an opt-in P2 setting, clearly labelled "System volume".

### R6. Key collisions between the design and the spec.

| Conflict | Source | Resolution |
|---|---|---|
| `s` = shuffle (global) vs `s` = sort (Album view footer) | design | Sort → `o` ("order"). `s` stays shuffle everywhere. |
| `q` = close/quit vs `q: clear` (Queue header) | design | Clear queue → `:queue clear` (asks for confirmation). Also `D` in Queue view. |
| `1/Enter: open` | design typo | `l/Enter: open`. |
| `+/-: volume` | design | Removed (R5). |
| `/` = filter list (spec) vs `/ Search Apple Music…` everywhere (design) | both | See R7. |
| `Tab` = focus panel vs `Tab: complete` in command mode | both | Fine. Modes are disjoint. Document it. |
| Search category chips (All/Songs/Albums/…) had no key | design | `H` / `L` = previous/next tab, in any tabbed view. |

Multi-key sequences (`gg`, `gh`, `dd`) need a defined **timeout (default 600 ms)**, a pending-keys indicator in the status bar, and a rule that a count prefix (`5j`) can't start with `0`.

### R7. Clarify what `/` does.
The spec says "`/` filters the current list; in Search it enters query input". The design shows a global "/ Search Apple Music…" box in the header and `/: search` in every footer. Two different meanings for one key in neighbouring views hurts predictability, which is the spec's own principle.

**Revision:**
- `/` always opens **search input**. The scope depends on where you are and is **always shown** in the input:
  - Home / Search / Now Playing → `Apple Music` (catalog)
  - Library views (Songs, Albums, Artists, Playlists, Favorites) → `Library`
  - `Ctrl+s` inside the input toggles the scope.
- **Filter the current list in place** → `F` (vim users also get `n`/`N` to jump between matches).
- `:search <q>` = catalog search. `:filter <q>` = in-place filter.

### R8. Make the sidebar match the design.
The spec lists 7 destinations with "Library" alongside "Albums/Artists/Playlists". That's ambiguous: what does "Library" show if Albums are separate? The design adds Favorites, Recently Played and Settings to the sidebar.

**Revision.** The sidebar is grouped:
```
Home
Search
── LIBRARY ──
Songs        (was "Library")
Albums
Artists
Playlists
Favorites    (P1)
Recently Played (P1)
──
Queue
Settings
```
`gl` → Songs. Add `gr` → Recently Played and `gf` → Favorites. Now Playing is reached with `gn`/`v`, not from the sidebar. P1 items are hidden until implemented. No dead entries ship.

### R9. Views the design shows that the spec doesn't describe.
- **Album grid with artwork** (design "Album View") vs the table in the spec. **Revision:** grid is the default when the terminal supports images and is ≥ 90 columns; otherwise a table. `t` toggles grid/table. The choice is persisted per view.
- **Right-hand Now Playing panel**, showing the current album's tracklist and a mini spectrum (≥ 120 cols). **Revision:** spec it explicitly. It shows the current container (album/playlist), not the whole queue. Focusable with `Tab`.
- **Home sections "Recently Played" and "Made For You"** are horizontal artwork rows with "See All →". **Revision:** they are horizontal carousels. `h/l` moves within a row, `j/k` moves between rows, `Enter` on a section header = See All.
- **Command palette with live theme preview** (`:theme`). **Revision:** moving the selection previews the theme. `Esc` reverts.
- **Theme list:** the design shows default, tokyo-night, catppuccin, gruvbox, dracula, nord, solarized. The spec has Minimal Monochrome. **Revision:** ship `harmune-midnight`, `tokyo-night`, `catppuccin-mocha`, `gruvbox-dark`, `nord`, `dracula`, `mono`. Solarized is P2.
- **Player-bar transport icons** (⤨ ⏮ ⏸ ⏭ ↻) are display-only status in a keyboard-first app. Mouse clicks on them are P2. Respect `NO_COLOR`.

### R10. The IPC protocol needs a precise contract.
Missing items:
- **Framing.** Use newline-delimited JSON (NDJSON), with a 1 MiB max frame size. Large payloads (artwork) never go over the socket. Send a cache file path instead.
- **Handshake.** `hello {protocolVersion, client: "tui"|"cli", pid}` → `welcome {protocolVersion, hostVersion, capabilities[]}`. `capabilities` advertises queue editing, favorites, recommendations and so on. The UI disables a feature when its capability is missing. This replaces "visibly disabled if unsupported" with a mechanism.
- **Clock.** `playback.changed` carries `position`, `positionTimestamp` (host monotonic → wall clock), `rate` (0 or 1), `duration` and `revision`. The TUI extrapolates position locally, so it never polls (this satisfies §9.1). The host also emits a resync every 5 s during playback and on seek.
- **Subscribe.** The client sends `subscribe {topics: [...]}`. The CLI's `harmune status` connects, takes a snapshot and disconnects without subscribing.
- **Errors.** `{success:false, error:{code, message, recoverable}}` with a closed set of codes (`notAuthorized`, `noSubscription`, `network`, `unavailable`, `unsupported`, `invalidArgument`, `internal`).
- **Peer check.** Use `getpeereid()` and reject a different UID. Socket at `~/Library/Application Support/Harmune/host.sock` with mode `0600`, in a `0700` directory. Watch the 104-byte `sun_path` limit and fall back to `$TMPDIR` if needed.

### R11. The artwork pipeline needs a design.
- **Library item artwork** on Apple platforms often comes back as a `musickit://` URL that only MusicKit's own image views can resolve, so `URLSession` can't fetch it. The host must fetch the bytes. Options: use the catalog equivalent's artwork URL, or render with MusicKit APIs in the host. The result is written to `~/Library/Caches/Harmune/artwork/<id>-<px>.png`. Validate this in Phase 0.
- The TUI reads cache files. On Kitty-protocol terminals it transmits once per image ID (`a=t`, `i=<id>`) and re-places it cheaply. It never retransmits unchanged artwork (spec §11.2). Use file transmission (`t=f`) only when the terminal is known to be local. Use direct (`t=d`) over SSH.
- Add **iTerm2 inline images (OSC 1337)** to the rendering priority. It is iTerm2's best protocol.
- **Fallback:** half-block (`▀`) rendering. Truecolor where `COLORTERM=truecolor`, otherwise quantize to 256 colors (Terminal.app before macOS 26 is 256-color).
- **Grid views:** at most 4 concurrent downloads/decodes. Render the visible cells first. Use an LRU for terminal-side image IDs (delete off-screen images after N).
- **Immersive background blur:** under-text images need a negative z-index *and* default-background cells. This conflicts with themes that paint backgrounds. Keep it at P2 and Kitty/Ghostty only.

### R12. Small spec corrections.
- **Media keys / Control Center** integration is a free win if `ApplicationMusicPlayer` publishes Now Playing info on macOS. Make it a P0 requirement, verified in Phase 0.
- **Favorites:** the API surface on macOS MusicKit is uncertain (Apple Music API `/v1/me/ratings` is the likely path). Hide `f` until the `favorites` capability is advertised.
- **Height breakpoints** were missing:
  - < 20 rows: player bar collapses to 1 line, no artwork
  - < 12 rows: header hidden
- **Quit message:** on `q`/`:quit` from root, print one line after restoring the terminal: `Harmune closed — music still playing (harmune service stop to stop it).`
- **Startup target:** < 300 ms to first frame with a running host. Cold host start < 2 s to first frame. Show a skeleton UI while waiting.
- Strip the `utm_source=chatgpt.com` tracking parameters from reference links.

### R13. Roadmap reordering.
- `harmune play|pause|next|status` (CLI) **moves into Phase 0**. It is the exit test.
- `DemoBackend` and the snapshot-test harness move into **Phase 1, week 1**.
- `config.toml` (theme + artwork + motion only) moves into **Phase 1**. Custom keybindings stay in Phase 3.
- Basic `:` command mode (`:q`, `:theme`, playback verbs) moves into **Phase 2**, because the design's theme picker depends on it. Completion/history stay in Phase 3.

---

## 3. Things I would not change
- Keep decorative-only visualizer honesty, labelled in Settings ("Decorative — not audio-reactive").
- Host-owned queue, with the TUI never assuming success.
- Status-bar errors with modals only for decisions.
- Non-goals list.
- Keep Music.app/AppleScript out — unless the Phase 0 gate forces the pivot in R1.

## Sources consulted
- [SwiftTUI (rensbreur)](https://github.com/rensbreur/SwiftTUI)
- [SwiftTUI — Swift Forums announcement](https://forums.swift.org/t/swifttui-a-terminal-ui-framework-for-swift/89032)
- [Apple Dev Forums — ApplicationMusicPlayer permission denied in sandbox](https://developer.apple.com/forums/thread/820580)
- [MusicKit documentation](https://developer.apple.com/documentation/musickit)
- [Sound MCP server (MusicKit CLI example)](https://glama.ai/mcp/servers/seayniclabs/sound)

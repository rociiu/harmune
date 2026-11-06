# Key bindings

These are the defaults. Rebind any of them in `~/.config/harmune/config.toml`, and run `harmune keys` to see what's in effect.

A count repeats motions, such as `5j` or `3]`. Multi-key sequences such as `gg` wait 600 ms for the next key.

## Navigation

| Keys | Action |
|---|---|
| `↓` / `↑` or `j` / `k` | move down / up (5j moves five) |
| `gg` / `G` | first / last item |
| `Ctrl+d` / `Ctrl+u` | half page down / up |
| `Ctrl+f` / `Ctrl+b` | full page down / up |
| `zz` | center the selection |
| `l` / `Enter` | open or play the selection |
| `h` / `←` | back |
| `Tab` | open or close the view switcher |
| `Esc` | close, clear the filter, or go back |
| `q` / `Ctrl+c` | back; quit from the root (music keeps playing) |

## Go To

| Keys | Action |
|---|---|
| `gh` | Home |
| `gs` | Search |
| `gl` | Songs |
| `ga` | Albums |
| `gA` | Artists |
| `gp` | Playlists |
| `gr` | Recently Played |
| `gq` | Queue |
| `gn` | Now Playing |
| `g,` | Settings |

## Playback

| Keys | Action |
|---|---|
| `Space` | play / pause |
| `>` / `<` | next / previous track |
| `]` / `[` | seek forward / back 5 seconds |
| `s` | shuffle |
| `r` | cycle repeat |
| `v` | immersive Now Playing |

## Queue

| Keys | Action |
|---|---|
| `a` / `p` | add to queue / play next |
| `dd` | remove the entry (in Queue, if supported) |
| `J` / `K` | move the entry (in Queue, if supported) |
| `D` | clear upcoming (in Queue, if supported) |

## Lists

| Keys | Action |
|---|---|
| `/` | search (Ctrl+S switches Apple Music / Library) |
| `H` / `L` | previous / next search category |
| `F` | filter the current list |
| `n` / `N` | next / previous match |
| `o` | sort Songs or Albums |
| `t` | grid or list (Albums) |
| `:` | command (:theme, :seek 90, :q) |
| `?` | this help |

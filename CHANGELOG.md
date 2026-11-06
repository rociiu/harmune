# Changelog

## Unreleased

First version with a real Apple Music host.

- Play Apple Music with Music.app closed, from a host app that outlives the terminal.
- TUI: Home, Search with categories, Songs, Albums (grid or list), Artists, Playlists, Recently Played, album, artist and playlist details, Queue, immersive Now Playing, Settings, keyboard help and command mode.
- Seven themes and custom themes, with a live-preview picker.
- Artwork through Kitty graphics, iTerm2 inline images, Sixel or half-blocks.
- CLI for playback, queue, search, library, service, config, keys, completions and cache.

### Known limitations

- Queue removal, reordering and clearing are off on Apple Music until they've been tested.
- Favorites aren't supported.
- The visualizer is decorative: MusicKit doesn't expose audio.
- No volume control: MusicKit has no API for it on macOS.

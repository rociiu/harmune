# IPC protocol

Version 1. Clients talk to the host over a Unix socket, using one JSON object per line. Try it by hand:

```bash
nc -U ~/Library/Application\ Support/Harmune/host.sock
```

## Transport

- **Socket:** `~/Library/Application Support/Harmune/host.sock`, or `HARMUNE_SOCKET`. Its mode is `0600`, and the host rejects any peer with a different user ID.
- **Limits:** 1 MiB per frame and 16 clients.
- **Dates:** ISO 8601 with fractional seconds, such as `2026-11-06T01:10:31.250Z`.

## Frames

Every frame has `version` (currently `1`) and `type`.

```json
{"version":1,"type":"command","id":"1","action":"playback.seek","payload":{"position":120}}
```

```json
{"version":1,"type":"response","id":"1","success":true}
```

```json
{"version":1,"type":"response","id":"2","success":false,"error":{"code":"notFound","message":"Song c:1 not found","recoverable":true}}
```

```json
{"version":1,"type":"event","event":"playback.changed","revision":12,"data":{}}
```

Responses carry the `id` of their command. Results are in `result`.

**Error codes:** `notAuthorized`, `noSubscription`, `network`, `unavailable`, `unsupported`, `invalidArgument`, `notFound`, `timeout`, `disconnected`, `internal`. An unknown action returns `unsupported`.

## Starting a session

Send `session.hello` first:

```json
{"version":1,"type":"command","id":"1","action":"session.hello","payload":{"protocolVersion":1,"client":"cli","pid":123}}
```

The result has `protocolVersion`, `hostVersion` and `capabilities`. To receive events, send `session.subscribe` with `{"topics":["playback","queue","authorization"]}`.

**Capabilities:** `queue.remove`, `queue.move`, `favorites`, `recommendations`, `recentlyPlayed`, `library.search`. Check them before offering an action.

## Commands

| Action | Payload | Result |
|---|---|---|
| `auth.status` | | `AuthStatus` |
| `auth.request` | | `AuthStatus` |
| `playback.state` | | `PlaybackState` |
| `playback.play` | `PlayRequest` | |
| `playback.pause`, `.toggle`, `.next`, `.previous` | | |
| `playback.seek` | `{"position":120}` | |
| `playback.shuffle` | `{"on":true}` | |
| `playback.repeat` | `{"mode":"off"\|"one"\|"all"}` | |
| `queue.get` | | `QueueState` |
| `queue.add` | `{"songIDs":[…],"position":"next"\|"last"}`, 1–500 IDs | |
| `queue.remove` | `{"entryID":"…"}` | |
| `queue.move` | `{"entryID":"…","index":3}` | |
| `queue.clear` | | |
| `catalog.search` | `SearchQuery`, limit up to 100 | `SearchResults` |
| `library.songs`, `.albums` | `{"sort":"title"\|"artist"\|"recentlyAdded","offset":0,"limit":100}`, limit up to 200 | `Page` |
| `library.artists`, `.playlists` | `{"offset":0,"limit":100}` | `Page` |
| `browse.album`, `.artist`, `.playlist` | `{"id":"…"}` | detail object |
| `browse.home` | | `HomeSections` |
| `service.status` | | `ServiceStatus` |
| `service.stop` | `{"force":false}` | fails with `invalidArgument` if music is playing and `force` is false |

The types are in `Sources/HarmuneCore/Models.swift` and `Sources/HarmuneIPC/Envelope.swift`.

**IDs** are tagged with their source: `c:` for the catalog and `l:` for the library. Treat them as opaque.

## Events

| Event | Topic | Data |
|---|---|---|
| `playback.changed` | `playback` | `PlaybackState` |
| `queue.changed` | `queue` | `QueueState` |
| `authorization.changed` | `authorization` | `AuthStatus` |

`revision` increases with each change. Ignore anything older than what you already have.

Playback events aren't sent every second. Work out the current position from the state:

```text
position + (now - positionTimestamp) * rate
```

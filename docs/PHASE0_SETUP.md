# Phase 0: testing the MusicKit host

This answers the question the whole design depends on: can a signed background app play Apple Music with Music.app closed? On one Mac, the answer so far is yes, at step A below with no provisioning profile; see `PHASE0_RESULTS.md`. Release signing (step C) hasn't been tried.

A new App ID can take a few minutes to work. On the first run, a search failed with `developerTokenInvalid` even though MusicKit was enabled, and the same build succeeded about two minutes later.

## 1. Register the App ID (once)

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list):

1. Add a new App ID of type **App**, with the explicit bundle ID `com.orinbyte.harmune`.
2. Open the **App Services** tab and enable **MusicKit**.

If that bundle ID is taken, choose your own and set `HARMUNE_BUNDLE_ID` when you build.

MusicKit is enabled here, on the App ID. It has no entitlement of its own: Apple's Developer Technical Support called `com.apple.developer.music-kit` made up in [this forum thread](https://developer.apple.com/forums/thread/820580).

## 2. Build and run the checks

```bash
Scripts/build-host.sh
```

Quit Music.app, then run:

```bash
Scripts/validate-phase0.sh
```

The script plays music out loud, asks what you heard, and writes `docs/PHASE0_RESULTS.md`. It stops at the first blocking failure. The host's log is at `~/Library/Logs/Harmune/host.log`.

## 3. If playback fails

Try these in order, rerunning the checks each time and keeping each results file. Which one works is the finding we need.

| Step | Change | Why |
|---|---|---|
| A | Nothing: Apple Development certificate, no profile | The simplest setup that could work |
| B | Add a macOS App Development profile for the App ID, with `Scripts/build-host.sh --profile <file>` | A profile gives the app a verified `application-identifier`, which MusicKit may need for its developer token |
| C | Use a Developer ID certificate and a Developer ID profile, then run `Scripts/notarize.sh <keychain-profile>` | The setup Harmune would ship with (this is also check V2) |
| D | Rerun step C from `/Applications` | Rules out anything specific to where the app is launched from |

What the errors in the log point to:

- **`DecodingError` ("not valid JSON") on a search:** look for a 401 in the system log. `developerTokenInvalid` means Apple issued a token and then rejected it. Check that MusicKit is enabled on the App ID, allow some time for a new App ID to take effect, then try step B.

  ```bash
  /usr/bin/log show --last 5m --predicate 'process == "Harmune"' | grep -i developerToken
  ```

- **`developerTokenRequestFailed`:** MusicKit isn't enabled for this bundle ID, or the signature doesn't match the team. Try step B.
- **`permissionDenied` from `play`:** the failure in the forum thread above, which had no confirmed fix. That app was sandboxed, and this one isn't.
- **Works only while Music.app is open, or only while it's closed:** record exactly which. The same thread reports trouble with Music.app open.

## 4. Decide

Per the plan's Phase 0 gate:

- **V1, V3, V4 and V6 pass:** keep building on this design.
- **V1 fails at every step above:** stop and decide whether to pivot, for example to a controller for Music.app.

## Resetting the permission prompt

To see the prompt again for V6:

```bash
tccutil reset MediaLibrary com.orinbyte.harmune
```

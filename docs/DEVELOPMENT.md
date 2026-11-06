# Development

## Without an Apple account

```bash
swift build
```

```bash
.build/debug/harmune --demo
```

To exercise the socket as well, run without `--demo`. The CLI starts `harmune-host --demo`, as long as no `Harmune.app` is installed where it looks:

```bash
HARMUNE_SOCKET=/tmp/hm.sock .build/debug/harmune
```

```bash
HARMUNE_SOCKET=/tmp/hm.sock .build/debug/harmune service stop --force
```

## With Apple Music

You need an Apple Developer account, with a MusicKit-enabled App ID. [PHASE0_SETUP.md](PHASE0_SETUP.md) has the steps.

```bash
Scripts/build-host.sh
```

```bash
build/Harmune.app/Contents/Resources/bin/harmune
```

Use your own bundle ID with `HARMUNE_BUNDLE_ID`, and a specific certificate with `HARMUNE_SIGN_IDENTITY`. After rebuilding, restart the running host:

```bash
build/Harmune.app/Contents/Resources/bin/harmune service stop --force
```

## Useful settings

| Variable | Effect |
|---|---|
| `HARMUNE_SOCKET` | Socket path, to keep a test host apart from your real one |
| `HARMUNE_HOST_APP` | Which `Harmune.app` to launch |
| `HARMUNE_GRAPHICS` | Force `kitty`, `iterm2`, `sixel`, `halfblock` or `none` |
| `NO_COLOR` | Use the `mono` theme |
| `XDG_CONFIG_HOME`, `XDG_STATE_HOME` | Base folders for config, and for history and the last view |

The host's log is at `~/Library/Logs/Harmune/host.log`.

## Tests

```bash
swift test
```

`Tests/TUITests` runs the real store and views on `DemoBackend`. `Scripts/validate-phase0.sh` runs the checks that need a signed host and a subscription, and it plays music, so it isn't part of `swift test`.

## Releasing

Releases need a **Developer ID Application** certificate, which isn't the same as the Apple Development certificate used for local builds.

1. Set the version in `Sources/HarmuneCore/Paths.swift` and update `CHANGELOG.md`.
2. Build, notarize and package. `<profile>` is a keychain profile, created once with `xcrun notarytool store-credentials`:

   ```bash
   Scripts/build-host.sh
   ```

   ```bash
   Scripts/notarize.sh <profile>
   ```

   ```bash
   Scripts/package.sh
   ```

3. Check the result on another Mac or a new user account, including the manual checks in [PHASE0_RESULTS.md](PHASE0_RESULTS.md).
4. To do the same in CI, push a `v*` tag. `.github/workflows/release.yml` lists the secrets it needs and creates a draft release to review.
5. Fill in `Casks/harmune.rb` and copy it to your Homebrew tap.

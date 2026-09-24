<p align="center">
  <img src="Notchly/Resources/Assets.xcassets/AppIcon.appiconset/logo_256x256.png" width="96" height="96" alt="Notchly app icon">
</p>

<h1 align="center">Notchly</h1>

<p align="center">
  A privacy-focused community fork for Apple Music and Codex background tasks.
</p>

<p align="center">
  <a href="https://github.com/Notchly/Notchly"><strong>Original project</strong></a>
  ·
  <a href="https://github.com/beans722/Notchly-whb"><strong>This fork</strong></a>
  ·
  <a href="docs/ARCHITECTURE.md"><strong>Architecture</strong></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.6%2B-black?style=flat-square&logo=apple" alt="macOS 14.6+">
  <img src="https://img.shields.io/badge/SwiftUI-Native-orange?style=flat-square&logo=swift" alt="Native SwiftUI app">
  <img src="https://img.shields.io/badge/Privacy-Friendly-green?style=flat-square" alt="Privacy friendly">
  <a href="https://github.com/beans722/Notchly-whb/blob/main/LICENSE">
    <img alt="License" src="https://img.shields.io/github/license/beans722/Notchly-whb?style=flat-square">
  </a>
</p>

---

## Notchly

**Notchly-whb** is a community fork of [Notchly](https://github.com/Notchly/Notchly). This build focuses on Apple Music and local lyrics, plus Codex background-task status and optional usage-limit display.

## Highlights

- Apple Music playback controls and the currently playing track.
- Optional lyric reading from the visible Music app interface using macOS Accessibility; lyrics stay on this Mac.
- Codex background-task status shown beside the physical notch only while Codex is not frontmost.
- Optional five-hour and weekly usage windows, refreshed at most every five minutes.
- Local Codex activity hooks store status and IDs, never prompt text.

## Codex AI Alerts

Quota sync is **off by default**. In Settings → Codex, enable **Codex Usage Sync**
to show the five-hour and weekly usage windows. Notchly reads the existing
access token from `~/.codex/auth.json` and sends it only to
`https://chatgpt.com/backend-api/wham/usage`, at most once every five minutes.
The token is not copied to app preferences or logs. This endpoint is undocumented
and may change; a window not returned by the service displays as unavailable.

The quota endpoint and window-routing approach were adapted from
[CodexIsland](https://github.com/ericjypark/codex-island), © 2026 Eric Park,
licensed under MIT. See `THIRD_PARTY_NOTICES.md`.

The left side shows Codex's running state only while a task is active and Codex
is not frontmost. The right side reserves space for both quota windows. The
physical camera cutout is measured from the display and kept free of text.
Lifecycle hooks store only local status, session ID, turn ID, and timestamp;
they discard prompt text. A stale active task expires after two hours without
another hook event, so very long silent runs may disappear temporarily.

Enable it in **Settings → Codex**:

1. Install the **Codex Live Activity** hook.
2. Review the hook entries in Codex and start a new task.

## Requirements

- macOS 14.6 or newer.

## V1 Test Download

[Download the Apple silicon DMG](https://github.com/beans722/Notchly-whb/raw/refs/heads/main/Notchly-V1-arm64.dmg).
[Verify its SHA-256 checksum](Notchly-V1-arm64.dmg.sha256).
Drag Notchly into Applications to install it.

This test build is ad-hoc signed and **not notarized by Apple**. macOS may warn
or block it on first launch. Only proceed if you trust this repository and have
verified the downloaded file; otherwise, do not override Gatekeeper. See
[Apple's safety guidance](https://support.apple.com/en-by/102445). The app is
arm64 only. Quota sync is off by default and requires explicit opt-in.

## Build From Source

```sh
git clone https://github.com/beans722/Notchly-whb.git
cd Notchly-whb
open Notchly.xcodeproj
```

In Xcode, select the **Notchly** target → **Signing & Capabilities** and choose
your own Apple development team. Do not add a personal Team ID to the shared
project. Then build and run with **Product → Run**. On first launch:

- Grant Accessibility access only if you want local Apple Music lyrics.
- Install the Codex Live Activity hook from Settings → Codex.
- Leave Codex Usage Sync off unless you want to send the existing Codex access
  token to the endpoint above.

For command-line builds, supply your own team identifier:

```sh
xcodebuild -project Notchly.xcodeproj -scheme Notchly -configuration Release \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates build
```

## Dependencies

- [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) for overlay windows.
- [mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter) for Now Playing / MediaRemote access.

## Contributing

Pull requests are welcome.

Please keep platform integrations isolated, avoid committing local signing changes, and make sure the app builds before opening a PR.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

This fork is released under the MIT License. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for required attribution.

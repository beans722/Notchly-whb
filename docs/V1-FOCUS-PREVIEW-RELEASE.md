# Notchly V1 Focus Preview

This is a free, open-source macOS test build for friends. Choose the DMG for
your Mac: `arm64` for Apple silicon or `x86_64` for Intel. Requires macOS 14.6
or newer. The focus pets unlock after 15 accumulated minutes in this preview;
this is a tester policy, not the planned 10-hour / 100-hour public thresholds.

## Install

1. Download the matching DMG **and** its `.sha256` file from this Release.
2. In Terminal, verify the pair in your Downloads folder:

   ```sh
   cd "$HOME/Downloads"
   shasum -a 256 -c Notchly-V1-focus-preview-arm64.dmg.sha256
   ```

   For an Intel Mac, replace `arm64` with `x86_64`. Continue only if it says
   `OK`. Open the DMG and drag `Notchly.app` to Applications.
3. Try to open Notchly. Because this test build is ad-hoc signed and **not
   notarized**, macOS may block its first launch. If that happens, open System
   Settings → Privacy & Security and use **Open Anyway** for Notchly, then
   confirm. This creates an exception for this app; do not disable Gatekeeper
   globally.

If the verified app still cannot be opened and you trust this exact download,
this is the **last-resort** command for an app already copied to Applications:

```sh
sudo xattr -dr com.apple.quarantine "/Applications/Notchly.app"
```

It removes quarantine from **only** `/Applications/Notchly.app` and bypasses
macOS first-open screening for that copy. It does not repair a damaged app or
an embedded framework signature mismatch. Do not run it against an unverified
download. Do not run `sudo codesign --force --deep --sign -` on an installed
copy: re-signing changes the shipped binary's identity and can break nested
code or macOS permission grants. If the app still quits on launch, capture the
full macOS crash report instead of repeatedly overriding protection.

## Packaging and privacy

Both DMGs contain an ad-hoc signed app and bundled
`MediaRemoteAdapter.framework`; both pass `codesign --verify --deep --strict`.
The no-account test packaging script disables Hardened Runtime so the earlier
Library Validation / unmatched-Team-ID startup crash does not apply to these
bundles. This also reduces code-injection protection, so only run a build you
trust. This is **not** equivalent to Apple Developer ID signing or notarization.

Codex usage sync is off by default. If you turn it on, Notchly reads your
local Codex access token and requests the five-hour and weekly windows from
`chatgpt.com/backend-api/wham/usage` at most every five minutes. Local task
hooks do not store prompts. Apple Music lyrics are read locally when available.

Source, build script, license, and third-party notices are in the repository.

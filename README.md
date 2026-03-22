# OneBtnVoice

`OneBtnVoice` is a native macOS dictation utility for Apple Silicon. Hold a global hotkey, speak, release the key, and the app transcribes locally with Whisper and pastes the result into the active text field.

## Current status

This repository contains the initial implementation of the architecture and app shell:

- native menu bar application built with `SwiftUI + AppKit`
- layered modules: `Domain`, `Application`, `Infrastructure`, `Presentation`
- local speech-to-text adapter wired for `WhisperKit`
- hold-to-talk hotkey flow for `Right Command`
- overlay UI, permissions flow, accessibility insertion, clipboard fallback
- install and uninstall scripts for local Git-based usage

The project is intentionally open-source friendly and unsandboxed for v1 so it can work with system-wide hotkeys and cross-app insertion.
`Launch at login` is best-effort in local ad-hoc installs. If macOS rejects it, dictation will still work and the app will show a message in Settings.

## Requirements

- Apple Silicon Mac
- macOS 14+
- Command Line Tools for terminal builds
- full Xcode 15+ recommended for IDE work and debugging
- Command Line Tools
- microphone access
- accessibility access
- input monitoring access

## First-time setup

1. Install Command Line Tools if needed:

```bash
xcode-select --install
```

2. Optional but recommended: install full Xcode from the App Store for debugging and package browsing.
3. Clone and install:

```bash
git clone <your-repo-url>
cd oneBtnVoice
./Scripts/install.sh
```

4. Launch `OneBtnVoice.app`.
5. Open Settings from the menu bar and grant permissions.
6. Focus any normal text field, hold `Right Command`, speak, then release it to insert the transcript.

## Development

Open the package in Xcode:

```bash
open Package.swift
```

Or build from the terminal:

```bash
swift build
swift test
```

For fast local UX iteration, use:

```bash
./Scripts/dev-reinstall.sh
```

This script:
- stops the running app
- rebuilds and reinstalls it
- launches it again

The reinstall flow updates the existing `.app` bundle in place instead of deleting it first. That gives macOS a better chance to keep previously granted Accessibility/Input Monitoring permissions during rapid local iteration.

### Stable permissions during development

If you reinstall the app often, macOS can ask for `Accessibility` and `Input Monitoring` again when the app is only ad-hoc signed. To make permissions stick across reinstalls, use a stable `Apple Development` signing identity.

The install script now does this automatically if your Mac already has an `Apple Development` certificate. If `security find-identity` still returns nothing, the script also tries to find the certificate label directly and sign with it.

You can also force a specific identity:

```bash
ONEBTNVOICE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/install.sh
```

To see available code-signing identities on your Mac:

```bash
security find-identity -v -p codesigning
```

If this command prints `0 valid identities found`, the script will fall back to ad-hoc signing, and repeated permission prompts are still expected during active development.

If signing fails and macOS shows a keychain access prompt, choose `Always Allow`, then run the install again.

## Known limitations in this initial version

- The `Right Command` single-modifier hotkey works through event monitoring, but some apps or system states can still require the fallback hotkey.
- The Whisper adapter is designed for `WhisperKit`; if WhisperKit changes its API, the adapter may need a small update.
- The app bundle is produced by the install script; notarization and signed DMG distribution are not included yet.

# Storybird

Storybird is a local-first macOS recorder that turns a real product walkthrough
into an interactive demo. Select a display or window from live thumbnails,
click through the product, then edit, preview, and export the generated flow.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138)](Package.swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## What Storybird Does

- Shows live thumbnails for recordable displays and unfocused windows.
- Captures the starting screen and the result of every mouse click.
- Converts each click into a hotspot targeting the next captured screen.
- Provides a visual editor, branching targets, and interactive preview.
- Records local preview analytics.
- Exports a standalone HTML demo with no server dependency.
- Stores all projects and assets locally in Application Support.

Storybird does not record keyboard input and has no account, cloud upload,
telemetry, CRM integration, video output, or HTML/DOM capture.

## Requirements

- macOS 14 or later
- Xcode 16 or later
- Screen Recording permission
- Input Monitoring permission for mouse clicks only

## Build and Run

```bash
swift build -c debug
swift test
./build.sh release
open build/Storybird.app
```

Run the app bundle rather than `swift run` when testing permissions. macOS ties
Transparency, Consent, and Control (TCC) grants to the bundle identifier and
code-signing requirement.

`build.sh` prefers a `Developer ID Application` or `Apple Development`
certificate. Override it with:

```bash
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" \
  ./build.sh release
```

Without a certificate, the script falls back to ad-hoc signing and macOS may
ask for permissions again after every rebuild.

Install the current build into `/Applications` with:

```bash
./install.sh
```

## Record a Flow

1. Click **Record Flow**.
2. Choose an entire display or an open window from the thumbnail gallery.
3. Use the selected product normally. Pace clicks long enough for each result
   screen to settle.
4. Click **Stop** in the floating Storybird control.
5. Edit screen titles, captions, hotspot behavior, and target screens.
6. Preview the flow or export it as static HTML.

Clicks outside the selected source are ignored. The editor and floating
recording HUD are excluded from captured content.

## Local Data

Projects live under:

```text
~/Library/Application Support/Storybird/
├── library.json
└── Assets/
    └── <project-id>/
        └── <capture>.png
```

When Storybird is first launched after the rename, it copies an existing
`~/Library/Application Support/OpenLane` library only if a Storybird library
does not already exist. The OpenLane copy is never moved or deleted.

Static exports contain an `index.html`, `demo.json`, and only the assets used by
the selected demo.

## Permissions and Privacy

Screen Recording is needed to generate the source gallery and capture selected
content. Input Monitoring is used only for global mouse-down events; Storybird
never observes keyboard events.

Captured screens can contain sensitive product or customer data. Storybird
keeps them on the Mac, but an exported demo intentionally copies its selected
screens to the export folder. Review exports before sharing them.

See [Troubleshooting](docs/Troubleshooting.md) for permission loops, empty
galleries, missing clicks, signing identity checks, and Gatekeeper warnings.

## Architecture

- `Storybird`: SwiftUI, AppKit, ScreenCaptureKit, permission and session
  orchestration.
- `StorybirdCore`: models, persistence, coordinate conversion, analytics, and
  static export.
- `docs/adr`: decision records for recording, authoring, library, and sharing.

The detailed contributor contract and architecture invariants are in
[AGENTS.md](AGENTS.md). Development workflow, smoke tests, commits, and pull
requests are covered by [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).

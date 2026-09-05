# Repository Guidelines

This is the agent-facing contract for Storybird. Keep the contributor-facing
documents aligned when a rule changes:

- [`README.md`](./README.md): product, installation, permissions, and usage
- [`CONTRIBUTING.md`](./CONTRIBUTING.md): build, tests, smoke checks, commits
- [`docs/Troubleshooting.md`](./docs/Troubleshooting.md): symptom-based recovery
- [`docs/adr/`](./docs/adr/): architectural decisions and rejected alternatives

## Project Structure & Module Organization

Storybird is a local-first SwiftUI macOS application.

- `Sources/Storybird/`: UI, ScreenCaptureKit coordination, recording lifecycle.
- `Sources/StorybirdCore/`: models, timeline validation, persistence, geometry.
- `Sources/StorybirdMCPKit/`: stdio MCP tools and capture/pointer contracts.
- `Sources/StorybirdMCP/`: companion executable entry point.
- `Tests/StorybirdCoreTests/`: deterministic XCTest coverage.
- `Tests/StorybirdMCPTests/`: deterministic MCP session and tool-contract coverage.
- `Resources/`: bundle metadata, entitlements, editable SVG app icon.
- `docs/adr/`: ADR registry and decision records.
- `.agents/skills/prepare-storybird-release/`: release audit harness.

Generated artifacts belong in `.build/`, `build/`, and `dist/`. Never edit or
commit them as source.

## Architecture Invariants

Read these before changing capture, persistence, or export behavior.

- **One selected source defines the session.** A recording targets exactly one
  display or one window. Do not silently switch sources after recording starts.
- **The gallery must not require window focus.** Window previews use independent
  window filters. Listing sources excludes Storybird itself, tiny/system utility
  windows, and off-screen windows.
- **Use Quartz coordinates for recorded clicks.** `CGEvent.location` and
  ScreenCaptureKit frames share a top-left capture coordinate system. Do not
  mix them with AppKit's bottom-left screen coordinates.
- **Normalize against the selected capture frame.** Clicks outside the chosen
  source are ignored. Window movement or resize uses the current filter frame
  where the runtime exposes it.
- **One clock defines video and layers.** The first encoded frame starts
  recording time at zero. Every click stores its mouse-down time on that clock,
  its button, and normalized top-left coordinates.
- **Every recording starts a new video project.** Do not append a human or MCP
  recording to the selected project. Publish the project only after the MP4 is
  finalized and validated.
- **Stop closes input before finalization.** Reject new clicks, drain accepted
  pointer commands, stop ScreenCaptureKit, finalize the encoder, then write the
  project library.
- **Capture has no Storybird-owned network path.** Ordinary recording,
  projects, and analytics remain on the Mac. A user-approved active MCP session
  may return only its selected source PNG through authenticated local IPC and
  stdio to the connected MCP client; that client controls any onward model or
  network disclosure.
- **Exclude Storybird controls from capture.** The editor is hidden during a
  session and the floating HUD uses `NSWindowSharingNone`.
- **Actual API results outrank permission preflight.** Attempt ScreenCaptureKit
  access before interpreting `CGPreflightScreenCaptureAccess`; stale TCC state
  must not block a working grant.
- **Stable signing is functional.** `build.sh` prefers Developer ID or Apple
  Development signing for both the app and bundled MCP companion. Ad-hoc
  signing changes the designated requirement and can force permission approval
  after every rebuild.
- **Never record keyboard or audio input.** Input Monitoring exists only to
  timestamp mouse clicks. MCP control may move, click, and scroll the pointer
  but must not observe or synthesize keyboard events. The first version records
  neither system audio nor microphone input.
- **MCP control requires explicit disclosure.** One active session exposes one
  selected display or window to the connected local client and accepts
  normalized pointer movement, left/right click, and scroll only after native
  Storybird approval. The companion has no TCC permission and may call the app
  only through a user-only Unix socket after Team ID and identifier validation.
  Invalid coordinates, missing frames, or missing permissions post no input.
- **Storybird remains the project writer.** The companion must never edit
  `library.json`, raw recordings, or timeline layers directly.
- **Persist projects atomically.** Library JSON writes use atomic replacement.
  A complete project-owned MP4 exists before the project references it; failed
  sessions remove unreferenced partial assets.
- **Preserve legacy data.** On first Storybird launch, copy an existing
  `Application Support/OpenLane` library only when the Storybird library does
  not exist. Never delete or move the legacy copy.
- **Video exports preserve the original.** Read the raw project MP4 and timed
  layers, render a silent H.264 MP4 to a sibling temporary file, then replace
  the chosen destination only after successful completion.
- **Fixed-size sheets scroll internally.** Do not let capture-source content
  resize the sheet beyond the visible display; clipping the last card is a
  regression.
- **Compact windows change navigation, not reachability.** Below the wide-layout
  threshold, hide the project sidebar automatically and move the timeline
  inspector into a sheet. Playback and every layer action remain reachable.

## Build, Test, and Development Commands

- `swift build -c debug`: compile with Swift 6 actor race checks.
- `swift test`: run deterministic unit tests without network access.
- `swift run StorybirdMCP`: run the development companion; privileged capture
  and pointer testing still belongs to the signed Storybird app.
- `./build.sh release`: create and sign `build/Storybird.app`.
- `open build/Storybird.app`: run the bundle that owns macOS TCC permissions.
- `./install.sh`: build and replace `/Applications/Storybird.app`.

Run Storybird as an app bundle, not with `swift run`, when testing Screen
Recording, Input Monitoring, or Accessibility pointer-control permissions.

## Coding Style & Naming Conventions

Use four spaces and standard Swift naming: `UpperCamelCase` types,
`lowerCamelCase` members, descriptive enum cases, and a `View` suffix for
SwiftUI views. Keep UI/AppKit coordination in `Storybird`; keep deterministic
business logic in `StorybirdCore`.

Do not weaken Swift 6 concurrency checks to silence a diagnostic. Preserve
explicit actor isolation and use a lock or actor for callback-owned state.
Comments explain non-obvious permission, timing, coordinate, or data durability
behavior and include measured evidence when one drove the rule.

## Testing Guidelines

Name tests `test_<behavior>_<expectedResult>()`. Tests must not access the
network, real ScreenCaptureKit sources, or the user's actual Application
Support directory. Use temporary directories and measured boundary values.
When adding a regression test, deliberately break the guarded behavior once and
confirm the test fails.

Capture changes require a manual smoke test:

1. Build and open the signed bundle.
2. Verify the gallery shows display and unfocused-window thumbnails.
3. Record visible motion and at least three clicks, then stop immediately after
   the final click.
4. Confirm the new project plays continuous video and all clicks appear in
   timestamp order.
5. Add top and bottom subtitles, edit a click caption, and confirm preview
   timing and placement.
6. Export an MP4 and confirm it contains the motion and overlays but no audio
   track.
7. Rebuild with the same signing identity and confirm permissions persist.

MCP control changes additionally require a signed companion smoke test:

1. Configure the MCP client to launch
   `build/Storybird.app/Contents/MacOS/StorybirdMCP`.
2. List sources and start one synthetic display or window session with explicit
   screen/input acknowledgement.
3. Confirm observe returns only that source, then move, click, and scroll.
4. Stop and confirm Storybird creates one playable video project with ordered,
   non-duplicated timed clicks.
5. Deny Accessibility or use an out-of-range coordinate and confirm no pointer
   event or library change occurs.

## Commit & Pull Request Guidelines

Use Conventional Commits: `<type>(<scope>): <subject>`.

- Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `chore`, `style`,
  `ci`.
- ADR scopes: `recording`, `authoring`, `library`, `sharing`.
- Extra scope: `build`.
- Subjects are English, lowercase, imperative, no period, at most 72 chars.

Behavior decisions update the relevant ADR before code and land together.
Pull requests use a commit-style title and sections for Summary, Motivation,
Verification, and Impact. Include synthetic screenshots for UI changes. Never
attach captured customer screens or exported customer demos.

## Security & Privacy

Never commit recordings, capture thumbnails, generated project libraries,
credentials, or files from `~/Library/Application Support/Storybird`. Treat any
change that expands permissions, storage scope, export content, or network
access as a security-sensitive behavior change requiring an ADR.

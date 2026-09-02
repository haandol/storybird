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
- `Sources/StorybirdCore/`: models, persistence, geometry, analytics, export.
- `Tests/StorybirdCoreTests/`: deterministic XCTest coverage.
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
- **A click connects the previous screen to the resulting screen.** Persist the
  post-click frame, then add a hotspot on the previous step targeting it.
- **Serialize click persistence.** Rapid clicks may queue, but project mutation
  remains ordered. Stop rejects new clicks and awaits the pending queue.
- **Capture remains local.** No screenshot, click event, project, or analytics
  event may leave the Mac. Network access is not part of the product.
- **Exclude Storybird controls from capture.** The editor is hidden during a
  session and the floating HUD uses `NSWindowSharingNone`.
- **Actual API results outrank permission preflight.** Attempt ScreenCaptureKit
  access before interpreting `CGPreflightScreenCaptureAccess`; stale TCC state
  must not block a working grant.
- **Stable signing is functional.** `build.sh` prefers Developer ID or Apple
  Development signing. Ad-hoc signing changes the designated requirement and
  can force permission approval after every rebuild.
- **Never record keyboard input.** Input Monitoring exists only to observe mouse
  clicks. Do not add key logging.
- **Persist projects atomically.** Library JSON writes use atomic replacement;
  captured assets are written before the project references them.
- **Preserve legacy data.** On first Storybird launch, copy an existing
  `Application Support/OpenLane` library only when the Storybird library does
  not exist. Never delete or move the legacy copy.
- **Static exports are self-contained and inert.** Escape embedded JSON against
  `</script>` termination, use text nodes for user strings, and copy only assets
  referenced by the selected project.
- **Fixed-size sheets scroll internally.** Do not let capture-source content
  resize the sheet beyond the visible display; clipping the last card is a
  regression.

## Build, Test, and Development Commands

- `swift build -c debug`: compile with Swift 6 actor race checks.
- `swift test`: run deterministic unit tests without network access.
- `./build.sh release`: create and sign `build/Storybird.app`.
- `open build/Storybird.app`: run the bundle that owns macOS TCC permissions.
- `./install.sh`: build and replace `/Applications/Storybird.app`.

Run Storybird as an app bundle, not with `swift run`, when testing Screen
Recording or Input Monitoring permissions.

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
3. Record at least three clicks and stop immediately after the final click.
4. Confirm ordered screens and hotspot targets in preview.
5. Rebuild with the same signing identity and confirm permissions persist.
6. Export the demo and open `index.html` locally.

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

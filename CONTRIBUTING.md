# Contributing to Storybird

Issues and pull requests are welcome. Read the
[architecture invariants](./AGENTS.md#architecture-invariants) before changing
capture, permission, persistence, or export behavior.

## Build and Run

Storybird is a Swift Package targeting macOS 14 or later and uses Swift tools
6.2 (Xcode 26 or a compatible Swift 6.2 toolchain). The bundled MCP companion
uses the official Swift MCP SDK pinned by `Package.resolved`.

```bash
swift build -c debug
swift test
./build.sh release
open build/Storybird.app
```

Use the bundle for permission testing. A bare SwiftPM executable does not have
the same stable bundle identity used by macOS Transparency, Consent, and Control
(TCC). The signed companion lives at
`build/Storybird.app/Contents/MacOS/StorybirdMCP`.

Install the current release build with `./install.sh`. Replacing a bundle on
disk does not replace its running process, so quit Storybird before validating a
new build.

### Signing

`build.sh` chooses the first `Developer ID Application` or `Apple Development`
identity in the keychain. Override it when needed:

```bash
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" \
  ./build.sh release
```

Without a certificate the script falls back to ad-hoc signing. The app can
launch, but its designated requirement becomes code-hash-specific, so Screen
Recording, Input Monitoring, and Storybird's Accessibility permission may need
approval after every build. The MCP companion itself receives no TCC grant.

### Replacing the App Icon

Generate the artwork with a character image you have permission to use, review
it at both 1024px and 64px, then save the approved 1024×1024 PNG as
`Resources/AppIcon-generated.png`.

Do not commit the reference character image unless its license explicitly
permits redistribution. Keep `Resources/AppIcon.svg` as the deterministic
fallback used when the generated PNG is absent. Never place API keys in the
repository.

## ADR-First Workflow

Behavior contracts live under `docs/adr/`. Update the relevant ADR before
implementing a changed decision, then land the ADR, code, and tests in one
commit. Bug fixes, formatting, documentation, and behavior-preserving
refactors do not need a new ADR.

An ADR records why a choice won, at least two realistic alternatives, and the
contract a reimplementation must preserve. It does not record file paths,
functions, or schemas already obvious from code.

## Automated Tests

Tests live in `Tests/StorybirdCoreTests/`, `Tests/StorybirdTests/`, and
`Tests/StorybirdMCPTests/` and run with `swift test`. Name them
`test_<behavior>_<expectedResult>()`.

- Do not use real screens, windows, click monitors, user projects, or network.
- Redirect filesystem work to a unique temporary directory.
- Test coordinate and timeline boundaries, persistence, migration, real MP4
  encoding, overlay composition, atomic export replacement, MCP consent,
  pointer ordering, and bundle metadata.
- Match actor isolation in tests; never weaken production annotations.
- Deliberately break a guarded behavior once to prove its regression test fails.

## Manual Smoke Test

ScreenCaptureKit and TCC behavior require a real signed bundle:

1. Open `build/Storybird.app` and grant Screen Recording/Input Monitoring.
2. Confirm the source sheet fits on screen and scrolls internally.
3. Resize the main window to its minimum size. Confirm the project sidebar
   collapses and the timeline inspector opens as a sheet without clipping.
4. Verify thumbnails appear for the display and unfocused app windows.
5. Select a window, create visible motion, perform three clicks, and stop after
   the final click.
6. Confirm the recording created a new video project and did not modify the
   previously selected project.
7. Play the raw video and confirm every click appears at the expected time and
   normalized location.
8. Add top and bottom subtitles and edit click-caption styles.
9. Export an MP4, play it locally, and confirm the overlays are burned in and
   no audio track exists.
10. Import a synthetic narrated MP4 or MOV without granting capture permissions.
    Confirm it creates a new project, **Add Click** places a Cue at the selected
    playhead and frame position, and the external source remains unchanged.
11. Trim or speed-change the imported clip, export it, and confirm one AAC track
    stays synchronized with the edited video. Confirm freeze and full-screen
    card intervals are silent.
12. Open **Voice**, approve the roughly 2 GB model preparation, and confirm the
    1.7B 8-bit MLX runtime becomes Ready. Quit and reopen Storybird, disconnect
    the network, and confirm generation does not download the model again.
13. Import synthetic MP3 and WAV voice references with their exact transcripts.
    Confirm a short but valid external file is accepted, while missing
    voice-rights consent is rejected without creating a profile.
14. Grant Microphone access, record the prompted text for at least 3 seconds,
    preview it, and save it as a voice profile. Deny the permission once and
    confirm Storybird shows recovery guidance without changing a project.
15. Generate two non-overlapping narration clips, preview them, adjust one
    start time and volume, then export. Confirm the final MP4 contains one AAC
    track with the imported source audio and narration at the expected times.
16. Delete a voice profile and confirm existing project-owned narration still
    plays and exports. Delete a narration clip and confirm its project-owned WAV
    is removed.
17. Rebuild and confirm the same signing identity keeps permissions.
18. On first launch after renaming, confirm an OpenLane library is copied while
    the original remains untouched.
19. Configure an MCP client to launch the signed `StorybirdMCP` companion.
20. Start one synthetic source session with explicit acknowledgement, observe
    its PNG, then move, click, and scroll.
21. Stop and confirm Storybird creates one video project with ordered,
    non-duplicated click timestamps.
22. Using an existing voice profile, have MCP create, update, and delete
    narration with project revision checks, then export the result. Confirm MCP
    exposes no tool for profile import, microphone recording, model preparation,
    or profile deletion.
23. Deny Accessibility or submit an out-of-range coordinate and confirm no
    pointer input or library mutation occurs.

Use synthetic content. Never put customer dashboards, messages, credentials, or
other private captures in issues, commits, or pull request attachments.

## Coding Style

Use four spaces and standard Swift API naming. Prefer one primary type per file,
structured concurrency, and explicit actor isolation. Keep editor UI/AppKit
coordination in `Storybird`, deterministic business logic in `StorybirdCore`,
and MCP/capture control in `StorybirdMCPKit`.

Comments explain non-obvious permission, timing, coordinate, and durability
rules. No formatter or linter is configured, so match nearby code and run
`swift build -c debug` to catch warnings.

## Commits

Storybird follows Conventional Commits:

```text
<type>(<scope>): <subject>
```

Types are `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `chore`, `style`,
and `ci`. ADR scopes are `recording`, `authoring`, `library`, and `sharing`;
`build` covers repository and distribution tooling.

Subjects are English, lowercase, imperative, have no trailing period, and stay
within 72 characters. Bodies explain why. One logical change belongs in one
commit; the ADR and implementation of one decision land together.

## Pull Requests

Use a commit-style title and this body:

```markdown
## Summary

## Motivation

## Verification

## Impact
```

List exact commands and manual checks. Include synthetic screenshots for UI
changes and call out permission, storage, bundle identity, and export changes.

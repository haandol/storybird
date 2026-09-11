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

### Prepare, Push, and Publish a Release

For a version tag already prepared on macOS, run this in `.devcontainer`:

```bash
./scripts/push-version.sh 0.1.2
```

Replace `0.1.2` with the prepared version; a leading `v` is also accepted. This
pushes only that existing annotated tag, including its referenced commit. It
does not push a branch or publish a GitHub Release. The script reads the commit
from the tag and checks its bundle version, so it works even after HEAD advances
or while unrelated local files are uncommitted. It needs only the container's
existing shell/Git tools and Git authentication: no ZIP, checksum, `gh` login, or
container rebuild is needed for this command.

An identical remote tag is a successful no-op. Missing tags, version mismatches,
or different remote tags stop without creating, moving, or overwriting tags.
Add `--check` to inspect without pushing; this check also runs on macOS.
Once the tag is pushed, release creation/publication can continue locally with
`gh` using the prepared ZIP and notes.

Prepare the release on macOS using
[the release skill](.agents/skills/prepare-storybird-release/SKILL.md): select the
version, update both bundle version fields, commit the release sources, run tests
and relevant native smoke checks, and build/sign the app from that commit. Package
`build/Storybird-X.Y.Z.zip` and write `build/release-notes-vX.Y.Z.md`, including the
verified ZIP SHA-256. These ignored files must be present in the shared workspace;
they are uploaded as release assets/notes, never committed.

Perform Git pushes yourself inside `.devcontainer`. Release creation/publication
uses `gh` and may run locally on macOS, including by the agent when requested.
Rebuild the container after pulling changes to its Dockerfile (the script requires
`unzip`). Both environments need `git`, `gh`, `jq`, and `unzip`; checksums use
`sha256sum` on Linux or `shasum` on macOS. If needed, run
`gh auth login --hostname github.com` in the environment executing the script.

Set these three values to the macOS preparation results; the example version is
only a placeholder. Do not derive the expected checksum from an unverified ZIP.

```bash
release_version="X.Y.Z"
release_commit="FULL_COMMIT_SHA_FROM_MACOS_PREPARATION"
release_sha256="VERIFIED_ZIP_SHA256_FROM_MACOS_PREPARATION"

# Read-only local and GitHub checks.
bash scripts/publish-release.sh "$release_version" "$release_commit" "$release_sha256"

# In .devcontainer: push only the prepared annotated tag.
./scripts/push-version.sh "$release_version"

# On macOS (or in .devcontainer): create and verify a draft using gh.
bash scripts/publish-release.sh "$release_version" "$release_commit" "$release_sha256" --draft

# Reverify the draft, publish it, and mark it Latest.
bash scripts/publish-release.sh "$release_version" "$release_commit" "$release_sha256" --publish
```

`--publish` can also create the draft and publish in one invocation after the tag
has been pushed. Only `--push` requires Linux; the other modes never push Git refs.
The publisher reads the specified release commit, even if HEAD has advanced or
unrelated files are uncommitted. Only its legacy `--push` mode requires a clean
working tree with the prepared commit at an attached HEAD. Both scripts require
a single `origin` push URL for `haandol/storybird`. The publisher checks the
ZIP checksum, committed/bundled metadata, tag commit, release title/notes and the
downloaded asset before publication. It refuses published versions, mismatched
tags/drafts, force pushes and asset replacement. A matching complete draft can be
resumed with the same command; a partial upload or metadata mismatch stops for
inspection. Push and release publication are separate steps; a failed release
operation leaves the already pushed refs intact.

The publisher does not build, sign, commit, or replace native smoke checks.
The older `publish-release.sh … --push` form also pushes the current branch and
requires the full artifact checks; prefer `push-version.sh` for the tag-only step.
Run the isolated shell regression checks for both scripts with
`python3 scripts/test-publish-release.py`; they use temporary repositories and a
fake GitHub CLI, without contacting GitHub.

Release fact collection is read-only and runs with Python 3 on macOS:

```bash
.agents/skills/prepare-storybird-release/scripts/collect_release_facts.sh --target v0.1.2 --online --json
python3 scripts/test-collect-release-facts.py
```

Local tags, remote tags and GitHub publication are reported separately. Without
an online lookup, or if it fails, publication stays `unknown`; a local tag does
not imply a published release. Comparisons use a reachable previous published
release, and report missing history instead of silently choosing a local tag.

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

### MCP support is part of feature completion

Implement MCP support with every feature, including added editable properties.
Follow the [MCP feature completion gate](AGENTS.md#mcp-feature-completion-gate)
and update the [feature inventory](docs/MCPFeatureParity.md) in the same change.
Trace each user action through the public schema, app handler and shared editor
to its saved result. A tool name alone does not prove parity.

Cover the supported properties and successful behavior, plus relevant revision
conflicts, invalid requests, atomic failure and undo. Changes to the public
protocol also need a production-handler/client test. Run `swift test`; for a
focused check during development:

```bash
swift test --filter 'MCPFeatureParityTests|MCPAudioProtocolTests|AgentProductionTests|ProjectAudioTests'
```

Native permission/file/voice/Settings boundaries retain their owning ADR rules.
Document those exceptions and view-only equivalents in the inventory. Any new
exception or broader permission needs the ADR gate. Unexplained MCP omissions
block feature completion; automated inventory checks do not replace reviewing
new UI actions. Include the tool/argument mapping and executed checks in the PR.

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
   Confirm project details start with an empty video area. Show and hide the
   preview repeatedly, drag its boundary in both directions, and resize the
   window. The hidden preview gives all remaining height to the timeline;
   playback controls and the final layer remain reachable without a project edit.
4. Verify thumbnails appear for the display and unfocused app windows.
5. Select a window, create visible motion, perform three clicks, and stop after
   the final click.
6. Confirm the recording created a new video project and did not modify the
   previously selected project.
7. Play the raw video and confirm every click appears at the expected time and
   normalized location.
8. Add top and bottom subtitles and edit click-caption styles.
   Overlap several Click Cues, subtitles, audio layers, and different effects.
   Confirm non-overlapping layers share rows and overlapping blocks remain
   independently reachable. Use the arrow beside Clicks, Subtitles, Audio, or
   Effects to expand that kind into individual rows, then compact it again.
   Verify view changes do not modify project data or undo. Confirm the last row
   is reachable by vertical scroll in wide and compact layouts.
   Drag a block in both modes and verify constant
   duration, correct scene ownership, one saved revision, and one-step undo.
   Drop outside the project or into a conflicting effect and confirm unchanged timing.
9. Export an MP4, play it locally, and confirm the overlays are burned in and
   no audio track exists.
10. Import a synthetic narrated MP4 or MOV without granting capture permissions.
    Confirm it creates a new project, **Add Click** places a Cue at the selected
    playhead and frame position, and the external source remains unchanged.
11. Trim or speed-change the imported clip, export it, and confirm one AAC track
    stays synchronized with the edited video. Confirm freeze and full-screen
    card intervals are silent.
12. Open **Settings › Voice**, approve the roughly 2 GB model preparation, and
    confirm the 1.7B 8-bit MLX runtime becomes Ready. Quit and reopen Storybird,
    disconnect the network, and confirm generation does not download the model
    again.
13. Choose a specific input device, reopen Storybird, and confirm the choice is
    retained. Disconnect it and confirm Settings keeps the selection while
    reporting that the system default will be used; reconnect it and confirm it
    becomes active without reselecting. Output-only devices must not appear.
14. Open **Create Voice Profile…** below the profile list. Confirm name,
    reference language, and consent appear only in the creation sheet. Select
    **Import File** and import synthetic MP3 and WAV references with their exact transcripts.
    Confirm a short but valid external file is accepted, while missing
    voice-rights consent keeps both import and recording disabled and creates
    no profile. File selection alone must not save a profile. **Create Profile**
    must save once, close the sheet, and update the list. Saving disables close
    and duplicate creation; a save failure preserves inputs and shows an inline error.
15. Select **Record**, grant Microphone access, and confirm the recording sheet shows the
    full prosody prompt, recording state, live waveform, elapsed time, and the
    10-second boundary. Pause and resume once, then preview and save a recording
    of at least 10 seconds. Confirm a shorter sample cannot be finalized.
    Deny the permission once and confirm Storybird shows recovery guidance
    without changing a project. Cancel during recording or after preview and
    confirm the sheet closes, microphone input stops, and no profile is added.
    Reopen creation and confirm it starts with a fresh name field and unchecked consent.
16. Open a project’s **Audio** panel and generate two overlapping clips.
    Drag one ready card onto an Audio row and add another at the playhead.
    Select a block, drag both trim edges and fade handles, and adjust its volume
    slider. Verify each completed gesture saves once and undo restores it.
    Exercise split, duplicate, mute and delete from the toolbar and right-click
    menu. Double-click generated speech to edit and regenerate one sentence.
    Try a placement past the project end and confirm the ready draft remains.
    Repeat in a compact window, then export. Confirm the final MP4 contains one AAC
    track with the imported source audio and narration at the expected times.
17. Rename a voice profile with its pencil button in Settings. Confirm the new
    name appears in profile selectors and survives restarting, while existing
    narration and reference audio remain unchanged. Reject a blank name, allow a
    duplicate name, and verify Cancel preserves the old name.
    Delete a voice profile in Settings and confirm existing project-owned narration still
    plays and exports. Delete a narration clip and confirm its project-owned WAV
    is retained for reuse and undo.
18. In **Settings › Shortcuts**, change every project shortcut, restart the app,
    and confirm the choices persist. Confirm a modifier-free or duplicate
    shortcut is rejected without replacing the previous working value.
19. Confirm the shortcuts do nothing while another app is active and use the
    same disabled conditions as the toolbar while recording, importing, or
    exporting.
    In **Settings › General › Storage**, select an empty temporary folder and
    confirm it displays its own library. Import a synthetic video, generate
    narration from an existing synthetic profile, export it, and restart.
    Confirm the selected folder and project persist, shared voice assets stay
    in Application Support, and the MCP client lists the selected library.
    Confirm **Use Default** selects `~/Documents/Storybird` and existing
    Application Support projects remain accessible by selecting that folder.
    Restore the default and reselect the custom folder; neither library may
    move or merge. Cancel the picker and try read-only, missing, and malformed
    libraries; selection must remain unchanged. During UI/MCP recording,
    import, export, model preparation, voice input, and narration generation,
    verify that folder controls are disabled with a reason.
20. Rebuild and confirm the same signing identity keeps permissions.
21. On first launch after renaming, confirm an OpenLane library is copied while
    the original remains untouched.
22. Configure an MCP client to launch the signed `StorybirdMCP` companion.
23. Start one synthetic source session with explicit acknowledgement, observe
    its PNG, then move, click, and scroll.
24. Stop and confirm Storybird creates one video project with ordered,
    non-duplicated click timestamps.
25. Using an existing voice profile, have MCP create, update, and delete
    narration with project revision checks, then export the result. Confirm MCP
    exposes no tool for profile import, microphone recording, model preparation,
    or profile deletion.
26. Deny Accessibility or submit an out-of-range coordinate and confirm no
    pointer input or library mutation occurs.

Use synthetic content. Never put customer dashboards, messages, credentials, or
other private captures in issues, commits, or pull request attachments.

## Rendered Authoring Checks

Authoring's opt-in rendering checks use synthetic media and native test windows.
Run them alone so unrelated rendering work does not distort the latency result:

```bash
STORYBIRD_RUN_AUTHORING_RENDER_PERFORMANCE=1 swift test --filter AuthoringRenderPerformanceTests
STORYBIRD_RUN_PREVIEW_FRAME_UI=1 swift test --filter PreviewFrameContractTests/test_nativeUIRenderedBoundaries
```

The first measures decoded frame readiness and rendered subtitle pixels for
100 actions on a 1080p, 120-second, 100-layer project. The second compares native
UI, PNG and MP4 overlay boundaries at 30, 60 and 120 fps. Ordinary `swift test`
also covers malformed edits, missing frame metadata, legacy data preservation
and production MCP protocol flows.

## Documentation Screenshots

README screenshots are rendered from the real SwiftUI views with a synthetic
temporary Storybird library. Regenerate them without opening customer projects:

```bash
STORYBIRD_UPDATE_DOC_SCREENSHOTS=1 \
  swift test --filter DocumentationScreenshotTests/test_generateSyntheticReadmeScreenshots
```

The harness writes `docs/images/welcome.png`, `docs/images/voice-narration.png`,
`docs/images/voice-profile-creation.png`, `docs/images/storage-settings.png`, and
`docs/images/narration-drafts.png`. Review the generated images before committing them.
Do not replace the synthetic state with an actual recording or project library.

The running-app editor and profile-dialog screenshots use a separate synthetic
demo. See [screenshot sources and reproduction](docs/images/README.md); its
generated video and library stay in `.build/readme-demo/`.

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

## Agent production regression checks

`AgentProductionTests` exercises independent project copies, reusable narration
jobs, revision conflicts, scene timing, text-driven Cue edits and composited
preview with temporary synthetic media. `SceneTimingTests` covers movement,
split boundaries, trim/delete, freeze segments, cards and legacy decoding.

For changes to this workflow, verify that a failed placement keeps its ready WAV,
that undo never points at a deleted generated WAV, and that a text-only edit
preserves the target's unrequested properties. Keep the public tool table in
`docs/MCP.md` and the repository's `create-storybird-video` skill aligned with the
actual advertised tools. Use synthetic documentation screenshots for UI changes.

### Independent audio layers

Use synthetic tones to check overlap, trim, fade, mute, amplification, waveform
inspection and AAC output (`swift test --filter ProjectAudioTests`). Keep real
microphone samples and user voice profiles out of fixtures. The prompt-to-video
production regression uses a deterministic local TTS provider through actual MCP
host commands. Native microphone smoke checks must use the signed app and a user's
explicit Start Recording action; verify mutual exclusion with screen/profile recording.

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
- `Tests/StorybirdTests/DocumentationScreenshotTests.swift`: opt-in synthetic
  README screenshot harness.

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
- **Screen recording never records keyboard or audio input.** Input Monitoring
  exists only to timestamp mouse clicks. MCP control may move, click, and scroll
  the pointer but must not observe or synthesize keyboard events. A user-selected
  imported movie may contain one primary audio track. The microphone is used only
  during explicit native voice-profile or independent project-audio recording and never during capture.
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
- **Project folder changes preserve each library.** Native Settings may select a
  persistent project root or restore the default. Validate before switching;
  never move or merge existing projects. Block changes throughout UI/MCP
  recording, import, export, and voice work. Unavailable or damaged folders keep
  the selection and report an error; never silently write to a fallback folder.
  The default project root is `~/Documents/Storybird`. Existing projects are not
  moved; select their previous folder to access them. Shared voice profiles,
  models, and the MCP socket stay in `~/Library/Application Support/Storybird`.
- **Preserve legacy data.** On first Storybird launch, copy an existing
  `Application Support/OpenLane` library only when the Storybird library does
  not exist. Never delete or move the legacy copy.
- **Video exports preserve the original.** Read the raw project MP4 and timed
  layers, render an H.264 MP4 to a sibling temporary file, and preserve one
  imported primary audio track plus project-owned cloned-voice narration as one
  synchronized AAC track when present. Replace the chosen destination only after
  successful completion.
- **Voice cloning is local and user-authorized.** The approved PoC uses the MLX
  Qwen3-TTS 1.7B Base 8-bit model on 24GB+ Apple Silicon. Model download,
  microphone capture, voice-profile reference-file selection, and profile deletion require native
  user action. MCP may use existing profiles but never register or delete them.
- **Narration timing is explicit.** Existing layers remain at fixed project
  times; new scene-linked narration and subtitles follow their start frame through
  clip edits without changing speech or display duration. Removing the start or
  owner excludes the layer but retains audio for undo. Allow overlapping audio layers; reject out-of-project results atomically.
- **Audio assets and layers are separate.** Generated speech, user-imported WAV/MP3/M4A,
  and native project voice recordings become complete project-owned audio assets.
  Registration does not advance edit revision. Layers reuse source ranges and allow
  overlap, trim, split, duplicate, gain, mute, and linear fades. UI and MCP share the
  same validation, preview mix, and export mix. Never delete audio required for undo.
- **Microphone sessions are exclusive.** Native profile and project recordings share
  one microphone lease acquired before requesting permission. Screen recording and
  another microphone session cannot start until it is released. MCP cannot start a
  microphone or choose a voice-profile reference file.
- **MCP imports local media without additional approval.** An authenticated local
  connection may pass an absolute MP4/MOV or WAV/MP3/M4A path readable by the app.
  Do not require a native file picker, folder grant, or screen-control session.
  Storybird copies and validates the media: video creates a new project, audio
  registers a reusable asset in the specified project without advancing revision.
  Import jobs and request keys stay in the selected library. Replays return the
  same job, conflicting inputs fail, cancellation preserves existing data, and
  interrupted jobs never automatically rerun. Reference-profile management and
  microphone actions retain their native boundaries.
- **Ready narration drafts survive placement failure.** Generate and validate the
  local WAV before placement. Draft metadata does not advance edit revision;
  placement and consumed state commit together exactly once. Interrupted jobs
  fail on restart and never auto-run. Drafts stay with their project library.
- **Duplicated projects own their media.** Copy and validate the source video and
  placed narration before publishing revision zero. Preserve the source, and do
  not copy unplaced drafts or undo history.
- **Shared voice assets live in Settings.** Model preparation, voice-profile
  creation/renaming/deletion, and the guided-recording input device are managed in
  Settings. Project UI uses existing profiles only for narration generation.
  Persist a selected microphone by stable UID; if it is absent, keep the choice
  and use the system default for that recording. Never switch an active sample.
- **Profile renaming changes display metadata only.** Native Settings trims the
  new name, rejects blanks, allows duplicate names, and publishes only after atomic
  persistence. Preserve identity, reference assets, and project narration; keep
  draft input and show an inline error on failure. MCP cannot rename profiles.
- **Voice profile creation owns a separate sheet.** Voice settings shows the
  profile list and a creation button below it. Enter the name, language, consent,
  and recording or import inputs in the sheet. Close after successful save or
  cancellation; cancellation stops input and discards temporary samples. Keep
  inputs and inline errors after failure, and block duplicate save and dismissal
  while saving.
- **Select the voice device before reading its format.** Applying a different
  microphone can change sample rate and channel count. Verify the AudioUnit
  readback, tap the selected device's input format, rebuild conversion if the
  callback format changes, and save every guided sample as 24kHz mono 16-bit
  WAV. Meter the actual interleaved or deinterleaved capture buffer; a callback
  alone does not prove that non-silent audio arrived.
- **Core Audio callbacks are not MainActor callbacks.** Install microphone tap
  closures from an explicit nonisolated boundary and hand audio only to
  lock-protected Sendable state. A tap closure that inherits MainActor
  isolation traps on Core Audio's realtime queue under Swift 6.
- **Project shortcuts stay local and equivalent.** New project, record/stop,
  import, and export shortcuts work only while Storybird is active, persist
  across launches, reject invalid or duplicate combinations, and use the same
  availability and approval rules as their visible controls. Do not add global
  keyboard monitoring or keyboard-related permissions.
- **Fixed-size sheets scroll internally.** Do not let capture-source content
  resize the sheet beyond the visible display; clipping the last card is a
  regression.
- **The Settings window stays fixed-size and scrolls by tab.** Do not resize it
  from tab content or let the final voice/shortcut control become unreachable.
- **Compact windows change navigation, not reachability.** Below the wide-layout
  threshold, hide the project sidebar automatically and move the timeline
  inspector into a sheet. Playback and every layer action remain reachable.
- **Preview space is a local view choice.** Start with an empty video area,
  allow preview display and repeated hiding, and give hidden preview space to
  timeline layers. Dragging the boundary resizes the viewports, not layer rows.
  Keep playback and layer scrolling reachable in both window layouts without
  changing project data, revision, or undo.
- **Timeline rows are a view of independent layers.** Click Cue groups, subtitles,
  audio, and effects reuse non-overlapping rows by default. Each kind's disclosure
  control toggles individual rows without changing project data, revision, or undo.
  Touching endpoints share a row. Keep row placement fixed during a drag and
  recompute it afterward. All blocks remain selectable with internal scrolling.
  Horizontal block drags preserve duration, reanchor scene-linked content, and
  commit once on release through revision validation and one undo entry. Invalid
  moves retain the stored project; video sequencing and suggestion application
  keep their existing controls and rules.
- **Audio editing stays beside the timeline.** Audio cards expose completed assets
  and ready drafts, with preview, drag placement and add-at-playhead. Trim edges,
  fade handles and volume sliders preview locally and commit once through revision
  validation and one undo entry. Keep numeric details and text regeneration reachable.
  Invalid ranges, stale edits and failed saves preserve the project and ready drafts.

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

### Release execution

Follow the requested outcome: preparation stays local, an explicitly requested
draft stays a draft, and registering/publishing a prepared release proceeds
through `--publish` to public Latest status. Reuse authorization and verified
artifacts for the same target. Report unperformed native or optional checks
honestly; their absence alone must not downgrade a publication request to a draft.
Resolve actual build/test/signature failures, tag/version/checksum conflicts,
upload or remote-state errors, and known data-loss/security defects. Honor any
checks the user explicitly makes a prerequisite for that release. Git pushes
remain the user's action in `.devcontainer`.

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

### MCP feature completion gate

Every feature implementation must include its MCP support and verification in
the same change. Review user actions and editable properties, not just tool names.
The existing project-editing ADR requires full UI/MCP editing parity.

- Before implementation, map each changed action/property to an advertised MCP
  tool, its arguments, app handler, shared validation and observable result.
  Maintain the inventory in [`docs/MCPFeatureParity.md`](./docs/MCPFeatureParity.md).
- Implement missing MCP paths alongside the UI. Reuse app-owned domain edits,
  revision checks, atomic persistence and undo; never bypass them with direct
  library writes or UI automation.
- Native-only consent, voice-profile reference-file selection, microphone, voice-profile/model
  management and Settings remain subject to their owning ADRs. View-only controls
  may use an equivalent preview/edit tool without reproducing the window gesture.
  Record the exact exception and its owner; do not label ordinary editing
  omissions "UI-only". A new exception or permission expansion needs the ADR
  admission/confirmation gate before implementation.
- Add or update schema/property coverage in `MCPFeatureParityTests` and behavior
  tests through the app host. For changed public protocol behavior, exercise the
  production MCP handlers with an MCP client, as in `MCPAudioProtocolTests`.
  Verify the successful result plus relevant stale revision, invalid input,
  partial-save prevention, undo and async terminal states. Tool existence alone
  is not behavior evidence.
- Keep `docs/MCP.md`, the feature inventory, README guidance and the video
  production skill aligned when affected. Run `swift test` and applicable signed
  smoke checks. Report unverified native/runtime checks explicitly.
- Do not mark a feature complete with an unexplained MCP gap or failing parity
  check. The PR must state the MCP path, test evidence and any ADR-backed
  exception. Passing inventory tests does not discover new UI actions; reviewers
  must compare the changed UI and domain behavior with the inventory.

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
6. Export a direct recording and confirm it contains the motion and overlays
   but no audio track. Import a synthetic narrated MP4 or MOV and confirm its
   export contains one synchronized AAC track.
7. Create a local voice profile from MP3/WAV and from the guided microphone
   prompt in Settings. Confirm both entry buttons stay disabled until voice-use
   consent is checked. Select a microphone, verify restart persistence, and
   verify disconnected-device fallback preserves the choice. Confirm the
   recording screen shows the full script, live input waveform, elapsed time,
   pause/resume, and the 10-second boundary. Generate narration through the
   project UI and MCP, and confirm export mixes it at the selected time. Change
   one sentence and confirm only its WAV is regenerated. Delete the profile and
   confirm project narration remains.
8. Change every project shortcut, restart, and confirm persistence. Reject a
   modifier-free or duplicate shortcut and confirm no action fires while the
   shortcut field is recording.
9. Rebuild with the same signing identity and confirm permissions persist.

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

UI documentation changes use synthetic views only:

```bash
STORYBIRD_UPDATE_DOC_SCREENSHOTS=1 \
  swift test --filter DocumentationScreenshotTests/test_generateSyntheticReadmeScreenshots
```

Review `docs/images/welcome.png`, `docs/images/voice-narration.png`,
`docs/images/voice-profile-creation.png`, and `docs/images/storage-settings.png`; never
substitute a customer recording or real project library.

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
credentials, or files from `~/Documents/Storybird` or
`~/Library/Application Support/Storybird`. Treat any
change that expands permissions, storage scope, export content, or network
access as a security-sensitive behavior change requiring an ADR.

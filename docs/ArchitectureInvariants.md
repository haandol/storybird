# Architecture Invariants

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
- **Voice cloning is local and user-authorized.** The approved PoC uses MLX
  Qwen3-TTS 1.7B or 0.6B Base, both 8-bit, on 24GB+ Apple Silicon. UI and MCP share
  model status, persistent selection and preparation. The UI preparation button
  or authenticated MCP preparation request starts download without another approval.
  Microphone capture, voice-profile reference-file selection and profile deletion
  retain native user action. MCP may use existing profiles but never register or delete them.
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

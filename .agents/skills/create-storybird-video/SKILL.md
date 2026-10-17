---
name: create-storybird-video
description: Create or edit Korean or English videos through Storybird and verify the exported MP4. Use for video production, not app development or release.
---

# Create a Storybird video

Complete the requested video or edit through Storybird. Infer the project,
language, output path and result from context; ask only when missing information
prevents starting or leaves the target or meaning ambiguous.

## Read only the needed workflow

Discover the connected tools first; an installed app does not prove a connection.
Use live schemas and the relevant sections of [MCP.md](../../../docs/MCP.md) for
field details. Choose the references needed by the actual request:

- **Existing project or visual edits:** read [editing.md](references/editing.md).
  For caption text, style, timing, SRT or verification, also read
  [subtitles.md](references/subtitles.md). Resolve one-based scenes and layer IDs
  with `storybird_get_edit_context`; do not record or generate speech unnecessarily.
- **New source material:** use [recording.md](references/recording.md) for a new
  recording, or [importing.md](references/importing.md) for local video, audio or
  additional video/image assets. A recording creates a separate project.
- **Narration or audio:** read the relevant sections of [audio.md](references/audio.md).
  Existing sound edits do not require model preparation or a new voice profile.
- **Another language version:** duplicate the project, then translate and edit
  the copy using the editing, audio and subtitle guidance that applies. Do not
  assume translated speech has the same duration.

For a new production, make a short shot list of actions, visible results and any
requested narration. Introductions emphasize benefit and outcome; tutorials
retain the steps viewers must reproduce. Use synthetic demo data and respect
the user's existing limits on external actions.

## Use app-owned edits

Compact is the default and only tool catalog. Use an explicit `action` (`kind`
for visual-effect creation and card insertion), with `project_id` and
`expected_revision` at the top level and operation fields in `input`.
History operations use `input: {}`. The [catalog table](../../../docs/MCP.md#compact-tool-catalog)
maps actions; replaced individual tool names are unsupported.

Use targeted edits and preserve unspecified text, style, voice, timing, IDs and
source media. For multiple targets that must succeed together, send explicit
`target`, `id`, `action` and changed `values` to `storybird_preview_edits` and
`storybird_apply_edits` with the same current revision. Preview never writes and
its generated IDs are provisional. Use IDs and the next revision returned by a
successful apply. Rejection saves no partial result; success is one undo unit.

On a conflict or ambiguous response, read current state and recompute instead of
blindly repeating a mutation. Never write the project library directly or
synthesize editor shortcuts: agents use the shared edit and preview tools.

## Verify and deliver

For captions, follow the complete source-text and style checks in
[subtitles.md](references/subtitles.md), including the read-only checker.
Inspect composited frames at changed scenes and overlay boundaries for text,
clipping, Cue completeness and placement. Still frames cannot verify speech or motion.
Start export and poll until completed, failed or cancelled; queued is not complete.
Preserve the project on failure and choose a bounded repair from the reported cause.

Verify the MP4 exists and opens, check duration and audio presence with available
media tools, and inspect playback or representative frames. Report the path,
language, duration and any unverified listening or motion checks. Keep language
exports distinct.

## Respect the action boundary

Model operations use the advertised MCP tools and the readiness/removal rules
in [audio.md](references/audio.md). Profile management, microphone input and
voice-profile reference-file selection remain native user actions. Local media
imports need no additional picker or folder approval. Recording auto-approval
is off by default and changes only on the user's request; follow
[recording.md](references/recording.md). Storybird controls only the pointer; a
separately authorized browser may supply text input to the same captured window.

For explicitly requested permanent project deletion, inspect its ID, name and
revision and ensure the user's request or approval covers that project and owned
assets. Reuse matching approval. Call `storybird_delete_project` with
`confirmed: true` and `expected_revision` to confirm through the agent without
an app popup. Never treat agent judgment or authentication as user consent.
`confirmed: false` cancels; omit it only for a native prompt. Deletion cannot be
undone. Inspect `project_removed` and `assets_removed` and report cleanup failures.

For app-version troubleshooting, `storybird_get_update_status` reads cached status.
Use `storybird_check_for_updates` only for a requested version check, then poll;
it fetches public GitHub metadata and never installs software or changes projects.
Do not add update checks to ordinary video production.

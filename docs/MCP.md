# Storybird MCP

Storybird ships a local stdio MCP companion. The companion has no Screen
Recording, Input Monitoring, or Accessibility permission. It forwards requests
through a user-only Unix socket, and the Storybird app verifies the peer's code
signing identifier and Team ID before executing commands.

## Install

```bash
./install.sh
```

Merge [`mcp/storybird.kiro.json`](../mcp/storybird.kiro.json) into
`~/.kiro/settings/mcp.json`, then restart Kiro.

Certificate signing is required for external control. Ad-hoc builds can run the
normal Storybird UI but the app rejects MCP IPC because there is no stable Team
ID to authenticate.

## Tools

See the [UI/MCP feature inventory](MCPFeatureParity.md) for action coverage,
native-only boundaries, view-only equivalents and regression checks. MCP does
not control every Settings or window action.

| Tool | Result |
|---|---|
| `storybird_list_sources` | Lists eligible displays and windows |
| `storybird_start_session` | Requests native approval and starts one-source video recording |
| `storybird_observe` | Returns the latest selected-source PNG |
| `storybird_move_pointer` | Moves the real pointer through Storybird |
| `storybird_click` | Performs a real left or right click through Storybird |
| `storybird_scroll` | Performs a real wheel event through Storybird |
| `storybird_stop_session` | Drains commands, finalizes the MP4, and saves the video project |
| `storybird_get_edit_context` | Returns one-based scene numbers, clip IDs/times, current text/layers, and the latest project revision |
| `storybird_create_project` | Creates an empty placeholder; later recordings still create separate projects |
| `storybird_duplicate_project` | Copies the video and placed narration into an independent project at revision 0 |
| `storybird_abort_session` | Discards the active incomplete recording; use stop to save it |
| `storybird_create_click` | Adds a Cue with optional description and subtitle text |
| `storybird_delete_click` | Removes a Cue and its suggestion metadata, retaining applied effects |
| `storybird_delete_subtitle` | Removes one independent subtitle |
| `storybird_create_spotlight` | Adds a timed normalized spotlight rectangle |
| `storybird_create_pan_zoom` | Adds a timed camera movement and zoom |
| `storybird_insert_title` | Inserts a title at the beginning or after a nonfinal clip |
| `storybird_insert_cta` | Appends a noninteractive closing card |
| `storybird_update_effect` | Changes only supplied properties of one effect |
| `storybird_delete_effect` | Removes an effect or closes a card's timeline gap |
| `storybird_update_suggestion` | Updates a pending suggestion's split and nested spotlight/pan_zoom properties |
| `storybird_apply_suggestion` | Applies a pending suggestion as one undoable edit |
| `storybird_reject_suggestion` | Rejects a pending suggestion without changing output or edit revision |
| `storybird_start_narration_draft` | Starts local synthesis without placing a layer or incrementing edit revision |
| `storybird_list_narration_drafts` | Lists project-owned generation jobs and measured durations |
| `storybird_get_narration_draft` | Returns generating, ready, failed, cancelled, or placed state |
| `storybird_cancel_narration_draft` | Cancels a running job or discards a ready draft |
| `storybird_place_narration_draft` | Places a ready WAV once using the latest revision and timing mode |
| `storybird_list_projects` | Lists local project models |
| `storybird_get_project` | Returns one editable project model without image bytes |
| `storybird_replace_project` | Validates and atomically replaces editable project properties against the current revision |
| `storybird_split_clip` | Splits one video clip at a source recording time |
| `storybird_trim_clip` | Keeps one source range and removes linked layers outside it |
| `storybird_delete_clip` | Removes one edited clip while preserving the original recording |
| `storybird_move_clip` | Moves one clip to a zero-based timeline index |
| `storybird_set_clip_speed` | Sets one clip from 0.25× through 4× |
| `storybird_insert_freeze` | Inserts a positive-duration still frame after one clip |
| `storybird_undo_project` | Undoes one project edit against the current revision |
| `storybird_redo_project` | Redoes one project edit against the current revision |
| `storybird_update_project` | Updates project name or summary |
| `storybird_update_click` | Edits the complete Cue: timing, indicator, description, subtitle, position, and styling |
| `storybird_upsert_subtitle` | Adds or updates a timed subtitle, including text color and font size |
| `storybird_preview_project` | Opens the native video timeline editor |
| `storybird_render_preview` | Returns a composited project-resolution PNG, visible layer IDs, and incomplete click IDs |
| `storybird_list_audio_assets` | Lists reusable project sounds with measured duration, peak and waveform |
| `storybird_place_audio_asset` | Places an asset source range as a new independent audio layer |
| `storybird_update_audio_layer` | Atomically edits start, source trim, duration, gain, mute and linear fades |
| `storybird_split_audio_layer` | Splits inside an audio layer at project seconds |
| `storybird_duplicate_audio_layer` | Reuses its audio under a new layer ID without TTS generation |
| `storybird_delete_audio_layer` | Removes the layer while keeping the asset for reuse and undo |
| `storybird_set_source_audio` | Changes gain or mute of the original movie audio |
| `storybird_render_audio_preview` | Renders a local mix WAV and returns path, duration, peak and waveform |
| `storybird_list_voice_profiles` | Lists existing profile metadata without reference audio or transcripts |
| `storybird_generate_narration` | Generates and places one local narration using an existing profile |
| `storybird_update_narration` | Changes timing or volume, or regenerates the selected sentence when text is supplied |
| `storybird_delete_narration` | Removes a narration layer while preserving its WAV for undo |
| `storybird_start_export` | Starts an asynchronous MP4 export and returns a job |
| `storybird_get_export` | Returns export state and progress |
| `storybird_cancel_export` | Cancels an active export without replacing an existing output |
| `storybird_export_project` | Renders H.264 MP4 with imported audio and generated narration mixed into AAC when present |
| `storybird_delete_project` | Requests native confirmation before deletion |

Pointer-changing tools can trigger effects in the selected application and
must not be auto-approved. Project deletion also requires a Storybird-native
confirmation.

Every clip mutation includes `project_id`, `expected_revision`, and the target
clip ID. Read the project again after a revision conflict, then recalculate the
edit instead of overwriting the newer UI state.

## Produce a narrated service video

The repository includes a
[`create-storybird-video` agent skill](../.agents/skills/create-storybird-video/SKILL.md)
for service introductions and tutorials. Discover the connected server's tool
schemas before starting; an installed companion does not by itself mean the
current agent has a working connection.

1. Have the user prepare the local voice model and a consented reference profile
   in Settings. Use `storybird_list_voice_profiles` to select an existing profile.
2. Prepare the script and synthetic demonstration data. Choose one visible
   window or display, then start a session with native approval.
3. Observe the selected source, perform the approved pointer actions, and verify
   each expected result. Stop the session and retrieve the saved project.
4. Read `storybird_get_edit_context` to resolve the shot list to scene numbers,
   clip IDs and project times. Trim waits, arrange clips, and add titles/effects.
5. Generate sentence drafts with explicit `language: "korean"` or
   `language: "english"`, poll until ready, then place the measured WAV using the
   latest revision. Use `timing_mode: "scene"` to follow the start scene or
   `"project"` for a fixed time. UI generation also offers Korean and English.
6. Place subtitles at the actual sentence times and inspect composited frames
   with `storybird_render_preview`. Every retained click needs both its
   description and Cue subtitle before export.
7. Start export, poll its job until a terminal state, and inspect the resulting
   MP4. Ask the user to listen to a short voice sample before relying on its
   pronunciation or resemblance for a longer production.

An introduction should show the user benefit and outcome. A tutorial should
preserve the input, action, and visible result needed to reproduce each step.
The agent writes and translates the script; Storybird stores, validates, and
renders it without calling a text-generation service.

### Narration and retries

`storybird_generate_narration` requires `project_id`, `expected_revision`,
`voice_profile_id`, `text`, and `start_time` in project seconds. Specify the
language explicitly instead of relying on its Korean default. To change the
language of an existing sentence, send both `text` and `language` through
`storybird_update_narration`.

For production work, prefer `storybird_start_narration_draft` with `project_id`,
`voice_profile_id`, `text`, and `language`. It returns a `generating` job without
changing the timeline revision. Poll `storybird_get_narration_draft` with
`project_id` and `draft_id` until `ready`, `failed`, or `cancelled`. Actual local
model workers run serially to avoid loading several models at once.

Ready drafts persist across app restarts. Use `storybird_place_narration_draft`
with `project_id`, `draft_id`, `expected_revision`, `start_time`, and optional
`timing_mode`. A duration conflict or stale revision retains the ready WAV.
Edit the scene length or start time and retry placement without regenerating.
Placement atomically creates the layer and marks the draft `placed`; undo does
not make a consumed draft available for duplicate placement. Running jobs become
failed with an interruption reason after restart and never auto-restart.

The legacy `storybird_generate_narration` still generates and places in one call;
its failed placement removes the unreferenced result. Do not issue several
revision-changing placements against the same revision. Read the current project
after a lost response before retrying. Never blindly replay pointer actions.

A scene-linked layer follows its start frame through clip movement, splitting,
trimming and speed changes. Its speech/display duration remains unchanged. A
trimmed-away start or deleted owner removes the layer; undo restores it and its
retained audio. Audio overlap is allowed; project overflow rejects the whole edit. Cards require fixed
project time. Existing files and calls without a timing mode retain fixed time;
updates preserve an existing layer's mode unless explicitly changed. Title edits
shift later layers using the same timing rules as title insertion/removal.

### Edit from the user's text request

`storybird_get_edit_context` returns the full project plus `scenes`. Scene
numbers are one-based clip order, excluding title/CTA cards. Resolve a request
such as “shorten the second scene and change its explanation to English” to
those IDs and current text before editing. Ask only if the intended target or
meaning remains ambiguous. The agent interprets and translates text; Storybird
performs the validated domain edits and never types into the demonstrated app.

| User request | Useful commands |
|---|---|
| Change the second scene's timing | `get_edit_context`, then `trim_clip` or `set_clip_speed` using its `clip_id` |
| Change this click's explanation/subtitle | `update_click` with `description` and/or `subtitle` |
| Change the title or highlight | `update_effect` with the target ID and supplied fields only |
| Rewrite one spoken sentence in English | `update_narration` with `text` and `language: "english"` |
| Keep Korean and English editable versions | `duplicate_project`, then edit the returned new project ID |
| Undo the last edit | `undo_project` using the latest revision |

All command names above have the `storybird_` prefix. Read the live schema for
supported property names. `update_click` supports the indicator, description and
Cue subtitle's independent timing/style fields. `caption` and `background_*`
remain legacy aliases for description properties; explicit description fields
take precedence. `update_effect` accepts only fields applicable to that effect
type. Unknown targets, invalid fields and stale revisions do not partially apply.
Pending suggestion changes/rejection do not change output or edit revision;
applying the suggestion does. Generated WAVs remain project-owned for undo until
project deletion.

### Targeted subtitle edits

Omit `subtitle_id` to create a subtitle. Supply an existing ID to update one;
unknown or malformed IDs are errors. `start_time` and `end_time` are required.
Other omitted properties retain their current values on update:

```json
{
  "project_id": "<project UUID>",
  "expected_revision": 4,
  "subtitle_id": "<existing subtitle UUID>",
  "start_time": 3.0,
  "end_time": 5.5,
  "text": "Create your first project.",
  "position": "bottom",
  "foreground_hex": "#FFFFFF",
  "font_size": 24,
  "background_hex": "#11131A",
  "background_opacity": 0.72
}
```

Invalid timing, position, color, font size, or opacity rejects the entire edit.
For a compound edit requiring properties beyond a targeted command, read the
complete model and use `storybird_replace_project` with the latest revision.
Preserve unrelated fields, IDs, source media and relationships. Draft states are
app-owned and cannot be rewritten through this endpoint. Never edit library
files or project assets directly.

### Recording input and multiple versions

Storybird exposes pointer movement, left/right click, and scrolling. It does not
type into the demonstrated service or record live microphone/system audio.
If a separately authorized browser tool is available, it may prepare or operate
the demonstrated webpage. Verify that it is operating the visible captured
window, not a hidden tab, and avoid controlling the pointer from two tools at once.

Each recording creates a new project. Use `storybird_duplicate_project` with
`project_id`, `expected_revision`, and an optional `name` to make a separate
editable language version. It copies the source video, placed narration and
editing state, but not unplaced drafts, jobs or undo history. The copy starts at
revision 0 and remains playable after the source project is deleted. Multiple
source-video composition is not provided. Translate and regenerate the chosen
sentences, then recalculate timing; translated speech is not duration-equivalent.

## Security boundary

- Storybird owns capture, video encoding, pointer input, project mutation,
  preview, and export.
- The companion translates MCP messages and launches Storybird when needed.
- The socket lives under the user's Storybird Application Support directory and
  is readable and writable only by that user.
- Storybird accepts only a `StorybirdMCP` peer signed by the same Team ID.
- No TCP or HTTP listener is opened.
- Screen recording captures no keyboard events, microphone input, or system
  audio. Voice-profile and separate project recording use the microphone only through the
  user's explicit native action.
- Live selected-source PNGs are returned only during an approved active session.
  Authenticated project preview can separately return a composited frame from a
  stored project without starting a recording session.
- Voice model preparation, reference-file selection, microphone recording, and
  profile deletion remain native user actions. Synthesis uses existing local
  profiles without exposing reference audio or exact reference transcripts.
- The completed raw MP4 stays in the Storybird project library unless the user
  explicitly exports it.

## Prompt-to-video audio production

With a prepared local model and an existing consented profile, the agent can finish
speech production without asking the user to record each sentence:

1. Read `storybird_get_edit_context` and `storybird_list_voice_profiles`.
2. Start a TTS draft for each sentence with `text`, `language` and the chosen profile.
3. Poll each job to a terminal state. Use its measured duration to edit picture length.
4. Refresh revision and place each ready draft once. Duplicate a placed layer to reuse it.
5. Use independent audio layers for additional voices, music or effects. Overlap is legal.
6. Render a selected audio range, inspect its peak and listen where supported; render
   video frames to inspect text and effects. Then start export and poll to completion.

`storybird_update_audio_layer` accepts `project_id`, `expected_revision`, `layer_id`,
and optional `name`, `start_time`, `source_start`, `duration`, `volume`, `muted`,
`fade_in`, `fade_out`, `timing_mode`. Times are seconds. Volume is a nonnegative
multiplier (1 = original), fades are linear, and their combined length cannot exceed
the layer. Source ranges must fit the full asset; project ranges must fit the picture.
`storybird_place_audio_asset` uses `asset_id`, `start_time`, optional source range
and timing mode. Registered assets are separate from unplaced TTS drafts.

`storybird_render_audio_preview` takes `project_id`, `start_time` and `duration`.
It returns a new local float WAV path, actual duration, peak and waveform. Peaks
above 1 indicate overload before final encoding; lower the appropriate layer gains.
Audio bytes are not returned. Preview does not change revision. A waveform or a
successfully created file does not verify pronunciation or naturalness.

Native **Audio & TTS** also permits optional file import and separate user-started
voice recording. MCP has no microphone-start or file-picker tool. Screen and microphone
recording are mutually exclusive. Source movie sound continues to follow video edits.

### Discovery and compatible narration calls

The server announces itself as **Storybird Video Production**. Initialization
instructions guide agents through TTS drafts, measured durations, revisioned
placement, overlapping audio edits, mix previews and completed export jobs.
`storybird_get_edit_context` exposes layer IDs under `project.narrations`;
`storybird_list_audio_assets` exposes reusable asset IDs separately.

The existing `storybird_update_narration` name remains available. Its gain uses
the same nonnegative multiplier as the audio-layer editor, including values above
2. Text regeneration is not advertised as idempotent. Layer deletion retains the
underlying sound and undo history. Positive audio durations use an exclusive
zero lower bound. Booleans and fractional revision numbers are rejected rather
than coerced, and unadvertised tool names are rejected before app IPC.

After updating the app bundle, restart Storybird and reconnect the MCP client so
both processes use the new implementation and refresh the tool list. A companion
already running from `/Applications/Storybird.app` does not pick up a build in the
repository automatically. The app and companion should come from the same bundle.

Protocol regression coverage uses the production server handlers and an actual
MCP SDK client over in-memory transport, with isolated app IPC and deterministic
TTS. Run `swift test --filter MCPAudioProtocolTests` without a live app, microphone
or voice profile.

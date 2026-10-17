---
name: create-storybird-video
description: Create or edit Korean or English videos through Storybird and verify the exported MP4. Use for video production, not app development or release.
---

# Create a Storybird video

Complete the requested video or edit through Storybird. Infer the target project,
language, output path and requested result from context; ask only when missing
information prevents starting or leaves the target/meaning ambiguous.

## Choose the needed workflow

Discover the connected tools before choosing commands. An installed app does not
prove a connection. Read only the relevant sections of [MCP.md](../../../docs/MCP.md)
for command properties or failure behavior; the live schemas determine availability.

If discovery includes the compact editing tools, use the matching tool with an
explicit `action` (`kind` for visual-effect creation and card insertion).
Keep `project_id` and `expected_revision` at the top level; put only the selected
operation's fields in `input`. The [profile table](../../../docs/MCP.md#choose-a-tool-profile)
maps actions. Use `input: {}` for history operations. Do not call replaced legacy
names when they are absent from discovery. The legacy profile keeps direct fields.

When `storybird_apply_edits` is advertised, use it for multiple explicit targets
that must succeed together. `storybird_preview_edits` accepts the same revision
and edit array and can inspect the prospective result without saving. Preview
IDs are provisional; use created IDs from a successful apply for later requests.
Read each target's fields and source bounds from `storybird_get_edit_context`.
Do not directly retime a scene-linked layer in conflict with its clip's move;
combine the clip move with style/text edits instead. Batch rejection saves no
partial result, and a successful edit is one undo unit.

- **Existing video:** start with `storybird_get_edit_context`. Resolve one-based
  scene numbers, clip times and layer IDs. Do not start a recording, inspect voice
  profiles, or generate speech for an edit that does not need them.
- **New footage:** read [recording.md](references/recording.md). A new recording
  creates a project; do not promise to merge it into another source video.
- **External video or audio file:** read [importing.md](references/importing.md).
  Use the advertised path-import tools without asking for a file picker or folder
  approval. Continue editing with the returned project or audio asset ID.

- To combine additional shots or still images, use `storybird_import_media` on
  the existing video project with an absolute MP4/MOV/PNG/JPEG path and a stable
  request key. Poll `storybird_get_import`. Registration leaves revision and
  playback unchanged. Read `storybird_list_media_assets` and use
  `storybird_place_media_asset` with a current revision and zero-based insertion
  index; images require an explicit positive duration. Video source ranges refer
  to that asset, not the first recording. Inspect an unplaced source with
  `storybird_render_preview` plus `asset_id` and source-relative `time`; image
  time is zero. Keep source thumbnails distinct from composited project previews.
- **Narration or audio changes:** use the generation rules below and
  [MCP narration guidance](../../../docs/MCP.md#narration-and-retries).
  Read [audio.md](references/audio.md) for generation, placement, timing and mix guidance.
- **Another language version:** duplicate the project, then translate and edit
  the copy. Do not assume translated speech has the same duration.

For a new production, make a short shot list of actions, visible results and any
requested narration. Introductions emphasize benefit and outcome; tutorials retain
the steps viewers must reproduce. Use synthetic demo data and respect the user's
existing external-action limits.

### Choose a speech source

Use Qwen3-TTS 1.7B Base 8-bit (`qwen3-tts-1.7b-base-8bit`) for **Clone my voice**
with an existing consented profile. Use 1.7B CustomVoice 8-bit
(`qwen3-tts-1.7b-customvoice-8bit`) for **Built-in voice** without a profile,
reference audio or microphone recording. Query `storybird_list_voice_models`;
snapshots expose boolean `supports_generation` and speaker ID array `speakers`.
CustomVoice IDs are `vivian`, `serena`, `uncle_fu`, `dylan`, `eric`, `ryan`,
`aiden`, `ono_anna`, `sohee`. Check readiness separately from generation support.

Select and prepare the supported model needed by the requested voice source.
Selection alone never downloads; both models can remain installed, and generation
uses the model matching the source. The retired 0.6B model cannot be selected,
installed or used for synthesis. Its saved selection migrates to Base; retained
files are exposed only for status/removal and are not automatically deleted.

Prefer `storybird_start_narration_draft` with project ID, text, explicit `korean`
or `english`, and exactly one voice source. Clone requests use `voice_profile_id`
and omit both `speaker` and `instruct`. CustomVoice requests use `speaker`, optional
`instruct`, and omit `voice_profile_id` entirely. `storybird_generate_narration`
uses the same voice fields plus current revision and placement time.

Poll drafts until ready, failed or cancelled; use measured duration to arrange
the picture, refresh revision and place a ready draft once. Ready drafts survive
restart and placement failure. For an existing CustomVoice layer,
`storybird_update_narration` accepts `speaker`/`instruct` with its narration ID and
current revision. Instruction-only regeneration keeps text/language;
`instruct: ""` clears instructions. Omitted settings remain unchanged. Do not use
these fields to convert cloned or imported audio. Preserve saved `customVoice`
metadata through asset reuse, split, duplicate, undo and reopen. A failed edit
preserves prior audio/settings. The native editing sheet and inspector expose the
same CustomVoice controls. Prepared synthesis runs locally without network access.

## Edit the requested scope

Preserve unspecified text, styling, voice, timing, IDs and source media. Prefer
targeted commands. Update an existing subtitle with its ID and current required
start/end times; omit unchanged optional properties. Change one title through its
effect ID, and one spoken sentence through its narration ID.

For multiple targets, read `storybird_get_edit_context`, then send explicit
`target`, `id`, `action`, and changed `values` to `storybird_preview_edits` and
`storybird_apply_edits` with the same current revision. Preview never writes;
its generated IDs are provisional. Use IDs returned by apply for later edits.
The context includes complete independent/Cue `captions`, editable fields,
source references and alignment candidates. Agent editing calls these commands;
it never needs to synthesize editor keys or manipulate the app's selection.

Set the project `canvas_preset` (`original`, `landscape`, `portrait`, `square`)
and `canvas_background_hex` through the shared batch. Set each clip's `fit_mode`
(`fit` or `fill`) and `anchor_x` / `anchor_y` in 0...1. Check representative PNGs
after changing the canvas: content Cues/effects follow the source placement,
while subtitles/cards stay on the canvas. Keep the requested font size and text.
Spotlight rectangle and pan/zoom start/end centers/scales use the same effect
fields exposed in the context and the batch update command.

Use full-project replacement only when targeted commands cannot express the edit.
Submit it through Storybird with the current revision; preserve unrelated fields,
immutable source media and app-owned draft states. Each successful edit supplies
the next revision. On conflict or an ambiguous response, read current state and
recompute instead of blindly repeating the mutation.

Use scene timing for layers that should follow a scene's start frame, and project
timing for fixed placement and card narration. Preserve existing timing unless
requested otherwise. Linked-layer duration stays unchanged through speed edits;
removing its start/owner excludes it and undo restores it. Audio overlap is allowed;
out-of-project placement requires repairing the picture or timing before retrying.

Retained Click Cues need both description and Cue subtitle before export. Fill
missing text or remove irrelevant Cues within the requested scope.

### Keep subtitles consistent and complete

Choose one subtitle style for the video before placing text: bottom-center by
default, the system font, one `font_size`, and consistent color/background settings.
Reuse it for independent and Cue subtitles; Cue fields are `subtitle_position`
and `subtitle_font_size`. Honor explicit user styling and
preserve existing styles in targeted edits. The renderer uses the full frame
width inside safe margins; do not simulate a narrow column with manual newlines.
Line breaks belong between words (Korean eojeol), never inside a word.

Unless the user explicitly permits shortening, include **all** text requested as
subtitles, in order. Narration subtitles must cover the full spoken script.
Do not summarize, omit clauses, add ellipses or reduce an individual caption's
font size to make it fit. Split long passages into successive timed segments at
word boundaries, preserving every word and punctuation mark. Use actual speech
timing and retain one style across those segments. If even one word cannot fit,
adjust the common size for the sequence or follow the user's explicit styling;
do not break that word or silently alter text.

Use independent-caption `split` only with both an internal project `time` and
`text_offset` counted in Unicode grapheme clusters. Use `merge` with the earliest
caption ID, adjacent non-overlapping `related_ids`, and explicit combined `text`.
Cue captions remain Cue components. Import an existing UTF-8 SRT with
`storybird_import_subtitles` (`project_id`, `expected_revision`, absolute `path`);
it appends all entries atomically. Export SRT only when requested, with an explicit
`scope` (`independent`, `cue`, `both`) and optional output directory. Read the
returned new path; export leaves the project and existing files unchanged.

Read back the saved subtitles and compare their ordered text with the source,
allowing only whitespace changes caused by wrapping/segmentation. Save the MCP
project response and full transcript outside the project library, then run:

```bash
python3 <skill-directory>/scripts/check-subtitles.py --project project.json --source transcript.txt
```

Resolve `<skill-directory>` to this skill's directory. The read-only checker accepts
`get_project` or `get_edit_context` JSON, includes Cue subtitles, and fails on missing,
repeated, reordered or changed words and inconsistent position/size. For a targeted
edit, repeat `--subtitle-id` for its complete source scope. Use
`--allow-style-variation` only for explicit user styling exceptions; it never
bypasses text preservation. If shortening was authorized, use the approved revised
transcript as the source. Repair audit failures through MCP and read back again.

Inspect every changed segment, including the longest and multiline cases, for full text,
consistent size, bottom/top anchor and word boundaries. An overflow error requires
repair before export; successful text storage alone does not prove it is visible.
Check segment boundaries for accidental overlap: subtitle end times are inclusive.

## Verify and deliver

Inspect composited frames at changed scenes and overlay boundaries for text,
clipping, Cue completeness and placement. Still frames cannot verify speech or motion.
Start export and poll until completed, failed or cancelled; queued is not complete.
Preserve the project on failure and choose a bounded repair from the reported cause.

Verify the MP4 exists and opens, check duration/audio presence with available media
tools, and inspect playback or representative frames. Report the path, language,
duration and any unverified listening/motion checks. Keep language exports distinct.

## Boundaries

Use app-owned tools, never direct project-library writes. Model status, selection
and installation/removal use MCP without additional approval. Use
`storybird_prepare_voice_model` to install and `storybird_remove_voice_model`
to remove a model only when requested; poll `storybird_get_voice_model` until
`ready`/`failed` for installation or `not_prepared`/`failed` for removal.
Removal keeps selection, profiles, ready drafts, completed audio and project
history. Reinstall a removed model before synthesis using that source. Model changes
are rejected during voice work. Profile management,
microphone input and voice-profile reference-file selection require native user
action. Project video/audio imports accept local paths through the advertised MCP
tools without additional consent. Do not work around the remaining boundaries.
Screen-control sessions use the persistent recording auto-approval setting, off
by default. Inspect it with `storybird_get_recording_auto_approval`; change it with
`storybird_set_recording_auto_approval` and an explicit `enabled` boolean only when
the user asks to change that preference. It skips Storybird's session dialog only;
macOS permissions, pending prompts and permanent deletion confirmation remain.

For an explicitly requested permanent project deletion, inspect the project ID,
name and revision and ensure the user's request or approval covers that project
and its owned assets. Reuse that approval instead of asking again. Call
`storybird_delete_project` with `confirmed: true` and `expected_revision` to
confirm through the agent without an app popup. Never treat agent judgment or
authentication alone as user consent. `confirmed: false` cancels; omit the field
only to use the native prompt. Deletion cannot be undone. Check the result's
`project_removed` and `assets_removed` flags and report a cleanup failure honestly.
Storybird controls only the pointer; a separately
authorized browser may supply text input to the same captured window.

For app-version troubleshooting, `storybird_get_update_status` reads cached status
without network access. Use `storybird_check_for_updates` only for a requested
version check, then poll status; it fetches public GitHub release metadata and
never installs software or changes projects. Do not add update checks to ordinary
video production.

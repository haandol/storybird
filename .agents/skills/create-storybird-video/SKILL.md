---
name: create-storybird-video
description: Produce Korean or English service introduction and tutorial videos through Storybird, using existing consented voice profiles, revision-checked editing, composited preview, and verified MP4 export. Use for making a video or editing an existing video from the user’s text request, not for developing or releasing the Storybird application.
---

# Create a Storybird video

Complete the requested video through Storybird, from the demonstrated service to
the exported MP4. Read [the MCP workflow](../../../docs/MCP.md) and discover the
connected tool schemas before selecting commands. Use the tools actually exposed
by that server; do not infer availability from an installed app or this skill.

## Prepare the production

Infer the service, audience, language, approximate length, voice profile, and
output location from the user's request and available context. Ask only for
missing inputs that prevent starting, such as which service to demonstrate.
Use an introduction to explain benefit and show outcomes; use a tutorial to keep
the steps that a viewer must reproduce.

Draft a brief shot list with the action, expected visible result, and narration
for each scene. Keep the script in the requested language. Do not assume that a
translation has the same spoken duration as the original.

Check available voice profiles. The user creates profiles and prepares the model
in native Settings. Do not register a voice, activate the microphone, download the
model, or modify profile files through an indirect route. A supported language is
not evidence that a particular voice sounds good: generate a short representative
sentence first and let the user assess pronunciation and resemblance when needed.

Prepare synthetic demonstration data and a predictable initial state. Preserve
the user's existing authorization and external-action limits. A recording request
does not authorize unrelated messages, purchases, uploads, or account changes.

## Record and edit

Select one visible source, request a named session, and allow the native approval
flow. Observe before acting and after each meaningful operation. Record the
action/result relationship so you can locate the corresponding clicks and scenes
after stopping. Do not assume a fresh frame proves the service operation finished.

Use Storybird for pointer actions. If a separately authorized browser tool is
needed for text input, verify it operates the captured visible window. Avoid
simultaneous pointer control. Do not add keyboard input to Storybird or bypass its
source/permission boundary.

Always stop a successful recording and wait for the finalized project. If the
connection is lost, inspect session/project state before trying again. An
ambiguous pointer response must not be blindly replayed.

Read the project and its revision. Cut idle time and mistakes, arrange scenes,
then add titles and freeze segments. Prefer targeted tools. When only full-model
replacement can edit a property, preserve unrelated fields and identifiers and
submit it through Storybird's revision-checked command.

Use `timing_mode: "scene"` for narration and subtitles that should follow a
scene's start frame. Their durations stay unchanged when the video speed changes.
Use `"project"` for fixed placement and card narration. Existing layers remain
fixed-time unless explicitly changed. Removed start frames/owners remove linked
layers; undo restores them. If an edit causes overlap or overflow, recalculate the
picture or start times rather than repeatedly sending the same rejected change.

## Edit from a text request

For an existing video, start with `storybird_get_edit_context`; do not begin a new
recording unless the requested change needs new footage. Resolve the user's words
against the one-based scene numbers, clip times, current captions and narration.
Select concrete project and layer IDs, and preserve unspecified text, styling,
voice and timing. Ask only when the intended target or meaning remains ambiguous.

Examples of translating intent into edits:

- “Change the second scene's explanation” → identify the scene and narration,
  then `storybird_update_narration` with the replacement text.
- “Change this subtitle” → `storybird_upsert_subtitle` with its existing ID and
  current start/end times; omit other properties to preserve them.
- “Rename the introduction” → `storybird_update_effect` with the title card ID
  and new `title`, without rewriting the complete project.
- “Make an English version too” → `storybird_duplicate_project`, use its returned
  project ID and revision, then translate/re-synthesize only the relevant layers.
- “Make this click clearer” → update the Cue description/subtitle, or apply/edit
  the associated spotlight/zoom suggestion after inspecting the current result.

Use targeted tools when they express the change. A compound edit can use the
existing revision-checked full-project replacement, but preserve immutable source
media, draft states and unrelated fields. Script interpretation/translation belongs
to the agent; the app does not invoke another text-generation model or synthesize
keyboard input. Each successful edit's revision becomes the next request's basis.
On conflict, reload and recompute against the user's newer state.

## Add or revise the user's voice

Prefer `storybird_start_narration_draft` with an existing profile and explicit
`korean` or `english`. Poll `storybird_get_narration_draft` until ready, failed or
cancelled; the ready result supplies the measured duration. Generation does not
advance the editing revision. Before placement, refresh the project revision and
call `storybird_place_narration_draft` with its start time and timing mode.

If the voice does not fit, retain the draft, edit the scene or add a freeze, then
place the same WAV without regenerating it. Ready drafts survive restart. Failed
or cancelled jobs are terminal; retry explicitly only when the cause is resolved.
A placed draft cannot be placed twice. Discard a draft only when the user's intent
permits removal of that generated audio.

The legacy generate-and-place command remains available, but failed placement
removes its unreferenced WAV. Do not run multiple revision-changing placements
against one revision. A lost response requires reading project/draft state before
retrying, not guessing whether it committed.

Change one placed sentence with `storybird_update_narration`. A language change
must include the text to regenerate. Preserve the other sentences and use actual
new duration when adjusting subtitles. Complete previous audio is retained for
undo. Short test synthesis and native listening are appropriate for verifying
service names, numbers and mixed-language phrases before a longer production.

Fill both description and Cue subtitle for retained clicks or remove irrelevant
Cues. Keep narration, instructional text and emphasis consistent, then inspect the
changed scene with `storybird_render_preview`.

## Verify and deliver

Inspect composited frames at meaningful scene boundaries and overlay times.
Check the displayed result, text clipping, click completeness, and overlay
placement. A still image does not verify speech or motion.

Start an export and poll until completed, failed, or cancelled. Do not report a
queued job as a finished video. For failure, preserve the project and use the
reported cause to choose a bounded repair.

Verify the exported artifact exists and can be opened. Check duration and audio
presence with available local media inspection tools, and inspect playback or
representative frames where available. Report which voice/listening or motion
checks remain unverified instead of claiming full audiovisual validation.

Return the finished MP4 path, language, duration, and any material limitation.
Keep each language's final MP4 distinct. Use project duplication for independently editable language versions. Do not
merge separate recordings or promise scene replacement: multiple source videos
are not supported by the current project model.

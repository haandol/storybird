# Narration and independent audio

Read only for requested speech generation/regeneration or audio edits. Existing
sound placement, trim or gain changes do not require model preparation or a new
voice profile. For field details, use the relevant audio/narration sections of
[MCP.md](../../../../docs/MCP.md) and the connected tool schemas.

## Generate or revise speech

Use existing consented profiles. Users prepare the model and create/manage profiles
in native Settings; never activate a microphone, download a model, choose an
external file or modify profile assets indirectly. A prepared model and profile
allow speech from text without a human recording.

Before a longer synthesis with an unverified voice/language, generate a short
representative sentence with service names, numbers or mixed-language phrases.
Inspect available evidence. Ask for listening feedback when it resolves material
uncertainty or the user requested review, not for routine approval of every sentence.

Prefer `storybird_start_narration_draft` with explicit `korean` or `english`.
Poll `storybird_get_narration_draft` until ready, failed or cancelled. Ready supplies
actual duration; generation does not advance edit revision. Refresh that revision
before `storybird_place_narration_draft` with the intended start and timing mode.

If speech does not fit, retain the ready WAV, edit placement/picture or add a freeze,
and place the same draft. Ready drafts survive restart; failed/cancelled jobs are
terminal and need an explicit retry after resolving the cause. A placed draft
cannot be placed twice, including after undo. Discard audio only within user intent.
Do not issue several revision-changing placements against one revision.

The legacy generate-and-place tool deletes an unreferenced WAV on placement
failure. Prefer drafts for recoverable production. On a lost response, inspect
project/draft state before retrying.

Use `storybird_update_narration` to change one placed sentence; include replacement
text for a language change. Preserve other sentences and adjust subtitles using
the new measured duration. Finished audio remains available for undo.

## Place and mix audio

Inspect reusable assets with `storybird_list_audio_assets`. Duplicate a placed
sound with `storybird_duplicate_audio_layer`, or place a registered asset with
`storybird_place_audio_asset`. Move/trim/mute/change gain or fades with
`storybird_update_audio_layer`; split at project seconds with `storybird_split_audio_layer`.
Original movie gain/mute uses `storybird_set_source_audio` without changing picture timing.

Overlapping voices, music and effects are allowed and mixed. Keep speech intelligible
through placement and gain; a crossfade combines an outgoing fade-out and incoming
fade-in. Preserve source audio and assets required for undo.

Render meaningful ranges with `storybird_render_audio_preview`. It returns a local
WAV path, measured duration, peak and waveform, not embedded audio bytes. Inspect
or audition through authorized tools. A peak above 1 calls for reduced gain.
Waveform/peak inspection cannot establish pronunciation, resemblance or naturalness.
Keep narration, instructional text and emphasis consistent and inspect the edited
scene with `storybird_render_preview` before the main skill's export checks.

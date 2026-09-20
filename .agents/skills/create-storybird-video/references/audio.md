# Narration and independent audio

Read only for requested speech generation/regeneration or audio edits. Existing
sound placement, trim or gain changes do not require model preparation or a new
voice profile. For field details, use the relevant audio/narration sections of
[MCP.md](../../../../docs/MCP.md) and the connected tool schemas.

## Generate or revise speech

Query `storybird_list_voice_models`. For cloning, prepare
`qwen3-tts-1.7b-base-8bit` and use an existing consented `voice_profile_id`.
For built-in speech without a profile, prepare `qwen3-tts-1.7b-customvoice-8bit`,
choose a returned `speaker`, and optionally provide `instruct` for speaking style,
emotion or pacing. Do not mix these fields with `voice_profile_id`.
Use `storybird_prepare_voice_model` if the required model is not ready.
Poll `storybird_get_voice_model` until ready or failed; preparation needs no
additional approval and model selection alone never downloads. Do not switch
models during active voice work. Both prepared models remain available.
Users create/manage profiles in native Settings; never activate a microphone,
choose a voice-profile reference file or modify profile assets indirectly.
CustomVoice requires no microphone, reference audio or profile. Retired 0.6B
installations are removal-only; use `storybird_remove_voice_model` when cleanup
is requested and poll until `not_prepared` or `failed`.

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
For an existing CustomVoice layer, `speaker` and `instruct` also trigger
regeneration. Sending only `instruct` keeps its text, language and speaker;
an empty string clears the instruction. These controls use the same revision
check and save the new audio and voice settings together.

## Place and mix audio

For an external WAV/MP3/M4A, follow [importing.md](importing.md) to register the
file without a picker. Then read the current revision before placing its asset.

Inspect reusable assets with `storybird_list_audio_assets`. In compact, use
`storybird_edit_audio_layer` with `action: "duplicate"`, `"update"`, `"split"` or
`"delete"` and put `layer_id` plus operation fields in `input`. A split uses
project seconds. In legacy, use the advertised `storybird_duplicate_audio_layer`,
`storybird_update_audio_layer`, `storybird_split_audio_layer` or deletion tool.
Place a registered asset with `storybird_place_audio_asset` in either profile.
Original movie gain/mute uses `storybird_set_source_audio` without changing picture timing.

Overlapping voices, music and effects are allowed and mixed. Keep speech intelligible
through placement and gain; a crossfade combines an outgoing fade-out and incoming
fade-in. Preserve source audio and assets required for undo.

Render meaningful ranges with `storybird_render_audio_preview`. It returns a local
WAV path, measured duration, peak and waveform, not embedded audio bytes. Inspect
or audition through authorized tools. A peak above 1 calls for reduced gain.
When the advertised schema includes `layer_id`, set it to audition only that
layer with its trim, gain, mute and fades. Use its project start and duration for
the entire layer; omit `layer_id` to inspect the full mix. Neither preview changes
revision or undo history.
Waveform/peak inspection cannot establish pronunciation, resemblance or naturalness.
Keep narration, instructional text and emphasis consistent and inspect the edited
scene with `storybird_render_preview` before the main skill's export checks.

# Narration and independent audio

Read only for requested speech generation/regeneration or audio edits. Existing
sound placement, trim or gain changes do not require model preparation or a new
voice profile. For field details, use the relevant audio/narration sections of
[MCP.md](../../../../docs/MCP.md) and the connected tool schemas.

## Generate or revise speech

Query `storybird_list_voice_models` and distinguish `supports_generation` from
local readiness. Clone my voice uses Qwen3-TTS 1.7B Base 8-bit
(`qwen3-tts-1.7b-base-8bit`) with an existing consented `voice_profile_id`.
Built-in voice uses 1.7B CustomVoice 8-bit (`qwen3-tts-1.7b-customvoice-8bit`)
without a profile, reference audio or microphone. Choose a returned `speaker`:
`vivian`, `serena`, `uncle_fu`, `dylan`, `eric`, `ryan`, `aiden`, `ono_anna`, `sohee`.
Clone requests omit `speaker` and `instruct`; CustomVoice requests omit
`voice_profile_id` entirely and may include `instruct` for style, emotion or pacing.
Never mix voice sources. `storybird_generate_narration` uses the same voice fields
plus the current revision and placement time.

Select and prepare the model matching the requested voice source. Selection
alone never downloads. Use `storybird_prepare_voice_model` when that model is
not ready and poll `storybird_get_voice_model` until ready or failed; preparation
needs no additional approval. Both models can remain installed, and generation
uses the model matching its source. Prepared synthesis runs locally without
network access. Model changes are rejected during active voice work.

The retired 0.6B model cannot be selected, installed or used for synthesis. Its
stored selection migrates to Base; retained files are status/removal-only and
are not automatically deleted. Only for requested cleanup, use
`storybird_remove_voice_model` and poll until `not_prepared` or `failed`.
Removal preserves selection, other models, profiles, ready drafts, completed
audio and project history. Reinstall before generating with a removed model.

Profile management, microphone input and voice-profile reference-file selection
remain native user actions. Do not modify profile assets indirectly. Native
profile/project recording offers 0–400% input volume (default 100%) and clipping
indication; agents use existing audio assets and timeline volume editing instead
of changing microphone input gain through MCP.

Before a longer synthesis with an unverified voice/language, generate a short
representative sentence with service names, numbers or mixed-language phrases.
Inspect available evidence. Ask for listening feedback when it resolves material
uncertainty or the user requested review, not for routine approval of every sentence.

Prefer `storybird_start_narration_draft` with explicit `korean` or `english`.
Poll `storybird_get_narration_draft` until ready, failed or cancelled. Ready supplies
actual duration; generation does not advance edit revision. Refresh that revision
before `storybird_place_narration_draft` with the intended start and timing mode.

If speech does not fit, retain the ready WAV, edit placement/picture or add a freeze,
and place the same draft. A placement conflict preserves the ready draft: refresh
revision/timing and retry placement without resynthesizing. Ready drafts survive restart; failed/cancelled jobs are
terminal and need an explicit retry after resolving the cause. A placed draft
cannot be placed twice, including after undo. Discard audio only within user intent.
Do not issue several revision-changing placements against one revision.

`storybird_generate_narration` deletes an unreferenced WAV on placement
failure. Prefer drafts for recoverable production. On a lost response, inspect
project/draft state before retrying.

Use `storybird_update_narration` to change one placed sentence; include replacement
text for a language change. Preserve other sentences and adjust subtitles using
the new measured duration. Finished audio remains available for undo.
For an existing CustomVoice layer, `speaker` and `instruct` also trigger
regeneration. Sending only `instruct` keeps its text, language and speaker;
an empty string clears the instruction. Omitted settings stay unchanged; these fields cannot convert cloned or imported
audio. The revision check and save cover audio and voice settings together;
failure preserves previous audio/settings. Preserve saved `customVoice` metadata
through placement, asset reuse, split, duplicate, undo and reopen. The native
editing sheet and inspector provide the same controls.

## Place and mix audio

For an external WAV/MP3/M4A, follow [importing.md](importing.md) to register the
file without a picker. Then read the current revision before placing its asset.

Inspect reusable assets with `storybird_list_audio_assets`. Use
`storybird_edit_audio_layer` with `action: "duplicate"`, `"update"`, `"split"` or
`"delete"` and put `layer_id` plus operation fields in `input`. A split uses
project seconds. Place a registered asset with `storybird_place_audio_asset`.
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

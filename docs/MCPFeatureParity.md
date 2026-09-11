# UI and MCP feature coverage

MCP (Model Context Protocol) lets an agent call Storybird actions. It supports the
project-editing surface, recording, previews and export. It does **not** control
every native setup or window action. This inventory maps implementation paths;
it is not proof that every property combination has been tested.

Maintain this file with every feature change under the
[completion gate](../AGENTS.md#mcp-feature-completion-gate). The
[tool guide](MCP.md) owns call examples and argument details. For each changed
action, review the UI, schema, app handler, shared editor and observable result.
An unexplained missing editing path blocks completion.

## Supported actions

Every name below is an advertised tool. Read IDs and the current `revision`
(the project's edit version) before changing an existing project.

| Native action or result | MCP path | Implementation and regression evidence |
|---|---|---|
| Import local MP4/MOV as a new project; import WAV/MP3/M4A as a reusable project asset | `storybird_import_video`, `storybird_import_audio` (`path`, `idempotency_key`; audio also `project_id`) | Production service → app host → app-owned import controller → shared video/audio validation and atomic library writer; `MCPMediaImportTests` verifies direct path import, replay, failures, cancellation, restart, placement and undo |
| Inspect or cancel a media import | `storybird_get_import`, `storybird_cancel_import` (`job_id`) | Durable per-library jobs, cooperative cancellation and reserved result identities; `MCPMediaImportTests`; no revision change until audio placement |
| Choose a display/window; start approved recording | `storybird_list_sources`, `storybird_start_session` (`source_id`, `project_name`) | App host applies the native auto-approval preference or waits for consent, then the shared capture session checks permissions/source and returns a frame; `MCPRecordingApprovalTests`, `StorybirdControlSessionTests`, `RecordingCoordinatorTests`; signed smoke required |
| Read or change MCP recording auto-approval in General Settings | `storybird_get_recording_auto_approval`, `storybird_set_recording_auto_approval` (`enabled`: required boolean) | App store persists the same user preference for UI/MCP and returns `{enabled}`; default off; no project revision or undo; `MCPRecordingApprovalTests`, `MCPFeatureParityTests` |
| Observe captured source; move, click, scroll | `storybird_observe`, `storybird_move_pointer`, `storybird_click`, `storybird_scroll` | Control session and pointer geometry; `StorybirdControlSessionTests`; real permissions require signed smoke |
| Stop/save or discard recording | `storybird_stop_session`, `storybird_abort_session` | Control host/coordinator; `RecordingCoordinatorTests`, `StorybirdControlSessionTests` |
| Create, list, inspect and select projects | `storybird_create_project`, `storybird_list_projects`, `storybird_get_project`, `storybird_get_edit_context`, `storybird_preview_project` | App store, edit context and native selection; `MCPFeatureParityTests`, `AgentProductionTests` |
| Rename, describe or independently duplicate a project | `storybird_update_project`, `storybird_duplicate_project` | App-owned saving and media copying; `AppStoreTests`, `AgentProductionTests` |
| Permanently delete a project | `storybird_delete_project` | Native confirmation in the control host; destructive lifecycle action, not a revisioned undoable edit |
| Split, trim, delete, reorder, speed-change and freeze video | `storybird_split_clip`, `storybird_trim_clip`, `storybird_delete_clip`, `storybird_move_clip`, `storybird_set_clip_speed`, `storybird_insert_freeze` | Shared `VideoTimelineEditor`; `MCPFeatureParityTests`, core timeline tests |
| Undo, redo and compound model edits | `storybird_undo_project`, `storybird_redo_project`, `storybird_replace_project` | App store validation and history; `AppStoreTests`, `AgentProductionTests` |
| Add/edit/delete Click Cues, including indicator, description and Cue subtitle | `storybird_create_click`, `storybird_update_click`, `storybird_delete_click` | Agent project editor and project validation; `MCPFeatureParityTests`, `AgentProductionTests`, `AppStoreTests` |
| Add/edit/delete independent subtitles; time, position, text/style and scene linkage | `storybird_upsert_subtitle`, `storybird_delete_subtitle` | Control host, scene timing and shared validation; `MCPFeatureParityTests`, `SceneTimingTests` |
| Add spotlight and pan/zoom | `storybird_create_spotlight`, `storybird_create_pan_zoom` | Agent project editor and content anchoring; core effect tests, `AgentProductionTests` |
| Insert title/CTA; edit/delete effects and card text/style | `storybird_insert_title`, `storybird_insert_cta`, `storybird_update_effect`, `storybird_delete_effect` | Shared card reconciliation/effect validation; `AgentProductionTests`, `MCPFeatureParityTests` |
| Inspect/edit/apply/reject generated click suggestions | `storybird_get_edit_context`, `storybird_update_suggestion`, `storybird_apply_suggestion`, `storybird_reject_suggestion` | Shared suggestion editor; `MCPFeatureParityTests`, `AgentProductionTests` |
| Pick an existing voice profile; generate/edit/delete narration | `storybird_list_voice_profiles`, `storybird_generate_narration`, `storybird_update_narration`, `storybird_delete_narration` | App-owned local synthesis; `AppStoreTests`, `AgentProductionTests`, `MCPAudioProtocolTests` |
| Inspect, select and prepare a voice model | `storybird_list_voice_models`, `storybird_get_voice_model`, `storybird_select_voice_model`, `storybird_prepare_voice_model` | App-owned persistent selection and per-model async preparation; `model_id`; no extra approval, no project revision/undo change; `VoiceModelTests`, `MCPVoiceModelProtocolTests` |
| Generate, list, inspect, cancel and place a reusable TTS draft | `storybird_start_narration_draft`, `storybird_list_narration_drafts`, `storybird_get_narration_draft`, `storybird_cancel_narration_draft`, `storybird_place_narration_draft` | Persisted draft lifecycle; `AgentProductionTests`, `MCPAudioProtocolTests` |
| List audio cards/assets and place them at a chosen time | `storybird_list_audio_assets`, `storybird_place_audio_asset` | App-owned assets and shared audio editor; `ProjectAudioTests`, `MCPAudioProtocolTests`, `TimelineAudioTests` |
| Move, trim, rename, fade, gain-adjust, mute or scene-link audio | `storybird_update_audio_layer` | Shared `AudioLayerEditor`; `ProjectAudioTests`, `TimelineAudioTests`, `MCPAudioProtocolTests` |
| Split, duplicate or delete audio blocks | `storybird_split_audio_layer`, `storybird_duplicate_audio_layer`, `storybird_delete_audio_layer` | Shared audio editor and retained source assets; `ProjectAudioTests`, `MCPAudioProtocolTests` |
| Change original movie gain/mute | `storybird_set_source_audio` | Shared project validation and mix; `ProjectAudioTests`, `MCPAudioProtocolTests` |
| Inspect a composited frame or mixed audio range | `storybird_render_preview`, `storybird_render_audio_preview` | Shared composition/mix and local renderers; `AgentProductionTests`, `ProjectAudioTests`, `MCPAudioProtocolTests` |
| Start, inspect, cancel or await MP4 export | `storybird_start_export`, `storybird_get_export`, `storybird_cancel_export`, `storybird_export_project` | Shared exporter and export lease; `VideoPipelineTests`, `AppStoreTests`, `AgentProductionTests`, `MCPAudioProtocolTests` |

### Shared performance paths

Shared performance changes preserve these tool arguments and results:

- UI edits and MCP edits still pass through the app's revision validation and
  atomic library writer. Unchanged project JSON is reused by value;
  `ProjectLibraryEncoderTests` covers edits without a revision change, order,
  deletion, encoding failure and failed-write retry. A cache hit never skips
  the filesystem write or reports an unsaved edit as successful.
- Scene-linked subtitle/audio editing shares one schedule lookup per remap or
  validation. `SceneTimingTests` also checks distinct owners displaying the same
  source frames after reordering. Timeline row caching is view-only;
  `TimelineTrackLayoutTests` verifies timing, text and disclosure invalidation.
- `storybird_render_audio_preview` and MP4 export use the same original-rate PCM
  silence and audio mix. `ProjectAudioTests` covers long gaps, overlapping
  sounds, split fades and exact preview duration.
- `storybird_render_preview` and MP4 export share bounded text/spotlight raster
  reuse. `OverlayRasterCacheTests` checks changed content, styles, geometry and
  memory bounds; the existing frame and protocol tests retain pixel/timing,
  invalid-input and terminal-state coverage.

### Gesture equivalents and property checks

- A timeline drag maps to changed project times. Cue moves use `time` and, when
  preserving the entire block, explicit indicator/description/subtitle start and
  end times. Subtitle/effect moves supply both endpoints. Audio moves use
  `start_time`. Preserve duration and scene ownership; do not assume that every
  targeted command has the same boundary behavior as a drag.
- Audio edge trims supply `source_start`, `start_time` and `duration` as applicable.
  Fade handles use `fade_in`/`fade_out`; volume and mute use `volume`/`muted`.
  Read the layer's existing timing mode and retain it unless changing it explicitly.
- Cards can be inserted and then styled with the effect update tool. Compound
  edits may use full replacement only through the app's revisioned validation;
  that endpoint cannot replace source media, forge drafts or register external assets.
- Pending suggestion changes/rejection and draft metadata do not increment the
  output revision. Applying a suggestion or placing audio does. Do not infer
  revision behavior only from a tool's mutating annotation.

The inventory test compares all advertised tool names against this file and
`MCP.md`, rejects stale documented names and checks uniqueness. Property tests
cover Cue/subtitle/audio/effect fields and require revision envelopes on edit
commands. Existing host and protocol suites check behavior, including failure
and undo. These automated checks cannot detect a new UI action omitted from
both the inventory and MCP; review of the changed UI remains mandatory.

## Native-only boundaries and local presentation

These are recorded exceptions to literal control of every UI action, not missing
project-editing tools. Changing their scope requires checking the owning ADR.

| Action unavailable through MCP | Current boundary / equivalent | Owner |
|---|---|---|
| Record project audio with a microphone | Explicit native microphone action; MCP may import existing local audio by path | [Voice/audio](adr/voice-narration/0001-local-cloned-voice-narration.md), [permissions](adr/recording/0003-permission-and-signing.md) |
| Create, rename or delete a voice profile | Native Settings and consent; MCP lists existing metadata and synthesizes from existing profiles | [Voice](adr/voice-narration/0001-local-cloned-voice-narration.md) |
| Read the guided reference script and its target duration | Native profile creation: Korean and English use approximately 20-second presentation scripts beginning with a greeting, with questions, emphasis, and pauses. Korean includes English feature names. Both retain a 10-second recording minimum. MCP uses existing profiles without exposing reference transcripts | [Voice](adr/voice-narration/0001-local-cloned-voice-narration.md) |
| Listen to a voice profile's reference sample | Native preview; MCP metadata omits reference audio and exact reference transcript | [Voice](adr/voice-narration/0001-local-cloned-voice-narration.md) |
| Select microphone, pause/resume/finalize microphone recording | Native recording UI; no MCP microphone start | [Voice](adr/voice-narration/0001-local-cloned-voice-narration.md), [permissions](adr/recording/0003-permission-and-signing.md) |
| Change/reset project folder, open Finder, configure shortcuts | Native Settings is the entry point; MCP uses the currently selected library | [Settings](adr/application-settings/0001-native-settings-and-shortcuts.md) |
| Grant OS permissions or accept native capture/deletion prompts | The user approves in macOS/Storybird; capture prompts are skipped only under the user's native auto-approval setting. OS permission and permanent deletion still require native approval | [Permissions](adr/recording/0003-permission-and-signing.md) |
| Play/pause/seek the native player, show/hide/resize preview, fold rows, scroll, select inspector tabs | Local view state has no dedicated MCP control; inspect specified times through rendered frame/audio tools and edit by stable IDs | [Authoring](adr/authoring/0001-timeline-overlay-editor.md) |
| Type or observe keyboard input; record live system audio during screen capture | Unsupported by Storybird itself; no MCP parity path | [Recording](adr/recording/0002-continuous-video-recording.md), [permissions](adr/recording/0003-permission-and-signing.md) |

## Verification scope

`MCPInitializationTests` sends raw external-client JSON through the production
transport adapter, including object-valued experimental capabilities. It checks
initialization, tool discovery, repeated-initialization rejection and standard-field validation
without launching or contacting Storybird. Same-SDK client tests alone cannot
detect every wire-format compatibility issue.

Use synthetic temporary projects. Never read the user's project library for a
parity audit. Run the focused command in [CONTRIBUTING](../CONTRIBUTING.md#mcp-support-is-part-of-feature-completion)
and `swift test` before declaring the change complete. Recording/pointer changes
also require the signed native smoke checks.

`AuthoringMCPProtocolTests` uses the production service and SDK client to exercise
project creation, discovery, clip/Cue/subtitle/effect editing, PNG inspection,
invalid and stale edits, strict full replacement, compound effect-retiming rejection,
undo/redo and MP4 export.
`MCPAudioProtocolTests` covers the complementary TTS and overlapping-audio flow.
These tests also check the advertised schemas and reject unknown tools or
arguments before app IPC. Frame timing and rendered boundaries are measured
separately by `PreviewFrameContractTests`.

This inventory does not claim real permission prompts, microphone input, every
property combination or subjective speech quality were tested. Native-only
setup boundaries remain as listed above.

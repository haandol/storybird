# Edit project scenes and layers

Read for existing-project edits, clip operations, canvas placement and visual effects.
Caption-specific text/style/SRT rules are in [subtitles.md](subtitles.md);
speech and audio-layer work are in [audio.md](audio.md).

Preserve unspecified text, styling, voice, timing, IDs and source media. Prefer
targeted commands. Update an existing subtitle with its ID and current required
start/end times; omit unchanged optional properties. Change one title through its
effect ID, and one spoken sentence through its narration ID.

The edit context includes complete independent/Cue `captions`, editable fields,
source references and alignment candidates. For atomic multi-target edits, do
not directly retime a scene-linked layer in conflict with its clip's move;
combine the clip move with style/text edits instead.

Set the project `canvas_preset` (`original`, `landscape`, `portrait`, `square`)
and `canvas_background_hex` through the shared batch. Set each clip's `fit_mode`
(`fit` or `fill`) and `anchor_x` / `anchor_y` in 0...1. Check representative PNGs
after changing the canvas: content Cues/effects follow the source placement,
while subtitles/cards stay on the canvas. Keep the requested font size and text.
Spotlight rectangle and pan/zoom start/end centers/scales use the same effect
fields exposed in the context and the batch update command.

When the user asks to hide part of the picture, create a mask through the
mask creation tool `storybird_create_visual_effect` with `kind: "mask"`. Supply both `timing_mode`
(`project` or `scene`) and `coordinate_space` (`content` or `canvas`) explicitly,
with start/end times and the entire rectangle inside 0...1, with positive width
and height. `color_hex` defaults
to black; opacity is always 100%. Use effect updates/batches for all mask values
and `order_index` for its zero-based position among masks. Later masks cover
earlier masks; all masks cover video, captions, cards and other effects.

Scene-linked masks keep their duration, follow the start owner, and disappear
when that start/owner is removed; undo restores them. Coordinate space is a
separate choice. Masks do not automatically track objects, and originals and raw
asset previews remain unmasked. Verify representative final PNGs and the exported
MP4 over the whole requested interval before reporting content as covered.

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

For targeted clip work, use compact `storybird_edit_clip` actions `duplicate`,
`set_duration` (image/freeze only) or `place_media`. The direct
`storybird_place_media_asset` tool also remains available. Read current IDs/revision first.
`destination_index` is a zero-based insertion position and `duration` is in
seconds. Video source times belong to the clip's referenced media asset; use
that source's bounds from the edit context, not the first recording's bounds. These commit one app-owned edit with undo; use the returned generated
IDs for subsequent edits. Multi-target changes still use preview/apply batches.

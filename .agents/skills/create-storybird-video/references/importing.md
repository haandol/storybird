# Import existing local media

Use this flow when the user supplies a video/audio location or the production
work has created a local media file. Check the connected schemas first. The
installed companion must advertise the import tools; if absent, explain that the
app and companion need updating. Do not fall back to editing the library directly.

## Choose the result

- MP4/MOV: `storybird_import_video` accepts `path` and `idempotency_key`. It creates
  a new project; it cannot insert another source into an existing timeline.
- WAV/MP3/M4A: `storybird_import_audio` also requires `project_id`. It registers a
  reusable asset without changing playback, revision, or undo. It does not need a
  voice profile or the synthesis model.

Pass an absolute local path readable by the Storybird app. Resolve relative paths
and `~` before calling; do not pass URLs or shell expressions. Do not ask the user
to select the file, grant its folder, or approve each import. Profile reference
selection, profile management, microphone input and actual screen recording keep
their separate native boundaries.

## Observe and continue

Keep the `idempotency_key` and returned `job_id` in the current production record.
Poll `storybird_get_import` with `job_id` until `completed`, `failed`, or
`cancelled`; `importing` is not completion. `storybird_cancel_import` requests
cancellation; continue polling until terminal.

Only completed jobs expose `result`. Video returns `projectID`, `duration`
(seconds), `width`, `height`, and creation `revision` 0. Read the current edit
context before editing; the project may have changed since import. Audio returns
`projectID`, `assetID`, and `duration` (seconds). Read the current revision and use
`storybird_place_audio_asset` to place it, then follow [audio.md](audio.md) for
mixing and preview. The app owns complete copies, so moving the external source
after success does not break the project.

## Recover without duplicates

After a lost start response, resend the same key and arguments to obtain the
existing job. The same key with different kind, path, or target project is a
conflict. To intentionally import changed contents at the same path, use a new
key. Do not repeatedly choose new keys while an earlier outcome is unknown.

Jobs remain with the selected library across reconnect, restart, and folder
reselection. A restart recovers an already committed result or marks unpublished
work failed; it never silently starts the import again. Terminal jobs stay
terminal, including after their result project was deleted. Resolve the reported
cause before intentionally retrying failed/cancelled work with a new key.

Source read errors, unsupported/corrupt media and save failures preserve existing
projects and source files. A saved audio asset remains available if later placement
fails: repair the timing or refresh revision and reuse the same asset.

# Troubleshooting Storybird

## The preview is blank or the timeline is too short

Project details initially show an empty video area. Click **Show Preview** inside
it to display the edited picture. **Hide Preview** beside the playback button
removes that area and expands the timeline; the same button shows it again.
Drag the horizontal handle above the playback controls to adjust the video and
timeline heights. Rows keep their height, and extra layers scroll inside the
timeline. These controls also work in compact windows.

## A timeline layer is hidden or its drag does not save

Non-overlapping layers share rows within their kind. Use the arrow beside
**Clicks**, **Subtitles**, **Audio**, or **Effects** to expand individual rows or
return to automatic row layout. Overlapping layers always occupy separate rows.
Scroll inside the timeline to reach later rows. Dragging preserves the complete layer
duration. A move outside the project, across an invalid scene boundary, or into
a conflicting same-kind effect is rejected with an error. Titles use clip
boundaries and CTA cards remain at the project end. Retry from the current
position after another editor changes the project.

## Screen Recording is enabled, but Storybird still asks for it

Quit every running Storybird copy, then launch the signed bundle you intend to
use:

```bash
./build.sh release
codesign -dv --verbose=4 build/Storybird.app 2>&1 \
  | grep -E 'Authority|TeamIdentifier|Identifier'
open build/Storybird.app
```

`TeamIdentifier` must not be empty. An ad-hoc build has a code-hash-specific
identity, so macOS may treat every rebuild as a new app.

If the signed build still fails, remove stale Storybird/OpenLane entries from
System Settings › Privacy & Security › Screen & System Audio Recording, enable
the current bundle, and relaunch it.

## The source gallery is empty or thumbnails are blank

- Confirm Screen Recording access for the exact Storybird bundle being run.
- Keep target windows open and visible on a Space.
- Minimized, off-screen, tiny utility, and Storybird-owned windows are omitted.
- Quit and reopen Storybird after changing permission.

## The source picker is clipped

The picker has a fixed size and scrolls internally. Scroll inside the gallery
instead of resizing the sheet.

## Video records, but click layers are missing

Enable Storybird under System Settings › Privacy & Security › Input Monitoring,
then relaunch it. Storybird observes only left/right mouse-down events and does
not register keyboard events.

Clicks outside the selected window or display are intentionally ignored. For a
window recording, keep the click inside its current visible frame.

## The recording stops but no project appears

Storybird publishes a project only after the MP4 encoder finishes. Check free
disk space and confirm the selected source stayed available until Stop
completed. A failed session must not leave a partial project in the library.

If this repeats with synthetic content, report the macOS version, source type,
recording duration, and available disk space. Do not attach private recordings.

## The final click is missing after Stop

Storybird stops accepting new clicks before it drains already accepted pointer
commands and finalizes the video. Make sure mouse-down occurred before pressing
Stop. Include the click timing in a synthetic bug report if a pre-Stop click is
still absent.

## The exported MP4 is missing overlays

Confirm the layer appears in the editor at the same playhead time. Click
captions appear around their click time; subtitles appear only inside their
start/end interval. Ensure the text is not empty and its background opacity is
not the only visible element over a matching background.

Re-export rather than modifying the original project MP4. Storybird keeps the
raw recording unchanged and burns layers into a separate output file.

## Export fails or an existing output is unchanged

Storybird writes a temporary MP4 beside the chosen destination and replaces the
destination only after successful encoding. Confirm the destination directory
is writable and has enough free space. An unchanged existing file after failure
is expected and protects the previous export.

## An imported video does not appear

Storybird imports local MP4 and QuickTime MOV files that contain a readable
video track, positive duration, and valid display dimensions. Unsupported,
damaged, or audio-only files do not create a project. Confirm the source still
exists, is readable, and there is enough disk space for a project-owned copy.

## Projects disappear after changing the storage folder

Each folder has a separate library. Open **Settings › General › Storage** and
select the previous folder. **Use Default** selects `~/Documents/Storybird`.
For projects saved at the previous default, select
`~/Library/Application Support/Storybird`. Storybird does not move, delete, or merge projects
when changing the folder. Shared voice profiles and prepared models stay in
Application Support.

## The selected project folder is unavailable

Reconnect the selected disk, restore access permissions, or choose another
usable folder in **Settings › General › Storage**. Reselect a repaired folder
to retry loading it. Storybird retains the saved choice and reports the error
instead of silently saving elsewhere. Do not delete or replace a damaged
`library.json`; keep it and its `Assets` folder together for recovery.

Finish any recording, import, export, or voice work before changing the folder.
The controls explain which active work is preventing the change.

## The recording or exported video has no audio

Direct Storybird screen recordings are intentionally silent and do not request
system-audio access. Microphone access is requested only when the user starts a
guided voice-profile sample or separate project audio recording.

For imported videos, confirm the source contains a readable primary audio track.
Storybird preserves that track in preview and exports it as one AAC track.
Original movie audio stays silent during freeze frames, title cards, and CTA cards; independent audio layers can play across those sections.

## The editor freezes while video or audio keeps playing

Update to a build containing the idle-audition stop fix and restart Storybird.
Earlier builds could repeatedly refresh the editor when video playback tried to
stop an audio audition that was already stopped. The audio device could continue
playing while the UI was stuck in that update loop. The fix leaves an already
idle audition unchanged and preserves normal stop, selection and completion behavior.

## An edited, narrated project fails with AVFoundation error -11841

Update to a build containing the shared composition-clock fix. Earlier builds
rounded each clip's duration independently, which could make the video end
slightly before the narration mix. A six-clip 59.96-second reproduction left
3.33 milliseconds uncovered and failed in the video reader. Both speed changes
and normal-speed trims could trigger it. The fix preserves the saved edit and
uses absolute project boundaries for the video and audio composition.

Retry the existing project with the updated app. Reader/writer failures now
include the export phase, snapshot revision, error domain/code and available
underlying errors. Preserve that message when reporting a remaining failure;
the error number alone does not establish the same cause.

## An MCP request stalls or loses its response

The local socket transport keeps each connection's I/O independent. A partial
request must not block other project queries, and cancelling a pending exchange
closes its socket. A disconnected client must not terminate Storybird when the
app tries to return a response.

After a lost response, read the current project revision and relevant draft or
export job before repeating a mutation. Sending a request may already have
changed the project even if its response was lost. Do not automatically repeat
pointer commands. Reconnect with the updated companion and retain the command
name and observed result when reporting a stall.

## The local voice model is not ready

Open **Settings › Voice**, choose Qwen3-TTS 1.7B Base 8-bit for **Clone my voice**
or 1.7B CustomVoice 8-bit for **Built-in voice**, then choose **Install Model**.
Storybird requires `uv`, installs a private MLX-Audio runtime, and downloads the
chosen model without another confirmation. Check free disk space and network
access. Once prepared, voice synthesis works offline. Selection alone does not
install a model, and another model's ready state does not prepare the one needed
by your voice source.

**Remove Model** removes only the selected model's app-owned runtime and downloads.
Existing audio and profiles remain usable. Reinstall before generating new speech.
If removal fails, read the status error and retry **Remove Model**; finish active
voice work before changing models. An interrupted cleanup can also be retried
after restart, even when the model shows **Not installed**.

For MCP, call `storybird_prepare_voice_model` with the required `model_id` and
poll `storybird_get_voice_model` until `ready` or `failed`. For removal, call
`storybird_remove_voice_model` and poll through `removing` until `not_prepared`
or `failed`. Model removal retains selection, other models, ready drafts,
completed audio and project history.

### The old 0.6B model is unavailable

0.6B Base is retired for new selection, installation and generation. Stored
selections migrate to 1.7B Base; existing files are not automatically deleted.
Retained files appear only for cleanup in Settings and MCP. Use the legacy ID
`qwen3-tts-0.6b-base-8bit` with the status/removal tools, not selection/preparation.
Its snapshot has `supports_generation: false`.

### Built-in speech asks for a profile or rejects instructions

Choose **Built-in voice**, install CustomVoice, then select a speaker and enter
optional instructions. A profile, reference recording and microphone access are
not required. In MCP, use a speaker ID from the model snapshot's `speakers` array,
such as `sohee`, and omit `voice_profile_id` entirely. Clone requests must omit
both `speaker` and `instruct`, even when instructions would be empty.

For an existing CustomVoice layer, both the editing sheet and inspector allow
speaker/instruction changes. MCP uses `storybird_update_narration` with the current
revision and narration ID. An instruction-only update keeps text and language;
`instruct: ""` clears instructions. These fields cannot convert a clone or imported
audio layer to CustomVoice. A rejected or failed update preserves previous audio
and settings; read the current revision before retrying a revision conflict.

## The guided recording uses the wrong microphone

Open **Settings › Voice** and choose the input device under **Guided Recording
Microphone**. Storybird stores the device UID rather than its temporary device
number. If the selected microphone is disconnected, Storybird keeps the
selection and temporarily uses the macOS system default. Reconnect the selected
device or choose the current **(System Default)** device, then start a new guided recording.
Changing the picker does not switch a recording already in progress.

## Voice cloning fails or sounds unlike the reference

If the reference is clean but generated speech sounds muffled, check that the
app includes the codec attention-window fix. MLX-Audio 0.5.3 reads the Qwen codec's
sliding-window setting but its decoder applies full causal attention instead.
Storybird restores the checkpoint's local attention window before MLX compiles
the decoder. This uses the existing model weights and voice profile; it does not
apply EQ or change pitch. Rebuild the app to update its bundled worker, then
compare a newly generated short sentence. Previously generated audio is unchanged.

To rename a saved profile, open **Settings › Voice**, click its pencil button,
and save the new name. A name cannot be blank. If saving fails, the dialog keeps
your input and shows the error; the saved profile retains its previous name.

Open **Settings › Voice › Create Voice Profile…** to enter the profile name,
language, and voice-use consent. Choose **Record** or **Import File** in that
window. Recording completion or file selection prepares a sample; **Create
Profile** saves it and closes the window. If saving fails, the window keeps your
input and shows the error for retry. **Cancel** discards the temporary recording.

For better clone quality, use a clean MP3/WAV containing several seconds of
natural speech and enter the transcript exactly as spoken. Background noise and
transcript mismatches are reproduced by the clone. Guided microphone profiles
show a live waveform and enforce at least ten seconds; rerecord the prosody
prompt in a quiet room if the input level barely moves.

If no waveform appears, refresh the device list in **Settings › Voice** and
confirm the chosen device has an input channel. Output-only devices are
intentionally excluded.

## Add Click does not create a Click Cue

Move the playhead inside a playable video clip, click **Add Click**, then select
a point inside the video frame. Full-screen title/CTA cards and the exact end of
the project have no source video time, so Storybird rejects Click Cue placement
there.

## The floating recorder appears in a capture

This is a bug. Storybird marks the HUD as non-shareable and hides the editor
during capture. Report the macOS version and source type through a private
security advisory if private content is visible.

## The MCP client cannot start the Storybird server

If startup fails during `initialize` with JSON-RPC `-32603` and “The data
couldn’t be read because it isn’t in the correct format,” install a build with
the initialization compatibility fix and reconnect the client. Swift MCP SDK
0.12.1 expects experimental capability values to be strings; clients can send
objects instead. Storybird ignores unsupported experimental metadata before SDK
decoding. This handshake failure does not require resetting screen permissions
or deleting project data.

If the connection works but an action is missing, check the
[UI/MCP feature inventory](MCPFeatureParity.md). File selection, microphone
recording, voice-profile management, project-folder selection and shortcut Settings
require native interaction. Recording auto-approval is available in both General
Settings and MCP.
Model list/status, selection, installation and removal are available through MCP.
Query and prepare the model required by the voice source: Base for a profile,
CustomVoice for a built-in speaker. Neither another model's ready state nor an
existing profile means the required model is prepared. `supports_generation: true`
describes model support; check `state` separately for readiness.
After installing a build with new tools, restart Storybird and reconnect the
MCP client to refresh discovery. A missing project-editing action should be
reported with the app version, tool name and expected property.

Build and install the signed bundle, then configure:

```text
/Applications/Storybird.app/Contents/MacOS/StorybirdMCP
```

Do not point the client at `.build/debug/StorybirdMCP`. Verify the installed companion:

```bash
codesign --verify --strict --verbose=2 \
  /Applications/Storybird.app/Contents/MacOS/StorybirdMCP
```

Reconnect the MCP client after changing its configuration or replacing the companion.

## Storybird MCP lists no sources or returns no frame

Enable Screen Recording for the installed Storybird bundle, then quit and
restart Kiro so it launches a new companion process.

The MCP source rules match the Storybird gallery: minimized, off-screen, tiny,
system utility, Storybird, and StorybirdMCP windows are excluded.

## Storybird MCP observes the screen but cannot move or click

Enable Storybird under System Settings › Privacy & Security › Accessibility.
The companion needs no Accessibility entry. Start a new session, then approve
the native Storybird dialog unless recording auto-approval is enabled.

Coordinates must be finite normalized values from `0` through `1`. Invalid
coordinates, missing frames, or revoked permissions post no input.

## Storybird asks “Allow Storybird MCP Control?” for every recording

The app defaults to confirming each screen-control session. Enable **Settings ›
General › MCP Recording › Automatically approve MCP recording** to skip that dialog.
You can also request `storybird_set_recording_auto_approval` with `{"enabled": true}`
or `{"enabled": false}` and read it with `storybird_get_recording_auto_approval`.
Both paths update the same persistent user preference; reconnecting MCP, reopening
the app or changing the project folder does not reset it.

The setting applies to new sessions. It does not accept an already open dialog or
stop an active recording. macOS Screen Recording/Accessibility prompts and permanent
project deletion confirmation remain in effect. A prompt shown by your MCP client
uses that client's own approval settings.

## An MCP session stops but no video project appears

`storybird_stop_session` drains accepted pointer actions, stops ScreenCaptureKit,
finalizes the MP4, validates timed clicks, and then saves the project. Check the
tool error and local disk space. A failed session must leave the existing
library unchanged.

## Existing OpenLane projects are missing

Storybird copies the OpenLane Application Support directory only when the
Storybird directory does not yet exist:

```text
~/Library/Application Support/OpenLane
~/Library/Application Support/Storybird
```

Storybird never deletes the OpenLane directory. Legacy screenshot projects are
preserved but are not automatically converted into video projects.

## macOS blocks the app at first launch

Public builds are not currently notarized. Verify the app signature:

```bash
codesign --verify --deep --strict --verbose=2 Storybird.app
```

Then use System Settings › Privacy & Security › Security › **Open Anyway** if
macOS presents the option.

## Narration is ready but will not fit

A ready draft keeps its WAV when placement exceeds the project duration or
conflicts with a newer project revision. Audio layers may overlap. Move its start or edit the picture (for example, insert a
freeze segment), refresh the project revision, and place the same draft again.
Do not regenerate solely to recover from a placement error. A draft that already
shows `placed` cannot be placed again, including after undo; use redo to restore
that placement.

## A narration does not follow the moved scene

Check its **Timing** selection. Existing narration and subtitles retain **Fixed
project time**. Choose **Follow scene** to anchor the start to its current clip.
Cards use fixed project time. Scene linking moves only the start, preserving
speech/display duration; exceeding the project duration rejects the entire edit.
Audio overlap is allowed.

## A voice generation was interrupted by restart

Interrupted draft jobs are marked failed and do not automatically run again.
Create a new draft explicitly. Ready drafts are retained. Check the native Voice
Settings if the model is not installed, or use `storybird_prepare_voice_model`
and poll `storybird_get_voice_model` until ready or failed. MCP cannot register
a voice profile.

## Audio layers and TTS production

- **Speech is longer than the picture:** keep the ready TTS draft, extend the scene
  or add a freeze, then place the same audio again. Generation is not required again.
- **Several voices talk at once:** overlap is allowed. Move, mute, trim or reduce
  a layer directly on the timeline. Select it for edge trimming and a volume slider,
  or use **Details** for exact values. Use fade-out/fade-in on overlapping clips for a crossfade.
- **Cannot find audio creation:** use **Audio** in the app toolbar or **Add Audio**
  above the timeline. In compact windows, scroll the panel above the timeline to
  reach cards and generation controls. Add places at the current playhead.
- **An edge drag returns to its old position:** the source range or project end
  would be exceeded, the project changed during the drag, or saving failed.
  Read the error and retry; the stored layer and undo history are preserved.
- **The mix is too loud:** inspect a mix preview's peak. Values above 1 need reduced
  gain; Storybird does not silently normalize your mix.
- **Cannot start a microphone:** finish the current screen or microphone recording.
  Only native Start Recording activates input. Project recording accepts positive
  audio length; the guided voice-profile sample still requires 10 seconds.
- **Imported audio cannot be used:** select a readable WAV, MP3 or M4A with **Import** in the Audio panel.
  Storybird copies and validates it before registration. Failed placement retains
  the asset, and deleting a layer preserves it for reuse and undo.

## An agent asks me to select a video or audio file

Check that the connected companion advertises `storybird_import_video` and
`storybird_import_audio`. These tools accept absolute local paths without a file
picker or folder approval. Update/rebuild the app and bundled companion together
and reconnect the MCP client if they are absent. Voice-profile reference samples
and microphone input still use the native consent flow.

Keep the returned `job_id` and poll `storybird_get_import`. After a lost response,
repeat the same `idempotency_key` and arguments to recover the existing job.
A key conflict means that key already names a different request. A failed or
cancelled job needs a new key for an intentional new attempt. An interrupted job
never restarts automatically. If the job record cannot be saved, restore access
to the selected library before retrying its status lookup. Imports do not fall
back to a different project folder.

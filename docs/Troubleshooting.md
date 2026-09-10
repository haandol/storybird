# Troubleshooting Storybird

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
when changing the folder. Shared voice profiles and the prepared model stay in
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

## The local voice model is not ready

Open **Settings › Voice** and choose **Prepare Model**. Storybird requires `uv`,
installs a private MLX-Audio runtime, and downloads the Qwen3-TTS 1.7B Base
8-bit model after confirmation. Check free disk space and network access. Once
prepared, voice synthesis works offline.

## The guided recording uses the wrong microphone

Open **Settings › Voice** and choose the input device under **Guided Recording
Microphone**. Storybird stores the device UID rather than its temporary device
number. If the selected microphone is disconnected, Storybird keeps the
selection and temporarily uses the macOS system default. Reconnect the selected
device or choose the current **(System Default)** device, then start a new guided recording.
Changing the picker does not switch a recording already in progress.

## Voice cloning fails or sounds unlike the reference

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

## Kiro cannot start the Storybird MCP server

Build and install the signed bundle, then configure:

```text
/Applications/Storybird.app/Contents/MacOS/StorybirdMCP
```

Do not point Kiro at `.build/debug/StorybirdMCP`. Verify the installed companion:

```bash
codesign --verify --strict --verbose=2 \
  /Applications/Storybird.app/Contents/MacOS/StorybirdMCP
```

Restart Kiro after changing its MCP configuration.

## Storybird MCP lists no sources or returns no frame

Enable Screen Recording for the installed Storybird bundle, then quit and
restart Kiro so it launches a new companion process.

The MCP source rules match the Storybird gallery: minimized, off-screen, tiny,
system utility, Storybird, and StorybirdMCP windows are excluded.

## Storybird MCP observes the screen but cannot move or click

Enable Storybird under System Settings › Privacy & Security › Accessibility.
The companion needs no Accessibility entry. Start a new session, then approve
the native Storybird dialog.

Coordinates must be finite normalized values from `0` through `1`. Invalid
coordinates, missing frames, or revoked permissions post no input. Do not
auto-approve pointer-changing tools.

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

A ready draft keeps its WAV when placement overlaps another narration or exceeds
the project duration. Move its start or edit the picture (for example, insert a
freeze segment), refresh the project revision, and place the same draft again.
Do not regenerate solely to recover from a placement error. A draft that already
shows `placed` cannot be placed again, including after undo; use redo to restore
that placement.

## A narration does not follow the moved scene

Check its **Timing** selection. Existing narration and subtitles retain **Fixed
project time**. Choose **Follow scene** to anchor the start to its current clip.
Cards use fixed project time. Scene linking moves only the start, preserving
speech/display duration; a resulting overlap rejects the entire edit.

## A voice generation was interrupted by restart

Interrupted draft jobs are marked failed and do not automatically run again.
Create a new draft explicitly. Ready drafts are retained. Check the native Voice
Settings if the model is not prepared; MCP cannot install the model or register
a voice profile.

## Audio layers and TTS production

- **Speech is longer than the picture:** keep the ready TTS draft, extend the scene
  or add a freeze, then place the same audio again. Generation is not required again.
- **Several voices talk at once:** overlap is allowed. Move, mute, trim or reduce
  a layer in its inspector. Use fade-out/fade-in on overlapping clips for a crossfade.
- **The mix is too loud:** inspect a mix preview's peak. Values above 1 need reduced
  gain; Storybird does not silently normalize your mix.
- **Cannot start a microphone:** finish the current screen or microphone recording.
  Only native Start Recording activates input. Project recording accepts positive
  audio length; the guided voice-profile sample still requires 10 seconds.
- **Imported audio cannot be used:** select a readable WAV, MP3 or M4A in Audio & TTS.
  Storybird copies and validates it before registration. Failed placement retains
  the asset, and deleting a layer preserves it for reuse and undo.

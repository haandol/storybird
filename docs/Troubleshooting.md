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

## The recording or export has no audio

This is expected. The current Storybird contract records silent screen video
and does not request system-audio or microphone access.

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

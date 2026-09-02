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
identity, so macOS may treat every rebuild as a new app even when the Screen
Recording toggle appears enabled.

The rename from OpenLane to Storybird also changes the bundle identifier to
`com.storybird.app`, so Storybird needs one new approval. Once a real
development certificate signs subsequent builds, that approval should persist.

If the signed build still fails, remove stale duplicate Storybird/OpenLane
entries from System Settings › Privacy & Security › Screen & System Audio
Recording, add or enable the current `build/Storybird.app`, and relaunch it.

## The source gallery is empty or thumbnails are blank

- Confirm Screen Recording access for the exact Storybird bundle being run.
- Keep the target windows open and visible on a Space; minimized/off-screen
  windows are intentionally omitted.
- Very small utility windows and Storybird's own windows are filtered out.
- Quit and reopen Storybird after changing permission.

## The source picker is clipped

The picker is fixed at a compact size and scrolls internally. If the last row is
unreachable, confirm you are running the newest bundle and scroll inside the
gallery rather than resizing the app window.

## A selected window records, but clicks do not become steps

Enable Storybird under System Settings › Privacy & Security › Input Monitoring,
then relaunch. Storybird listens only for left and right mouse-down events and
does not register keyboard events.

Clicks outside the selected window or display are ignored. For a window
recording, click inside the selected window and pause briefly while the result
screen settles.

## The floating recorder appears in a capture

This is a bug. Storybird marks the HUD as non-shareable and hides the editor
during capture. Report the macOS version, source type (display/window), and a
synthetic reproduction through a private security advisory if private content
is visible.

## The final click is missing after Stop

Storybird removes the click monitor first and waits for the queued click writes
before stopping the stream. If a step is still missing, include the number and
timing of clicks in a bug report; do not attach private captures.

## An agent recording package does not import

Confirm the package ends in `.storybirdrecording` and contains only
`manifest.json` plus an `assets/` directory of PNG files. The first screen must
have no preceding click; every later screen needs finite normalized `x` and `y`
coordinates between `0` and `1`.

Storybird rejects extra manifest fields, extra files, nested or absolute asset
paths, symbolic links, unsupported versions, and unreadable images. Rebuild the
package with:

```bash
.agents/skills/record-storybird-flow/scripts/build_recording_bundle.py \
  --spec /absolute/path/spec.json \
  --output /absolute/path/demo.storybirdrecording
```

Agent import does not require Screen Recording or Input Monitoring. If the
package opens in another app, install and launch the newest signed Storybird
bundle so macOS registers the file type.

## Existing OpenLane projects are missing

Storybird copies the OpenLane Application Support directory only when the
Storybird directory does not yet exist. Check both:

```text
~/Library/Application Support/OpenLane
~/Library/Application Support/Storybird
```

Storybird never deletes the OpenLane directory. If both existed before first
launch, Storybird keeps its own library as authoritative to avoid overwriting
newer work.

## An exported demo does not open correctly

Open the generated `index.html` directly in a current browser and confirm the
adjacent `assets/` directory was not moved separately. Re-export rather than
manually editing `demo.json`; the exporter rewrites asset names and safely
embeds the project data.

## macOS blocks the app at first launch

Local Apple Development builds normally open directly. Public builds are not
currently notarized. Verify the app came from the official repository and check
its signature:

```bash
codesign --verify --deep --strict --verbose=2 Storybird.app
```

Then use System Settings › Privacy & Security › Security › **Open Anyway** if
macOS presents the option.

# README screenshot sources

All video content, project names, profile names, captions, and narration text in
these images are synthetic. Never substitute a customer recording or voice sample.

| Image | Source |
|---|---|
| `editor-app.png` | Running signed Storybird app, temporary Northstar demo library, Click Cue selected at 1 second |
| `voice-settings-app.png` | Running signed app's Voice settings, empty profile list |
| `voice-profile-dialog-app.png` | Running signed app's creation sheet, unsaved fictional name “Demo narrator”, consent off; cancelled after capture |
| `welcome.png` | Real SwiftUI welcome view rendered by the documentation test |
| `voice-narration.png` | Real SwiftUI Voice settings with a synthetic profile |
| `voice-profile-creation.png` | Real SwiftUI creation view with empty inputs |
| `narration-drafts.png` | Real SwiftUI composer with synthetic ready-draft metadata |
| `storage-settings.png` | Real SwiftUI General settings with a temporary library |

The live app screenshots were captured on 2026-09-10. No microphone recording,
model download, or voice-profile save was performed for them. Model status and
microphone names in a new capture will depend on the test Mac.

## Reproduce the running-app editor

With Pillow and FFmpeg available, run from the repository root:

```bash
python3 scripts/prepare-readme-demo.py
./build.sh debug
```

Quit the development app before launching the demo. This launch argument selects
an isolated library for this process; it does not save a project-folder preference:

```bash
open -n build/Storybird.app --args \
  -projectLibraryRootPath "$PWD/.build/readme-demo/library"
```

Enlarge the window, select the Click Cue, and capture the app window. The sample
contains an 18-second synthetic movie, three clips, one complete Click Cue, and
three independent subtitles. Generated media and library files stay under
`.build/readme-demo/` and must not be committed.

For settings and the creation sheet, use an empty/test profile list. Enter only
a fictional name, leave consent off, capture the window, and cancel. Do not
photograph a personal profile list, reference transcript, or live microphone input.
Quit the demo and reopen the app normally afterward to restore the usual library.

## Reproduce the component images

```bash
STORYBIRD_UPDATE_DOC_SCREENSHOTS=1 \
  swift test --filter DocumentationScreenshotTests/test_generateSyntheticReadmeScreenshots
```

This renders actual SwiftUI views in an isolated test fixture. It does not update
the three running-app screenshots. Review all changed images before committing.

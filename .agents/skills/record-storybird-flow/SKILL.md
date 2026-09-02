---
name: record-storybird-flow
description: Record a user-requested browser or desktop workflow into Storybird using software-controlled actions, screenshots, and normalized click coordinates. Use when an agent must create a Storybird demo without relying on physical mouse Input Monitoring; do not use for ordinary human-driven Record Flow sessions.
---

# Record a Storybird Flow

Create a local Storybird project while carrying out the workflow the user
requested. This path records visible screenshots and click locations directly;
it does not synthesize macOS mouse events or depend on Screen Recording and
Input Monitoring permissions.

## Boundaries

- The recording request does not authorize purchases, messages, uploads,
  account changes, sensitive-data transmission, or other external side
  effects. Apply the active browser/computer-use confirmation policy before
  those actions.
- Capture visible screens only. Never serialize DOM, cookies, local storage,
  keyboard input, passwords, payment data, or authentication tokens.
- Use one browser window, app window, or other named source for the entire
  recording.
- Represent only meaningful pointer actions as transitions. Typing may happen
  between transitions, but it is not stored in the recording package.
- Stop before an irreversible or unapproved action. A safe preview flow may end
  at the final confirmation screen.

## Workflow

1. Use the appropriate browser or computer-control skill to open the requested
   source and reach the agreed starting state.
2. Create an isolated temporary work directory and save an initial PNG
   screenshot before performing the first recorded action.
3. For every recorded pointer action:
   - determine the action point in the visible source viewport;
   - normalize it as `x / viewportWidth` and `y / viewportHeight`;
   - perform the software-controlled action;
   - wait until the visible result is stable;
   - save the resulting source screenshot as PNG.
4. Write a JSON spec for `scripts/build_recording_bundle.py`. The first step has
   no `click`; every later step carries the click that produced it:

   ```json
   {
     "project_name": "Amazon Dyson purchase flow",
     "source_name": "Amazon Chrome window",
     "steps": [
       {"image": "/tmp/flow/start.png"},
       {
         "image": "/tmp/flow/results.png",
         "click": {"x": 0.72, "y": 0.08}
       }
     ]
   }
   ```

5. Build the package:

   ```bash
   python3 scripts/build_recording_bundle.py \
     --spec /absolute/path/spec.json \
     --output /absolute/path/name.storybirdrecording
   ```

6. Import it by opening the package with the installed app:

   ```bash
   open -a Storybird /absolute/path/name.storybirdrecording
   ```

7. Verify in Storybird that:
   - the imported project name matches the spec;
   - the screen count equals the number of spec steps;
   - each screen except the last has one hotspot targeting the next screen.

If import fails, preserve the package and report Storybird's visible error.
Never modify Storybird's `library.json` or `Assets` directory directly.

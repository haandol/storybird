# Storybird MCP

Storybird ships a local stdio MCP companion. The companion has no Screen
Recording, Input Monitoring, or Accessibility permission. It forwards requests
through a user-only Unix socket, and the Storybird app verifies the peer's code
signing identifier and Team ID before executing commands.

## Install

```bash
./install.sh
```

Merge [`mcp/storybird.kiro.json`](../mcp/storybird.kiro.json) into
`~/.kiro/settings/mcp.json`, then restart Kiro.

Certificate signing is required for external control. Ad-hoc builds can run the
normal Storybird UI but the app rejects MCP IPC because there is no stable Team
ID to authenticate.

## Tools

| Tool | Result |
|---|---|
| `storybird_list_sources` | Lists eligible displays and windows |
| `storybird_start_session` | Requests native approval and starts one-source video recording |
| `storybird_observe` | Returns the latest selected-source PNG |
| `storybird_move_pointer` | Moves the real pointer through Storybird |
| `storybird_click` | Performs a real left or right click through Storybird |
| `storybird_scroll` | Performs a real wheel event through Storybird |
| `storybird_stop_session` | Drains commands, finalizes the MP4, and saves the video project |
| `storybird_list_projects` | Lists local project models |
| `storybird_get_project` | Returns one editable project model without image bytes |
| `storybird_split_clip` | Splits one video clip at a source recording time |
| `storybird_trim_clip` | Keeps one source range and removes linked layers outside it |
| `storybird_delete_clip` | Removes one edited clip while preserving the original recording |
| `storybird_move_clip` | Moves one clip to a zero-based timeline index |
| `storybird_set_clip_speed` | Sets one clip from 0.25× through 4× |
| `storybird_insert_freeze` | Inserts a positive-duration still frame after one clip |
| `storybird_update_project` | Updates project name or summary |
| `storybird_update_click` | Updates a timed click caption, location, or style |
| `storybird_upsert_subtitle` | Adds or updates a timed subtitle layer |
| `storybird_preview_project` | Opens the native video timeline editor |
| `storybird_export_project` | Renders a silent H.264 MP4 |
| `storybird_delete_project` | Requests native confirmation before deletion |

Pointer-changing tools can trigger effects in the selected application and
must not be auto-approved. Project deletion also requires a Storybird-native
confirmation.

Every clip mutation includes `project_id`, `expected_revision`, and the target
clip ID. Read the project again after a revision conflict, then recalculate the
edit instead of overwriting the newer UI state.

## Security boundary

- Storybird owns capture, video encoding, pointer input, project mutation,
  preview, and export.
- The companion translates MCP messages and launches Storybird when needed.
- The socket lives under the user's Storybird Application Support directory and
  is readable and writable only by that user.
- Storybird accepts only a `StorybirdMCP` peer signed by the same Team ID.
- No TCP or HTTP listener is opened.
- Keyboard events, microphone input, and system audio are not captured.
- The selected source PNG may be returned only during the approved active
  session. The completed raw MP4 stays in the Storybird project library unless
  the user explicitly exports it.

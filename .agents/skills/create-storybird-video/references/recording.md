# Record new footage

Read only when the request needs a new recording. For an existing project edit,
return to the main skill and use its edit context.

For existing local MP4/MOV footage, follow [importing.md](importing.md) instead
of recording it again. Actual screen recording follows the approval flow below.

Choose one visible display or window and follow Storybird's saved approval setting.
The session dialog is skipped only when recording auto-approval is enabled.
`storybird_get_recording_auto_approval` reads the setting. If the user asks to change
it, use `storybird_set_recording_auto_approval` with `enabled: true` or `false`.
The setting persists across restarts and is also available in General Settings.
macOS permissions still apply. Do not change the preference merely to unblock a
recording request, and do not treat it as authorization for external side effects.
For a browser walkthrough without a user-selected source, prepare a dedicated
visible demo window with only relevant tabs and a recognizable name if supported.
Keep unrelated work outside it. Honor an explicitly selected source; use a whole
display when the requested demonstration needs it.

Observe before acting and after meaningful operations. Record the action/result
relationship to locate clicks and scenes later. A fresh frame does not prove the
service operation completed. The recording request does not authorize unrelated
messages, purchases, uploads or account changes.

Use Storybird for pointer actions. If a separately authorized browser provides
text input, verify it controls the captured visible window. Do not control the
pointer simultaneously through both tools. If focus changes, verify the source,
restore the demo window when appropriate and re-read its UI before input.
If unrelated content enters capture, stop before preparing a replacement session;
do not silently switch the source inside an active session.

Stop the session and wait for the finalized project. On a lost connection, inspect
session/project state before retrying. Never blindly replay an ambiguous click.
Read the resulting project/revision, trim idle time and mistakes, arrange scenes
and add requested titles/freezes through the normal editor tools.

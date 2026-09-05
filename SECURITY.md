# Security Policy

## Supported Versions

Before the first tagged release, security fixes target the `main` branch. After
releases begin, only the latest public Storybird release is supported; fixes
ship in a new release rather than being backported.

## Reporting a Vulnerability

Report privately through GitHub Security Advisories:

`https://github.com/haandol/storybird/security/advisories/new`

Include the impact, reproduction steps, Storybird version, and macOS version.
Do not attach raw recordings, exported videos, project libraries, credentials,
or private click/subtitle data.

## In Scope

Storybird holds Screen Recording, Input Monitoring, and pointer-only
Accessibility permission. Its bundled MCP companion has no TCC permission and
uses authenticated local IPC. Important failures include:

- recordings, thumbnails, click coordinates, subtitles, or projects leaving the Mac
  outside an explicitly approved MCP stdio session or export;
- keyboard input being collected despite the mouse-only permission boundary;
- capturing outside the display or window explicitly selected by the user;
- another process borrowing Storybird's permissions or recording session;
- an MCP client observing a source or posting input without explicit session
  acknowledgement and native app approval, an untrusted local process passing
  IPC authentication, or either process opening a TCP/HTTP listener;
- path traversal, asset collisions, partial MP4 publication, or writes outside the Storybird library or
  an explicitly selected export folder;
- timed layers being rendered at a different source, time, or coordinate than
  the approved recording;
- exported text causing code execution or file-system interpretation;
- accidental inclusion of Storybird's editor or HUD in captures;
- keyboard, system audio, or microphone data being collected despite the
  mouse-only and silent-video boundary;
- unstable signing that disconnects the app from an existing TCC grant.

## Out of Scope

- App Sandbox being disabled is a documented choice for the current
  independently distributed build.
- Releases not being notarized is a distribution limitation, not by itself a
  vulnerability.
- Recording pixels and overlays intentionally included in a user-triggered MP4
  export.
- The selected source PNG intentionally returned to the connected local MCP
  client during a user-approved session. The client controls onward model or
  network processing.
- Data surviving app deletion under Application Support.
- Issues requiring an attacker who already has local code execution as the
  logged-in user.

Storybird has no account, cloud sync, telemetry, or automatic update download.
Adding a network path is a security-sensitive behavior change.

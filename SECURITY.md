# Security Policy

## Supported Versions

Before the first tagged release, security fixes target the `main` branch. After
releases begin, only the latest public Storybird release is supported; fixes
ship in a new release rather than being backported.

## Reporting a Vulnerability

Report privately through GitHub Security Advisories:

`https://github.com/haandol/storybird/security/advisories/new`

Include the impact, reproduction steps, Storybird version, and macOS version.
Do not attach captured screens, exported demos, project libraries, credentials,
or analytics data.

## In Scope

Storybird holds Screen Recording and Input Monitoring permission and stores
captured product content locally. Important failures include:

- screenshots, thumbnails, click coordinates, or projects leaving the Mac;
- keyboard input being collected despite the mouse-only permission boundary;
- capturing outside the display or window explicitly selected by the user;
- another process borrowing Storybird's permissions or recording session;
- path traversal, asset collisions, or writes outside the Storybird library or
  an explicitly selected export folder;
- agent recording packages containing unexpected files or fields, symbolic
  links, non-PNG assets, or hidden browser/session data;
- stored or exported script injection through project or hotspot text;
- accidental inclusion of Storybird's editor or HUD in captures;
- unstable signing that disconnects the app from an existing TCC grant.

## Out of Scope

- App Sandbox being disabled is a documented choice for the current
  independently distributed build.
- Releases not being notarized is a distribution limitation, not by itself a
  vulnerability.
- Captures intentionally included in a user-triggered static export.
- Visible screenshots and normalized click positions intentionally included in
  a user-triggered agent recording package import.
- Data surviving app deletion under Application Support.
- Issues requiring an attacker who already has local code execution as the
  logged-in user.

Storybird has no account, cloud sync, telemetry, or automatic update download.
Adding a network path is a security-sensitive behavior change.

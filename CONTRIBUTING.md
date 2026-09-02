# Contributing to Storybird

Issues and pull requests are welcome. Read the
[architecture invariants](./AGENTS.md#architecture-invariants) before changing
capture, permission, persistence, or export behavior.

## Build and Run

Storybird is a dependency-free Swift Package targeting macOS 14 or later and
uses Swift tools 6.2 (Xcode 26 or a compatible Swift 6.2 toolchain).

```bash
swift build -c debug
swift test
./build.sh release
open build/Storybird.app
```

Use the bundle for permission testing. A bare SwiftPM executable does not have
the same stable bundle identity used by macOS Transparency, Consent, and Control
(TCC).

Install the current release build with `./install.sh`. Replacing a bundle on
disk does not replace its running process, so quit Storybird before validating a
new build.

### Signing

`build.sh` chooses the first `Developer ID Application` or `Apple Development`
identity in the keychain. Override it when needed:

```bash
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" \
  ./build.sh release
```

Without a certificate the script falls back to ad-hoc signing. The app can
launch, but its designated requirement becomes code-hash-specific, so Screen
Recording and Input Monitoring permission may need approval after every build.

### Replacing the App Icon

Generate the artwork with a character image you have permission to use, review
it at both 1024px and 64px, then save the approved 1024×1024 PNG as
`Resources/AppIcon-generated.png`.

Do not commit the reference character image unless its license explicitly
permits redistribution. Keep `Resources/AppIcon.svg` as the deterministic
fallback used when the generated PNG is absent. Never place API keys in the
repository.

## ADR-First Workflow

Behavior contracts live under `docs/adr/`. Update the relevant ADR before
implementing a changed decision, then land the ADR, code, and tests in one
commit. Bug fixes, formatting, documentation, and behavior-preserving
refactors do not need a new ADR.

An ADR records why a choice won, at least two realistic alternatives, and the
contract a reimplementation must preserve. It does not record file paths,
functions, or schemas already obvious from code.

## Automated Tests

Tests live in `Tests/StorybirdCoreTests/` and run with `swift test`. Name them
`test_<behavior>_<expectedResult>()`.

- Do not use real screens, windows, click monitors, user projects, or network.
- Redirect filesystem work to a unique temporary directory.
- Test coordinate boundaries, click linkage, persistence, migration, analytics,
  export escaping, and bundle metadata.
- Match actor isolation in tests; never weaken production annotations.
- Deliberately break a guarded behavior once to prove its regression test fails.

## Manual Smoke Test

ScreenCaptureKit and TCC behavior require a real signed bundle:

1. Open `build/Storybird.app` and grant Screen Recording/Input Monitoring.
2. Confirm the source sheet fits on screen and scrolls internally.
3. Resize the main window to its minimum size. Confirm the project sidebar
   collapses, screen selection moves to a menu, and the inspector opens as a
   sheet without clipping.
4. Verify thumbnails appear for the display and unfocused app windows.
5. Select a window, perform three paced clicks, and stop after the final click.
6. Confirm each previous screen has a hotspot targeting the next screen.
7. Preview the flow and finish it; check local analytics.
8. Export to a temporary folder and open `index.html`.
9. Rebuild and confirm the same signing identity keeps permissions.
10. On first launch after renaming, confirm an OpenLane library is copied while
   the original remains untouched.

Use synthetic content. Never put customer dashboards, messages, credentials, or
other private captures in issues, commits, or pull request attachments.

## Coding Style

Use four spaces and standard Swift API naming. Prefer one primary type per file,
structured concurrency, and explicit actor isolation. Keep UI/AppKit code in
`Storybird` and deterministic logic in `StorybirdCore`.

Comments explain non-obvious permission, timing, coordinate, and durability
rules. No formatter or linter is configured, so match nearby code and run
`swift build -c debug` to catch warnings.

## Commits

Storybird follows Conventional Commits:

```text
<type>(<scope>): <subject>
```

Types are `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `chore`, `style`,
and `ci`. ADR scopes are `recording`, `authoring`, `library`, and `sharing`;
`build` covers repository and distribution tooling.

Subjects are English, lowercase, imperative, have no trailing period, and stay
within 72 characters. Bodies explain why. One logical change belongs in one
commit; the ADR and implementation of one decision land together.

## Pull Requests

Use a commit-style title and this body:

```markdown
## Summary

## Motivation

## Verification

## Impact
```

List exact commands and manual checks. Include synthetic screenshots for UI
changes and call out permission, storage, bundle identity, and export changes.

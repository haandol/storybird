# Repository Guidelines

This is the agent-facing contract for Storybird. Keep the contributor-facing
documents aligned when a rule changes:

- [`README.md`](./README.md): product, installation, permissions, and usage
- [`CONTRIBUTING.md`](./CONTRIBUTING.md): build, tests, smoke checks, commits
- [`docs/Troubleshooting.md`](./docs/Troubleshooting.md): symptom-based recovery
- [`docs/adr/`](./docs/adr/): architectural decisions and rejected alternatives

## Project Structure & Module Organization

Storybird is a local-first SwiftUI macOS application.

- `Sources/Storybird/`: UI, ScreenCaptureKit coordination, recording lifecycle.
- `Sources/StorybirdCore/`: models, timeline validation, persistence, geometry.
- `Sources/StorybirdMCPKit/`: stdio MCP tools and capture/pointer contracts.
- `Sources/StorybirdMCP/`: companion executable entry point.
- `Tests/StorybirdCoreTests/`: deterministic XCTest coverage.
- `Tests/StorybirdTests/`: app-host, MCP protocol, media and synthetic UI tests.
- `Resources/`: bundle metadata, entitlements, editable SVG app icon.
- `docs/adr/`: ADR registry and decision records.
- `.agents/skills/prepare-storybird-release/`: release audit harness.
- `Tests/StorybirdTests/DocumentationScreenshotTests.swift`: opt-in synthetic
  README screenshot harness.

Generated artifacts belong in `.build/`, `build/`, and `dist/`. Never edit or
commit them as source.

## Architecture Invariants

Before changing behavior, read the relevant rules in
[`docs/ArchitectureInvariants.md`](docs/ArchitectureInvariants.md) and the owning
ADR. The detailed rules are maintained there; do not duplicate them here.
In particular, preserve local capture, native consent boundaries, app-owned
atomic project writes, original media, revision checks, and undo.

## Decision Scope

Apply the ADR admission gate to changed requirement contracts, domain invariants,
state/permission rules, system/data/security boundaries, providers/fallbacks,
adopted algorithms, consistency models, and durable trade-offs. Requirement
values and rules count even when the code change is small. Restorative bug fixes,
docs/operations, replaceable implementation choices, and behavior-preserving
refactors are exempt.

For admitted changes, read the full `docs/adr/.mapping.json` and plausible owners,
update the existing owner before creating another, and confirm the changed
contract once before implementation. Proposed or missing prerequisites block
implementation. Do not infer approval requirements from exempt maintenance.

## Build, Test, and Development Commands

- `swift build -c debug`: compile with Swift 6 actor race checks.
- `swift test`: run deterministic unit tests without network access.
- `swift run StorybirdMCP`: run the development companion; privileged capture
  and pointer testing still belongs to the signed Storybird app.
- `./build.sh release`: create and sign `build/Storybird.app`.
- `open build/Storybird.app`: run the bundle that owns macOS TCC permissions.
- `./install.sh`: build and replace `/Applications/Storybird.app`.

Run Storybird as an app bundle, not with `swift run`, when testing Screen
Recording, Input Monitoring, or Accessibility pointer-control permissions.

### Release execution

Follow the requested outcome: preparation stays local, an explicitly requested
draft stays a draft, and registering/publishing a prepared release proceeds
through `--publish` to public Latest status. Reuse authorization and verified
artifacts for the same target. Report unperformed native or optional checks
honestly; their absence alone must not downgrade a publication request to a draft.
Resolve actual build/test/signature failures, tag/version/checksum conflicts,
upload or remote-state errors, and known data-loss/security defects. Honor any
checks the user explicitly makes a prerequisite for that release. Git pushes
remain the user's action in `.devcontainer`.

`scripts/push-version.sh VERSION` pushes only the prepared version tag from
`.devcontainer`. After the user reports that prepared tag was pushed, verify it
and use authenticated local macOS `gh` to finish publication and Latest without
another confirmation. Do not copy GitHub API credentials into the container for
this handoff. Ordinary branch pushes are not release requests.

## Coding Style & Naming Conventions

Use four spaces and standard Swift naming: `UpperCamelCase` types,
`lowerCamelCase` members, descriptive enum cases, and a `View` suffix for
SwiftUI views. Keep UI/AppKit coordination in `Storybird`; keep deterministic
business logic in `StorybirdCore`.

Do not weaken Swift 6 concurrency checks to silence a diagnostic. Preserve
explicit actor isolation and use a lock or actor for callback-owned state.
Comments explain non-obvious permission, timing, coordinate, or data durability
behavior and include measured evidence when one drove the rule.

## Testing Guidelines

### MCP feature completion gate

Every feature implementation must include its MCP support and verification in
the same change. Review user actions and editable properties, not just tool names.
The existing project-editing ADR requires full UI/MCP editing parity.

- Before implementation, map each changed action/property to an advertised MCP
  tool, its arguments, app handler, shared validation and observable result.
  Maintain the inventory in [`docs/MCPFeatureParity.md`](./docs/MCPFeatureParity.md).
- Implement missing MCP paths alongside the UI. Reuse app-owned domain edits,
  revision checks, atomic persistence and undo; never bypass them with direct
  library writes or UI automation.
- Native-only consent, voice-profile reference-file selection, microphone, voice-profile
  management and non-model Settings remain subject to their owning ADRs. View-only controls
  may use an equivalent preview/edit tool without reproducing the window gesture.
  Record the exact exception and its owner; do not label ordinary editing
  omissions "UI-only". A new exception or permission expansion needs the ADR
  admission/confirmation gate before implementation.
- Add or update schema/property coverage in `MCPFeatureParityTests` and behavior
  tests through the app host. For changed public protocol behavior, exercise the
  production MCP handlers with an MCP client, as in `MCPAudioProtocolTests`.
  Verify the successful result plus relevant stale revision, invalid input,
  partial-save prevention, undo and async terminal states. Tool existence alone
  is not behavior evidence.
- Keep `docs/MCP.md`, the feature inventory, README guidance and the video
  production skill aligned when affected. Run `swift test` and applicable signed
  smoke checks. Report unverified native/runtime checks explicitly.
- Do not mark a feature complete with an unexplained MCP gap or failing parity
  check. The PR must state the MCP path, test evidence and any ADR-backed
  exception. Passing inventory tests does not discover new UI actions; reviewers
  must compare the changed UI and domain behavior with the inventory.

Name tests `test_<behavior>_<expectedResult>()`. Tests must not access the
network, real ScreenCaptureKit sources, or the user's actual Application
Support directory. Use temporary directories and measured boundary values.
When adding a regression test, deliberately break the guarded behavior once and
confirm the test fails.

### Select checks by impact

Use the [verification matrix](CONTRIBUTING.md#verification-by-change) and the
[manual smoke catalog](CONTRIBUTING.md#manual-smoke-test). Run relevant tests
while editing, then `swift test` for code changes. Documentation-only edits need
path/link and consistency checks; release-script changes need their isolated
Python regression suites. Do not require microphone or capture approval for
unrelated maintenance, and do not report synthetic tests as native verification.

Regenerate affected UI documentation with the
[synthetic screenshot harness](CONTRIBUTING.md#documentation-screenshots), then
review the changed images. Never substitute a real project library or recording.

## Commit & Pull Request Guidelines

Use Conventional Commits: `<type>(<scope>): <subject>`.

- Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `chore`, `style`,
  `ci`.
- ADR scopes: `recording`, `authoring`, `library`, `sharing`.
- Extra scope: `build`.
- Subjects are English, lowercase, imperative, no period, at most 72 chars.

Behavior decisions update the relevant ADR before code and land together.
Pull requests use a commit-style title and sections for Summary, Motivation,
Verification, and Impact. Include synthetic screenshots for UI changes. Never
attach captured customer screens or exported customer demos.

## Security & Privacy

Never commit recordings, capture thumbnails, generated project libraries,
credentials, or files from `~/Documents/Storybird` or
`~/Library/Application Support/Storybird`. Treat any
change that expands permissions, storage scope, export content, or network
access as a security-sensitive behavior change requiring an ADR.

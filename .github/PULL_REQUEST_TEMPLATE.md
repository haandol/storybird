## Summary

## Motivation

## Verification

- [ ] Applicable checks from `CONTRIBUTING.md#verification-by-change` completed
- [ ] `swift test` for Swift code changes (also builds debug targets)
- [ ] Relevant signed manual smoke results recorded, including unperformed checks
- [ ] Synthetic documentation screenshots regenerated when README UI changed

## Impact

Describe permission, storage, project-format, export, signing, voice-reference,
or model-download changes. Write `None` when there is no impact.

## MCP Support

- [ ] Every changed action/property has an MCP path, or an explained existing ADR exception
- [ ] `docs/MCPFeatureParity.md` and affected tool/workflow documentation are current
- [ ] Schema/property and app-host behavior tests cover the change; protocol tests updated when affected

List the tools and arguments, shared behavior, exact checks/results, and any
native-only or view-only exception with its owning ADR. For non-feature changes,
state why MCP behavior is unaffected. Tool-list checks alone do not prove parity.

## UI Evidence

Include synthetic screenshots for UI changes. Never attach customer captures,
credentials, private messages, or exported customer demos.

## Decision Record

Choose the applicable case and explain it:

- No admitted decision changed (for example, a restorative bug fix or docs edit).
- An admitted contract changed: its owning ADR and `.mapping.json` were updated,
  confirmed once before implementation, and landed with the implementation.

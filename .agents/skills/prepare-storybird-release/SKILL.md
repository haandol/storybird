---
name: prepare-storybird-release
description: Prepare, audit or publish a Storybird release from verified shipped changes, with Korean release notes, synchronized versions, a signed ZIP and confirmed GitHub state. Use for release preparation, release-note work, readiness checks or requested publication; ordinary feature development uses its own workflow.
---

# Prepare Storybird Release

Keep the release commit, public description and downloadable app consistent. Use
the repository's existing scripts (`collect_release_facts.sh`, `push-version.sh`,
`publish-release.sh`) and GitHub CLI; do not create a per-release replacement
pipeline.

## Scope and authorization

| Request | Completion state |
| --- | --- |
| Prepare, audit or check readiness | Local version, tag, notes and verified ZIP, or findings. No remote writes. |
| Draft | GitHub draft with verified assets. |
| Release, publish, or push and release ("릴리즈해줘") | Agent pushes `main` and the tag through `.devcontainer`, publishes with `--publish`, and confirms Latest. |
| User reports a prepared tag was pushed | Verify the remote tag, then publish without another confirmation. |
| Status question during a release | Answer with current facts, then continue to the requested completion. |

- An explicit release or push request authorizes the remote stages after the
  required checks. Honor authorization already established in the session; do not
  ask again just because a later stage is remote. A local bump, a draft or a
  successful push alone is not completion of a publication request.
- Follow the caller's version preference. Otherwise increment the patch component.
- Every Git push runs inside this repository's `.devcontainer`, never from the
  macOS host first and never as a host fallback. GitHub release API work runs with
  the existing macOS `gh` authentication; never copy credentials into the container.
- Preserve unrelated work and existing public releases. Do not overwrite published
  tags or assets. Do not include recordings, capture thumbnails, project
  libraries, credentials or personal paths in commits, notes or assets.
- Respect branch protection, hooks and CI. Report a real signing, test, CI,
  permission or remote-state blocker; never bypass it or describe an unperformed
  check as passed. Record unperformed native smoke checks honestly; their absence
  alone does not downgrade an authorized publication to a draft.
- Versioning, notes and packaging do not need an ADR. Apply the repository's
  ADR admission gate if a release requires a product behavior change.

## Resolve the working paths

Use the checkout as the working directory. Reuse instructions already read in the
session (`AGENTS.md`, `CONTRIBUTING.md`); read `README.md`, `Resources/Info.plist`,
`build.sh` and affected ADRs or troubleshooting guidance only as release impact
requires.

`SKILL_DIR` means the absolute directory containing this file; it is not a
pre-existing environment variable. Invoke the bundled collector by that path from
the checkout. Keep generated notes, logs and packages under ignored `build/`.

## Load the current stage

| Stage | Reference and result |
| --- | --- |
| Candidate and version | [release-candidate.md](references/release-candidate.md): fixed target, preceding public release and synchronized versions. |
| Public explanation | [release-notes.md](references/release-notes.md): Korean notes grounded in shipped changes and real checks. |
| Validation and packaging | [release-validation.md](references/release-validation.md): tests, signed app, verified ZIP and checksum. |
| Push and publication | [release-publication.md](references/release-publication.md): container pushes, CI on the exact commit, tag push and verified publication. |

Read only the stages the request needs. Reuse verified artifacts and evidence for
the same target; repeat only the checks whose sources or artifacts changed.

Report the target version and full commit, change summary, notes and ZIP paths with
the checksum, test and signature results, unperformed checks, and which of commit,
`main` push, CI, tag push, draft and publication actually completed.

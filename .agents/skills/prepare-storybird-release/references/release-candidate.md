# Candidate and version

Inspect the working tree, branch and remote. From the checkout, run the read-only
collector:

```bash
"$SKILL_DIR/scripts/collect_release_facts.sh" --target HEAD --online
```

Use `--target <ref>` for a specific candidate, `--json` for structured output, and
omit `--online` only when GitHub access is unavailable.

- `local_tag`, `remote_tag` and `release_state` are separate facts. A local tag or
  draft does not mean the version was published.
- `release_state: unknown` means the lookup failed or did not run; it is not `absent`.
- `comparison` uses the reachable preceding published release. If that base cannot
  be established, do not report the change list as complete.
- If the target is already published, verify it and report it; do not publish it
  again or invent an empty next release. On a retry, inspect existing tags,
  releases and assets first.

The commit range excludes uncommitted files. Review and commit the authorized
release sources before fixing the target; do not package an ambiguous mixture of
the candidate and unrelated local edits. Read the complete commit messages and
diff since the base, plus affected ADRs and user documentation. PRs, issues and
automatically generated notes reveal omissions, but the target commit is the
shipping evidence.

Use the user's exact version or requested increment. Otherwise increment the patch
component; a `feat` label or a large diff does not authorize a minor bump. If a
real compatibility conflict requires a user decision, explain it with the
prepared changes.

Keep these values consistent:

| Location | Value |
| --- | --- |
| `Resources/Info.plist` `CFBundleShortVersionString` | `X.Y.Z` |
| `Resources/Info.plist` `CFBundleVersion` | integer greater than the preceding public build |
| annotated tag / GitHub title | `vX.Y.Z` (message `Storybird X.Y.Z`) / `Storybird X.Y.Z` |
| ZIP / Korean notes | `build/Storybird-X.Y.Z.zip` / `build/release-notes-vX.Y.Z.md` |

Edit only the two version strings in `Resources/Info.plist`. `plutil -replace`
rewrites the whole file with tabs and reordered keys, so check that the diff is the
two changed lines and that `plutil -lint` passes. A version-only commit uses
`chore(build): bump version to X.Y.Z`. Keep the version fixed across retries
unless the existing published state requires a new release.

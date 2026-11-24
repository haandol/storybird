# Push and publish

Use this stage only for an authorized publication request. Before the first remote
write, show the version, full target SHA, release title, notes path and ZIP
checksum in one concise progress update. That update is not a new approval step.

## Run pushes in the devcontainer

Every Git push runs in this repository's running `.devcontainer`. Find it by the
checkout path; the repository is mounted at `/workspaces/storybird` and the SSH
remote uses the mounted `~/.ssh`:

```bash
container="$(docker ps --filter "label=devcontainer.local_folder=$PWD" --format '{{.ID}}' | head -n 1)"
in_container() { docker exec -w /workspaces/storybird "$container" sh -c "$1"; }
```

If no container is running, report that blocker and ask the user to start the
devcontainer. Do not push from the macOS host, and never fall back to it. Warnings
about unsupported `gssapi*` options in the mounted SSH config are harmless.
Resolve an explicit hook or security denial before retrying; never bypass it.

## Push main and wait for CI

Confirm the container sees the release commit and that the prepared tag is
consistent, then push the branch:

```bash
in_container "git log --oneline -1 && ./scripts/push-version.sh X.Y.Z --check"
in_container "git push origin main"
```

Wait for the GitHub Actions run on that exact commit to finish successfully before
pushing the tag:

```bash
run_id="$(gh run list --commit FULL_COMMIT_SHA --workflow ci.yml --json databaseId --jq '.[0].databaseId')"
gh run watch "$run_id" --exit-status --interval 30
```

Never use a force push, an administrator bypass or a disabled hook. If CI fails,
stop before the tag push, fix the cause in a new commit and prepare the version on
that commit. Do not tag a stale head or an unpushed commit.

## Push the tag and publish

```bash
in_container "./scripts/push-version.sh X.Y.Z"
"$SKILL_DIR/scripts/collect_release_facts.sh" --target vX.Y.Z --online
bash scripts/publish-release.sh X.Y.Z FULL_COMMIT_SHA VERIFIED_ZIP_SHA256 --publish
```

`push-version.sh` pushes only the existing annotated tag and its commit. An
identical remote tag is a no-op; a different remote tag stops. Confirm that
`remote_tag` matches the prepared commit before publishing. Take the checksum from
the verified ZIP record, never from an unverified file.

`--publish` checks the inputs, creates or resumes its intermediate draft, uploads
the ZIP and its `.sha256` companion, re-downloads both, publishes and marks
Latest in one run; a separate `--check` or `--draft` is unnecessary. A draft or
release with any other asset set, such as a partial upload, stops for inspection.
Its output includes the intermediate draft's `untagged-…` URL before the final
release URL. Use `--draft` only when a draft is the requested result, and
`--check` for a read-only audit. The legacy `--push` mode is not used; pushes go
through the container.

If the user pushed the tag themselves and reports it, start from the remote tag
check above without asking again.

## Confirm the public state

```bash
gh release view vX.Y.Z --json tagName,name,isDraft,isPrerelease,assets
gh api repos/haandol/storybird/releases/latest --jq .tag_name
download_dir="$(mktemp -d)"
gh release download vX.Y.Z --pattern 'Storybird-X.Y.Z.zip' --pattern 'Storybird-X.Y.Z.zip.sha256' --dir "$download_dir"
(cd "$download_dir" && shasum -a 256 -c Storybird-X.Y.Z.zip.sha256)
```

Confirm `isDraft=false`, the tag and title, Latest, exactly the two assets, and
that the downloaded companion verifies the downloaded ZIP. Remove only the
temporary download directory. Do not use `--clobber` or move tags to change
published content. On failure, report which remote stages
completed (`main` push, CI, tag push, draft, publication) and what remains; the
pushed refs stay intact.

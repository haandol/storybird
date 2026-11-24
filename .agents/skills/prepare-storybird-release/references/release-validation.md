# Validate and package the candidate

Build and test the exact release commit on macOS:

```bash
swift test
test -x .build/test-python/bin/python || python3 -m venv .build/test-python
.build/test-python/bin/python -m pip install -r scripts/requirements-test.txt
.build/test-python/bin/python scripts/run-python-tests.py
./build.sh release
codesign --verify --deep --strict --verbose=2 build/Storybird.app
codesign --verify --strict --verbose=2 build/Storybird.app/Contents/MacOS/StorybirdMCP
codesign -dv --verbose=4 build/Storybird.app
codesign -dv --verbose=4 build/Storybird.app/Contents/MacOS/StorybirdMCP
```

`swift test` and `./build.sh release` share `.build`; run them one after the other.
Record the real Swift totals, skips and failures, and the Python suite result.
Reuse a passing full suite for the same sources instead of repeating it.

Require a real `Apple Development` or `Developer ID Application` signature with the
same nonempty `TeamIdentifier` on the app and the MCP companion executable. The build script's
ad-hoc fallback is not a releasable build: TCC permissions would not persist.
Storybird is not notarized; follow the installation wording in the notes guide.

Use the affected-area manual smoke checks in `AGENTS.md`/`CONTRIBUTING.md`. Reuse
existing evidence, distinguish newly performed checks from unperformed ones, and
never report a synthetic test as native capture, click, microphone or permission
verification. An unperformed check is recorded, not treated as a failure. It
blocks publication only when the user made it a prerequisite or a real defect was
found.

Package the checked app with macOS metadata preserved. Before reusing an existing
archive path, confirm it is the matching verified candidate; never overwrite an
unrelated or published asset.

```bash
release_version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
release_archive="build/Storybird-${release_version}.zip"
test ! -e "$release_archive"
ditto -c -k --sequesterRsrc --keepParent build/Storybird.app "$release_archive"
unzip -t "$release_archive"
(cd build && shasum -a 256 "Storybird-${release_version}.zip" > "Storybird-${release_version}.zip.sha256")
(cd build && shasum -a 256 -c "Storybird-${release_version}.zip.sha256")
```

The `.sha256` companion names the ZIP by basename, so users can run
`shasum -a 256 -c` in their download folder. `publish-release.sh` requires its
exact `<sha256>  Storybird-X.Y.Z.zip` line and uploads both files.

Extract the ZIP into a `mktemp -d` directory. Recheck the version, build number,
strict signatures and `TeamIdentifier` of the app and the MCP companion, then
remove only that directory. The tag commit, bundle, file names, notes and checksum must
agree.

Create the annotated tag locally on the exact release commit:

```bash
git tag -a "v${release_version}" -m "Storybird ${release_version}" FULL_COMMIT_SHA
```

If the tag already exists, confirm it targets the same commit; never move it.
Later tooling commits do not require moving the tag or rebuilding the app.

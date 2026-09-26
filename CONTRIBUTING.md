# Contributing to Sayo

Develop and test on `dev`. Send contributor PRs to `dev`; only a tested `dev` PR is merged into `main`. `main` contains public release code. A maintainer's `local` branch, if present, is a frozen private archive and must never be pushed or merged into public history.

## Build and test

Use macOS 14 or later with Xcode command line tools and Swift 6. The app supports Apple Silicon and Intel.

```sh
swift test
python3 -m unittest discover -s Tests/ReleaseTests -v
python3 scripts/check_public_tree.py
python3 scripts/release_notes.py check
bash scripts/build-app.sh release
```

The universal app is built at `dist/direct/Sayo.app`. A Developer ID certificate is used when available; otherwise local development builds are ad-hoc signed. Set `SAYO_SIGNING_IDENTITY=-` for an explicitly ad-hoc-signed development build. Building does not install, upload, notarize, or publish anything.

Install bash 4+ and fish to run all terminal behavior tests. Set `SAYO_TEST_BASH` and `SAYO_TEST_FISH` to their executable paths if needed. Missing runtimes are reported as skipped, not verified. UI/accessibility behavior needs separate foreground-app acceptance on macOS.

## Update notes

Add a uniquely named `updates/<short-name>.json` with each change intended for the next main merge. Do not edit or delete existing notes. Keep each bullet to one JSON string without embedded newlines:

```json
{
  "bump": "patch",
  "en": ["Describe the user-visible change."],
  "zh-CN": ["描述用户可感知的变化。"]
}
```

Use `patch` for fixes, `minor` for features, or `major` for a major release. The highest requested level among pending notes wins. Version components are `x.y.z`, with `y <= 99` and `z <= 999`; overflowing patch or minor increments the next component. The build number is calculated as `x * 100000 + y * 1000 + z`.

Do not manually change the Info.plist version, `Distribution/versions.json`, or generated `UPDATE_NOTES.md`. After a dev-to-main merge, the version bot records pending notes, commits the new version to main, then merges that commit back into dev without force pushing. Wait for this synchronization before the next release PR. If it conflicts, merge main into dev, resolve the conflict, and rerun the version workflow. Repeated runs do not bump already-processed notes.

Initial public history contains one root commit at version `0.1.0`. This history reset is a one-time migration; do not rewrite published history afterward. Internal `docs/`, design experiments, credentials, and generated artifacts are excluded from both public branches. Public README, contributor guidance, license, and update notes are intentionally included.

Create `dev` from `main` when establishing a checkout's development branch. Local tool directories `.agent/`, `.agents/`, `.claude/`, and `.codex/` must stay out of public commits, including when nested inside another directory. They are ignored locally and rejected by public-tree checks and the installed push guard, even if an earlier commit added them and a later commit removed them.

## Releases

See [.github/RELEASE_SETUP.md](.github/RELEASE_SETUP.md) for repository settings and credentials. A version commit does not automatically create a tag. A maintainer chooses a `vX.Y.Z` tag after the version workflow and dev checks finish; the tag workflow builds and publishes that exact revision.

To preview release notes locally without a tag, network writes, or credentials:

```sh
python3 scripts/release_notes.py body --tag v0.1.0
```

For later versions, pass `--previous vX.Y.Z` using the preceding published release. The result includes every version's notes between those bounds, even when several main merges occurred between releases.

## Review expectations

Explain the change and how it was verified. Include the update-note filename. Keep secrets, personal paths, diagnostic transcripts, and internal design notes out of source and PRs. Report security-sensitive findings privately through the repository's private vulnerability reporting feature when enabled.

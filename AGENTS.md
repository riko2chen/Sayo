# Development and release branches

- Develop, run feature tests, and commit verified changes on `dev`. Submit contributor PRs to `dev`.
- `main` is the public release branch. Merge tested `dev` through a PR; the version workflow owns version commits.
- `local`, if present in a maintainer checkout, is a frozen private archive. Never edit it, merge it into public branches, push it, or push its history under another ref.
- Do not push or publish unless the user authorizes that action. A local push lock must not be removed without explicit approval.
- Never track internal `docs/`, personal records, signing credentials, or generated build artifacts in public branches.
- Add an immutable `updates/<unique-name>.json` note with each user-visible change. See CONTRIBUTING.md.
- Do not manually change the version ledger or Info.plist version during ordinary development.
- Commit each completed and verified feature before starting another. Do not rewrite published history.

# Verification

Run the relevant tests, then the checks described in CONTRIBUTING.md. Build a release for changes that affect packaging or application behavior.
Use computer use for UI acceptance and restore settings changed during verification. Test caret movement in the foreground app; background-targeted actions do not change system-wide focus. Distinguish simulated states, unit tests, and real UI checks.
Installing a local build is a separate maintainer action: when requested, quit Sayo, copy the verified bundle, launch it, check the signature and executable hashes, and verify the running process started after installation.

In the original maintainer checkout identified by `sayo-local-archive.json` in Git's common directory, the standing request is to build and install the latest release in `/Applications/Sayo.app` after tests pass. Quit the running instance before copying, then launch the installed copy and perform the checks above. Fresh contributor clones do not inherit this installation request.

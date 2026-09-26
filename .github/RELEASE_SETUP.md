# Maintainer release setup

Repository: `riko2chen/Sayo`. Setup below is a separate remote operation; local scripts do not configure GitHub, upload credentials, create tags, or publish releases. Never paste secrets into issues, PRs, update notes, or logs.

## GitHub settings

- Keep `main` as the default branch. Require PRs and the `Development checks` check. Release PRs must be from this repository's `dev` branch; CI enforces that restriction.
- Allow merge commits and use a normal merge for the long-lived dev-to-main PR. Do not auto-delete dev. Disable force pushes/deletion on public branches.
- Create a dedicated GitHub App installed only on this repository with Contents read/write and Metadata read permissions. Allow only that App to bypass main's PR requirement for version commits. Store its numeric ID in repository variable `RELEASE_APP_ID`, and its PEM private key in repository secret `RELEASE_APP_PRIVATE_KEY`.
- The App token is used for version commits and dev synchronization, so the resulting dev push triggers CI. The default GITHUB_TOKEN does not trigger another push workflow. The version workflow neither creates a tag nor publishes a release.
- Protect `v*` tags against update/deletion and restrict their creation to maintainers. A tag cannot be used to release code outside main's first-parent history.
- Create the `release` environment. Allow version tags (`v*`) and main (needed for retry dispatch). Restrict access to its secrets to trusted release jobs. An optional environment reviewer approval adds a manual checkpoint; omit reviewers for automatic publication on tag push.
- Enable private vulnerability reporting and review dependency/license alerts for the public repository.

## Release environment secrets

| Secret | Value |
|---|---|
| `SIGNING_CERTIFICATE_P12_BASE64` | Base64 of a Developer ID Application `.p12` export, including its private key |
| `SIGNING_CERTIFICATE_PASSWORD` | Password protecting that export |
| `NOTARY_KEY_P8_BASE64` | Base64 of an App Store Connect API private key authorized for notarization |
| `NOTARY_KEY_ID` | API key ID |
| `NOTARY_ISSUER_ID` | API issuer ID |
| `SPARKLE_PRIVATE_KEY` | Existing Sparkle private signing key in the format accepted by `sign_update --ed-key-file` |

Reuse the Sparkle key matching `Distribution/release.json`; do not generate a replacement for routine releases. The public key in source is intentionally public. Exporting local signing keys and adding these secrets require a separate maintainer decision; the automation never exports the maintainer's Keychain. Missing credentials fail the release instead of publishing an ad-hoc or unsigned update.

Signing credentials are imported into a temporary runner keychain/files and removed in an always-run cleanup step. Untrusted PR CI has no signing secrets and performs only development builds.

## Release sequence

1. Develop/test on dev and add immutable update notes. Merge the checked dev PR into main.
2. `Version merged changes` adds a version commit and synchronizes dev. Wait for it and the resulting dev checks to succeed. The initial public root is already versioned as `0.1.0` and needs no extra bump.
3. Fetch main and create an annotated `vX.Y.Z` tag pointing at its version commit. Push that one tag. Do not push several release tags together.
4. `Publish tagged release` verifies tag ancestry, canonical version, calculated build, complete notes, and public source history. It selects the preceding published stable release, not an unpublished tag or draft.
5. It builds a Universal 2 app, signs the app and DMG, notarizes and staples the DMG, then generates a Sparkle-signed appcast retaining previous entries and a checksum file.
6. It creates/updates a draft with combined English/Chinese notes, uploads DMG/appcast/checksums, downloads and verifies those bytes, and only then publishes as latest. Published versions are never overwritten or downgraded.

Only one release runs at a time. GitHub concurrency retains at most one pending run; publish one tag at a time and retry any superseded pending tag when appropriate. Retrying an already public release is a no-op. Failed unpublished drafts can be retried from the Actions UI using the existing tag. A draft may be replaced during a retry; a public release may not. No credentials or intermediate build folders are uploaded as artifacts.

The app reads `https://github.com/riko2chen/Sayo/releases/latest/download/appcast.xml`. It will remain unavailable until the first complete release is published. After initial publication, perform a real old-version-to-new-version update acceptance test, including download, signature verification, installation, and restart. Local fixture tests do not prove that online path.

## Local archive protection

Run `python3 scripts/install_local_guards.py` to install the local push guard. In a migration checkout, archive metadata and a push lock live in Git's common directory, outside tracked source. The guard rejects local/private history even if aliased as main or a tag. It also rejects internal files in public ancestry. It never removes an existing push lock. Do not use `--no-verify`, `--all`, or `--mirror` to bypass archive protection.

The first public push after a one-time history migration must be reviewed separately because it may replace an existing README-only root. Normal subsequent work uses ordinary fast-forward pushes and PR merges.

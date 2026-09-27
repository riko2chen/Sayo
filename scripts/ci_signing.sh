#!/bin/bash
# GitHub-hosted macOS runner only. Never reads or exports a maintainer's keychain.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'CI signing setup is only for GitHub Actions.' >&2; exit 1; }
: "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}"
if [[ "${1:-}" == cleanup ]]; then
  security delete-keychain "$RUNNER_TEMP/sayo-signing.keychain-db" 2>/dev/null || true
  rm -f "$RUNNER_TEMP/sayo-signing.p12" "$RUNNER_TEMP/sayo-notary.p8" "$RUNNER_TEMP/sayo-sparkle.key"
  exit 0
fi
: "${SIGNING_CERTIFICATE_P12_BASE64:?}" "${SIGNING_CERTIFICATE_PASSWORD:?}"
: "${NOTARY_APPLE_ID:?}" "${NOTARY_APP_PASSWORD:?}" "${NOTARY_TEAM_ID:?}" "${SPARKLE_PRIVATE_KEY:?}"
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['RUNNER_TEMP'])
for variable, name, encoded in [
    ('SIGNING_CERTIFICATE_P12_BASE64', 'sayo-signing.p12', True),
    ('SPARKLE_PRIVATE_KEY', 'sayo-sparkle.key', False),
]:
    raw = os.environ[variable].strip()
    value = base64.b64decode(raw, validate=True) if encoded else raw.encode()
    with os.fdopen(os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'wb') as stream:
        stream.write(value)
PY
signing_keychain="$RUNNER_TEMP/sayo-signing.keychain-db"
signing_password="$(openssl rand -hex 32)"
security create-keychain -p "$signing_password" "$signing_keychain"
security set-keychain-settings -lut 21600 "$signing_keychain"
security unlock-keychain -p "$signing_password" "$signing_keychain"
security import "$RUNNER_TEMP/sayo-signing.p12" -P "$SIGNING_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$signing_keychain"
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$signing_password" "$signing_keychain" >/dev/null
security list-keychains -d user -s "$signing_keychain" "$HOME/Library/Keychains/login.keychain-db"
identity="$(security find-identity -v -p codesigning "$signing_keychain" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
[[ -n "$identity" ]] || { echo 'A valid Developer ID Application certificate is required.' >&2; exit 1; }
[[ "$identity" == *"($NOTARY_TEAM_ID)" ]] || { echo 'The signing identity and notarization team must match.' >&2; exit 1; }
xcrun notarytool store-credentials sayo-release \
  --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_APP_PASSWORD" --team-id "$NOTARY_TEAM_ID" \
  --keychain "$signing_keychain" --validate
printf 'SAYO_SIGNING_IDENTITY=%s\n' "$identity" >> "$GITHUB_ENV"
rm -f "$RUNNER_TEMP/sayo-signing.p12"

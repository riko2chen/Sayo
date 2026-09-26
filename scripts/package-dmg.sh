#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != --skip-build ]]; then
  if [[ $# -gt 0 ]]; then echo 'Usage: scripts/package-dmg.sh [--skip-build]' >&2; exit 2; fi
  bash scripts/build-app.sh direct release
fi
app="$PWD/dist/direct/Sayo.app"
python3 scripts/verify_distribution.py "$app" direct
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
final_dmg="$PWD/dist/direct/Sayo-$version-$build.dmg"
packaging_python="$PWD/.build/packaging-venv/bin/python"
if [[ ! -x "$packaging_python" ]]; then
  python3 -m venv "$PWD/.build/packaging-venv"
fi
# Build-only dependencies; never copied into either application.
"$packaging_python" -m pip install --disable-pip-version-check -r scripts/requirements-packaging.txt
background="$PWD/dist/direct/dmg-background.png"
swift scripts/make-dmg-background.swift "$background"
# dmgbuild combines this 1× image and its @2x sibling into a multi-resolution TIFF.
"$PWD/.build/packaging-venv/bin/dmgbuild" \
  -s scripts/dmg_settings.py -D "app=$app" -D "background=$background" \
  "Sayo" "$final_dmg"
identity="${SAYO_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
fi
if [[ -n "$identity" && "$identity" != - ]]; then
  codesign --force --sign "$identity" --timestamp "$final_dmg"
  codesign --verify --strict "$final_dmg"
fi
hdiutil verify "$final_dmg" >/dev/null
python3 scripts/verify_dmg.py "$final_dmg"
echo "Created $final_dmg (local only; not uploaded)"

#!/bin/bash
# Developer ID signing, using the same secret names as CE-Programming/CEmu.
# The extension and containing app have distinct sandbox entitlements.
set -euo pipefail
set +x
umask 077
stage="initialization"
trap 'status=$?; printf "Signing failed during: %s (exit %s)\n" "$stage" "$status" >&2; exit "$status"' ERR
progress() {
  stage="$1"
  printf '%s\n' "$stage"
}
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
app="${1:-$project_root/build/products/Release/Safari WebUSB.app}"
required=(MACOS_CERTIFICATE MACOS_CERTIFICATE_PWD MACOS_KEYCHAIN_PWD MACOS_CODESIGN_IDENT
  APPLE_NOTARIZATION_USERNAME APPLE_NOTARIZATION_PASSWORD APPLE_NOTARIZATION_TEAMID)
missing=()
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then missing+=("$name"); fi
done
if (( ${#missing[@]} )); then
  printf 'Missing signing/notarization secret: %s\n' "${missing[@]}" >&2
  exit 1
fi
test -d "$app/Contents/PlugIns/Safari WebUSB Extension.appex"
temporary=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/safari-webusb-sign.XXXXXX")
keychain="$temporary/signing.keychain-db"
restore_search_list=false
cleanup() {
  if [[ "$restore_search_list" == true ]]; then
    python3 - "$temporary/keychains.txt" <<'RESTORE' || true
import pathlib, shlex, subprocess, sys
original = shlex.split(pathlib.Path(sys.argv[1]).read_text())
subprocess.run(["security", "list-keychains", "-d", "user", "-s", *original], check=True)
RESTORE
  fi
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Decode through the environment; never place certificate contents in commands.
python3 - "$temporary/certificate.p12" <<'PY'
import base64, os, pathlib, sys
certificate = ''.join(os.environ['MACOS_CERTIFICATE'].split())
pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(certificate, validate=True))
PY
progress "Creating temporary signing keychain"
security create-keychain -p "$MACOS_KEYCHAIN_PWD" "$keychain"
progress "Configuring temporary signing keychain"
security set-keychain-settings -lut 21600 "$keychain"
progress "Unlocking temporary signing keychain"
security unlock-keychain -p "$MACOS_KEYCHAIN_PWD" "$keychain"
# codesign's --keychain limits certificate lookup, but private-key lookup also
# needs the keychain in the user search list. Keep the existing trust keychains.
progress "Registering temporary signing keychain"
security list-keychains -d user > "$temporary/keychains.txt"
restore_search_list=true
python3 - "$temporary/keychains.txt" "$keychain" <<'REGISTER'
import pathlib, shlex, subprocess, sys
original = shlex.split(pathlib.Path(sys.argv[1]).read_text())
subprocess.run(["security", "list-keychains", "-d", "user", "-s", sys.argv[2], *original], check=True)
REGISTER
progress "Importing signing certificate and private key"
security import "$temporary/certificate.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PWD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
progress "Authorizing signing-key access"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$MACOS_KEYCHAIN_PWD" "$keychain" >/dev/null

progress "Checking imported code-signing identities"
security find-identity -v -p codesigning "$keychain"

# The universal CI build is ad-hoc signed. Add the release team's macOS
# app-group entitlement to copies, without mutating generated build inputs.
python3 - "$temporary" <<'PY'
import os, pathlib, plistlib, re, sys
team = os.environ['APPLE_NOTARIZATION_TEAMID']
if not re.fullmatch(r'[A-Z0-9]{10}', team):
    raise SystemExit('Invalid Apple developer team identifier')
for name in ('Extension', 'App'):
    source = pathlib.Path('build/Safari WebUSB/Native') / (name + '.entitlements')
    entitlements = plistlib.loads(source.read_bytes())
    entitlements['com.apple.security.application-groups'] = [team + '.org.webtilp.safariwebusb']
    (pathlib.Path(sys.argv[1]) / source.name).write_bytes(plistlib.dumps(entitlements))
PY
progress "Signing embedded extension"
codesign --force --sign "$MACOS_CODESIGN_IDENT" --keychain "$keychain" --timestamp --options runtime \
  --generate-entitlement-der --entitlements "$temporary/Extension.entitlements" \
  "$app/Contents/PlugIns/Safari WebUSB Extension.appex"
progress "Signing containing app"
codesign --force --sign "$MACOS_CODESIGN_IDENT" --keychain "$keychain" --timestamp --options runtime \
  --generate-entitlement-der --entitlements "$temporary/App.entitlements" "$app"
progress "Verifying signed distribution"
python3 scripts/verify-distribution.py "$app" --release

progress "Validating notarization credentials"
xcrun notarytool store-credentials safari-webusb --keychain "$keychain" \
  --apple-id "$APPLE_NOTARIZATION_USERNAME" --password "$APPLE_NOTARIZATION_PASSWORD" \
  --team-id "$APPLE_NOTARIZATION_TEAMID" >/dev/null
progress "Packaging notarization submission"
ditto -c -k --keepParent "$app" "$temporary/notarization.zip"
progress "Submitting app for notarization"
if ! xcrun notarytool submit "$temporary/notarization.zip" --keychain-profile safari-webusb \
  --keychain "$keychain" --wait --timeout 20m --output-format json > "$temporary/result.json"; then
  echo 'Notarization submission did not complete.' >&2
  cat "$temporary/result.json" >&2
  exit 1
fi
status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$temporary/result.json")
if [[ "$status" != Accepted ]]; then
  submission=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$temporary/result.json")
  xcrun notarytool log "$submission" --keychain-profile safari-webusb --keychain "$keychain" \
    "$temporary/notarization-log.json"
  cat "$temporary/notarization-log.json" >&2
  exit 1
fi
progress "Stapling notarization ticket"
xcrun stapler staple "$app"
progress "Verifying signed distribution"
python3 scripts/verify-distribution.py "$app" --release --notarized
echo 'Developer ID signing, notarization and stapling succeeded.'

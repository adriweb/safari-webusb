#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
command -v pkg-config >/dev/null || { echo 'Install pkg-config (brew install pkgconf).' >&2; exit 1; }
./scripts/build-libusb.sh
export PKG_CONFIG_PATH="$project_root/build/deps/libusb/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export SAFARI_WEBUSB_DEPLOYMENT_TARGET="${SAFARI_WEBUSB_DEPLOYMENT_TARGET:-13.0}"
configuration="${BUILD_CONFIGURATION:-Release}"
architectures="${BUILD_ARCHS:-arm64 x86_64}"
case "$configuration" in Debug|Release) ;; *) echo 'BUILD_CONFIGURATION must be Debug or Release.' >&2; exit 1 ;; esac
for architecture in $architectures; do
  case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
done
test -f extension/page.js || { echo 'Missing extension/page.js' >&2; exit 1; }
converter=safari-web-extension-packager
if ! xcrun --find "$converter" >/dev/null 2>&1; then converter=safari-web-extension-converter; fi
if [[ ! -d 'build/Safari WebUSB/Safari WebUSB.xcodeproj' ]]; then
  xcrun "$converter" "$project_root/extension" --project-location "$project_root/build" \
    --app-name 'Safari WebUSB' --bundle-identifier org.webtilp.safariwebusb \
    --objc --macos-only --copy-resources --no-open --no-prompt
fi
python3 scripts/configure-project.py
signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
if [[ -n "${TEAM_ID:-}" ]]; then signing=("DEVELOPMENT_TEAM=$TEAM_ID" CODE_SIGN_STYLE=Automatic); fi
xcodebuild -project 'build/Safari WebUSB/Safari WebUSB.xcodeproj' -scheme 'Safari WebUSB' \
  -configuration "$configuration" -derivedDataPath build/derived-data \
  "CONFIGURATION_BUILD_DIR=$project_root/build/products/$configuration" \
  "ARCHS=$architectures" ONLY_ACTIVE_ARCH=NO "${signing[@]}" build "$@"
printf '\nBuilt: %s/build/products/%s/Safari WebUSB.app\n' "$project_root" "$configuration"

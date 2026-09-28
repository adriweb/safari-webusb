#!/bin/bash
# Read USB descriptors through a signed App Sandbox + USB entitlement.
# Never grants devices, claims interfaces, or sends application transfers.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
native='build/Safari WebUSB/Native'
app='build/USB Enumeration Probe.app'
test -f "$native/libusb-1.0.a" || { echo 'Run ./scripts/build.sh first.' >&2; exit 1; }
configuration="${BUILD_CONFIGURATION:-Release}"
deployment=$(plutil -extract LSMinimumSystemVersion raw -o - "build/products/$configuration/Safari WebUSB.app/Contents/Info.plist")
mkdir -p "$app/Contents/MacOS"
xcrun clang -fobjc-arc -O2 "-mmacosx-version-min=$deployment" -I"$native" \
  native/USBBackend.m native/Enumerate.m "$native/libusb-1.0.a" \
  -framework Foundation -framework IOKit -framework CoreFoundation -framework Security \
  -o "$app/Contents/MacOS/USBProbe"
python3 - <<'PY'
import pathlib, plistlib
path = pathlib.Path('build/USB Enumeration Probe.app/Contents/Info.plist')
path.write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'org.webtilp.safariwebusb.enumerate',
    'CFBundleExecutable': 'USBProbe', 'CFBundleName': 'USB Enumeration Probe',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSUIElement': True,
}))
PY
codesign --force --sign - --entitlements "$native/Extension.entitlements" "$app"
"$app/Contents/MacOS/USBProbe"

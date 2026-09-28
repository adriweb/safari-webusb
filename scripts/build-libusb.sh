#!/bin/bash
# Build the pinned dependency from source. All generated files stay in build/deps.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
command -v python3 >/dev/null
command -v pkg-config >/dev/null || { echo 'Install pkg-config (brew install pkgconf).' >&2; exit 1; }
IFS=$'\t' read -r libusb_version libusb_url libusb_sha deployment < <(python3 - <<'PY'
import json
from pathlib import Path
m = json.loads(Path('dependencies/libusb.json').read_text())
assert m['architectures'] == ['arm64', 'x86_64']
assert m['name'] == 'libusb'
assert all(c in '0123456789abcdef' for c in m['sha256']) and len(m['sha256']) == 64
print('\t'.join(m[k] for k in ('version', 'url', 'sha256', 'macos_deployment_target')))
PY
)
# Validate before using metadata in generated directory names and compiler flags.
[[ "$libusb_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$deployment" =~ ^[0-9]+\.[0-9]+$ ]]
[[ "$libusb_url" == "https://github.com/libusb/libusb/releases/download/v$libusb_version/libusb-$libusb_version.tar.bz2" ]]
[[ "$libusb_sha" =~ ^[0-9a-f]{64}$ ]]
prefix="$project_root/build/deps/libusb"
work_root="$project_root/build/deps/libusb-work/$libusb_version"
source_archive="$project_root/build/deps/sources/libusb-$libusb_version.tar.bz2"
mkdir -p "$(dirname "$source_archive")" "$work_root"
if [[ ! -f "$source_archive" ]]; then
  download="$(mktemp "${source_archive}.download.XXXXXX")"
  trap 'rm -f "$download"' EXIT
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$libusb_url" -o "$download"
  actual_sha="$(shasum -a 256 "$download" | cut -d ' ' -f 1)"
  [[ "$actual_sha" == "$libusb_sha" ]] || { echo 'Downloaded libusb source checksum does not match the pin.' >&2; exit 1; }
  mv "$download" "$source_archive"
  trap - EXIT
fi
actual_sha="$(shasum -a 256 "$source_archive" | cut -d ' ' -f 1)"
[[ "$actual_sha" == "$libusb_sha" ]] || { echo "Source checksum mismatch: $source_archive" >&2; exit 1; }

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
compiler="$(xcrun --find clang)"
build_key="$( { cat dependencies/libusb.json scripts/build-libusb.sh; "$compiler" --version; printf '%s\n' "$sdk_path"; } | shasum -a 256 | cut -d ' ' -f 1)"
validate_archive() {
  test -f "$prefix/lib/libusb-1.0.a" || return 1
  python3 - "$prefix/lib/libusb-1.0.a" "$deployment" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys
archive, minimum = sys.argv[1:]
prefix = pathlib.Path(archive).parents[1]
info_path = prefix / 'build-info.json'
if not info_path.is_file():
    raise SystemExit('libusb build provenance is missing')
info = json.loads(info_path.read_text())
if info.get('archive_sha256') != hashlib.sha256(pathlib.Path(archive).read_bytes()).hexdigest():
    raise SystemExit('libusb archive hash does not match its build provenance')
header = prefix / 'include/libusb-1.0/libusb.h'
if not header.is_file() or info.get('header_sha256') != hashlib.sha256(header.read_bytes()).hexdigest():
    raise SystemExit('libusb header hash does not match its build provenance')
pc = prefix / 'lib/pkgconfig/libusb-1.0.pc'
match = re.search(r'^prefix=(.*)$', pc.read_text(), re.M) if pc.is_file() else None
if not match or pathlib.Path(match.group(1)) != prefix:
    raise SystemExit('libusb pkg-config prefix changed; rebuilding for the current checkout')
arches = subprocess.check_output(['lipo', '-archs', archive], text=True).split()
if set(arches) != {'arm64', 'x86_64'}:
    raise SystemExit('libusb archive must contain exactly arm64 and x86_64')
for arch in arches:
    load = subprocess.check_output(['otool', '-arch', arch, '-l', archive], text=True)
    versions = re.findall(r'^\s*minos\s+(\d+(?:\.\d+)*)', load, re.M)
    if not versions or any(tuple(map(int, version.split('.'))) != tuple(map(int, minimum.split('.'))) for version in versions):
        raise SystemExit(f'{arch}: unexpected minimum macOS versions: {set(versions)}')
PY
}
if [[ -z "${LIBUSB_SOURCE_DIR:-}" && -f "$prefix/.build-key" && "$(cat "$prefix/.build-key")" == "$build_key" && -f "$prefix/include/libusb-1.0/libusb.h" && -f "$prefix/lib/pkgconfig/libusb-1.0.pc" ]] && validate_archive; then
  printf 'Using verified universal libusb %s (macOS %s+): %s\n' "$libusb_version" "$deployment" "$prefix"
  exit 0
fi

custom_source=false
if [[ -n "${LIBUSB_SOURCE_DIR:-}" ]]; then
  source_dir="$(cd "$LIBUSB_SOURCE_DIR" && pwd -P)"
  case "$source_dir/" in
    "$work_root/"*|"$prefix/"*) echo 'Keep LIBUSB_SOURCE_DIR outside the generated libusb work and install directories.' >&2; exit 1 ;;
  esac
  custom_source=true
  test -f "$source_dir/configure" || { echo 'LIBUSB_SOURCE_DIR must contain a prepared libusb configure script.' >&2; exit 1; }
else
  source_dir="$work_root/source"
  # This directory is reserved for this script; no user source is ever removed.
  rm -rf "$source_dir"
  mkdir -p "$source_dir"
  tar -xjf "$source_archive" --strip-components=1 -C "$source_dir"
fi
jobs="${JOBS:-4}"
[[ "$jobs" =~ ^[0-9]+$ && "$jobs" -ge 1 && "$jobs" -le 64 ]] || { echo 'JOBS must be an integer from 1 to 64.' >&2; exit 1; }
for arch in arm64 x86_64; do
  build_dir="$work_root/$arch"
  install_dir="$work_root/install-$arch"
  rm -rf "$build_dir" "$install_dir"
  mkdir -p "$build_dir" "$install_dir"
  host="$arch-apple-darwin"
  [[ "$arch" != arm64 ]] || host=aarch64-apple-darwin
  printf 'Building libusb %s for %s, macOS %s+\n' "$libusb_version" "$arch" "$deployment"
  (
    cd "$build_dir"
    env CC="$compiler" CFLAGS="-O2 -arch $arch -isysroot $sdk_path -mmacosx-version-min=$deployment" \
      LDFLAGS="-arch $arch -isysroot $sdk_path -mmacosx-version-min=$deployment" \
      MACOSX_DEPLOYMENT_TARGET="$deployment" \
      "$source_dir/configure" --host="$host" --prefix="$install_dir" \
      --enable-static --disable-shared --disable-dependency-tracking \
      --disable-examples-build --disable-tests-build > configure.log 2>&1 || { cat configure.log >&2; exit 1; }
    make -j "$jobs" > make.log 2>&1 || { cat make.log >&2; exit 1; }
    make install > install.log 2>&1 || { cat install.log >&2; exit 1; }
  )
done
mkdir -p "$prefix/lib/pkgconfig" "$prefix/include/libusb-1.0" "$prefix/share/licenses/libusb"
lipo -create "$work_root/install-arm64/lib/libusb-1.0.a" "$work_root/install-x86_64/lib/libusb-1.0.a" -output "$prefix/lib/libusb-1.0.a"
cp "$source_dir/libusb/libusb.h" "$prefix/include/libusb-1.0/libusb.h"
cp "$source_dir/COPYING" "$prefix/share/licenses/libusb/COPYING"
python3 - "$work_root/install-arm64/lib/pkgconfig/libusb-1.0.pc" "$prefix" "$custom_source" "$build_key" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys
pc, prefix, custom, key = sys.argv[1:]
prefix = pathlib.Path(prefix)
content = re.sub(r'^prefix=.*$', lambda _: f'prefix={prefix}', pathlib.Path(pc).read_text(), flags=re.M)
(prefix / 'lib/pkgconfig/libusb-1.0.pc').write_text(content)
metadata = json.loads(pathlib.Path('dependencies/libusb.json').read_text())
metadata.update(custom_source=custom == 'true', build_key=key,
    archive_sha256=hashlib.sha256((prefix / 'lib/libusb-1.0.a').read_bytes()).hexdigest(),
    header_sha256=hashlib.sha256((prefix / 'include/libusb-1.0/libusb.h').read_bytes()).hexdigest(),
    compiler=subprocess.check_output(['xcrun', 'clang', '--version'], text=True).splitlines()[0],
    sdk_version=subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip())
(prefix / 'build-info.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
validate_archive
if [[ "$custom_source" == false ]]; then printf '%s\n' "$build_key" > "$prefix/.build-key"; else rm -f "$prefix/.build-key"; fi
printf 'Built universal libusb %s (macOS %s+): %s\n' "$libusb_version" "$deployment" "$prefix"
printf 'Use PKG_CONFIG_PATH="%s/lib/pkgconfig"\n' "$prefix"

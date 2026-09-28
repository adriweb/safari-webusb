#!/bin/bash
# Archive the exact release source plus the materials needed to relink libusb.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$project_root" <<'PY'
import gzip
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
os.chdir(root)
def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()
def die(message):
    raise SystemExit(message)
def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

if pathlib.Path(git('rev-parse', '--show-toplevel')).resolve() != root:
    die('Run from the standalone Safari WebUSB repository, not the parent tilibs checkout.')
if git('status', '--porcelain', '--untracked-files=no'):
    die('Commit tracked changes before packaging; the archive must match the application commit exactly.')
commit = git('rev-parse', 'HEAD')
short_commit = commit[:12]
epoch = int(git('show', '-s', '--format=%ct', commit))
try:
    manifest_bytes = subprocess.check_output(['git', 'show', f'{commit}:dependencies/libusb.json'])
except subprocess.CalledProcessError:
    die('The dependency pin must be committed before packaging source.')
metadata = json.loads(manifest_bytes)
if (root / 'dependencies/libusb.json').read_bytes() != manifest_bytes:
    die('The dependency pin must match HEAD.')
version = metadata['version']
if not isinstance(version, str) or any(c not in '0123456789.' for c in version):
    die('Invalid dependency version.')
archive = root / 'build/deps/sources' / f'libusb-{version}.tar.bz2'
if not archive.is_file() or digest(archive) != metadata['sha256']:
    die('Missing or mismatched pinned libusb source. Run ./scripts/build-libusb.sh first.')
build_info_path = root / 'build/deps/libusb/build-info.json'
if not build_info_path.is_file():
    die('Missing dependency build provenance. Run ./scripts/build-libusb.sh first.')
build_info = json.loads(build_info_path.read_text())
if build_info.get('custom_source') or any(build_info.get(key) != metadata[key] for key in metadata):
    die('This source-packaging route requires the pinned unmodified dependency. A custom-source distribution must also package its actual modified source.')
binary_archive = root / 'build/deps/libusb/lib/libusb-1.0.a'
if not binary_archive.is_file() or digest(binary_archive) != build_info.get('archive_sha256'):
    die('The dependency archive does not match its recorded build. Rebuild from pinned source.')
project = root / 'build/Safari WebUSB'
if not (project / 'Safari WebUSB.xcodeproj/project.pbxproj').is_file():
    die('Build the app first; the generated Xcode project contains additional application source required for relinking.')
# Catch stale generated implementation/resources before publishing a source set.
for path in root.joinpath('native').iterdir():
    if path.is_file() and path.suffix in ('.h', '.m', '.html') and path.name != 'Enumerate.m':
        directory = 'Safari WebUSB' if path.name in ('AppDelegate.m', 'ViewController.m') else 'Native'
        if path.name == 'Main.html':
            directory = 'Safari WebUSB/Base.lproj'
        copied = project / directory / path.name
        if not copied.is_file() or copied.read_bytes() != path.read_bytes():
            die(f'Stale generated native source: {copied}. Rebuild the app.')
for path in root.joinpath('extension').iterdir():
    if path.is_file():
        copied = project / 'Safari WebUSB Extension/Resources' / path.name
        if not copied.is_file() or copied.read_bytes() != path.read_bytes():
            die(f'Stale generated extension resource: {copied}. Rebuild the app.')

base = f'Safari-WebUSB-source-{short_commit}'
output = root / 'build' / f'{base}.tar.gz'
with tempfile.TemporaryDirectory(prefix='.source-package-', dir=root / 'build') as temporary:
    package = pathlib.Path(temporary) / base
    application = package / 'app'
    application.mkdir(parents=True)
    source_tar = subprocess.check_output(['git', 'archive', '--format=tar', commit])
    subprocess.run(['tar', '-xf', '-', '-C', str(application)], input=source_tar, check=True)
    third_party = package / 'third_party'
    third_party.mkdir()
    shutil.copyfile(archive, third_party / archive.name)
    (third_party / 'libusb.json').write_bytes(manifest_bytes)
    (third_party / 'SHA256SUMS').write_text(f"{metadata['sha256']}  {archive.name}\n")
    generated = package / 'generated-xcode-project'
    # Preserve converter-generated host app source, project, entitlements and
    # copied resources. Rebuild libusb.a from its exact source, never distribute
    # signing identities, personal Xcode state or generated binary caches here.
    shutil.copytree(project, generated, symlinks=True, ignore=shutil.ignore_patterns(
        '*.a', '*.o', '*.dSYM', '*.app', '*.appex', '*.p12', '*.pfx', '*.mobileprovision',
        '*.provisionprofile', '.DS_Store', 'xcuserdata', 'DerivedData', 'build', '.git'))
    generated_hashes = {}
    for path in sorted(generated.rglob('*')):
        if path.is_symlink():
            target = (path.parent / os.readlink(path)).resolve()
            if not target.is_relative_to(generated.resolve()):
                die(f'Generated source has a symlink outside its source tree: {path}')
        elif path.is_file():
            generated_hashes[path.relative_to(generated).as_posix()] = digest(path)
    source_manifest = {
        'archive_format_version': 1,
        'application_commit': commit,
        'application_tree': git('rev-parse', f'{commit}^{{tree}}'),
        'application_source': 'app/',
        'generated_project_source': 'generated-xcode-project/',
        'generated_project_sha256': generated_hashes,
        'libusb': metadata,
        'libusb_source_archive': f'third_party/{archive.name}',
        'dependency_build': build_info,
    }
    (package / 'SOURCE-MANIFEST.json').write_text(json.dumps(source_manifest, indent=2, sort_keys=True) + '\n')
    instructions = f'''# Safari WebUSB source and relinking materials

Application commit: {commit}
Application tree: {source_manifest['application_tree']}
libusb source: {archive.name}
SHA-256: {metadata['sha256']}

This archive accompanies the application binary from this commit. `app/` is
an exact Git archive of that commit. `generated-xcode-project/` preserves the
additional host application and project source generated by Apple's Safari
extension packager. `third_party/` contains the complete original libusb
source archive, its checksum, and the pinned dependency metadata. The root
SOURCE-MANIFEST.json lists the generated project files and their hashes.

License notices and permissions are in app/LICENSE, app/LICENSES, and libusb's
COPYING and source headers inside the dependency archive. libusb may be
modified under LGPL-2.1-or-later; the application permits the own-use changes
and debugging/reverse engineering required by LGPL section 6. No private
signing keys are needed or included.

## Rebuild or relink with a modified libusb

Use macOS with Xcode and its command-line tools selected (`xcode-select`),
Python 3, and pkg-config. Consult app/README.md and app/docs/DISTRIBUTION.md
for the current build, signing, and Safari development-install instructions.
The default build produces arm64 + x86_64 binaries targeting macOS {metadata['macos_deployment_target']}.

From this extracted archive's root:

```sh
mkdir -p app/build/deps/sources
cp third_party/{archive.name} app/build/deps/sources/
cp -R generated-xcode-project 'app/build/Safari WebUSB'
tar -xjf third_party/{archive.name}
# Make your changes to libusb-{version}/ before running the next command.
cd app
LIBUSB_SOURCE_DIR="$PWD/../libusb-{version}" ./scripts/build.sh
```

LIBUSB_SOURCE_DIR makes the dependency builder rebuild the supplied prepared
source tree for both architectures. Without it, the script builds and verifies
the pinned unmodified source. All dependency build output stays inside
app/build/deps; your supplied source directory is not removed or edited.
For an entirely unmodified rebuild omit LIBUSB_SOURCE_DIR.

Modified or relinked binaries invalidate the distributor's original signature.
The default build uses local ad-hoc signing. Enable Safari's development option
for unsigned extensions when testing it, or sign with your own suitable Apple
identity. You cannot reproduce the distributor's signature and do not need its
private key to rebuild. Local installation is distinct from notarized or App
Store distribution; follow the documented route for the one you need.

If redistributing a build using modified libusb, preserve the applicable notices,
mark your library changes, provide their corresponding source and relinking
materials, and respect the license. The automated release source packager
intentionally rejects custom-source builds instead of describing them as the
pinned unmodified dependency.
'''
    (package / 'SOURCE-BUNDLE-README.md').write_text(instructions)
    # Stable ownership, timestamps, ordering and gzip metadata make repeated
    # packaging of identical sources byte-for-byte reproducible.
    temporary_output = pathlib.Path(temporary) / output.name
    with temporary_output.open('wb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as tar:
                for path in [package, *sorted(package.rglob('*'))]:
                    info = tar.gettarinfo(str(path), arcname=path.relative_to(package.parent).as_posix())
                    info.uid = info.gid = 0
                    info.uname = info.gname = ''
                    info.mtime = epoch
                    info.pax_headers = {}
                    if path.is_file() and not path.is_symlink():
                        with path.open('rb') as source:
                            tar.addfile(info, source)
                    else:
                        tar.addfile(info)
    temporary_output.replace(output)
print(output)
PY

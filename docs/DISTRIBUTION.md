# Building and distributing Safari WebUSB

Public macOS downloads use a universal app signed with **Developer ID
Application**, then notarized by Apple. Local ad-hoc and Apple Development builds
remain useful for testing, but are not substitutes for that distribution path.
The repository also publishes corresponding source so the statically linked
libusb can be modified and the app rebuilt.

## CI behavior

| Event | App signing | Output |
| --- | --- | --- |
| Pull request | Ad hoc | App ZIP and corresponding source artifact |
| Push to `main` | Ad hoc | App ZIP and corresponding source artifact |
| Push a tag matching `v*` | Developer ID and notarized; credentials required | App ZIP and source archive attached to a GitHub release |
| Manual run, `sign_and_notarize: false` | Ad hoc | App ZIP and source artifact |
| Manual run, `sign_and_notarize: true` | Developer ID and notarized; credentials required | Signed app ZIP and source artifact; no GitHub release |

Builds use the source/checksum pin in [dependencies/libusb.json](../dependencies/libusb.json)
and compile libusb and the app for `arm64` and `x86_64`, targeting macOS 13.
Safari 18 remains the minimum browser version. PRs and ordinary branch builds
can run without Apple credentials. A requested signed build fails if any required
credential is missing; a tag release does not silently fall back to an unsigned
download.

The source archive is named `Safari-WebUSB-source-<12-character-commit>.tar.gz`.
It records the exact Git revision used for the build and includes the
corresponding libusb source archive. The app's `Contents/Resources` also contains
`THIRD-PARTY-NOTICES.txt`, `LICENSE`, and `LICENSES/libusb-LGPL-2.1.txt`. Keep the
app ZIP and its source archive together when mirroring or redistributing a
release.

## Configure signing credentials

Add these seven repository secrets under GitHub Settings > Secrets and variables >
Actions. Their names follow CEmu's existing macOS workflow; their values must
be configured independently for this repository.

| Secret | Contents |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded PKCS#12 (`.p12`) export of a Developer ID Application identity, including its private key |
| `MACOS_CERTIFICATE_PWD` | Password protecting that `.p12` export |
| `MACOS_KEYCHAIN_PWD` | Password used to create the temporary CI signing keychain |
| `MACOS_CODESIGN_IDENT` | Full signing identity name, such as `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_NOTARIZATION_USERNAME` | Apple ID used for notarization |
| `APPLE_NOTARIZATION_PASSWORD` | App-specific password for that Apple ID |
| `APPLE_NOTARIZATION_TEAMID` | Apple Developer team identifier for the signing identity |

Export the Developer ID Application identity from Keychain Access with its
private key. An Apple Development certificate, Mac App Distribution certificate,
or Developer ID Installer certificate is not the identity expected here. The
certificate and notarization credentials must belong to the same team.

GitHub supplies `GITHUB_TOKEN` to each run; do not add it as a personal secret.
The release job uses that token to attach files to the tag's GitHub release.
No Apple secret values are shipped in the repository or source archives.
GitHub's API can list secret names but cannot return their decrypted values, so
credentials cannot be copied out of CEmu by inspecting its GitHub configuration.

To configure secrets from a terminal, use `gh secret set NAME --repo OWNER/REPO`
and enter each value when prompted. For the base64 certificate, redirect a
local file into that command instead of placing its contents in a command line.

## Signing and notarization

[scripts/sign-and-notarize.sh](../scripts/sign-and-notarize.sh) imports the
certificate into a temporary keychain and signs the native `.appex` before the
outer `.app`. Both use the same Developer ID identity, secure timestamps, and
hardened runtime. Each receives its own entitlement file: in particular, the
native extension retains its App Sandbox and USB access entitlements. The app
also receives USB, serial-device and network-server entitlements for its loopback listener.
Signing adds `<TEAMID>.org.webtilp.safariwebusb` to both targets' app groups,
using the notarization team ID, and the verifier checks it against the actual
signing team. Generated entitlement files are preserved; signing uses temporary
copies. Developer ID signing of this team-prefixed macOS app-group format does
not require an additional provisioning profile or portal registration.

This ordering matters because the app's signature seals its embedded extension.
Do not overwrite the whole app with a blanket recursive signature that drops or
assigns the wrong entitlements. Distribution signatures must not retain the
development `com.apple.security.get-task-allow` entitlement.

The script submits the app ZIP with `notarytool`, waits for acceptance, staples
the ticket to the app, and recreates the downloadable ZIP. A ZIP itself cannot
be stapled. Notarization establishes Apple's distribution assessment; it does
not validate native messaging, extension permissions, or USB behavior in Safari.

The verifier checks the packaged app and can enforce the signed-release path:

```sh
python3 scripts/verify-distribution.py \
  "build/products/Release/Safari WebUSB.app" --release --notarized
```

The current USB, App Sandbox, and team-prefixed macOS app-group entitlements do not require a
macOS provisioning profile. Additional restricted capabilities would require
their own provisioning configuration; the project does not add them merely to
enable USB access. App Store/TestFlight distribution is a separate workflow
from the Developer ID downloads produced here.

## Install a download or local build

For a signed release, extract the app ZIP, move Safari WebUSB.app to Applications,
and open it. Then enable the extension in Safari > Settings > Extensions and
grant access to the website where you will use WebUSB. Reload that website so
the API is injected before its first scripts execute.

Keep Safari WebUSB running while using the signed build's USB connection. You
can close its window without quitting the app. After quitting or restarting the
app, open it again, reload the website, and choose the device again. There is no
login item, daemon, or automatic app launch.

For an ad-hoc artifact or locally rebuilt app, enable Safari's developer features
and Allow Unsigned Extensions before enabling the extension. Safari resets this
option after it quits. This is also the supported route for testing a locally
modified library without the project's Developer ID private key.

## Rebuild and relink

Safari WebUSB and libusb are licensed under LGPL-2.1-or-later. The corresponding
source archive contains the app source, JavaScript resources, build scripts,
license notices, and exact upstream libusb source used for that artifact. A
fresh rebuild regenerates the Xcode project, compiles the native code, and
statically links the selected libusb archive; it does not require the project's
signing certificate.

For a build from Git, install Xcode, Python 3, and `pkg-config`, then run:

```sh
./scripts/build.sh
```

This automatically builds the pinned universal libusb and produces
`build/products/Release/Safari WebUSB.app` with an ad-hoc signature. The
`BUILD_CONFIGURATION` and `BUILD_ARCHS` settings documented in the main README
also apply. No system libusb installation is needed.

The corresponding source archive has this layout:

```text
Safari-WebUSB-source-<12-character-commit>/
  app/                         exact project revision
  generated-xcode-project/     generated wrapper sources, without binary caches
  third_party/libusb-1.0.30.tar.bz2
  third_party/libusb.json
  SOURCE-MANIFEST.json
  SOURCE-BUNDLE-README.md
```

Follow `SOURCE-BUNDLE-README.md` for the complete build recipe, including using
its bundled libusb archive and generated wrapper. This avoids relying on a
future upstream download to recover the exact dependency source.

For a locally modified library, unpack the supplied source, make your changes,
and point `LIBUSB_SOURCE_DIR` at that prepared source tree. For example, after a
normal checkout build has downloaded the pinned archive:

```sh
mkdir -p build/modified-source
tar -xjf build/deps/sources/libusb-1.0.30.tar.bz2 -C build/modified-source
# Edit build/modified-source/libusb-1.0.30 as desired.
LIBUSB_SOURCE_DIR="$PWD/build/modified-source/libusb-1.0.30" ./scripts/build.sh
```

The dependency helper builds both architectures from that source and replaces
its generated static archive before the app is relinked. Supply
`LIBUSB_SOURCE_DIR` on each modified-library build; omitting it restores the
pinned-source build. The source directory must contain a prepared `configure`
script, as the supplied release tarball does. The helper accepts `JOBS` from
1 to 64 to control build parallelism.

Install the resulting ad-hoc app through the local-build instructions above.
Creating a public Developer ID distribution of your modified app requires your
own signing identity and notarization credentials.

[scripts/package-source.sh](../scripts/package-source.sh) writes the matching
source archive under `build/`. It requires a generated Xcode project and a clean
tracked working tree and exports the exact Git `HEAD`, so commit source changes
before packaging them. The release packager rejects `LIBUSB_SOURCE_DIR` custom
builds: a modified-library distribution needs its own complete source bundle
containing those modifications rather than an archive mislabeled as the pinned
upstream source.

## Provenance and references

The CI signing sequence and secret names were informed by
[CEmu's macOS workflow](https://github.com/CE-Programming/CEmu/blob/54f4a9a4eb9e1c89a7c405705b1a1fc1ab428da2/.github/workflows/build.mac.workflow.yml)
at commit `54f4a9a4eb9e1c89a7c405705b1a1fc1ab428da2` on its `master` branch.
CEmu builds and signs architecture-specific apps, packages DMGs, notarizes and
staples those DMGs, and updates a `nightly` prerelease. Its source is
[GPL-3.0-or-later](https://github.com/CE-Programming/CEmu/blob/54f4a9a4eb9e1c89a7c405705b1a1fc1ab428da2/LICENSE).
This project's workflow is independently written, with Safari-specific
entitlements, universal builds, ZIP/source artifacts, and tag-based releases.

- [Apple: distribute a Safari web extension](https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension)
- [Apple: customize notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple: provisioning profiles and unrestricted macOS entitlements](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Apple: USB sandbox entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb)

WebSerial and WebHID require the signed app-group transport. Ad-hoc CI artifacts
can exercise the WebUSB compatibility path, but cannot stream serial/HID input.
The release verifier checks the app serial entitlement alongside USB/network
permissions. Physical Serial/HID device validation remains separate from CI.

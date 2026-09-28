# Safari WebUSB prototype

An original, experimental implementation of `navigator.usb`, `navigator.serial`,
and `navigator.hid` for **Safari 18 or later on macOS**. A Safari Web Extension
supplies the JavaScript APIs. Its companion app uses libusb for USB transfers,
macOS serial I/O for serial ports, and IOKit for HID reports. No browser fork,
kernel extension, or privileged installation is intended.

This is a development prototype with the compatibility boundaries listed below. On
macOS 27 / Safari 27, a Developer ID-signed installation has been exercised with
WebTiLP and a TI-84 Plus CE Python (`0451:e008`): device selection, open/close,
configuration selection, device information, directory listing, remote keys,
clock synchronization, file reception, and 320 × 240 screenshot reception
worked on real hardware.

Screenshot reception exposed a Safari native-messaging failure during sustained
traffic. The signed build now uses native messaging only to bootstrap an
authenticated loopback WebSocket to the running companion app. USB requests
retain their ordering, exact lengths, and page grants without per-packet native
messaging or added WASM delays. Ad-hoc builds without an app group retain the
older, paced native-message path. With the persistent transport and a clean
WebTiLP WASM build, the user reported screenshots taking **under four seconds**,
compared with about **126 seconds** on the paced path. Live Safari logs confirm
successful captures; the sub-four-second duration is user-reported. See
[Native messaging and throughput](docs/NATIVE-MESSAGING.md) for the test setup,
measurements, and remaining limitations.

Local macOS 27 / Xcode 27 checks also cover app construction and signatures,
JavaScript behavior, native fake-USB assertions, and WebKit injection before the
first page script. These checks complement the hardware observations; they do
not prove behavior on other Safari or macOS versions.

## Build and install locally

Prerequisites: Xcode with its command-line tools selected, Node.js for tests,
Python 3, and `pkg-config` (`brew install pkgconf`). The bundled build helper
fetches the pinned libusb source, verifies its checksum, and builds a static
universal library for macOS 13 or later:

```sh
./scripts/build.sh
```

The default configuration is Release, signed ad hoc for local testing. Expected
outputs are:

```text
build/Safari WebUSB/Safari WebUSB.xcodeproj
build/products/Release/Safari WebUSB.app
```

The build script calls `scripts/build-libusb.sh` automatically and uses its
archive under `build/deps/libusb`. Both the app and library contain Apple Silicon
and Intel code by default. No Homebrew libusb installation or runtime dylib is
needed. Safari 18 or later is still required even on a compatible macOS.

`BUILD_CONFIGURATION=Debug` selects the Debug configuration. `BUILD_ARCHS="arm64"`
or `BUILD_ARCHS="x86_64"` limits the app to one architecture; the dependency
helper always builds its universal archive. The default is
`BUILD_ARCHS="arm64 x86_64"`. See [relinking](docs/DISTRIBUTION.md#rebuild-and-relink)
for the `LIBUSB_SOURCE_DIR` override used to test a modified library.

Run the app, then enable **Safari WebUSB** in Safari > Settings > Extensions.
Keep the app running while using USB; closing its window leaves the bridge
running. Quitting the app closes the connection and requires a new device
selection after relaunch. The app does not install a login item or daemon.
For ad-hoc local builds, first enable Safari > Settings > Advanced > Show
features for web developers, then Allow Unsigned Extensions in Safari's
developer options. Safari resets that setting when it quits. To use an Apple
development identity, open the generated Xcode project and select your team,
or run `TEAM_ID=YOUR_TEAM_ID ./scripts/build.sh`. Development signing is for
local development; public downloads use a Developer ID Application certificate
and notarization as described in [Distribution](docs/DISTRIBUTION.md).

Grant the extension access to the test website. Reload the page after granting
access so that the API is injected before the website's scripts execute.
Installing just the JavaScript folder as a temporary Safari extension cannot
provide the native USB backend; the containing app is required.

Both targets use App Sandbox and the USB entitlement. The companion app also
has the serial-device and network-server entitlements and binds only to IPv4 loopback, on a random
port. Signed builds share a team-prefixed macOS app-group container for private
bootstrap credentials. Release signing derives the group from the signing
team; no additional provisioning profile is needed for this macOS group format.
Ad-hoc builds cannot authenticate access to that shared container and use the
slower native-message fallback for WebUSB only. WebSerial and WebHID require
the signed app group and persistent socket; ad-hoc installations report
`NotSupportedError` when choosing a serial or HID device.

## Exercise the API

Serve this directory locally:

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

Open <http://localhost:8765/tests/smoke.html> in Safari. Enable the extension for
localhost and reload if necessary. The page offers separate buttons to:

1. List devices already granted to the current document.
2. Request a device through the extension's chooser. The default vendor filter
   is Texas Instruments (`0451`); vendor and product IDs are editable hex values.
3. Inspect descriptors, open the selected device, select an advertised
   configuration explicitly, and close the device.
4. Forget the current document's grant.

The smoke page sends no endpoint or control transfers. Opening a device and
selecting its configuration are separate user actions; selecting a configuration
may change device state. Choose a test device that is not in use by another app.

For an existing WebUSB site, enable the extension for that site and reload it.
Use its normal Connect button. The extension currently exposes the API only to
top-level secure pages (HTTPS or localhost). Embedded frames and Web Workers are
outside the prototype's scope. USB permissions are scoped to the current page
session; a reload requires another device selection.

## Serial and HID smoke checks

Open <http://localhost:8765/tests/peripherals.html> after building and signing the
updated app. The page provides separate serial/HID choosers, descriptor display,
open/close, and passive input logging. It sends no serial bytes, output reports,
or feature reports. Opening a serial port can change its modem signals, so use
a test device. Enable the extension for an existing Serial/HID site and reload
it to use its normal connection flow. Permissions are per document for all APIs;
choosing a USB device does not also grant its serial or HID interface.

## Architecture

```text
Website: navigator.usb / navigator.serial / navigator.hid
  │ window.postMessage (untrusted page requests)
  ▼
Isolated content script: document connection + trusted gesture check
  │ browser.runtime port
  ▼
Persistent macOS background page: origin checks + privileged device chooser
  │ authenticated WebSocket on 127.0.0.1 (one persistent connection)
  ▼
Companion app: session/grant validation + libusb / serial I/O / IOHID
  │ macOS device access
  ▼
USB device
```

Two declarative `document_start` content scripts run in `MAIN` and `ISOLATED`
worlds. The `MAIN` script supplies the page-visible classes and methods; the
isolated script has access to extension APIs. `world: "MAIN"` requires Safari
18, which is why earlier Safari versions are not targeted. A page's content
security policy does not require a script-tag injection workaround.

Safari's native messaging differs from Firefox/Chromium's stdio hosts. It
delivers requests to `NSExtensionRequestHandling.beginRequest(with:)` in the
bundled native extension. Safari ignores the application ID passed to
`sendNativeMessage`; requests can reach only the containing app's native
extension. Only the background or other extension pages may call this API.
The signed build uses it for a short-lived, Safari-profile-bound connection
credential. The native extension and app share a secret through their signed
app group. Mutual challenge proofs authenticate both socket endpoints before
any USB request, including protection against a stale port being reused by an
unrelated local listener. The shared secret never enters JavaScript, and the
derived connection key stays in the privileged background page.

Socket loss rejects pending operations without retrying writes, invalidates
page grants, and closes that connection's native USB sessions. A fresh chooser
can establish a new connection. No speculative USB reads or protocol-specific
buffering are used.

Xcode 27's packager warns that the `world` manifest key is unsupported. The
installed macOS 27 WebKit engine nevertheless accepts the actual Manifest V2
extension and exposes `navigator.usb`, `USBDevice`, and `USBConfiguration` to
the first inline page script. A negative control changing `MAIN` to `ISOLATED`
makes that check fail. The packager warning does not establish a runtime
incompatibility; this check covers WebKit injection, not Safari's native host.

Manifest V2 with a persistent background page is intentional for this macOS
prototype. Safari supports this desktop configuration. Manifest V3 requires a
nonpersistent page or service worker, which would require additional restoration
and connection handling. Background persistence still does **not** guarantee
native extension process persistence.

The native request/response fields and limits are specified in
[PROTOCOL.md](PROTOCOL.md). The background supplies origin and document session
identity; a web page cannot choose its own authorization origin. A device grant
requires an explicit choice in extension UI. Native operations also check the
session's grant, so JavaScript API objects alone do not grant hardware access.

## Automated checks

Run the JavaScript tests from this directory:

```sh
node --test tests/*.test.cjs
```

On macOS 15.4 or newer, the public WebKit embedding APIs also allow a real
engine check of the complete extension's `document_start` injection:

```sh
xcrun clang -fobjc-arc -framework AppKit -framework WebKit \
  tests/webkit-injection.m -o /tmp/safari-webusb-injection
/tmp/safari-webusb-injection "$PWD/extension"
```

This loads an in-memory secure-origin page into an ephemeral `WKWebView`. The
first inline page script must see the WebUSB API. It does not modify Safari's
settings, contact the example.org base URL, ask for a device, or access USB.
The process needs permission to launch WebKit's normal helper processes; a
restricted command sandbox can prevent that. It does not exercise native
messaging, the Safari permission UI, or hardware.

## Native process lifetime and recovery

Signed builds keep USB handles in the running companion app. Closing its window
leaves the connection available; quitting or restarting the app disconnects its
clients. Losing a socket invalidates that connection's document grants and
closes its native USB, serial and HID sessions. Pending operations fail without
automatic replay. Serial streams error and opened HID devices receive disconnects.
Open Safari WebUSB again, reload the website, and choose the device again.

Ad-hoc builds without a signed app group use the compatibility transport, which
retains handles in Safari's native extension process. Apple does not promise
that this process remains alive after completing a request. Both transports
include a random backend process identifier in replies, and subsequent requests
carry the expected identifier. A mismatch fails with `InvalidStateError` rather
than restoring an old grant or interface claim.

Page sessions expire after 60 seconds without activity or heartbeats, releasing
abandoned handles and grants. Automated checks cover stale-state rejection and
connection cleanup; recovery after app or extension termination still needs
live Safari validation. Safari's `connectNative` API alone does not provide
Firefox's long-lived stdio host mechanism.

## Compatibility boundaries

- The intended surface includes enumeration, chooser permissions, descriptors,
  open/close, configuration and interface selection, halt clearing, reset,
  control transfers, and bulk/interrupt transfers.
- Isochronous transfers are unsupported. Transfers are bounded in size and use
  a native timeout, unlike WebUSB's unbounded asynchronous transfer model.
- Ordinary native operations are serialized, with bounded transfer timeouts.
  Serial output abort bypasses a blocked operation and cancels queued writes
  for that document/port. The
  compatibility transport spaces native-message starts by at least 40 ms,
  limiting its aggregate dispatch to 25 calls per second. The persistent socket
  transport has no deliberate per-transfer pacing delay. See
  [Native messaging and throughput](docs/NATIVE-MESSAGING.md).
- Serial reads and HID input reports use asynchronous native events, independent
  of the request queue. Serial reads are demand-driven and bounded to one chunk
  per stream pull. Ordinary requests remain globally ordered; a slow USB transfer or
  blocked write can delay subsequent commands by up to its timeout. Sustained
  high-rate streaming across devices still needs workload-specific validation.
- Device reconnects require selecting the device again. Disconnects are polled
  every 10 seconds; there is no automatic restoration of grants after replugging.
- Restoring a page from Safari's back/forward cache requires a reload to create
  a fresh document connection.
- The extension cannot grant access to interfaces owned exclusively by a macOS
  driver or another application. It should not detach system drivers.
- WebSerial supports local macOS serial ports, USB vendor/product filters,
  baud/data/stop/parity/flow-control settings, readable/writable streams, modem
  signals, drain, close and forget. Bluetooth service selection, worker APIs,
  and persistent permissions are unsupported. Existing OS-exposed Bluetooth
  serial ports can appear as generic serial ports. Driver-specific signal and
  custom-baud support varies; parity/framing/overrun errors are not individually
  classified by this POSIX backend.
- WebHID supports device filters, collections/report descriptors, input reports,
  output reports and feature reports. Protected or malformed HID descriptors
  are rejected natively; mixed devices containing protected collections are
  conservatively denied as a whole. Long-item and usage-delimiter descriptors
  are unsupported. Feature reads are limited to 64 KiB including the report ID;
  other transfers are limited to 1 MiB. Keyboard/mouse and security-token access
  are unavailable. HID chooser selection returns an array containing one device.
- Serial and HID have automated PTY/fake-device coverage; physical serial/HID
  devices have not yet been validated in Safari. The existing calculator
  results above concern WebUSB.
- Safari/iOS has no corresponding general-purpose libusb/IOKit path. iPhone and
  iPad are not targets.
- Page scripts can inspect and modify the JavaScript shim and can forge page
  messages. Authorization must remain in the isolated/background/native layers.
  This remains prototype code, not a reviewed security boundary for arbitrary
  websites or sensitive USB devices.

## Tests and CI

```sh
node --test tests/*.test.cjs
./native/tests/run.sh
```

The native tests link a fake USB transport and exercise authorization, descriptors,
state transitions, endpoint/control checks, transfer errors and device cleanup.
Additional tests use real pseudo-terminals for serial streams, HID descriptor
fixtures and fake IOKit for reports, and verify shared session/event isolation.
Handler tests use a fake backend, context, and monotonic clock to check reply
pacing, context release, and exactly-once submission without extra delay for
slow transfers. These tests never claim or transfer to physical hardware.
JavaScript tests execute the
actual shim and extension bridge with mocked browser/native transports.

After building, `./scripts/probe-usb.sh` performs read-only descriptor enumeration
in a signed app sandbox with the USB entitlement. It prints device metadata
(including serial numbers, when available); it never grants or claims devices.
Running a sandboxed executable outside an app bundle can fail in macOS's
`libsecinit`, which is why this diagnostic creates its own small `.app` bundle.

GitHub Actions builds a universal Release app using the pinned static libusb,
runs automated checks, and uploads app and source archives. Pushes to `main`
and pull requests produce ad-hoc development artifacts. A `v*` tag requires
Developer ID signing and notarization before creating a GitHub release. Manual
runs are unsigned unless `sign_and_notarize` is enabled; a signed manual run
uploads artifacts without publishing a release.

The signed path requires the seven Apple signing/notarization secrets listed
in [Distribution](docs/DISTRIBUTION.md). They must be configured for this
repository; GitHub does not make another repository's encrypted secret values
available for copying. CI validates packaging and code signatures, not USB
operation inside Safari or physical calculator transfers.

## License and acknowledgments

Copyright (C) 2026 Adrien Bertrand. This project is licensed under the
[GNU Lesser General Public License, version 2.1 or later](LICENSE).


[ArcaneNibble/awawausb](https://github.com/ArcaneNibble/awawausb) inspired this
experiment. It supplies a Firefox WebUSB shim, a persistent background page,
and an OS-specific Rust native host. Its isolated bridge uses Firefox's
`exportFunction` and `cloneInto`, and its host communicates over stdin/stdout;
those pieces cannot be used unchanged in Safari.

The implementation here is original; no awawausb code is copied. Its upstream
[license](https://github.com/ArcaneNibble/awawausb/blob/main/LICENSE) is a
permissive ISC-style grant with the author's copyright notice. libusb is an
independent LGPL-2.1-or-later dependency. CI app archives include
[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt), the project license, and the
libusb license; corresponding source archives accompany the binaries.
These contain the exact project revision and pinned libusb source, with the
[rebuild and relinking instructions](docs/DISTRIBUTION.md#rebuild-and-relink)
needed to build against a modified library.

The macOS signing sequence and credential names are informed by
[CEmu's workflow at `54f4a9a`](https://github.com/CE-Programming/CEmu/blob/54f4a9a4eb9e1c89a7c405705b1a1fc1ab428da2/.github/workflows/build.mac.workflow.yml).
This project's workflow is independently written. It signs the Safari extension
and containing app with separate entitlements and distributes a ZIP rather
than CEmu's DMG.

## Sources

- [Apple: messaging between the app and JavaScript](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)
- [Apple: USB sandbox entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb)
- [Apple: app extension lifecycle](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)
- [Apple: persistent/nonpersistent background pages and Safari version requirements](https://developer.apple.com/documentation/safariservices/optimizing-your-web-extension-for-safari)
- [Apple: packaging a web extension](https://developer.apple.com/documentation/safariservices/packaging-a-web-extension-for-safari)
- [Apple: running and enabling a local extension](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension)
- [Apple: App Store or Developer ID/notarized distribution](https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension)
- [MDN compatibility data: content script worlds and injection timing](https://github.com/mdn/browser-compat-data/blob/main/webextensions/manifest/content_scripts.json)
- [awawausb architecture](https://github.com/ArcaneNibble/awawausb/blob/main/Documentation/architecture.md)

Apple's packager used to be named `safari-web-extension-converter`; Xcode versions
may expose either name. Official distribution can use the Mac App Store or a
Developer ID–signed and notarized containing app.

# Prototype wire protocol (v1)

The extension background is the only native-messaging caller. It supplies a
random per-document `session` and the top-level HTTPS/localhost `origin` from
Safari's port sender (never page data). USB messages are JSON:

```js
{version: 1, op: "transferIn", session, origin,
 instance: "expected native process UUID, omitted only for enumerate",
 args: {deviceId, endpointNumber: 1, length: 64}}
```

Responses: `{ok: true, result, instance}` or
`{ok: false, error: {name, message}, instance}`. A stale `instance` must fail
with `InvalidStateError`, never silently recover a granted device.

Signed builds bootstrap the socket with one native message:
`{version:1, op:"transportBootstrap", args:{origin:<extension origin>}}`.
The native handler obtains the Safari profile from `SFExtensionProfileKey` and
returns `{ok:true,url,token,key}`. The URL is strictly `ws://127.0.0.1:<port>/`.
The app-group master secret stays native; `key` is a per-connection derived key
kept only by the privileged background. Tokens bind profile, extension Origin,
app instance, expiry, and nonce. Bootstrap errors use `{ok:false,error}`;
only `NotSupportedError` (no signed app group) permits the old paced transport.

The socket exchanges `hello` with the token and a client challenge, then
`challenge` with a server challenge and base64 HMAC-SHA256 proof over
`server:<client challenge>:<server challenge>`. After verifying the server,
the client sends `authenticate` with a proof over `client:<server challenge>`.
The server verifies it and sends `ready`. The key itself never crosses the
socket. Single-use nonces and the actual WebSocket Origin are checked before
authentication completes.

USB traffic then uses `{type:"request",id,message:<USB message>}` and
`{type:"response",id,response:<USB response>}`. Transport admission failures use
`{type:"error",id,error:{name,message}}`. Authentication failures may omit the
ID and close the socket. Each socket has a native session namespace, and losing
it closes its USB sessions. Requests are never automatically replayed.

- `enumerate`: returns an array of device snapshots before any device grant.
  The socket requires the document `session` and `origin` on this request too;
  only the underlying legacy backend permits their omission.
- `grant`: privileged chooser completion only; args `{deviceId}`. Creates the
  backend session/origin binding and grants a device. Returns its snapshot.
- `getDevices`: returns snapshots of this session's granted connected devices.
- `heartbeat`: renews session lease; returns null. Sessions expire after 60 s.
- `closeSession`: release handles, grants and session; returns null.
- `open`, `close`, `reset`, `forget`: args `{deviceId}`, return snapshot except
  `forget` returns null.
- `selectConfiguration`: args `{deviceId, configurationValue}`.
- `claimInterface`, `releaseInterface`: args `{deviceId, interfaceNumber}`.
- `selectAlternateInterface`: args `{deviceId, interfaceNumber, alternateSetting}`.
- `clearHalt`: args `{deviceId, direction: "in"|"out", endpointNumber}`.
  These state operations return updated snapshots.
- `transferIn`: args `{deviceId, endpointNumber, length}` -> `{status, data}`.
- `transferOut`: args `{deviceId, endpointNumber, data}` -> `{status, bytesWritten}`.
- `controlTransferIn`: args `{deviceId, setup, length}` -> `{status, data}`.
- `controlTransferOut`: args `{deviceId, setup, data}` -> `{status, bytesWritten}`.
  `data` on wire is base64; `setup` has WebUSB requestType/recipient/request/value/index.
  Transfers capped at 1 MiB, control transfers at 65535 bytes, native timeout 5 s.
  Native queue/discovery admission expires after 10 s, before device mutations.
  A stalled transfer resolves with `status: "stall"`, other errors reject.
  Isochronous transfers are explicitly unsupported.

Snapshot uses WebUSB's property names (version components, class/subclass/protocol,
vendorId/productId, manufacturerName/productName/serialNumber, configurations) plus
`id`, `opened`, `configurationValue` (null if unconfigured). Configuration has
configurationValue/configurationName/interfaces; interface has interfaceNumber,
claimed, alternateSetting, alternates; alternate has alternateSetting,
interfaceClass/interfaceSubclass/interfaceProtocol/interfaceName/endpoints;
endpoint has endpointNumber/direction/type/packetSize.

Page shim RPC uses window.postMessage with `{source: "safari-webusb-page", id,
op, args}` and response `{source: "safari-webusb-extension", id, ok, result/error}`.
Content connects one runtime port named `safari-webusb-v1`, forwards requests, and
returns responses unchanged. Background accepts only `requestDevice` (args are
USBDeviceRequestOptions), `getDevices`, and device operations above. `getDevices`
returns [] until an explicit grant. `requestDevice` is gated by a trusted recent
gesture in the isolated content script and a privileged extension chooser.
Native device snapshots are converted into JS USBDevice objects by the shim.
Background may send `{event: "disconnect", deviceId}` or
`{event: "connect", device: snapshot}` over the same port; content adds source.

## Serial and HID

The persistent socket also carries namespaced `serial.*` and `hid.*` operations,
using the same process instance, profile and document identity. Native messaging
fallback does not support these APIs. Each API keeps separate grants; the shared
`closeSession` releases all three. Idle sessions expire after 60 seconds.

Input uses `{type:"event",session,event:{event,deviceId,...}}` socket frames.
Only the authenticated connection/document receives these frames; the background
also checks that the corresponding device grant still exists. Content adds the
usual page-message source. Socket teardown errors pending streams and revokes
grants. Event frames are bounded by the same send-queue and size caps as replies.

- `serial.enumerate`, `serial.grant`, `serial.getPorts`: native chooser operations
  and granted enumeration. Page-facing chooser operation is `serial.requestPort`.
  Snapshots contain `id`, `productName`, optional `usbVendorId`/`usbProductId`,
  `opened` and `connected`. Device paths remain native.
- `serial.open`: `{deviceId,baudRate,dataBits,stopBits,parity,flowControl,bufferSize}`.
- `serial.read`: `{deviceId,length}` requests one chunk, at most 65536 bytes,
  acknowledges immediately, then emits `serial.data` with base64 `data` when
  input becomes available. A new read credit is required for another chunk.
- `serial.cancelRead`: cancels the outstanding credit before acknowledging.
- `serial.write`: `{deviceId,data}` sends at most 1 MiB and returns `{bytesWritten}`.
  Writes are nonblocking natively and have a five-second deadline.
- `serial.drain`: waits asynchronously for queued output, with a bounded deadline.
- `serial.abortWrite`: cancels/discards queued output without closing input.
  This operation bypasses a blocked request, cancels queued writes for the same
  document/port, and never cancels another document's work.
- `serial.getSignals`: `{deviceId}` returns a WebSerial input signal dictionary.
- `serial.setSignals`: `{deviceId,signals:{dataTerminalReady?,requestToSend?,break?}}`.
- `serial.close` drains/closes, and `serial.forget` revokes the document grant.
  Errors emit `serial.error` with `{error:{name,message}}`; removal emits
  `serial.disconnect`. All operations except enumeration require native grants.

- `hid.enumerate`, `hid.grant`, `hid.getDevices`: native chooser operations and
  granted enumeration. Page-facing `hid.requestDevice` returns a one-item array
  after the user selects a device. Snapshots contain `id`, `vendorId`, `productId`,
  `productName`, `opened`, and WebHID `collections`/report/item descriptors.
- `hid.open`, `hid.close`, `hid.forget`: `{deviceId}`.
- `hid.sendReport`, `hid.sendFeatureReport`: `{deviceId,reportId,data}`. Base64 data
  excludes the report-ID byte; the native backend supplies it when needed.
- `hid.receiveFeatureReport`: `{deviceId,reportId}` returns `{data}` including a
  nonzero report-ID byte, matching the WebHID feature-report DataView. Native
  feature reads are limited to 64 KiB including that ID by macOS.
- `hid.inputreport`: `{deviceId,reportId,data}` events exclude the report-ID byte
  from `data`. Removal emits `hid.disconnect`.

HID report lengths and IDs are validated against parsed native descriptors.
Protected usages are denied natively, including mixed devices with a protected
collection. Serial/HID connections are exclusive per device and scoped to one
native document session. Page-supplied paths, grants and session identities are
never accepted. Chooser operations consume the same trusted-gesture allowance
as WebUSB; all APIs are restricted to secure top-level documents.

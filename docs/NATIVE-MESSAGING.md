# Native messaging and throughput

## Persistent transport

The signed build uses an authenticated loopback WebSocket from the persistent
extension background to the companion app. Native messaging supplies only the
initial, expiring connection credentials. The app owns the USB backend and
keeps running when its window is closed. This removes the 40 ms reply floor
from USB operations without modifying websites or their WASM builds.

On September 28, 2026, a standalone Network.framework echo listener was tested
from the installed Safari 27 extension's actual background page. All 10,000
sequential 64-byte round trips passed byte checks in **2,281 ms** (about 4,384
round trips per second). The server verified 10,000 echoes and its IPv4
loopback-only binding. These results come from a standalone channel probe.
They do not measure USB hardware or the full page/content-script/extension
path; the subsequent hardware results are described separately below.

The installed companion app was also tested directly by a temporary signed
client using its real shared-container bootstrap and mutual authentication.
All 1,000 sequential transport-validation error responses arrived in **112 ms**
(median **0.100 ms**, p95 **0.158 ms**). These deliberately invalid requests
were rejected before USB backend access. This checks the installed listener and
authentication, not Safari's bootstrap, USB transfers, or screenshot speed.

The persistent transport subsequently passed the real Safari/WebTiLP/calculator
path with a TI-84 Plus CE Python (`0451:e008`) and a clean WASM build served at
`localhost:8766`. On September 28, WebTiLP logged successful **320 × 240**
screenshots at **18:10:36** and **18:10:47**, and a **25-entry directory listing**
at **18:10:38** (local time). The user reported screenshots taking **under four
seconds**, compared with the paced transport's approximately **126 seconds**.
The browser logs confirm completed captures; their completion timestamps alone
do not independently establish the sub-four-second duration. This local run
used Safari's Allow Unsigned Extensions development setting. It confirms the
browser-to-hardware screenshot path without a website/WASM timing workaround;
it does not establish complete WebUSB compatibility.

Two consecutive sends of the unchanged, archived `Image1.8Ca` also succeeded
through the normal WebTiLP UI, each followed by its automatic 25-entry directory
refresh. The logs show send/listing completion at **18:12:31 / 18:12:31** and
**18:13:38 / 18:13:39** (local time), without a reconnect or added delay. The
paced transport had repeatedly timed out on this sequence. This confirms the
reported reproduction passes with the persistent transport; it does not isolate
the calculator firmware condition behind the earlier timeout.

The endpoints authenticate one another with HMAC challenges before any USB
operation. The bootstrap is bound to Safari's profile and the extension's
actual WebSocket Origin; it expires after 30 seconds and can be used only once.
The app-group master secret never leaves native code. Frames, connections,
pending requests, and request deadlines are bounded. Disconnects close native
sessions and fail uncertain operations without replay.

The native-message pacing described below remains the ad-hoc development
fallback when no signed app group is available. Signed builds report an
actionable error when the companion app is unavailable rather than silently
switching transports during a USB session.

## Original native-message failure

On macOS 27 / Safari 27, sustained native-message traffic failed after about
150 successful replies, even when each caller awaited the preceding reply.
The error was:

```
Invalid call to runtime.sendNativeMessage(). The operation couldn’t be completed. (SFErrorDomain error 3.).
```

The SDK calls this error `SFErrorLoadingInterrupted`. The native process remained
alive. Probes that requested no USB operation reproduced the failure, isolating
it from calculator screenshot decoding and USB transfer size.

## Measurements

These are observations from one installation on September 28, 2026, not a
published Safari API quota or a guarantee about other versions.

| Live probe | Result |
| --- | --- |
| Granted-device metadata, sequential calls without deliberate gaps | 151 replies, then failure; 243.62 ms |
| Same metadata calls with 10 ms gaps | 150 replies, then failure |
| Same metadata calls with 100 ms gaps | All 300 passed; 32,480 ms |
| Direct native calls with invalid protocol version `{version: 0}` | 150 replies, then bridge failure; 105 ms |
| `connectNative` with invalid-version messages | 151 replies, then stalled; probe timed out at 5,099 ms |
| Direct invalid-version calls, sequential with 40 ms gaps | All 1,000 received structured native replies; 142,222 ms |
| Installed native reply pacing plus global background queue, full WebTiLP screenshot | 320 × 240 image received and displayed; about 126 seconds |
| Installed persistent WebSocket transport, clean WebTiLP WASM | Two 320 × 240 captures confirmed in browser logs; under four seconds per screenshot reported by the user |

Invalid-version probes exercise the same native bridge and backend but fail
protocol validation before any requested USB operation. Their expected native
error replies count as successful transport, not successful USB operations.
Minimum spacing does not promise a completion rate: browser scheduling and
request latency can make a run considerably slower.

Safari/PlugInKit logs from the original screenshot failure show completed
requests retaining host plugin references:

- At **15:33:14.161**, the reference count reached **151**; the first bridge
  rejection followed at **15:33:14.162**.
- **144 references** were released together at **15:33:19.165–19.169**, around
  five seconds after the burst completed.
- Isolated later calls also released their final references about **5.06–5.25
  seconds** after starting.

Individual extension requests had already reported completion and teardown.
The delayed plugin-reference release explains why awaiting replies alone did
not prevent accumulation. The private implementation of that delay has not
been established.

WebKit's [native-messaging implementation at a pinned revision](https://github.com/WebKit/WebKit/blob/00f03c1f906ff25f9536f528e81477c861c0325c/Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIRuntimeCocoa.mm#L237)
contains a 150-active-request guard in its fallback path. Safari can instead use
a delegate path, and the fallback's error wording differs from this failure;
that source is supporting context, not proof of the exact Safari counter.
The same fallback handles each native-port message as a separate native request.
Switching to `connectNative` did not solve the measured problem.

## Paced compatibility transport and limits

A background-page timer probe requested twenty 40 ms sleeps; actual delays
were **137–148 ms**. Native completion logs during the failed screenshot also
showed **135–140 ms** between replies, followed by the five-second USB timeout.
Background JavaScript pacing prevented the original bridge error but introduced
long packet gaps; a foreground-page 40 ms pacing experiment received a complete
screenshot. The later USB timeout is distinct from `SFErrorDomain error 3`.

The native handler therefore records a monotonic deadline **40 ms after request
receipt**, submits USB work immediately, and asynchronously completes the reply
on the main queue at or after that deadline. A slower USB operation has already
consumed this interval and gains no extra 40 ms wait. No thread sleeps and no
USB operation is replayed. This also lets normal replies satisfy the JavaScript
minimum gap without relying on throttled background timers.

The background controller sends all native calls through one FIFO queue,
including chooser, polling, device, and session-cleanup requests. It allows one
call in flight and retains a **40 ms minimum start gap** as a guard, bounding new
calls to 25 per second. This spacing is an empirical workaround for the observed
retention, not a negotiated Safari limit.

The queue admits at most 128 pending calls and rejects work still waiting after
10 seconds. It checks document/session validity again before dispatch and never
replays a failed native call automatically: an uncertain USB write must not be
sent twice. Cleanup can still run after its page closes.

Real WebTiLP testing with a TI-84 Plus CE Python (`0451:e008`) has confirmed
information retrieval, directory listing, remote keys, clock synchronization,
and file reception. Both the temporary page-level queue and the installed native-pacing
implementation completed a real 320 × 240 screenshot and displayed its graph.
The installed build started the successful screenshot at 16:21:31.621 and
WebTiLP logged completion at 16:23:38 (local time), about 126 seconds later.
Native reply intervals were typically 45–55 ms. After the earlier failed USB
transfer, WebTiLP needed its emergency connection reset and a reconnect before
device information and the screenshot succeeded. These observations do not
establish complete WebUSB compatibility.

A 320 × 240 × 2-byte screenshot is 153,600 bytes. WebTiLP reads this in 64-byte
pieces. On the paced compatibility path, these require roughly 2,400 native
calls; dispatching those reads at 40 ms intervals alone takes at least about
96 seconds, and browser scheduling can increase this. The persistent transport
carries those same USB requests over the socket without the pacing floor.
Individual USB transfer timeouts remain five seconds, and requests retain
their exact lengths without read-ahead or automatic replay. Isochronous support,
concurrent streaming, native-process recovery, and the other boundaries in the
[README](../README.md#compatibility-boundaries) remain separate limitations.

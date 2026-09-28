"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {webcrypto} = require("node:crypto");
const {trustedOrigin, validateFilters, eligible, createNativeScheduler, createController} = require("../extension/background.js");
const device = {id: "dev-1", vendorId: 0x451, productId: 0xe008, serialNumber: "A", deviceClass: 0,
  configurations: [{configurationValue: 1, interfaces: [{interfaceNumber: 0, alternates: [{interfaceClass: 255, interfaceSubclass: 0, interfaceProtocol: 0}]}]}]};
const event = () => { const listeners = []; return {addListener: fn => listeners.push(fn), fire: (...args) => listeners.map(fn => fn(...args))}; };
const tick = () => new Promise(resolve => setImmediate(resolve));
class FakeClock {
  constructor() { this.now = 0; this.nextId = 0; this.pending = new Map(); }
  setTimeout(fn, delay) { const id = ++this.nextId; this.pending.set(id, {fn, at: this.now + delay}); return id; }
  clearTimeout(id) { this.pending.delete(id); }
  setInterval(fn, delay) {
    const id = ++this.nextId;
    this.poll = fn;
    this.pending.set(id, {fn, at: this.now + delay, repeat: delay});
    return id;
  }
  clearInterval(id) { this.pending.delete(id); }
  async advance(milliseconds) {
    const target = this.now + milliseconds;
    await tick();
    for (;;) {
      const next = [...this.pending].filter(([, t]) => t.at <= target).sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
      if (!next) break;
      const [id, timer] = next;
      this.now = timer.at;
      this.pending.delete(id);
      if (timer.repeat) this.pending.set(id, {...timer, at: this.now + timer.repeat});
      timer.fn();
      await tick();
    }
    this.now = target;
    await tick();
  }
}
function harness(minimumGap = 0) {
  const calls = [], starts = [], posts = [], windows = [];
  let instance = "epoch-1";
  let connected = true;
  const runtime = {id: "extension-id", onConnect: event(), onMessage: event(), getURL: path => `safari-web-extension://test/${path}`,
    async sendNativeMessage(app, message) {
      calls.push(message); starts.push(timers.now);
      let result = null;
      if (message.op === "enumerate") result = [device];
      else if (message.op === "grant") result = device;
      else if (message.op === "getDevices") result = connected ? [device] : [];
      else if (message.op === "open") result = {...device, opened: true};
      return {ok: true, instance, result};
    }};
  const browser = {runtime, windows: {onRemoved: event(), create: async options => { windows.push(options); return {id: 7}; }, remove: async () => {}}};
  const timers = new FakeClock();
  const nativeScheduler = createNativeScheduler({timers, now: () => timers.now, minimumGap});
  let disconnectTransport, emitEvent;
  const transportFactory = ({onDisconnect, onEvent}) => {
    disconnectTransport = onDisconnect; emitEvent = onEvent;
    return {minimumGap, send: message => runtime.sendNativeMessage("org.webtilp.safariwebusb", message), close() {}};
  };
  const controller = createController(browser, webcrypto, timers, {nativeScheduler, transportFactory});
  function port(url = "https://example.org/app", frameId = 0) {
    const port = {name: "safari-webusb-v1", sender: {url, frameId, tab: {id: 3}}, onMessage: event(), onDisconnect: event(), postMessage: m => posts.push(m), disconnect() { this.disconnected = true; }};
    runtime.onConnect.fire(port);
    return port;
  }
  async function choose(session) {
    const pending = controller.request(session, {id: "choose", op: "requestDevice", args: {filters: [{vendorId: 0x451}]}});
    await timers.advance(minimumGap);
    const url = windows.at(-1).url;
    const selection = Promise.all(runtime.onMessage.fire({op: "chooserSelect", deviceId: "dev-1"}, {id: runtime.id, url}));
    await timers.advance(minimumGap);
    await selection;
    return pending;
  }
  return {browser, controller, calls, starts, posts, windows, timers, port, choose, disconnectTransport, emitEvent, setEpoch: value => { instance = value; }, unplug: () => { connected = false; }};
}
test("trusted origin comes from Safari sender, rejects frames and insecure pages", () => {
  assert.equal(trustedOrigin({tab: {}, frameId: 0, url: "https://example.org/a"}), "https://example.org");
  assert.equal(trustedOrigin({tab: {}, frameId: 0, url: "http://localhost:8765/a"}), "http://localhost:8765");
  for (const sender of [{tab: {}, frameId: 1, url: "https://example.org"}, {tab: {}, frameId: 0, url: "http://example.org"}, {tab: {}, frameId: 0, url: "file:///tmp/a"}, {frameId: 0, url: "https://example.org"}]) assert.throws(() => trustedOrigin(sender), {name: "SecurityError"});
});
test("USB filters implement class matching, exclusions and dependency validation", () => {
  assert.equal(eligible(device, validateFilters({filters: [{vendorId: 0x451}]})), true);
  assert.equal(eligible(device, validateFilters({filters: [{classCode: 255}]})), true);
  assert.equal(eligible(device, validateFilters({filters: [], exclusionFilters: [{serialNumber: "A"}]})), false);
  assert.equal(eligible({...device, deviceClass: 3}, validateFilters({filters: []})), false);
  for (const filter of [{productId: 1}, {subclassCode: 1}, {classCode: 255, protocolCode: 1}, {vendorId: -1}, {vendorId: 0.5}]) assert.throws(() => validateFilters({filters: [filter]}), {name: "TypeError"});
});
test("getDevices does not enumerate before consent; page cannot invoke grant or choose another origin", async () => {
  const h = harness(); h.port(); const [session] = h.controller.sessions;
  assert.deepEqual(await h.controller.request(session, {id: "1", op: "getDevices"}), []);
  assert.equal(h.calls.length, 0);
  await assert.rejects(h.controller.request(session, {id: "2", op: "grant", args: {deviceId: device.id}, origin: "https://evil.org"}), {name: "NotSupportedError"});
  await assert.rejects(h.controller.request(session, {id: "3", op: "open", args: {deviceId: device.id}}), {name: "NotAllowedError"});
  assert.equal(h.calls.length, 0);
});
test("only the privileged chooser can grant; operations bind origin, session, and native epoch", async () => {
  const h = harness(); h.port(); const [session] = h.controller.sessions;
  const choice = h.controller.request(session, {id: "1", op: "requestDevice", args: {filters: []}, origin: "https://evil.org"});
  await tick();
  const ignored = h.browser.runtime.onMessage.fire({op: "chooserSelect", deviceId: device.id}, {id: "extension-id", url: "https://example.org/chooser.html"});
  assert.equal(ignored[0], undefined);
  assert.equal(h.calls.filter(c => c.op === "grant").length, 0);
  const url = h.windows[0].url;
  const [info] = h.browser.runtime.onMessage.fire({op: "chooserInfo"}, {id: "extension-id", url});
  assert.equal((await info).origin, "https://example.org");
  await Promise.all(h.browser.runtime.onMessage.fire({op: "chooserSelect", deviceId: device.id}, {id: "extension-id", url}));
  assert.equal((await choice).id, device.id);
  await h.controller.request(session, {id: "2", op: "open", args: {deviceId: device.id}});
  assert.equal(h.calls.at(-1).origin, "https://example.org");
  assert.equal(h.calls.at(-1).session, session.id);
  assert.equal(h.calls.at(-1).instance, "epoch-1");
});
test("grants are per document, not transferable between tabs", async () => {
  const h = harness(); h.port(); h.port(); const [a, b] = h.controller.sessions;
  await h.choose(a);
  await assert.rejects(h.controller.request(b, {id: "1", op: "transferIn", args: {deviceId: device.id, endpointNumber: 1, length: 1}}), {name: "NotAllowedError"});
  assert.deepEqual(await h.controller.request(b, {id: "2", op: "getDevices"}), []);
});
test("native restart invalidates old grants and reports disconnect", async () => {
  const h = harness(); h.port(); const [session] = h.controller.sessions;
  await h.choose(session); h.setEpoch("epoch-2");
  await assert.rejects(h.controller.request(session, {id: "2", op: "open", args: {deviceId: device.id}}), {name: "InvalidStateError"});
  assert.equal(session.devices.size, 0);
  assert.deepEqual(h.posts.at(-1), {event: "disconnect", deviceId: device.id});
});
test("physical disconnect polling drops grant and tab close releases native session", async () => {
  const h = harness(); const port = h.port(); const [session] = h.controller.sessions;
  await h.choose(session); h.unplug(); await h.timers.poll();
  assert.equal(session.devices.size, 0);
  assert.deepEqual(h.posts.at(-1), {event: "disconnect", deviceId: device.id});
  port.onDisconnect.fire(); await tick();
  assert.equal(h.calls.at(-1).op, "closeSession");
  assert.equal(h.controller.sessions.size, 0);
});
test("closing chooser rejects request instead of leaving a promise pending", async () => {
  const h = harness(); h.port(); const [session] = h.controller.sessions;
  const pending = h.controller.request(session, {id: "1", op: "requestDevice", args: {filters: []}});
  const rejected = assert.rejects(pending, {name: "NotFoundError"});
  await tick(); h.browser.windows.onRemoved.fire(7); await rejected;
  assert.equal(h.controller.choosers.size, 0);
});
test("oversized transfers are rejected before native serialization", async () => {
  const h = harness(); h.port(); const [session] = h.controller.sessions;
  await assert.rejects(h.controller.request(session, {id: "1", op: "transferOut", args: {deviceId: device.id, data: "A".repeat(1400000)}}), {name: "QuotaExceededError"});
  assert.equal(h.calls.length, 0);
});
test("overlapping selection calls cannot race native enumeration to open two choosers", async () => {
  const h = harness(); h.port(); const [session] = h.controller.sessions;
  const first = h.controller.request(session, {id: "1", op: "requestDevice", args: {filters: []}});
  const rejected = assert.rejects(first, {name: "NotFoundError"});
  await assert.rejects(h.controller.request(session, {id: "2", op: "requestDevice", args: {filters: []}}), {name: "InvalidStateError"});
  await tick();
  assert.equal(h.windows.length, 1);
  h.browser.windows.onRemoved.fire(7); await rejected;
  assert.equal(session.choosing, false);
});

function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return {promise, resolve, reject}; }
function schedulerHarness(options = {}) {
  const clock = new FakeClock();
  return {clock, scheduler: createNativeScheduler({timers: clock, now: () => clock.now, ...options})};
}
test("native scheduler enforces FIFO starts 40 ms apart with at most one active call", async () => {
  const {clock, scheduler} = schedulerHarness();
  const started = [], first = deferred();
  const a = scheduler.schedule(() => { started.push(["a", clock.now]); return first.promise; });
  const b = scheduler.schedule(() => { started.push(["b", clock.now]); return "b"; });
  const c = scheduler.schedule(() => { started.push(["c", clock.now]); return "c"; });
  await clock.advance(80);
  assert.deepEqual(started, [["a", 0]]);
  first.resolve("a"); await tick();
  assert.deepEqual(started, [["a", 0], ["b", 80]]);
  await clock.advance(39);
  assert.equal(started.length, 2);
  await clock.advance(1);
  assert.deepEqual(started, [["a", 0], ["b", 80], ["c", 120]]);
  assert.deepEqual(await Promise.all([a, b, c]), ["a", "b", "c"]);
});
test("native scheduler bounds all pending work including its active call at 128", async () => {
  const {clock, scheduler} = schedulerHarness();
  const first = deferred(), calls = [];
  const requests = [scheduler.schedule(() => { calls.push(0); return first.promise; })];
  for (let i = 1; i < 128; i++) requests.push(scheduler.schedule(() => { calls.push(i); return i; }));
  await assert.rejects(scheduler.schedule(() => calls.push("overflow")), {name: "QuotaExceededError"});
  first.resolve(0);
  await clock.advance(127 * 40);
  assert.deepEqual(await Promise.all(requests), Array.from({length: 128}, (_, i) => i));
  assert.deepEqual(calls, Array.from({length: 128}, (_, i) => i));
});
test("queued native requests expire at 10 seconds even while the active call is stalled", async () => {
  const {clock, scheduler} = schedulerHarness();
  const first = deferred(), calls = [];
  const active = scheduler.schedule(() => first.promise);
  const queued = scheduler.schedule(() => calls.push("expired"));
  let expired = false;
  const rejection = assert.rejects(queued, error => { expired = true; return error.name === "TimeoutError" && error.message.includes("not started"); });
  await clock.advance(9999);
  assert.equal(expired, false);
  await clock.advance(1);
  await rejection;
  first.resolve(); await active; await tick();
  assert.deepEqual(calls, []);
  assert.equal(clock.pending.size, 0);
});
test("native failures propagate once and do not replay or poison the queue", async () => {
  const {clock, scheduler} = schedulerHarness();
  const error = new Error("ambiguous native failure"), calls = [];
  const failed = scheduler.schedule(() => { calls.push("write"); return Promise.reject(error); });
  const rejected = assert.rejects(failed, e => e === error);
  const next = scheduler.schedule(() => { calls.push("read"); return 42; });
  await clock.advance(40);
  await rejected;
  assert.equal(await next, 42);
  await clock.advance(10000);
  assert.deepEqual(calls, ["write", "read"]);
});
test("dispatch validation cancels stale queued work without issuing a native call", async () => {
  const {clock, scheduler} = schedulerHarness();
  const calls = []; let valid = true;
  await scheduler.schedule(() => calls.push("initial"));
  const stale = scheduler.schedule(() => calls.push("stale"), () => { if (!valid) throw Object.assign(new Error("stale"), {name: "AbortError"}); });
  const rejected = assert.rejects(stale, {name: "AbortError"});
  const next = scheduler.schedule(() => { calls.push("next"); return clock.now; });
  valid = false;
  await clock.advance(40);
  await rejected;
  assert.equal(await next, 40);
  assert.deepEqual(calls, ["initial", "next"]);
});
test("controller paces chooser, all documents, heartbeat and post-disconnect cleanup together", async () => {
  const h = harness(40), firstPort = h.port(); h.port();
  const [a, b] = h.controller.sessions;
  await h.choose(a); await h.choose(b);
  const base = h.calls.length;
  const openA = h.controller.request(a, {id: "a", op: "open", args: {deviceId: device.id}});
  const openB = h.controller.request(b, {id: "b", op: "open", args: {deviceId: device.id}});
  const poll = h.timers.poll();
  firstPort.onDisconnect.fire();
  await h.timers.advance(200);
  await Promise.all([openA, openB, poll]);
  assert.deepEqual(h.calls.slice(base).map(c => c.op), ["open", "open", "closeSession", "getDevices"]);
  assert.deepEqual(h.calls.slice(0, 4).map(c => c.op), ["enumerate", "grant", "enumerate", "grant"]);
  for (let i = 1; i < h.starts.length; i++) assert.ok(h.starts[i] - h.starts[i - 1] >= 40, JSON.stringify(h.starts));
  assert.equal(h.calls.at(-2).session, a.id);
  assert.equal(h.calls.at(-1).session, b.id);
});
test("queued grant is rejected if its document closes before dispatch", async () => {
  const h = harness(40), port = h.port(), [session] = h.controller.sessions;
  const choosing = h.controller.request(session, {id: "choose", op: "requestDevice", args: {filters: []}});
  const rejected = assert.rejects(choosing, {name: "AbortError"});
  await tick();
  const selection = Promise.all(h.browser.runtime.onMessage.fire({op: "chooserSelect", deviceId: device.id}, {id: h.browser.runtime.id, url: h.windows[0].url}));
  port.onDisconnect.fire();
  await h.timers.advance(40);
  await Promise.all([rejected, selection]);
  assert.deepEqual(h.calls.map(c => c.op), ["enumerate"]);
});
test("queued grant rechecks the origin and session identity captured from its document", async () => {
  for (const key of ["origin", "id"]) {
    const h = harness(40); h.port(); const [session] = h.controller.sessions;
    const choosing = h.controller.request(session, {id: "choose", op: "requestDevice", args: {filters: []}});
    const rejected = assert.rejects(choosing, {name: "SecurityError"});
    await tick();
    const selection = Promise.all(h.browser.runtime.onMessage.fire({op: "chooserSelect", deviceId: device.id}, {id: h.browser.runtime.id, url: h.windows[0].url}));
    session[key] = "changed";
    await h.timers.advance(40);
    await Promise.all([rejected, selection]);
    assert.deepEqual(h.calls.map(c => c.op), ["enumerate"]);
  }
});
test("native restart invalidates queued operations before another native dispatch", async () => {
  const h = harness(40); h.port(); const [session] = h.controller.sessions;
  await h.choose(session); h.setEpoch("epoch-2");
  const restarted = h.controller.request(session, {id: "a", op: "open", args: {deviceId: device.id}});
  const queued = h.controller.request(session, {id: "b", op: "reset", args: {deviceId: device.id}});
  const rejected = [assert.rejects(restarted, {name: "InvalidStateError"}), assert.rejects(queued, {name: "InvalidStateError"})];
  await h.timers.advance(80);
  await Promise.all(rejected);
  assert.equal(h.calls.filter(c => c.op === "reset").length, 0);
});
test("queued device operations recheck a grant revoked by an earlier forget", async () => {
  const h = harness(40); h.port(); const [session] = h.controller.sessions;
  await h.choose(session);
  const forgotten = h.controller.request(session, {id: "a", op: "forget", args: {deviceId: device.id}});
  const queued = h.controller.request(session, {id: "b", op: "open", args: {deviceId: device.id}});
  const rejected = assert.rejects(queued, {name: "NotAllowedError"});
  await h.timers.advance(80);
  await Promise.all([forgotten, rejected]);
  assert.equal(h.calls.filter(c => c.op === "open").length, 0);
});
test("grant completing after navigation still queues exactly one closeSession", async () => {
  const h = harness(40), port = h.port(), [session] = h.controller.sessions;
  const gate = deferred(), send = h.browser.runtime.sendNativeMessage;
  h.browser.runtime.sendNativeMessage = async (app, message) => {
    const reply = await send(app, message);
    if (message.op === "grant") await gate.promise;
    return reply;
  };
  const choosing = h.controller.request(session, {id: "choose", op: "requestDevice", args: {filters: []}});
  const rejected = assert.rejects(choosing, {name: "AbortError"});
  await tick();
  const selection = Promise.all(h.browser.runtime.onMessage.fire({op: "chooserSelect", deviceId: device.id}, {id: h.browser.runtime.id, url: h.windows[0].url}));
  await h.timers.advance(40);
  port.onDisconnect.fire();
  gate.resolve();
  await h.timers.advance(40);
  await Promise.all([selection, rejected]);
  assert.deepEqual(h.calls.map(c => c.op), ["enumerate", "grant", "closeSession"]);
  assert.equal(h.calls.at(-1).instance, "epoch-1");
  assert.equal(session.devices.size, 0);
});


test("persistent transport uses the global FIFO without a per-call timer gap", async () => {
  const {clock, scheduler} = schedulerHarness({minimumGap: () => 0});
  const active = deferred(), starts = [];
  const a = scheduler.schedule(() => { starts.push(["a", clock.now]); return active.promise; });
  const b = scheduler.schedule(() => { starts.push(["b", clock.now]); return "b"; });
  const c = scheduler.schedule(() => { starts.push(["c", clock.now]); return "c"; });
  assert.deepEqual(starts, [["a", 0]]);
  active.resolve("a");
  assert.deepEqual(await Promise.all([a, b, c]), ["a", "b", "c"]);
  assert.deepEqual(starts, [["a", 0], ["b", 0], ["c", 0]]);
  assert.equal(clock.pending.size, 0);
});
test("transport loss invalidates all documents and cancels queued calls without replay", async () => {
  const h = harness(); h.port(); h.port();
  const [a, b] = h.controller.sessions;
  await h.choose(a); await h.choose(b);
  const original = h.browser.runtime.sendNativeMessage;
  const nativeOpen = deferred();
  h.browser.runtime.sendNativeMessage = async (app, message) => {
    if (message.op === "open") { h.calls.push(message); return nativeOpen.promise; }
    return original(app, message);
  };
  const active = h.controller.request(a, {id: "a", op: "open", args: {deviceId: device.id}});
  const queued = h.controller.request(b, {id: "b", op: "reset", args: {deviceId: device.id}});
  const activeRejected = assert.rejects(active, {name: "InvalidStateError"});
  const queuedRejected = assert.rejects(queued, {name: "NetworkError"});
  const failure = Object.assign(new Error("socket lost"), {name: "NetworkError"});
  h.disconnectTransport(failure);
  await queuedRejected;
  assert.equal(a.instance, null); assert.equal(b.instance, null);
  assert.equal(a.devices.size, 0); assert.equal(b.devices.size, 0);
  nativeOpen.resolve({ok: true, instance: "epoch-1", result: {...device, opened: true}});
  await activeRejected;
  assert.equal(h.calls.filter(c => c.op === "reset").length, 0);
  assert.equal(h.calls.filter(c => c.op === "open").length, 1);
  assert.equal(a.devices.size, 0);
  assert.equal(h.posts.filter(p => p.event === "disconnect").length, 2);
  await h.choose(a);
  assert.equal(a.devices.size, 1);
});
test("transport loss rejects an open chooser and a fresh chooser can recover", async () => {
  const h = harness(); h.port(); const [session] = h.controller.sessions;
  const pending = h.controller.request(session, {id: "choose", op: "requestDevice", args: {filters: []}});
  const rejected = assert.rejects(pending, {name: "NetworkError"});
  await tick(); assert.equal(h.controller.choosers.size, 1);
  h.disconnectTransport(Object.assign(new Error("socket lost"), {name: "NetworkError"}));
  await rejected;
  assert.equal(h.controller.choosers.size, 0); assert.equal(session.choosing, false);
  await h.choose(session); assert.equal(session.devices.size, 1);
});

test("Serial and HID filters match IDs and collections with validated dependencies", () => {
  const {validatePeripheralFilters: filters, peripheralEligible: eligible} = require("../extension/background.js");
  const serial = {id:"port-1",usbVendorId:0x451,usbProductId:0xe018};
  assert.ok(eligible("serial", serial, filters("serial", {filters:[{usbVendorId:0x451,usbProductId:0xe018}]})));
  assert.ok(!eligible("serial", serial, filters("serial", {filters:[{usbVendorId:3}]})));
  const hid = {id:"hid-1",vendorId:0x3f0,productId:0x2441,collections:[{usagePage:0xff00,usage:1}]};
  assert.ok(eligible("hid", hid, filters("hid", {filters:[{usagePage:0xff00,usage:1}]})));
  assert.ok(!eligible("hid", hid, filters("hid", {filters:[],exclusionFilters:[{vendorId:0x3f0}]})));
  for (const [kind, value] of [["serial",{usbProductId:1}],["hid",{productId:1}],["hid",{usage:1}],["hid",{usagePage:-1}]])
    assert.throws(() => filters(kind,{filters:[value]}), {name:"TypeError"});
  assert.throws(() => filters("serial",{filters:[{bluetoothServiceClassId:1}]}), {name:"NotSupportedError"});
});

test("Serial and HID use distinct chooser grants, route input to one document, and revoke on loss", async () => {
  const h = harness(); h.port(); h.port("https://other.example/app");
  const [session, other] = h.controller.sessions;
  const port = {id:"port-1",usbVendorId:0x451,usbProductId:0xe018,opened:false};
  const hid = {id:"hid-1",vendorId:0x3f0,productId:0x2441,opened:false,collections:[]};
  h.browser.runtime.sendNativeMessage = async (_, message) => {
    h.calls.push(message);
    const value = message.op.startsWith("serial.") ? port : hid;
    const result = message.op.endsWith(".enumerate") || message.op.endsWith(".getPorts") || message.op.endsWith(".getDevices") ? [value] : value;
    return {ok:true,instance:"epoch-1",result};
  };
  for (const op of ["serial.getPorts","hid.getDevices"]) assert.deepEqual(await h.controller.request(session,{id:op,op}), []);
  for (const op of ["serial.grant","hid.enumerate","serial.unknown"]) await assert.rejects(h.controller.request(session,{id:op,op,args:{deviceId:port.id}}),{name:"NotSupportedError"});
  for (const [op, device] of [["serial.requestPort",port],["hid.requestDevice",hid]]) {
    const pending = h.controller.request(session,{id:op,op,args:{filters:[]}});
    await tick(); const url=h.windows.at(-1).url;
    const [info] = await Promise.all(h.browser.runtime.onMessage.fire({op:"chooserInfo"},{id:h.browser.runtime.id,url}));
    assert.equal(info.kind,op.split(".")[0]);
    await Promise.all(h.browser.runtime.onMessage.fire({op:"chooserSelect",deviceId:device.id},{id:h.browser.runtime.id,url}));
    const selected=await pending;
    assert.deepEqual(selected,op.startsWith("hid.") ? [device] : device);
    await assert.rejects(h.controller.request(other,{id:"open-other",op:op.split(".")[0]+".open",args:{deviceId:device.id}}),{name:"NotAllowedError"});
  }
  assert.equal(h.calls.filter(c=>c.op==="serial.enumerate").length,2);
  assert.equal(h.calls.filter(c=>c.op==="hid.enumerate").length,2);
  await assert.rejects(h.controller.request(session,{id:"wrong-api",op:"serial.open",args:{deviceId:hid.id}}),{name:"NotAllowedError"});
  h.emitEvent(other.id,{event:"serial.data",deviceId:port.id,data:"AQ=="});
  h.emitEvent(session.id,{event:"serial.data",deviceId:hid.id,data:"Ag=="});
  assert.equal(h.posts.length,0);
  h.emitEvent(session.id,{event:"serial.data",deviceId:port.id,data:"AQ=="});
  assert.equal(h.posts.length,1); assert.equal(h.posts[0].data,"AQ=="); h.posts.length=0;
  h.disconnectTransport(new Error("gone"));
  assert.equal(session.serial.size,0); assert.equal(session.hid.size,0);
  assert.deepEqual(h.posts.filter(m=>m.event).map(m=>m.event),["serial.disconnect","hid.disconnect"]);
});

test("serial abort bypasses a blocked write, cancels queued same-port writes, and preserves other documents", async () => {
  const h=harness(); h.port(); h.port("https://other.example");
  const [session,other]=h.controller.sessions;
  for(const current of [session,other]) { current.instance="epoch-1"; current.serial.set("port-1",{id:"port-1"}); }
  let finishWrite,finishAbort;
  h.browser.runtime.sendNativeMessage=(_,message)=>{
    h.calls.push(message);
    if(message.op==="serial.abortWrite") return new Promise(resolve=>{finishAbort=()=>resolve({ok:true,instance:"epoch-1",result:null});});
    if(!finishWrite) return new Promise(resolve=>{finishWrite=()=>resolve({ok:false,instance:"epoch-1",error:{name:"AbortError",message:"canceled"}});});
    return Promise.resolve({ok:true,instance:"epoch-1",result:{bytesWritten:1}});
  };
  const request=(s,id,op="serial.write")=>h.controller.request(s,{id,op,args:{deviceId:"port-1",data:"AQ=="}});
  const first=assert.rejects(request(session,"active"),{name:"AbortError"});
  await tick();
  const queued=assert.rejects(request(session,"queued"),{name:"AbortError"});
  const preserved=request(other,"other");
  const abort=request(session,"abort","serial.abortWrite");
  await tick();
  assert.deepEqual(h.calls.map(c=>c.op),["serial.write","serial.abortWrite"]);
  const late=assert.rejects(request(session,"late"),{name:"AbortError"});
  finishWrite(); await tick(); await late;
  finishAbort(); await abort; await first; await queued;
  assert.deepEqual(await preserved,{bytesWritten:1});
  assert.equal(h.calls.filter(c=>c.op==="serial.write" && c.session===session.id).length,1);
});

test("peripheral chooser renews an expired native lease before granting its selected attachment", async () => {
  const h=harness(); h.port(); const [session]=h.controller.sessions;
  let enumeratedAt=-Infinity;
  const port={id:"port-1",usbVendorId:0x451,usbProductId:0xe018};
  h.browser.runtime.sendNativeMessage=async (_,message)=>{
    h.calls.push(message);
    if(message.op==="serial.enumerate") { enumeratedAt=h.timers.now; return {ok:true,instance:"epoch-1",result:[port]}; }
    assert.equal(message.op,"serial.grant");
    assert.ok(h.timers.now-enumeratedAt<60000,"grant has a live native session");
    return {ok:true,instance:"epoch-1",result:port};
  };
  const selection=h.controller.request(session,{id:"choose",op:"serial.requestPort",args:{filters:[]}});
  await tick(); await h.timers.advance(65000);
  const url=h.windows.at(-1).url;
  await Promise.all(h.browser.runtime.onMessage.fire({op:"chooserSelect",deviceId:port.id},{id:h.browser.runtime.id,url}));
  assert.deepEqual(await selection,port);
});

test("HID chooser cancellation returns an empty array without a grant", async () => {
  const h=harness(); h.port(); const [session]=h.controller.sessions;
  h.browser.runtime.sendNativeMessage=async (_,message)=>{h.calls.push(message);return {ok:true,instance:"epoch-1",result:[]};};
  const selection=h.controller.request(session,{id:"choose",op:"hid.requestDevice",args:{filters:[]}});
  await tick();
  await Promise.all(h.browser.runtime.onMessage.fire({op:"chooserCancel"},{id:h.browser.runtime.id,url:h.windows.at(-1).url}));
  assert.deepEqual(await selection,[]);
  assert.deepEqual(h.calls.map(c=>c.op),["hid.enumerate"]);
});

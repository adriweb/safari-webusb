"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");
const { randomUUID } = require("node:crypto");
const { ReadableStream, WritableStream } = require("node:stream/web");
const sources = Object.fromEntries(["serial", "hid"].map(kind => [kind,
  fs.readFileSync(path.join(__dirname, `../extension/page-${kind}.js`), "utf8")]));
const tick = () => new Promise(resolve => setImmediate(resolve));

function harness(kind, options = {}) {
  const listeners = new Map(), timers = new Map(), requests = [];
  let timerID = 0, granted = true;
  const current = kind === "hid" ? { id: "hid-device-1", vendorId: 0x03f0, productId: 0x2441,
    productName: "HP Prime", opened: false, collections: [{ usagePage: 0xff00, usage: 1, children: [],
      inputReports: [{ reportId: 1, items: [{ reportSize: 8, reportCount: 1024 }] }] }] }
    : { id: "serial-port-1", productName: "TI Evo", usbVendorId: 0x451, usbProductId: 0xe018, connected: true, opened: false };
  const navigator = { userActivation: { isActive: true } };
  if (options.native) navigator[kind] = options.native;
  const location = { origin: "https://devices.example" };
  const window = {
    isSecureContext: options.secure ?? true,
    addEventListener(type, handler) { if (!listeners.has(type)) listeners.set(type, []); listeners.get(type).push(handler); },
    postMessage(message, targetOrigin) {
      assert.equal(targetOrigin, location.origin);
      requests.push(structuredClone(message));
      queueMicrotask(async () => {
        if (h.drop) return;
        try { h.event({ id: message.id, ok: true, result: await h.handle(message) }); }
        catch (error) { h.event({ id: message.id, ok: false, error: { name: error.name, message: error.message } }); }
      });
    }
  };
  window.top = options.frame ? {} : window;
  function emit(type, event = {}) { for (const handler of listeners.get(type) ?? []) handler(event); }
  function native(message) {
    switch (message.op.split(".")[1]) {
      case "getPorts": case "getDevices": return granted ? [structuredClone(current)] : [];
      case "requestPort": granted = true; return structuredClone(current);
      case "requestDevice": granted = true; return [structuredClone(current)];
      case "open": current.opened = true; return structuredClone(current);
      case "close": current.opened = false; return null;
      case "forget": current.opened = false; granted = false; return null;
      case "write": return { bytesWritten: Buffer.from(message.args.data, "base64").length };
      case "receiveFeatureReport": return { data: Buffer.from([message.args.reportId, 23, 42]).toString("base64") };
      case "getSignals": return { clearToSend: true, dataCarrierDetect: false, dataSetReady: true, ringIndicator: false };
      default: return null;
    }
  }
  const h = { window, navigator, requests, timers, current, emit, handle: native, native, drop: false,
    event(data, overrides = {}) { emit("message", { source: window, origin: location.origin,
      data: { source: "safari-webusb-extension", ...data }, ...overrides }); },
    timeout() { for (const callback of [...timers.values()]) callback(); }
  };
  const context = vm.createContext({ window, navigator, location, Event, EventTarget, DOMException, ReadableStream, WritableStream,
    crypto: { randomUUID }, btoa: value => Buffer.from(value, "binary").toString("base64"),
    atob: value => {
      if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) throw new TypeError("Invalid base64");
      return Buffer.from(value, "base64").toString("binary");
    }, setTimeout(fn) { const id = ++timerID; timers.set(id, fn); return id; }, clearTimeout(id) { timers.delete(id); }
  });
  vm.runInContext(sources[kind], context, { filename: `page-${kind}.js` });
  h.api = navigator[kind];
  return h;
}
async function openedSerial(options = {}) {
  const h = harness("serial"), [port] = await h.api.getPorts();
  await port.open({ baudRate: 115200, ...options });
  return { h, port };
}
async function openedHID() {
  const h = harness("hid"), [device] = await h.api.getDevices(); await device.open(); return { h, device };
}

for (const kind of ["serial", "hid"]) {
  test(`${kind}: secure top-level install preserves native APIs and brands constructors`, () => {
    assert.equal(harness(kind, { secure: false }).api, undefined);
    assert.equal(harness(kind, { frame: true }).api, undefined);
    const native = {}; assert.equal(harness(kind, { native }).api, native);
    const h = harness(kind), names = kind === "serial" ? ["Serial", "SerialPort"] : ["HID", "HIDDevice"];
    for (const name of names) assert.throws(() => new h.window[name](), /Illegal constructor/);
    assert.equal(Object.prototype.toString.call(h.api), `[object ${names[0]}]`);
  });
  test(`${kind}: stable device identity and gesture restrictions`, async () => {
    const h = harness(kind), get = kind === "serial" ? "getPorts" : "getDevices", request = kind === "serial" ? "requestPort" : "requestDevice";
    const [device] = await h.api[get]();
    assert.equal((await h.api[get]())[0], device);
    const chosen = await h.api[request]({ filters: [] });
    assert.equal(kind === "serial" ? chosen : chosen[0], device);
    h.navigator.userActivation.isActive = false;
    await assert.rejects(h.api[request]({ filters: [] }), { name: "SecurityError" });
    assert.equal(h.timers.size, 0);
  });
  test(`${kind}: bridge loss rejects pending work, emits one disconnect, ignores late replies`, async () => {
    const h = harness(kind), get = kind === "serial" ? "getPorts" : "getDevices";
    const [device] = await h.api[get]();
    let count = 0;
    h.api.ondisconnect = event => { assert.equal(event[kind === "serial" ? "port" : "device"], device); count++; };
    h.drop = true;
    const promise = h.api[get]();
    const rejection = assert.rejects(promise, { name: "NetworkError" });
    h.event({ event: "bridge.disconnect" });
    await rejection;
    h.event({ event: "bridge.disconnect" });
    assert.equal(count, 1); assert.equal(h.timers.size, 0);
    await assert.rejects(h.api[get](), { name: "InvalidStateError" });
    await assert.rejects(device.open({ baudRate: 9600 }), { name: "NetworkError" });
    const requests = h.requests.length;
    await device.forget(); assert.equal(h.requests.length, requests);
  });
  test(`${kind}: only same-window same-origin replies resolve pending requests; pagehide aborts`, async () => {
    const h = harness(kind), get = kind === "serial" ? "getPorts" : "getDevices";
    h.drop = true;
    let settled = false;
    const promise = h.api[get]().finally(() => { settled = true; });
    const id = h.requests.at(-1).id;
    h.event({ id, ok: true, result: [] }, { source: {} });
    h.event({ id, ok: true, result: [] }, { origin: "https://other.example" });
    await tick(); assert.equal(settled, false);
    const rejection = assert.rejects(promise, { name: "AbortError" });
    h.emit("pagehide"); await rejection; assert.equal(h.timers.size, 0);
  });
}

test("serial: filter/open/signal validation is local and getInfo matches WebTiLP", async () => {
  const h = harness("serial"), port = await h.api.requestPort();
  assert.deepEqual({ ...port.getInfo() }, { usbVendorId: 0x451, usbProductId: 0xe018 });
  for (const filters of [null, {}, [{ usbProductId: 1 }], [{ usbVendorId: 65536 }]])
    await assert.rejects(h.api.requestPort({ filters }), { name: "TypeError" });
  for (const options of [undefined, {}, { baudRate: 0 }, { baudRate: 9600, dataBits: 6 }, { baudRate: 9600, bufferSize: 1024 * 1024 + 1 },
    { baudRate: 9600, parity: "mark" }, { baudRate: 9600, stopBits: 3 }]) await assert.rejects(port.open(options), { name: "TypeError" });
  assert.equal(port.readable, null); assert.equal(port.writable, null);
  await assert.rejects(port.getSignals(), { name: "InvalidStateError" });
  await port.open({ baudRate: 9600 });
  assert.equal((await port.getSignals()).clearToSend, true);
  await port.setSignals({ dataTerminalReady: true, break: false, ignored: true });
  assert.deepEqual(h.requests.at(-1).args.signals, { dataTerminalReady: true, break: false });
  await assert.rejects(port.setSignals({ break: 1 }), { name: "TypeError" });
  await assert.rejects(port.open({ baudRate: 9600 }), { name: "InvalidStateError" });
  await port.close(); assert.equal(port.readable, null);
});

test("serial: one read credit with backpressure, including data-before-ACK and BYOB", async () => {
  const { h, port } = await openedSerial({ bufferSize: 8 });
  let ack;
  h.handle = request => request.op === "serial.read" ? new Promise(resolve => { ack = resolve; }) : h.native(request);
  const reader = port.readable.getReader();
  const first = reader.read(); await tick();
  assert.equal(h.requests.filter(r => r.op === "serial.read").length, 1);
  h.event({ event: "serial.data", deviceId: h.current.id, data: "AQID" });
  assert.deepEqual(Array.from((await first).value), [1, 2, 3]);
  const second = reader.read(); await tick();
  assert.equal(h.requests.filter(r => r.op === "serial.read").length, 1);
  ack(null); await tick();
  assert.equal(h.requests.filter(r => r.op === "serial.read").length, 2);
  h.event({ event: "serial.data", deviceId: h.current.id, data: "BA==" });
  ack(null); assert.deepEqual(Array.from((await second).value), [4]);
  await tick(); assert.equal(h.requests.filter(r => r.op === "serial.read").length, 2);
  await reader.cancel(); reader.releaseLock();
  h.handle = h.native;
  const byob = port.readable.getReader({ mode: "byob" });
  const read = byob.read(new Uint8Array(8)); await tick();
  h.event({ event: "serial.data", deviceId: h.current.id, data: "BQY=" });
  assert.deepEqual(Array.from((await read).value), [5, 6]);
  await byob.cancel(); byob.releaseLock(); await port.close();
});

test("serial: canceled read events cannot reach a replacement stream before cancel ACK", async () => {
  const { h, port } = await openedSerial();
  let cancelAck;
  h.handle = request => request.op === "serial.cancelRead" ? new Promise(resolve => { cancelAck = resolve; }) : h.native(request);
  const reader = port.readable.getReader(); const oldRead = reader.read(); await tick();
  const cancel = reader.cancel(); await tick(); reader.releaseLock();
  const replacement = port.readable.getReader(); const newRead = replacement.read(); await tick();
  h.event({ event: "serial.data", deviceId: h.current.id, data: "/w==" });
  assert.equal(h.requests.filter(r => r.op === "serial.read").length, 1);
  cancelAck(null); await cancel; await tick();
  assert.equal((await oldRead).done, true);
  assert.equal(h.requests.filter(r => r.op === "serial.read").length, 2);
  h.event({ event: "serial.data", deviceId: h.current.id, data: "Bw==" });
  assert.deepEqual(Array.from((await newRead).value), [7]);
  h.handle = h.native; await replacement.cancel(); replacement.releaseLock(); await port.close();
});

test("serial: writes preserve BufferSource slices, serialize, and drain on stream close", async () => {
  const { h, port } = await openedSerial(); const writer = port.writable.getWriter();
  let release;
  h.handle = request => request.op === "serial.write" && !release ? new Promise(resolve => { release = () => resolve(h.native(request)); }) : h.native(request);
  const backing = Uint8Array.from([9, 1, 2, 8]);
  const first = writer.write(new DataView(backing.buffer, 1, 2));
  const second = writer.write(Uint8Array.from([3])); await tick();
  assert.equal(h.requests.filter(r => r.op === "serial.write").length, 1);
  assert.equal(h.requests.at(-1).args.data, "AQI=");
  await assert.rejects(port.close(), { name: "InvalidStateError" });
  release(); await Promise.all([first, second]);
  assert.equal(h.requests.filter(r => r.op === "serial.write").length, 2);
  await writer.close(); writer.releaseLock();
  assert.equal(h.requests.at(-1).op, "serial.drain");
  // WebTiLP's cleanup condition still observes an open port after stream close.
  assert.ok(port.readable || port.writable); await port.close();
});

test("serial: abort discards output without closing the port", async () => {
  const { h, port } = await openedSerial(); const writer = port.writable.getWriter();
  writer.closed.catch(() => {});
  await writer.abort(); writer.releaseLock();
  assert.equal(h.requests.at(-1).op, "serial.abortWrite");
  assert.ok(port.readable); assert.ok(port.writable); await port.close();
});

test("serial: abort interrupts an outstanding native write and permits a new writer", async () => {
  const { h, port } = await openedSerial(); const writer = port.writable.getWriter(); writer.closed.catch(() => {});
  let cancelWrite;
  h.handle = request => {
    if (request.op === "serial.write") return new Promise((_, reject) => { cancelWrite = () => reject(new DOMException("aborted", "AbortError")); });
    if (request.op === "serial.abortWrite") cancelWrite();
    return h.native(request);
  };
  const write = assert.rejects(writer.write(new Uint8Array([5])), { name: "AbortError" }); await tick();
  await writer.abort(); await write; writer.releaseLock();
  assert.equal(h.requests.filter(r => r.op === "serial.abortWrite").length, 1);
  assert.ok(port.writable); assert.ok(port.readable); await port.close();
});

test("serial: fatal native errors close stream state and allow explicit reopen", async () => {
  const { h, port } = await openedSerial(); const reader = port.readable.getReader(); reader.closed.catch(() => {});
  const result = assert.rejects(reader.read(), { name: "NetworkError" }); await tick();
  h.event({ event: "serial.error", deviceId: h.current.id, error: { name: "NetworkError", message: "descriptor closed" } });
  await result; reader.releaseLock();
  assert.equal(port.connected, true); assert.equal(port.readable, null); assert.equal(port.writable, null);
  await port.open({ baudRate: 115200 }); assert.ok(port.readable); assert.ok(port.writable); await port.close();
});

test("serial: partial writes fail without replay, oversized writes never reach native", async () => {
  for (const large of [false, true]) {
    const { h, port } = await openedSerial(); const writer = port.writable.getWriter(); writer.closed.catch(() => {});
    h.handle = request => request.op === "serial.write" ? { bytesWritten: 0 } : h.native(request);
    await assert.rejects(writer.write(new Uint8Array(large ? 1024 * 1024 + 1 : 1)), { name: large ? "TypeError" : "NetworkError" });
    assert.equal(h.requests.filter(r => r.op === "serial.write").length, large ? 0 : 1);
    assert.equal(port.writable, null); writer.releaseLock(); await port.close();
  }
});

test("serial: large buffer preferences retain 64KiB read credits and accept larger writes", async () => {
  const { h, port } = await openedSerial({ bufferSize: 1024 * 1024 });
  const reader = port.readable.getReader(); const read = reader.read(); await tick();
  assert.equal(h.requests.at(-1).args.length, 65536);
  await reader.cancel(); await read; reader.releaseLock();
  const writer = port.writable.getWriter();
  await writer.write(new Uint8Array(65537));
  assert.equal(Buffer.from(h.requests.at(-1).args.data, "base64").length, 65537);
  await writer.close(); writer.releaseLock(); await port.close();
});

test("serial: recoverable line errors replace readable; disconnect errors both streams and pending read", async () => {
  const { h, port } = await openedSerial();
  const oldStream = port.readable, reader = oldStream.getReader(); reader.closed.catch(() => {});
  const first = assert.rejects(reader.read(), { name: "ParityError" }); await tick();
  h.event({ event: "serial.error", deviceId: h.current.id, error: { name: "ParityError", message: "bad parity" } });
  await first; reader.releaseLock(); assert.notEqual(port.readable, oldStream);
  const next = port.readable.getReader(); next.closed.catch(() => {});
  const second = assert.rejects(next.read(), { name: "NetworkError" });
  const writer = port.writable.getWriter(); const closed = assert.rejects(writer.closed, { name: "NetworkError" });
  await tick(); h.event({ event: "serial.disconnect", deviceId: h.current.id });
  await second; await closed;
  assert.equal(port.connected, false); assert.equal(port.readable, null); assert.equal(port.writable, null);
  next.releaseLock(); writer.releaseLock();
});

test("serial: malformed/oversized input cannot overflow a read credit", async () => {
  for (const data of ["%%%", "AQID", ""]) {
    const { h, port } = await openedSerial({ bufferSize: 2 });
    const reader = port.readable.getReader(); reader.closed.catch(() => {});
    const result = assert.rejects(reader.read(), { name: "OperationError" }); await tick();
    h.event({ event: "serial.data", deviceId: h.current.id, data }); await result;
    assert.equal(port.readable, null); reader.releaseLock(); await port.close();
  }
});

test("HID: filter validation, immutable collections, and lifecycle state", async () => {
  const h = harness("hid");
  for (const options of [undefined, {}, { filters: {} }, { filters: [{ productId: 1 }] }, { filters: [{ usage: 1 }] },
    { filters: [{ vendorId: -1 }] }, { filters: [], exclusionFilters: null }])
    await assert.rejects(h.api.requestDevice(options), { name: "TypeError" });
  const [device] = await h.api.requestDevice({ filters: [{ vendorId: 0x3f0, usagePage: 0xff00, ignored: 1 }] });
  assert.deepEqual(h.requests.at(-1).args.filters, [{ vendorId: 0x3f0, usagePage: 0xff00 }]);
  assert.ok(Object.isFrozen(device.collections[0].inputReports[0].items));
  await assert.rejects(device.sendReport(1, new Uint8Array()), { name: "InvalidStateError" });
  await device.open(); assert.equal(device.opened, true);
  await assert.rejects(device.open(), { name: "InvalidStateError" });
  await device.close(); assert.equal(device.opened, false);
  await device.forget(); assert.equal((await h.api.getDevices()).length, 0);
});

test("HID: report writes preserve offsets; feature results include report ID", async () => {
  const { h, device } = await openedHID();
  const data = Uint8Array.from([99, 10, 20, 88]);
  await device.sendReport(1, new DataView(data.buffer, 1, 2));
  assert.deepEqual(h.requests.at(-1).args, { deviceId: h.current.id, reportId: 1, data: "ChQ=" });
  await device.sendFeatureReport(2, data.subarray(1, 3));
  assert.equal(h.requests.at(-1).op, "hid.sendFeatureReport");
  const result = await device.receiveFeatureReport(2);
  assert.equal(Object.prototype.toString.call(result), "[object DataView]");
  assert.deepEqual(Array.from(new Uint8Array(result.buffer)), [2, 23, 42]);
  for (const id of [-1, 256, 0.5]) await assert.rejects(device.sendReport(id, data), { name: "TypeError" });
  await device.sendReport(1, new Uint8Array(65537));
  assert.equal(Buffer.from(h.requests.at(-1).args.data, "base64").length, 65537);
  await assert.rejects(device.sendReport(1, new Uint8Array(1024 * 1024 + 1)), { name: "TypeError" });
  await assert.rejects(device.sendReport(1, [1, 2]), { name: "TypeError" });
  await assert.rejects(device.sendReport(1, new Uint8Array(new SharedArrayBuffer(2))), { name: "TypeError" });
});

test("HID: inputreport uses stable device and DataView without report ID; handler replacement works", async () => {
  const { h, device } = await openedHID(); let count = 0;
  device.oninputreport = () => assert.fail("replaced handler ran");
  device.oninputreport = event => {
    count++; assert.equal(event.device, device); assert.equal(event.reportId, 3);
    assert.deepEqual(Array.from(new Uint8Array(event.data.buffer)), [1, 2]);
    assert.ok(event instanceof h.window.HIDInputReportEvent);
  };
  h.event({ event: "hid.inputreport", deviceId: h.current.id, reportId: 3, data: "AQI=" });
  h.event({ event: "hid.inputreport", deviceId: h.current.id, reportId: 999, data: "AQI=" });
  h.event({ event: "hid.inputreport", deviceId: h.current.id, reportId: 3, data: "%%%" });
  assert.equal(count, 1);
  await device.close();
  h.event({ event: "hid.inputreport", deviceId: h.current.id, reportId: 3, data: "AQI=" });
  assert.equal(count, 1);
});

test("HID: input reports can arrive during a pending output report and disconnect rejects that output", async () => {
  const { h, device } = await openedHID(); let received = false;
  device.oninputreport = () => { received = true; };
  h.drop = true;
  const output = assert.rejects(device.sendReport(1, new Uint8Array([4])), { name: "NetworkError" });
  h.event({ event: "hid.inputreport", deviceId: h.current.id, reportId: 1, data: "AQ==" });
  assert.equal(received, true);
  h.event({ event: "hid.disconnect", deviceId: h.current.id }); await output;
  assert.equal(device.opened, false); assert.equal(h.timers.size, 0);
});

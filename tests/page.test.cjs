"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");
const { randomUUID } = require("node:crypto");
const source = fs.readFileSync(path.join(__dirname, "../extension/page.js"), "utf8");

function snapshot() {
  return {
    id: "native-device-7", usbVersionMajor: 2, usbVersionMinor: 0, usbVersionSubminor: 0,
    deviceClass: 0, deviceSubclass: 0, deviceProtocol: 0, vendorId: 0x0451, productId: 0xe008,
    deviceVersionMajor: 1, deviceVersionMinor: 0, deviceVersionSubminor: 2,
    manufacturerName: "Texas Instruments", productName: "TI-84 Plus CE", serialNumber: "TEST-ONLY",
    opened: false, configurationValue: 1,
    configurations: [{ configurationValue: 1, configurationName: "Default", interfaces: [{
      interfaceNumber: 0, claimed: false, alternateSetting: 0,
      alternates: [0, 1].map(alternateSetting => ({ alternateSetting, interfaceClass: 0xff,
        interfaceSubclass: 0, interfaceProtocol: 0, interfaceName: "TI interface",
        endpoints: ["in", "out"].map(direction => ({ endpointNumber: 1, direction, type: "bulk", packetSize: 64 }))
      }))
    }] }]
  };
}

function harness(options = {}) {
  const listeners = new Map();
  const timers = new Map();
  let timerID = 0;
  const requests = [];
  const current = snapshot();
  let granted = options.granted ?? true;
  const native = request => {
    const args = request.args;
    switch (request.op) {
      case "getDevices": return granted ? [structuredClone(current)] : [];
      case "requestDevice": granted = true; break;
      case "open": current.opened = true; break;
      case "close": current.opened = false; current.configurations[0].interfaces[0].claimed = false; break;
      case "selectConfiguration": current.configurationValue = args.configurationValue; break;
      case "claimInterface": current.configurations[0].interfaces[0].claimed = true; break;
      case "releaseInterface": current.configurations[0].interfaces[0].claimed = false; break;
      case "selectAlternateInterface": current.configurations[0].interfaces[0].alternateSetting = args.alternateSetting; break;
      case "clearHalt": case "reset": break;
      case "forget": granted = false; current.opened = false; return null;
      case "transferIn": case "controlTransferIn": return { status: "ok", data: "AAEC/w==" };
      case "transferOut": case "controlTransferOut": return { status: "ok", bytesWritten: Buffer.from(args.data, "base64").length };
      default: throw new Error(`Unexpected operation ${request.op}`);
    }
    return structuredClone(current);
  };
  const navigator = { userActivation: { isActive: true } };
  if (options.nativeUSB) navigator.usb = options.nativeUSB;
  const location = { origin: "https://webtilp.example" };
  const window = {
    isSecureContext: options.secure ?? true,
    addEventListener(type, handler) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(handler);
    },
    postMessage(message, targetOrigin) {
      assert.equal(targetOrigin, location.origin);
      requests.push(structuredClone(message));
      queueMicrotask(async () => {
        if (h.drop) return;
        try {
          const result = await h.handle(message);
          emit("message", { source: window, origin: location.origin,
            data: { source: "safari-webusb-extension", id: message.id, ok: true, result } });
        } catch (error) {
          emit("message", { source: window, origin: location.origin,
            data: { source: "safari-webusb-extension", id: message.id, ok: false, error: { name: error.name, message: error.message } } });
        }
      });
    }
  };
  window.top = options.frame ? {} : window;
  function emit(type, event = {}) { for (const handler of listeners.get(type) ?? []) handler(event); }
  const h = { window, navigator, requests, timers, current, emit, handle: native, native, drop: false,
    event(data, overrides = {}) { emit("message", { source: window, origin: location.origin,
      data: { source: "safari-webusb-extension", ...data }, ...overrides }); },
    timeout() { for (const callback of [...timers.values()]) callback.fn(); }
  };
  const context = vm.createContext({ window, navigator, location, Event, EventTarget, DOMException,
    crypto: { randomUUID }, btoa: value => Buffer.from(value, "binary").toString("base64"),
    atob: value => {
      if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) throw new TypeError("Invalid base64");
      return Buffer.from(value, "base64").toString("binary");
    },
    setTimeout(fn, delay) { const id = ++timerID; timers.set(id, { fn, delay }); return id; },
    clearTimeout(id) { timers.delete(id); }
  });
  vm.runInContext(source, context, { filename: "page.js" });
  h.usb = navigator.usb;
  return h;
}

test("install only in secure top-level documents without native WebUSB", () => {
  assert.equal(harness({ secure: false }).usb, undefined);
  assert.equal(harness({ frame: true }).usb, undefined);
  const nativeUSB = {};
  assert.equal(harness({ nativeUSB }).usb, nativeUSB);
  const h = harness();
  assert.ok(h.usb instanceof h.window.USB);
  for (const name of ["USB", "USBDevice", "USBConfiguration", "USBInterface", "USBAlternateInterface", "USBEndpoint"])
    assert.throws(() => new h.window[name](), /Illegal constructor/);
});

test("requestDevice filters are normalized and a user gesture is required", async () => {
  const h = harness({ granted: false });
  assert.equal((await h.usb.getDevices()).length, 0);
  h.navigator.userActivation.isActive = false;
  await assert.rejects(h.usb.requestDevice({ filters: [] }), { name: "SecurityError" });
  h.navigator.userActivation.isActive = true;
  for (const options of [undefined, {}, { filters: {} }, { filters: [{ productId: 1 }] },
    { filters: [{ subclassCode: 1 }] }, { filters: [{ classCode: 255, protocolCode: 1 }] },
    { filters: [{ vendorId: 65536 }] }, { filters: [], exclusionFilters: "bad" }])
    await assert.rejects(h.usb.requestDevice(options), { name: "TypeError" });
  const device = await h.usb.requestDevice({ filters: [{ vendorId: 0x451, ignored: "value" }],
    exclusionFilters: [{ vendorId: 0x451, productId: 1 }] });
  assert.equal(device.vendorId, 0x451);
  assert.deepEqual(h.requests.at(-1).args, { filters: [{ vendorId: 0x451 }], exclusionFilters: [{ vendorId: 0x451, productId: 1 }] });
  assert.equal(h.timers.size, 0);
});

test("devices have stable identity and expose descriptors used by Emscripten libusb", async () => {
  const h = harness();
  const [device] = await h.usb.getDevices();
  assert.equal(device, (await h.usb.getDevices())[0]);
  assert.equal(device, await h.usb.requestDevice({ filters: [] }));
  assert.ok(device instanceof h.window.USBDevice);
  assert.equal(Object.prototype.toString.call(device), "[object USBDevice]");
  const fields = ["usbVersionMajor", "usbVersionMinor", "usbVersionSubminor", "deviceClass", "deviceSubclass",
    "deviceProtocol", "vendorId", "productId", "deviceVersionMajor", "deviceVersionMinor", "deviceVersionSubminor",
    "manufacturerName", "productName", "serialNumber", "opened"];
  for (const field of fields) assert.equal(device[field], h.current[field]);
  assert.equal(device.configuration, device.configurations[0]);
  const config = device.configuration;
  const iface = config.interfaces[0];
  const alt = iface.alternate;
  assert.equal(config.configurationValue, 1);
  assert.equal(config.configurationName, "Default");
  assert.equal(iface.interfaceNumber, 0);
  assert.equal(iface.claimed, false);
  assert.equal(alt, iface.alternates[0]);
  assert.equal(alt.interfaceClass, 255);
  assert.equal(alt.endpoints[0], alt.endpoints[0]);
  assert.equal(alt.endpoints[0].direction, "in");
  assert.equal(alt.endpoints[0].endpointNumber, 1);
  assert.equal(alt.endpoints[0].type, "bulk");
  assert.equal(alt.endpoints[0].packetSize, 64);
  assert.ok(Object.isFrozen(device.configurations));
  assert.throws(() => { device.vendorId = 0; }, TypeError);
  // libusb attaches symbols to USBDevice to track identity/open refcounts.
  device[Symbol.for("libusb.open_close_chain")] = Promise.resolve(1);
  assert.ok(device[Symbol.for("libusb.open_close_chain")]);
});

test("state operations return undefined and update retained descriptors", async () => {
  const h = harness();
  const [device] = await h.usb.getDevices();
  const iface = device.configuration.interfaces[0];
  await assert.rejects(device.claimInterface(0), { name: "InvalidStateError" });
  assert.equal(await device.open(), undefined);
  assert.equal(device.opened, true);
  assert.equal(await device.selectConfiguration(1), undefined);
  assert.equal(await device.claimInterface(0), undefined);
  assert.equal(iface.claimed, true);
  assert.equal(await device.selectAlternateInterface(0, 1), undefined);
  assert.equal(iface.alternate, iface.alternates[1]);
  assert.equal(iface.alternate.alternateSetting, 1);
  assert.equal(await device.clearHalt("in", 1), undefined);
  assert.equal(await device.reset(), undefined);
  assert.equal(await device.releaseInterface(0), undefined);
  assert.equal(iface.claimed, false);
  await device.claimInterface(0);
  assert.equal(await device.close(), undefined);
  assert.equal(device.opened, false);
  assert.equal(iface.claimed, false);
  assert.equal(await device.forget(), undefined);
  assert.equal((await h.usb.getDevices()).length, 0);
});

test("bulk and control transfers preserve view offsets and DataView bytes", async () => {
  const h = harness();
  const [device] = await h.usb.getDevices();
  await device.open();
  const data = new Uint8Array([99, 1, 2, 3, 88]);
  const out = await device.transferOut(1, data.subarray(1, 4));
  assert.ok(out instanceof h.window.USBOutTransferResult);
  assert.equal(out.bytesWritten, 3);
  assert.equal(h.requests.at(-1).args.data, "AQID");
  await device.transferOut(1, new DataView(data.buffer, 2, 2));
  assert.equal(h.requests.at(-1).args.data, "AgM=");
  await device.transferOut(1, data.buffer);
  assert.equal(h.requests.at(-1).args.data, "YwECA1g=");
  const incoming = await device.transferIn(1, 64);
  assert.ok(incoming instanceof h.window.USBInTransferResult);
  assert.equal(Object.prototype.toString.call(incoming.data), "[object DataView]");
  assert.equal(incoming.data.byteLength, 4);
  assert.deepEqual(Array.from(new Uint8Array(incoming.data.buffer)), [0, 1, 2, 255]);
  const setup = { requestType: "vendor", recipient: "interface", request: 1, value: 257, index: 0 };
  assert.equal((await device.controlTransferIn(setup, 4)).data.getUint8(3), 255);
  await device.controlTransferOut(setup, new DataView(data.buffer, 1, 3));
  assert.deepEqual(h.requests.at(-1).args.setup, setup);
  assert.equal(h.requests.at(-1).args.data, "AQID");
  assert.equal((await device.controlTransferOut(setup)).bytesWritten, 0);
  assert.equal(h.requests.at(-1).args.data, "");
  assert.equal(h.timers.size, 0);
});

test("transfer validation rejects invalid endpoints, setup, lengths, and shared memory", async () => {
  const h = harness();
  const [device] = await h.usb.getDevices();
  await device.open();
  const setup = { requestType: "standard", recipient: "device", request: 6, value: 256, index: 0 };
  for (const endpoint of [0, 16, -1, 1.5, "1", NaN]) await assert.rejects(device.transferIn(endpoint, 4), { name: "TypeError" });
  for (const length of [-1, 1.5, 1048577, Infinity]) await assert.rejects(device.transferIn(1, length), { name: "TypeError" });
  await assert.rejects(device.transferOut(1, [1, 2]), { name: "TypeError" });
  await assert.rejects(device.transferOut(1, new Uint8Array(1048577)), { name: "TypeError" });
  await assert.rejects(device.transferOut(1, new Uint8Array(new SharedArrayBuffer(4))), { name: "TypeError" });
  await assert.rejects(device.controlTransferIn(setup, 65536), { name: "TypeError" });
  await assert.rejects(device.controlTransferOut(setup, new Uint8Array(65536)), { name: "TypeError" });
  await assert.rejects(device.controlTransferIn({ ...setup, requestType: "invalid" }, 4), { name: "TypeError" });
  await assert.rejects(device.controlTransferIn({ ...setup, value: -1 }, 4), { name: "TypeError" });
  await assert.rejects(device.selectConfiguration(0), { name: "TypeError" });
  await assert.rejects(device.clearHalt("out", 0), { name: "TypeError" });
  await assert.rejects(device.isochronousTransferIn(1, [64]), { name: "NotSupportedError" });
  await assert.rejects(device.isochronousTransferOut(1, new Uint8Array(1), [1]), { name: "NotSupportedError" });
});

test("stalls resolve and native errors retain DOMException names", async () => {
  const h = harness();
  const [device] = await h.usb.getDevices();
  await device.open();
  h.handle = () => ({ status: "stall", data: null });
  const result = await device.transferIn(1, 64);
  assert.equal(result.status, "stall");
  assert.equal(result.data, null);
  h.handle = () => ({ status: "stall", bytesWritten: 0 });
  assert.equal((await device.transferOut(1, new Uint8Array(0))).status, "stall");
  h.handle = () => { throw new DOMException("The interface is busy", "NetworkError"); };
  await assert.rejects(device.claimInterface(0), error => error instanceof DOMException && error.name === "NetworkError" && error.message === "The interface is busy");
  h.handle = () => { throw new DOMException("Old native instance", "InvalidStateError"); };
  await assert.rejects(device.open(), { name: "InvalidStateError" });
  assert.equal(h.timers.size, 0);
});

test("incoming transfer bounds protect libusb's direct DataView copy", async () => {
  const h = harness();
  const [device] = await h.usb.getDevices();
  await device.open();
  await assert.rejects(device.transferIn(1, 3), { name: "OperationError" });
  for (const result of [null, { status: "bad", data: "" }, { status: "ok" }, { status: "ok", data: "###" }]) {
    h.handle = () => result;
    await assert.rejects(device.transferIn(1, 4), { name: "OperationError" });
  }
  h.handle = () => ({ status: "ok", bytesWritten: 2 });
  await assert.rejects(device.transferOut(1, new Uint8Array(1)), { name: "OperationError" });
});

test("connect/disconnect events carry the same device and update opened/claimed state", async () => {
  const h = harness();
  const [device] = await h.usb.getDevices();
  await device.open();
  await device.claimInterface(0);
  const iface = device.configuration.interfaces[0];
  const events = [];
  h.usb.ondisconnect = event => events.push(event);
  h.event({ event: "disconnect", deviceId: h.current.id });
  assert.equal(events.length, 1);
  assert.ok(events[0] instanceof h.window.USBConnectionEvent);
  assert.equal(events[0].device, device);
  assert.equal(device.opened, false);
  assert.equal(iface.claimed, false);
  await assert.rejects(device.open(), { name: "NetworkError" });
  h.usb.onconnect = event => events.push(event);
  h.current.opened = false;
  h.event({ event: "connect", device: structuredClone(h.current) });
  assert.equal(events.length, 2);
  assert.equal(events[1].device, device);
  await device.open();
  h.usb.ondisconnect = null;
  h.event({ event: "disconnect", deviceId: h.current.id });
  assert.equal(events.length, 2);
});

test("messages from other sources or origins cannot settle requests", async () => {
  const h = harness();
  h.drop = true;
  const promise = h.usb.getDevices();
  const id = h.requests.at(-1).id;
  h.event({ id, ok: true, result: [] }, { source: {} });
  h.event({ id, ok: true, result: [] }, { origin: "https://other.example" });
  h.event({ source: "wrong", id, ok: true, result: [] });
  assert.equal(h.timers.size, 1);
  h.event({ id, ok: true, result: [] });
  assert.equal((await promise).length, 0);
  assert.equal(h.timers.size, 0);
});

test("timeouts and pagehide reject pending calls and clear timers", async () => {
  const h = harness();
  h.drop = true;
  let promise = h.usb.getDevices();
  assert.equal([...h.timers.values()][0].delay, 20000);
  const rejection = assert.rejects(promise, { name: "TimeoutError" });
  h.timeout();
  await rejection;
  // Fake timers keep fired handles, like a minimal scheduler; pagehide clears live ones.
  h.timers.clear();
  promise = h.usb.requestDevice({ filters: [] });
  assert.equal([...h.timers.values()][0].delay, 130000);
  const unloaded = assert.rejects(promise, { name: "AbortError" });
  h.emit("pagehide");
  await unloaded;
  assert.equal(h.timers.size, 0);
  h.emit("pageshow", { persisted: true });
  await assert.rejects(h.usb.getDevices(), error => error.name === "InvalidStateError" && /Reload/.test(error.message));
});

test("synchronous transport errors do not leave pending timeouts", async () => {
  const h = harness();
  h.window.postMessage = () => { throw new DOMException("Could not clone", "DataCloneError"); };
  await assert.rejects(h.usb.getDevices(), { name: "DataCloneError" });
  assert.equal(h.timers.size, 0);
});

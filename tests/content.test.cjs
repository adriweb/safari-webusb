"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { randomUUID } = require("node:crypto");
const { test } = require("node:test");
const source = fs.readFileSync(path.join(__dirname, "../extension/content.js"), "utf8");
const pageSource = fs.readFileSync(path.join(__dirname, "../extension/page.js"), "utf8");

const event = () => {
  const listeners = [];
  return { addListener(listener) { listeners.push(listener); }, emit(message) { listeners.forEach(listener => listener(message)); } };
};
function harness(options = {}) {
  const listeners = new Map();
  const posted = [];
  const forwarded = [];
  const timers = new Map();
  let timerID = 0;
  let now = 0;
  let connectionAttempts = 0;
  const origin = "https://webtilp.example";
  const port = {
    onMessage: event(), onDisconnect: event(), disconnects: 0,
    postMessage(message) {
      if (h.postError) throw h.postError;
      forwarded.push(structuredClone(message));
      if (h.onForward) h.onForward(message);
    },
    // Real WebExtension ports notify the other end, not this end, on disconnect().
    disconnect() { this.disconnects++; }
  };
  const window = {
    isSecureContext: options.secure ?? true,
    addEventListener(type, listener, flags) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push({ listener, once: flags?.once });
    },
    postMessage(message, targetOrigin) {
      assert.equal(targetOrigin, origin);
      posted.push(structuredClone(message));
      queueMicrotask(() => emit("message", { source: window, origin, data: message }));
    }
  };
  window.top = options.frame ? {} : window;
  function emit(type, message) {
    for (const entry of [...listeners.get(type) ?? []]) {
      entry.listener(message);
      if (entry.once) listeners.set(type, listeners.get(type).filter(item => item !== entry));
    }
  }
  const h = {
    window, port, posted, forwarded, timers,
    connectionAttempts: () => connectionAttempts,
    send(message, overrides = {}) { emit("message", { source: window, origin,
      data: { source: "safari-webusb-page", ...message }, ...overrides }); },
    reply(message) { port.onMessage.emit(message); },
    gesture(type = "click", flags = {}) { emit(type, { isTrusted: true, ...flags }); },
    advance(milliseconds) { now += milliseconds; },
    emit,
    expireAll() { for (const [id, timer] of [...timers]) { timers.delete(id); timer.fn(); } }
  };
  const context = vm.createContext({ window, location: { origin }, navigator: { userActivation: { isActive: true } },
    Event, EventTarget, DOMException, crypto: { randomUUID },
    btoa: value => Buffer.from(value, "binary").toString("base64"),
    atob: value => Buffer.from(value, "base64").toString("binary"),
    performance: { now: () => now },
    setTimeout(fn, delay) { const id = ++timerID; timers.set(id, { fn, delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    browser: { runtime: { connect(config) {
      connectionAttempts++;
      assert.equal(config.name, "safari-webusb-v1");
      if (options.connectError) throw new Error("Extension was reloaded");
      return port;
    } } }
  });
  vm.runInContext(source, context, { filename: "content.js" });
  h.loadPage = () => {
    vm.runInContext(pageSource, context, { filename: "page.js" });
    return context.navigator.usb;
  };
  return h;
}

test("isolated bridge runs only in secure top-level documents", () => {
  for (const options of [{ secure: false }, { frame: true }]) {
    const h = harness(options);
    h.send({ id: "1", op: "getDevices" });
    assert.equal(h.connectionAttempts(), 0);
    assert.equal(h.posted.length, 0);
    assert.equal(h.forwarded.length, 0);
  }
  assert.equal(harness().connectionAttempts(), 1);
});

test("bridge forwards only own-window own-origin messages with valid IDs", () => {
  const h = harness();
  const message = { id: "r1", op: "getDevices", args: {} };
  h.send(message, { source: {} });
  h.send(message, { origin: "https://untrusted.example" });
  h.send({ ...message, source: "unknown" });
  h.send({ ...message, id: 42 });
  h.send({ ...message, id: "x".repeat(101) });
  assert.equal(h.forwarded.length, 0);
  h.send({ ...message, origin: "https://forged.example", session: "forged", grant: true });
  assert.deepEqual(h.forwarded, [{ id: "r1", op: "getDevices", args: {} }]);
  h.send(message);
  assert.equal(h.forwarded.length, 1);
  h.reply({ id: "r1", ok: true, result: [] });
  assert.deepEqual(h.posted.at(-1), { id: "r1", ok: true, result: [], source: "safari-webusb-extension" });
  assert.equal(h.timers.size, 0);
  h.reply({ id: "r1", ok: true, result: [] });
  assert.equal(h.posted.length, 1);
});

test("requestDevice consumes one recent trusted gesture and ignores synthetic/repeated input", () => {
  const h = harness();
  let id = 0;
  const request = () => h.send({ id: String(++id), op: "requestDevice", args: { filters: [] } });
  request();
  assert.equal(h.posted.at(-1).error.name, "SecurityError");
  h.gesture("click", { isTrusted: false }); request();
  assert.equal(h.forwarded.length, 0);
  h.gesture("keydown", { repeat: true }); request();
  assert.equal(h.forwarded.length, 0);
  h.gesture("click"); h.advance(1001); request();
  assert.equal(h.forwarded.length, 0);
  h.gesture("click"); request();
  assert.equal(h.forwarded.length, 1);
  assert.equal([...h.timers.values()][0].delay, 130000);
  request();
  assert.equal(h.forwarded.length, 1);
  assert.equal(h.posted.at(-1).error.name, "SecurityError");
  h.gesture("keydown", { repeat: false }); request();
  assert.equal(h.forwarded.length, 2);
  h.gesture("touchend"); request();
  assert.equal(h.forwarded.length, 3);
});

test("pending quota is bounded and completed requests release capacity", () => {
  const h = harness();
  for (let id = 0; id < 33; id++) h.send({ id: String(id), op: "getDevices" });
  assert.equal(h.forwarded.length, 32);
  assert.equal(h.timers.size, 32);
  assert.equal(h.posted.at(-1).error.name, "QuotaExceededError");
  h.reply({ id: "0", ok: false, error: { name: "NetworkError", message: "host stopped" } });
  assert.equal(h.timers.size, 31);
  h.send({ id: "33", op: "getDevices" });
  assert.equal(h.forwarded.length, 33);
  assert.equal(h.timers.size, 32);
});

test("only known device events bypass pending IDs, and late events are suppressed", () => {
  const h = harness();
  h.reply(null);
  h.reply({ event: "unknown" });
  h.reply({ id: "unknown", ok: true, result: [] });
  assert.equal(h.posted.length, 0);
  h.reply({ event: "connect", device: { id: "device-1" } });
  h.reply({ event: "disconnect", deviceId: "device-1" });
  assert.equal(h.posted.length, 2);
  h.port.onDisconnect.emit();
  assert.equal(h.posted.at(-1).event, "bridge.disconnect");
  h.posted.pop();
  h.reply({ event: "connect", device: { id: "device-1" } });
  assert.equal(h.posted.length, 2);
});

test("remote disconnection rejects all pending calls once and prevents future forwarding", () => {
  const h = harness();
  h.send({ id: "1", op: "getDevices" });
  h.send({ id: "2", op: "getDevices" });
  h.port.onDisconnect.emit();
  assert.equal(h.posted.at(-1).event, "bridge.disconnect");
  h.posted.pop();
  assert.equal(h.posted.length, 2);
  assert.ok(h.posted.every(message => message.error.name === "InvalidStateError"));
  assert.equal(h.timers.size, 0);
  h.port.onDisconnect.emit();
  h.reply({ id: "1", ok: true, result: [] });
  assert.equal(h.posted.length, 2);
  h.send({ id: "3", op: "getDevices" });
  assert.equal(h.forwarded.length, 2);
  assert.equal(h.posted.at(-1).error.name, "InvalidStateError");
});

test("pagehide explicitly closes local state even without an onDisconnect event", () => {
  const h = harness();
  h.send({ id: "1", op: "getDevices" });
  h.emit("pagehide", {});
  assert.equal(h.port.disconnects, 1);
  assert.equal(h.posted.at(-1).event, "bridge.disconnect");
  h.posted.pop();
  assert.equal(h.posted.at(-1).error.name, "InvalidStateError");
  assert.equal(h.timers.size, 0);
  h.reply({ id: "1", ok: true, result: [] });
  assert.equal(h.posted.length, 1);
  h.emit("pageshow", { persisted: true });
  h.send({ id: "2", op: "getDevices" });
  assert.equal(h.forwarded.length, 1);
  assert.match(h.posted.at(-1).error.message, /Reload/);
  h.emit("pagehide", {});
  assert.equal(h.port.disconnects, 1);
});

test("connection startup and synchronous posting failures reject immediately", () => {
  const failed = harness({ connectError: true });
  failed.send({ id: "1", op: "getDevices" });
  assert.equal(failed.posted.at(-1).error.name, "InvalidStateError");
  assert.equal(failed.timers.size, 0);
  const h = harness();
  h.send({ id: "1", op: "getDevices" });
  h.postError = new Error("Attempting to use a disconnected port object");
  h.send({ id: "2", op: "getDevices" });
  assert.equal(h.posted.at(-1).event, "bridge.disconnect");
  h.posted.pop();
  assert.equal(h.posted.length, 2);
  assert.ok(h.posted.every(message => message.error.name === "InvalidStateError"));
  assert.equal(h.timers.size, 0);
  assert.equal(h.port.disconnects, 1);
});

test("unanswered requests expire without permanently consuming bridge quota", () => {
  const h = harness();
  for (let id = 0; id < 32; id++) h.send({ id: String(id), op: "getDevices" });
  assert.ok([...h.timers.values()].every(timer => timer.delay === 20000));
  h.expireAll();
  assert.equal(h.posted.length, 32);
  assert.ok(h.posted.every(message => message.error.name === "TimeoutError"));
  assert.equal(h.timers.size, 0);
  h.reply({ id: "0", ok: true, result: [] });
  assert.equal(h.posted.length, 32);
  h.send({ id: "new", op: "getDevices" });
  assert.equal(h.forwarded.length, 33);
});

test("real page shim and isolated bridge exchange RPCs and propagate host failure", async () => {
  const h = harness();
  const usb = h.loadPage();
  h.onForward = message => h.reply({ id: message.id, ok: true, result: [] });
  assert.equal((await usb.getDevices()).length, 0);
  assert.equal(h.forwarded.length, 1);
  assert.equal(h.timers.size, 0);
  // navigator.userActivation alone cannot bypass the isolated trusted-event gate.
  await assert.rejects(usb.requestDevice({ filters: [] }), { name: "SecurityError" });
  assert.equal(h.forwarded.length, 1);
  h.gesture();
  h.onForward = message => h.reply({ id: message.id, ok: false, error: { name: "NotFoundError", message: "No device selected." } });
  await assert.rejects(usb.requestDevice({ filters: [] }), { name: "NotFoundError" });
  assert.equal(h.forwarded.length, 2);
  assert.equal(h.timers.size, 0);
  h.onForward = undefined;
  const pending = usb.getDevices();
  await new Promise(resolve => queueMicrotask(resolve));
  h.port.onDisconnect.emit();
  await assert.rejects(pending, { name: "InvalidStateError" });
  assert.equal(h.timers.size, 0);
});

test("all three device choosers consume the same trusted activation and use the chooser deadline", () => {
  for (const op of ["serial.requestPort", "hid.requestDevice"]) {
    const h = harness();
    h.send({id:"denied",op,args:{filters:[]}});
    assert.equal(h.posted.at(-1).error.name,"SecurityError");
    h.emit("click", {isTrusted:true});
    h.send({id:"allowed",op,args:{filters:[]}});
    assert.equal(h.forwarded.length,1);
    assert.equal([...h.timers.values()][0].delay,130000);
    h.send({id:"used",op:"requestDevice",args:{filters:[]}});
    assert.equal(h.posted.at(-1).error.name,"SecurityError");
  }
});

test("isolated bridge passes native serial input and HID report events", () => {
  const h=harness();
  for (const event of ["serial.data","serial.error","hid.inputreport","hid.disconnect"]) h.reply({event,deviceId:"test",data:"AQ=="});
  assert.deepEqual(h.posted.map(m=>m.event),["serial.data","serial.error","hid.inputreport","hid.disconnect"]);
});

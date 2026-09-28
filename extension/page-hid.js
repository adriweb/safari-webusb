/* WebHID page API. Device authorization is enforced by the extension/native host. */
(() => {
  "use strict";
  if (!window.isSecureContext || window.top !== window || "hid" in navigator) return;
  const MAX_REPORT = 1024 * 1024;
  const token = Symbol("WebHID internal constructor");
  const slots = new WeakMap(), hidSlots = new WeakMap(), devices = new Map(), pending = new Map();
  const prefix = `hid:${crypto.randomUUID()}`;
  let sequence = 0, active = true;
  const exception = (name, message) => name === "TypeError" ? new TypeError(message) : new DOMException(message, name);
  function integer(value, max, name) {
    if (!Number.isInteger(value) || value < 0 || value > max) throw new TypeError(`Invalid ${name}.`);
    return value;
  }
  function state(device) {
    const slot = slots.get(device);
    if (!slot) throw new TypeError("Illegal invocation");
    return slot;
  }
  function ready(device, opened = true) {
    const slot = state(device);
    if (!slot.connected) throw exception("NetworkError", "The HID device is disconnected.");
    if (slot.busy || (opened && !slot.snapshot.opened)) throw exception("InvalidStateError", "The HID device is not ready.");
    return slot;
  }
  function rpc(op, args = {}) {
    if (!active) return Promise.reject(exception("InvalidStateError", "Reload this page to reconnect the device extension."));
    return new Promise((resolve, reject) => {
      const id = `${prefix}:${++sequence}`;
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(exception("TimeoutError", "The HID extension did not respond."));
      }, op === "hid.requestDevice" ? 130000 : 20000);
      pending.set(id, { resolve, reject, timer, deviceId: args.deviceId });
      try { window.postMessage({ source: "safari-webusb-page", id, op, args }, location.origin); }
      catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
    });
  }
  function freeze(value) {
    if (value && typeof value === "object") { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
    return value;
  }
  function snapshot(value) {
    if (!value || typeof value.id !== "string" || !Array.isArray(value.collections))
      throw exception("OperationError", "Invalid HID device snapshot.");
    integer(value.vendorId, 65535, "vendorId"); integer(value.productId, 65535, "productId");
    return { ...value, opened: !!value.opened, collections: freeze(JSON.parse(JSON.stringify(value.collections))) };
  }
  function deviceFor(value) {
    const data = snapshot(value);
    let device = devices.get(data.id);
    if (!device) { device = new HIDDevice(token, data); devices.set(data.id, device); }
    else { const slot = state(device); slot.snapshot = data; slot.connected = true; }
    return device;
  }
  function bytes(data) {
    let view;
    if (ArrayBuffer.isView(data)) view = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    else if (Object.prototype.toString.call(data) === "[object ArrayBuffer]") view = new Uint8Array(data);
    else throw new TypeError("data must be an ArrayBuffer or view.");
    if (Object.prototype.toString.call(view.buffer) === "[object SharedArrayBuffer]" || view.byteLength > MAX_REPORT)
      throw new TypeError(`HID reports require an unshared buffer of at most ${MAX_REPORT} bytes.`);
    return view;
  }
  function encode(view) {
    let binary = "";
    for (let offset = 0; offset < view.length; offset += 8192) binary += String.fromCharCode(...view.subarray(offset, offset + 8192));
    return btoa(binary);
  }
  function decode(data, maximum = MAX_REPORT) {
    if (typeof data !== "string" || data.length > 4 * Math.ceil(maximum / 3)) throw exception("OperationError", "Invalid HID report data.");
    let binary;
    try { binary = atob(data); } catch { throw exception("OperationError", "Invalid HID report data."); }
    if (binary.length > maximum) throw exception("OperationError", "The HID report is too large.");
    return new DataView(Uint8Array.from(binary, c => c.charCodeAt(0)).buffer);
  }
  async function change(device, op) {
    const slot = ready(device, false);
    if (op === "hid.open" && slot.snapshot.opened) throw exception("InvalidStateError", "The HID device is already open.");
    slot.busy = true;
    try {
      const result = await rpc(op, { deviceId: slot.snapshot.id });
      if (!slot.connected) throw exception("NetworkError", "The HID device is disconnected.");
      if (result && result.id !== slot.snapshot.id) throw exception("OperationError", "Invalid HID device snapshot.");
      if (result) slot.snapshot = snapshot(result);
      slot.snapshot = { ...slot.snapshot, opened: op === "hid.open" };
    } finally { slot.busy = false; }
  }
  class HIDDevice extends EventTarget {
    constructor(key, data) {
      super();
      if (key !== token) throw new TypeError("Illegal constructor");
      slots.set(this, { snapshot: data, connected: true, busy: false, inputreport: null });
    }
    async open() { await change(this, "hid.open"); }
    async close() { await change(this, "hid.close"); }
    async forget() {
      // The native host revokes grants when it reports a device disconnect.
      if (!state(this).connected) return;
      await change(this, "hid.forget");
    }
    async sendReport(reportId, data) {
      const slot = ready(this);
      await rpc("hid.sendReport", { deviceId: slot.snapshot.id, reportId: integer(reportId, 255, "reportId"), data: encode(bytes(data)) });
    }
    async sendFeatureReport(reportId, data) {
      const slot = ready(this);
      await rpc("hid.sendFeatureReport", { deviceId: slot.snapshot.id, reportId: integer(reportId, 255, "reportId"), data: encode(bytes(data)) });
    }
    async receiveFeatureReport(reportId) {
      const slot = ready(this);
      const result = await rpc("hid.receiveFeatureReport", { deviceId: slot.snapshot.id, reportId: integer(reportId, 255, "reportId") });
      // Feature data includes its nonzero report ID; inputreport data does not.
      return decode(result?.data, MAX_REPORT + 1);
    }
  }
  for (const field of ["vendorId", "productId", "productName", "opened", "collections"])
    Object.defineProperty(HIDDevice.prototype, field, { configurable: true, enumerable: true, get() { return state(this).snapshot[field]; } });
  class HIDConnectionEvent extends Event {
    constructor(type, options) {
      if (!options || !slots.has(options.device)) throw new TypeError("An HIDDevice is required.");
      super(type, options);
      Object.defineProperty(this, "device", { value: options.device, enumerable: true });
    }
  }
  class HIDInputReportEvent extends Event {
    constructor(type, options) {
      if (!options || !slots.has(options.device) || Object.prototype.toString.call(options.data) !== "[object DataView]")
        throw new TypeError("An HIDDevice and DataView are required.");
      integer(options.reportId, 255, "reportId");
      super(type, options);
      for (const field of ["device", "reportId", "data"]) Object.defineProperty(this, field, { value: options[field], enumerable: true });
    }
  }
  function filters(values, name) {
    if (!Array.isArray(values)) throw new TypeError(`${name} must be an array.`);
    return values.map(filter => {
      if (!filter || typeof filter !== "object") throw new TypeError("Each HID filter must be an object.");
      const result = {};
      for (const key of ["vendorId", "productId", "usagePage", "usage"])
        if (filter[key] !== undefined) result[key] = integer(filter[key], 65535, key);
      if (result.productId !== undefined && result.vendorId === undefined) throw new TypeError("productId requires vendorId.");
      if (result.usage !== undefined && result.usagePage === undefined) throw new TypeError("usage requires usagePage.");
      return result;
    });
  }
  class HID extends EventTarget {
    constructor(key) {
      super(); if (key !== token) throw new TypeError("Illegal constructor");
      hidSlots.set(this, { connect: null, disconnect: null });
    }
    async getDevices() {
      if (!hidSlots.has(this)) throw new TypeError("Illegal invocation");
      const result = await rpc("hid.getDevices");
      if (!Array.isArray(result)) throw exception("OperationError", "Invalid HID device list.");
      return result.map(deviceFor);
    }
    async requestDevice(options) {
      if (!hidSlots.has(this)) throw new TypeError("Illegal invocation");
      if (!options || typeof options !== "object") throw new TypeError("HIDDeviceRequestOptions are required.");
      const args = { filters: filters(options.filters, "filters") };
      if (options.exclusionFilters !== undefined) args.exclusionFilters = filters(options.exclusionFilters, "exclusionFilters");
      if (navigator.userActivation && !navigator.userActivation.isActive) throw exception("SecurityError", "requestDevice requires a user gesture.");
      const result = await rpc("hid.requestDevice", args);
      if (!Array.isArray(result)) throw exception("OperationError", "Invalid HID device list.");
      return result.map(deviceFor);
    }
  }
  function handler(Class, map, type) {
    Object.defineProperty(Class.prototype, `on${type}`, { configurable: true, enumerable: true,
      get() { if (!map.has(this)) throw new TypeError("Illegal invocation"); return map.get(this)[type]; },
      set(value) {
        const slot = map.get(this); if (!slot) throw new TypeError("Illegal invocation");
        if (slot[type]) this.removeEventListener(type, slot[type]);
        slot[type] = typeof value === "function" ? value : null;
        if (slot[type]) this.addEventListener(type, slot[type]);
      }
    });
  }
  handler(HIDDevice, slots, "inputreport"); handler(HID, hidSlots, "connect"); handler(HID, hidSlots, "disconnect");
  const hid = new HID(token);
  function rejectPending(error, deviceId) {
    for (const [id, request] of pending) if (deviceId === undefined || request.deviceId === deviceId) {
      clearTimeout(request.timer); pending.delete(id); request.reject(error);
    }
  }
  function disconnect(device, error) {
    const slot = state(device), wasConnected = slot.connected;
    slot.connected = false; slot.snapshot = { ...slot.snapshot, opened: false };
    rejectPending(error, slot.snapshot.id);
    if (wasConnected) hid.dispatchEvent(new HIDConnectionEvent("disconnect", { device }));
  }
  function terminate(error) {
    if (!active) return;
    active = false; rejectPending(error);
    for (const device of devices.values()) disconnect(device, error);
  }
  window.addEventListener("message", event => {
    if (event.source !== window || event.origin !== location.origin || !active) return;
    const message = event.data;
    if (!message || message.source !== "safari-webusb-extension") return;
    if (message.event) {
      if (message.event === "bridge.disconnect") { terminate(exception("NetworkError", "The device extension disconnected. Reload this page.")); return; }
      try {
        if (message.event === "hid.connect") hid.dispatchEvent(new HIDConnectionEvent("connect", { device: deviceFor(message.device) }));
        const device = devices.get(message.deviceId);
        if (!device) return;
        if (message.event === "hid.disconnect") disconnect(device, exception("NetworkError", "The HID device disconnected."));
        if (message.event === "hid.inputreport" && state(device).connected && device.opened)
          device.dispatchEvent(new HIDInputReportEvent("inputreport", { device, reportId: message.reportId, data: decode(message.data) }));
      } catch { /* Ignore malformed unsolicited events. */ }
      return;
    }
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id); clearTimeout(request.timer);
    if (message.ok === true) request.resolve(message.result);
    else request.reject(exception(message.error?.name || "OperationError", message.error?.message || "The HID operation failed."));
  });
  window.addEventListener("pagehide", () => terminate(exception("AbortError", "The document was hidden or unloaded.")));
  for (const Class of [HID, HIDDevice, HIDConnectionEvent, HIDInputReportEvent]) {
    Object.defineProperty(Class.prototype, Symbol.toStringTag, { value: Class.name, configurable: true });
    if (!(Class.name in window)) Object.defineProperty(window, Class.name, { value: Class, writable: true, configurable: true });
  }
  Object.defineProperty(navigator, "hid", { value: hid, configurable: true, enumerable: true });
})();

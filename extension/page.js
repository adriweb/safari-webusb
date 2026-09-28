/* Safari WebUSB prototype. Runs in the page world; authorization lives in the
 * isolated extension and native host. Never trust this code as a security gate. */
(() => {
  "use strict";
  if (!window.isSecureContext || window.top !== window || "usb" in navigator) return;

  const MAX_TRANSFER = 1024 * 1024;
  const TIMEOUT_MS = 20000;
  const token = Symbol("WebUSB internal constructor");
  const devices = new Map();
  const deviceSlots = new WeakMap();
  const descriptorSlots = new WeakMap();
  const pending = new Map();
  const prefix = crypto.randomUUID();
  let sequence = 0;
  let active = true;

  const exception = (name, message) => name === "TypeError" ? new TypeError(message)
    : name === "RangeError" ? new RangeError(message) : new DOMException(message, name);
  function integer(value, maximum, name, minimum = 0) {
    if (!Number.isInteger(value) || value < minimum || value > maximum)
      throw new TypeError(`${name} must be an integer from ${minimum} to ${maximum}.`);
    return value;
  }
  function enumeration(value, allowed, name) {
    if (!allowed.includes(value)) throw new TypeError(`Invalid ${name}.`);
    return value;
  }
  function rpc(op, args = {}) {
    if (!active) return Promise.reject(exception("InvalidStateError", "Reload this page to reconnect the Safari WebUSB extension."));
    return new Promise((resolve, reject) => {
      const id = `${prefix}:${++sequence}`;
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(exception("TimeoutError", "The Safari WebUSB extension did not respond."));
      }, op === "requestDevice" ? 130000 : TIMEOUT_MS);
      pending.set(id, { resolve, reject, timer });
      try {
        window.postMessage({ source: "safari-webusb-page", id, op, args }, location.origin);
      } catch (error) {
        clearTimeout(timer);
        pending.delete(id);
        reject(error);
      }
    });
  }
  function state(device) {
    const slot = deviceSlots.get(device);
    if (!slot) throw new TypeError("Illegal invocation");
    return slot;
  }
  function available(device, opened = false) {
    const slot = state(device);
    if (!slot.connected) throw exception("NetworkError", "The USB device is disconnected.");
    if (opened && !slot.snapshot.opened) throw exception("InvalidStateError", "The USB device is not open.");
    return slot;
  }
  function snapshotValid(snapshot) {
    return snapshot && typeof snapshot.id === "string" && Array.isArray(snapshot.configurations);
  }
  function update(device, snapshot) {
    const slot = state(device);
    if (!snapshotValid(snapshot) || snapshot.id !== slot.snapshot.id)
      throw exception("OperationError", "The extension returned an invalid USB device.");
    slot.snapshot = snapshot;
    slot.connected = true;
  }
  function deviceFor(snapshot) {
    if (!snapshotValid(snapshot)) throw exception("OperationError", "The extension returned an invalid USB device.");
    let device = devices.get(snapshot.id);
    if (!device) {
      device = new USBDevice(token, snapshot);
      devices.set(snapshot.id, device);
    } else update(device, snapshot);
    return device;
  }
  async function change(device, op, args = {}, requiresOpen = true) {
    const slot = available(device, requiresOpen);
    update(device, await rpc(op, { deviceId: slot.snapshot.id, ...args }));
  }
  function closeLocally(device) {
    const slot = state(device);
    slot.snapshot = { ...slot.snapshot, opened: false, configurations: slot.snapshot.configurations.map(c => ({
      ...c, interfaces: c.interfaces.map(i => ({ ...i, claimed: false }))
    })) };
  }

  // Wrapper identity is stable; getters read the latest snapshot so a retained
  // USBInterface sees claim/release and alternate-setting changes immediately.
  function wrap(device, kind, keys) {
    const slot = state(device);
    const key = JSON.stringify([kind, ...keys]);
    if (!slot.wrappers.has(key)) {
      const Class = { configuration: USBConfiguration, interface: USBInterface,
        alternate: USBAlternateInterface, endpoint: USBEndpoint }[kind];
      const wrapper = new Class(token);
      descriptorSlots.set(wrapper, { device, keys });
      slot.wrappers.set(key, wrapper);
    }
    return slot.wrappers.get(key);
  }
  function descriptor(object, depth) {
    const slot = descriptorSlots.get(object);
    if (!slot) throw new TypeError("Illegal invocation");
    const [configurationValue, interfaceNumber, alternateSetting, endpointNumber, direction] = slot.keys;
    let value = state(slot.device).snapshot.configurations.find(c => c.configurationValue === configurationValue);
    if (depth >= 2) value = value?.interfaces.find(i => i.interfaceNumber === interfaceNumber);
    if (depth >= 3) value = value?.alternates.find(a => a.alternateSetting === alternateSetting);
    if (depth >= 4) value = value?.endpoints.find(e => e.endpointNumber === endpointNumber && e.direction === direction);
    if (!value) throw exception("InvalidStateError", "The USB descriptor is no longer available.");
    return value;
  }
  class USBConfiguration {
    constructor(key) { if (key !== token) throw new TypeError("Illegal constructor"); }
    get interfaces() {
      const { device, keys } = descriptorSlots.get(this);
      return Object.freeze(descriptor(this, 1).interfaces.map(i => wrap(device, "interface", [keys[0], i.interfaceNumber])));
    }
  }
  class USBInterface {
    constructor(key) { if (key !== token) throw new TypeError("Illegal constructor"); }
    get alternate() {
      const { device, keys } = descriptorSlots.get(this);
      const value = descriptor(this, 2);
      return wrap(device, "alternate", [...keys, value.alternateSetting ?? value.alternates[0].alternateSetting]);
    }
    get alternates() {
      const { device, keys } = descriptorSlots.get(this);
      return Object.freeze(descriptor(this, 2).alternates.map(a => wrap(device, "alternate", [...keys, a.alternateSetting])));
    }
  }
  class USBAlternateInterface {
    constructor(key) { if (key !== token) throw new TypeError("Illegal constructor"); }
    get endpoints() {
      const { device, keys } = descriptorSlots.get(this);
      return Object.freeze(descriptor(this, 3).endpoints.map(e => wrap(device, "endpoint", [...keys, e.endpointNumber, e.direction])));
    }
  }
  class USBEndpoint {
    constructor(key) { if (key !== token) throw new TypeError("Illegal constructor"); }
  }
  for (const [Class, depth, fields] of [
    [USBConfiguration, 1, ["configurationValue", "configurationName"]],
    [USBInterface, 2, ["interfaceNumber", "claimed"]],
    [USBAlternateInterface, 3, ["alternateSetting", "interfaceClass", "interfaceSubclass", "interfaceProtocol", "interfaceName"]],
    [USBEndpoint, 4, ["endpointNumber", "direction", "type", "packetSize"]]
  ]) for (const field of fields) Object.defineProperty(Class.prototype, field, {
    configurable: true, enumerable: true, get() { return descriptor(this, depth)[field]; }
  });

  function bytes(data, maximum, optional = false) {
    if (data === undefined && optional) return new Uint8Array(0);
    let view;
    if (ArrayBuffer.isView(data)) view = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    else if (Object.prototype.toString.call(data) === "[object ArrayBuffer]") view = new Uint8Array(data);
    else throw new TypeError("data must be an ArrayBuffer or an ArrayBuffer view.");
    if (Object.prototype.toString.call(view.buffer) === "[object SharedArrayBuffer]")
      throw new TypeError("SharedArrayBuffer data is not supported.");
    if (view.byteLength > maximum) throw new TypeError(`Transfers are limited to ${maximum} bytes.`);
    return view;
  }
  function encode(view) {
    let binary = "";
    for (let offset = 0; offset < view.length; offset += 8192)
      binary += String.fromCharCode(...view.subarray(offset, offset + 8192));
    return btoa(binary);
  }
  function setupParameters(setup) {
    if (!setup || typeof setup !== "object") throw new TypeError("A control transfer setup is required.");
    return {
      requestType: enumeration(setup.requestType, ["standard", "class", "vendor"], "requestType"),
      recipient: enumeration(setup.recipient, ["device", "interface", "endpoint", "other"], "recipient"),
      request: integer(setup.request, 255, "request"),
      value: integer(setup.value, 65535, "value"),
      index: integer(setup.index, 65535, "index")
    };
  }
  class USBInTransferResult {
    constructor(status, data = null) {
      enumeration(status, ["ok", "stall", "babble"], "transfer status");
      if (data !== null && Object.prototype.toString.call(data) !== "[object DataView]") throw new TypeError("data must be a DataView.");
      Object.defineProperties(this, { status: { value: status, enumerable: true }, data: { value: data, enumerable: true } });
    }
  }
  class USBOutTransferResult {
    constructor(status, bytesWritten = 0) {
      enumeration(status, ["ok", "stall"], "transfer status");
      integer(bytesWritten, Number.MAX_SAFE_INTEGER, "bytesWritten");
      Object.defineProperties(this, { status: { value: status, enumerable: true }, bytesWritten: { value: bytesWritten, enumerable: true } });
    }
  }
  function inResult(result, maximum) {
    if (!result || !["ok", "stall", "babble"].includes(result.status)) throw exception("OperationError", "Invalid USB transfer result.");
    if (result.data == null && result.status !== "ok") return new USBInTransferResult(result.status);
    if (typeof result.data !== "string") throw exception("OperationError", "Missing USB transfer data.");
    let binary;
    try { binary = atob(result.data); } catch { throw exception("OperationError", "Invalid USB transfer data."); }
    if (binary.length > maximum) throw exception("OperationError", "The USB transfer exceeded the requested length.");
    const data = Uint8Array.from(binary, c => c.charCodeAt(0));
    return new USBInTransferResult(result.status, new DataView(data.buffer));
  }
  function outResult(result, maximum) {
    if (!result || !["ok", "stall"].includes(result.status) || !Number.isInteger(result.bytesWritten)
        || result.bytesWritten < 0 || result.bytesWritten > maximum)
      throw exception("OperationError", "Invalid USB transfer result.");
    return new USBOutTransferResult(result.status, result.bytesWritten);
  }
  class USBDevice {
    constructor(key, snapshot) {
      if (key !== token) throw new TypeError("Illegal constructor");
      deviceSlots.set(this, { snapshot, connected: true, wrappers: new Map() });
    }
    get configurations() {
      return Object.freeze(state(this).snapshot.configurations.map(c => wrap(this, "configuration", [c.configurationValue])));
    }
    get configuration() {
      const value = state(this).snapshot.configurationValue;
      return value == null || value === 0 ? null : wrap(this, "configuration", [value]);
    }
    async open() { await change(this, "open", {}, false); }
    async close() { await change(this, "close", {}, false); }
    async selectConfiguration(configurationValue) {
      await change(this, "selectConfiguration", { configurationValue: integer(configurationValue, 255, "configurationValue", 1) });
    }
    async claimInterface(interfaceNumber) {
      await change(this, "claimInterface", { interfaceNumber: integer(interfaceNumber, 255, "interfaceNumber") });
    }
    async releaseInterface(interfaceNumber) {
      await change(this, "releaseInterface", { interfaceNumber: integer(interfaceNumber, 255, "interfaceNumber") });
    }
    async selectAlternateInterface(interfaceNumber, alternateSetting) {
      await change(this, "selectAlternateInterface", { interfaceNumber: integer(interfaceNumber, 255, "interfaceNumber"),
        alternateSetting: integer(alternateSetting, 255, "alternateSetting") });
    }
    async clearHalt(direction, endpointNumber) {
      await change(this, "clearHalt", { direction: enumeration(direction, ["in", "out"], "direction"),
        endpointNumber: integer(endpointNumber, 15, "endpointNumber", 1) });
    }
    async reset() { await change(this, "reset"); }
    async forget() {
      const slot = state(this);
      await rpc("forget", { deviceId: slot.snapshot.id });
      closeLocally(this);
    }
    async transferIn(endpointNumber, length) {
      const slot = available(this, true);
      integer(endpointNumber, 15, "endpointNumber", 1);
      integer(length, MAX_TRANSFER, "length");
      return inResult(await rpc("transferIn", { deviceId: slot.snapshot.id, endpointNumber, length }), length);
    }
    async transferOut(endpointNumber, data) {
      const slot = available(this, true);
      integer(endpointNumber, 15, "endpointNumber", 1);
      const view = bytes(data, MAX_TRANSFER);
      return outResult(await rpc("transferOut", { deviceId: slot.snapshot.id, endpointNumber, data: encode(view) }), view.byteLength);
    }
    async controlTransferIn(setup, length) {
      const slot = available(this, true);
      const parameters = setupParameters(setup);
      integer(length, 65535, "length");
      return inResult(await rpc("controlTransferIn", { deviceId: slot.snapshot.id, setup: parameters, length }), length);
    }
    async controlTransferOut(setup, data) {
      const slot = available(this, true);
      const parameters = setupParameters(setup);
      const view = bytes(data, 65535, true);
      return outResult(await rpc("controlTransferOut", { deviceId: slot.snapshot.id, setup: parameters, data: encode(view) }), view.byteLength);
    }
    async isochronousTransferIn() { state(this); throw exception("NotSupportedError", "Isochronous transfers are not supported by Safari WebUSB."); }
    async isochronousTransferOut() { state(this); throw exception("NotSupportedError", "Isochronous transfers are not supported by Safari WebUSB."); }
  }
  for (const field of ["usbVersionMajor", "usbVersionMinor", "usbVersionSubminor", "deviceClass", "deviceSubclass", "deviceProtocol",
    "vendorId", "productId", "deviceVersionMajor", "deviceVersionMinor", "deviceVersionSubminor",
    "manufacturerName", "productName", "serialNumber", "opened"])
    Object.defineProperty(USBDevice.prototype, field, { configurable: true, enumerable: true,
      get() { return state(this).snapshot[field]; } });

  function filters(values, name) {
    if (!Array.isArray(values)) throw new TypeError(`${name} must be an array.`);
    return values.map(filter => {
      if (!filter || typeof filter !== "object") throw new TypeError("Each USB filter must be an object.");
      const result = {};
      for (const field of ["vendorId", "productId", "classCode", "subclassCode", "protocolCode"])
        if (filter[field] !== undefined) result[field] = integer(filter[field], field.endsWith("Id") ? 65535 : 255, field);
      if (result.productId !== undefined && result.vendorId === undefined) throw new TypeError("productId requires vendorId.");
      if (result.subclassCode !== undefined && result.classCode === undefined) throw new TypeError("subclassCode requires classCode.");
      if (result.protocolCode !== undefined && result.subclassCode === undefined) throw new TypeError("protocolCode requires subclassCode.");
      if (filter.serialNumber !== undefined) result.serialNumber = String(filter.serialNumber);
      return result;
    });
  }
  class USBConnectionEvent extends Event {
    constructor(type, options) {
      if (!options || !deviceSlots.has(options.device)) throw new TypeError("A USBDevice is required.");
      super(type, options);
      Object.defineProperty(this, "device", { value: options.device, enumerable: true });
    }
  }
  const usbSlots = new WeakMap();
  class USB extends EventTarget {
    constructor(key) {
      super();
      if (key !== token) throw new TypeError("Illegal constructor");
      usbSlots.set(this, { connect: null, disconnect: null });
    }
    async getDevices() {
      if (!usbSlots.has(this)) throw new TypeError("Illegal invocation");
      const result = await rpc("getDevices");
      if (!Array.isArray(result)) throw exception("OperationError", "Invalid USB device list.");
      return result.map(deviceFor);
    }
    async requestDevice(options) {
      if (!usbSlots.has(this)) throw new TypeError("Illegal invocation");
      if (!options || typeof options !== "object") throw new TypeError("USBDeviceRequestOptions are required.");
      const args = { filters: filters(options.filters, "filters") };
      if (options.exclusionFilters !== undefined) args.exclusionFilters = filters(options.exclusionFilters, "exclusionFilters");
      if (navigator.userActivation && !navigator.userActivation.isActive)
        throw exception("SecurityError", "requestDevice requires a user gesture.");
      return deviceFor(await rpc("requestDevice", args));
    }
  }
  for (const type of ["connect", "disconnect"]) Object.defineProperty(USB.prototype, `on${type}`, {
    configurable: true, enumerable: true,
    get() { return usbSlots.get(this)[type]; },
    set(handler) {
      const handlers = usbSlots.get(this);
      if (handlers[type]) this.removeEventListener(type, handlers[type]);
      handlers[type] = typeof handler === "function" ? handler : null;
      if (handlers[type]) this.addEventListener(type, handlers[type]);
    }
  });
  const usb = new USB(token);
  window.addEventListener("message", event => {
    if (event.source !== window || event.origin !== location.origin) return;
    const message = event.data;
    if (!message || message.source !== "safari-webusb-extension") return;
    if (message.event === "connect" || message.event === "disconnect") {
      if (!active) return;
      let device;
      try {
        if (message.event === "connect") device = deviceFor(message.device);
        else {
          device = devices.get(message.deviceId);
          if (!device) return;
          closeLocally(device);
          state(device).connected = false;
        }
        usb.dispatchEvent(new USBConnectionEvent(message.event, { device }));
      } catch { /* Malformed unsolicited events cannot break pending RPCs. */ }
      return;
    }
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    clearTimeout(request.timer);
    if (message.ok === true) request.resolve(message.result);
    else request.reject(exception(message.error?.name || "OperationError", message.error?.message || "The USB operation failed."));
  });
  window.addEventListener("pagehide", () => {
    active = false;
    for (const request of pending.values()) {
      clearTimeout(request.timer);
      request.reject(exception("AbortError", "The document was hidden or unloaded."));
    }
    pending.clear();
    for (const device of devices.values()) closeLocally(device);
  });

  for (const Class of [USB, USBDevice, USBConfiguration, USBInterface, USBAlternateInterface, USBEndpoint,
    USBConnectionEvent, USBInTransferResult, USBOutTransferResult]) {
    Object.defineProperty(Class.prototype, Symbol.toStringTag, { value: Class.name, configurable: true });
    if (!(Class.name in window)) Object.defineProperty(window, Class.name, { value: Class, writable: true, configurable: true });
  }
  Object.defineProperty(navigator, "usb", { value: usb, configurable: true, enumerable: true });
})();

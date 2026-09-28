/* Web Serial page API. Authorization and port ownership live in the native host. */
(() => {
  "use strict";
  if (!window.isSecureContext || window.top !== window || "serial" in navigator) return;
  const MAX_READ = 65536, MAX_TRANSFER = 1024 * 1024;
  const token = Symbol("Web Serial internal constructor");
  const slots = new WeakMap(), serialSlots = new WeakMap(), ports = new Map(), pending = new Map();
  const prefix = `serial:${crypto.randomUUID()}`;
  let sequence = 0, active = true;
  const exception = (name, message) => name === "TypeError" ? new TypeError(message) : new DOMException(message, name);
  function integer(value, max, name, min = 0) {
    if (!Number.isInteger(value) || value < min || value > max) throw new TypeError(`Invalid ${name}.`);
    return value;
  }
  function enumeration(value, allowed, name) {
    if (!allowed.includes(value)) throw new TypeError(`Invalid ${name}.`);
    return value;
  }
  function state(port) {
    const slot = slots.get(port); if (!slot) throw new TypeError("Illegal invocation"); return slot;
  }
  function ready(port, opened = true) {
    const slot = state(port);
    if (!slot.connected) throw exception("NetworkError", "The serial port is disconnected.");
    if (slot.busy || (opened && !slot.opened)) throw exception("InvalidStateError", "The serial port is not ready.");
    return slot;
  }
  function rpc(op, args = {}) {
    if (!active) return Promise.reject(exception("InvalidStateError", "Reload this page to reconnect the device extension."));
    return new Promise((resolve, reject) => {
      const id = `${prefix}:${++sequence}`;
      const timer = setTimeout(() => {
        pending.delete(id); reject(exception("TimeoutError", "The serial extension did not respond."));
      }, op === "serial.requestPort" ? 130000 : 20000);
      pending.set(id, { resolve, reject, timer, deviceId: args.deviceId });
      try { window.postMessage({ source: "safari-webusb-page", id, op, args }, location.origin); }
      catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
    });
  }
  function snapshot(value) {
    if (!value || typeof value.id !== "string") throw exception("OperationError", "Invalid serial port snapshot.");
    for (const name of ["usbVendorId", "usbProductId"]) if (value[name] !== undefined) integer(value[name], 65535, name);
    return { ...value, connected: value.connected !== false, opened: !!value.opened };
  }
  function portFor(value) {
    const data = snapshot(value);
    let port = ports.get(data.id);
    if (!port) { port = new SerialPort(token, data); ports.set(data.id, port); }
    else { const slot = state(port); slot.snapshot = data; slot.connected = data.connected; }
    return port;
  }
  function bytes(data) {
    let view;
    if (ArrayBuffer.isView(data)) view = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    else if (Object.prototype.toString.call(data) === "[object ArrayBuffer]") view = new Uint8Array(data);
    else throw new TypeError("data must be an ArrayBuffer or view.");
    if (Object.prototype.toString.call(view.buffer) === "[object SharedArrayBuffer]" || view.byteLength > MAX_TRANSFER)
      throw new TypeError(`Serial writes require an unshared buffer of at most ${MAX_TRANSFER} bytes.`);
    return view;
  }
  function encode(view) {
    let binary = "";
    for (let offset = 0; offset < view.length; offset += 8192) binary += String.fromCharCode(...view.subarray(offset, offset + 8192));
    return btoa(binary);
  }
  function decode(data, length) {
    if (typeof data !== "string" || data.length > 4 * Math.ceil(length / 3)) throw exception("OperationError", "Invalid serial read data.");
    let binary;
    try { binary = atob(data); } catch { throw exception("OperationError", "Invalid serial read data."); }
    if (!binary.length || binary.length > length) throw exception("OperationError", "Invalid serial read length.");
    return Uint8Array.from(binary, c => c.charCodeAt(0));
  }
  function finishCredit(slot, credit) {
    if (!credit.ack || !credit.delivered) return;
    if (slot.credit === credit) slot.credit = null;
    credit.resolve();
  }
  function clearCredit(slot) {
    const credit = slot.credit;
    slot.credit = null;
    if (credit) credit.resolve();
  }
  function failRead(slot, error, fatal = true) {
    clearCredit(slot);
    const controller = slot.readController;
    slot.readStream = null; slot.readController = null; slot.readFatal = fatal;
    try { controller?.error(error); } catch { /* Already canceled. */ }
  }
  function clearStreams(slot, error) {
    failRead(slot, error);
    const controller = slot.writeController;
    slot.writeStream = null; slot.writeController = null; slot.writeFatal = true;
    try { controller?.error(error); } catch { /* Already closed. */ }
  }
  function readable(port) {
    const slot = state(port);
    if (!slot.opened || !slot.connected || slot.busy || slot.readFatal) return null;
    if (slot.readStream) return slot.readStream;
    let controller;
    const stream = new ReadableStream({
      type: "bytes",
      start(value) { controller = value; slot.readController = value; },
      async pull() {
        // A cancellation acknowledgment fences data from the previous reader.
        try { await slot.readCancel; }
        catch (error) { if (slot.readController === controller) failRead(slot, error); return; }
        if (!slot.opened || slot.readController !== controller || slot.readFatal) return;
        return new Promise(resolve => {
          const credit = { resolve, controller, length: Math.min(slot.bufferSize, MAX_READ), ack: false, delivered: false };
          slot.credit = credit;
          rpc("serial.read", { deviceId: slot.snapshot.id, length: credit.length }).then(() => {
            credit.ack = true; finishCredit(slot, credit);
          }, error => {
            if (slot.credit === credit) failRead(slot, error);
            else credit.resolve();
          });
        });
      },
      cancel() {
        if (slot.readController !== controller) return;
        slot.readStream = null; slot.readController = null; clearCredit(slot);
        const previous = slot.readCancel;
        slot.readCancel = previous.then(() => rpc("serial.cancelRead", { deviceId: slot.snapshot.id }));
        // Keep failures visible to cancel(), but prevent an ignored promise from
        // becoming an unhandled rejection before a new reader is acquired.
        slot.readCancel.catch(() => {});
        return slot.readCancel;
      }
    }, { highWaterMark: 0 });
    slot.readStream = stream;
    return stream;
  }
  function writable(port) {
    const slot = state(port);
    if (!slot.opened || !slot.connected || slot.busy || slot.writeFatal) return null;
    if (slot.writeStream) return slot.writeStream;
    let controller, abortRequest;
    function abortOutput() {
      if (!abortRequest) {
        abortRequest = rpc("serial.abortWrite", { deviceId: slot.snapshot.id });
        abortRequest.catch(() => {});
      }
      return abortRequest;
    }
    const stream = new WritableStream({
      start(value) {
        controller = value; slot.writeController = value;
        // Stream abort must interrupt an outstanding native write, instead of
        // waiting for the write to finish before the sink's abort callback.
        value.signal?.addEventListener("abort", abortOutput, { once: true });
      },
      async write(data) {
        try {
          ready(port);
          const view = bytes(data);
          const result = await rpc("serial.write", { deviceId: slot.snapshot.id, data: encode(view) });
          if (!result || result.bytesWritten !== view.byteLength) throw exception("NetworkError", "The serial write was incomplete.");
        } catch (error) {
          if (slot.writeController === controller) { slot.writeStream = null; slot.writeController = null; slot.writeFatal = !abortRequest; }
          throw error;
        }
      },
      async close() {
        await rpc("serial.drain", { deviceId: slot.snapshot.id });
        if (slot.writeController === controller) { slot.writeStream = null; slot.writeController = null; }
      },
      async abort() {
        await abortOutput();
        if (slot.writeController === controller) { slot.writeStream = null; slot.writeController = null; }
      }
    }, { highWaterMark: 1 });
    slot.writeStream = stream;
    return stream;
  }
  class SerialPort extends EventTarget {
    constructor(key, data) {
      super(); if (key !== token) throw new TypeError("Illegal constructor");
      slots.set(this, { snapshot: data, connected: data.connected, opened: false, busy: false,
        readStream: null, readController: null, readFatal: false, readCancel: Promise.resolve(), credit: null,
        writeStream: null, writeController: null, writeFatal: false, bufferSize: MAX_TRANSFER,
        connect: null, disconnect: null });
    }
    get connected() { return state(this).connected; }
    get readable() { return readable(this); }
    get writable() { return writable(this); }
    getInfo() {
      const data = state(this).snapshot, result = {};
      for (const name of ["usbVendorId", "usbProductId"]) if (data[name] !== undefined) result[name] = data[name];
      return result;
    }
    async open(options) {
      const slot = ready(this, false);
      if (slot.opened) throw exception("InvalidStateError", "The serial port is already open.");
      if (!options || typeof options !== "object") throw new TypeError("SerialOptions are required.");
      const args = {
        deviceId: slot.snapshot.id, baudRate: integer(options.baudRate, 0xffffffff, "baudRate", 1),
        dataBits: enumeration(options.dataBits ?? 8, [7, 8], "dataBits"),
        stopBits: enumeration(options.stopBits ?? 1, [1, 2], "stopBits"),
        parity: enumeration(options.parity ?? "none", ["none", "even", "odd"], "parity"),
        flowControl: enumeration(options.flowControl ?? "none", ["none", "hardware"], "flowControl"),
        bufferSize: integer(options.bufferSize ?? 255, MAX_TRANSFER, "bufferSize", 1)
      };
      slot.busy = true;
      try {
        const result = snapshot(await rpc("serial.open", args));
        if (!slot.connected) throw exception("NetworkError", "The serial port is disconnected.");
        if (result.id !== slot.snapshot.id || !result.opened) throw exception("OperationError", "Invalid serial open result.");
        slot.snapshot = result; slot.opened = true; slot.bufferSize = args.bufferSize;
        slot.readFatal = false; slot.writeFatal = false; slot.readCancel = Promise.resolve();
      } finally { slot.busy = false; }
    }
    async close() {
      const slot = ready(this);
      if (slot.readStream?.locked || slot.writeStream?.locked) throw exception("InvalidStateError", "Release the stream locks before closing the serial port.");
      slot.busy = true;
      try {
        await rpc("serial.close", { deviceId: slot.snapshot.id });
        slot.opened = false;
        clearStreams(slot, exception("InvalidStateError", "The serial port is closed."));
      } finally { slot.busy = false; }
    }
    async forget() {
      // Physical/bridge disconnect already revokes the document's native grant.
      if (!state(this).connected) return;
      const slot = ready(this, false);
      slot.busy = true;
      try {
        await rpc("serial.forget", { deviceId: slot.snapshot.id });
        slot.opened = false;
        clearStreams(slot, exception("InvalidStateError", "The serial port grant was forgotten."));
      } finally { slot.busy = false; }
    }
    async getSignals() {
      const slot = ready(this), result = await rpc("serial.getSignals", { deviceId: slot.snapshot.id });
      const signals = {};
      for (const name of ["clearToSend", "dataCarrierDetect", "dataSetReady", "ringIndicator"]) {
        if (typeof result?.[name] !== "boolean") throw exception("OperationError", "Invalid serial signals.");
        signals[name] = result[name];
      }
      return signals;
    }
    async setSignals(options = {}) {
      const slot = ready(this);
      if (!options || typeof options !== "object") throw new TypeError("SerialOutputSignals are required.");
      const signals = {};
      for (const name of ["dataTerminalReady", "requestToSend", "break"]) if (options[name] !== undefined) {
        if (typeof options[name] !== "boolean") throw new TypeError(`Invalid ${name}.`);
        signals[name] = options[name];
      }
      await rpc("serial.setSignals", { deviceId: slot.snapshot.id, signals });
    }
  }
  class SerialConnectionEvent extends Event {
    constructor(type, options) {
      if (!options || !slots.has(options.port)) throw new TypeError("A SerialPort is required.");
      super(type, options); Object.defineProperty(this, "port", { value: options.port, enumerable: true });
    }
  }
  function filters(values) {
    if (!Array.isArray(values)) throw new TypeError("filters must be an array.");
    return values.map(filter => {
      if (!filter || typeof filter !== "object") throw new TypeError("Each serial filter must be an object.");
      const result = {};
      for (const name of ["usbVendorId", "usbProductId"]) if (filter[name] !== undefined) result[name] = integer(filter[name], 65535, name);
      if (result.usbProductId !== undefined && result.usbVendorId === undefined) throw new TypeError("usbProductId requires usbVendorId.");
      if (filter.bluetoothServiceClassId !== undefined) throw exception("NotSupportedError", "Bluetooth serial ports are not supported.");
      return result;
    });
  }
  class Serial extends EventTarget {
    constructor(key) { super(); if (key !== token) throw new TypeError("Illegal constructor"); serialSlots.set(this, { connect: null, disconnect: null }); }
    async getPorts() {
      if (!serialSlots.has(this)) throw new TypeError("Illegal invocation");
      const result = await rpc("serial.getPorts");
      if (!Array.isArray(result)) throw exception("OperationError", "Invalid serial port list.");
      return result.map(portFor);
    }
    async requestPort(options = {}) {
      if (!serialSlots.has(this)) throw new TypeError("Illegal invocation");
      if (!options || typeof options !== "object") throw new TypeError("SerialPortRequestOptions must be an object.");
      const args = { filters: filters(options.filters === undefined ? [] : options.filters) };
      if (options.allowedBluetoothServiceClassIds !== undefined && (!Array.isArray(options.allowedBluetoothServiceClassIds) || options.allowedBluetoothServiceClassIds.length))
        throw exception("NotSupportedError", "Bluetooth serial ports are not supported.");
      if (navigator.userActivation && !navigator.userActivation.isActive) throw exception("SecurityError", "requestPort requires a user gesture.");
      return portFor(await rpc("serial.requestPort", args));
    }
  }
  for (const [Class, map] of [[Serial, serialSlots], [SerialPort, slots]]) for (const type of ["connect", "disconnect"])
    Object.defineProperty(Class.prototype, `on${type}`, { configurable: true, enumerable: true,
      get() { if (!map.has(this)) throw new TypeError("Illegal invocation"); return map.get(this)[type]; },
      set(value) {
        const slot = map.get(this); if (!slot) throw new TypeError("Illegal invocation");
        if (slot[type]) this.removeEventListener(type, slot[type]);
        slot[type] = typeof value === "function" ? value : null;
        if (slot[type]) this.addEventListener(type, slot[type]);
      }
    });
  const serial = new Serial(token);
  function rejectPending(error, deviceId) {
    for (const [id, request] of pending) if (deviceId === undefined || request.deviceId === deviceId) {
      clearTimeout(request.timer); pending.delete(id); request.reject(error);
    }
  }
  function connectionEvent(type, port) {
    port.dispatchEvent(new SerialConnectionEvent(type, { port, bubbles: true }));
    serial.dispatchEvent(new SerialConnectionEvent(type, { port }));
  }
  function disconnect(port, error) {
    const slot = state(port), wasConnected = slot.connected;
    slot.connected = false; slot.opened = false;
    clearStreams(slot, error); rejectPending(error, slot.snapshot.id);
    if (wasConnected) connectionEvent("disconnect", port);
  }
  function terminate(error) {
    if (!active) return;
    active = false; rejectPending(error);
    for (const port of ports.values()) disconnect(port, error);
  }
  window.addEventListener("message", event => {
    if (event.source !== window || event.origin !== location.origin || !active) return;
    const message = event.data;
    if (!message || message.source !== "safari-webusb-extension") return;
    if (message.event) {
      if (message.event === "bridge.disconnect") { terminate(exception("NetworkError", "The device extension disconnected. Reload this page.")); return; }
      try {
        if (message.event === "serial.connect") connectionEvent("connect", portFor(message.device));
        const port = ports.get(message.deviceId);
        if (!port) return;
        const slot = state(port);
        if (message.event === "serial.disconnect") disconnect(port, exception("NetworkError", "The serial port disconnected."));
        if (message.event === "serial.error" && slot.opened) {
          const error = exception(message.error?.name || "NetworkError", message.error?.message || "The serial read failed.");
          if (["BreakError", "FramingError", "ParityError", "BufferOverrunError"].includes(error.name)) failRead(slot, error, false);
          else {
            // Fatal errors close the native descriptor but do not remove the
            // physical port or its grant. A later explicit open can recover.
            slot.opened = false; clearStreams(slot, error); rejectPending(error, slot.snapshot.id);
          }
        }
        const credit = slot.credit;
        if (message.event === "serial.data" && credit && !credit.delivered && slot.opened) {
          try { credit.controller.enqueue(decode(message.data, credit.length)); credit.delivered = true; finishCredit(slot, credit); }
          catch (error) { failRead(slot, error); }
        }
      } catch { /* Malformed unsolicited events cannot break pending RPCs. */ }
      return;
    }
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id); clearTimeout(request.timer);
    if (message.ok === true) request.resolve(message.result);
    else request.reject(exception(message.error?.name || "OperationError", message.error?.message || "The serial operation failed."));
  });
  window.addEventListener("pagehide", () => terminate(exception("AbortError", "The document was hidden or unloaded.")));
  for (const Class of [Serial, SerialPort, SerialConnectionEvent]) {
    Object.defineProperty(Class.prototype, Symbol.toStringTag, { value: Class.name, configurable: true });
    if (!(Class.name in window)) Object.defineProperty(window, Class.name, { value: Class, writable: true, configurable: true });
  }
  Object.defineProperty(navigator, "serial", { value: serial, configurable: true, enumerable: true });
})();

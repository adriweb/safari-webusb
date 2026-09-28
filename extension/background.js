/* No page-supplied origin, grant or native operation is trusted here. */
(function (root) {
  "use strict";
  const MAX_BYTES = 1024 * 1024;
  const DEVICE_OPS = new Set(["open", "close", "reset", "forget", "selectConfiguration", "claimInterface", "releaseInterface", "selectAlternateInterface", "clearHalt", "transferIn", "transferOut", "controlTransferIn", "controlTransferOut"]);
  const PERIPHERAL_OPS = new Set([
    ...["open", "close", "forget", "read", "cancelRead", "write", "drain", "abortWrite", "getSignals", "setSignals"].map(op => "serial." + op),
    ...["open", "close", "forget", "sendReport", "sendFeatureReport", "receiveFeatureReport"].map(op => "hid." + op)
  ]);
  const LIST_OPS = new Set(["getDevices", "serial.getPorts", "hid.getDevices"]);
  const isForget = op => op === "forget" || op.endsWith(".forget");
  const kindOf = op => op.startsWith("serial.") ? "serial" : op.startsWith("hid.") ? "hid" : "usb";
  const devicesFor = (session, kind) => kind === "usb" ? session.devices : session[kind];
  const nativeOp = (kind, op) => kind === "usb" ? op : kind + "." + op;
  const BLOCKED_CLASSES = new Set([1, 3, 8, 9, 11, 14, 16, 224]);
  const fail = (name, message) => Object.assign(new Error(message), {name});
  function trustedOrigin(sender) {
    if (!sender || !sender.tab || sender.frameId !== 0) throw fail("SecurityError", "USB is available only in a top-level page.");
    let url;
    try { url = new URL(sender.url); } catch { throw fail("SecurityError", "Invalid page URL."); }
    if (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname))) throw fail("SecurityError", "USB requires HTTPS or localhost.");
    return url.origin;
  }
  function validateFilters(options) {
    if (!options || !Array.isArray(options.filters) || options.filters.length > 64 || (options.exclusionFilters !== undefined && (!Array.isArray(options.exclusionFilters) || options.exclusionFilters.length > 64))) throw fail("TypeError", "requestDevice requires a filters array (at most 64 entries).");
    const validate = filters => filters.map(filter => {
      if (!filter || typeof filter !== "object" || Array.isArray(filter)) throw fail("TypeError", "Invalid USB device filter.");
      const copy = {};
      for (const [key, max] of [["vendorId", 65535], ["productId", 65535], ["classCode", 255], ["subclassCode", 255], ["protocolCode", 255]]) {
        if (filter[key] !== undefined) {
          if (!Number.isInteger(filter[key]) || filter[key] < 0 || filter[key] > max) throw fail("TypeError", `Invalid ${key}.`);
          copy[key] = filter[key];
        }
      }
      if (filter.serialNumber !== undefined) {
        if (typeof filter.serialNumber !== "string" || filter.serialNumber.length > 256) throw fail("TypeError", "Invalid serialNumber.");
        copy.serialNumber = filter.serialNumber;
      }
      if ((copy.productId !== undefined && copy.vendorId === undefined) || (copy.subclassCode !== undefined && copy.classCode === undefined) || (copy.protocolCode !== undefined && copy.subclassCode === undefined)) throw fail("TypeError", "USB filter dependencies are missing.");
      return copy;
    });
    return {filters: validate(options.filters), exclusionFilters: validate(options.exclusionFilters || [])};
  }
  function matches(device, filter) {
    for (const key of ["vendorId", "productId", "serialNumber"]) if (filter[key] !== undefined && filter[key] !== device[key]) return false;
    if (filter.classCode === undefined) return true;
    const classMatch = (c, s, p) => c === filter.classCode && (filter.subclassCode === undefined || s === filter.subclassCode) && (filter.protocolCode === undefined || p === filter.protocolCode);
    if (classMatch(device.deviceClass, device.deviceSubclass, device.deviceProtocol)) return true;
    return device.configurations.some(c => c.interfaces.some(i => i.alternates.some(a => classMatch(a.interfaceClass, a.interfaceSubclass, a.interfaceProtocol))));
  }
  function eligible(device, options) {
    // Do not offer devices that have no unprotected USB interface at all.
    if (BLOCKED_CLASSES.has(device.deviceClass) || !device.configurations.some(c => c.interfaces.some(i => i.alternates.some(a => !BLOCKED_CLASSES.has(a.interfaceClass))))) return false;
    return (!options.filters.length || options.filters.some(f => matches(device, f))) && !options.exclusionFilters.some(f => matches(device, f));
  }
  function validatePeripheralFilters(kind, options) {
    if (options === undefined && kind === "serial") options = {};
    if (!options || typeof options !== "object" || Array.isArray(options)) throw fail("TypeError", "Invalid device options.");
    const validate = (filters, required) => {
      if (filters === undefined && !required) return [];
      if (!Array.isArray(filters) || filters.length > 64) throw fail("TypeError", "Expected at most 64 device filters.");
      return filters.map(filter => {
        if (!filter || typeof filter !== "object" || Array.isArray(filter)) throw fail("TypeError", "Invalid device filter.");
        const copy = {}, fields = kind === "serial" ? ["usbVendorId", "usbProductId"] : ["vendorId", "productId", "usagePage", "usage"];
        for (const key of fields) if (filter[key] !== undefined) {
          if (!Number.isInteger(filter[key]) || filter[key] < 0 || filter[key] > 65535) throw fail("TypeError", `Invalid ${key}.`);
          copy[key] = filter[key];
        }
        const [vendor, product] = fields;
        if (copy[product] !== undefined && copy[vendor] === undefined || copy.usage !== undefined && copy.usagePage === undefined)
          throw fail("TypeError", "Device filter dependencies are missing.");
        if (filter.bluetoothServiceClassId !== undefined) throw fail("NotSupportedError", "Bluetooth service filters are not supported.");
        return copy;
      });
    };
    if (options.allowedBluetoothServiceClassIds?.length) throw fail("NotSupportedError", "Bluetooth serial services are not supported.");
    return {filters:validate(options.filters, kind === "hid"), exclusionFilters:validate(options.exclusionFilters, false)};
  }
  function peripheralEligible(kind, device, options) {
    const match = filter => {
      const fields = kind === "serial" ? ["usbVendorId", "usbProductId"] : ["vendorId", "productId"];
      if (fields.some(key => filter[key] !== undefined && filter[key] !== device[key])) return false;
      return filter.usagePage === undefined || (device.collections || []).some(c => c.usagePage === filter.usagePage && (filter.usage === undefined || c.usage === filter.usage));
    };
    return (!options.filters.length || options.filters.some(match)) && !options.exclusionFilters.some(match);
  }
  function validateRequest(message) {
    if (!message || typeof message.id !== "string" || message.id.length > 100 || typeof message.op !== "string") throw fail("TypeError", "Invalid USB request.");
    if (!["requestDevice", "getDevices", "serial.requestPort", "serial.getPorts", "hid.requestDevice", "hid.getDevices"].includes(message.op) && !DEVICE_OPS.has(message.op) && !PERIPHERAL_OPS.has(message.op)) throw fail("NotSupportedError", "Unsupported USB operation.");
    if (DEVICE_OPS.has(message.op) || PERIPHERAL_OPS.has(message.op)) {
      const args = message.args;
      if (!args || typeof args.deviceId !== "string" || args.deviceId.length > 100) throw fail("TypeError", "Invalid USB device.");
      if (args.data !== undefined && (typeof args.data !== "string" || args.data.length > Math.ceil(MAX_BYTES / 3) * 4)) throw fail("QuotaExceededError", "USB transfers are limited to 1 MiB.");
    }
  }
  // On macOS 27 / Safari 27, rapid native-message bursts fail after about 150
  // replies; 40 ms pacing is an empirical workaround, not a documented quota.
  // Bound and pace all callers together; a rejected native call is never replayed.
  function createNativeScheduler({timers = root, now = () => root.performance.now(), minimumGap = 40, maxPending = 128, admissionTimeout = 10000} = {}) {
    const queue = [];
    let active = false, lastStart = -Infinity, wakeup = null;
    function pump() {
      if (wakeup !== null) { timers.clearTimeout(wakeup); wakeup = null; }
      const time = now();
      while (queue.length && queue[0].deadline <= time) {
        queue.shift().reject(fail("TimeoutError", "Native USB queue is busy. The operation was not started."));
      }
      if (!queue.length) return;
      const gap = typeof minimumGap === "function" ? minimumGap() : minimumGap;
      if (active || time < lastStart + gap) {
        const next = active ? queue[0].deadline : Math.min(queue[0].deadline, lastStart + gap);
        wakeup = timers.setTimeout(pump, Math.max(0, next - time));
        return;
      }
      const entry = queue.shift();
      try { entry.validate(); }
      catch (error) { entry.reject(error); pump(); return; }
      active = true;
      lastStart = time;
      let pending;
      try { pending = entry.run(); } catch (error) { pending = Promise.reject(error); }
      Promise.resolve(pending).then(entry.resolve, entry.reject).finally(() => {
        active = false;
        pump();
      });
    }
    return {
      cancelPending(error, predicate = () => true) {
        if (wakeup !== null) { timers.clearTimeout(wakeup); wakeup = null; }
        for (let i = queue.length - 1; i >= 0; --i) if (predicate(queue[i].metadata)) queue.splice(i, 1)[0].reject(error);
        pump();
      },
      schedule(run, validate = () => {}, metadata) {
        if (queue.length + Number(active) >= maxPending) return Promise.reject(fail("QuotaExceededError", "Too many pending native USB requests."));
        return new Promise((resolve, reject) => {
          queue.push({run, validate, metadata, resolve, reject, deadline: now() + admissionTimeout});
          pump();
        });
      }
    };
  }
  function createController(browser, crypto, timers = root, options = {}) {
    const sessions = new Set();
    const choosers = new Map();
    let transportEpoch = 0;
    const transportFactory = options.transportFactory || (config => root.SafariWebUSBTransport.createTransport(config));
    const transport = transportFactory({browser, crypto, timers, onEvent(identifier, event) {
      const session = [...sessions].find(s => s.id === identifier);
      if (!session || session.closed || !event || typeof event.deviceId !== "string") return;
      if (event.event === "permissions.revoked") {
        if (!["usb", "serial", "hid"].includes(event.kind)) return;
        const devices = devicesFor(session, event.kind);
        ++session.permissionEpoch;
        if (!session.known[event.kind].has(event.deviceId)) return;
        session.known[event.kind].delete(event.deviceId);
        if (devices.delete(event.deviceId)) post(session, {event: nativeOp(event.kind, "disconnect"), deviceId: event.deviceId});
        return;
      }
      const kind = kindOf(event.event || "");
      if (!session.instance || kind === "usb") return;
      const devices = devicesFor(session, kind);
      if (!devices.has(event.deviceId)) return;
      if (event.data !== undefined && (typeof event.data !== "string" || event.data.length > Math.ceil(MAX_BYTES / 3) * 4)) return;
      if (event.event === kind + ".disconnect") devices.delete(event.deviceId);
      post(session, event);
    }, onDisconnect(error) {
      ++transportEpoch;
      nativeScheduler.cancelPending(error);
      for (const session of sessions) invalidate(session);
      for (const token of [...choosers.keys()]) finishChooser(token, null, error);
    }});
    const nativeScheduler = options.nativeScheduler || createNativeScheduler({timers, minimumGap: () => transport.minimumGap});
    const chooserURL = browser.runtime.getURL("chooser.html");
    const permissionsURL = browser.runtime.getURL("permissions.html");
    const managementSession = crypto.randomUUID();
    // Safari's getURL() preserves UUID casing while WebKit's authenticated
    // WebSocket Origin lowercases the host. Use the same canonical origin.
    const managementOrigin = new URL(browser.runtime.getURL(""));
    if (managementOrigin.protocol !== "safari-web-extension:" || !managementOrigin.hostname || managementOrigin.port || managementOrigin.username || managementOrigin.password)
      throw fail("SecurityError", "Invalid extension origin.");
    const extensionOrigin = `${managementOrigin.protocol}//${managementOrigin.hostname.toLowerCase()}`;
    const post = (session, message) => { if (!session.closed) { try { session.port.postMessage(message); } catch {} } };
    async function native(session, op, args = {}, expected = session.instance) {
      if (op === "serial.write" && session.aborting.has(args.deviceId)) throw fail("AbortError", "Serial output is being canceled.");
      const queuedInstance = session.instance, sessionId = session.id, origin = session.origin, privateBrowsing = session.privateBrowsing, queuedEpoch = transportEpoch, permissionEpoch = session.permissionEpoch;
      const run = () => transport.send({version: 1, op, session: sessionId, origin, privateBrowsing, ...(expected ? {instance: expected} : {}), args});
      const validate = () => {
        if (queuedEpoch !== transportEpoch) throw fail("InvalidStateError", "The USB transport disconnected before the operation started.");
        // closeSession must still release handles after its page has gone away.
        if (op !== "closeSession") {
          if (session.closed) throw fail("AbortError", "The requesting page closed before the USB operation started.");
          if (session.instance !== queuedInstance && !(queuedInstance === null && (LIST_OPS.has(op) || session.instance === expected))) throw fail("InvalidStateError", "The USB document session changed before the operation started.");
          if ((DEVICE_OPS.has(op) || PERIPHERAL_OPS.has(op)) && !(isForget(op) ? session.known[kindOf(op)] : devicesFor(session, kindOf(op))).has(args.deviceId)) throw fail("NotAllowedError", "This page has not been granted that USB device.");
        }
        if (session.id !== sessionId || session.origin !== origin || session.privateBrowsing !== privateBrowsing) throw fail("SecurityError", "The USB document session identity changed before the operation started.");
        if (op === "serial.write" && session.aborting.has(args.deviceId)) throw fail("AbortError", "Serial output is being canceled.");
      };
      let response;
      if (op === "serial.abortWrite") {
        validate();
        if (session.aborting.has(args.deviceId)) throw fail("InvalidStateError", "Serial output is already being canceled.");
        session.aborting.add(args.deviceId);
        try {
          nativeScheduler.cancelPending(fail("AbortError", "Serial output was canceled before it started."),
            item => item?.sessionId === sessionId && item.op === "serial.write" && item.deviceId === args.deviceId);
          // A blocked write must not prevent its cancellation from reaching the
          // native backend. The socket enforces the same narrow exception.
          response = await run();
        } finally { session.aborting.delete(args.deviceId); }
      } else response = await nativeScheduler.schedule(run, validate, {sessionId, op, deviceId: args.deviceId});
      if (queuedEpoch !== transportEpoch) throw fail("InvalidStateError", "The USB transport disconnected. Choose the device again.");
      if (!response || typeof response.instance !== "string" || typeof response.ok !== "boolean") throw fail("NetworkError", "Invalid response from the native USB bridge.");
      if (expected && expected !== response.instance || LIST_OPS.has(op) && session.instance && session.instance !== response.instance) {
        invalidate(session);
        throw fail("InvalidStateError", "The native USB process restarted. Choose the device again.");
      }
      if (session.permissionEpoch !== permissionEpoch && !isForget(op) && op !== "closeSession") throw fail("NotAllowedError", "Device permission changed while the operation was in progress.");
      if (!response.ok) throw fail(response.error?.name || "NetworkError", response.error?.message || "USB request failed.");
      return response;
    }
    function invalidate(session) {
      for (const deviceId of session.devices.keys()) post(session, {event: "disconnect", deviceId});
      session.devices.clear();
      for (const kind of ["serial", "hid"]) {
        for (const deviceId of devicesFor(session, kind).keys()) post(session, {event: kind + ".disconnect", deviceId});
        devicesFor(session, kind).clear();
      }
      for (const known of Object.values(session.known)) known.clear();
      ++session.permissionEpoch;
      session.instance = null;
    }
    async function finishChooser(token, deviceId, error) {
      const choice = choosers.get(token);
      if (!choice) return;
      choosers.delete(token);
      timers.clearTimeout(choice.timer);
      if (choice.windowId !== undefined) browser.windows.remove(choice.windowId).catch(() => {});
      if (error) {
        if (choice.kind === "hid" && deviceId === null && error.name === "NotFoundError") choice.resolve([]);
        else choice.reject(error);
        return;
      }
      const device = choice.devices.find(d => d.id === deviceId);
      if (!device || choice.session.closed) { choice.reject(fail("NotFoundError", "No device selected.")); return; }
      try {
        // The chooser can outlive an idle native session. Refresh only after an
        // explicit selection, renewing the lease and rejecting stale attachments.
        const refreshed = await native(choice.session, nativeOp(choice.kind, "enumerate"), {}, choice.instance);
        if (!refreshed.result.some(d => d.id === deviceId && (choice.kind === "usb"
            ? eligible(d, choice.filters) : peripheralEligible(choice.kind, d, choice.filters))))
          throw fail("NotFoundError", "The selected device is no longer available. Choose it again.");
        const reply = await native(choice.session, nativeOp(choice.kind, "grant"), {deviceId}, choice.instance);
        // Navigation can close a port while the native grant is in flight.
        if (choice.session.closed) {
          await native(choice.session, "closeSession", {}, choice.instance).catch(() => {});
          choice.reject(fail("AbortError", "The requesting page closed."));
          return;
        }
        choice.session.instance = reply.instance;
        devicesFor(choice.session, choice.kind).set(deviceId, reply.result);
        choice.session.known[choice.kind].add(deviceId);
        choice.resolve(choice.kind === "hid" ? [reply.result] : reply.result);
      } catch (error) { choice.reject(error); }
    }
    async function choose(session, args, kind = "usb") {
      const filters = kind === "usb" ? validateFilters(args) : validatePeripheralFilters(kind, args);
      if (session.choosing) throw fail("InvalidStateError", "A USB device chooser is already open for this page.");
      session.choosing = true;
      try {
      const reply = await native(session, nativeOp(kind, "enumerate"), {}, null);
      if (session.closed) throw fail("AbortError", "The requesting page closed.");
      if (session.instance && session.instance !== reply.instance) invalidate(session);
      const devices = reply.result.filter(device => kind === "usb" ? eligible(device, filters) : peripheralEligible(kind, device, filters));
      const token = crypto.randomUUID();
      return await new Promise((resolve, reject) => {
        const choice = {session, kind, filters, devices, instance: reply.instance, resolve, reject};
        choosers.set(token, choice);
        choice.timer = timers.setTimeout(() => finishChooser(token, null, fail("NotFoundError", "Device selection timed out.")), 120000);
        browser.windows.create({url: `${chooserURL}?token=${encodeURIComponent(token)}`, type: "popup", width: 560, height: 480}).then(window => {
          if (choosers.has(token)) choice.windowId = window.id;
          else browser.windows.remove(window.id).catch(() => {});
        }, error => finishChooser(token, null, fail("NotSupportedError", `Could not open the USB chooser: ${error.message}`)));
      });
      } finally { session.choosing = false; }
    }
    async function request(session, message) {
      validateRequest(message);
      if (["requestDevice", "serial.requestPort", "hid.requestDevice"].includes(message.op)) return choose(session, message.args, kindOf(message.op));
      const kind = kindOf(message.op), devices = devicesFor(session, kind);
      if (LIST_OPS.has(message.op)) {
        const reply = await native(session, message.op);
        if (session.closed) {
          await native(session, "closeSession", {}, reply.instance).catch(() => {});
          throw fail("AbortError", "The requesting page closed.");
        }
        if (!Array.isArray(reply.result)) throw fail("NetworkError", "Invalid saved-device list from the native bridge.");
        session.instance = reply.instance;
        const live = new Set(reply.result.map(d => d.id));
        for (const id of devices.keys()) if (!live.has(id)) { devices.delete(id); post(session, {event: nativeOp(kind, "disconnect"), deviceId: id}); }
        for (const device of reply.result) { devices.set(device.id, device); session.known[kind].add(device.id); }
        return reply.result;
      }
      const permitted = isForget(message.op) ? session.known[kind] : devices;
      if (!session.instance || !permitted.has(message.args.deviceId)) throw fail("NotAllowedError", "This page has not been granted that device.");
      const {result} = await native(session, message.op, message.args);
      if (isForget(message.op)) { devices.delete(message.args.deviceId); session.known[kind].delete(message.args.deviceId); }
      else if (result?.id) devices.set(result.id, result);
      return result;
    }
    browser.runtime.onConnect.addListener(port => {
      if (port.name !== "safari-webusb-v1") { port.disconnect(); return; }
      let origin;
      try { origin = trustedOrigin(port.sender); } catch { port.disconnect(); return; }
      const session = {port, origin, privateBrowsing: port.sender.tab.incognito !== false, permissionEpoch: 0, known: {usb: new Set(), serial: new Set(), hid: new Set()}, id: crypto.randomUUID(), instance: null, devices: new Map(), serial: new Map(), hid: new Map(), aborting: new Set(), closed: false, pending: new Set(), polling: false};
      sessions.add(session);
      port.onMessage.addListener(async message => {
        if (session.closed || !message || typeof message.id !== "string" || session.pending.has(message.id)) return;
        if (session.pending.size >= 32) { post(session, {id: message.id, ok: false, error: {name: "QuotaExceededError", message: "Too many pending USB requests."}}); return; }
        session.pending.add(message.id);
        try { post(session, {id: message.id, ok: true, result: await request(session, message)}); }
        catch (error) { post(session, {id: message.id, ok: false, error: {name: error.name, message: error.message}}); }
        finally { session.pending.delete(message.id); }
      });
      port.onDisconnect.addListener(() => {
        session.closed = true;
        sessions.delete(session);
        for (const [token, choice] of choosers) if (choice.session === session) finishChooser(token, null, fail("AbortError", "The requesting page closed."));
        if (session.instance) native(session, "closeSession").catch(() => {});
      });
    });
    browser.runtime.onMessage.addListener((message, sender) => {
      // Web pages cannot complete a chooser, even if they guess its token.
      if (!sender?.url || sender.id !== browser.runtime.id) return undefined;
      let url;
      try { url = new URL(sender.url); } catch { return undefined; }
      if (url.href === permissionsURL) {
        const privateBrowsing = sender.tab ? sender.tab.incognito !== false : browser.extension?.inIncognitoContext !== false;
        if (privateBrowsing) return Promise.resolve({error: "Saved device permissions are unavailable in private browsing."});
        if (!["permissions.list", "permissions.revoke", "permissions.clear"].includes(message?.op)) return undefined;
        if (message.op === "permissions.revoke" && (typeof message.id !== "string" || !message.id.length || message.id.length > 256))
          return Promise.resolve({error: "Invalid device permission."});
        const args = message.op === "permissions.revoke" ? {id: message.id} : {};
        return nativeScheduler.schedule(() => transport.send({version: 1, op: message.op, extensionManagement: true,
          session: managementSession, origin: extensionOrigin, privateBrowsing: false, args}))
          .then(response => {
            if (!response || response.ok !== true) throw fail(response?.error?.name || "NetworkError", response?.error?.message || "Could not update device permissions.");
            return {result: response.result};
          }).catch(error => ({error: error.message}));
      }
      if (url.href.split("?")[0] !== chooserURL) return undefined;
      const token = url.searchParams.get("token");
      const choice = choosers.get(token);
      if (!choice) return Promise.resolve({error: "This chooser has expired."});
      if (message?.op === "chooserInfo") return Promise.resolve({origin: choice.session.origin, kind: choice.kind, privateBrowsing: choice.session.privateBrowsing, remembersPermissions: transport.supportsRememberedPermissions !== false, devices: choice.devices});
      if (message?.op === "chooserSelect") {
        return finishChooser(token, message.deviceId).then(() => ({ok: true}));
      }
      if (message?.op === "chooserCancel") return finishChooser(token, null, fail("NotFoundError", "No device selected.")).then(() => ({ok: true}));
      return undefined;
    });
    browser.windows.onRemoved.addListener(windowId => {
      for (const [token, choice] of choosers) if (choice.windowId === windowId) finishChooser(token, null, fail("NotFoundError", "No device selected."));
    });
    // Keep document grants, including detached IDs usable by forget(), alive.
    // No device identities are broadcast to unrelated pages.
    const heartbeat = timers.setInterval(async () => {
      for (const session of sessions) {
        if (!session.instance || !Object.values(session.known).some(ids => ids.size) || session.polling) continue;
        session.polling = true;
        try {
          if (!(session.devices.size + session.serial.size + session.hid.size)) await native(session, "heartbeat");
          else for (const op of LIST_OPS) if (devicesFor(session, kindOf(op)).size) await request(session, {id: "heartbeat", op});
        }
        catch { invalidate(session); }
        finally { session.polling = false; }
      }
    }, 10000);
    return {request, sessions, choosers, stop() { timers.clearInterval(heartbeat); transport.close(); }};
  }
  if (typeof module === "object" && module.exports) module.exports = {validatePeripheralFilters, peripheralEligible, trustedOrigin, validateFilters, matches, eligible, validateRequest, createNativeScheduler, createController};
  else createController(root.browser, root.crypto);
})(globalThis);

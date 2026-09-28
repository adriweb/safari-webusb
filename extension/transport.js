/* Privileged background transport. Bootstrap credentials never reach pages. */
(function (root) {
  "use strict";
  const APP = "org.webtilp.safariwebusb";
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const fail = (name, message) => Object.assign(new Error(message), {name});
  const launch = "Launch Safari WebUSB, then choose the device again.";
  const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
  function validError(error) {
    return object(error) && typeof error.name === "string" && error.name.length > 0 && error.name.length <= 100
      && typeof error.message === "string" && error.message.length <= 4096;
  }
  function validResponse(response) {
    return object(response) && typeof response.ok === "boolean" && typeof response.instance === "string"
      && response.instance.length > 0 && response.instance.length <= 256
      && (response.ok || validError(response.error));
  }
  function endpoint(value) {
    const match = typeof value === "string" && /^ws:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})\/$/.exec(value);
    if (!match || Number(match[1]) > 65535) throw fail("SecurityError", "The native USB bridge returned an invalid loopback endpoint.");
    return value;
  }
  function decode(value, length) {
    if (typeof value !== "string" || value.length !== Math.ceil(length / 3) * 4) throw fail("SecurityError", "Invalid USB authentication data.");
    let binary;
    try { binary = root.atob(value); } catch { throw fail("SecurityError", "Invalid USB authentication data."); }
    if (binary.length !== length || root.btoa(binary) !== value) throw fail("SecurityError", "Invalid USB authentication data.");
    return Uint8Array.from(binary, c => c.charCodeAt(0));
  }
  function encode(value) { return root.btoa(String.fromCharCode(...new Uint8Array(value))); }

  function createTransport({browser = root.browser, crypto = root.crypto, WebSocket = root.WebSocket,
      timers = root, origin, onDisconnect = () => {}, onEvent = () => {}, bootstrapTimeout = 10000,
      handshakeTimeout = 10000, requestTimeout = 15000, maxPending = 128} = {}) {
    let current = null, blocked = false, stopped = false, inFlight = 0, usedSocket = false;
    const bytes = text => new TextEncoder().encode(text);
    function lost(connection, error) {
      if (connection.closed) return;
      connection.closed = true;
      timers.clearTimeout(connection.timer);
      for (const item of connection.pending.values()) {
        timers.clearTimeout(item.timer);
        item.reject(error);
      }
      connection.pending.clear();
      connection.reject(error);
      if (current === connection) current = null;
      blocked = true;
      try { connection.socket?.close(); } catch {}
      try { onDisconnect(error); } catch {}
    }
    function sendFrame(connection, value) {
      if (connection.closed) throw fail("NetworkError", `Safari WebUSB disconnected. ${launch}`);
      connection.socket.send(JSON.stringify(value));
    }
    function finishResponse(connection, id, response) {
      const item = connection.pending.get(id);
      if (!item || !validResponse(response)) throw fail("NetworkError", "Invalid response from the native USB bridge.");
      connection.pending.delete(id);
      timers.clearTimeout(item.timer);
      item.resolve(response);
    }
    async function authenticate(connection, message) {
      const signature = decode(message.proof, 32);
      const verified = await crypto.subtle.verify("HMAC", connection.key, signature,
        bytes(`server:${connection.challenge}:${message.challenge}`));
      if (!verified) throw fail("SecurityError", `Cannot authenticate the Safari WebUSB app. ${launch}`);
      const proof = encode(await crypto.subtle.sign("HMAC", connection.key, bytes(`client:${message.challenge}`)));
      if (connection.closed) return;
      connection.key = null;
      connection.state = "readyWait";
      sendFrame(connection, {type: "authenticate", proof});
    }
    function receive(connection, data) {
      if (connection.closed) return;
      try {
        if (typeof data !== "string" || data.length > 2 * 1024 * 1024) throw fail("NetworkError", "Invalid native USB WebSocket message.");
        let message;
        try { message = JSON.parse(data); } catch { throw fail("NetworkError", "Invalid native USB WebSocket JSON."); }
        if (!object(message)) throw fail("NetworkError", "Invalid native USB WebSocket message.");
        if (message.type === "error") {
          if (!validError(message.error)) throw fail("NetworkError", "Invalid native USB transport error.");
          const error = fail(message.error.name, message.error.message);
          if (connection.state !== "ready" || typeof message.id !== "string") throw error;
          const item = connection.pending.get(message.id);
          if (!item) throw fail("NetworkError", "Unexpected native USB transport error.");
          connection.pending.delete(message.id);
          timers.clearTimeout(item.timer);
          item.reject(error);
        } else if (connection.state === "challenge" && message.type === "challenge") {
          if (typeof message.challenge !== "string" || !UUID.test(message.challenge)) throw fail("SecurityError", "Invalid USB authentication challenge.");
          connection.state = "verifying";
          authenticate(connection, message).catch(error => lost(connection, error));
        } else if (connection.state === "readyWait" && message.type === "ready") {
          connection.state = "ready";
          timers.clearTimeout(connection.timer);
          connection.resolve(connection);
        } else if (connection.state === "ready" && message.type === "event") {
          if (typeof message.session !== "string" || message.session.length > 128 || !object(message.event)
              || (!/^(serial|hid)\.(data|error|inputreport|connect|disconnect)$/.test(message.event.event)
                && !(message.event.event === "permissions.revoked" && ["usb", "serial", "hid"].includes(message.event.kind)))
              || typeof message.event.deviceId !== "string" || message.event.deviceId.length > 128)
            throw fail("NetworkError", "Invalid native device event.");
          onEvent(message.session, message.event);
        } else if (connection.state === "ready" && message.type === "response" && typeof message.id === "string") {
          finishResponse(connection, message.id, message.response);
        } else throw fail("NetworkError", "Unexpected native USB WebSocket message.");
      } catch (error) { lost(connection, error); }
    }
    async function bootstrap(connection) {
      let reply;
      try {
        const extensionOrigin = origin ?? new URL(browser.runtime.getURL("")).origin;
        if (!extensionOrigin || extensionOrigin === "null") throw new Error("Extension origin unavailable");
        reply = await browser.runtime.sendNativeMessage(APP, {version: 1, op: "transportBootstrap", args: {origin: extensionOrigin}});
      } catch { throw fail("NetworkError", `Cannot contact the Safari WebUSB app. ${launch}`); }
      if (connection.closed) return;
      if (object(reply) && reply.ok === false && validError(reply.error) && reply.error.name === "NotSupportedError" && !usedSocket) {
        // Only an explicit native response for unsigned/ad-hoc installations
        // permits legacy messaging. Socket errors never silently downgrade.
        connection.legacy = true;
        connection.state = "ready";
        timers.clearTimeout(connection.timer);
        connection.resolve(connection);
        return;
      }
      if (!object(reply) || reply.ok !== true) throw fail("NetworkError", `Safari WebUSB persistent transport is unavailable. ${launch}`);
      const url = endpoint(reply.url);
      if (typeof reply.token !== "string" || reply.token.length < 16 || reply.token.length > 4096) throw fail("SecurityError", "Invalid USB authentication token.");
      const token = reply.token;
      const keyBytes = decode(reply.key, 32);
      reply = null;
      try { connection.key = await crypto.subtle.importKey("raw", keyBytes, {name: "HMAC", hash: "SHA-256"}, false, ["sign", "verify"]); }
      finally { keyBytes.fill(0); }
      if (connection.closed) return;
      timers.clearTimeout(connection.timer);
      connection.timer = timers.setTimeout(() => lost(connection, fail("TimeoutError", `Safari WebUSB authentication timed out. ${launch}`)), handshakeTimeout);
      connection.challenge = crypto.randomUUID();
      const socket = connection.socket = new WebSocket(url);
      connection.state = "opening";
      socket.onopen = () => {
        if (connection.closed) return;
        connection.state = "challenge";
        try { sendFrame(connection, {type: "hello", token, challenge: connection.challenge}); }
        catch { lost(connection, fail("NetworkError", `Safari WebUSB connection failed. ${launch}`)); }
      };
      socket.onmessage = event => receive(connection, event.data);
      socket.onerror = () => lost(connection, fail("NetworkError", `Cannot connect to Safari WebUSB. ${launch}`));
      socket.onclose = () => lost(connection, fail("NetworkError", `Safari WebUSB disconnected. ${launch}`));
    }
    function connect(message) {
      if (stopped) return Promise.reject(fail("AbortError", "Safari WebUSB transport was stopped."));
      if (current) return current.promise;
      if (blocked && !["enumerate", "serial.enumerate", "hid.enumerate", "getDevices", "serial.getPorts", "hid.getDevices", "permissions.list"].includes(message.op)) return Promise.reject(fail("InvalidStateError", `The USB transport disconnected. ${launch}`));
      blocked = false;
      const connection = {pending: new Map(), closed: false, legacy: false, state: "bootstrap"};
      connection.promise = new Promise((resolve, reject) => { connection.resolve = resolve; connection.reject = reject; });
      current = connection;
      connection.timer = timers.setTimeout(() => lost(connection, fail("TimeoutError", `Safari WebUSB startup timed out. ${launch}`)), bootstrapTimeout);
      bootstrap(connection).catch(error => lost(connection, error));
      return connection.promise;
    }
    return {
      get minimumGap() { return current?.legacy ? 40 : 0; },
      get supportsRememberedPermissions() { return current?.state === "ready" && !current.legacy; },
      async send(message) {
        if (!object(message)) throw fail("TypeError", "Invalid native USB request.");
        if (inFlight >= maxPending) throw fail("QuotaExceededError", "Too many pending USB transport requests.");
        ++inFlight;
        try {
          const connection = await connect(message);
          if (connection.legacy && /^(serial|hid|permissions)\./.test(message.op)) throw fail("NotSupportedError", "WebSerial, WebHID and saved permission settings require the signed Safari WebUSB app and its persistent connection. Launch the app, then reload this page.");
          if (connection.closed) throw fail("NetworkError", `Safari WebUSB disconnected. ${launch}`);
          return await new Promise((resolve, reject) => {
            const id = crypto.randomUUID();
            const timer = timers.setTimeout(() => lost(connection, fail("TimeoutError", `Safari WebUSB did not respond. The operation was not retried. ${launch}`)), requestTimeout);
            connection.pending.set(id, {resolve, reject, timer});
            if (connection.legacy) {
              Promise.resolve().then(() => browser.runtime.sendNativeMessage(APP, message)).then(response => {
                if (!connection.closed) {
                  try { finishResponse(connection, id, response); }
                  catch (error) { lost(connection, error); }
                }
              }, () => lost(connection, fail("NetworkError", `Safari WebUSB native messaging failed. ${launch}`)));
            } else {
              try {
                usedSocket = true;
                sendFrame(connection, {type: "request", id, message});
              } catch { lost(connection, fail("NetworkError", `Safari WebUSB connection failed. The operation was not retried. ${launch}`)); }
            }
          });
        } finally { --inFlight; }
      },
      close() {
        stopped = true;
        if (current) lost(current, fail("AbortError", "Safari WebUSB transport was stopped."));
      }
    };
  }
  const api = {createTransport};
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.SafariWebUSBTransport = Object.freeze(api);
})(globalThis);

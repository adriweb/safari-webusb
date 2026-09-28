/* The isolated world owns the extension port and observes trusted gestures. */
(() => {
  "use strict";
  if (window.top !== window || !window.isSecureContext) return;
  const origin = location.origin;
  const pending = new Map();
  const chooserOps = new Set(["requestDevice", "serial.requestPort", "hid.requestDevice"]);
  let lastGesture = -Infinity;
  let disconnected = false;
  let port;
  try { port = browser.runtime.connect({name: "safari-webusb-v1"}); }
  catch { disconnected = true; }
  for (const name of ["click", "keydown", "touchend"]) {
    window.addEventListener(name, event => {
      if (!disconnected && event.isTrusted && (name !== "keydown" || !event.repeat)) lastGesture = performance.now();
    }, true);
  }
  const respond = data => window.postMessage({...data, source: "safari-webusb-extension"}, origin);
  function closeBridge(message) {
    if (disconnected) return;
    disconnected = true;
    lastGesture = -Infinity;
    for (const [id, timer] of pending) {
      clearTimeout(timer);
      respond({id, ok: false, error: {name: "InvalidStateError", message}});
    }
    pending.clear();
    respond({event: "bridge.disconnect"});
  }
  window.addEventListener("message", event => {
    if (event.source !== window || event.origin !== origin) return;
    const message = event.data;
    if (!message || message.source !== "safari-webusb-page" || typeof message.id !== "string" || message.id.length > 100) return;
    if (pending.has(message.id)) return;
    if (disconnected) {
      respond({id: message.id, ok: false, error: {name: "InvalidStateError", message: "The Safari WebUSB bridge disconnected. Reload this page."}});
      return;
    }
    if (pending.size >= 32) {
      respond({id: message.id, ok: false, error: {name: "QuotaExceededError", message: "Too many USB requests are pending."}});
      return;
    }
    if (chooserOps.has(message.op)) {
      if (performance.now() - lastGesture > 1000) {
        respond({id: message.id, ok: false, error: {name: "SecurityError", message: "Choose a device from a click or key press."}});
        return;
      }
      lastGesture = -Infinity;
    }
    pending.set(message.id, setTimeout(() => {
      pending.delete(message.id);
      respond({id: message.id, ok: false, error: {name: "TimeoutError", message: "The Safari WebUSB extension did not respond."}});
    }, chooserOps.has(message.op) ? 130000 : 20000));
    try { port.postMessage({id: message.id, op: message.op, args: message.args}); }
    catch {
      closeBridge("The Safari WebUSB bridge disconnected. Reload this page.");
      try { port.disconnect(); } catch {}
    }
  });
  if (port) {
    port.onMessage.addListener(message => {
      if (disconnected || !message || typeof message !== "object") return;
      if (message.event === "connect" || message.event === "disconnect" || /^(serial|hid)\.(data|error|inputreport|connect|disconnect)$/.test(message.event)) { respond(message); return; }
      if (!pending.has(message.id)) return;
      clearTimeout(pending.get(message.id));
      pending.delete(message.id);
      respond(message);
    });
    port.onDisconnect.addListener(() => closeBridge("The Safari WebUSB extension stopped. Reload this page."));
  }
  window.addEventListener("pagehide", () => {
    // Calling disconnect() does not fire onDisconnect at the calling end.
    closeBridge("The requesting page closed. Reload this page to reconnect Safari WebUSB.");
    try { port?.disconnect(); } catch {}
  }, {once: true});
})();

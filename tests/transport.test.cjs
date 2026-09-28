"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {webcrypto, createHmac, randomUUID} = require("node:crypto");
const {createTransport} = require("../extension/transport.js");
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return {promise, resolve, reject}; };
class Clock {
  now = 0; next = 0; pending = new Map();
  setTimeout(fn, delay) { const id = ++this.next; this.pending.set(id, {fn, at: this.now + delay}); return id; }
  clearTimeout(id) { this.pending.delete(id); }
  async advance(ms) {
    const end = this.now + ms;
    await tick();
    for (;;) {
      const next = [...this.pending].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      this.now = next[1].at; this.pending.delete(next[0]); next[1].fn(); await tick();
    }
    this.now = end; await tick();
  }
}
const key = Buffer.alloc(32, 0x39);
const token = "01234567-89ab-cdef-0123-456789abcdef";
const origin = "safari-web-extension://12345678-1234-1234-1234-123456789abc";
const request = op => ({version: 1, op, session: "document-session", origin: "https://example.org", args: {}});
const success = {ok: true, instance: "native-epoch", result: []};
const proof = value => createHmac("sha256", key).update(value).digest("base64");
function harness(options = {}) {
  const h = {native: [], sockets: [], frames: [], disconnected: [], clock: new Clock(), respond: true,
    bootstrap: {ok: true, url: "ws://127.0.0.1:52123/", token, key: key.toString("base64")}, ...options};
  class Socket {
    constructor(url) { this.url = url; this.closed = false; this.challenge = randomUUID(); h.sockets.push(this); queueMicrotask(() => { if (!this.closed) this.onopen?.(); }); }
    receive(message) { this.onmessage?.({data: typeof message === "string" ? message : JSON.stringify(message)}); }
    send(text) {
      if (this.closed) throw new Error("closed");
      const message = JSON.parse(text); h.frames.push(message);
      if (message.type === "hello") {
        if (h.onHello) { h.onHello(this, message); return; }
        this.receive({type: "challenge", challenge: this.challenge, proof: proof(`server:${message.challenge}:${this.challenge}`)});
      } else if (message.type === "authenticate") {
        assert.equal(message.proof, proof(`client:${this.challenge}`));
        if (h.onAuthenticate) h.onAuthenticate(this, message);
        else this.receive({type: "ready"});
      } else if (message.type === "request" && h.respond) {
        queueMicrotask(() => this.receive({type: "response", id: message.id, response: success}));
      }
    }
    close() { if (this.closed) return; this.closed = true; queueMicrotask(() => this.onclose?.()); }
  }
  h.browser = {runtime: {getURL: path => `${origin}/${path}`, async sendNativeMessage(app, message) {
    assert.equal(app, "org.webtilp.safariwebusb");
    h.native.push(message);
    return message.op === "transportBootstrap" ? (typeof h.bootstrap === "function" ? h.bootstrap() : h.bootstrap) : success;
  }}};
  h.transport = createTransport({browser: h.browser, crypto: webcrypto, WebSocket: Socket, timers: h.clock, origin,
    bootstrapTimeout: 100, handshakeTimeout: 100, requestTimeout: 100, maxPending: h.maxPending ?? 128,
    onEvent: (session, event) => (h.events ||= []).push({session, event}),
    onDisconnect: error => h.disconnected.push(error)});
  h.until = async predicate => {
    for (let i = 0; i < 1000 && !predicate(); ++i) await tick();
    assert.ok(predicate(), "condition settled");
  };
  h.requests = () => h.frames.filter(f => f.type === "request");
  return h;
}
test("one bootstrap mutually authenticates a persistent socket and keeps credentials privileged", async () => {
  const h = harness();
  assert.deepEqual(await h.transport.send(request("enumerate")), success);
  assert.deepEqual(await h.transport.send(request("transferIn")), success);
  assert.equal(h.native.length, 1); assert.equal(h.sockets.length, 1); assert.equal(h.transport.minimumGap, 0);
  assert.equal(h.transport.supportsRememberedPermissions,true);
  assert.deepEqual(h.native[0], {version: 1, op: "transportBootstrap", args: {origin}});
  assert.deepEqual(h.frames.map(f => f.type), ["hello", "authenticate", "request", "request"]);
  assert.equal(h.frames[0].token, token);
  assert.notEqual(h.requests()[0].id, h.requests()[1].id);
  assert.deepEqual(h.requests()[1].message, request("transferIn"));
  assert.ok(!JSON.stringify(h.frames).includes(key.toString("base64")));
  assert.ok(!JSON.stringify(h.requests()).includes(token));
  assert.equal(h.clock.pending.size, 0);
  h.transport.close();
});
test("spoofed or replayed server proofs receive no client proof or USB request", async () => {
  for (const badProof of [Buffer.alloc(32).toString("base64"), proof("server:another-client:another-server"), "bad"]) {
    const h = harness({onHello(socket) { socket.receive({type: "challenge", challenge: socket.challenge, proof: badProof}); }});
    await assert.rejects(h.transport.send(request("enumerate")), {name: "SecurityError"});
    assert.deepEqual(h.frames.map(f => f.type), ["hello"]);
    assert.equal(h.disconnected.length, 1); assert.equal(h.native.length, 1);
  }
});
test("strict loopback endpoint rejects alternate hosts, credentials, paths and invalid ports", async () => {
  for (const url of ["ws://localhost:52123/", "wss://127.0.0.1:52123/", "ws://127.0.0.2:52123/", "ws://127.1:52123/",
    "ws://127.0.0.1:52123/path", "ws://127.0.0.1:52123/?token=x", "ws://127.0.0.1:52123/#x",
    "ws://user@127.0.0.1:52123/", "ws://127.0.0.1:0/", "ws://127.0.0.1:65536/", "ws://127.0.0.1:052123/"]) {
    const h = harness(); h.bootstrap.url = url;
    await assert.rejects(h.transport.send(request("enumerate")), {name: "SecurityError"});
    assert.equal(h.sockets.length, 0); assert.equal(h.native.length, 1);
  }
});
test("only explicit bootstrap NotSupportedError enables legacy 40 ms mode", async () => {
  const h = harness({bootstrap: {ok: false, error: {name: "NotSupportedError", message: "No signed app group"}}});
  assert.deepEqual(await h.transport.send(request("enumerate")), success);
  assert.equal(h.transport.minimumGap, 40);
  assert.equal(h.transport.supportsRememberedPermissions,false); assert.equal(h.sockets.length, 0);
  assert.deepEqual(h.native.map(m => m.op), ["transportBootstrap", "enumerate"]);
  await h.transport.send(request("open"));
  assert.deepEqual(h.native.map(m => m.op), ["transportBootstrap", "enumerate", "open"]);
  h.transport.close();
  for (const bootstrap of [null, {}, {ok: false, error: {name: "NotSupportedError"}}, {ok: false, error: {name: "NetworkError", message: "App missing"}},
    () => Promise.reject(Object.assign(new Error("API absent"), {name: "NotSupportedError"}))]) {
    const h = harness({bootstrap});
    await assert.rejects(h.transport.send(request("enumerate")), error => error.name === "NetworkError" && error.message.includes("Launch Safari WebUSB"));
    assert.equal(h.sockets.length, 0); assert.equal(h.native.length, 1);
  }
});
test("invalid bootstrap authentication fields never open a socket", async () => {
  for (const fields of [{key: ""}, {key: Buffer.alloc(16).toString("base64")}, {key: "!".repeat(44)}, {token: "short"}, {token: {}}]) {
    const h = harness(); Object.assign(h.bootstrap, fields);
    await assert.rejects(h.transport.send(request("enumerate")), {name: "SecurityError"});
    assert.equal(h.sockets.length, 0);
  }
});
test("socket loss rejects all pending work without replay, requiring a fresh chooser", async () => {
  const h = harness({respond: false});
  const pending = [h.transport.send(request("enumerate")), h.transport.send(request("transferOut"))];
  const rejected = pending.map(p => assert.rejects(p, {name: "NetworkError"}));
  await h.until(() => h.requests().length === 2);
  h.sockets[0].close(); await Promise.all(rejected);
  assert.equal(h.disconnected.length, 1);
  await assert.rejects(h.transport.send(request("transferIn")), {name: "InvalidStateError"});
  assert.equal(h.requests().length, 2); assert.equal(h.native.length, 1);
  h.respond = true;
  assert.deepEqual(await h.transport.send(request("enumerate")), success);
  assert.equal(h.sockets.length, 2); assert.equal(h.native.length, 2); assert.equal(h.requests().length, 3);
  h.transport.close();
});
test("a socket operation is never silently downgraded to legacy after disconnect", async () => {
  const h = harness(); await h.transport.send(request("enumerate"));
  h.sockets[0].close(); await tick();
  h.bootstrap = {ok: false, error: {name: "NotSupportedError", message: "no group"}};
  await assert.rejects(h.transport.send(request("enumerate")), {name: "NetworkError"});
  assert.deepEqual(h.native.map(m => m.op), ["transportBootstrap", "transportBootstrap"]);
  assert.equal(h.requests().length, 1);
});
test("request timeout closes the transport and never retries an ambiguous USB write", async () => {
  const h = harness({respond: false});
  const write = h.transport.send(request("transferOut"));
  const rejected = assert.rejects(write, {name: "TimeoutError"});
  await h.until(() => h.requests().length === 1);
  await h.clock.advance(100); await rejected;
  await assert.rejects(h.transport.send(request("transferOut")), {name: "InvalidStateError"});
  assert.equal(h.requests().length, 1); assert.equal(h.native.length, 1); assert.equal(h.clock.pending.size, 0);
  assert.equal(h.disconnected.length, 1);
});
test("bootstrap and handshake deadlines discard late replies and leave no pending timers", async () => {
  const pendingBootstrap = deferred();
  const h = harness({bootstrap: () => pendingBootstrap.promise});
  const rejected = assert.rejects(h.transport.send(request("enumerate")), {name: "TimeoutError"});
  await h.clock.advance(100); await rejected;
  pendingBootstrap.resolve({ok: true, url: "ws://127.0.0.1:1/", token, key: key.toString("base64")}); await tick();
  assert.equal(h.sockets.length, 0); assert.equal(h.clock.pending.size, 0);
  const stalled = harness({onHello() {}});
  const rejected2 = assert.rejects(stalled.transport.send(request("enumerate")), {name: "TimeoutError"});
  await stalled.until(() => stalled.frames.length === 1);
  await stalled.clock.advance(100); await rejected2;
  assert.equal(stalled.requests().length, 0); assert.equal(stalled.clock.pending.size, 0);
});
test("malformed and unmatched responses disconnect instead of accepting fabricated USB results", async () => {
  for (const malformed of ["{", "null", {type: "response", id: "unknown", response: success},
    {type: "response", id: 7, response: success}, {type: "response", response: {ok: true}},
    {type: "response", response: {ok: false, instance: "native", error: {name: 1, message: "bad"}}},
    {type: "error", error: {name: "TypeError", message: 7}}]) {
    const h = harness({respond: false});
    const pending = h.transport.send(request("enumerate"));
    const rejected = assert.rejects(pending, {name: "NetworkError"});
    await h.until(() => h.requests().length === 1);
    const message = typeof malformed === "object" ? {...malformed, id: malformed.id || h.requests()[0].id} : malformed;
    h.sockets[0].receive(message); await rejected;
    assert.equal(h.disconnected.length, 1); assert.equal(h.requests().length, 1);
  }
});
test("ready before authentication and duplicate challenges never dispatch USB requests", async () => {
  for (const onHello of [socket => socket.receive({type: "ready"}), (socket, hello) => {
    const challenge = {type: "challenge", challenge: socket.challenge, proof: proof(`server:${hello.challenge}:${socket.challenge}`)};
    socket.receive(challenge); socket.receive(challenge);
  }]) {
    const h = harness({onHello});
    await assert.rejects(h.transport.send(request("enumerate")), {name: "NetworkError"});
    await tick(); assert.equal(h.requests().length, 0);
  }
});
test("authenticated transport errors reject only their request and backend errors retain their envelope", async () => {
  const h = harness({respond: false});
  const pending = h.transport.send(request("enumerate"));
  const rejected = assert.rejects(pending, {name: "QuotaExceededError", message: "Queue full"});
  await h.until(() => h.requests().length === 1);
  h.sockets[0].receive({type: "error", id: h.requests()[0].id, error: {name: "QuotaExceededError", message: "Queue full"}});
  await rejected; assert.equal(h.disconnected.length, 0);
  const next = h.transport.send(request("enumerate"));
  await h.until(() => h.requests().length === 2);
  const response = {ok: false, instance: "native-epoch", error: {name: "NotFoundError", message: "Device disconnected"}};
  h.sockets[0].receive({type: "response", id: h.requests()[1].id, response});
  assert.deepEqual(await next, response); assert.equal(h.native.length, 1);
  h.transport.close();
});
test("pending limit includes requests waiting for bootstrap; close rejects them and never starts a socket", async () => {
  const bootstrap = deferred();
  const h = harness({maxPending: 2, bootstrap: () => bootstrap.promise});
  const first = h.transport.send(request("enumerate")), second = h.transport.send(request("enumerate"));
  const rejected = [first, second].map(p => assert.rejects(p, {name: "AbortError"}));
  await assert.rejects(h.transport.send(request("enumerate")), {name: "QuotaExceededError"});
  h.transport.close(); await Promise.all(rejected);
  bootstrap.resolve({ok: true, url: "ws://127.0.0.1:1/", token, key: key.toString("base64")}); await tick();
  assert.equal(h.sockets.length, 0); assert.equal(h.native.length, 1);
  await assert.rejects(h.transport.send(request("enumerate")), {name: "AbortError"});
});


test("bootstrap accepts the native signed claims token up to the 4096 byte protocol limit", async () => {
  const claims = {profile: randomUUID(), origin, instance: randomUUID(), nonce: randomUUID(), issuedAt: 1790610000,
    expiresAt: 1790610060, appGroup: "group.org.webtilp.safariwebusb", version: 1};
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64");
  const nativeToken = payload + "." + proof(payload);
  assert.ok(nativeToken.length > 256 && nativeToken.length < 4096);
  const h = harness(); h.bootstrap.token = nativeToken;
  await h.transport.send(request("enumerate"));
  assert.equal(h.frames[0].token, nativeToken);
  h.transport.close();
  const tooLong = harness(); tooLong.bootstrap.token = "A".repeat(4097);
  await assert.rejects(tooLong.transport.send(request("enumerate")), {name: "SecurityError"});
  assert.equal(tooLong.sockets.length, 0);
});

test("authenticated input events coexist with replies and malformed events disconnect", async () => {
  const h=harness(); await h.transport.send(request("serial.enumerate"));
  const event={event:"serial.data",deviceId:"port-1",data:"AQID"};
  h.sockets[0].receive({type:"event",session:"document-session",event});
  assert.deepEqual(h.events,[{session:"document-session",event}]);
  await h.transport.send(request("serial.write"));
  h.sockets[0].receive({type:"event",session:"document-session",event:{event:"serial.grant",deviceId:"port-1"}});
  assert.equal(h.disconnected.length,1);
});

test("Serial and HID require event-capable signed transport instead of native-message fallback", async () => {
  const h=harness({bootstrap:{ok:false,error:{name:"NotSupportedError",message:"unsigned"}}});
  for(const op of ["serial.enumerate","hid.enumerate"]) await assert.rejects(h.transport.send(request(op)),{name:"NotSupportedError"});
  assert.equal(h.native.length,1);
  assert.equal(h.native[0].op,"transportBootstrap");
});

test("fresh remembered-device lists reconnect after loss without replaying transfers", async () => {
  for (const op of ["getDevices","serial.getPorts","hid.getDevices","permissions.list"]) {
    const h=harness(); await h.transport.send(request("enumerate"));
    h.sockets[0].close(); await tick();
    await assert.rejects(h.transport.send(request("transferOut")),{name:"InvalidStateError"});
    assert.deepEqual(await h.transport.send(request(op)),success);
    assert.deepEqual(h.requests().map(f=>f.message.op),["enumerate",op]);
    assert.equal(h.native.length,2);
  }
});

test("native revocation events carry one API and reject malformed permission metadata", async () => {
  const h=harness(); await h.transport.send(request("getDevices"));
  for (const kind of ["usb","serial","hid"]) h.sockets[0].receive({type:"event",session:"document-session",event:{event:"permissions.revoked",kind,deviceId:"device-1"}});
  assert.deepEqual(h.events.map(e=>e.event.kind),["usb","serial","hid"]);
  h.sockets[0].receive({type:"event",session:"document-session",event:{event:"permissions.revoked",kind:"all",deviceId:"device-1"}});
  assert.equal(h.disconnected.length,1);
});

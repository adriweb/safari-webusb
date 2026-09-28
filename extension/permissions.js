"use strict";
const list = document.getElementById("permissions");
const status = document.getElementById("status");
const refresh = document.getElementById("refresh");
const clear = document.getElementById("clear");
let busy = false;
async function send(op, id) {
  const reply = await browser.runtime.sendMessage({op, ...(id ? {id} : {})});
  if (!reply || reply.error) throw new Error(reply?.error || "Device permissions are unavailable.");
  return reply.result;
}
function render(permissions) {
  if (!Array.isArray(permissions)) throw new Error("Invalid device permission list.");
  list.replaceChildren();
  for (const permission of permissions) {
    const row = document.createElement("section"); row.className = "permission";
    const origin = document.createElement("h2"); origin.textContent = permission.origin;
    const device = document.createElement("div"); device.className = "device";
    const name = document.createElement("span"); name.textContent = permission.name || "Device";
    const detail = document.createElement("small");
    detail.textContent = `${({usb:"USB", serial:"Serial", hid:"HID"})[permission.kind] || "Device"} · ${permission.durable ? "Remembered" : "Until disconnected"}`;
    name.appendChild(detail);
    const forget = document.createElement("button"); forget.type = "button"; forget.textContent = "Forget";
    forget.addEventListener("click", () => update("permissions.revoke", permission.id));
    device.append(name, forget); row.append(origin, device); list.appendChild(row);
  }
  clear.disabled = !permissions.length;
  status.textContent = permissions.length ? `${permissions.length} saved device permission${permissions.length === 1 ? "" : "s"}.` : "No saved device permissions.";
}
async function update(op = "permissions.list", id) {
  if (busy) return;
  busy = true; refresh.disabled = true; clear.disabled = true;
  for (const button of list.querySelectorAll("button")) button.disabled = true;
  try {
    if (op !== "permissions.list") await send(op, id);
    render(await send("permissions.list"));
  } catch (error) { status.textContent = error.message; }
  finally {
    busy = false; refresh.disabled = false;
    for (const button of list.querySelectorAll("button")) button.disabled = false;
  }
}
refresh.addEventListener("click", () => update());
clear.addEventListener("click", () => update("permissions.clear"));
update();

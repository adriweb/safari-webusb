"use strict";
const status = document.getElementById("status");
const connect = document.getElementById("connect");
const form = document.getElementById("form");
const hex = value => value.toString(16).padStart(4, "0");
browser.runtime.sendMessage({op: "chooserInfo"}).then(info => {
  if (!info || info.error) throw new Error(info?.error || "The device chooser is unavailable.");
  document.getElementById("origin").textContent = info.origin;
  document.getElementById("heading").textContent = `Connect a ${info.kind === "serial" ? "serial port" : info.kind === "hid" ? "HID device" : "USB device"}`;
  document.getElementById("permission-note").textContent = info.privateBrowsing
    ? "Private browsing: access lasts until this page is closed or reloaded."
    : !info.remembersPermissions ? "Access lasts until this page is closed or reloaded. Remembering devices requires the signed app and its persistent connection."
    : "This website can use this device again without asking. Devices without a unique serial number are remembered only while they remain connected. You can revoke access in Device permissions in the extension’s toolbar menu.";
  for (const device of info.devices) {
    const label = document.createElement("label");
    const radio = document.createElement("input");
    radio.type = "radio"; radio.name = "device"; radio.value = device.id;
    radio.addEventListener("change", () => { connect.disabled = false; });
    const name = document.createElement("span");
    name.textContent = device.productName || "USB device";
    const detail = document.createElement("small");
    const vendor = device.vendorId ?? device.usbVendorId, product = device.productId ?? device.usbProductId;
    detail.textContent = `${vendor === undefined ? "Serial port" : hex(vendor) + (product === undefined ? "" : ":" + hex(product))}${device.manufacturerName ? ` · ${device.manufacturerName}` : ""}${device.serialNumber ? ` · ${device.serialNumber}` : ""}`;
    name.appendChild(detail); label.append(radio, name);
    document.getElementById("devices").appendChild(label);
  }
  if (!info.devices.length) status.textContent = "No matching devices. Connect a device, cancel, and try again.";
}).catch(error => { status.textContent = error.message; });
form.addEventListener("submit", event => {
  event.preventDefault();
  const deviceId = new FormData(form).get("device");
  if (!deviceId) return;
  connect.disabled = true;
  browser.runtime.sendMessage({op: "chooserSelect", deviceId}).catch(error => { status.textContent = error.message; });
});
document.getElementById("cancel").addEventListener("click", () => browser.runtime.sendMessage({op: "chooserCancel"}));

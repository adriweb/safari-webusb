"use strict";
let port, reader, hid;
const output = document.querySelector("#log");
const log = text => { output.textContent = (new Date().toLocaleTimeString() + " " + text + "\n" + output.textContent).slice(0, 32000); };
const bytes = data => [...new Uint8Array(data.buffer ?? data, data.byteOffset ?? 0, data.byteLength)].slice(0, 64).map(x=>x.toString(16).padStart(2,"0")).join(" ");
const show = () => {
  document.querySelector("#serialInfo").textContent = port ? JSON.stringify({info:port.getInfo(),readable:!!port.readable,writable:!!port.writable},null,2) : "No port selected.";
  document.querySelector("#hidInfo").textContent = hid ? JSON.stringify({vendorId:hid.vendorId,productId:hid.productId,productName:hid.productName,opened:hid.opened,collections:hid.collections},null,2) : "No device selected.";
};
const button = (id, action) => document.getElementById(id).onclick = async () => { try { await action(); show(); log(id + ": OK"); } catch(error) { log(id + ": " + error.name + ": " + error.message); } };
button("serialChoose", async () => { if(port?.readable) throw new Error("Close the current port first."); port=await navigator.serial.requestPort(); });
button("serialList", async () => { log(JSON.stringify((await navigator.serial.getPorts()).map(p=>p.getInfo()))); });
button("serialOpen", async () => {
  if(!port) throw new Error("Choose a port first.");
  await port.open({baudRate:Number(document.querySelector("#baud").value)});
  reader=port.readable.getReader();
  (async () => { const current=reader; try { for(;;) { const {value,done}=await current.read(); if(done) break; log("Serial input: " + bytes(value)); } } catch(error) { log("Serial input: " + error); } finally { current.releaseLock(); if(reader===current) reader=null; show(); } })();
});
const closeSerial=async () => { if(reader) await reader.cancel(); if(port) await port.close(); };
button("serialClose", closeSerial);
button("serialForget", async () => { if(port?.readable) await closeSerial(); await port?.forget(); port=null; });
button("hidChoose", async () => { if(hid?.opened) throw new Error("Close the current device first."); [hid]=await navigator.hid.requestDevice({filters:[]}); if(hid) hid.oninputreport=e=>log("HID input " + e.reportId + ": " + bytes(e.data)); });
button("hidList", async () => { log(JSON.stringify((await navigator.hid.getDevices()).map(d=>({vendorId:d.vendorId,productId:d.productId,productName:d.productName})))); });
button("hidOpen", async () => { if(!hid) throw new Error("Choose a device first."); await hid.open(); });
button("hidClose", async () => { await hid?.close(); });
button("hidForget", async () => { await hid?.forget(); hid=null; });
button("clear", async () => { output.textContent=""; });
log("WebSerial: " + !!navigator.serial + "; WebHID: " + !!navigator.hid);

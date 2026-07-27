const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("klmsWindows", {
  loadConfig: () => ipcRenderer.invoke("config:load"),
  saveConfig: (config) => ipcRenderer.invoke("config:save", config),
  clearConfig: () => ipcRenderer.invoke("config:clear"),
  saveDashboardCache: (input) => ipcRenderer.invoke("dashboardCache:save", input),
  readClipboardText: () => ipcRenderer.invoke("clipboard:readText"),
  writeClipboardText: (text) => ipcRenderer.invoke("clipboard:writeText", text),
  clearClipboardTextIfUnchanged: (text) => ipcRenderer.invoke("clipboard:clearTextIfUnchanged", text),
  relayRequest: (request) => ipcRenderer.invoke("relay:request", request),
  startRelayEvents: (request) => ipcRenderer.invoke("relay:socketStart", request),
  stopRelayEvents: () => ipcRenderer.invoke("relay:socketStop"),
  requestRelaySnapshot: (request) => ipcRenderer.invoke("relay:snapshotRequest", request),
  downloadRelayFile: (request) => ipcRenderer.invoke("relay:fileDownload", request),
  onRelayEvent: (callback) => {
    const listener = (_event, payload) => callback(payload);
    ipcRenderer.on("relay:event", listener);
    return () => ipcRenderer.removeListener("relay:event", listener);
  },
  onRelaySnapshot: (callback) => {
    const listener = (_event, payload) => callback(payload);
    ipcRenderer.on("relay:snapshot", listener);
    return () => ipcRenderer.removeListener("relay:snapshot", listener);
  },
  onRelaySocketState: (callback) => {
    const listener = (_event, payload) => callback(payload);
    ipcRenderer.on("relay:socketState", listener);
    return () => ipcRenderer.removeListener("relay:socketState", listener);
  }
});

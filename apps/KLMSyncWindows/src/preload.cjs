const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("klmsWindows", {
  loadConfig: () => ipcRenderer.invoke("config:load"),
  saveConfig: (config) => ipcRenderer.invoke("config:save", config),
  clearConfig: () => ipcRenderer.invoke("config:clear"),
  readClipboardText: () => ipcRenderer.invoke("clipboard:readText"),
  relayRequest: (request) => ipcRenderer.invoke("relay:request", request),
  waitForRelayEvent: (request) => ipcRenderer.invoke("relay:waitForEvent", request),
  openExternal: (target) => ipcRenderer.invoke("shell:openExternal", target)
});

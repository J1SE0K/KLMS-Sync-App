const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("klmsWindows", {
  loadConfig: () => ipcRenderer.invoke("config:load"),
  saveConfig: (config) => ipcRenderer.invoke("config:save", config),
  relayRequest: (request) => ipcRenderer.invoke("relay:request", request),
  openExternal: (target) => ipcRenderer.invoke("shell:openExternal", target)
});

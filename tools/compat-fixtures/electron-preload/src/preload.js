const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('api', {
  save: (slot, data) => ipcRenderer.invoke('save', slot, data),
  load: (slot) => ipcRenderer.invoke('load', slot),
  ask: () => ipcRenderer.invoke('ask'),
  site: () => ipcRenderer.invoke('site'),
  probe: () => ipcRenderer.invoke('probe'),
  versions: { electron: process.versions.electron },
});

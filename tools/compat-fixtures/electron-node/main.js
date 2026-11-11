// 메인 프로세스: userData 에 JSON 저장, 창 크기·배율
const { app, BrowserWindow, ipcMain } = require('electron');
const fs = require('fs');
const path = require('path');

const file = () => path.join(app.getPath('userData'), 'progress.json');
function load() {
  try { return JSON.parse(fs.readFileSync(file(), 'utf8')); } catch (e) { return { count: 0 }; }
}
ipcMain.handle('load', () => load());
ipcMain.handle('save', (event, data) => {
  const tmp = file() + '.tmp';
  fs.mkdirSync(path.dirname(file()), { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify(data), 'utf8');
  if (fs.existsSync(file())) fs.copyFileSync(file(), file() + '.bak');
  fs.renameSync(tmp, file());
  return true;
});
ipcMain.handle('version', () => app.getVersion());
ipcMain.on('ping', (event, n) => event.reply('pong', n + 1));

app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 1000, height: 600, show: false,
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  });
  win.setContentSize(1200, 800);
  win.once('ready-to-show', () => {
    win.webContents.setZoomFactor(1.25);   // 1200×800 / 1.25 → 레이아웃 960×640
    win.show();
  });
  win.loadFile('index.html');
});
app.on('window-all-closed', () => app.quit());

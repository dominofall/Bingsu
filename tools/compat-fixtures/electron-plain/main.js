// 메인은 창만 만든다
const { app, BrowserWindow } = require('electron');
app.on('ready', () => {
  const win = new BrowserWindow({ width: 800, height: 600 });
  win.setMenuBarVisibility(false);
  win.loadFile('page/index.html');
});

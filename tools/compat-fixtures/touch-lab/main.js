// 메인은 1280×720 창 하나만 만든다 (운빨던전과 같은 크기)
const { app, BrowserWindow } = require('electron');
app.on('ready', () => {
  const win = new BrowserWindow({ width: 1280, height: 720, resizable: false });
  win.setMenuBarVisibility(false);
  win.loadFile('index.html');
});

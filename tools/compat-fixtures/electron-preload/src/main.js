// 메인: contextIsolation + preload, userData/saves/ 아래에 저장
const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const fs = require('fs');
const path = require('path');

const dir = () => path.join(app.getPath('userData'), 'saves');
ipcMain.handle('save', (e, slot, data) => {
  fs.mkdirSync(dir(), { recursive: true });
  fs.writeFileSync(path.join(dir(), 'slot' + slot + '.json'), JSON.stringify(data));
  return fs.readdirSync(dir());
});
ipcMain.handle('load', (e, slot) => {
  const f = path.join(dir(), 'slot' + slot + '.json');
  return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')) : null;
});
ipcMain.handle('ask', async () => {
  const r = await dialog.showMessageBox({ message: '정말 지울까요?', buttons: ['지우기', '취소'], cancelId: 1 });
  if (r.response === 0) fs.rmSync(dir(), { recursive: true, force: true });
  return r.response;
});
ipcMain.handle('site', () => shell.openExternal('https://example.com/'));
ipcMain.handle('probe', () => {
  // 쓰기 거부 확인: 모두 던져야 한다
  const tries = [
    () => fs.writeFileSync(path.join(__dirname, 'hack.js'), 'x'),
    () => fs.writeFileSync('/app/package.json', '{}'),
    () => fs.writeFileSync(path.join(app.getPath('userData'), '..', 'save.json'), '{}'),
    () => fs.writeFileSync(path.join(app.getPath('userData'), '.hidden'), 'x'),
    () => fs.writeFileSync('/tmp/x.txt', 'x'),
  ];
  const out = tries.map((t) => { try { t(); return 'leaked'; } catch (e) { return e.code || 'ERR'; } });
  // 한도: 파일 하나 16MB 넘으면 거부, 파일 1,000개 넘으면 거부 (확인 뒤 지운다)
  const ud = app.getPath('userData');
  try { fs.writeFileSync(path.join(ud, 'big.bin'), Buffer.alloc(17 * 1024 * 1024)); out.push('leaked'); } catch (e) { out.push(e.code || 'ERR'); }
  const many = path.join(ud, 'many');
  fs.mkdirSync(many, { recursive: true });
  let made = 0, code = 'leaked';
  for (let i = 0; i < 1100; i++) {
    try { fs.writeFileSync(path.join(many, i + '.txt'), 'x'); made++; } catch (e) { code = (e.code || 'ERR') + '@' + made; break; }
  }
  fs.rmSync(many, { recursive: true, force: true });
  out.push(code);
  return out;
});

function create() {
  const win = new BrowserWindow({
    width: 1280, height: 720,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  win.loadFile(path.join(__dirname, '..', 'web', 'index.html'));
}
app.whenReady().then(create);

# Electron 호환 1차 — 구현 명세

2026-11-11 결정. 전체 계획은 [`compat-plan.md`](compat-plan.md)(§4 설계, §6 의 0·1단계). 구현 세션(Opus, 워크트리)용 명세다. 명세와 다르게 해야 하면 이 파일 끝 "구현 기록"에 이유와 함께 적는다.

**목표:** PC 용 Electron 게임 zip 을 고치지 않고 가져와 실행한다. 첫 대상은 운빨던전(조사 표는 compat-plan §1). 끝났다는 기준은 §9.

## 0. 원칙

- **게임 이름으로 분기하지 않는다.** `if 운빨던전` 같은 코드를 쓰지 않는다. Electron·Node API 를 흉내 내는 공용 계층을 만들고, 운빨던전은 그 첫 시험 대상일 뿐이다. 운빨던전에만 필요한 보정이 나오면 코드에 넣지 말고 "구현 기록"에 적어 둔다(보정 파일 형식은 3차에서 정한다).
- **지금 웹 러너 위에 얹는다.** `GlassBowl`(WKWebView) + 스킴 핸들러 + 문서 시작 스크립트. MV·MZ(`IMPLEMENTATION-mvmz.md`)와 같은 길이다.
- **레조넌스·MV·MZ·웹 주소 게임은 그대로.** 기존 `PokemonSchemeHandler`·`GreenTeaSchemeHandler`·`nwShim` 의 동작이 바뀌면 안 된다. 공용으로 떼어 내는 것은 좋지만 `GreenTeaSelfTest`·`SpoonSelfTest`·`IglooSelfTest` 가 그대로 통과해야 한다.
- **쓰기는 그 게임의 저장 폴더 안 `userData/` 한정**(§4). PLAN 8.2 의 두 번째 예외다.
- 게임 파일은 커밋하지 않는다. 화면 문구는 평범한 한국어, 코드 이름은 빙수 테마(Electron = 팥빙수 → `RedBean…`), 주석·커밋·보고는 한국어. 엔진 이름은 화면에 보이지 않는다.
- 코드는 직접 쓴다. 다른 프로젝트의 Electron 흉내 코드를 옮기지 않는다.

| 개념 | 코드 (제안, 바꿔도 됨) |
|---|---|
| Electron 게임 정보 판별 | `Bowl/RedBeanProbe.swift` (순수 함수) → `Dish.electron: ElectronInfo?`, `bingsu.json` 의 `electron` |
| 스킴 핸들러 (게임 읽기 + userData 읽기·쓰기) | `Bowl/RedBeanSchemeHandler.swift`, 스킴 `bingsu-app`, 출처 `bingsu-app://game` |
| Node 흉내 (공용) | `Bowl/BowlScripts+Node.swift` 의 `nodeShim` |
| Electron 흉내 + 메인 실행 | `Bowl/BowlScripts+Electron.swift` 의 `electronShim` |
| 자가 테스트 | `Bowl/RedBeanSelfTest.swift` (`BINGSU_SELFTEST=1` 에 추가) |
| 시험용 작은 게임 | `tools/compat-fixtures/` (직접 만든 것, 커밋함) |

## 1. 먼저 확인할 것 (0단계, 반나절 안쪽)

본 구현 전에 시뮬레이터 웹뷰에서 아래를 확인하고 결과를 "구현 기록"에 적는다. 결과에 따라 §7 의 대비책을 넣는다.

1. `new Audio("…ogg")` 가 소리를 내는가(운빨던전 울음소리는 ogg 1,245개·wav 868개, 음악은 mp3). 배포 대상은 iOS 26. MV·MZ 때 시뮬레이터의 `canPlayType('audio/ogg')` 는 참이었다. 지금 빙수의 Ogg 폴리필은 `decodeAudioData` 만 대신한다.
2. 운빨던전 화면이 WebKit 에서 깨지지 않는가. `styles.css` 는 `vh`·`vw`·`inset`·`:has`·`::-webkit-scrollbar`·`aspect-ratio` 를 쓴다.
3. 동기 XHR 로 그림 수십 장을 읽어 data URL 로 바꾸는 코드(`mapScreen.js`·`creditScreen.js` 의 `fs.readFileSync`)가 체감될 만큼 느린가.
4. 웹뷰의 레이아웃 폭·높이를 게임이 정한 크기(1280×720)로 정확히 만드는 방법(§6)이 실제로 되는가.

## 2. 판별·가져오기 (`Shaver/RecipeDetector.swift`, `Shaver/Delivery.swift`, `RedBeanProbe`)

- asar 풀기는 지금 그대로(`resources/app.asar` → 게임 폴더). `app.asar.unpacked/` 가 있으면 같은 자리에 겹쳐 놓는다.
- **옛 경로 유지:** 풀고 나서 `dist/index.html` + `assets/` 모양이면 지금처럼 `ElectronInfo` 없이 `.electron`(레조넌스 경로). 이미 설치된 게임은 `electron` 항목이 없으므로 그대로 옛 경로다.
- **새 경로:** 그 밖에 `package.json` 이 있고 `main`(없으면 `index.js`)이 가리키는 파일이 있으면 `RedBeanProbe` 가 아래를 읽어 `ElectronInfo` 를 만든다. 전부 글자 훑기(정적)이고 게임 코드를 실행하지 않는다.
  - `main`: 메인 스크립트 상대 경로.
  - `entry`: 메인 스크립트의 `loadFile('…')`·`loadURL(…'…html')` 문자열에서 찾는다. 못 찾으면 메인 스크립트 폴더·게임 루트의 `index.html`, 다음 `dist/`·`build/`·`public/`·`app/`·`src/`·`renderer/` 의 `index.html` 순. 그래도 없으면 `.unknown` + "시작 화면을 찾지 못했어요".
  - `inputStyle`: 화면 쪽 `.js`·`.html` 을 훑어 `gamepad`·`keydown`·`keyup` 듣기 수와 `click`·`mouse*`·`pointer*` 듣기 수를 센다. 게임패드가 없고 키 듣기가 마우스 듣기의 1/5 이하면 `pointer`, 아니면 `pad`. (운빨던전: 키 8 대 마우스 약 180 → `pointer`)
  - `title`: `package.json` 의 `productName` → 시작 화면의 `<title>` → `name`.
- `dataPathApp`: `package.json` 의 `name`(지금 규칙). 운빨던전은 `pokecarddungeon`.
- 원격 주소를 여는 앱(`loadURL('https://…')`)은 이번 범위가 아니다. `.unknown` + "온라인 주소를 여는 앱이에요. 주소로 웹 게임 추가를 써 보세요".
- 가져올 때 Windows 찌꺼기 정리(`*.exe`·`*.dll`·`*.pak`·`locales/` 등)는 지금 규칙 그대로. 운빨던전의 `resources/elevate.exe` 도 지워진다.
- `.node` 파일(네이티브 애드온)이 게임 안에 있으면 가져오기는 하되 `ElectronInfo.nativeAddons` 에 이름을 적어 둔다(실행 때 `require` 하면 §5 의 기록으로 간다).

## 3. 스킴 핸들러 (`RedBeanSchemeHandler`)

게임이 보는 가상 경로는 두 갈래다.

| 가상 경로 | 실제 | 권한 |
|---|---|---|
| `/app/…` | 게임 폴더 | 읽기만 |
| `/userData/…` | `Saves/<dataPathApp>/userData/` | 읽기·쓰기 (§4) |
| 그 밖 (`/appData`, `/tmp`, `/home` …) | 없음 | 읽기 404, 쓰기 403 |

- 주소는 `bingsu-app://game/app/index.html` 식. 시작 주소는 `bingsu-app://game/app/<entry>`.
- 읽기 규칙은 `GreenTeaSchemeHandler` 와 같게: 대소문자 무시 다시 찾기(iOS 실기기는 대소문자를 가린다), Range(206), `HEAD` 의 `X-Bingsu-Kind`·`X-Bingsu-Mtime`, 폴더 `GET` 은 이름 배열 JSON, `..`·`\`·`:`·NUL·숨김 조각·밖을 가리키는 링크는 404. 같은 코드를 공용으로 떼어 쓰는 것을 권한다(녹차 쪽 동작은 그대로).
- 응답에 `Access-Control-Allow-Origin` 은 넣지 않는다(같은 출처만 쓴다).

## 4. 저장 (`userData`)

- **`Saves/<dataPathApp>/save.json` 은 빙수가 이미 쓰는 이름이다**(`Freezer.localStorageFile`). 운빨던전도 `save.json` 을 쓴다. 그래서 게임의 userData 는 한 단계 아래 `Saves/<dataPathApp>/userData/` 로 둔다. 절대 저장 폴더 바로 아래에 쓰게 하지 않는다.
- 쓰기 허용: `/userData/` 아래, 조각마다 1~128바이트·숨김 아님, 깊이 4 이하. `PUT`·`DELETE`·`MOVE`(둘 다 `/userData/` 안)·`MKCOL`. 확장자는 가리지 않는다(게임마다 다르다).
- 한도: 파일 하나 `Freezer.maxBytes`(16MB), 게임 하나 파일 1,000개·합계 512MB(MV·MZ 와 같은 값). 넘으면 507 → 흉내 계층에서 `ENOSPC`.
- 거부는 403 + `[RedBean] write denied <경로>` 로그.
- **얼음틀:** `IceTray` 가 새 경로 게임(`dish.electron != nil`)에서는 `userData/` 아래 파일을 하위 폴더까지 묶는다(키는 지금 규칙 `bingsu.file.<상대 경로 UTF-8 16진수>`). 이 게임들은 localStorage 스냅샷(`freezerEnabled`)을 끈다(같은 `save.json` 을 두 곳이 쓰면 서로 덮는다). localStorage 를 쓰는 Electron 게임의 그 데이터는 1차에서는 웹뷰 저장소에만 남는다(백업 대상 아님, "구현 기록"의 남은 일).
- 게임을 열기 전 `IceTray.sync(dish, allowUnpack: true)`, 백그라운드·종료 때 `allowUnpack: false` 로(MV·MZ 와 같은 자리).
- 가져오는 zip 안에 `userData/` 폴더나 맨 위 저장 파일이 같이 들어 있는 경우는 1차 범위가 아니다(PC 세이브는 Files 앱에서 `Saves/<이름>/userData/` 에 넣는다).

## 5. 흉내 계층 (문서 시작 스크립트)

주입 순서: 지금의 공용 스크립트 → `nodeShim` → `electronShim`(메인 실행 포함) → 페이지.

### 5.1 Node 흉내 (`nodeShim`, 공용)
- `nwShim` 의 path·Buffer·fs·os·process 를 떼어 내 같이 쓴다. `nwShim` 은 떼어 낸 것을 쓰도록 바꾸되 MV·MZ 동작과 로그는 그대로.
- 차이는 설정으로: 출처(`bingsu-mv` / `bingsu-app`), 루트(`/` / `/app`), `process.platform`.
- **`process.platform` 은 `win32`** 로 둔다(이 게임들이 시험된 환경이 Windows 다). 경로는 POSIX 식(`/`)이고 fs 가 `\` 를 `/` 로 바꿔 받는다. `process.env` 에 `APPDATA=/appData`, `HOME`·`USERPROFILE=/home`. `process.versions` 에 `electron`·`chrome`·`node` 문자열(게임이 Electron 인지 볼 때 쓴다), `process.type`(메인 `browser`, 화면 `renderer`), `process.resourcesPath=/app`.
- 더할 것: `events`(EventEmitter), `util`(`format`·`inspect`·`promisify`·`inherits`·`types` 최소), `url`(`fileURLToPath`·`pathToFileURL`·`URL`), `assert` 최소, `fs.copyFileSync`·`fs.rmSync({recursive})`·`fs.mkdirSync({recursive})`·`fs.readdirSync`·`fs.promises`.
- **CommonJS 로더:** `makeRequire(dir)` 가 `./`·`../`·`/` 로 시작하는 이름을 그 폴더 기준으로 찾는다(`그대로` → `.js` → `.json` → `/index.js`, `package.json` 의 `main` 은 `node_modules` 안에서만). 파일은 동기 XHR 로 읽어 `(function (exports, require, module, __filename, __dirname) {…})` 로 감싸 실행하고 경로별로 캐시한다. `.json` 은 `JSON.parse`. 맨이름(`lodash`)은 `node_modules` 를 위로 올라가며 찾는다. 감싼 코드 끝에 `//# sourceURL=<가상 경로>` 를 붙여 오류 위치가 보이게 한다.
- 없는 모듈·없는 함수는 조용히 삼키지 않는다. Node 와 같은 오류(`MODULE_NOT_FOUND`, `ENOSYS`)를 던지고 `bowl` 메시지로 `compat` 기록을 남긴다(무엇을, 어느 파일에서). 네이티브 애드온(`.node`)·`child_process`·`net`·`dgram`·`worker_threads` 는 `MODULE_NOT_FOUND`.

### 5.2 Electron 흉내 (`electronShim`)
`require('electron')` 이 주는 것. 메인과 화면이 같은 웹뷰에 있으므로 한 객체에 양쪽을 다 담아도 된다.

- **ipc:** `ipcMain.handle/handleOnce/removeHandler/on/once/removeListener`, `ipcRenderer.invoke/send/sendSync/on/once/removeListener/removeAllListeners`. 인자와 결과는 `structuredClone` 으로 복사해 넘긴다(진짜와 같이 함수·DOM 은 못 넘기고 오류가 난다). `invoke` 는 항상 Promise, 핸들러가 없으면 진짜와 같은 문구로 거절. 핸들러의 첫 인자 `event` 에 `sender`(= `webContents`)·`reply`·`returnValue`. `webContents.send` → `ipcRenderer.on`.
- **app:** `getPath(name)`(`userData`·`appData`·`temp`·`home`·`documents`·`desktop`·`downloads`·`exe`·`logs` → §3 의 가상 경로), `setPath`(무시하고 기록), `getAppPath`(`/app`), `getName/setName`, `getVersion`(`package.json`), `getLocale`(`ko`)·`getSystemLocale`, `isPackaged = true`, `whenReady`·`isReady`, `on/once`(`ready`·`window-all-closed`·`activate`·`before-quit` 는 받기만), `quit/exit`(→ 게임 종료, 지금의 MV `quit` 경로), `requestSingleInstanceLock → true`, `commandLine.appendSwitch`·`disableHardwareAcceleration`·`setAppUserModelId`(무시).
  - 이름을 `setName` 으로 바꿔도 userData 는 §4 의 한 곳이다(운빨던전은 `app.setName('포켓몬 운빨던전')` 을 부른다).
- **BrowserWindow:** `new BrowserWindow(opts)` 는 창을 만들지 않고 옵션을 적어 둔다. `loadFile/loadURL`(지금 열린 페이지와 다르면 기록만), `webContents`(`send`·`on/once`·`setZoomFactor/getZoomFactor`·`openDevTools`·`setWindowOpenHandler`·`session` 최소·`executeJavaScript`), `on/once`(`ready-to-show`·`closed`·`resize`·`enter-full-screen`·`leave-full-screen`), `show/hide/focus/center/close/destroy/isDestroyed`, `setContentSize/getContentSize/setSize/getSize/getBounds/setBounds`, `setFullScreen/isFullScreen`, `setResizable/isResizable`, `setMenu/setMenuBarVisibility/removeMenu`, `setTitle`, `getAllWindows/getFocusedWindow/fromWebContents`. `ready-to-show` 는 `DOMContentLoaded`, `did-finish-load` 는 `load` 때 낸다. 두 번째 창을 만들면 기록만 하고 같은 객체처럼 군다.
- **그 밖:** `Menu`·`MenuItem`·`Tray`·`globalShortcut`·`powerSaveBlocker`·`nativeTheme`·`Notification`·`autoUpdater`(아무것도 안 함), `screen`(`getPrimaryDisplay`·`getDisplayMatching`·`getAllDisplays` → 1920×1080 작업 영역, 배율 1), `shell.openExternal`(지금 있는 "사파리에서 열까요?" 경로)·`shell.openPath`(무시), `dialog.showMessageBox(Sync)`(`confirm`/`alert` 로)·`showOpenDialog`·`showSaveDialog`(취소로 답하고 기록), `clipboard`(읽기 빈 글자, 쓰기는 `navigator.clipboard`), `nativeImage` 최소, `contextBridge.exposeInMainWorld(k, api)` → `window[k] = api`, `webFrame`.
- 목록에 없는 것을 부르면 `undefined` 가 아니라 **기록 남기는 대역**을 준다(`Proxy`: 부르면 아무것도 안 하고 한 번만 `compat` 기록). 게임이 멈추지 않는 것이 먼저다.

### 5.3 메인 실행과 화면 쪽 준비
1. 문서 시작에 메인 스크립트를 §5.1 로더로 실행한다(`require('/app/<main>')`, 메인용 `require` 는 Node 흉내 전부 + electron). 오류가 나면 기록하고 화면 쪽은 계속 띄운다.
2. `app.whenReady()` 를 풀고 `ready` 를 낸다. 이때 게임이 `BrowserWindow` 를 만들고 `ipcMain.handle` 을 건다.
3. 화면 쪽 준비는 그 창의 `webPreferences` 를 따른다.
   - `nodeIntegration: true`(운빨던전): 전역에 `require`(페이지 폴더 기준)·`module`·`exports`·`__dirname`·`__filename`·`global`·`process`·`Buffer` 를 둔다. `<script>` 로 읽힌 파일이 `module.exports = …` 를 해도 오류가 없어야 한다(운빨던전의 `mapGen.js`).
   - `preload` 가 있으면: 그 스크립트를 로더로 실행한다(electron 과 Node 흉내를 준다). `contextIsolation` 을 실제로 나누지는 않는다.
   - 둘 다 없으면: 전역을 건드리지 않는다(순수 브라우저 코드).
4. 문서 시작 스크립트의 마이크로태스크는 페이지의 첫 `<script>` 보다 먼저 끝난다는 것에 기대지 말고, `ipcRenderer.invoke` 는 메인 준비가 끝날 때까지 기다렸다가 넘긴다.
5. 페이지가 통째로 다른 문서로 옮겨 가면 메인은 새 문서에서 다시 시작한다(1차의 한계, 기록만).

## 6. 화면·입력

- **화면 크기:** 게임이 정한 창 크기를 웹뷰의 레이아웃 크기로 삼는다. 값은 `BrowserWindow` 의 내용 크기(`setContentSize` → 생성자 `width/height` → 기본 1280×720)를 `setZoomFactor` 값으로 나눈 것. 흉내 계층이 이 값을 네이티브에 알리고(`bowl` 이나 새 메시지), 컨테이너는 그 비율로 게임 자리를 잡고(지금 16:9 고정 계산을 비율 인자로), 웹뷰 안은 `innerWidth`·`innerHeight` 가 그 값이 되게 한다. 방법은 0단계 4번에서 되는 쪽으로: (가) 웹뷰를 그 크기로 만들고 `transform` 으로 줄이기, (나) `viewport` 메타 `width=<폭>` 주입. 탭 좌표가 맞아야 한다.
  - 운빨던전은 설정에 해상도·전체화면 항목이 있다. 값이 바뀌면 같은 경로로 다시 맞춘다(전체화면은 1920×1080 으로 답한다).
- **패드:** `inputStyle == pointer` 인 게임은 가상 패드를 처음부터 숨기고(지금 "매핑 없는 웹 게임"과 같은 동작, 일시정지 화면에서 켤 수 있음) 탭이 그대로 웹뷰로 간다. 가로에서는 게임이 화면을 채운다. `pad` 인 게임은 지금 Electron 기본 배치.
- iOS 의 "첫 탭은 가리키기" 버릇, 길게 눌러 가리키기, 키 줄, 확대는 **2차**다. 1차에서는 건드리지 않고, 불편한 자리를 "구현 기록"에 적어 둔다.
- 데스크톱 흉내(`desktopSpoof`)·UA 는 로컬 게임 기본값을 따르되, 게임이 UA 로 휴대폰용 화면을 고르지 않게 데스크톱 Safari UA 를 쓴다(MV·MZ 와 같게).

## 7. 소리

- `mediaTypesRequiringUserActionForPlayback = []` 는 지금 그대로라 첫 화면 음악이 사용자 동작 없이 난다.
- 0단계 1번에서 `<audio>` 의 ogg 가 안 되면: `HTMLMediaElement` 의 `src`(와 `new Audio(src)`)가 `.ogg` 일 때 파일을 받아 지금 있는 WASM 디코더로 풀고 WAV Blob 주소로 바꿔 끼우는 보정을 `BowlScripts` 에 넣는다(주소별 캐시, 상한). 되면 넣지 않는다.
- "무음 모드에서도 소리 재생"·음량·다른 앱 소리와 함께 듣기는 지금 스크립트가 `<audio>` 에도 듣는지 확인한다.

## 8. 시험용 작은 게임 (`tools/compat-fixtures/`)

실제 게임은 커밋할 수 없으므로, 직접 만든 아주 작은 Electron 식 게임을 둔다(각각 폴더 하나, `package.json` + 메인 + 화면, 그림·소리는 코드로 만들거나 몇 KB).

1. `electron-node/`: `nodeIntegration: true`. 화면에서 `require('electron')`·상대 모듈·`fs.readFileSync`(JSON, 그림 → data URL)·`module.exports` 가 든 `<script>`, 메인에서 userData JSON 읽고 쓰기·`setContentSize`·`setZoomFactor`.
2. `electron-preload/`: `contextIsolation` + `preload` + `contextBridge` 로 `window.api.save/load`.
3. `electron-plain/`: 순수 브라우저 코드 + `localStorage`, 메인은 창만 만든다.

자가 테스트(`RedBeanSelfTest`)는 순수 함수(경로 규칙 표, 쓰기 허용·한도, `RedBeanProbe` 가 위 세 폴더를 읽은 결과)를 본다. 실행 확인은 §9 에서 손으로.

## 9. 끝났다는 기준 (시뮬레이터: iPhone 17 Pro, iPad Pro 13)

게임 원본은 주 저장소 폴더의 `포켓몬 운빨던전 1.6/`(읽기만, 워크트리에 복사해도 커밋 금지). zip 으로 묶어 `BINGSU_IMPORT` 로 넣는다.

| 항목 | 기준 |
|---|---|
| 가져오기 | 운빨던전 zip → 게임 목록에 제목 "포켓몬 운빨던전", 로그에 `main=main.js entry=index.html input=pointer saves=pokecarddungeon` |
| 실행 | 타이틀(음악 남) → 모험 시작 → 스타터 고르기 → 지도 → 전투 한 번 → 상점이나 센터 한 번. 콘솔 오류 없이 |
| 화면 | `innerWidth×innerHeight` 가 1280×720, iPhone 가로·세로와 iPad 가로·세로에서 잘리지 않고 탭 자리가 맞음. 패드는 숨겨져 있음 |
| 저장 | `Saves/pokecarddungeon/userData/` 에 `settings.json`·`save.json`·`pokedex.json` 등이 생김. 저장 폴더 바로 아래의 `save.json` 은 얼음틀 것만 |
| 이어하기 | 앱을 완전히 껐다 켠 뒤 타이틀의 이어하기로 지도까지. 도감 기록 유지 |
| 소리 | 음악, 효과음, 울음소리(ogg·wav 각각) |
| 설정 | 게임 안 설정의 음량 저장, 해상도·전체화면을 바꿔도 화면이 깨지지 않음 |
| 쓰기 거부 | `/app` 쓰기, `/userData` 밖, `..`, 숨김 이름, 17MB 파일, 1,001번째 파일 → 거부 + 로그 |
| 얼음틀·가짜 iCloud | 백그라운드 때 `파일 n개 → save.json`, `BINGSU_FAKE_ICLOUD` 로 iPhone 저장 → iPad 이어하기 |
| 시험용 게임 | §8 의 세 개가 각각 실행·저장·이어하기 |
| 회귀 | 레조넌스 타이틀·저장 복원, MV·MZ 하나 실행·저장, 웹 주소 게임 하나 로딩, 기본 게임 Bingsu. 자가 테스트 전부 통과 |
| Release | Release 구성 컴파일 |

하지 못한 것은 표에 "하지 못함"으로 적는다. 실기기는 사용자가 한다.

## 10. 하지 않는 것 (1차)

- 포인터 방식 다듬기(가리키기·오른쪽 클릭·휠·키 줄·확대) → 2차.
- 일반 NW.js 게임, 호환 보고서 화면, 게임별 보정 파일 → 3차. (기록 자체는 1차에서 로그로 남긴다.)
- 자체 프로토콜(`protocol.registerFileProtocol` 등)을 쓰는 새 게임, 원격 주소 앱, 여러 창, `webview` 태그, `file://` 로 직접 만든 주소.
- 빌드 번호·"새로운 기능" 글·TestFlight 아카이브·업로드·main 병합·사이트 글. 전부 사용자 결정 뒤에 한다.

## 11. 작업 환경 주의

- 워크트리에는 `BingsuApp/build/BrassBowl/`(엔진 프레임워크)와 `BingsuApp/Secrets.xcconfig` 가 없다. 주 저장소(워크트리가 갈라져 나온 원래 폴더)의 것을 링크하거나 복사하고 `xcodegen generate` 를 한다. 프레임워크가 없으면 경고만 뜨고 RPG Maker 게임이 안 도는 앱이 된다(로그의 "BrassBowl.framework 넣음" 확인).
- `~/Dev` 는 작은 파일 입출력이 느린 외장 디스크 이미지다. `-derivedDataPath` 는 내장 디스크(`~/Library/Developer/Xcode/DerivedData/…`)로 준다.
- 시뮬레이터는 iPhone 17 Pro 와 iPad Pro 13 둘만 쓴다. 새로 만들지 않는다.
- 주 저장소의 main 에는 다른 작업이 커밋 안 된 채 있을 수 있다. 건드리지 않는다.

## 구현 기록

2026-11-11, 워크트리 `claude/electron-compat-0a2cbd`, 시뮬레이터 iPhone 17 Pro · iPad Pro 13 (iOS 26).

### 0단계 확인 결과

1. **ogg `<audio>`:** `canPlayType('audio/ogg')` 는 "maybe", `; codecs=vorbis` 는 "probably" 인데 `play()` 는 `NotSupportedError`(code 4). wav·mp3 는 난다. → §7 대비책을 넣었다(`mediaShim`: `.ogg`·`.oga` 주소를 받아 `OfflineAudioContext.decodeAudioData`(지금 WASM 폴리필이 대신함)로 풀고 16비트 WAV Blob 주소로 바꿔 끼움, 주소별 캐시, 96MB 넘으면 오래된 것부터 해제, 실패하면 원래 주소). 로그 예: `ogg media impidimp.ogg 34KB in 71ms`.
2. **WebKit 화면:** 타이틀·지도·전투·설정 화면이 깨지지 않았다(`vh`·`inset`·`:has`·`aspect-ratio` 문제 없음). 따로 고친 CSS 없음.
3. **동기 XHR 그림 읽기:** 숫자로 재지는 않았다. 시뮬레이터에서 지도 화면이 바로 열렸고 멈춤은 느끼지 못했다. 앱 시작부터 메인 실행까지 약 0.7초, 페이지 로드 끝까지 약 1.7초. 실기기 확인 필요.
4. **레이아웃 크기:** (가) 방식. 웹뷰 프레임을 게임 크기(내용 크기 ÷ 확대 배율)로 만들고 SwiftUI `.frame` + `.scaleEffect` 로 줄인다. `innerWidth×innerHeight` 1280×720, 탭 좌표 맞음(세로 iPhone 에서 기대 CSS 536,440 → 실제 535,440).
- 2~4번은 따로 손으로 만든 흉내 대신 본 구현으로 바로 쟀다(명세와 다른 점).

### 명세와 다르게 한 것과 이유

- **가져오기:** asar 없이 `resources/app/package.json` 이 있으면 그 폴더를 게임 루트로 삼는다(Electron 은 asar 를 끈 배포도 있다).
- **Windows 찌꺼기 정리:** 새 경로 모양(`RedBeanProbe.looksLikeApp`)이면 `*.exe`·`*.dll` 과 Electron 실행 파일 이름들, `.pak` 만 든 `locales/` 만 지운다. 게임 자료로 쓰일 수 있는 다른 이름은 남긴다. 옛 경로는 지금 규칙 그대로.
- **Node 흉내 공용화의 부수 효과(MV·MZ):** 413/507 이 `EIO` 대신 `ENOSPC`, 흉내 안 하는 fs 함수 몇 개가 조용히 넘어가지 않고 `ENOSYS` + `compat` 기록, `os` 객체가 조금 더 풍부. MV·MZ 저장·불러오기 회귀는 통과.
- **localStorage:** 새 경로 게임은 얼음틀 localStorage 스냅샷을 끄므로(§4) 게임의 localStorage 는 게임별 웹뷰 저장소에만 남는다(앱을 껐다 켜도 유지는 확인, 백업·iCloud 대상은 아님). 남은 일.
- **`keysToDocument`** 를 새 경로 게임에도 켠다(키 이벤트를 문서로).
- **`mediaShim`** 은 ogg 변환 말고도 `<audio>` 를 일시정지·재개(`__bingsu.pause/resume`)와 게임 음량에 맞춘다. 지금 스크립트는 AudioContext 만 다뤘다.
- **`alert`·`confirm`** 은 WKWebView 에서 기본으로 안 뜨므로 UI 대리자를 넣었다. 새 경로 게임 메인 프레임만 대화상자를 띄우고, 다른 게임은 지금처럼 바로 끝낸다(confirm 은 거짓).
- **문서 시작 viewport 메타:** 페이지의 첫 인라인 스크립트가 `innerWidth` 를 980×551 로 읽었다(viewport 메타가 문서 끝 스크립트에서만 들어가서). `electronShim` 맨 앞에서 넣는다.
- **처음 프레임 1280×720 + 보일 때 로드(`loadWhenShown`):** 위 문제를 잡으려다 넣은 것. 진짜 원인은 viewport 메타였지만 해가 없고 새 경로 게임에만 해당해 남겼다.
- **resize 다시 보내기:** 크기가 바뀌는 도중의 값(735×490)이 마지막 `resize` 이벤트로 남는 일이 iPad 에서 있었다. 목표 크기에 닿았는데 마지막 이벤트가 다른 값이면 `resize` 를 한 번 더 낸다(`redbean resize re-sent`).
- **로그:** `<audio>` 파일별 첫 재생 결과(`media play ok/failed`), userData 쓰기 로그는 50개까지 다 남기고 그 뒤는 100개마다. DEBUG 전용 `BINGSU_TAPDEBUG=1` 탭 로그.
- **시험용 게임:** 빙수 실행기는 페이지 콘솔의 warn·error 만 로그로 넘기므로 `[fixture]` 줄은 `console.warn`. `electron-preload` 의 probe 에 한도 시험(17MB, 1,100개 쓰기)을 넣었다.
- package.json 없는 순수 HTML 옛 경로, 레조넌스 경로는 바꾸지 않았다.

### 운빨던전에서만 필요했던 보정

없음. 코드에 게임 이름 분기 없음. 참고로 게임 스스로 울음소리를 ogg → m4a/mp3 → wav 순서로 찾는다(일부 ogg 는 파일이 없어 404, mp3 는 `NotSupported`, 그다음 wav 가 남). 게임 동작이고 빙수 문제는 아니다.

### 2차로 넘길 불편한 점

- iPhone 세로에서 게임이 아주 작다(1280×720 을 폭에 맞춤).
- 전투의 공격·카드 놓기가 끌기로만 된다. 작은 화면에서 끌기 거리가 길다.
- 설정의 해상도 `<select>` 가 iOS 기본 선택기로 뜬다(동작은 함).
- 첫 탭이 가리키기로만 먹히고 클릭이 다음 터치 때 오는 듯 보인 적이 있다. 시뮬레이터 탭 도구(두 탭이 14ms 안이면 두 번 탭으로 묶임, 스크린숏이 화면보다 1초쯤 늦음)와 섞여 원인을 가리지 못했다. 실기기에서 다시 볼 것.
- 1280pt 웹뷰를 dpr 3 으로 그리면 그리기 버퍼가 크다(메모리). 평균 57~58fps 는 나왔다.
- `dialog.showMessageBox` 를 `confirm` 으로 바꾸므로 버튼 글자가 게임 것("지우기"/"취소")이 아니라 "취소"/"확인"이다.
- 쓰기 한도 확인이 PUT 마다 폴더를 훑는다(O(n), 파일 1,000개 근처에서 PUT 하나에 약 20ms). 보통 게임은 파일 몇 개라 문제없지만 많이 쓰는 게임이면 캐시가 필요하다.

### 남은 일

- localStorage 를 쓰는 Electron 게임의 그 데이터 백업·iCloud(위).
- 패드 방식(`inputStyle == pad`) 새 경로 게임의 패드 표시 확인(아래 표).

### §9 결과

| 항목 | iPhone 17 Pro | iPad Pro 13 |
|---|---|---|
| 가져오기 | 통과. 카드 제목 "포켓몬 운빨던전", 로그 `recipe=electron main=main.js entry=index.html input=pointer saves=pokecarddungeon keys=6 pointer=183 gamepad=false node=true preload=-` | 통과(같은 로그) |
| 실행 | 타이틀(음악 `media play ok title.mp3`) → 모험하기 → 튜토리얼 아니오 → 일반 모드 → 스타터 파이리 → 지도(`map.mp3`) → 전투 승리(+50G). 콘솔 warn·error 없음. **상점·센터는 하지 못함**(지도에서 그 칸까지 가지 않음) | iPhone 저장으로 이어서 2층 전투 승리(+50G, 타우린). 상점·센터 하지 못함 |
| 화면 | 1280×720, 가로는 높이를 채움, 세로는 폭에 맞춤. 탭 자리 맞음. 패드 숨김 | 가로·세로 1280×720, 잘림 없음, 탭 자리 맞음, 패드 숨김 |
| 저장 | `Saves/pokecarddungeon/userData/` 에 `pokedex.json`·`pokedex.json.bak`·`save.json`·`settings.json`·`tutorial.json`. `.tmp` → MOVE 동작. 바로 아래 `save.json` 은 얼음틀 묶음뿐 | 같음 |
| 이어하기 | 앱을 끄고 다시 켜서 "이어하기 · 일반모드 1막" → 지도 | 다시 켜서 이어하기 → 3층 지도, 골드 200 |
| 소리 | 음악 mp3, 울음 wav `play ok`, ogg 변환 확인(`impidimp.ogg 34KB in 71ms`). 효과음은 로그로 따로 가리지 않음(귀로 들은 확인은 하지 못함 — 시뮬레이터 세션에 소리 출력 확인 수단 없음) | 로그로만 확인 |
| 설정 | 해상도 1920×1080 → `redbean window 1920x1080` 로 UI 가 PC 처럼 작아지고 깨지지 않음, 1280×720 으로 돌아옴. 전체화면 켜기·끄기 저장. `settings.json` 유지. 음량 저장은 따로 확인하지 않음 | 하지 못함(iPhone 에서만) |
| 쓰기 거부 | `electron-preload` probe: `/app`·`__dirname`·`userData/..`·숨김 이름·`/tmp` 다섯 개 모두 `EACCES`, 17MB `ENOSPC`, 1,001번째 파일 `ENOSPC@1000`. 경로 규칙·한도는 자가 테스트 표로도 | 자가 테스트만 |
| 얼음틀·가짜 iCloud | 백그라운드 때 `[IceTray] pokecarddungeon: 파일 5개 → save.json`, 이글루 올림 | 내려받아 `save.json → 파일 5개` 로 userData 복원 → 이어하기, 다시 켤 때 올림 |
| 시험용 게임 | node: 전부 OK(레이아웃 960×640, 마지막 resize 960×640 포함). preload: `window.api`, 페이지에 node 없음, 1280×720, slot1 저장·불러오기, 대화상자, 사이트 열기("사파리에서 열까요?"). plain: localStorage 실행 횟수가 켤 때마다 늘어남(runs=3), 800×600 | node 전부 OK(`resize re-sent 960x640` 뒤 마지막 resize OK) |
| 패드 표시(`pad` 게임) | **하지 못함.** 이 시뮬레이터들에서는 MV 게임도 패드가 숨겨져 있다(게임 컨트롤러가 연결된 것으로 잡히는 환경 상태로 보임). `electron-plain`(pad 판정)의 패드가 보이는지는 실기기에서 | 같음 |
| 회귀 | 레조넌스 타이틀·`ready restore=up-to-date`, MV(adventure) 파일 1 불러오기·메뉴 저장(`.bak` → 저장 → global → bak 지움), 웹 주소 example.com 로딩, 기본 게임 Bingsu `ready restore=up-to-date` | 하지 못함(iPhone 에서만) |
| 자가 테스트 | Spoon roundtrip 72/0·compat·skins 7/7·export, Igloo 46, GreenTea 75/75, RedBean 52/52 | — |
| Release | 시뮬레이터용 Release 구성 컴파일 성공. 기기용 아카이브는 하지 않음(사용자 결정) | — |

# RPG Maker MV · MZ 실행 — 구현 명세 (빌드 27)

2026-11-01 결정. 조사 문서 [`research.md`](research.md) §2(2.1~2.9)·§4.2·§5(M1~M4) 를 바탕으로 한다. 구현 세션(Opus, 워크트리)용 명세. 명세와 다르게 해야 하면 이 파일 끝에 "구현 중 바뀐 것" 절로 적는다. VX/VX Ace(빌드 26) 와는 독립이다.

## 0. 원칙

- **지금 웹 러너 위에 얹는다.** MV/MZ 는 새 엔진이 아니라 `GlassBowl`(WKWebView) + 커스텀 스킴 핸들러 + 문서 시작 스크립트로 돈다. 길은 research §2.2 의 **B(NW.js 흉내)**: 게임이 `Utils.isNwjs()` 를 참으로 보고 PC 처럼 `save/` 에 파일로 저장하되, 그 쓰기는 빙수가 `Saves/<dataPathApp>/` 로 돌린다. 브라우저 모드(localStorage/IndexedDB) 는 쓰지 않는다.
- **쓰기는 저장 폴더 한정.** PLAN 8.2 "웹 게임에 네이티브 파일 API 를 주지 않는다" 의 유일한 예외다: 스킴 핸들러는 `save/` 아래 정해진 이름·확장자·크기만 쓰고, 그 밖은 403 + 로그. 이 예외를 PLAN 8.2 에 한 줄로 적는다.
- **코드는 직접 쓴다.** `mvmz-apple-mobile`(GPLv3 + 추가 조건) 은 구조 참고만 하고 코드를 옮기지 않는다. 옮긴 줄이 하나라도 있으면 오픈소스 라이선스 화면에 그쪽 요구대로 저작자 표시를 넣는다(research §2.9 끝).
- **레조넌스·포켓로그는 그대로.** 기존 Electron·웹 URL 경로의 스킴 핸들러·스크립트 동작이 바뀌면 안 된다. MV/MZ 분기는 `dish.recipe == .rpgMakerMV` 로만.
- 게임 파일은 커밋하지 않는다(PLAN 8장). 엔진 이름은 화면에 안 보인다(PLAN 7장). 화면 문구 평범한 한국어, 코드 이름 빙수 테마, 주석·커밋·보고 한국어.

| 개념 | 코드 |
|---|---|
| MV/MZ 게임 루트·메타 판별 | `Shaver/RecipeDetector.swift` + `Bowl/MVMZProbe.swift`(순수 함수) |
| MV/MZ 스킴 핸들러(읽기 + 저장 폴더 쓰기) | `Bowl/GreenTeaSchemeHandler.swift` (녹차빙수 = `.rpgMakerMV` 뱃지) |
| NW.js 흉내 스크립트 | `Bowl/BowlScripts.swift` 의 `nwShim` (문서 시작) |
| 키 배치 | `CutlerySet.rpgMakerMV` (`Spoon/SpoonModel.swift` 옆 `Bowl/CutlerySet+MV.swift`) |

## 1. 판별·가져오기 (`Shaver/RecipeDetector.swift`, `Shaver/Delivery.swift`)

- 루트 찾기: zip 안에서 (a) `package.json` 의 `main`(`www/index.html` 등) 이 가리키는 폴더, (b) `www/index.html` + `www/js/`, (c) 맨 위 `index.html` + `js/rmmz_core.js`(MZ) 또는 `js/rpg_core.js`(MV) + `data/System.json`. 셋 중 하나면 `.rpgMakerMV`. `package.nw` 가 있으면 먼저 풀어(`SafeUnzip`) 그 안을 루트로. exe 하나로 묶인 게임(Enigma 등) 은 `index.html` 이 없어 "지원하지 않는 게임" 으로 떨어지는데, `Game.exe` 와 `nw.pak` 만 있고 `www/` 가 없으면 문구를 "이 게임은 파일이 실행 파일 안에 묶여 있어 열 수 없어요" 로.
- `Dish` 에 `mvmz: MVMZInfo?`(`engine: .mv|.mz`, `root`(게임 폴더 기준 상대, `""` 또는 `www`), `gameTitle`, `encryptedImages/Audio`) 를 `bingsu.json` 매니페스트에 저장.
- `dataPathApp`: MZ 는 `System.json` `advanced.gameId` 가 있으면 `mz-<gameId>`, MV(또는 gameId 없음) 는 `package.json` `name` → `System.json` `gameTitle` 순(기존 `safeFolder` 규칙으로 정리). 업데이트해도 바뀌지 않는 값이어야 한다.
- `Dish.Recipe.rpgMakerMV.servable = true`, 뱃지·상태 줄은 지금 규칙.
- 가져올 때 게임 폴더(`<root>/save/`) 에 있는 `*.rpgsave`·`*.rmmzsave` 를 `Saves/<dataPathApp>/` 로 옮긴다(겹치면 `backups/`, 빌드 26 의 VX 처리와 같은 문구·같은 함수 재사용).
- 표지: `System.json` 의 `title1Name` → `<root>/img/titles1/<이름>.png`(MZ 암호화 `.png_`, MV `.rpgmvp`) 를 읽어 게임칩 표지로(사용자 표지가 없을 때). 암호화면 헤더 16바이트 확인 뒤 다음 16바이트를 `encryptionKey` 로 XOR 해 푼다(`Shaver/RPGMakerCrypt.swift`, 표지용만). 실패하면 기본 아이콘.

## 2. 스킴 핸들러 (`Bowl/GreenTeaSchemeHandler.swift`)

`PokemonSchemeHandler` 를 고치지 말고 새 핸들러를 만들되, Range·MIME·206 처리는 공용 함수로 빼서 둘이 같이 쓴다.

- 출처: `bingsu-mv://game/`(스킴 이름은 기존 규칙에 맞춰). 경로 → `<game>/<root>/<경로>`. **대소문자 무시**: 정확한 경로가 없으면 조각마다 디렉터리 목록에서 대소문자 무시로 다시 찾는다(결과는 캐시). `..`·절대 경로·심볼릭 링크는 404.
- GET/HEAD: 파일 그대로. `.rpgmvp`·`.rpgmvo`·`.rpgmvm`·끝이 `_` 인 파일은 `application/octet-stream`(게임이 스스로 푼다). HEAD 에는 `X-Bingsu-Kind: file|dir` 과 `X-Bingsu-Mtime`(ms) 헤더. 디렉터리 GET 은 이름 배열 JSON.
- **쓰기(저장 폴더만)**: 경로가 `save/` 로 시작하고(루트 기준) 이름이 `^[A-Za-z0-9_.-]{1,64}\.(rpgsave|rmmzsave)(_|\.bak)?$` 일 때만 PUT(본문 ≤ 16MB, `Freezer.maxBytes` 와 같게)·DELETE·MOVE(`Destination` 도 같은 규칙 안)·MKCOL(`save` 자체만) 허용. 실제 파일은 `Saves/<dataPathApp>/<이름>`. 그 밖의 PUT/DELETE/MOVE/MKCOL 은 403 + `[Bowl] mv write denied <경로>` 로그(Diag 와 같은 방식으로 게임별 집계).
- **본문 수신 확인(M2 첫 과제):** `WKURLSchemeTask.request.httpBody` 가 동기 XHR PUT 에서 실제로 오는지 시뮬레이터에서 먼저 확인한다. 오지 않으면 대안: 스크립트가 본문을 base64 로 잘라 `X-Bingsu-Body-<n>` 헤더(조각당 64KB) 로 보내고 핸들러가 이어 붙인다. 어느 쪽이든 이 파일 "구현 중 바뀐 것" 에 적는다.
- 저장 폴더가 없으면 핸들러가 만든다. 게임이 `save/` 밖 경로를 `existsSync` 로 묻는 것은 HEAD 로 답하면 된다(쓰기 아님).

## 3. NW.js 흉내 스크립트 (`BowlScripts.nwShim`, 문서 시작, `.rpgMakerMV` 만)

research §2.2 B 의 모양을 빙수가 직접 구현한다(약 300줄, 옮겨 쓰지 않음).

- `window.require(name)`: `fs`·`path`·`os`·`nw.gui`(앞의 `node:` 제거) 만. 나머지는 `MODULE_NOT_FOUND` 코드를 가진 Error. 호출된 모듈 이름을 `bowl` 메시지로 한 번씩 보고(플러그인 의존 파악).
- `fs`: 동기 함수는 **동기 XHR** 로 스킴에 — `existsSync`/`statSync`(HEAD, `isFile/isDirectory/mtime`), `readFileSync`(GET; 인코딩 없으면 `Uint8Array`/Buffer 흉내, `utf8` 이면 문자열), `writeFileSync`(PUT), `unlinkSync`(DELETE), `mkdirSync`(MKCOL), `readdirSync`(디렉터리 GET), `renameSync`(MOVE). 비동기판(`readFile`·`writeFile`·`unlink`·`rename` 등) 은 동기판을 `setTimeout(0)` 으로 감싸 콜백. `Buffer` 가 없으면 `from/toString('utf8'|'base64')` 만 되는 최소 흉내.
- `path`: `join`·`dirname`·`basename`·`extname`·`resolve`(루트 `/`)·`sep = "/"`.
- `process`: `{ platform: "linux", env: {}, argv: [], versions: { node: "0" }, cwd: () => "/", exit: () => 종료 메시지, on: noop, mainModule: { filename: "/index.html" } }`. MZ `main.js` 가 `/private/var` 로 시작하는 경로를 거부하므로 **루트 기준 `/`** 를 유지.
- `nw.gui`: `App.quit`/`closeAllWindows` → 네이티브 종료(기존 일시정지 "게임 종료" 와 같은 메시지), `Window.get()` → 어떤 메서드·속성이든 무해한 Proxy(`resizeTo`·`enterFullscreen`·`showDevTools` 등), `Menu`·`MenuItem` 빈 클래스, `Shell.openExternal(url)` → 네이티브로 넘겨 기존 외부 링크 규칙(Safari) 로. `window.close` 도 종료.
- 저장 경로: MV `StorageManager.localFileDirectoryPath`·MZ `StorageManager.fileDirectoryPath` 가 `process.mainModule.filename` 기준 `save/` 를 만들므로 결과는 `/save/` → 스킴 핸들러의 `save/`.
- 사용자 에이전트: `GlassBowl` 이 `.rpgMakerMV` 면 `customUserAgent` 를 데스크톱 Safari 로(연구 §2.2 "With the user agent of a phone…"). 기존 `maxTouchPoints`·`matchMedia` 위장은 그대로.
- 소리: MV 는 `WebAudio.canPlayOgg = () => true` 로 덮어 `.ogg` 를 고르게(빙수 Ogg 폴리필이 디코딩). MZ 는 건드리지 않는다(자체 디코더). 어느 길을 탔는지 `[Bowl] mv audio ext=.ogg via=polyfill|native|vorbisdecoder` 로 로그.
- 입력: 가상 Gamepad(기존 `__bingsu.pad`) 그대로. 키 합성 대상은 `.rpgMakerMV` 일 때 `document`(MV/MZ 가 document 에서 듣는다). 둘이 겹쳐 두 번 눌리지 않게 **키 경로는 `CutlerySet.transport == .keyboard` 일 때만** 쓴다(아래 배치는 gamepad).
- 일시정지·재개: 빙수가 rAF 를 묶는 동안 MZ `SceneManager._currentTime`/MV `SceneManager._currentTime`(있으면) 을 재개 때 `performance.now()` 로 맞춰 따라잡기 폭주를 막는다. `WebAudio._context` 는 기존 오디오 일시정지 경로(`AudioContext.suspend`) 를 그대로 쓴다.
- 포커스: 기존 `document.hasFocus = () => true` 로 충분(MZ `isGameActive`).
- 픽셀 선명도: 이 게임 설정 › 화면 › "픽셀 선명하게"(기본 켬) → `canvas { image-rendering: pixelated }`.

## 4. 키 배치 (`Bowl/CutlerySet+MV.swift`)

`CutlerySet.rpgMakerMV`: 전송 gamepad(표준 배치가 그대로 `Input.gamepadMapper` 에 맞음). 꼬리표: A 확인, B 취소, X 대시, Y 메뉴, LB 이전 페이지, RB 다음 페이지, 십자키·왼스틱 이동(`dpadAsStick = false`, 십자키 12~15 가 이미 방향). 키보드 폴백(`keys`)은 Z/X/Shift/Esc/Q/W/방향키. `forDish` 에서 `.rpgMakerMV` → 이 배치.

## 5. 저장 데이터 (`Freezer/IceTray.swift`, `Freezer/Freezer.swift`)

- `IceTray` 가 `Saves/<dataPathApp>/` 의 `*.rpgsave`·`*.rmmzsave` 를 save.json 에 묶는다(끝이 `_` 인 임시 파일과 `.bak` 은 묶지 않음). 되돌리기·백업·iCloud·Drive 는 XP 와 같은 길.
- 쓰기 순서 보장: MZ 는 `파일_` 로 옮기고 → 새로 쓰고 → `_` 지움. 핸들러의 MOVE/PUT/DELETE 가 같은 큐에서 순서대로 처리되게(동기 XHR 이라 자연히 순서가 맞지만 핸들러 내부에서 비동기로 넘기지 않는다).
- 게임 종료·백그라운드 때 `IceTray.sync` 호출 지점을 `BowlContainerView` 의 `.rpgMakerMV` 분기에 더한다(지금 Electron 은 localStorage flush, mkxp 는 IceTray).

## 6. 러너·화면 (`Bowl/BowlContainerView.swift`, `Bowl/GlassBowl.swift`)

- `.rpgMakerMV` 는 Electron 과 같은 `GlassBowl` 경로. 스킴 핸들러만 `GreenTeaSchemeHandler`, 시작 URL `bingsu-mv://game/index.html`. 화면 비율: 고정하지 않는다(게임이 캔버스를 창에 맞춤) — 포켓로그처럼 16:9 고정이 아니라 전체 화면. 세로 화면에서는 기존 "그 밖의 웹 게임" 규칙.
- 한 프로세스 1게임 제약 없음(안내 문구 안 띄움).
- 웹 프로세스 종료 처리·Diag 기록은 기존 그대로.

## 7. 테스트 게임

구현 세션은 사용자 없이 진행한다. 무료 배포 MV 게임 하나와 MZ 게임 하나(가능하면 암호화 배포본 하나 포함)를 찾아 `Games/mvmz-test/`(gitignore) 에만 두고, 이름·출처·엔진·암호화 여부만 `research.md` §4.3 표에 더한다. 못 찾으면 그 사실을 보고하고 코드 완성·회귀 확인까지만 하고 멈춘다.

## 8. 확인 (시뮬레이터 iPhone 17 Pro · iPad Pro 13)

- **회귀**: 레조넌스(Electron) 타이틀·저장·이어하기, 포켓로그(웹) 로딩·패드가 빌드 26 과 같음(스킴 핸들러·스크립트 분기 누수 없음).
- **M1**: MV·MZ 각각 zip 가져오기 → `recipe=rpgMakerMV engine=mv|mz root=…` 로그 → 타이틀 → 새 게임 → 가상 패드로 이동·대화·메뉴. 데스크톱 UA 확인(`navigator.userAgent` 로그). 소리 로그 `ext=.ogg`.
- **M2**: 저장 → `Saves/<dataPathApp>/file1.rmmzsave`(또는 `.rpgsave`) 생김, 게임 폴더엔 없음, `save/` 밖 쓰기 시도는 403 로그 → 종료·재실행 → 이어하기. PC 세이브(`file1.rpgsave`) 를 zip 에 넣어 가져오기 → 옮겨지고 이어하기. 같은 zip 재가져오기(업데이트) → 저장 유지. 가짜 iCloud 로 두 시뮬레이터 이어하기. 본문 수신 방식(httpBody 또는 헤더) 기록.
- **M3**: 일시정지 30초 뒤 재개해도 급가속 없음(화면 녹화 대신 `SceneManager._currentTime` 차이 로그). 키보드 폴백 배치로 바꿔도 확인·취소 동작.
- **M4**: 암호화 게임 표지가 게임칩에 보임, `img/` 경로 대소문자가 다른 게임(테스트용으로 파일 이름 하나를 바꿔) 도 그림이 뜸.
- **메모리**: MZ 맵에서 10분 자동 진행(또는 대기) 뒤 앱·웹 프로세스 메모리 기록(`Diag`), 배경음악 메모리 쌓임 여부를 `audiomix` 로그로.
- `git grep` 으로 PLAN 8.2 예외 문구가 들어갔는지, 핸들러가 `save/` 밖 PUT 을 거부하는 단위 자가 테스트(`BINGSU_SELFTEST=1`: 경로 규칙 표 10개).

## 9. 이번 빌드에서 하지 않는 것

브라우저 모드(localStorage/IndexedDB) 저장 지원, 배속, 플러그인별 호환 작업(로그만 모음), 동영상(`.webm`/`.mp4`) 보장, 스크린샷 저장 플러그인, 배경음악 메모리 다이어트(포켓로그 `musicDiet` 의 MV 이식은 측정 결과 보고 다음 빌드), mvmz 코드 이식.

## 10. 끝낼 때

PLAN.md 로드맵 "RPG Maker MV/MZ(NW.js) 지원" 항목 `[x]` + 요약·확인 결과, PLAN 8.2 에 예외 한 줄, `docs/beta/testflight-info.md` §2 빌드 27 테스트 문안 초안, `docs/beta/guide.md` 에 "RPG Maker MV·MZ 게임" 절(zip 모양, 저장 위치, PC 세이브), `research.md` [미확인] 갱신. 빌드 번호는 부모 세션이 올린다.

## 11. 구현 중 바뀐 것 (2026-11-01, 구현 세션)

- **본문 수신: `httpBody` 로 온다.** 동기 XHR PUT 본문이 `WKURLSchemeTask.request.httpBody` 에 그대로 왔다(iPhone 17 Pro·iPad Pro 13 시뮬레이터, MZ 3939B·MV 7056B, 로그 `[Bowl] mv put body via=httpBody`). 헤더 조각(`X-Bingsu-Body-<n>`) 대안은 만들지 않았다. 핸들러는 `httpBody` 가 없으면 `httpBodyStream` 을 읽고, 둘 다 없으면 빈 본문으로 본다(어느 길이었는지 첫 PUT 때 한 번 로그).
- **흉내 스크립트 자리:** `BowlScripts.swift` 가 이미 길어 `Bowl/BowlScripts+NW.swift` 의 `extension BowlScripts { nwShim(engine:), pixelatedCSS }` 로 따로 뒀다.
- **`process.versions` 는 빈 객체.** 명세의 `{ node: "0" }` 대신 `{}`. `versions.node` 가 있으면 흔한 라이브러리(압축·저장 플러그인 등)가 Node 환경으로 보고 브라우저에 없는 모듈(`buffer`·`zlib` 등)을 `require` 하기 때문. 엔진 판단(`Utils.isNwjs`)은 `require`·`process` 존재만 보므로 영향 없음.
- **`dataPathApp`:** MV 배포본의 `package.json` `name` 은 편집기 기본값("KADOKAWA/RPGMV", "rmmz-game" 등)인 경우가 많아 그런 이름(`MVMZProbe.genericPackageNames`)과 빈 이름은 건너뛰고 `System.json` `gameTitle` 로 간다. 시험한 MV 게임은 `name` 이 비어 `Adventure`, MZ 데모는 `gameId` 로 `mz-23209317`.
- **재개 때 시각 맞추기:** MV 는 `SceneManager._currentTime` 을 `performance.now()` 로(로그 `mv resume _currentTime gap=…`), MZ 는 `_currentTime` 이 없고 PIXI 틱커의 `deltaTime` 을 쓰므로 `_smoothDeltaTime = 1`·`_elapsedTime = 0` 으로 되돌린다(로그 `mv resume smoothDelta reset`). 빙수 재개 경로(`resume()`)가 `window.__bingsuResumeHook` 을 부른다.
- **`SceneManager.reloadGame`(F5) 은 `location.reload()`.** NW.js 의 `chrome.runtime.reload` 가 없어서.
- **소리:** MV 는 명세대로 `canPlayOgg = () => true`(로그 `via=polyfill`). MZ 는 건드리지 않았는데, 시뮬레이터는 `canPlayOgg` 가 참이라 `via=native` 로 고른 뒤 `decodeAudioData` 가 실패해 빙수 Ogg 폴리필(WASM 워커)이 푼다(`ogg native decode unsupported` → `ogg decoded …(worker)`). 게임 자체 `VorbisDecoder` 길은 시뮬레이터에선 안 탐. 실기기는 [미확인].
- **키 경로:** 키보드 전송 배치는 화면 설정 없이 디버그 환경 변수 `BINGSU_MV_KEYBOARD=1` 로만 고른다(기본은 게임패드). 키 대상은 `KEYS_TO_DOCUMENT` 일 때 `document`.
- **핸들러가 `save/` 읽기도 저장 폴더에서 한다:** `save/` 의 GET·HEAD·폴더 목록은 게임 폴더가 아니라 `Saves/<dataPathApp>/` 를 보고, 목록은 저장 이름 규칙에 맞는 것만. `MKCOL save` 는 폴더가 이미 있으니 201 만 돌려준다. 그 밖에 `.wasm` 은 `application/wasm`.
- **Windows 배포 찌꺼기 정리:** 가져올 때 맨 위의 `nw.pak`·`nw_100/200_percent.pak`·`natives_blob.bin`·`credits.html` 과, 안에 pak·dll 등만 있는 `locales`·`swiftshader`·`pnacl` 을 지운다(`Delivery.pruneWindowsBinaries`). 실행 파일에 묶인 게임은 `DeliveryError.packedInExe`.
- **업데이트 화면의 버전:** MV·MZ 는 `package.json` `version` 을 읽는다. 없으면 "버전 알 수 없음"(시험한 두 게임 모두 그랬다).
- **자가 테스트:** `GreenTeaSelfTest`(앱 시작, 33개: 쓰기 규칙 표 20줄·경로 거르기·분류·다른 호스트·암호 풀기 왕복·기본 이름·저장 이름) + `GlassBowl` 이 MV·MZ 를 열 때 웹뷰 안에서 `fs` 로 `save/` 밖 쓰기 8가지(`/index.html`·`/data/System.json`·`/save/../js/main.js`·`/save/notes.txt`·`/SAVE/x/file1.rpgsave`·`mkdir /img/new`·`unlink /js/main.js`·`rename → /data/System.json`)를 시도해 모두 거부되는지(`selftest mv write guard OK tried=8 leaked=[]`). 둘 다 `BINGSU_SELFTEST=1` 일 때만.
- **테스트 게임:** 암호화 배포본은 찾지 못해, MV 게임을 편집기와 같은 방식(헤더 16바이트 + 앞 16바이트 XOR)으로 직접 암호화한 시험본을 만들었다(실제 배포본 아님). MZ 암호화(`.png_`·`.ogg_`)는 시험하지 못했다.

## 12. 확인 결과 (2026-11-01, 시뮬레이터)

iPhone 17 Pro (iOS 26) 와 iPad Pro 13 (M5).

| 항목 | 결과 |
|---|---|
| MZ 가져오기·실행 (iPhone·iPad) | `recipe=rpgMakerMV engine=mz root=. saves=mz-23209317`, 타이틀 → 새 게임 → 맵, 패드 A 확인·Y 메뉴·십자키 이동. UA 데스크톱(`mobile=false nwjs=true`) |
| MV 가져오기·실행 (iPhone, Windows 배포 모양 `Adventure-win/www/`) | `engine=mv root=www dataPathApp=Adventure`, `Game.exe`·`nw.pak`·`locales` 정리됨, `require fs·path·nw.gui`, 소리 `ext=.ogg via=polyfill` |
| 저장 (MZ) | 첫 저장 PUT `file1.rmmzsave`·`global.rmmzsave`, 덮어쓰기 MOVE→`_` · PUT · DELETE `_` 순서. 파일은 `Saves/mz-23209317/` 에만, 게임 폴더엔 `save/` 없음 |
| 저장 (MV) | PUT `file1.rpgsave`·`global.rpgsave`, 덮어쓰기 PUT `.bak` → PUT → DELETE `.bak`. `Saves/Adventure/` 에만 |
| 이어하기 | MZ·MV 모두 재실행 → 이어하기에 파일 1(플레이 시간·파티) → 맵 |
| `save/` 밖 쓰기 | 8가지 모두 403 + `mv write denied` 로그(iPhone MZ·MV, iPad MZ) |
| PC 세이브 | `Adventure-enc/save/file1.rpgsave` 를 넣은 zip → "저장 파일 2개를 저장 데이터 폴더로 옮김" → 이어하기 바로 됨 |
| 업데이트 | 같은 zip 다시 가져오기(업데이트) → 저장 파일 해시 그대로, 업데이트 전 백업 생김 |
| 얼음틀 | 백그라운드·재실행 때 `파일 2개 → save.json`, iCloud 에서 받은 save.json → 파일 2개 |
| 가짜 iCloud | iPhone 저장 → iPad 에서 같은 zip 가져온 뒤 열기 → 내려받아 파일로 풀고 이어하기, iPad 에서 다시 저장 → iPhone 이 내려받음(3937B) |
| 재개 | MV `_currentTime gap=259ms`, MZ `smoothDelta reset`. 홈에 다녀와도 급가속 없음 |
| 키보드 경로 | `BINGSU_MV_KEYBOARD=1`: A → `KeyZ`, B → `KeyX`, 대상 `document`, 불러오기 화면 열고 닫힘 |
| 암호화·대소문자 | 직접 만든 암호화 MV(`.rpgmvp`·`.rpgmvo`, 파일 이름 `castle.rpgmvp`·`ACTOR1.rpgmvp` 로 대소문자 바꿈): 게임칩 표지가 풀린 타이틀 그림, 타이틀·맵·캐릭터 그림 정상 |
| 회귀 | 레조넌스 타이틀·저장 복원(`restore=file-changed`), 포켓로그 로딩·패드 표시·로그인 화면까지(로그인 뒤는 확인 못 함). XP·VX 게임은 실행해 보지 않음(바뀐 곳은 `IceTray` 확장자 고르기뿐이고 XP·VX 값은 그대로) |
| 자가 테스트 | `[GreenTea] selftest OK 33/33`, Spoon·Igloo 자가 테스트 그대로 통과 |
| 메모리 (iPad, MZ 맵에 세워 두고 8분, 호스트에서 `ps` RSS 1분마다) | 앱 276→142MB, 웹 콘텐츠 프로세스 249→137MB 로 줄어든 뒤 4분부터 평평(137~145MB). 쌓임 없음. 배경음악이 한 곡뿐인 작은 데모라 큰 게임·실기기는 따로 봐야 함. `audiomix` 로그는 이 경로에서 안 나옴 |
| 하지 못한 것 | MV 를 iPad 에서 실행(iPhone 만), 실기기, 실제 암호화 배포본, MZ 암호화 |

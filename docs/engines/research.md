# RPG Maker VX · VX Ace · MV · MZ 실행 조사

작성 2026-11-01 · 조사만 했고 코드는 바꾸지 않았다 · 로드맵 순서(2026-10-31 사용자 결정): VX/VX Ace 먼저 → MV/MZ

표기: **[확인]** 소스·파일을 직접 읽어 확인 · **[문서]** 공개 문서·스토어 설명에 적힌 것 · **[추정]** 근거는 있으나 돌려 보지 않음 · **[미확인]** 확인하지 못함.
경로가 `~/Dev/vendor/...` 인 파일은 저장소 밖에 받아 둔 포크·참고 소스(커밋하지 않음)다. `mvmz-apple-mobile` 은 이번 조사 때 세션 임시 폴더에 받아 읽기만 했다(커밋 `64f0e22`, 2026-10-19).

---

## 요약 (한 화면)

**VX / VX Ace — 엔진은 이미 준비돼 있고, 빙수 쪽 연결만 남았다.**
- 지금 앱에 들어가는 `BrassBowl.framework`(포크 v9, `68efcd3`)에 Ruby 1.8·1.9·3.1 이 모두 들어 있고(`_mkxp_get_script_binding_18/19/31`), `.rgss2a`·`.rgss3a` 아카이브 해제, RGSS2/3 판별(`Scripts=` 확장자), 544×416 기본 해상도, VX·VX Ace 용 `RPG` 모듈 미리 불러오기(`rpg_vx.rb`·`rpg_vxace.rb`)가 들어 있다. **엔진을 다시 빌드할 필요는 없다** [확인].
- 막히는 곳은 빙수 코드 다섯 군데다 [확인]: ① `RecipeDetector` 가 `Scripts.rxdata` 만 보고 `.rvdata2`·암호화 아카이브를 못 알아봄 → "지원하지 않는 게임" ② `RubyProfile` 이 mkxp.json 없는 게임을 모두 Ruby 1.8 로 돌림 → VX Ace(원래 Ruby 1.9)는 19 로 ③ 키 배치 `CutlerySet.rpgMakerXP` 의 확인 버튼이 `C` 키인데 RGSS2/3 기본 배치에는 `C` 가 없음(확인은 `Z`) ④ VX/VX Ace 는 저장 파일(`Save01.rvdata2`)을 **게임 폴더에** 씀 → 지금 얼음틀(`IceTray`)·iCloud 가 못 보고, 게임 업데이트 때 폴더째 바뀌어 **저장이 사라질 수 있음** ⑤ 화면 비율 4:3 고정(VX/Ace 는 544×416 = 약 1.31).
- 추가로 고를 것: MIDI 를 쓰는 일반 VX/Ace 게임은 사운드폰트가 없어 무음(기본 `.sf2` 동봉 필요), RTP 를 요구하는 게임(그림·소리를 게임에 안 넣은 게임)은 RTP 를 사용자가 따로 가져오게 할지.
- Win32API·DLL 은 포크의 `win32_wrap.rb` 가 자주 쓰는 함수(키 상태·마우스 위치·창 찾기·레지스트리·WinINet·Winsock 등)를 흉내 내고, 모르는 호출은 0 을 돌려주고 로그만 남긴다. 외부 DLL(FMOD Ex 등)은 못 쓴다.

**MV / MZ — 지금 웹 러너(`GlassBowl`) 위에 "NW.js 흉내"를 얹는 방식이 검증된 길이다.**
- 같은 포크 작성자의 `mvmz-apple-mobile`(GPLv3+추가 조건)이 정확히 이 구조다: WKWebView + 커스텀 스킴 + 368줄 `runtime.js` 가 `require('fs'|'path'|'os'|'nw.gui')`·`process` 를 만들어 주고, fs 호출을 **동기 XHR → 스킴 핸들러의 PUT/DELETE/MKCOL/MOVE** 로 바꿔 저장을 게임 폴더 `save/` 에 파일로 쓴다 [확인].
- MV/MZ 엔진은 `typeof require === "function" && typeof process === "object"` 로만 NW.js 여부를 판단한다. 흉내를 안 내면 MV 는 `localStorage`(`RPG File1` 같은 키), MZ 는 **IndexedDB**(localforage, `rmmzsave.<gameId>.<이름>`)에 저장한다 [확인]. 지금 냉동실(`Freezer`)은 localStorage 만, 그것도 `bingsu.`/`rcb.` 로 시작하고 공백 없는 키만 받으므로 **둘 다 그대로는 못 담는다** → 파일 저장 방식(흉내) + 얼음틀 확장을 권장.
- 빙수 웹 러너에서 고칠 것 [확인]: 스킴 핸들러가 Electron 모양(`dist/`·`assets/`)만 서빙하고 GET/HEAD 외는 405 · 키 입력을 `window` 로 보내는데 MV/MZ 는 `document` 에서 듣는다 · 로컬 게임에 아이폰 UA 를 그대로 둠(MV 는 모바일 UA 면 `.m4a` 를 찾는데 PC 판에는 대개 없음) · `index.html` 단독 판별이 MZ·MV 웹 배포판을 Electron 으로 오판.
- 그대로 쓸 수 있는 것 [확인]: 가상 Gamepad(MV/MZ 가 `navigator.getGamepads()` 를 폴링, 표준 배치 0=확인·1=취소·2=대시·3=메뉴), `document.hasFocus()` 덮어쓰기(MZ 가 이걸로 멈춤 판단), Ogg Vorbis WASM 폴리필, rAF 기반 프레임 제한·일시정지.
- 암호화 리소스(`.rpgmvp`·`.png_` 등)는 **게임이 스스로 푼다**(키는 `System.json`) — 앱은 표지 그림을 뽑을 때만 풀면 된다.

**RPGPlayer (App Store, $6.99)** [문서]: XP·VX·VX Ace 는 MKXP-Z, MV·MZ 는 "custom web wrapper". ZIP·RAR·7z 를 Files 에서 가져오고, RTP 자동 연결, 게임별 가상 패드 배치 저장, 컨트롤러 연결 시 패드 숨김, 끌어 옮기는 게임 안 도구 막대. 스토어 설명에 GPL·소스 공개 언급은 없고 공개 저장소도 찾지 못함 → GPL 준수 방식은 **[미확인]**.

**권장 첫 PoC (반나절):** 빙수 코드에서 VX Ace 판별 + Ruby 19 + RGSS3 키 배치 세 군데만 바꿔, VX Ace Lite(공식 무료판)로 만든 빈 프로젝트를 시뮬레이터에서 타이틀 → 새 게임 → 저장까지. 저장 파일이 게임 폴더에 생기는지 눈으로 확인 → 다음 PoC(저장 위치)의 근거.

---

## 0. 지금 빙수 러너 (읽은 파일)

| 항목 | 지금 상태 | 출처 |
|---|---|---|
| 엔진 판별 | Electron(`dist/index.html`+`assets`, `resources/app.asar`) → mkxp(`mkxp.json` 또는 `Game.ini`+`Data/Scripts.rxdata`) → MV(`package.nw`·`nw.pak`·`www/index.html`) → `index.html` 단독은 Electron | `BingsuApp/Bingsu/Shaver/RecipeDetector.swift:10-17` |
| MV 판별 결과 | `.rpgMakerMV` 는 `servable == false` → 목록에만 오르고 못 엶 | `BingsuApp/Bingsu/MenuBoard/Dish.swift:5-28` |
| XP 러너 | `BrassBowl.framework` 를 dlopen, `mkxp_setSetting("rubyVersion"/"syntaxTransform"/…)`, 저장 폴더 `Saves/<dataPathApp>/` 를 `mkxp_setUserDataDirectory`, 게임 mkxp.json 을 `mkxp_setManagedConfigDir`, `preloadScript` 는 `mkxp_setConfigOverlayJSON` 으로 덧붙임 | `BingsuApp/Bingsu/BrassBowl/BrassBowlEngine.swift:118-170, 336-366` |
| Ruby 고르기 | mkxp.json 이나 `x64-msvcrt-ruby3*` DLL 이 있으면 31+modern, 아니면 18+legacy | `BrassBowlEngine.swift:585-595` |
| XP 키 배치 | A=`C`, B=`X`, X=`Z`, Y=`D`, L=`A`, R=`S`, 배속=`Q` (Essentials 기준) | `BingsuApp/Bingsu/BrassBowl/CutlerySet+XP.swift` |
| XP 화면 | 4:3 고정 | `BrassBowlContainerView.swift:54-55` |
| 저장 묶기 | 얼음틀이 `Saves/<dataPathApp>/` 의 `rxdata·rvdata·rvdata2·dat·sav·bak·ini·txt·json5` 를 save.json 으로 묶어 백업·iCloud | `BingsuApp/Bingsu/Freezer/IceTray.swift:3-17` |
| 웹 러너 | WKWebView, 게임별 영구 `WKWebsiteDataStore`, 문서 시작 때 Ogg Vorbis WASM 폴리필·냉동실·온도계·가상 패드 스크립트 주입 | `BingsuApp/Bingsu/Bowl/GlassBowl.swift:24-112`, `Bowl/BowlScripts.swift` |
| 스킴 핸들러 | `pokemon://game/…` → `dist/` 또는 `assets/` 만, GET/HEAD 외 405, 경로 검사(`..`·`\`·`:`·숨김 파일 차단), Range 206 | `Bowl/PokemonSchemeHandler.swift:25-91` |
| 가상 패드(웹) | `navigator.getGamepads()` 에 Xbox 360 이름의 표준 배치 패드를 끼움 + `__bingsu.key(code)` 가 KeyboardEvent 합성(대상: `document.activeElement` 가 body 면 `window`) | `BowlScripts.swift:232-283` |
| 냉동실 키 규칙 | 접두어 `rcb.`(레조넌스) 또는 `bingsu.` + `[A-Za-z0-9_.-]` | `Freezer/Freezer.swift:43, 105-110` |
| 게임 업데이트 | 새 폴더로 통째로 바꾸고 옛 폴더는 지움(선택 시 보관). 바꾸기 전 `Freezer.freeze()` 백업 | `Shaver/Delivery.swift:250-275` |

---

## 1. VX / VX Ace on mkxp-z

### 1.1 엔진이 지원하는 범위 [확인]

| 항목 | 내용 | 출처 |
|---|---|---|
| RGSS 버전 | `rgssVersion` 0~3(0 = 자동). 자동이면 `Game.ini` 의 `Scripts=` 확장자로: `.rvdata` → 2, `.rvdata2` → 3, 그 밖 1 | `~/Dev/vendor/mkxp-z-apple-mobile/src/config.cpp:164, 436, 584-600` |
| 기본 해상도 | RGSS1 640×480, RGSS2/3 544×416 (`defScreenW/H` 를 따로 주지 않으면). 게임이 `Graphics.resize_screen` 으로 바꿀 수 있음(VX Ace 에서 640×480 으로 넓히는 스크립트가 흔함 [추정]) | `config.cpp:449-455` |
| 암호화 아카이브 | 버전별 이름 `Game.rgssad`/`Game.rgss2a`/`Game.rgss3a` 를 열고, RGSSAD v1(XP·VX)과 RGSS3A(Ace) 형식 둘 다 읽음 | `src/sharedstate.cpp:56-66`, `src/crypto/rgssad.cpp:379, 588-675` |
| Ruby | 한 바이너리에 1.8.8·1.9.3·3.1.3. 호스트가 `rubyVersion` 으로 고름. legacy 변환 설명: "Ruby 1.9 for RGSS3, Ruby 1.8 for RGSS<3" | `src/app_bridge.h:140-175, 480-490`, empo `ios/Empo/docs/multi-ruby.md` |
| RPG 모듈 | `RPG::Map` 등 데이터 클래스를 버전별 미리 불러오기 스크립트로 정의(`rpg_xp.rb`/`rpg_vx.rb`/`rpg_vxace.rb`) | `scripts/preload/` |
| 기본 키 | 공통: 방향키, Space·Enter=C(확인), Esc·X·Num0=B(취소), Shift=A, A=X, S=Y, D=Z, Q=L, W=R. **RGSS1 만** Z=A·C=C, **RGSS2/3 은** Z=C | `src/input/keybindings.cpp:68-118, 157-165` |
| 소리 | SDL_sound(OGG·WAV·MP3 등) + MIDI 는 FluidSynth(빙수가 정적으로 넣음). 사운드폰트 기본값은 빈 문자열(`midiSoundFont: ""`) | `deps/common.make:328-345`, `config.cpp:207` |
| 동영상 | Ogg Theora 만. MP4 오프닝은 말없이 건너뜀 | empo `docs/troubleshooting.mdx`, `docs/requirements.mdx` [문서] |
| RTP | `mkxp.json` 의 `"RTP": [경로…]` 를 파일 시스템 검색 경로에 추가 | `config.cpp:217, 410`, `sharedstate.cpp:154-155` |
| 저장 위치 | **게임 폴더 안 쓰기는 그대로(literal)**. 엔진의 `UserData`(빙수가 지정하는 `Saves/<dataPathApp>/`)는 게임이 `System.data_directory` 등으로 직접 가리킬 때만 쓰임 → 일반 VX/Ace 의 `Save01.rvdata2` 는 게임 폴더에 생김 | `scripts/preload/windows_fs.rb:79-130, 185-240` |
| 대소문자 | Windows 처럼 대소문자 무시 경로 흉내 | `windows_fs.rb` 머리 주석 |

empo(같은 작성자의 런처)는 이 코어로 "RPG Maker XP, VX, VX Ace" 를 지원한다고 적고, Ruby 고르는 규칙을 이렇게 둔다 [문서]: 번들 Ruby DLL → 스크립트 문법 훑기 → 아카이브 확장자(`.rgssad`·`.rgss2a` → 18, `.rgss3a` → 19) → `Game.ini Library=`(`RGSS1*`/`RGSS2*` → 18, `RGSS3*` → 19) → 기본 31 (`ios/Empo/docs/multi-ruby.md` "Detection").

### 1.2 XP 와 다른 점

| | RPG Maker XP (RGSS1) | VX (RGSS2) | VX Ace (RGSS3) |
|---|---|---|---|
| 스크립트 파일 | `Data/Scripts.rxdata` | `Data/Scripts.rvdata` | `Data/Scripts.rvdata2` |
| 암호화 아카이브 | `Game.rgssad` | `Game.rgss2a` | `Game.rgss3a` (형식이 다름) |
| `Game.ini Library=` | `RGSS10xE.dll` | `RGSS20xJ/E.dll` | `System\RGSS30x.dll` |
| 원래 Ruby → 빙수에서 쓸 값 | 1.8 → `18`(Essentials 신판은 `31`) | 1.8 → `18` | 1.9.2 → **`19`** |
| 기본 해상도 | 640×480 (Essentials 는 512×384 로 바꿈) | 544×416 | 544×416 |
| 확인 키(엔진 기본) | C·Space·Enter | **Z**·Space·Enter | **Z**·Space·Enter |
| 저장 파일(기본 스크립트) | `Save1.rxdata`(게임 폴더) | `Save1.rvdata` | `Save01.rvdata2` |
| 기본 글꼴 | RTP 없음(시스템 글꼴) | RTP `UmePlus Gothic` [추정] | RTP `VL Gothic` [추정] |
| 동영상 | 없음 | 없음 | `Graphics.play_movie`(.ogv) |

- 글꼴: 엔진은 게임 `Fonts/` → 공용 글꼴(빙수가 넘기는 `Assets.bundle/Fonts`: `liberation.ttf`, `wqymicrohei.ttf` — 후자에 한글 포함 [추정]) 순으로 찾는다. 기본 이름이 없으면 대체 글꼴로 그린다(`src/display/font.cpp:845, 958`).
- `Game.ini` 제목: 일본 게임은 Shift-JIS, 한글판은 CP949 인 경우가 많다 [추정]. 엔진은 인코딩을 따로 판별하지만(`config.cpp` "Could not determine encoding of Game.Title"), 빙수 `RecipeDetector.iniTitle` 은 UTF-8 로만 읽어 실패하면 폴더 이름이 제목이 된다 [확인].
- 저장 형식은 Marshal 이라 PC 세이브와 바이트 그대로 호환(XP 와 같음) [추정].

### 1.3 지금 BrassBowl 빌드에 RGSS2/3 가 켜져 있나 → **켜져 있다** [확인]

- mkxp-z 는 RGSS 버전을 빌드 플래그가 아니라 **실행 중에** 고른다. 소스에 `#ifdef RGSS2` 같은 분기가 없고 `rgssVer` 실행 값 분기만 47곳(`grep` 결과).
- 앱에 들어가는 `BingsuApp/build/BrassBowl/iphonesimulator/BrassBowl.framework`:
  - `nm` → `_mkxp_get_script_binding_18`, `_19`, `_31` 셋 다 있음 (`build-framework.sh:35, 60` 이 `mkxp18/19/31-merged.o` 를 모두 링크)
  - `strings` → `.rvdata2`, `.rgss3a`, `RGSS3A`, `RGSS version %d (RPG Maker %s)`
  - `Ruby/1.8`, `Ruby/1.9.1`, `Ruby/3.1.0` 표준 라이브러리, `Assets.bundle/Preload/rpg_vx.rb`·`rpg_vxace.rb`·`win32_wrap.rb`·`windows_fs.rb` 들어 있음
- empo 는 프레임워크 `Info.plist` 에 `EmpoCoreRGSSVersionMask`(3 = RGSS1·2, 7 = RGSS3 까지)를 적어 가져오기 때 거른다(`ios/Empo/src/Cores/Mkxp/MkxpCore.swift:13-40`). 빙수 빌드는 1.9 가 있으므로 7 에 해당.

### 1.4 빙수 쪽에서 바꿔야 할 곳 [확인]

| # | 파일 | 지금 | 바꿀 것 |
|---|---|---|---|
| 1 | `Shaver/RecipeDetector.swift:13` | `Game.ini` + `Data/Scripts.rxdata` 만 | 1.6 의 단서 표 전부. 암호화 XP(`Game.rgssad`)도 지금은 못 알아봄 |
| 2 | `BrassBowl/BrassBowlEngine.swift:589-595` `RubyProfile` | mkxp.json 없으면 18+legacy | RGSS3 → `19`+legacy, RGSS2 → `18`+legacy. 사용자 덮어쓰기(이 게임 설정)도 empo 처럼 두면 좋음 |
| 3 | `BrassBowl/CutlerySet+XP.swift` | A=`KeyC` | RGSS2/3 용 배치 새로: A=`KeyZ`(또는 Enter), B=`KeyX`, X=`KeyA`, Y=`KeyS`, Z=`KeyD`, L=`KeyQ`, R=`KeyW`, 대시=Shift. 꼬리표도 "확인/취소/대시/메뉴" 로 |
| 4 | `Freezer/IceTray.swift` + `Shaver/Delivery.swift:250-275` | 얼음틀은 `Saves/<dataPathApp>/` 만 봄, 업데이트는 게임 폴더를 통째로 교체 | (a) 엔진 쪽: 빙수 preload 스크립트로 `Save\d+\.rvdata2?` 경로를 `System.data_directory` 로 돌리기(이미 소리 크기용 preload 를 넣는 자리가 있음, `BrassBowlEngine.swift:336-366`), 또는 (b) 빙수 쪽: 얼음틀이 게임 폴더 맨 위의 저장 파일도 묶고 업데이트 때 옮겨 심기. **(a) 가 PC 세이브 넣기·iCloud 가 XP 와 같은 길이라 단순**. 다만 일부 게임은 `Save` 이름을 바꾸므로 [추정] 확장자 기준 + 게임 폴더 맨 위로 한정 |
| 5 | `BrassBowl/BrassBowlContainerView.swift:54` | 4:3 | 엔진이 알려 주는 게임 크기(`mkxp_getGameWindow`·게임 영역 콜백, `docs/phase3-mkxp-poc.md` 4.1)로. 최소한 RGSS2/3 은 544:416 |
| 6 | MIDI | 게임 `mkxp.json` 의 `midiSoundFont` 만 | 일반 VX/Ace 는 mkxp.json·sf2 가 없음 → 빙수가 기본 GM 사운드폰트를 동봉하고 오버레이 JSON 으로 넘김. 후보(라이선스 확인 필요 [미확인]): GeneralUser GS, FluidR3_GM(MIT 로 알려짐), TimGM6mb(GPL-2, 6MB 안팎) |
| 7 | RTP | 없음 | `Game.ini RTP=RPGVXAce` 인데 `Graphics/`·`Audio/` 가 비었으면 시작 전 안내. 사용자가 RTP 폴더를 가져오면 오버레이 JSON `"RTP": [경로]`. RTP 설치 파일은 Windows exe 라 빙수가 풀어 주기는 어렵다(zip 으로 된 RTP 를 받게 안내) [추정] |
| 8 | 화면 문구 | "RPG Maker XP 게임은…" 등 엔진 이름이 화면에 나옴 | PLAN 7장 "엔진은 사용자에게 보여주지 않는다" 와 어긋남. VX 를 붙일 때 "이 게임은…" 같은 중립 문구로 |

나머지(dlopen, 저장 폴더 지정, 볼륨·온라인 preload, 가상 패드 → `mkxp_injectKeyEvent`, 일시정지, 한 프로세스 1게임 안내)는 XP 와 그대로 쓴다.

### 1.5 일반 VX Ace 게임 스크립트가 iOS 에서 막히는 것과 우회

포켓몬 에센셜이 아닌 일반 VX Ace 게임은 커뮤니티 스크립트(Yanfly Ace Engine, Victor, Galv, Hime 등)를 많이 쓴다. 대부분 순수 Ruby 라 문제없고, 막히는 것은 Windows 에 닿는 부분이다.

| 쓰임 | 흔한 호출 | iOS 에서 | 출처 |
|---|---|---|---|
| 전체 화면·창 크기 | `keybd_event`(Alt+Enter), `GetSystemMetrics`, `SetWindowPos`, `FindWindow` | `Keybd_event`·`FindWindowA/Ex`·`GetForegroundWindow`·`GetClientRect` 흉내. 나머지는 0 → 대개 무해 | `scripts/preload/win32_wrap.rb` 클래스 목록 [확인] |
| 전체 키보드·단축키 | `GetKeyState`, `GetAsyncKeyState`, `GetKeyboardState`, `MapVirtualKey`, `ToUnicode` | 흉내(SDL 키 상태에서 읽음) → 빙수가 주입한 키가 그대로 보임 [추정] | 같은 파일 |
| 마우스 | `GetCursorPos`, `ScreenToClient`, `ShowCursor` | 흉내. 단 빙수는 `mkxp_setTouchMouseEnabled(false)` → 마우스로 하는 게임은 이 게임 설정에서 켜야 함 | `win32_wrap.rb`, `BrassBowlEngine.swift:148` [확인] |
| ini 읽기 | `GetPrivateProfileString`(언어·옵션) | 흉내 목록에 **없음** → 0·빈 문자열 → 기본값으로 감 [추정] | 같은 파일(목록에 없음) [확인] |
| 레지스트리 | `RegOpenKeyEx`, `RegQueryValueEx` | 흉내 | 같은 파일 |
| 인터넷 | WinINet(`InternetOpenUrl`, `HttpSendRequest`, `URLDownloadToFile`), Winsock | Ruby `socket`·openssl 로 흉내. 빙수 "온라인 허용" 설정을 따름 | 같은 파일, `docs/phase3-mkxp-poc.md` 2장 |
| 소리 확장 | FMOD Ex(`fmodex.dll`), Audio 위치 읽기 스크립트 | DLL 못 씀 → `load_module` 는 아무것도 안 함, 이후 상수 참조 오류는 엔진이 넘김 → 기본 Audio 로 떨어지거나 소리 없음 [추정] | `win32_wrap.rb:22-37` |
| 그 밖 DLL | 암호화 해제기, 이미지·영상 DLL, 스크린샷 저장 | 못 씀. 모르는 Win32API 는 `TOLERATE_ERRORS = true` 로 0 을 돌려주고 로그 한 줄 | `win32_wrap.rb:1559-1614` [확인] |
| 저장 미리보기·DLL 낀 플러그인 | 스크린샷 PNG 저장, 창 정보 | JoiPlay `postload.rb` 일부를 옮긴 무력화 스크립트 | `scripts/postload/rgss_plugin_stubs.rb` |
| 동영상 | `.mp4`/`.wmv` 오프닝 | 건너뜀(검은 화면) | empo `docs/troubleshooting.mdx` [문서] |
| 대화창 | `msgbox`(RGSS3 내장) | 엔진이 RGSS3 에서 제공 | `rgss_plugin_stubs.rb` 주석 |

우회 원칙(제안): ① 엔진의 흉내·무력화 스크립트를 먼저 믿고 ② 실패는 로그(`BINGSU_MKXP_LOG=1`)로 함수 이름을 모아 ③ 정말 흔한 것만 빙수 preload 로 덧붙인다. empo 는 이 밖에 "JoiPlay 호환"(`$joiplay = true`) 토글을 둔다(`app_bridge.h` `mkxp_setJoiplayCompat`, 빙수는 `mkxp_setSetting("joiplayCompat", …)` 으로 같은 것을 켤 수 있음).

### 1.6 가져오기 판별(`RecipeDetector`)에 더할 단서

empo `MkxpCore.isGameRoot`(`*.ini` 의 `Scripts=` 또는 아카이브)·`MkxpProfile.rgssVersion` 과 엔진의 판별을 합친 표:

| 순서 | 단서 | 판정 |
|---|---|---|
| 1 | `mkxp.json`(지금처럼) — 안에 `"rgssVersion": n` 이 있으면 그 값 | mkxp, 그 RGSS |
| 2 | 맨 위에 `Game.rgss3a` | VX Ace, Ruby 19 |
| 3 | 맨 위에 `Game.rgss2a` | VX, Ruby 18 |
| 4 | 맨 위에 `Game.rgssad` | XP, Ruby 18(또는 31 — 번들 Ruby DLL 이 있으면) |
| 5 | 맨 위의 `*.ini`(이름이 exe 와 같게 바뀐 경우가 있음) 에 `Scripts=…rvdata2` / `…rvdata` / `…rxdata` | Ace / VX / XP |
| 6 | `Data/Scripts.rvdata2` / `.rvdata` 만 있음(ini 없음) | Ace / VX |
| 7 | `Game.ini Library=` 의 `RGSS3`/`RGSS2`/`RGSS1` | 보조 |
| 8 | `Game.ini RTP=RPGVXAce`(또는 `RTP1=`) 인데 `Graphics/System` 이 없음 | 실행 전 RTP 안내 |

- `Game.ini` 를 읽을 때 CRLF·Shift-JIS/CP949 를 고려(지금 `mkxp.json` CRLF 버그를 고친 것과 같은 종류).
- 게임 폴더가 zip 안 한 단계 아래(`MyGame/Game.exe`)인 경우는 기존 가져오기가 처리하는지 확인 필요 [미확인].
- `Dish.Recipe` 는 `.mkxp` 하나로 두고 RGSS 버전·Ruby 는 실행 때 다시 판별해도 된다(지금 `RubyProfile.detect` 와 같은 자리).

---

## 2. MV / MZ in WKWebView

### 2.1 게임 폴더 모양

| | MV (Windows 배포) | MZ (Windows 배포) | 웹 배포(MV·MZ) |
|---|---|---|---|
| 게임 루트 | `www/` (`index.html`, `js/rpg_core.js` …) | 맨 위 (`index.html`, `js/rmmz_core.js` …) [추정 — `package.json` 의 `main` 으로 확인 권장] | 맨 위 |
| NW.js 흔적 | `Game.exe`·`nw.pak`·`package.json`(`main: "www/index.html"` [추정]) | 같음 | 없음 |
| 데이터 | `www/data/System.json` | `data/System.json` | 같음 |
| 저장(PC) | `www/save/file1.rpgsave`, `global.rpgsave`, `config.rpgsave` | `save/file1.rmmzsave`, `global.rmmzsave`, `config.rmmzsave` | 브라우저 저장소 |

- `package.nw`(zip)로 묶은 게임은 풀어서 쓰면 된다(기존 `SafeUnzip`). Enigma Virtual Box 같은 도구로 exe 하나에 넣은 게임은 풀 방법이 없어 지원 불가로 안내 [추정].
- 대소문자: Windows 에서 만든 게임은 파일 이름 대소문자가 코드와 다른 경우가 많다. `mvmz-apple-mobile` 의 `MvmzFileServer.m` 은 없는 경로 조각을 대소문자 무시로 다시 찾는다 [확인]. 지금 `PokemonSchemeHandler` 에는 이 처리가 없다.

### 2.2 Node 의존 — 엔진이 어떻게 판단하나 [확인]

- MV `rpg_core.js` 와 MZ `rmmz_core.js` 둘 다 `Utils.isNwjs = () => typeof require === "function" && typeof process === "object"` (MV corescript `js/rpg_core/Utils.js:61-63`, MZ `js/rmmz_core/Utils.js:72-74`).
- `StorageManager.isLocalMode()` 가 곧 `Utils.isNwjs()`. 참이면 fs 로 파일 저장, 거짓이면 브라우저 저장소. **엔진 자체에는 localStorage/IndexedDB 폴백 경로가 이미 있다.**
- 그 밖 엔진 안의 NW.js 사용: 창·메뉴·개발자 도구(`require('nw.gui')`), `chrome.runtime.reload`, `process.mainModule.filename`(저장 폴더 계산). 흉내 안 내면 이 부분은 그냥 건너뛴다(조건이 `isNwjs`).

그래서 길이 두 개다.

| | A. 흉내 안 냄 (브라우저 모드) | B. NW.js 흉내 (권장) |
|---|---|---|
| 저장 | MV: `localStorage` 키 `RPG File1`·`RPG Global`·`RPG Config`(+`bak`), LZString base64. MZ: localforage(IndexedDB) 키 `rmmzsave.<gameId>.<이름>`, pako 압축 | 게임 폴더 `save/` 에 PC 와 같은 파일. 스킴 핸들러가 쓰기를 받아 `Saves/<dataPathApp>/` 로 돌림 |
| 빙수 냉동실 | MV: 키에 공백이 있고 접두어가 달라 **지금 규칙에 걸림**(`Freezer.swift:105-110`). MZ: IndexedDB 라 **아예 안 보임** | 얼음틀 확장자에 `rpgsave`·`rmmzsave` 만 더하면 XP 와 같은 길(백업·iCloud) |
| PC 세이브 이어하기 | 불가(브라우저 저장소에 직접 넣어야) | 파일 그대로 넣으면 됨 |
| 엔진 코드 손댐 | 없음 | 문서 시작 스크립트(약 300줄) + 스킴 핸들러 쓰기 |
| 플러그인 호환 | `require` 를 쓰는 플러그인은 `isNwjs` 를 안 보고 부르면 깨짐 | 흉내 범위 안이면 됨 |

**B 의 구체 모양** (`mvmz-apple-mobile/src/runtime.js`, 368줄) [확인]:
- `window.require(name)` → `fs`·`path`·`os`·`nw.gui`(앞의 `node:` 떼고)만, 나머지는 `MODULE_NOT_FOUND`.
- `fs.*Sync` → **동기 XHR** 로 같은 출처 스킴에: `existsSync/statSync`=HEAD(`X-Mvmz-Kind`·`X-Mvmz-Mtime` 헤더), `readFileSync`=GET(바이너리는 `x-user-defined`), `writeFileSync`=PUT, `unlinkSync/rmdirSync`=DELETE, `mkdirSync`=MKCOL, `readdirSync`=디렉터리 GET → JSON, `renameSync`=MOVE+`Destination`. 콜백판(`fs.readFile` 등)은 `setTimeout` 으로 감쌈.
- `process` = `{ platform: "linux", env: {}, argv: [], cwd: () => "/", exit, on: noop, mainModule: { filename: "/index.html" } }` — 주석: MZ `main.js` 는 경로가 `/private/var` 로 시작하면 오류로 멈추므로 게임 폴더 기준 상대 경로여야 함.
- `nw.gui` = `App.quit/closeAllWindows` → 종료 메시지, `Window.get()` → 어떤 메서드든 아무것도 안 하는 Proxy, `Menu` 빈 클래스. `window.close` 도 종료.
- 사용자 에이전트를 **데스크톱 Safari** 로 고정(`mvmz_core.m:179-180`): "With the user agent of a phone, MV asks for .m4a audio that many desktop games do not ship, MV drops its fixed update rate, and MZ uses only 90% of the screen height" (원문 주석).

빙수에 옮길 때(제안):
- `PokemonSchemeHandler` 를 일반화하거나 MV/MZ 용 핸들러를 따로: 루트 = 게임 루트(`www/` 또는 맨 위), 대소문자 무시, 메서드 GET/HEAD 에 더해 **`save/` 아래에서만** PUT/DELETE/MKCOL/MOVE 허용, 확장자 허용 목록(`.rpgsave`·`.rmmzsave`·`.bak`·끝 `_`), 크기 상한(냉동실 16MB 와 같게), 실제 쓰기는 `Saves/<dataPathApp>/` 로. 나머지 쓰기는 403(+로그).
- 이는 PLAN 8.2 "웹 게임에 네이티브 파일 API 를 주지 않는다" 의 **예외**가 되므로 8.2 에 "MV/MZ 는 저장 폴더 한정 쓰기만" 을 문서로 남겨야 한다.
- 저장 폴더 이름(`dataPathApp`): MZ 는 `System.json` 의 `advanced.gameId`(MZ 전용 숫자), MV 는 `package.json` `name` 또는 `System.json` `gameTitle` [추정 — 필드 존재는 엔진 코드(`$dataSystem.advanced.gameId`)로 확인, MV 쪽 이름 규칙은 미정].

### 2.3 세이브 위치와 빙수 `Freezer` 연동

- B 로 가면: `save/file1.rpgsave` → `Saves/<dataPathApp>/file1.rpgsave`. 얼음틀(`IceTray.saveExtensions`)에 `rpgsave`·`rmmzsave` 를 더하면 묶기·백업·되돌리기·iCloud(`Igloo`)가 XP 와 똑같이 돈다. 게임 업데이트로 폴더가 바뀌어도 저장은 `Saves/` 에 있어 안전.
- MZ 의 저장 순서: 기존 파일을 `파일_` 로 옮기고 → 새로 쓰고 → `_` 지움(실패 시 되돌림) (`StorageManager.saveToLocalFile`) [확인]. 그래서 MOVE·DELETE 가 꼭 필요하고, 얼음틀이 끝이 `_` 인 임시 파일은 묶지 않아야 한다.
- MV 는 `.bak` 백업 파일을 씀(`StorageManager.backup`) [확인].
- A 로 가는 경우(대안): 냉동실에 "게임별 키 규칙"(MV: `^RPG (File\d+|Global|Config)(bak)?$`)과 IndexedDB 덤프(MZ)를 새로 만들어야 하고, 원격 웹 게임과 같은 영구 저장소 삭제 위험(PLAN 6장 "iOS 가 WebView 저장소 삭제")을 그대로 안는다 → 권장하지 않음.

### 2.4 오디오

| | MV | MZ |
|---|---|---|
| 형식 고르기 | `AudioManager.audioFileExt`: `WebAudio.canPlayOgg() && !Utils.isMobileDevice()` 면 `.ogg`, 아니면 **`.m4a`**. `canPlayOgg` 는 `<audio>.canPlayType('audio/ogg')` | `.ogg` 만. `!Utils.canPlayOgg()` 이고 `VorbisDecoder` 가 있으면 **게임 자체 WASM 디코더**(`libs/vorbisdecoder.js`)로 조금씩 풂 |
| 불러오기 | XHR arraybuffer → (암호화면 해제) → `decodeAudioData` | `file:` 이 아니면 `fetch` 스트리밍(`_startFetching`) |
| 출처 | MV corescript `js/rpg_managers/AudioManager.js:392-398`, `js/rpg_core/WebAudio.js:66-71, 123-129` | MZ `js/rmmz_core/WebAudio.js:388-420` |

- PC 판 MV 게임에는 `.m4a` 가 없는 경우가 많다(mvmz 주석) → **데스크톱 UA 로 `isMobileDevice` 를 거짓으로** 만들어야 `.ogg` 를 고른다. 그다음 `canPlayType('audio/ogg')` 가 iOS 에서 빈 문자열이면 다시 `.m4a` 로 가므로, 빙수 폴리필(`BowlScripts.oggVorbisPolyfill`, "OggS" 면 WASM 으로 풂)이 있는 한 `WebAudio.canPlayOgg = () => true` 로 덮는 것이 맞다 [추정 — 실기기 확인 필요].
- 반대로 mvmz 는 **시뮬레이터에서만** `canPlayOgg` 를 거짓으로 만든다: "The simulator says that it plays Ogg, then fails to decode it" (`runtime.js` runFrame). 실기기 WebKit 이 Ogg 를 직접 푸는지는 빙수 폴리필 주석("iOS WebKit 은 decodeAudioData 로 .ogg 를 못 풀기 때문에")과 엇갈림 → **[미확인]**, PoC 에서 실기기로 볼 것. 빙수 폴리필은 "기본 디코딩 먼저 → 실패하면 WASM" 순서라 어느 쪽이든 동작한다.
- MZ 는 `canPlayOgg` 가 거짓이면 자체 디코더를 쓰므로 빙수 폴리필과 겹칠 일이 적다. 참이면 `decodeAudioData` → 빙수 폴리필이 받는다.
- 암호화 소리(`.rpgmvo`, `.ogg_`)는 게임이 풀어 `decodeAudioData` 에 넘기므로 폴리필은 "OggS" 를 보게 된다 [추정].
- 포켓로그에서 겪은 배경음악 메모리 쌓임(빌드 23 `musicDiet`)은 MV 도 곡 전체를 `AudioBuffer` 로 푸는 구조라 같은 문제가 생길 수 있다 [추정] → 큰 게임에서 메모리 측정 필요.
- 소리 첫 재생: `mediaTypesRequiringUserActionForPlayback = []` 는 이미 켜져 있다(`GlassBowl.swift:27`).

### 2.5 WebGL / Canvas 성능

- MV 는 PixiJS v4, MZ 는 PixiJS v5 로 WebGL 우선(mvmz `engineDetails` 가 `Graphics._renderer` / `Graphics._app.renderer` 에서 WebGL 1/2·Canvas 를 읽음) [확인]. WKWebView 의 WebGL 은 Metal 위에서 돈다 [추정].
- 빙수 프레임 제한(rAF 묶기)은 MV(고정 1/60 초 누적)·MZ(`SceneManager.determineRepeatNumber` 로 한 프레임에 여러 번 갱신)와 잘 맞는다: 30 으로 묶어도 게임 속도는 유지 [추정, 코드 구조로 판단]. mvmz 는 같은 자리로 배속(`_deltaTime`·`determineRepeatNumber` 곱)을 만든다.
- 화질 "낮음"(`devicePixelRatio` 덮어쓰기)은 MV/MZ 가 캔버스를 게임 해상도로 만들고 CSS 로 늘리므로 효과가 없을 수 있다 [미확인].
- 웹 콘텐츠 프로세스 메모리 상한(PLAN 6장 1.5~2GB)과 텍스처 크기: 큰 게임·고해상도 플러그인에서 WebGL 컨텍스트가 날아갈 수 있다 [추정]. 기존 `webViewWebContentProcessDidTerminate` 처리와 Diag 기록을 그대로 쓰면 된다.
- 픽셀 아트 선명도: mvmz 는 "부드럽게" 끔이면 `canvas, video { image-rendering: pixelated; }` 를 넣는다 [확인].

### 2.6 터치 입력과 가상 패드

- **Gamepad 폴링** [확인]: MV/MZ `Input._pollGamepads` 가 매 프레임 `navigator.getGamepads()` 를 읽고 `gamepad.connected` 인 것만 쓴다. 표준 배치 `Input.gamepadMapper`: 0=ok, 1=cancel, 2=shift(대시), 3=menu, 4=pageup, 5=pagedown, 12~15=십자키. 왼쪽 스틱 축 0/1 은 임계값 0.5 로 방향(MZ `Input.js:281-320`, MV 도 같은 표). → 빙수 가상 Gamepad(`BowlScripts.swift:232-270`)가 **그대로 먹는다**. 빙수 A=0, B=1, X=2, Y=3 배치가 곧 확인·취소·대시·메뉴.
- **키보드 경로는 고칠 것** [확인]: MV/MZ 는 `document.addEventListener("keydown"…)` 로 듣는다(MZ `Input.js:236-238`). 빙수 `__bingsu.key` 는 포커스가 body 면 `window` 에 이벤트를 보내는데(`BowlScripts.swift:279-280`), `window` 에 보낸 이벤트는 `document` 로 내려가지 않는다. 키보드로 보내는 배치를 쓰려면 대상을 `document` 로. mvmz 는 `(document.activeElement || document)` 에 보낸다. MV/MZ `Input.keyMapper`: Enter·Space·Z=ok, Esc·X·Insert·Num0=escape, Shift=shift, Q/W=pageup/pagedown, 방향키, F9=debug — `keyCode` 를 본다(빙수는 이미 `keyCode` 를 박아 넣음).
- 둘 다 쓰면 두 번 눌림: mvmz 는 `navigator.getGamepads = () => []` 로 막고 모두 키로 보낸다. 빙수는 가상 Gamepad 를 기본으로 쓰고 키 경로는 보조로 두는 편이 기존 구조(실제 컨트롤러도 이 객체로 들어옴)와 맞다.
- **터치**: MV/MZ 는 `TouchInput` 으로 마우스·터치 이벤트를 직접 받아 탭 이동·메뉴 선택을 한다(엔진 기본 기능). 빙수의 `maxTouchPoints = 0`·`matchMedia` 데스크톱 위장은 MV/MZ 엔진 판단에 영향이 없다 [추정]. 패드가 덮지 않은 화면 영역의 탭은 게임으로 가야 하므로, 일시정지 버튼·패드 밖 터치를 웹뷰로 통과시키는지 확인할 것.
- **포커스**: MZ `SceneManager.isGameActive` 가 `window.top.document.hasFocus()` 가 거짓이면 갱신을 멈춘다 → 빙수가 이미 `Document.prototype.hasFocus` 를 참으로 덮어 둠(`BowlScripts.swift:212-214`) [확인].
- 새 입력 배치 `CutlerySet.rpgMakerMV`(제안): 전송 = 게임패드, A=확인, B=취소, X=대시, Y=메뉴, L/R=페이지. empo 기본 키도 B 를 Shift 로 바꾼다("MV and MZ read B as nothing, and Shift as dash", `MvmzCore.swift`).

### 2.7 암호화 리소스 [확인]

- MV: 그림 `.rpgmvp`, 소리 `.rpgmvo`, 영상 `.rpgmvm`. MZ: 원래 확장자 뒤에 `_`(`.png_`, `.ogg_`) — `WebAudio._realUrl` 이 `Utils.hasEncryptedAudio()` 면 `_` 를 붙임.
- `System.json` 의 `hasEncryptedImages`·`hasEncryptedAudio`·`encryptionKey` 를 엔진이 읽어 `Utils.decryptArrayBuffer`(MZ)/`Decrypter`(MV)로 **게임이 스스로 푼다**. 헤더 16바이트(`52 50 47 4d 56 00…`, "RPGMV") 확인 뒤 다음 16바이트를 키로 XOR.
- 앱이 할 일: 스킴 핸들러가 이 확장자들을 `application/octet-stream` 으로 내주기만 하면 됨(지금 기본값이 그렇다). 게임 목록 **표지**를 `img/titles1/` 에서 뽑을 때만 앱이 풀어야 한다(empo `MvmzGame.titlePicture` 가 같은 일).

### 2.8 플러그인의 Node 의존

- 엔진 자체 Node 사용은 2.2 의 것뿐이고 모두 `isNwjs` 로 감싸여 있다 [확인].
- Yanfly(MV)·VisuStella(MZ) 플러그인 소스는 **[미확인]**: VisuStella 는 유료·난독화 배포라 이번에 읽지 못했다(공개 사본 주소는 로그인 페이지만 돌려줌). 그래서 아래는 흔한 모양에 대한 대비책이다 [추정].
  - 데이터·텍스트 파일 읽기(`fs.readFileSync`, `fs.readdirSync`) → B 의 fs 흉내로 됨.
  - 외부 링크 열기(`require('nw.gui').Shell.openExternal`) → mvmz 흉내에는 `Shell` 이 **없다** → 빙수판에는 `Shell.openExternal(url)` → 네이티브로 넘겨 Safari(기존 외부 링크 규칙)로.
  - 창 크기·전체 화면·개발자 도구(`nw.Window.get().resizeTo/enterFullscreen/showDevTools`) → 아무것도 안 하는 Proxy 로 충분.
  - `process.env`·`process.platform` 분기 → 흉내 값으로 linux 경로.
  - 스크린샷 저장 플러그인 → `save/` 밖 쓰기라 403 → 플러그인이 예외를 잡는지는 게임마다 [미확인].
- 대응: `require` 실패·403 쓰기를 `bowl` 로그로 모아 게임별로 본다(빙수 Diag 와 같은 방식).

### 2.9 기존 iOS 포팅 사례

| 사례 | 무엇을 바꿨나 | 출처 |
|---|---|---|
| MV 공식 모바일 배포 + Cordova | MV 의 모바일 배포는 웹 파일만 내보내고 앱 포장은 개발자가 함. Cordova(ios 6+)는 WKURLSchemeHandler 로 `app://localhost` 같은 사용자 스킴에서 서빙해 `file://` XHR·CORS 문제를 피함. 이때 NW.js 가 없으니 브라우저 모드(localStorage, `.m4a`) | cordova-ios 6.0.0 공지, UIWebView 경고 안내 [문서]. MV 쪽 동작은 위 엔진 코드 [확인] |
| empo + mvmz-apple-mobile | 2.2·2.4·2.6 의 runtime.js(데스크톱 UA, fs→동기 XHR, `getGamepads` 끔, `hasFocus` 참, 일시정지 때 rAF 묶고 `WebAudio._context` suspend, 재개 때 `SceneManager._currentTime` 을 지금으로 맞춰 따라잡기 15회 막기), 대소문자 무시 파일 서버. MV/MZ 는 한 프로세스 1게임 제약이 없음 | `runtime.js`, `MvmzFileServer.m`, `mvmz_core.m`, empo `docs/faq.mdx`, `ios/Empo/docs/pause-resume.md` [확인] |
| RPGPlayer | "custom web wrapper". 저장을 `www/saves` 또는 `saves` 에 둔다는 버전 노트 → 파일 저장(=NW.js 흉내 계열)으로 보임 [추정] | App Store 버전 기록 [문서] |
| JoiPlay(안드로이드) | RPG Maker 플러그인이 MV/MZ 를 웹뷰로 돌림 — 세부는 비공개 [미확인] | — |

**라이선스**: `mvmz-apple-mobile` 과 empo 는 GPLv3 + 추가 조건(7조: 저작자 표시를 라이선스 화면에 같은 크기로·누를 수 있는 주소로, "Empo" 이름·아이콘 쓰지 않기). 빙수는 GPLv3 이라 가져다 쓸 수 있지만, 코드를 옮기면 "mvmz-apple-mobile, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/mvmz-apple-mobile" 을 오픈소스 라이선스 화면에 넣어야 한다(README "License"). 빙수는 이미 포크의 같은 조건을 지키고 있다(PLAN Phase 3 "GPL 준수"). **권장: 정적 라이브러리(`libmvmz.a`)를 끼우지 말고**, 빙수 `GlassBowl`·`BowlScripts` 구조에 맞춰 흉내 스크립트를 직접 쓰되 위 동작을 참고한다(빙수는 이미 WKWebView·스킴·패드·소리·일시정지를 갖고 있어 겹치는 부분이 대부분). 코드를 그대로 옮기는 부분이 생기면 표시를 넣는다.

---

## 3. RPGPlayer (App Store)

출처: App Store `id6754986970` 페이지(2026-11-01 조회), 검색 결과. 앱을 설치해 보지는 않았다.

| 항목 | 내용 | 구분 |
|---|---|---|
| 개발자·값 | Emir Han Temur, $6.99, 유틸리티, 81.7MB, iOS·iPadOS 17.6+, M1 Mac, visionOS | [문서] |
| 엔진 | XP·VX·VX Ace 는 MKXP-Z, MV·MZ 는 "custom web wrapper". 노트에 Pokémon Essentials·Win32API 게임 수정 언급 | [문서] |
| 가져오기 | Files 앱에서 ZIP·RAR, 2.2 에서 7z, 베타 노트에 암호 걸린 압축. 풀린 폴더 가져오기는 설명에 없음 | [문서] |
| RTP | XP/VX/Ace 의 RTP 를 "detected and linked automatically" | [문서] — 어떻게 RTP 를 얻는지는 [미확인] |
| 저장 | `RPGPlayer/games/{게임 이름}` 아래 `www/saves` 또는 `saves`(2.1), 자동 백업, "Backup All Saves"(2.2), 2.3 에서 저장 체계를 다시 써 바이트 그대로 백업. 앱 안 가져오기·내보내기는 "곧" (리뷰 답글) | [문서] |
| 패드·컨트롤러 | 바꿀 수 있는 가상 패드, 게임별 배치 저장, 컨트롤러 연결 시 패드 숨기기(2.0), 라이브러리·설정도 컨트롤러로 조작("Game Mode"/"UI Mode", 2.3), 끌어 옮기는 게임 안 도구 막대(설정·저장/불러오기), MKXP-Z 게임용 가상 키보드 | [문서] |
| 기타 | 일본어·중국어 글꼴 대체, 로그 첨부 문제 신고, 홈 화면 위젯, 저장 공간 관리 | [문서] |
| 평가 | 3.3/5 (94개). 저장 실패·입력 문제 리뷰가 있고 개발자는 고쳤다고 답함 | [문서] |
| 라이선스 | 설명·버전 기록에 GPL·오픈소스·소스 제공 언급 없음. 공개 저장소를 찾지 못함. 앱 안 라이선스 화면이 있는지 [미확인] | [미확인] |

같은 분야의 다른 앱: **Runa**(mkxp-z 기반 유료 앱, PLAN Phase 3 에 이미 기록), **QuestPlay**(MV·MZ 실행, 검색 결과로만 봄 [미확인]), **empo**(오픈소스, AltStore 배포, XP~MZ + PSDK).

**빙수에 참고할 점** (빙수 원칙 — 엔진 이름 숨김, Delta 식 구조 — 에 맞는 것만):
- 컨트롤러가 붙으면 패드 숨기기는 빙수도 이미 함. 라이브러리·설정을 컨트롤러로 다루는 "UI 모드"는 일시정지 화면 컨트롤러 조작(PLAN 9.3)과 이어지는 다음 단계.
- "게임 안 도구 막대에서 저장/불러오기" 는 RPG Maker 게임이 메뉴 저장만 지원하는 것(빙수 README 한계 항목)을 보완하는 기능 — mkxp-z 에는 저장 상태 기능이 없으므로 그대로 따라 하기는 어렵다 [추정].
- RTP 자동 연결은 일반 VX/Ace 게임에서 실제로 필요한 기능 → 1.4 의 7번.
- MKXP-Z 게임용 가상 키보드는 빙수에 이미 있음(이름 입력 글자 창).

---

## 4. 권장 순서와 공수

### 4.1 VX / VX Ace (먼저)

| PoC | 하는 일 (반나절 단위) | 끝났다고 볼 기준 |
|---|---|---|
| **V1** 판별·Ruby·키 | `RecipeDetector` 에 1.6 표 2~6번, `RubyProfile` 에 RGSS3 → 19, RGSS2/3 키 배치. 시뮬레이터에서 VX Ace 테스트 게임 | 타이틀 → 새 게임 → 걷기 → 메뉴 저장. 로그 "RGSS version 3 (RPG Maker VX Ace)", Ruby 1.9 |
| **V2** 저장 위치 | 빙수 preload 로 `Save*.rvdata2` 를 `System.data_directory` 로 돌리기(또는 얼음틀이 게임 폴더를 봄) + 게임 업데이트 뒤에도 남는지 | `Saves/<이름>/Save01.rvdata2` 생성, save.json 묶임, 게임 다시 가져오기(업데이트) 뒤 이어하기 |
| **V3** 화면·소리 | 544×416 비율, 기본 사운드폰트 오버레이, 암호화 `.rgss3a` 게임 | 레터박스 없이 꽉 참, MIDI BGM 소리, 아카이브 게임 실행 |
| **V4** RTP·VX | RTP 없는 게임 안내 + RTP 폴더 연결, VX(RGSS2) 게임 하나 | 안내 문구, RTP 연결 뒤 그림·소리 정상 |
| 실기기 | TestFlight 로 메모리·발열 | XP 와 같은 항목 |

**막힐 위험이 큰 곳**
- 저장 위치를 돌리는 preload 가 게임마다 다른 저장 스크립트(파일 이름·폴더를 바꾸는 커뮤니티 스크립트)와 부딪힘 [추정]. 실패 시 대안 (b)(얼음틀이 게임 폴더를 봄)로.
- Ruby 1.9 판으로 처음 돌리는 것: 포크가 1.9 로 실제 게임을 얼마나 돌려 봤는지는 empo 문서로만 안다 [문서]. 1.9 로 안 되면 31+legacy 로 바꿔 보는 사용자 설정을 둔다(empo 의 `rubyVersionOverride`).
- RTP 의존 게임이 많다면 RTP 연결 UX 가 사실상 필수 [추정].
- 한 프로세스 1게임 제약은 VX/Ace 도 같다(Ruby VM).

### 4.2 MV / MZ (다음)

| PoC | 하는 일 (반나절 단위) | 끝났다고 볼 기준 |
|---|---|---|
| **M1** 띄우기만 | 판별(`js/rmmz_core.js`·`js/rpg_core.js`·`data/System.json`, `package.json main` 으로 루트), 스킴 핸들러 루트를 게임 루트로, 데스크톱 UA. **흉내 없이**(브라우저 모드) | MZ·MV 각각 타이틀 → 새 게임, 가상 패드로 이동·메뉴. 소리 형식(.ogg/.m4a) 로그 |
| **M2** NW.js 흉내 + 저장 | `require`/`process`/`nw.gui`(+`Shell`) 흉내, 스킴 핸들러 `save/` 한정 쓰기 → `Saves/<이름>/`, 얼음틀 확장자 | `file1.rmmzsave`/`file1.rpgsave` 생성·이어하기, PC 세이브 넣어 이어하기, iCloud |
| **M3** 소리·입력 다듬기 | `canPlayOgg` 덮기 + 실기기에서 Ogg 직접 디코딩 여부, 키 경로 `document`, `CutlerySet.rpgMakerMV`, 일시정지 때 `SceneManager._currentTime` 맞추기 | 소리 끊김 없음, 일시정지 뒤 급가속 없음 |
| **M4** 표지·암호화 | 암호화 게임 표지 풀기, 대소문자 무시 경로 | 암호화 게임 목록 표지·실행 |

**막힐 위험이 큰 곳**
- 동기 XHR 로 PUT 본문을 스킴 핸들러가 받는 부분: mvmz 가 동작하는 것으로 보아 되지만 빙수 핸들러로 직접 확인 필요 [추정].
- 플러그인 Node 의존(2.8)은 게임을 돌려 봐야 안다.
- 큰 게임의 웹 프로세스 메모리(배경음악 `AudioBuffer`, 텍스처).
- MV 의 `.m4a` / `.ogg` 고르기가 실기기에서 어떻게 나오는지 [미확인].

### 4.3 테스트에 쓸 게임 (저작권 문제 없는 것만)

공개 라이선스(CC·MIT)로 나온 **완성 게임**은 이번 검색에서 찾지 못했다(자산 팩·플러그인만 나옴). 그래서 이렇게 권한다.

1. **직접 만든 작은 프로젝트 (가장 깨끗함)**
   - VX Ace: 공식 무료판 **RPG Maker VX Ace Lite** — 맵·이벤트 수 제한, 스크립트 편집 불가지만 `Scripts.rvdata2` 는 그대로 씀. 만든 게임은 판매 목적이 아니면 공개 가능(일본 보도). 기본 RTP 자산을 쓰므로 "RTP 포함" 배포 여부·RTP 없는 경우를 함께 시험할 수 있다. 다운로드: rpgmakerweb 의 free programs 페이지.
   - MV / MZ: 공식 체험판으로 빈 프로젝트를 배포(Windows/웹) — 체험판의 배포 기능 제한 여부 **[미확인]**. 체험판 기간이 끝나도 만든 배포 폴더는 남는다.
   - 시험용 장면(제안): 걷기·대화·전투 한 번·저장/불러오기·MIDI 또는 OGG BGM·암호화 배포 한 벌·한글 텍스트.
2. **작가가 무료로 배포한 프리웨어 — 로컬 시험용으로만**: 저장소·앱 번들·문서 스크린샷에 넣지 않는다(PLAN 8.1 과 같은 취급, `Games/` 는 이미 gitignore). 엔진 버전은 받아서 폴더로 확인할 것(위 1.6·2.1 표).
3. 포켓몬 팬게임은 이번 범위에서 시험 대상으로 삼지 않는다(닌텐도 IP — 기존 원칙대로 로컬에만).

---

## 5. 권장 PoC 순서 (한 줄씩)

1. **V1** VX Ace 판별 + Ruby 19 + RGSS3 키 → VX Ace Lite 테스트 게임 타이틀·저장 (반나절)
2. **V2** VX/Ace 저장 위치 `Saves/` 로 + 업데이트 뒤 보존 (반나절~1일)
3. **V3** 544×416 비율 · 기본 사운드폰트 · `.rgss3a` (반나절)
4. **V4** RTP 안내·연결 + VX(RGSS2) 한 개 (1일) → 실기기 TestFlight
5. **M1** MV/MZ 판별 + 스킴 루트 + 데스크톱 UA, 브라우저 모드로 띄우기 (반나절)
6. **M2** NW.js 흉내 + `save/` 쓰기 → 얼음틀·iCloud (1일)
7. **M3** 소리·키·일시정지 다듬기 (반나절~1일), **M4** 표지·암호화·대소문자 (반나절)

---

## 6. 참고 링크

**저장소 안 (읽은 파일)**
- `PLAN.md` 2.5·3.3·3.4·Phase 3·8장, `docs/phase3-mkxp-poc.md`, `BingsuApp/BrassBowl/README.md`, `BingsuApp/BrassBowl/build-framework.sh`
- `BingsuApp/Bingsu/BrassBowl/BrassBowlEngine.swift`, `BrassBowlContainerView.swift`, `CutlerySet+XP.swift`
- `BingsuApp/Bingsu/Shaver/RecipeDetector.swift`, `Shaver/Delivery.swift`, `MenuBoard/Dish.swift`
- `BingsuApp/Bingsu/Bowl/GlassBowl.swift`, `BowlScripts.swift`, `PokemonSchemeHandler.swift`
- `BingsuApp/Bingsu/Freezer/Freezer.swift`, `IceTray.swift`
- `BingsuApp/build/BrassBowl/iphonesimulator/BrassBowl.framework` (nm·strings·Info.plist, 빌드 산출물, 커밋 안 됨)

**저장소 밖 소스 (커밋 안 함)**
- mkxp-z iOS 포크 `~/Dev/vendor/mkxp-z-apple-mobile` (v9 `68efcd3`): `src/config.cpp`, `src/sharedstate.cpp`, `src/crypto/rgssad.cpp`, `src/app_bridge.h`·`.cpp`, `src/input/keybindings.cpp`, `src/display/font.cpp`, `scripts/preload/win32_wrap.rb`·`windows_fs.rb`, `scripts/postload/rgss_plugin_stubs.rb` — https://github.com/mateo-m/mkxp-z-apple-mobile
- empo `~/Dev/vendor/empo-app` (`4f56ca3`): `ios/Empo/docs/multi-ruby.md`·`cores.md`·`pause-resume.md`, `ios/Empo/src/Cores/Mkxp/MkxpCore.swift`, `ios/Empo/src/Cores/Mvmz/MvmzCore.swift`, `cores/mvmz/*`, `docs/faq.mdx`·`requirements.mdx`·`troubleshooting.mdx`, `ADDITIONAL-TERMS.md` — https://github.com/mateo-m/empo-app
- mvmz-apple-mobile (`64f0e22`): `src/runtime.js`, `src/mvmz_core.m`, `src/MvmzFileServer.m`, `README.md` — https://github.com/mateo-m/mvmz-apple-mobile

**엔진 코어 스크립트**
- MV corescript (MIT): https://github.com/rpgtkoolmv/corescript — `js/rpg_managers/StorageManager.js`, `AudioManager.js`, `js/rpg_core/Utils.js`, `WebAudio.js`
- MZ corescript (나눠 둔 사본): https://github.com/MechanicalPen/rmmz-corescripts-split — `js/rmmz_managers/StorageManager.js`, `SceneManager.js`, `js/rmmz_core/Utils.js`, `Input.js`, `WebAudio.js` (원본: https://github.com/stak/rmmz-corescript)

**앱·기타**
- RPGPlayer App Store: https://apps.apple.com/us/app/rpgplayer-an-rpgmaker-player/id6754986970
- Runa (mkxp-z 기반): https://mwm.ai/apps/runa-rpg-maker-vn-player/6779939767
- cordova-ios 6.0.0 (WKURLSchemeHandler): https://cordova.apache.org/announcements/2020/06/01/cordova-ios-release-6.0.0.html · https://cordova.apache.org/howto/2020/07/18/uiwebview-warning.html
- RPG Maker 무료 프로그램(VX Ace Lite 등): https://old.rpgmakerweb.com/download/free-programs · VX Ace Lite 배포 조건 보도: https://forest.watch.impress.co.jp/docs/news/20130207_586893.html · Lite 한계: https://himeworks.com/2013/05/overcoming-the-limits-of-vx-ace-lite/
- MKXP-Z 위키 항목: https://emulation.gametechwiki.com/index.php/MKXP-Z

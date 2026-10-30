# 빙수 앱 (BingsuApp)

SwiftUI iOS/iPadOS 26+ 런처. 프로젝트 파일은 `project.yml`에서 xcodegen으로 생성한다. 코드 이름은 빙수 테마, 화면 문구는 평범한 한국어("게임 목록", "설정", "가져오기").

## 폴더 (빙수 이름 ↔ 역할)

| 폴더 | 역할 |
|---|---|
| `Bingsu/App` | 앱 진입점(`BingsuApp.swift`: 백그라운드 다운로드 세션 깨우기, 디버그 환경변수), 색(`Palette`)·유리 재질과 홈 배경(`Glass`, 칩·일시정지 유리는 SwiftGlass) |
| `Bingsu/MenuBoard` | 메뉴판 — 게임 목록 화면, `Dish`(게임) 모델, `MenuBoardStore`, 주소로 추가한 웹 게임(`WebGames`), 홈 화면 컨트롤러 이동 |
| `Bingsu/Shaver` | 얼음 갈기 — 가져오기. 엔진 판별(`RecipeDetector`), zip 안전 해제(`SafeUnzip`), asar 풀기, 가져오기 파이프라인(`Delivery`), 다운로드(`Courier`), 파일 선택기(`GamePicker`) |
| `Bingsu/Bowl` | 그릇 — 게임 실행 화면. `GlassBowl`(WKWebView), `PokemonSchemeHandler`(로컬 게임 스킴), 주입 JS(`BowlScripts`), 게임 화면(`BowlContainerView`), 일시정지 화면(`PauseBoard`: 가로 왼쪽 패널·세로 아래 시트) |
| `Bingsu/Spoon` | 숟가락 — 가상 패드(5종 배치 `SpoonModel`, 그림 `SpoonFace`·`SpoonSkin`, 게임별 버튼 뜻 `CutlerySet`), 실제 컨트롤러(`LongSpoon`), 진동(`Rumble`, 효과음별 `RumbleSet` — 표는 `Resources/Rumble/*.json`, 형식은 `docs/rumble/README.md`) |
| `Bingsu/Freezer` | 냉동실 — 저장 데이터(`Documents/Saves/<게임>/`), 백업, iCloud 동기화(`Igloo`), 파일로 저장하는 게임(RPG Maker XP)의 저장 파일 ↔ save.json 맞추기(`IceTray`) |
| `Bingsu/BrassBowl` | 놋그릇 — RPG Maker XP 게임 실행. 엔진(`BrassBowl.framework`, mkxp-z 포크) 열기·부르기(`BrassBowlEngine`), 게임 화면·일시정지(`BrassBowlContainerView`), 키 배치(`CutlerySet+XP`) |
| `BrassBowl/` (앱 소스 밖) | 엔진 프레임워크 빌드·넣기 스크립트와 설명(`BrassBowl/README.md`) |
| `Bingsu/Thermometer` | 온도계 — FPS·열·메모리, 성능 기록(`PerfLog`/`PerfRecorder`) |
| `Bingsu/Kitchen` | 부엌 — 설정, 이 게임 설정(`DishPrefs`), 웹 게임 추가·내려받기 화면, 저장 데이터 충돌 선택 |
| `Bingsu/Resources` | Info.plist, 에셋, Ogg Vorbis WASM 디코더(MIT), 기본 게임 `SampleGame/`("Bingsu", Phaser·ZzFX MIT 동봉) |

## 데이터 위치 (기기 안)

| 위치 | 내용 |
|---|---|
| `Library/Application Support/Games/<id>/` | 가져온 게임 파일 (백업 제외, Files 앱에 안 보임 — Documents 에 두면 iPad 파일 선택기가 멈춤) |
| `Documents/Saves/<dataPathApp>/` | 저장 데이터·백업 (iCloud 동기화 대상. 파일 공유는 꺼 둠 — 켜면 iPad 파일 선택기가 빈 화면으로 멈춤. 꺼내기는 앱의 백업 내보내기) |
| `Documents/Prefs/`, `Documents/Covers/` | 게임별 설정·표지 |
| `Documents/Perf/` | 성능 기록 (기기마다, 동기화 안 함) |
| `Documents/WebGames.json` | 주소로 추가한 웹 게임 |
| `Library/Caches/Downloads/` | 내려받는 중인 zip (가져오면 지움) |

## 빌드·실행

저장소 맨 위 폴더에서:

```bash
cd BingsuApp && xcodegen generate && xcodebuild -project BingsuApp.xcodeproj -scheme Bingsu -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/SimDD build
```

RPG Maker XP 게임까지 돌리려면 먼저 엔진 프레임워크를 만든다(`BrassBowl/README.md`). 없으면 앱은 그대로 빌드되고 RPG Maker XP 게임만 "준비 중"으로 보인다.

결과물은 `build/SimDD/Build/Products/Debug-iphonesimulator/Bingsu.app`. 실기기·TestFlight 는 `DEVELOPMENT_TEAM=<팀 ID>` 를 명령줄로 넘긴다. 팀 ID·서명·API 키는 커밋하지 않는다.

**Debug 와 Release 차이:** 기본 제공 웹 게임 카드(포켓로그·포켓본크)는 Debug 빌드에만 있다. Release(TestFlight) 빌드에서는 사용자가 "주소로 웹 게임 추가"로 넣고, 게임별 조정(패드 배치·진동·화면 비율·웹 저장소)은 `Dish.knownWeb` 이 호스트로 판별해 똑같이 적용한다.

## 개발용 게임 폴더

앱은 게임 파일을 포함하지 않는다. 시뮬레이터에서는 호스트 파일시스템을 읽을 수 있으므로 저장소 루트 `Games/<게임id>/`를 그대로 메뉴판에 올린다(`MenuBoardStore.devGamesDirs`, `BINGSU_DEV_GAMES=/path` 로 추가 가능). 실기기에서는 앱의 가져오기로 넣는다.

Electron 게임을 개발용으로 올리려면 asar 를 풀어 둔다:

```bash
npx --yes @electron/asar extract <게임 폴더>/resources/app.asar Games/<게임id>
```

## 디버그 환경변수

시뮬레이터에서는 `xcrun simctl launch` 앞에 `SIMCTL_CHILD_` 를 붙여 넘긴다.

| 변수 | 동작 |
|---|---|
| `BINGSU_OPEN=<dish id>` | 실행 직후 그 게임을 연다 |
| `BINGSU_IMPORT=<zip 경로>` | 그 zip 을 가져온다 |
| `BINGSU_ADDWEB="이름\|주소"` | 주소로 웹 게임 추가 |
| `BINGSU_DOWNLOAD=<주소>` | 내려받기 시작 (`BINGSU_ALLOW_HTTP=1` 이면 http·로컬 주소 허용, Debug 만) |
| `BINGSU_FORCE_PAD=1` | 컨트롤러가 붙어 있어도 가상 패드 표시 |
| `BINGSU_KEYDEBUG=1` | 키·효과음 전달 로그 |
| `BINGSU_FAKE_ICLOUD=<폴더>` | 그 폴더를 iCloud 컨테이너로 씀 |
| `BINGSU_SELFTEST=1` | 게임 로드 직후 저장 경로 자가 검증 |
| `BINGSU_MKXP_LOG=1` | RPG Maker XP 엔진 디버그 로그 |
| `BINGSU_KEYS="초:코드,…"` | RPG Maker XP 게임에 그 시각(초)마다 키 한 번 (코드는 `KeyC`·`ArrowUp` 같은 KeyboardEvent.code) |
| `BINGSU_AUTOKEY="코드:간격:횟수"` | 12초 뒤부터 그 키를 간격(초)마다 횟수만큼 (글자 입력 중엔 건너뜀) |

로그 보기: `xcrun simctl spawn <UDID> log show --last 2m --style compact | grep "\[Bowl\]"`. 디버그 빌드는 `isInspectable = true` 라 Mac Safari 개발 메뉴에서 웹뷰 인스펙터를 열 수 있다.

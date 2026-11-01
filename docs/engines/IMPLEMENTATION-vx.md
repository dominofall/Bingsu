# RPG Maker VX · VX Ace 실행 — 구현 명세 (빌드 26)

2026-11-01 결정. 조사 문서 [`research.md`](research.md) §1(1.1~1.6)·§4.1·§4.3·§5(V1~V4) 를 바탕으로 한다. 구현 세션(Opus, 워크트리)용 명세. 명세와 다르게 해야 하면 이 파일 끝에 "구현 중 바뀐 것" 절로 적는다. MV/MZ 는 빌드 27 로 따로 간다.

## 0. 원칙

- **엔진은 다시 빌드하지 않는다.** 번들된 `BrassBowl.framework`(mkxp-z 포크 v9)에 RGSS2/3·Ruby 1.8/1.9/3.1·`.rgss2a`/`.rgss3a` 해제·`rpg_vx.rb`/`rpg_vxace.rb` 가 이미 들어 있다(research §1.3). 바꾸는 것은 빙수 쪽 Swift 와 빙수가 넘기는 preload 스크립트뿐이다. 프레임워크 빌드가 꼭 필요한 문제가 나오면 멈추고 부모 세션에 보고한다.
- **XP 는 그대로.** 레조넌스·어나더 레드·포켓몬 파티!(RGSS1, Essentials) 의 동작·키·저장 위치가 바뀌면 안 된다. 모든 분기는 `rgssVersion` 으로 나누고 1 이면 지금 코드 경로다.
- **저장은 빙수 저장 폴더에.** VX/Ace 기본 스크립트는 저장 파일을 게임 폴더에 쓴다(research §1.1 "저장 위치"). 빙수는 `Saves/<dataPathApp>/` 로 돌려서 업데이트 때 보존되고 iCloud·Drive(`IceTray` → `Freezer`)로 동기화되게 한다.
- **엔진 이름은 화면에 안 보인다**(PLAN 7장). "RPG Maker XP 게임은…" 같은 기존 문구를 "이 게임은…" 으로 중립화한다.
- **게임 파일은 커밋하지 않는다**(PLAN 8장). 테스트용 게임은 `Games/` 또는 저장소 밖에만 두고, 문서에는 이름·출처만 적는다.
- 화면 문구는 평범한 한국어, 코드 이름은 빙수 테마. 주석·커밋·보고 한국어.

## 1. 판별 (`Shaver/RecipeDetector.swift`)

research §1.6 표 그대로. `Dish.Recipe` 는 `.mkxp` 하나로 두고, RGSS 버전은 새 `RGSSVersion`(1·2·3) 판별 함수가 **가져올 때와 실행할 때** 같은 규칙으로 정한다(`BrassBowl/RGSSProbe.swift`, 순수 함수):

1. `mkxp.json` 의 `rgssVersion`(1~3) 이 있으면 그 값.
2. 맨 위 `Game.rgss3a` → 3, `Game.rgss2a` → 2, `Game.rgssad` → 1.
3. 맨 위 `*.ini`(exe 이름을 따라 바뀐 경우 포함) 의 `Scripts=` 값 확장자: `.rvdata2` → 3, `.rvdata` → 2, `.rxdata` → 1.
4. `Data/Scripts.rvdata2` → 3, `Data/Scripts.rvdata` → 2, `Data/Scripts.rxdata` → 1.
5. 보조: `Library=` 의 `RGSS3`/`RGSS2`/`RGSS1`.

`detect(folder:)` 는 위 어느 하나라도 맞으면 `.mkxp`. `Game.ini` 읽기는 UTF-8 → CP949 → Shift-JIS 순으로 시도하고 CRLF 를 처리한다(`iniTitle` 도 같은 함수로). `describe` 의 `dataPathApp` 은 지금처럼 제목(없으면 폴더 이름) — VX/Ace 는 `mkxp.json` 이 없으므로 제목 기준이 된다. 폴더가 zip 안 한 단계 아래인 경우는 기존 가져오기가 처리하는지 확인하고, 안 되면 "루트에 판별 단서가 없고 하위 폴더 하나뿐이면 그 안으로" 규칙을 더한다.

RTP 단서: `Game.ini` 의 `RTP=`/`RTP1=` 값이 있고 `Graphics/System`(또는 `Graphics/Characters`) 이 없으면 `Dish` 에 `needsRTP: String?`(RTP 이름) 를 적는다(매니페스트에 저장).

## 2. Ruby·설정 (`BrassBowl/BrassBowlEngine.swift`)

- `RubyProfile.detect` 확장: `mkxp.json`·Ruby 3 DLL → `31`/modern(지금처럼). 그 밖에 RGSS 3 → `19`/legacy, RGSS 2·1 → `18`/legacy.
- 오버레이 JSON(`mkxp_setConfigOverlayJSON`, 지금 preloadScript 를 넘기는 자리) 에 함께 넘긴다: `"rgssVersion": n`(판별값, 자동 판별에 맡기지 않음), RGSS2/3 이면 `"defScreenW": 544, "defScreenH": 416`(게임이 `Graphics.resize_screen` 으로 바꾸면 그쪽이 이김), `"midiSoundFont"`(§5), `"RTP"`(§6, 있을 때만).
- 이 게임 설정 › 고급에 "Ruby 버전: 자동 / 1.8 / 1.9 / 3.1"(`DishPrefs.rubyOverride`, 옵셔널, 예전 파일 호환) 을 두어 empo 처럼 사용자가 덮어쓸 수 있게 한다. 기본은 자동.
- `BINGSU_MKXP_LOG=1` 로그에 `[BrassBowl] rgss=3 ruby=19 screen=544x416` 한 줄.

## 3. 키 배치 (`BrassBowl/CutlerySet+XP.swift`)

`CutlerySet.rpgMakerVX`(RGSS2/3 공용) 추가: 엔진 기본 바인딩(research §1.1 "기본 키": 확인 Z·Space·Enter, 취소 Esc·X·Num0, 대시 Shift, X=A, Y=S, Z=D, L=Q, R=W) 기준.

| 패드 | 키 | 꼬리표 |
|---|---|---|
| A | `KeyZ` | 확인 |
| B | `KeyX` | 취소·메뉴 |
| X | `ShiftLeft` | 대시 |
| Y | `KeyD` | Z |
| LB / RB | `KeyQ` / `KeyW` | L / R |
| LT / RT | `KeyA` / `KeyS` | X / Y |
| 보기 | `ShiftLeft` | 대시 |
| 메뉴 | `Escape` | 메뉴 |
| 십자키·스틱 | 방향키 | |

`CutlerySet.forDish` 는 `dish.recipe == .mkxp` 일 때 RGSS 버전으로 `rpgMakerXP`/`rpgMakerVX` 를 고른다(버전은 `Dish` 매니페스트에 저장된 값, 없으면 실행 때 판별값). `BrassKeys.scancode` 에 `Numpad0`(98)·`ShiftLeft`(있음) 확인.

## 4. 저장 위치 (`BrassBowl` preload 스크립트 + `Freezer/IceTray.swift`)

**엔진 쪽(우선, research §1.4-4 (a)):** 빙수가 넘기는 preload 스크립트 `bingsu_saves.rb`(RGSS2/3 에서만 추가) 가 Ruby 수준에서 저장 파일 경로를 돌린다. 게임 스크립트가 `DataManager`/`Scene_File` 을 어떻게 고쳤든 먹도록 **파일 API 를 감싼다**: `File.open`·`File.exist?`·`File.exists?`·`File.delete`·`File.rename`·`File.size`·`File.mtime`·`Dir.glob`·`Dir.[]`·`Kernel#save_data`·`Kernel#load_data` 에서 **상대 경로 이름이 `/\A(?:\.\/)?Save\d*\.(?:rvdata2|rvdata|rxdata)\z/i`** 이면 `BINGSU_SAVE_DIR`(빙수가 `mkxp_setUserDataDirectory` 로 넘기는 `Saves/<dataPathApp>/`, 환경 변수로도 넘김) 아래 경로로 바꾼다. `Dir.glob("Save*.rvdata2")` 는 그 폴더에서 찾은 뒤 **원래 모양(상대 이름)** 으로 돌려준다(게임이 이름에서 번호를 뽑으므로). 엔진의 `windows_fs.rb` 가 이미 같은 함수들을 감싸고 있으니 그 **뒤에** 실행되게 preloadScript 순서를 맞추고, 대소문자 무시는 그쪽 규칙을 따른다. RGSS1 에는 넣지 않는다(Essentials 는 자기 저장 폴더를 쓰고, 일반 XP 게임의 `Save1.rxdata` 는 다음 빌드 과제로 남겨 둔다 — 단, 패턴에 `rxdata` 를 넣어 두어 스크립트 자체는 세 버전 공용).

**빙수 쪽:** `IceTray` 가 `Saves/<dataPathApp>/` 의 `Save*.rvdata2`·`Save*.rvdata` 도 묶도록 `safeName`·확장자 허용 목록을 넓힌다(Marshal 바이너리라 base64, 지금 `Game.rxdata` 와 같은 길). `Freezer.validate` 의 키 규칙(`^<prefix>[A-Za-z0-9_.-]+$`) 안에 드는지 확인. 업데이트(`Delivery` 폴더 교체) 는 게임 폴더만 바꾸므로 저장은 자동 보존.

**게임 폴더에 이미 저장 파일이 있는 경우**(PC 에서 하던 게임을 zip 으로 가져옴): 가져올 때 `Save\d*.rvdata2?` 를 `Saves/<dataPathApp>/` 로 **옮기고**(덮어쓰지 않음, 같은 이름이 있으면 `backups/` 로) 로그·가져오기 결과 화면에 "저장 파일 n개를 옮겼어요".

## 5. MIDI 사운드폰트

일반 VX/Ace 게임은 `mkxp.json` 도 `.sf2` 도 없다. 규칙:
1. 앱에 **작은 GM 사운드폰트 하나**를 동봉할 수 있으면 동봉한다. 조건: GPLv3 앱과 함께 배포 가능한 라이선스(CC0·MIT·CC-BY·GPL-2.0-or-later·GPLv3 호환), 8MB 이하. 후보 순서: TimGM6mb(라이선스 문서를 **직접 확인**해 "or later" 인지 볼 것), GeneralUser GS(라이선스 문서 확인), 그 밖 CC0 미니 GM. 동봉하면 `THIRD_PARTY_LICENSES.md` 와 설정 › 오픈소스 라이선스에 추가하고 `Resources/SoundFont/<이름>.sf2` 폴더 리소스로.
2. 조건에 맞는 것이 없으면 동봉하지 않고, 이 게임 설정 › 소리에 "MIDI 사운드폰트 파일(.sf2) 넣기"(Files 로 가져와 `Application Support/SoundFont/` 에 저장, 모든 mkxp 게임 공용) 만 둔다. 어느 쪽이든 이 가져오기 UI 는 만든다(사용자가 더 좋은 폰트를 쓸 수 있게). 우선순위: 게임 `mkxp.json` 의 값 → 사용자가 넣은 파일 → 동봉 파일.
3. 결정한 것을 "구현 중 바뀐 것" 에 적는다.

## 6. RTP

- 가져오기 결과·게임칩 상태: `needsRTP` 면 "RTP 가 필요해요 · RPGVXAce" 띠와 게임을 열 때 안내 시트("이 게임은 공용 그림·소리 묶음(RTP)을 따로 써요. RTP 폴더를 zip 으로 묶어 넣어 주세요"). 설치 파일(exe) 은 못 푼다고 적는다.
- RTP 넣기: 게임 추가 메뉴 › "RTP 넣기"(zip, `Graphics/`·`Audio/` 가 있어야 통과, `SafeUnzip`) → `Application Support/RTP/<이름>/`. 이름은 `Game.ini` 의 `RTP=` 값과 대소문자 무시로 맞춘다(`RPGVXAce`, `RPGVX`, `Standard`).
- 실행 때 오버레이 `"RTP": ["<그 폴더>"]`. 넣은 RTP 가 없으면 그냥 실행하되 안내는 한 번만(게임별 `DishPrefs.rtpNoticeShown`).

## 7. 화면 비율 (`BrassBowl/BrassBowlContainerView.swift`)

`static let aspect = 4/3` → 엔진이 실제 창 크기를 알려 주는 API(`docs/phase3-mkxp-poc.md` 4.1 의 게임 영역 콜백 / `mkxp_getGameWindow` 류)가 있으면 그 값을 쓰고, 없거나 아직 모르면 RGSS 2/3 → 544:416, 1 → 4:3. `Graphics.resize_screen` 으로 바뀐 뒤에도 따라가게 콜백이 있으면 구독한다.

## 8. 문구·기타

- "RPG Maker XP 게임은 …" 류 화면 문구(가져오기 결과·준비 중 안내·한 프로세스 1게임 안내) 를 엔진 이름 없는 문구로. 설정 › 오픈소스 라이선스의 mkxp-z 고지는 그대로.
- 디버그: `BINGSU_RGSS=<1|2|3>`(판별 강제), `BINGSU_RUBY=<18|19|31>`.
- `docs/phase3-mkxp-poc.md` 는 손대지 않는다. 새 사실은 `research.md` 의 [미확인] 표시를 갱신하고, 사용자용 안내는 `docs/beta/guide.md` 에 "RPG Maker VX·VX Ace 게임" 절(저장 위치, RTP, MIDI).

## 9. 테스트 게임

구현 세션은 사용자 없이 진행한다. 저작권 문제 없이 **내려받아 사적으로 테스트**할 수 있는 무료 VX Ace 게임과 VX 게임을 각각 하나 찾아(itch.io·rpgmaker.net 의 무료 배포작, 암호화 `.rgss3a` 로 배포된 것 하나를 포함하면 좋다) `Games/` 아래(gitignore) 에 두고 쓴다. 저장소에는 게임 이름·출처 URL·RGSS 버전·암호화 여부만 `research.md` §4.3 에 적는다. 적당한 게임을 못 찾으면 그 사실을 보고하고, XP 경로 회귀 확인과 코드 완성까지만 하고 멈춘다(부모 세션이 사용자에게 VX Ace Lite 프로젝트를 요청).

## 10. 확인 (시뮬레이터 iPhone 17 Pro · iPad Pro 13, 기존 두 대)

- **XP 회귀**: 포켓몬 파티!(또는 어나더 레드) 가져오기·타이틀·새 게임·저장·이어하기가 빌드 25 와 같음(키 C 확인, 4:3, `Saves/<dataPathApp>/Game.rxdata`). `BINGSU_MKXP_LOG=1` 에 `rgss=1 ruby=31`(파티) 또는 `18`.
- **VX Ace**: zip 가져오기 → 판별 `.mkxp`·`rgss=3`·`ruby=19` → 타이틀 → 새 게임 → 세이브 → `Saves/<dataPathApp>/Save01.rvdata2` 생김, 게임 폴더엔 없음 → 종료·재실행 → 이어하기 목록에 보임 → 같은 zip 다시 가져오기(업데이트) → 저장 유지. 패드 A 가 확인(Z), B 취소, 화면 544:416. 가짜 iCloud(`BINGSU_FAKE_ICLOUD`) 로 두 시뮬레이터 이어하기(IceTray 가 `.rvdata2` 를 묶음). 암호화 `.rgss3a` 게임이 있으면 같은 확인.
- **VX(RGSS2)**: 게임이 있으면 타이틀·저장(`Save1.rvdata`), `ruby=18`.
- **PC 세이브 들고 오기**: zip 안에 `Save01.rvdata2` 를 넣어 가져오기 → `Saves/` 로 옮겨지고 이어하기 됨.
- **MIDI**: `.mid` BGM 이 있는 게임(없으면 RTP BGM 의 .mid 하나를 테스트 게임에 넣어) 에서 소리가 남(동봉 또는 사용자 sf2).
- **RTP**: `Graphics/` 를 비운 사본으로 `needsRTP` 띠·안내 시트, RTP zip 넣기 → 실행.
- **문구**: 화면 어디에도 "RPG Maker XP" 가 남지 않음(`git grep "RPG Maker XP" BingsuApp/Bingsu --include=*.swift` 가 주석뿐).
- 메모리: VX Ace 타이틀·맵에서 앱 메모리를 `[Thermometer]` 로 기록(참고용).

## 11. 이번 빌드에서 하지 않는 것

MV/MZ(빌드 27), 일반 XP 게임(비 Essentials) 의 `Save1.rxdata` 이동, RTP 설치 파일(exe) 풀기, 동영상(ogv 외), 마우스 게임 지원 개선, BrassBowl 재빌드, JoiPlay 호환 토글 UI.

## 12. 끝낼 때

PLAN.md 로드맵 Phase 3 에 "VX/VX Ace" 항목을 `[x]` 로 추가하고 요약·확인 결과, `docs/beta/testflight-info.md` §2 에 빌드 26 테스트 문안 초안, `docs/beta/guide.md` 절, `THIRD_PARTY_LICENSES.md`(사운드폰트가 들어갔으면). 빌드 번호는 부모 세션이 올린다.

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

## 13. 확인 결과 (2026-11-01, 시뮬레이터)

테스트 게임은 vgperson 이 영어로 옮겨 무료 배포하는 두 작품(`Games/vx-test/` 아래에만 둠, research.md §4.3). RTP 는 공식 `RPGVXAce_RTP.zip` 안의 설치 파일을 PC 도구(innoextract)로 풀어 폴더째 zip 으로 묶어 넣었다.

| 항목 | 결과 |
|---|---|
| XP 회귀(iPhone) | 파티!: `rgss=1 ruby=31 syntax=modern`, 4:3(콜백 1.334), A→`KeyC` 로 타이틀 메뉴, RTP 안내 안 뜸. 어나더 레드: `rgss=1 ruby=31`, `Saves/` 의 기존 저장 불러옴. 파티!는 이어할 저장이 없어 새 저장은 안 해 봄(RGSS1 은 저장 스크립트를 안 넣으므로 경로 변화 없음) |
| VX Ace 판별·실행(iPhone) | Hello? Hell... o?(`Game.rgss3a` 암호화): 가져오기 `recipe=mkxp rgss=3 rtp=RPGVXAce needsRTP=true`, 실행 `rgss=3 ruby=19 syntax=legacy screen=544x416`. 게임이 640×480 으로 바꾸자 화면 비율도 1.308→1.334 로 따라감. 패드 A→`KeyZ`, B→`KeyX` |
| RTP | RTP 없이 열면 "RTP 가 필요해요" 한 번 → 그냥 열기 → 효과음 `Audio/SE/Decision1` 없음 오류(예상대로). RTP zip 가져오기 → "RTP 를 넣었어요 · RPGVXAce" → 다시 열면 안내 없이 RTP 타일·소리로 진행, 덧씌움 로그 `rtp=RPGVXAce` |
| 저장(VX Ace) | 이 게임은 메뉴를 막고 진행 중에 `DataManager.save_game(0)` 로 저장한다. 시험용 preload(게임 폴더 `mkxp.json`, 저장소에 없음)로 맵에서 같은 호출 → `Saves/Hello? Hell... o?/Save01.rvdata2` 생김, 게임 폴더엔 없음, `Dir.glob('Save*.rvdata2')` = `["Save01.rvdata2"]`. 다시 켜서 `load_header`·`load_game(0)` 성공(맵 2). IceTray 가 save.json 에 묶음 |
| 업데이트 | 같은 zip 다시 가져오기 → 업데이트 → `Save01.rvdata2`·save.json 그대로, 업데이트 전 백업 생김 |
| PC 세이브 | zip 에 `Save01.rvdata2`(내용 다름)·`Save02.rvdata2` 를 넣어 업데이트 → "게임 폴더에 있던 저장 파일 2개를 옮겼어요", Save02 는 `Saves/`, 이미 있던 Save01 과 겹친 것은 `backups/<시각> Save01.rvdata2` |
| VX(iPhone) | The Witch's House(`Game.rgss2a` 암호화): `rgss=2 ruby=18 screen=544x416`, RTP 필요 없음. 게임 자체 저장 화면(File 1~4)에서 저장 → 다시 켜면 타이틀 Continue 켜짐. **단, 이 게임은 저장을 `Save/1.rvdata`·`PublicData.rvdata` 로 하므로 게임 폴더에 남는다**(아래 "남은 것") |
| iPad Pro 13 | Witch's House 가로 화면, A→`KeyZ` B→`KeyX` X→`ShiftLeft` Y→`KeyD` L→`KeyQ` R→`KeyW`, 비율 1.308 |
| MIDI | 사용자 sf2 를 `Application Support/SoundFont/` 에 두고 테스트 게임에 시험용 `.mid` 를 넣어 `Audio.bgm_play` → 오류 없음, 덧씌움 로그 `sf=test.sf2`. 소리 자체는 귀로 확인 못 함 |
| 문구 | `git grep "RPG Maker XP" BingsuApp/Bingsu -- '*.swift'` 는 주석뿐 |
| 메모리 | Hello Hello 타이틀 71MB, 맵 83MB(시뮬레이터 phys_footprint), 약 59fps |

**하지 않은 것:** 가짜 iCloud(`BINGSU_FAKE_ICLOUD`) 두 시뮬레이터 이어하기(IceTray 가 `Save01.rvdata2` 를 save.json 에 묶는 것까지만 확인), 사람 손으로 끝까지 진행하며 저장(두 게임 모두 시험용 preload 로 저장 호출), 실기기.

**남은 것(다음 빌드 후보):**
- 게임이 저장 이름·폴더를 바꾼 경우(Witch's House 의 `Save/N.rvdata`·`PublicData.rvdata` 처럼) 저장이 게임 폴더에 남아 업데이트(예전 파일 삭제)·iCloud 에서 빠진다. 감싸기 규칙을 "맨 위 `Save*/` 폴더와 `Data/` 밖 `*.rvdata*`" 로 넓히거나, 업데이트 때 게임이 만든 파일을 옮겨 심는 방법 중 하나.
- Hello Hello 의 조명 스크립트(HN_Light)가 맵을 떠날 때(메뉴·저장 화면으로 바꿀 때) `self.bitmap` 이 nil 이라 오류. 원래 게임은 메뉴를 막아 두어 보통 진행에선 안 나올 수 있으나, 엔딩에서 타이틀로 돌아갈 때 나는지 확인 필요(엔진 쪽 차이일 수 있음).
- PC 세이브가 이미 있는 저장과 겹쳐 `backups/` 로 간 파일은 이 게임 설정 › 백업 목록(json 만 보임)에 나오지 않는다. 결과 화면 문구도 "n개를 옮겼어요" 하나뿐.

## 구현 중 바뀐 것

- **판별**: ini 글자 판별 순서를 UTF-8 → (가나가 있고 반각 가나가 없으면) Shift-JIS → CP949 → Shift-JIS 로 했다. CP949 를 먼저 시도하면 일본어 ini 가 깨진 한글로 읽히는 경우가 있어서. exe 이름으로 바뀐 ini 는 `Scripts=` 가 있는 맨 위 `*.ini` 를 찾는다.
- **needsRTP**: §1.6 의 "`Graphics/System` 없음" 대신 RTP 에만 있는 그림(VX·Ace `Graphics/System/IconSet`, XP `Graphics/Windowskins/`)이 게임 폴더에도, 아카이브 이름표에도 없을 때로 했다. Hello Hello 는 `Graphics/System` 에 세 장만 넣어 두어 원래 규칙으론 못 잡았다. 아카이브(v1·v3) 이름표만 읽는 `RGSSArchive.entryNames` 를 넣었다.
- **IceTray**: 이미 `rxdata`·`rvdata`·`rvdata2` 를 허용하고 키를 16진수로 바꾸고 있어 고칠 것이 없었다.
- **저장 스크립트**: §4 의 목록 외에 `FileTest`·`IO.read` 류·`File.stat/size?/zero?/readable?/writable?/readlines/foreach/binread/binwrite`·`Dir.[]`·`File.delete` 여러 인자도 감쌌다. 엔진 `windows_fs.rb` 의 예전 저장 되살리기(`MKXPSaveFS.recover_legacy_save`·`recover_glob_matches`)는 RGSS2/3 에서 끈다 — 켜 두면 `Saves/` 맨 위의 `Save01.rvdata2` 를 게임 폴더로 도로 옮겨 버린다. Ruby 1.8 에서도 돌게 `alias`+문자열 `class_eval` 로 썼다. 저장 폴더는 `BINGSU_SAVE_DIR` 환경 변수(없으면 `System.data_directory`).
- **Ruby 덮어쓰기**: 이 게임 설정 › 고급 › Ruby 버전(자동/1.8/1.9/3.1). 바꾸는 것은 Ruby 판뿐이고 문법 변환(modern)은 원래 modern 인 게임에서 3.1 을 고를 때만 유지한다(1.9 로 낮춘 Essentials 게임에 modern 변환을 걸지 않으려고).
- **사운드폰트**: 동봉하지 않았다. TimGM6mb 는 Debian copyright 기준 GPL-2 only("or later" 없음)라 GPLv3 앱과 같이 줄 수 없고, GeneralUser GS 는 30MB 대라 8MB 조건을 넘는다. 그 밖의 CC0 GM 폰트는 크기·음질을 확인하지 못했다. 그래서 이 게임 설정 › 소리 › "MIDI 사운드폰트 파일(.sf2) 넣기"만 두었다(512MB 까지, `RIFF....sfbk` 머리 확인, 하나만 두고 모든 RPG Maker 게임 공용). `THIRD_PARTY_LICENSES.md` 는 바꾸지 않았다.
- **RTP 넣기**: 따로 화면을 만들지 않고 일반 게임 가져오기가 "게임이 아니고 `Graphics/`·`Audio/` 가 있는 zip" 을 RTP 로 알아보게 했다. 게임 추가 메뉴의 "RTP 넣기 (zip)" 는 같은 파일 고르기를 연다. 이름은 zip·폴더 이름(vxace/vx/rpgxp·standard) → 안의 폴더 모양(Battlebacks1 → Ace, Autotiles·Windowskins → XP, 나머지 VX) 순으로 고른다. 안내 시트 버튼은 "그냥 열기"·"목록으로".
- **화면 비율**: 엔진의 `mkxp_setGameRectChangedCallback` 이 그리는 영역을 알려 주므로 그 w/h 를 쓴다(1% 안쪽 변화는 무시). 콜백이 오기 전에는 RGSS2/3 544:416, XP 4:3. XP 는 실행 로그에 `screen=auto`.
- **문구**: 설정 › 오픈소스 라이선스의 엔진 설명도 "RPG Maker XP" → "RPG Maker" 로(mkxp-z 고지 자체는 그대로).
- **실행 로그**: `BINGSU_MKXP_LOG` 와 상관없이 `[BrassBowl] rgss=… ruby=… screen=…` 과 `설정 덧씌움 [키] sf=… rtp=…` 를 한 줄씩 남긴다.
- **zip 안 한 단계 아래 폴더**: 기존 `Delivery` 가 이미 처리해 새 규칙이 필요 없었다.

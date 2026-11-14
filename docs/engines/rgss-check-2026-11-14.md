# Ruby 버전별 시작 점검 결과 (2026-11-14)

도구: `tools/rgss-check/` (README 참고). 시뮬레이터 iPad Pro 13, 빌드 두 개:
- **fix** = 브랜치 `layout-center-fix` 7a4013e (Ruby 3.1 맨 위 def 공개 스크립트 `toplevelScript` 포함)
- **base** = main 4dd4aab (고치기 전)

게임 파일·스크린숏은 커밋하지 않는다. 스크린숏은 공유 노트 폴더 `rgss-check-shots/`.

## 결과 표

| 게임 | RGSS | 빌드 | Ruby (자동=*) | 시작 | 오류·건너뛴 스크립트 | 엔진 해상도 → 실제 화면 | 게임이 밝힌 크기 | 일치 | 맨 위 def 공개 |
|---|---|---|---|---|---|---|---|---|---|
| 포켓몬 Z 한글 패치 | XP | fix | 31* | ✓ | - | 640x480 → 512x384 | 512x384 | ✓ | true |
| 포켓몬 Z 한글 패치 | XP | fix | 18 | ✓ | - | 640x480 → 512x384 | 512x384 | ✓ | true |
| 포켓몬 Z 한글 패치 | XP | base | 31* | ✓ | - | 640x480 → **640x480** (게임은 512x384 로 앎) | 512x384 | **✗** | **false** |
| 포켓몬 Z V2.18 원본 | XP | fix | 31* | **오류로 멈춤** | RandomObjects:505 NameError · 건너뛴 스크립트 2: AudioUtilities(`when x:`), PScreen_Load(`Invalid retry`) | 640x480 | 512x384 | ? | true |
| 포켓몬 Z V2.18 원본 | XP | fix | 18 | ✓ | - | 640x480 → 512x384 | 512x384 | ✓ | true |
| 포켓몬 Z V2.18 원본 | XP | base | 31* | **오류로 멈춤** | 위와 같음 | 640x480 | 512x384 | ? | false |
| Pokémon Wishing Star | XP | fix | 31* | ✓ | - | 640x480 → 512x384 | 512x384 | ✓ | true |
| Pokémon Wishing Star | XP | fix | 18 | 오류로 멈춤 | TilesetWrapper:26 TypeError · 건너뛴 스크립트 28 (신형 문법) | 640x480 | 512x384 | ? | true |
| Pokémon Wishing Star | XP | base | 31* | ✓ | - | 640x480 → 512x384 | 512x384 | ✓ | false |
| HelloHellO | VX Ace 🔒 | fix | 19* / 18 / 31 | ✓ (측정 없음) | - | 544x416 | - | ? | - |
| HelloHellO | VX Ace 🔒 | base | 19* / 31 | ✓ (측정 없음) | - | 544x416 | - | ? | - |
| The Witch's House | VX 🔒 | fix | 18* / 31 | ✓ (측정 없음) | - | 544x416 | - | ? | - |

- 🔒 = 스크립트가 암호화 아카이브 안 → probe·정적 검사 없음(mkxp.json 이 없어 probe 를 넣으면 자동 판별이 바뀜). 스크린숏으로 타이틀·첫 화면 확인.
- **어나더 레드·포켓몬 파티!** 는 실행 점검을 못 했다: `~/Dev` 디스크 이미지가 느려(2만 4천 파일 나열에 23초) 엔진이 시작할 때 파일을 모두 훑는
  단계(`createPathCache`)에서 90초 안에 Ruby 가 시작되지 않았다. 내장 디스크로 복사하면 되지만(Wishing Star 로 확인) 복사가 25분씩 걸리고
  여유 공간이 모자라 미뤘다(`--local` 로 다시 가능). 정적 검사는 했다: 둘 다 신형 문법 오류 없음, 파티! 에 `Object.respond_to?` 1곳(아래 3번).
- Wishing Star·어나더 레드·파티! 는 Essentials v20+ (Ruby 3 전용 문법)라 Ruby 1.8 로 바꾸면 깨지는 게 정상. 사용자에게 Ruby 선택을 숨긴 것(layout-center-fix 0b28d2e)이 맞다.

## 발견한 Ruby 버전 차이 문제

### 1. Ruby 3.1 에서 옛 문법 스크립트를 엔진이 통째로 건너뜀 → 뒤에서 NameError (높음, 미해결)
- 포켓몬 Z V2.18 원본(한글 패치 없음)은 mkxp.json 이 있어 자동으로 Ruby 3.1 인데, 스크립트는 Essentials v16 시절 Ruby 1.8 문법이다.
  엔진 로그 `[SKIPPED] Script 'PScreen_Load': SyntaxError - Invalid retry`(544행, rescue 밖 `retry`), `'AudioUtilities': unexpected ':'`(919행, `when 0:`).
  PScreen_Load 의 `PokemonLoad#pbStartLoadScreen` 이 없어져 RandomObjects:505 의 `alias` 가 NameError → 시작 못 함. base·fix 둘 다.
- `syntaxTransform: modern` 이 이 두 문법을 고치지 못한다. 한글 패치는 스크립트를 직접 고쳐(“Z-32 Ruby Compat”) 피해 간다.
- **고칠 방향(제안)**
  1. 엔진: Ruby 3.1 에서 스크립트가 SyntaxError 이면 건너뛰기 전에 옛 문법 변환(`when x:` → `when x then`, rescue 밖 `retry` → 루프 재시작 등
     legacy 변환기 규칙)을 한 번 더 걸어 다시 컴파일. 건너뛰면 앱에 "건너뛴 스크립트 N개" 를 알림으로 넘겨 진단 리포트에 남긴다.
  2. 앱: `RubyProfile.detect` 가 mkxp.json 만 보고 3.1 을 고르는 것이 이 게임에는 틀림. 가져올 때(또는 첫 실행 때) 스크립트에 1.8 전용 문법이
     있으면(`rgss-check/scan.rb` 의 문법 검사와 같은 원리, 앱에서는 엔진에 컴파일만 시켜 보는 함수가 필요) 1.8 로. 또는 3.1 실행이
     `[SKIPPED]`·NameError 로 멈추면 다음 실행부터 1.8 로 자동 전환(사용자에게는 묻지 않음 — Ruby 선택을 숨긴 방향과 같음).
  3. 한글 패치처럼 패치가 문법을 고쳐 3.1 로 잘 도는 경우가 있으니, 자동 전환은 "3.1 이 실패했을 때만" 이 안전하다.

### 2. 맨 위 def 가 Ruby 3.1 에서 비공개 → `Kernel.respond_to?` 거짓 (높음, fix 브랜치에서 해결 확인)
- base: probe 의 `toplevel_def_public=false`, 포켓몬 Z 한글 패치는 `resize_screen` 이 한 번도 안 불려 엔진은 640x480 인데 게임은 512x384 로 앎
  (게임이 `Graphics.width` 를 덮어써 게임 안 값만 보면 정상처럼 보인다 — probe 는 덮어쓰기 전에 잡아 둔 엔진 값으로 잼). 스크린숏: 왼쪽 위 80%.
- fix: `true`, `resize_screen 512x384` 불림, 가운데 정상. Z 원본·Wishing Star 에서도 부작용 없음.

### 3. 같은 종류의 검사가 다른 게임에도 있음 (낮음)
- 포켓몬 파티!: `YOUNG's Essentials/007_SpeedUp.rb:36` 의 `Object.respond_to?(:pbScreenCapture)` (F8 화면 캡처). base 빌드에서는 F8 이 조용히
  안 먹었을 것. fix 의 `toplevelScript` 가 같이 고친다(실행 확인은 못 함 — 위 디스크 문제).
- 정적 검사(`scan.rb`)로 다른 게임을 가져올 때마다 `toplevel-respond_to`·`syntax-error-modern` 을 보면 같은 문제를 미리 찾을 수 있다.

### 4. mkxp.json 끝 쉼표 (낮음)
- 포켓몬 Z 의 mkxp.json 은 JSON5 식 끝 쉼표가 있어 표준 JSON 으로 못 읽는다. 빙수 `installOverlay` 는 `JSONSerialization` 으로 읽으므로
  이런 게임은 게임 자신의 `defScreenW`·`midiSoundFont`·`RTP` 키를 모르고 빙수 기본값을 덮어쓸 수 있다(Z 는 그 키가 없어 영향 없음).
  `preloadScript` 키까지 있으면 빙수 스크립트(소리 크기·온라인·맨 위 def 공개)를 아예 넣지 않는다. 제안: 끝 쉼표를 빼고 읽기(JSON5 옵션).

## 다음에 돌릴 때
- 큰 게임은 `--local`(내장 디스크 복사, 여유 공간 확인) 또는 게임을 내장 디스크에 두고.
- 어나더 레드·포켓몬 파티! 실행 점검, 그리고 사용자가 가져온 게임(앱 데이터 `Games/`) 을 그대로 돌리는 모드(복제본 없이, probe 없이)도 있으면 좋다.

## 이어서 고친 것 (브랜치 `ruby-script-detect` 50f8940, layout-center-fix 0b28d2e 위)

1번·2번 문제에 대한 세 겹 방어. 앱 입력·패치 코드는 건드리지 않음.

1. **스크립트 문법으로 Ruby 고르기** (`RubyScriptScan`, `BrassBowl/RGSSProbe.swift`): `Data/Scripts.rxdata` 를 풀어
   1.8 전용 문법(`when x:`, rescue 밖 `retry`)이 있고 신형 문법(`&.`, `->(`, 키워드 인자, `{a: 1}`)이 하나도 없으면
   mkxp.json 이 있어도 옛 Ruby. 결과는 `Caches/ruby-script-scan.json` 에 캐시. 신형 문법이 한 곳이라도 있으면 3.1 유지(한글 패치처럼
   고쳐 둔 게임 보호). `scan.rb` 도 같은 규칙.
2. **맨 위 def 공개** (`toplevelScript`, layout-center-fix 에 이미 있음).
3. **화면 크기 자동 맞춤** (`screenFitScript`, 모든 Ruby): 게임이 `resize_screen` 을 부르지 않았는데 게임이 보는 `Graphics.width/height`
   가 엔진 화면보다 작으면 90프레임 뒤 한 번 `resize_screen`. 앱 로그 `[bingsu] screen fit 640x480 -> 512x384`.

| 게임 | 결과 (iPad Pro 13, ruby-detect 빌드, 자동) |
|---|---|
| 포켓몬 Z V2.18 원본 | **18 로 고름**(1.8 문법 24곳, 신형 0) → 시작 ✓, 512x384 일치 (전에는 31 에서 오류로 멈춤) |
| 포켓몬 Z 한글 패치 | 31 유지 → ✓, 512x384 일치 |
| 포켓몬 Z 한글 패치 + `BINGSU_NO_TOPLEVEL=1` | 2번을 꺼도 3번이 640x480 → 512x384 로 맞춤 ✓ |
| The Witch's House | 18 ✓ |
| Wishing Star · 어나더 레드 · 파티! | 정적 검사로 31 유지 확인(신형 문법 있음). 실행은 디스크 문제로 이번엔 안 함 |

디버그 끄기: `BINGSU_NO_SCREENFIT=1`, `BINGSU_NO_TOPLEVEL=1`. 엔진 쪽 "건너뛴 스크립트 다시 변환" 은 아직 안 함(1번 제안 1).

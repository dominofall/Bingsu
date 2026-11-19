# 포켓몬 게임 공통 진동 — 기본 표 + 게임별 JSON 계획

작성 2026-11-19. 상태: **1~6단계 완료(2026-11-19, 4단계는 시뮬레이터까지)**, 실기기 세기 조정·포획 확인 남음. **빌드 51 에 넣는다**(사용자 2026-11-19), 브랜치 `rumble-51`.

1단계에서 계획과 달라진 점: 상황 패턴은 기존 표 값을 그대로 이어받아 `crit_throw` 0.5/0.7/0.14, `level_up` 0.2/0.5/0.2 이고, `ball_drop`·`flee` 를 더해 13개. 짧은 이름이 다른 게임을 잡지 않도록 `detect.localExact`(정확히 같은 이름) 추가(Z 는 `Pokemon Z`). 해시로 짝짓기는 하지 않음.

## 목표

1. 진동표가 따로 없는 포켓몬 팬게임도 **기본 설정만으로** 피격·기절·포획 같은 순간에 진동한다.
2. 게임별 JSON 파일(`Resources/Rumble/<게임>.json`)은 기본 설정을 **물려받고 다른 점만** 적는다.
3. 효과음뿐 아니라 **화면 흔들림**에도 진동한다 (엔진이 알려 주는 곳만).

## 바탕: 네 게임의 효과음 비교 (2026-11-19)

| 묶음 | 쓰는 게임 | 이름 예 |
|---|---|---|
| **Essentials 신형** (v19~21) | 어나더레드, 레조넌스 `Audio/SE` (어나더레드에서 바이트 그대로 복사) | `Battle damage super`, `Battle ball shake`, `Pkmn faint` |
| **Essentials 구형** (v16~18) | Pokemon Z | `superdamage`, `ballshake`, `faint`, `throw` |
| **PokeRogue** | 포켓로그, 레조넌스 `Battle/audio/sfx` (바이트 그대로) | `hit_strong`, `pb_throw`, `faint` |
| PRSFX 기술 소리 (Reborn) | 넷 다 (레조넌스는 이름만 바꿈) | `PRSFX- Earthquake` |

- 같은 상황의 소리는 세 묶음 모두 **같은 원작 소리를 따로 녹음한 것**입니다(음색 0.85~0.98, 길이·다듬기는 다름). 그래서 소리 비교나 해시로는 게임 사이의 짝을 자동으로 맞출 수 없습니다. **이름 → 상황 표**로 갑니다.
- 해시로 짝짓기는 하지 않습니다. 실행 중에 빙수가 보는 것은 파일 이름뿐이고(웹 `sfxWatch`, RGSS `Audio.se_play`), 해시를 계산하려면 파일을 다시 읽어야 해서 얻는 것보다 비용이 큽니다.
- 기술 소리(PRSFX)는 너무 자주 나서 기본 진동에 넣지 않습니다(블루투스 이어폰 지직거림, `docs/rumble/README.md`).

## 1. 상황 목록과 진동 패턴

패턴은 **상황마다 한 번만** 정합니다. 숫자는 지금 `resonance.json`·`pokerogue.json` 값을 그대로 이어받습니다.

| 상황 (`event`) | strong | weak | 길이 | 반복 | 비고 |
|---|---|---|---|---|---|
| `hit_weak` 효과가 별로 | 0.25 | 0.3 | 0.10 | | |
| `hit_normal` 일반 타격 | 0.6 | 0.4 | 0.16 | | |
| `hit_super` 효과가 굉장함 | 1.0 | 0.6 | 0.28 | | 가장 센 축 |
| `faint` 기절 | 0.8 | 0.2 | 0.45 | | |
| `ball_throw` 볼 던지기 | 0.2 | 0.5 | 0.10 | | |
| `ball_hit` 볼이 맞음 | 0.5 | 0.3 | 0.08 | | |
| `ball_shake` 볼 흔들림 | 0.45 | 0.2 | 0.12 | | 게임이 흔들릴 때마다 소리를 내므로 반복 없음 |
| `catch_click` 포획 확정 | 0.7 | 0.5 | 0.30 | | |
| `crit_throw` 크리티컬 캡처 | 0.6 | 0.6 | 0.20 | | |
| `recall` 볼로 돌아옴 | 0.2 | 0.4 | 0.10 | | |
| `level_up` 레벨 업 | 0.3 | 0.3 | 0.20 | | |
| `screen_shake` 화면 흔들림 | 세기·길이는 엔진 값에서 계산 (4장) | | | | |

- 상황 패턴은 새 파일 `Resources/Rumble/events.json` 한 곳에 둡니다. 나중에 "상황별 세기" 설정이 생기면 여기에 곱하면 됩니다(지금은 만들지 않음, 설정은 켬/끔·세기만 유지).
- 게임 파일의 규칙은 숫자 대신 `"event": "hit_super"`만 써도 되고, 숫자를 같이 쓰면 숫자가 이깁니다.

## 2. 기본 표 (`base-*.json`)

| 파일 | 내용 | 아무 게임에나 써도 되나 |
|---|---|---|
| `base-essentials.json` | 신형 이름: `Battle damage normal/super/weak`, `Battle throw`, `Battle ball hit`, `Battle ball shake`, `Battle catch click`, `Battle critical catch throw`, `Battle recall`, `Pkmn faint`, `Pkmn level up` | **예** — 이름이 독특해 다른 게임과 겹치지 않음 |
| `base-essentials-classic.json` | 구형 이름 중 독특한 것: `normaldamage`, `superdamage`, `notverydamage`, `ballshake`, `jumptoball`, `expfull` | **예** |
| `base-pokerogue.json` | `pb_throw`, `pb_bounce_1/2`, `pb_catch`, `pb_lock`, `pb_rel`, `crit_throw` | **예** (`pb_` 접두어) |
| (게임 파일에만) | `hit`, `hit_strong`, `hit_weak`, `faint`, `throw`, `recall`, `flee` 같은 흔한 이름 | **아니오** — 일반 RPG 의 `hit.ogg` 까지 울림 |

**고르는 순서** (위가 먼저, 먼저 맞는 규칙 하나만):

1. 사용자가 넣은 표 `Documents/Rumble/<게임 id>.json` (지금과 같음)
2. 게임 파일 `Resources/Rumble/<게임>.json` 의 `rules`
3. 그 게임 파일의 `extends` 에 적힌 기본 표들 (적은 순서대로)
4. 게임 파일이 없으면: `fallback: true` 인 기본 표 셋 전부

그래서 진동표가 없는 Essentials 게임도 4번으로 바로 진동하고, 게임 파일은 흔한 이름이나 그 게임만의 소리만 적으면 됩니다.

## 3. 파일 형식 확장 (format 1 그대로, 필드만 추가)

```json
{
  "format": 1,
  "kind": "game",
  "game": "Pokemon Z",
  "detect": {"localNames": ["pokemon z"]},
  "extends": ["base-essentials-classic", "base-essentials"],
  "rules": [
    {"sound": "throw", "match": "exact", "event": "ball_throw"},
    {"sound": "faint", "match": "exact", "event": "faint"},
    {"sound": "recall", "match": "exact", "event": "recall"},
    {"sound": "Explosion", "match": "prefix", "strong": 0.9, "weak": 0.4, "duration": 0.3, "note": "Z 만의 폭발음"}
  ]
}
```

| 추가 필드 | 설명 |
|---|---|
| `kind` | `game`(기본값) · `base` · `events`. `base` 는 `detect` 대신 `fallback: true/false` 를 가짐 |
| `extends` | 기본 표 파일 이름 목록 (8개까지, `base-` 로 시작하는 것만, 기본 표끼리는 이어받지 않음 — 순환 방지) |
| 규칙의 `event` | 상황 이름. 숫자 필드(`strong`·`weak`·`duration`)가 없으면 필수 |

**이름 맞추기 규칙 고침 (중요):**
- RGSS 게임은 확장자 없이 `Audio/SE/Battle damage normal` 로 부릅니다. 지금 문서가 권하는 `"hit."`(점 붙은 앞부분) 규칙은 여기서 안 맞습니다.
- 빙수가 이름을 **폴더 빼고, 소문자로, 확장자 빼고** 한 가지 모양으로 만든 뒤 비교합니다. 이후 규칙은 확장자 없이 `exact` 로 씁니다(`"sound": "hit_strong", "match": "exact"`).
- 옛 파일 호환: `sound` 가 `.` 으로 끝나는 `prefix` 규칙은 읽을 때 `exact`(점 뺌)로 바꿉니다. 지금 번들 표 3개는 전부 이 모양이라 손실이 없습니다. 바꾸기 전후 표를 같은 이름 목록으로 돌려 차이 0 을 확인합니다(2026-10-30 에 한 방식 그대로).
- 예전 빙수 빌드는 `event` 규칙을 "필수 필드 빠짐"으로 그 규칙만 버립니다. 번들 파일은 빌드와 함께 가므로 문제없고, 사용자 표는 새 빌드에서만 의미가 있습니다.

## 4. 엔진별 신호

| 엔진 | 효과음 | 화면 흔들림 | 할 일 |
|---|---|---|---|
| 웹·Electron (포켓로그, 레조넌스) | `sfxWatch` → `sfx` 메시지 **(있음)** | 일반적인 신호 없음 | 이름 정규화만. 흔들림은 아래 조사 항목 |
| RPG Maker XP·VX·VX Ace (어나더레드, Z) | `Audio.se_play`·`me_play` 훅 → 울타리 신호 **(2단계에서 만듦)** | `Game_Screen#start_shake(power, speed, duration)` 가로채기 | **새로 만듦** (아래) |
| RPG Maker MV·MZ | Web Audio 라 `sfxWatch` 로 잡힐 것 (확인 필요) | `Game_Screen.prototype.startShake` 가로채기 | JS 한 줄 훅 |

**RGSS → 빙수 신호 통로 (핵심 작업):**
- 지금 Ruby → Swift 신호는 글자 입력용 신호 파일을 0.15초마다 읽는 방식입니다. 효과음 진동에 쓰기엔 늦고, 파일 쓰기가 잦아집니다.
- **안 A (권장):** BrassBowl(mkxp-z, 우리가 빌드)에 Ruby 함수 `Bingsu.rumble(name)` 을 C 로 추가해 Swift 콜백을 바로 부릅니다. 지연 없음, 파일 없음. fence.c 와도 무관합니다.
- **안 B (대안):** 시작할 때 Swift 가 "지켜볼 이름 목록"을 Ruby 에 넘기고, Ruby 는 목록에 있는 소리일 때만 신호 파일에 한 줄 덧붙입니다. Swift 는 50ms 마다 읽습니다. 프레임워크를 다시 빌드하지 않아도 됩니다.
- 둘 다 Ruby 쪽에서 **표에 있는 이름만** 보내서 신호 수가 적습니다(메뉴·발소리는 아예 안 넘어옴).

**2단계에서 실제로 고른 방법 (2026-11-19): 안 C — 울타리(fence.c) 마법 경로.**
- 안 A 는 Ruby 1.8·1.9·3.1 세 판의 엔진을 모두 다시 빌드해야 하고, 안 B 는 파일을 씁니다. 대신 이미 엔진 안에서 파일 함수(open·stat·access…)를 가로채는 `fence.c` 를 씁니다.
- Ruby 가 `File.exist?("/.bingsu-sfx/<이름>")` 을 부르면 `check()` 맨 앞에서 접두어를 보고 Swift 가 등록한 처리기(`mkxp_sfxSetHandler`)에 이름을 넘긴 뒤 ENOENT 로 돌려줍니다. 디스크에는 닿지 않고, 프레임워크만 다시 링크하면 됩니다(`build-framework.sh`).
- Swift 는 게임을 켤 때 그 게임의 진동표 규칙을 `BINGSU_SFX_RULES`(줄마다 `e|p|s|c` + 탭 + 이름)로 넘깁니다. Ruby 는 `RumbleSet.normalize` 와 같게 이름을 다듬고 **표에 있는 이름만** 보내며, 같은 이름이 40ms 안에 또 오면 한 번만 보냅니다. Swift 는 1초에 15개까지만 받고 표로 다시 맞춘 뒤 `Rumble.shared.play` (진동 꺼짐·블루투스 보호는 거기서).
- 옛 Essentials(포켓몬 Z)는 게임 스크립트가 `Audio.se_play` 를 통째로 다시 정의합니다. 그래서 `singleton_method_added` 로 다시 정의될 때마다 새 함수를 다시 감쌉니다.
- `BINGSU_KEYDEBUG=1` 이면 표에 없는 이름도 넘겨 `[BrassBowl] sfx <이름> (표에 없음)` / `-> rumble` 로그를 남깁니다(표 만들 때 씀).
- 확인(iPad Pro 13 시뮬레이터, `BINGSU_KEYS` 자동 입력): 어나더레드(Ruby 3.1)·Z(Ruby 1.8) 둘 다 효과음이 키 입력 16~20ms 뒤 빙수에 도착. 메뉴 소리로 만든 임시 사용자 표로 `-> rumble` 확인 후 지움. **실제 전투 효과음 진동은 4단계에서.**

**화면 흔들림 → 진동:**
- RGSS `power`(1~9) → 세기 `power/9`, `duration`(프레임) → 길이 `min(duration/40, 0.5)` 초. `speed` 는 쓰지 않음.
- 효과음 진동과 0.15초 안에 겹치면 센 쪽 하나만 울립니다(타격음과 흔들림이 같이 오는 경우가 많음).
- 게임 파일에서 끌 수 있게 `"shake": false` (기본 켬).
- 조사: 포켓로그는 Phaser 라 `Camera#shake` 를 가로챌 수 있을지 (Phaser 가 전역에 없으면 불가). 레조넌스는 자체 캔버스 연출이라 하지 않습니다(게임 코드를 고쳐야 함, 업데이트마다 깨짐).

## 5. 처음 넣을 게임 파일

| 파일 | `extends` | 게임 전용 규칙 | 감지 |
|---|---|---|---|
| `another-red.json` | `base-essentials` | 없음 또는 소수(`Vs flash` 등은 로그 보고 결정) | `localNames`: 실제 값은 로그로 확인 |
| `pokemon-z.json` | `base-essentials-classic`, `base-essentials` | `throw`, `faint`, `recall`, `hit`(용도 확인), `Flee` | 로그로 확인 |
| `resonance.json` | `base-essentials`, `base-pokerogue` | `hit`·`hit_strong`·`hit_weak`·`faint` (지금 규칙을 `event` 로) | `resonance` (지금과 같음) |
| `pokerogue.json` | `base-pokerogue` | 지금 규칙을 `event` 로 | `pokerogue.net` (지금과 같음) |

## 6. 순서

1. **형식:** 이름 정규화 + `event`·`extends`·`kind`·`fallback` 읽기, 옛 규칙 자동 변환, `events.json`·`base-*.json` 세 개. 기존 표와 새 표를 같은 이름 목록으로 비교해 차이 0 확인.
2. **RGSS 신호:** ~~안 A~~ → 울타리 마법 경로(안 C, 위)로 됨 (2026-11-19). `se_play`·`me_play` 훅, `BINGSU_KEYDEBUG=1` 이면 `[BrassBowl] sfx <이름> -> rumble` 로그.
3. **화면 흔들림:** RGSS `start_shake`, MV·MZ `startShake` 훅, 겹침 처리. **됨 (2026-11-19):**
   - RGSS: 효과음 스크립트(`sfxScript`)가 `Graphics.update` 에서 `Game_Screen#start_shake` 가 생기길 기다렸다가(600프레임까지) 한 번 감싸고, 같은 울타리 통로로 `!shake:<power>:<프레임>` 을 보냄. Swift 가 `RumbleSet.shakePattern` 으로 진동.
   - MV·MZ: `sfxWatch` 가 0.5초마다(2분까지) `Game_Screen.prototype.startShake` 를 찾아 감싸고 `sfx` 메시지에 `{shake, frames}` 로 보냄(숫자만, 9·600 으로 자름).
   - 겹침: `Rumble.play(_:from:)` — 다른 쪽(효과음↔흔들림)이 0.15초 안에 이미 울렸고 이번 것이 약하면 건너뜀. 같은 쪽끼리는 그대로.
   - 끄기: 게임 표 `"shake": false` (기본 켬, 게임 표 없는 게임은 켬).
   - 확인: iPad 시뮬레이터에서 시험 코드로 `$game_screen.start_shake(9,5,20)`·`(3,5,20)` 을 부르게 한 임시 빌드 — Z(Ruby 1.8)·어나더레드(Ruby 3.1) 둘 다 `[BrassBowl] shake power=9 frames=20 -> rumble`. 시험 코드는 뺌. MV·MZ 훅은 node 에서 늦게 생기는 `Game_Screen` 으로 확인(실제 MV·MZ 게임에서는 아직).
4. **게임 파일 네 개**와 실제 플레이 확인 — **시뮬레이터에서 됨 (2026-11-19):**
   - 방법: 임시 빌드에서 맵에 들어가면 `WildBattle.start`(신형) / `pbWildBattle(PBSpecies::…)`(구형)로 야생 배틀을 열고 `BINGSU_AUTOKEY=Enter:1.3:75` 로 첫 기술만 계속 씀. `BINGSU_KEYDEBUG=1` 로 효과음 이름 전부 기록. 시험 코드는 뺌.
   - 어나더레드(꼬렛 Lv3): `battle damage normal` ×2 → 진동, `pkmn faint` → 진동. 꼬마돌 Lv2: `battle damage weak` ×4 → 약한 진동, `pkmn faint` → 진동.
   - Z(꼬렛 Lv3): 내보낼 때 `recall` → 진동(Z 는 내보내기에도 이 소리), `normaldamage` ×5 → 진동, `faint` → 진동.
   - 울음소리(`rattata`·`019cry`), 메뉴(`gui sel decision`·`choose`), 기술 효과음(`prsfx- …`), `pkmn exp gain` 은 표에 없어 울리지 않음 — 의도대로. 빠진 전투 소리가 없어 표는 고치지 않음.
   - 확인 못 함: 효과 굉장함(`battle damage super`·`superdamage`), 포획(볼 던지기·흔들림·확정), 레벨 업, 실기기 손 느낌. 레조넌스·포켓로그는 1단계 이름 비교(바뀐 진동 0)로 갈음.
   - 원래 계획 문장: 어나더레드·Z 는 첫 야생 배틀(피격·효과 굉장함·포획 흔들림·포획 확정·기절), 레조넌스·포켓로그는 지금 표와 같은 순간에 그대로 울리는지.
5. **문서:** 됨 (2026-11-19) — README 에 "RPG Maker 게임이라면" 절(효과음·흔들림 지켜보는 함수, `shake`, 겹침, 파일 없이도 되는 경우), 1차 표 `TABLE-v1.md`. 원래 계획: `docs/rumble/README.md` 에 `event`·`extends`·확장자 없는 이름 규칙, Essentials 게임 개발자용 "대부분은 파일 없이도 됨" 안내. `tools/rumble-lab` 에 RGSS 시험 장면 추가 여부는 2단계 뒤 결정.
6. **설정 화면:** 됨 (2026-11-19) — 게임 설정 › 조작 › 컨트롤러 진동 줄은 "게임 전용 / 기본 / 직접 넣은 표 / 없음" 한마디, 안쪽 화면에 "쓰는 표"·"규칙"(게임 이름 · N개 + 기본 표 M개)·RPG Maker 게임만 "화면 흔들림: 울려요/울리지 않아요". 새 토글 없음. 원래 계획: 게임 설정 › 컨트롤러 진동에 "쓰는 표: 기본(Essentials) / 게임 전용 / 내가 넣은 표" 한 줄. 새 토글은 넣지 않음.

## 7. 게임이 스스로 진동을 요청하는 경우 (2026-11-19 조사)

- 엔진 자체에는 진동 기능이 없습니다: RGSS(XP·VX·VX Ace), mkxp-z(빙수 BrassBowl 소스 검색), MV·MZ 코어 모두.
- 가진 포켓몬 게임 다섯(어나더레드·패치, Wishing Star, Party!, Z)의 스크립트에도 진동 호출이 없습니다. "Vibrate VS sprite" 는 그림 흔들기 연출이고, Z 의 Win32API 호출 90여 종 중 XInput 은 없습니다.
- 진동을 쓰는 게임은 **플러그인·스크립트를 따로 넣은 경우**뿐입니다.
  - **MV·MZ 플러그인** (NekoGakuen GamePad, Ready to Rumble, CGMZ Rumble, Gamepad Modification and Vibration): 표준 Gamepad API `vibrationActuator.playEffect` 를 부릅니다. 빙수는 이미 이 요청을 받아 울립니다(`BowlScripts` 의 가상 패드). 단, MV·MZ 로컬 게임의 기본 배치는 키보드라 게임이 패드를 못 보면 요청 자체가 안 옵니다. 이런 게임은 게임 파일에 "표준 게임패드 배치" 표시가 필요합니다(진동 실험실과 같은 처리).
  - **VX Ace Gamepad Extender (Lone Wolf)**: `WolfPad.vibrate(left, right, frames)` → `Win32API.new("xinput1_3", "XInputSetState")`. iOS 에는 Windows DLL 이 없어 빙수에서는 이 호출이 동작하지 않습니다. 쓰는 게임이 나오면 `Win32API.new("xinput1_3"…, "XInputSetState")` 만 흉내 내 진동으로 바꾸는 작은 대체를 검토합니다(지금은 하지 않음).
- 결론: 포켓몬 팬게임은 게임이 진동을 주지 않으므로 이 계획(효과음·화면 흔들림)이 맞습니다. 게임이 직접 요청하는 진동이 있으면 그쪽이 표보다 먼저입니다.

## 확인 못 한 것 / 정할 것

- Z 의 `hit`, `Lock On`, `PokemonGet` 이 어느 순간에 나는지 (로그로 확인 후 규칙).
- Essentials 전투가 화면 흔들림을 `start_shake` 로 하는지, 애니메이션 자체 흔들림으로 하는지 (후자면 효과음 진동만으로 충분).
- 안 A 를 위해 BrassBowl 프레임워크를 다시 빌드하는 것이 다음 빌드 일정에 맞는지. 맞지 않으면 안 B 로 먼저.
- 몇 번 빌드에 넣을지 (로드맵 순서는 사용자 결정).

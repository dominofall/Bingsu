# 효과음 진동표 — 게임 개발자 안내

빙수는 게임 컨트롤러(또는 컨트롤러가 없으면 폰 햅틱)를 **게임이 재생하는 효과음과 화면 흔들림에 맞춰** 울립니다.
대부분의 팬게임은 진동을 직접 요청하지 않기 때문에, 빙수가 효과음 파일 이름을 보고 "이 소리가 나면 이렇게 울린다"는 표를 씁니다.

이 표는 **게임마다 JSON 파일 하나**입니다. 여러분의 게임용 파일을 하나 만들어 빙수 저장소에 PR 로 보내 주시면, 다음 빌드부터 그 게임에서도 패드가 울립니다.

**먼저:** 게임 코드를 고칠 수 있다면 표준 Gamepad API 로 진동을 직접 요청하는 게 가장 좋습니다(`navigator.getGamepads()[0].vibrationActuator.playEffect("dual-rumble", {duration, strongMagnitude, weakMagnitude})`). 빙수가 받아 컨트롤러로 전달하고, PC 크롬에서도 똑같이 울립니다. 이 진동표는 그렇게 하지 않는 게임을 위한 것입니다. 두 방식을 모두 시험해 볼 수 있는 작은 게임이 [`tools/rumble-lab`](../../tools/rumble-lab/README.md) 에 있습니다.

직접 요청하는 예시는 기본 게임 "Bingsu"([`SampleGame/dist/index.html`](../../BingsuApp/Bingsu/Resources/SampleGame/dist/index.html) 의 `rumble()`)입니다. 진동표 없이 한 그릇 완성·실수·단계 올라감 순간에 스스로 진동을 요청합니다.

진동표 실제 예시: [`pokerogue.json`](../../BingsuApp/Bingsu/Resources/Rumble/pokerogue.json) (웹 게임), [`resonance.json`](../../BingsuApp/Bingsu/Resources/Rumble/resonance.json) (로컬 게임), [`pokemon-z.json`](../../BingsuApp/Bingsu/Resources/Rumble/pokemon-z.json) (RPG Maker XP)

**Pokemon Essentials·PokeRogue 효과음을 그대로 쓰는 게임은 파일이 없어도 됩니다.** 빙수에는 여러 게임이 같이 쓰는 **기본 표**가 있어서, 게임 표가 없는 게임에도 아래 이름이 나오면 진동합니다. 게임 표를 만들 때도 기본 표를 `extends` 로 물려받고 다른 점만 적으면 됩니다.

| 기본 표 | 어떤 이름 | 예 |
|---|---|---|
| [`base-essentials`](../../BingsuApp/Bingsu/Resources/Rumble/base-essentials.json) | Essentials v19~21 | `Battle damage super`, `Battle ball shake`, `Pkmn faint` |
| [`base-essentials-classic`](../../BingsuApp/Bingsu/Resources/Rumble/base-essentials-classic.json) | Essentials v16~18 | `superdamage`, `ballshake`, `expfull` |
| [`base-pokerogue`](../../BingsuApp/Bingsu/Resources/Rumble/base-pokerogue.json) | PokeRogue `audio/se` | `pb_throw`, `pb_move`, `crit_throw` |

기본 표에는 다른 게임과 겹치지 않는 독특한 이름만 들어 있습니다. `hit`·`faint`·`throw` 같은 흔한 이름은 일반 RPG 에서도 쓰이므로 **게임 표에만** 적습니다.

**PR 없이 내 기기에서만 쓰기:** 게임 목록에서 게임칩을 꾹 눌러 "이 게임 설정 › 컨트롤러 진동"을 열면, 지금 쓰는 표(기본·게임 전용·직접 넣은 표)와 규칙 수를 보고 같은 형식의 JSON 을 그 게임에만 넣을 수 있습니다(`detect` 는 없어도 됨). 기기 안 `Documents/Rumble/<게임 id>.json` 에 저장되고 번들 표보다 먼저 쓰입니다. 같은 화면의 "지금 표 내보내기"로 기본 표나 빈 양식을 받아 고쳐 쓰면 편합니다. 검사 기준은 아래와 같고, 맞지 않으면 화면에 이유가 나옵니다.

## RPG Maker 게임이라면

코드를 고치지 않아도 됩니다. 빙수가 게임 안에서 다음 두 가지를 지켜봅니다.

| 엔진 | 효과음 | 화면 흔들림 |
|---|---|---|
| RPG Maker XP·VX·VX Ace | `Audio.se_play`·`Audio.me_play` 로 낸 소리. 게임 스크립트가 이 함수를 다시 정의해도(옛 Essentials) 따라갑니다 | `Game_Screen#start_shake(power, speed, duration)` |
| RPG Maker MV·MZ | Web Audio 로 재생한 소리 파일 | `Game_Screen.prototype.startShake(power, speed, duration)` |

- 효과음은 **진동표에 이름이 있을 때만** 울립니다. 이름은 폴더와 확장자를 빼고 소문자로 비교합니다(`Audio/SE/Battle damage normal` → `battle damage normal`).
- 화면 흔들림은 표와 상관없이 울립니다. 세기는 `power ÷ 9`, 길이는 `duration ÷ 40`초(0.08~0.5초)입니다. 이벤트에서 흔들기를 자주 쓰는 게임이라 거슬리면 게임 표에 `"shake": false` 를 넣어 주세요.
- 같은 순간에 효과음 진동과 흔들림 진동이 겹치면(0.15초 안) 센 쪽 하나만 울립니다.
- Essentials 효과음을 그대로 쓰는 포켓몬 팬게임은 위 기본 표 덕분에 파일이 없어도 전투 타격·기절·포획이 울립니다. 이름을 바꾼 소리만 게임 표에 적으면 됩니다.
- MV·MZ 플러그인에서 `navigator.getGamepads()[i].vibrationActuator` 로 직접 요청하는 진동도 그대로 전달됩니다.
- 어떤 소리를 어떤 상황(`event`)에 붙일지는 [1차 표](TABLE-v1.md)를 기준으로 합니다. 울음소리·메뉴·기술 효과음처럼 잦은 소리는 손이 피곤해서 넣지 않습니다.

## 파일 위치와 이름

```
BingsuApp/Bingsu/Resources/Rumble/<게임>.json
```

- 이름은 **영어 소문자·숫자·하이픈**만, 40자 이내 (`pokerogue.json`, `pokemon-xyz.json`). 다른 글자가 들어가면 빙수가 읽지 않습니다.
- 한 파일에 한 게임. 파일 크기는 **64KB 이하**.
- 이 폴더는 앱 번들에 폴더째 들어가므로 Xcode 프로젝트를 고칠 필요는 없습니다(빙수 쪽에서 `xcodegen generate` 만 다시 돌립니다).
- 두 파일이 같은 게임을 알아보면 파일 이름 알파벳 순서로 먼저인 것을 씁니다.

## 형식 (format 1)

```json
{
  "format": 1,
  "game": "내 팬게임",
  "source": "효과음 폴더: Audio/SE/*.ogg (v1.2 기준)",
  "detect": {
    "webHosts": ["mygame.example.com"],
    "localNames": ["my-fangame"]
  },
  "extends": ["base-essentials"],
  "rules": [
    {"sound": "hit_strong", "match": "exact", "event": "hit_super"},
    {"sound": "hit",        "match": "exact", "event": "hit_normal"},
    {"sound": "explosion",  "match": "prefix", "strong": 0.9, "weak": 0.4, "duration": 0.3, "note": "Explosion1·2·3"},
    {"sound": "ball shake", "match": "exact", "strong": 0.45, "weak": 0.2, "duration": 0.12, "repeats": 3, "gap": 0.35, "note": "볼 흔들림"}
  ]
}
```

### 효과음 이름은 확장자 없이 씁니다

빙수는 게임이 넘긴 소리 이름을 **폴더를 빼고, 소문자로, 오디오 확장자(`.wav` `.ogg` `.mp3` `.m4a` 등)를 빼고** 비교합니다. 웹 게임은 `hit.wav`, RPG Maker 게임은 `Audio/SE/Battle damage normal`(확장자 없음)처럼 넘기는데, 둘 다 `hit`, `battle damage normal` 이 됩니다. 그래서 규칙의 `sound` 도 확장자 없이 쓰고, 대부분 `exact` 면 됩니다.

예전 방식(`"hit."` + `prefix`, 즉 점을 붙여 확장자 앞까지 맞추기)도 그대로 읽습니다. 빙수가 읽을 때 `"hit"` + `exact` 로 바꿉니다. 확장자까지 적은 `exact`(`"lab_strong.wav"`)도 확장자를 빼고 읽어서, 같은 이름의 `.ogg` 도 맞습니다.

### 상황 (`event`)

숫자를 직접 적는 대신 상황 이름을 쓰면, 모든 게임에서 같은 순간에 같은 진동이 납니다. 패턴은 [`events.json`](../../BingsuApp/Bingsu/Resources/Rumble/events.json) 한 곳에 있습니다.

| `event` | 순간 | | `event` | 순간 |
|---|---|---|---|---|
| `hit_weak` | 효과가 별로인 타격 | | `ball_drop` | 볼이 땅에 떨어짐 |
| `hit_normal` | 일반 타격 | | `ball_shake` | 볼 흔들림 한 번 |
| `hit_super` | 효과가 굉장한 타격 | | `catch_click` | 포획 확정 |
| `faint` | 기절 | | `crit_throw` | 크리티컬 캡처 |
| `ball_throw` | 볼 던지기 | | `recall` | 볼이 열림: 내보내기·돌아오기 |
| `ball_hit` | 볼이 맞거나 튕김 | | `catch_absorb` | 볼에 빨려 들어감 (포획 중) |
| | | | `flee` | 도망 |
| | | | `level_up` | 레벨 업 |

어떤 소리를 어떤 상황에 붙일지 기준은 [`TABLE-v1.md`](TABLE-v1.md) (1차 표) 에 있습니다.

`event` 와 숫자를 같이 쓰면 적은 숫자만 바꿉니다(`{"sound": "boss hit", "match": "exact", "event": "hit_super", "duration": 0.4}`).

### 맨 위

| 필드 | 필수 | 설명 |
|---|---|---|
| `format` | 예 | 형식 버전. 지금은 `1` 만 읽습니다. 다른 숫자면 파일 전체를 무시합니다. |
| `game` | 아니오 | 사람이 읽는 게임 이름 (40자까지). 로그에만 쓰입니다. |
| `source` | 아니오 | 효과음을 어디서 찾았는지 메모. 빙수는 읽지 않습니다. |
| `detect` | 예 | 이 표를 어떤 게임에 쓸지. 아래 셋 중 하나 이상. |
| `extends` | 아니오 | 물려받을 기본 표 파일 이름 목록 (8개까지, 예 `["base-essentials"]`). 이 파일의 `rules` 를 먼저 보고, 맞는 게 없으면 적은 순서대로 기본 표를 봅니다. |
| `rules` | 예 | 효과음 → 진동 규칙 목록 (200개까지). **위에서부터 먼저 맞는 규칙 하나만** 씁니다. `extends` 가 있으면 비어 있어도 됩니다. |
| `kind` | 아니오 | 빙수 안쪽 파일용(`base`·`events`). 게임 표는 쓰지 않습니다. |
| `shake` | 아니오 | 화면 흔들림에도 진동할지 (기본 `true`). RPG Maker XP·VX·VX Ace 의 `Game_Screen#start_shake`, MV·MZ 의 `Game_Screen.prototype.startShake` 가 불릴 때 세기 `power/9`, 길이 `min(프레임/40, 0.5)`초로 울립니다. 흔들림이 너무 잦은 게임이면 `false`. 게임 표가 없는 게임은 늘 켜져 있습니다. |

**어떤 표를 쓰나:** 내가 넣은 표 → 게임 표(+ `extends`) → 게임 표가 없으면 기본 표 셋 전부.

### `detect` — 게임 알아보기

| 필드 | 설명 |
|---|---|
| `webHosts` | 웹 게임 주소의 호스트. `pokerogue.net` 이라고 쓰면 `pokerogue.net` 과 `beta.pokerogue.net` 같은 하위 도메인이 모두 맞습니다. 영어 소문자·숫자·`.`·`-` 만, 점 하나 이상. 8개까지. |
| `localNames` | 로컬 게임(압축 파일로 가져온 게임). 게임의 저장 폴더 이름(`package.json` 의 `name`, RPG Maker 는 `mkxp.json` 의 `dataPathApp` 또는 `Game.ini` 의 `Title`, Windows `%APPDATA%` 폴더 이름)이나 빙수 안 게임 id 에 이 글자가 **들어 있으면** 맞습니다(대소문자 무시). 3~60자, 8개까지. 너무 흔한 단어(`game`, `pokemon`)는 다른 게임까지 잡으니 피해 주세요. |
| `localExact` | `localNames` 와 같지만 **정확히 같을 때만** 맞습니다. `Pokemon Z` 처럼 짧은 이름이 `Pokemon Zeta` 까지 잡지 않게 할 때 씁니다. |

`webHosts` 는 웹 게임에만, `localNames`·`localExact` 는 로컬 게임에만 적용됩니다.

### `rules` 의 규칙 하나

| 필드 | 필수 | 범위 | 설명 |
|---|---|---|---|
| `sound` | 예 | 1~80자 | 효과음 이름(확장자 없이). 대소문자 무시. |
| `match` | 예 | `exact` `prefix` `suffix` `contains` | `sound` 와 비교하는 방법: 정확히 같음 / 그걸로 시작 / 그걸로 끝남 / 어딘가 들어 있음. 정규식은 받지 않습니다. |
| `event` | 아래 셋 대신 | 상황 이름 | `events.json` 의 패턴을 씁니다. 함께 적은 숫자만 덮어씁니다. 없는 이름이면 이 규칙만 버립니다. |
| `strong` | `event` 없으면 예 | 0~1 | 저주파(묵직한, 큰) 모터 세기. |
| `weak` | `event` 없으면 예 | 0~1 | 고주파(가벼운, 작은) 모터 세기. |
| `duration` | `event` 없으면 예 | 0.02~2 | 한 번 울리는 길이(초). |
| `repeats` | 아니오 | 1~10, 기본 1 | 반복 횟수 (볼 흔들림 3번 등). |
| `gap` | 아니오 | 0~1, 기본 0 | 반복 사이 쉬는 시간(초). |
| `sharpness` | 아니오 | 0~1 | 날카로움. 0 쪽은 둔하고 묵직하게(큰 모터), 1 쪽은 가볍고 또렷하게(작은 모터). 빼면 `strong ≥ weak` 일 때 0.2, 아니면 0.7. |
| `note` | 아니오 | | 메모. 빙수는 읽지 않습니다. |

범위를 벗어난 숫자는 범위 끝으로 잘립니다. 필수 필드가 빠졌거나 `match` 가 틀린 규칙은 그 규칙만 버립니다.

**한 소리만 맞추려면 `exact` 를 쓰세요.** `"hit"` + `exact` 는 `hit.wav`·`hit.ogg` 만 맞고 `hit_strong.wav` 는 안 맞습니다. `"hit"` + `prefix` 는 `hit_strong`, `hitch` 까지 다 잡습니다. `prefix` 는 `Explosion1`·`Explosion2` 처럼 번호가 붙는 묶음에 쓰고, 더 구체적인 규칙을 위에 두세요.

## 효과음 이름 알아내는 법

빙수가 실제로 보는 이름은 **파일 이름만**입니다(폴더·쿼리 문자열 제외, 소문자로 바꿈, 80자까지). 웹 게임은 `XMLHttpRequest`/`fetch` 로 받은 오디오를 `decodeAudioData` 로 풀어 `AudioBufferSourceNode.start()` 로 재생할 때 잡힙니다. Howler.js·Phaser 같은 Web Audio 기반 엔진은 대부분 그대로 됩니다.

가장 확실한 방법은 빙수 개발 빌드로 게임을 돌려 로그를 보는 것입니다.

1. Xcode 에서 Bingsu 스킴 › Edit Scheme › Run › Arguments › Environment Variables 에 `BINGSU_KEYDEBUG = 1` 추가 (원하면 `BINGSU_OPEN = <게임 id>` 로 실행하자마자 그 게임을 엶)
2. 게임을 하면서 Xcode 콘솔(또는 Console.app, 프로세스 `Bingsu`)에서 다음 줄을 봅니다.
   ```
   [Bowl] sfx hit.wav                 ← 표에 없는 효과음
   [Bowl] sfx hit_strong.wav -> rumble  ← 표가 맞아서 진동을 보냄
   [Rumble] 진동표 3개: mygame(12), pokerogue(14), resonance(10)
   [Rumble] mygame: rules[3] 에 ... (이 규칙만 무시)
   [BrassBowl] sfx battle damage normal -> rumble   ← RPG Maker XP·VX·VX Ace 게임
   [BrassBowl] sfx gui sel cursor (표에 없음)
   [BrassBowl] shake power=9 frames=20 -> rumble   ← 화면 흔들림 (MV·MZ 는 [Bowl] shake …)
   ```
   효과음 진동과 화면 흔들림 진동이 0.15초 안에 겹치면 센 쪽 하나만 울립니다. RPG Maker XP·VX·VX Ace 게임은 `Audio.se_play`·`me_play` 로 낸 소리가 폴더·확장자를 뺀 이름으로 찍힙니다. `BINGSU_KEYDEBUG` 를 켜지 않으면 표에 있는 이름만 빙수로 넘어옵니다.
3. 피격·기절·포획·진화 같은 "손에 느껴졌으면 하는" 순간의 이름을 골라 규칙을 만듭니다.

게임 소스나 에셋 폴더(`audio/se`, `Audio/SE` 등)의 파일 목록을 봐도 되지만, 실제로 어떤 순간에 어떤 소리가 나는지는 로그로 확인하는 편이 정확합니다.

## 진동 세기 설계 팁

- **블루투스 패드는 세기를 켜짐/꺼짐으로만 받는 경우가 많습니다.** 예를 들어 IINE Retro 는 DualShock·Xbox·스위치 흉내 모드 모두 그렇습니다. 이런 패드에서는 `strong 0.2` 와 `1.0` 이 똑같이 느껴지고, **길이(`duration`)만 체감 차이를 만듭니다.** 전체 크기는 사용자가 패드 자체 진동 단계로 조절합니다. 또 빙수는 컨트롤러 진동을 **최소 0.2초**로 보냅니다(그보다 짧으면 모터가 돌기 전에 끝나 거의 안 느껴짐). 그러니 0.2초보다 짧은 값끼리는 차이가 없습니다.
- 폰 햅틱(컨트롤러가 없을 때)은 세기 값을 정확히 따릅니다.
- 사용자 설정의 진동 세기(기본 70%)가 여러분 값에 곱해집니다. 사용자가 바꿀 수 있는 건 진동 켬/끔과 이 세기뿐입니다. 가장 센 순간(치명타·기절)을 1.0 근처로, 나머지는 그보다 낮게 상대적으로 잡으세요.
- **너무 자주 울리지 않게 하세요.** 블루투스 패드 진동 명령과 블루투스 이어폰 소리는 폰의 무선 하나를 나눠 써서, 진동이 잦으면 이어폰 소리가 지직거릴 수 있습니다. 빙수는 소리가 블루투스로 나갈 때 (설정 "블루투스 이어폰일 때 진동 줄이기", 기본 켬) 진동을 펄스 없이 한 덩어리로, 최대 0.25초, 반복 없이, 앞 진동과 0.3초 안이면 건너뛰게 바꿉니다. 그러니
  - 메뉴 이동·글자 출력·발소리처럼 **연달아 나는 소리에는 규칙을 만들지 마세요.**
  - 0.3초보다 짧은 간격의 `repeats` 는 블루투스 보호 중에 첫 번만 울립니다. 중요한 건 첫 번에 담으세요.
  - 0.5초가 넘는 긴 진동은 대부분 불쾌합니다. 0.2~0.35초가 무난합니다(컨트롤러는 0.2초 미만을 0.2초로 늘림).
- 진동이 겹치면 새 진동이 앞 진동을 끊고 시작합니다.

## 추가 절차 (PR)

1. 이 저장소를 포크하고 `BingsuApp/Bingsu/Resources/Rumble/<게임>.json` 을 추가합니다. 다른 파일은 건드리지 않아도 됩니다.
2. 가능하면 빙수 개발 빌드로 직접 돌려 `[Rumble] 진동표 …` 줄에 여러분 파일이 보이는지, 원하는 효과음에 `-> rumble` 이 붙는지 확인합니다.
3. PR 설명에 게임 이름·배포 주소(또는 로컬 게임이면 저장 폴더 이름)·확인한 방법을 적어 주세요. **게임 파일·에셋은 올리지 마세요.** 효과음 이름만 있으면 됩니다.
4. 빙수 쪽에서 검토 후 병합하면 다음 빌드부터 적용됩니다.

빙수는 이 파일을 믿지 않는 데이터로 다룹니다: 크기·개수·값 범위를 검사하고, 읽을 수 없거나 `format` 이 다른 파일은 로그만 남기고 건너뜁니다. 그래서 파일 하나가 깨져도 다른 게임의 진동에는 영향이 없습니다.

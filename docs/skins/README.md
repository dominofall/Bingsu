# 가상 패드 스킨 · 배치 — 만드는 사람 안내

빙수의 가상 패드는 **자리(배치)** 와 **생김새(스킨)** 를 따로 다룹니다.

- **배치**는 빙수가 기기·화면 방향·패드 종류(기본·스틱·Xbox 전체·레트로·한손)에 맞춰 계산하고, 앱 안 "가상 패드 배치" 편집기에서 사용자가 끌어서 바꿀 수 있습니다.
- **스킨**은 버튼·십자키·스틱 하나하나의 색과 그림입니다. 자리는 들어 있지 않아서, 어떤 배치·기기에서든 같은 스킨이 그대로 쓰입니다.

스킨은 폴더 하나(`skin.json` + 선택적 PNG)를 zip 으로 묶은 **`.bingsuskin`** 파일입니다. 색만 적은 스킨은 `skin.json` 하나면 됩니다. 여러분이 만든 스킨을 빙수 저장소에 PR 로 보내 주시면 다음 빌드부터 앱에 들어갑니다.

**PR 없이 내 기기에서만 쓰기:** `.bingsuskin`(또는 `skin.json` 이 든 `.zip`)을 Files 앱에서 열어 "빙수로 열기", 또는 설정 › 가상 패드 › 스킨 › "파일에서 가져오기". 기기 안 `Documents/Skins/<id>/` 에 저장됩니다. 검사에 걸리면 이유가 화면에 나옵니다(아래 "검사 기준").

**가장 쉬운 시작:** 설정 › 가상 패드 › 스킨에서 아무 스킨이나 "복제해서 고치기" → 색·모양을 만지고 저장 → "내보내기"로 `.bingsuskin` 을 받습니다. 그 파일의 `skin.json` 을 고치거나 PNG 를 더 넣으면 됩니다. 앱에 든 스킨 예시: [`ice`](../../BingsuApp/Bingsu/Resources/Skins/ice/skin.json)(기본, 색만), [`blocks`](../../BingsuApp/Bingsu/Resources/Skins/blocks/skin.json)(그림 스킨).

## 파일 위치와 이름

```
BingsuApp/Bingsu/Resources/Skins/<id>/skin.json
BingsuApp/Bingsu/Resources/Skins/<id>/*.png        (그림 스킨만)
```

- `<id>` 는 **영어 소문자·숫자·하이픈**, 2~40자, `skin.json` 의 `id` 와 같아야 합니다. 앱에 든 스킨 id(`ice`, `glass`, `retro-gray`, `neon`, `outline`, `contrast`, `blocks`)와 겹치면 가져오지 않습니다.
- PNG 파일 이름은 영어 소문자·숫자·`_`·`-`, 확장자 `.png`. 하위 폴더는 읽지 않습니다(`__MACOSX`·`.DS_Store` 는 조용히 무시).
- 폴더는 앱 번들에 폴더째 들어가므로 Xcode 프로젝트를 고칠 필요가 없습니다(빙수 쪽에서 `xcodegen generate` 만 다시 돌립니다).

## `skin.json` (format 1)

```json
{
  "format": 1,
  "id": "retro-gray",
  "name": "레트로 회색",
  "author": "홍길동",
  "license": "CC0-1.0",
  "note": "게임보이 몸체색. 레트로 배치와 어울려요.",

  "colors": {
    "ink": "#6B6760",
    "text": "#3A3835",
    "fill": "#C8C4BC",
    "fillTop": 0.25,
    "shadeBottom": 0.2,
    "shade": "#000000",
    "rim": 1.0,
    "lineWidth": 1.5,
    "press": "#D94A7A",
    "dpad": "#3B3B3B",
    "stick": "#3B3B3B"
  },
  "shape": { "kind": "circle" },
  "labels": { "style": "retro", "font": "rounded", "overrides": { "x": "X", "y": "Y" } },
  "buttonColors": { "a": "#8C2F5A", "b": "#8C2F5A" },

  "images": {
    "button.round": { "normal": "round.png", "pressed": "round-on.png" },
    "button.pill":  { "normal": "pill.png", "pressed": "pill-on.png", "capInsets": 14 },
    "button.a":     { "normal": "a.png", "pressed": "a-on.png", "label": false },
    "dpad":         { "normal": "dpad.png", "pressedArm": "dpad-up-on.png" },
    "stick.base":   { "normal": "stick-base.png" },
    "stick.knob":   { "normal": "stick-knob.png", "pressed": "stick-knob-on.png" },
    "orb":          { "normal": "pause.png" }
  }
}
```

### 맨 위

| 필드 | 필수 | 설명 |
|---|---|---|
| `format` | 예 | 형식 버전. 지금은 `1` 만 읽습니다. 다른 숫자면 파일 전체를 무시합니다. |
| `id` | 예 | 폴더 이름과 같은 식별자. 사용자가 고른 스킨은 이 값으로 기억되므로 한번 공개한 뒤 바꾸지 마세요. |
| `name` | 예 | 화면에 보이는 이름(40자까지). |
| `author` | PR 때 예 | 작성자. 설정 › 스킨 목록에 "만든 사람"으로 보입니다(60자까지). |
| `license` | PR 때 예 | SPDX 식별자(`CC0-1.0`, `CC-BY-4.0`, `MIT`). 앱에 들어가는 스킨은 이 셋 중 하나여야 합니다. 다른 사람의 그림(게임기 로고·게임 아트 포함)은 넣지 마세요. |
| `note` | 아니오 | 한 줄 설명(80자까지). |
| `colors` `shape` `labels` `buttonColors` `images` | 아니오 | 모두 선택. 없는 값은 기본 스킨 "얼음"의 값을 씁니다. |

### `colors` — 색

색은 `#RRGGBB` 또는 `#RRGGBBAA`. 사용자의 **불투명도 슬라이더**(0.25~0.9)는 모든 채움·테두리에 곱해지므로, 스킨은 "슬라이더 1.0 일 때"의 모습을 적는다고 생각하면 됩니다.

| 필드 | 기본(얼음) | 설명 |
|---|---|---|
| `ink` | `#FFFFFF` | 테두리와 위쪽 밝은 빛의 색 |
| `text` | = `ink` | 버튼 글자·십자키 화살표 색 |
| `fill` | 없음 | 버튼 바탕을 채우는 단색. 없으면 투명 위에 빛·그늘 그라데이션만 |
| `fillTop` | `0.3` | 위쪽 `ink` 빛의 진하기 0~1 |
| `shadeBottom` | `0.3` | 아래쪽 `shade` 그늘의 진하기 0~1 |
| `shade` | `#000000` | 아래쪽 그늘 색 |
| `rim` | `1.1` | 테두리 진하기 0~1.5 |
| `lineWidth` | `1` | 테두리 굵기 0~4 (pt) |
| `press` | `#6EC2E8` | 눌렸을 때 채우는 색 |
| `dpad` | = `fill` | 십자키 바탕색 |
| `stick` | = `fill` | 스틱 바닥·손잡이 바탕색 |

### `shape` — 둥근 버튼 모양

`{"kind": "circle"}`(기본) 또는 `{"kind": "squircle", "corner": 0.4}`. `corner` 는 반지름 대비 모서리 둥글기 0.2~0.5. 알약 버튼(L·R·−·+ 등)은 늘 캡슐이고 십자키는 늘 십자입니다.

### `labels` — 글자

| 필드 | 설명 |
|---|---|
| `style` | 버튼 글자 세트. `xbox`(기본: A B X Y · LB RB LT RT · ⧉ ≡), `switch`(A B X Y · L R ZL ZR · − +), `playstation`(○ × △ □ · L1 R1 L2 R2 · SHARE OPTIONS), `retro`(A B X Y · L R L2 R2 · SELECT START), `none`(글자 없음). |
| `font` | `rounded`(기본) · `default` · `mono` · `serif` |
| `overrides` | 버튼별 글자 덮어쓰기, 8자까지. 키는 `a b x y lb rb lt rt view menu l3 r3`. |

빙수의 배치 종류가 정하는 글자(기본 배치의 L·R·−·+, 레트로의 SELECT·START)보다 `overrides` 가 우선하고, `style` 은 그 밖의 버튼에만 적용됩니다.

### `buttonColors` — 버튼별 바탕색

`{"a": "#C8343E", "b": "#F2C032", "x": "#2A6BD6", "y": "#3BA55D"}` 처럼 버튼마다 `fill` 을 덮어씁니다. 눌리면 그 색을 25% 밝게 합니다(`press` 대신).

### `images` — 그림 (그림 스킨)

요소 키마다 PNG 를 줍니다. 그림이 있는 요소는 색·그라데이션·테두리를 그리지 않고 그림만 그립니다. 빠진 요소는 위의 색 값으로 그립니다(부분 스킨 가능).

| 키 | 그림의 쓰임 | 비고 |
|---|---|---|
| `button.a` … `button.r3` | 그 버튼만 | 개별 키가 공통 키보다 우선 |
| `button.round` | 둥근 버튼 공통 (A B X Y L3 R3) | 정사각 PNG, 원형으로 그립니다 |
| `button.pill` | 알약 버튼 공통 (LB RB LT RT 보기 메뉴) | 가로로 늘어나므로 `capInsets` 로 9-slice 지정 |
| `dpad` | 십자키 전체 | `normal` 은 정사각. `pressedArm` 은 **위쪽 팔이 눌린** 그림 하나(정사각, 다른 방향은 빙수가 돌려서 씀) |
| `stick.base` `stick.knob` | 스틱 바닥 / 손잡이 | 정사각. 손잡이 `pressed` 는 스틱을 잡고 있을 때 |
| `orb` | 일시정지(눈송이) 버튼 | 정사각 |

각 항목의 값:

| 필드 | 설명 |
|---|---|
| `normal` | 기본 그림 파일 이름 (필수) |
| `pressed` | 눌린 그림. 없으면 `normal` 위에 `press` 색을 덮습니다 |
| `pressedArm` | `dpad` 전용 (위 참고) |
| `capInsets` | 9-slice 안쪽 여백(px). 숫자 하나 또는 `{"top":…,"left":…,"bottom":…,"right":…}`. 알약 버튼에 권장 |
| `label` | `false` 면 이 요소 위에 글자를 안 그립니다(PNG 에 글자를 넣었을 때) |

PNG 규칙: 한 변 **32~1024px**, 정사각(알약은 가로가 길어도 됨), 투명 배경 권장. 빙수는 표시 크기에 맞춰 줄여 그리므로 256~512px 이면 충분합니다. 버튼은 화면에서 지름 30~70pt 로 보입니다.

## 배치 파일 `layouts.json` (선택)

스킨 zip 에 `layouts.json` 을 함께 넣으면, 가져온 뒤 "이 스킨이 권하는 배치도 쓸까요?" 를 묻고 사용자가 수락하면 그 배치가 적용됩니다. 손으로 쓰기보다 **앱의 배치 편집기에서 "배치 내보내기"** 로 받는 것이 쉽습니다. 형식은 편집기가 저장하는 것과 같습니다.

```json
{
  "format": 1,
  "layouts": {
    "phone.landscape.simple": {
      "elements": [
        {"type": "dpad",   "anchor": "bottomLeft",   "x": 94,  "y": -94, "radius": 62},
        {"type": "button", "button": "a", "anchor": "bottomRight", "x": -50, "y": -96, "radius": 26},
        {"type": "button", "button": "menu", "anchor": "bottomCenter", "x": 48, "y": -39, "radius": 15, "pill": true, "label": "+"},
        {"type": "stick",  "side": "left", "anchor": "bottomLeft", "x": 94, "y": -94, "radius": 48, "floating": true},
        {"type": "orb",    "anchor": "bottomCenter", "x": 0, "y": -70}
      ]
    }
  }
}
```

- 키는 `<기기>.<방향>.<패드 종류>`: 기기 `phone`·`pad`, 방향 `landscape`·`portrait`, 종류 `simple`·`standard`·`full`·`retro`·`oneHand`. 없는 키는 빙수 기본 배치를 씁니다. 한손은 가로에서 기본 배치로 그려지므로 `*.landscape.oneHand` 는 쓰이지 않고 `*.landscape.simple` 을 씁니다.
- 한손 배치는 **오른손 기준**으로 적습니다. 사용자가 "왼손으로 쓰기"를 켜면 빙수가 좌우를 뒤집어 그립니다.
- `anchor` 는 안전 영역 안쪽의 기준점: `topLeft` `topCenter` `topRight` `bottomLeft` `bottomCenter` `bottomRight`. `x`·`y` 는 그 기준점에서의 거리(오른쪽·아래가 +), `radius` 는 반지름. 단위는 **배치 포인트**로, 사용자의 크기 슬라이더(0.8~1.3)와 iPad 배율(1.4)이 곱해져 화면 pt 가 됩니다. 기본 반지름: 둥근 버튼 26, 숄더 알약 23, 보기·메뉴 15, 십자키 62, 스틱 48.
- `type`: `button`(`button` 키 필수, `pill`·`label`·`stretch` 선택), `dpad`, `stick`(`side` left/right, `floating`), `orb`(일시정지 버튼. 사용자의 "일시정지 버튼 자리" 설정이 "패드 안"일 때만 쓰임). `button` 이름: `a` `b` `x` `y` `lb` `rb` `lt` `rt` `view` `menu` `l3` `r3` `home`.
- 스틱의 `floating` 을 적지 않으면 사용자의 "움직이는 스틱" 설정을 따릅니다.
- 같은 요소가 두 번 나오면 뒤의 것을, 한 종류에 40개 넘는 요소는 거절합니다. 모르는 `type`·`button`·`anchor` 가 든 요소는 그 요소만 버리고, 모르는 키는 그 키만 버립니다. 숫자가 범위를 벗어나면 범위 안으로 맞춥니다.

## 검사 기준 (맞지 않으면 가져오지 않습니다)

- zip 전체 10MB 이하, 파일 40개 이하, `skin.json` 64KB 이하, `layouts.json` 64KB 이하. 실행 파일·스크립트·기타 확장자는 거절, PNG 가 아닌데 `.png` 인 파일(매직 바이트 확인)도 거절.
- PNG 24개 이하, 각각 32~1024px. `images` 가 가리키는 파일이 없으면 그 항목만 무시하고 알립니다.
- `format` 이 1 이 아니거나 `id`·`name` 이 없거나 규칙에 안 맞으면 전체 거절. 색 문자열이 틀리면 그 값만 기본값.
- zip 안 경로에 `..`·절대 경로·심볼릭 링크가 있으면 거절(zip slip).
- 같은 `id` 의 사용자 스킨이 이미 있으면 **덮어씁니다**(업데이트). 앱에 든 스킨 id 와 같으면 거절합니다. 단 `layouts.json` 이 들어 있으면 스킨은 넣지 않고 그 배치만 권합니다(앱에 든 스킨에 맞춘 배치를 나눌 때).

## 빙수 쪽 처리 (참고)

- 스킨을 고르는 자리: 설정 › 가상 패드 › 스킨(전역), 게임칩 꾹 누르기 › 이 게임 설정 › 가상 패드(게임별), 게임 중 일시정지 패널 › 조작(이 게임에만 저장).
- 가져오는 길: 설정 › 가상 패드 › 스킨 › 관리… › 파일에서 가져오기, 또는 게임 추가(+)·Files 의 "다음으로 열기"로 `.bingsuskin`(또는 `skin.json` 이 든 zip)을 열면 빙수가 게임이 아닌 스킨으로 알아보고 넣습니다. 이 길로 받은 권하는 배치는 전역 설정에 들어갑니다.
- 고른 스킨 파일이 기기에 없으면(지웠거나 iCloud 로 설정만 넘어온 다른 기기) 조용히 "얼음"으로 그립니다. 스킨 파일은 iCloud 로 동기화하지 않습니다.
- 그림은 처음 쓸 때 한 번 512px 이하로 줄여 메모리에 올리고 게임 중에는 다시 디코딩하지 않습니다. 흐림(blur) 합성은 쓰지 않습니다(게임 위 발열).

## PR 보내기

1. `BingsuApp/Bingsu/Resources/Skins/<id>/` 에 폴더를 넣습니다. `license` 는 `CC0-1.0`·`CC-BY-4.0`·`MIT` 중 하나, 직접 그린 그림만.
2. 기기에서 `.bingsuskin` 으로 가져와 기본·스틱·Xbox 전체·레트로·한손 다섯 배치와 가로·세로에서 한 번씩 확인한 스크린샷을 PR 에 붙여 주세요.
3. 빙수가 `xcodegen generate` 와 시뮬레이터 확인을 거쳐 다음 빌드에 넣고, 설정 › 오픈소스 라이선스와 스킨 목록에 작성자를 표시합니다.

# 가상 패드 스킨 + 배치 편집기 — 구현 명세 (빌드 24)

2026-11-01 결정. 한 빌드에 **스킨**(형식·번들 7종·가져오기·색 디자이너·문서)과 **배치 편집기**(끌어 옮기기·크기·요소 켜고 끄기·게임별·방향별 저장)를 함께 넣는다. 사용자용 형식 문서는 [`README.md`](README.md), 이 파일은 구현 세션(Opus, 워크트리)을 위한 명세다. 모르는 결정이 나오면 이 문서의 원칙(§0)으로 판단하고, 그래도 갈리면 부모 세션에 묻는다.

## 0. 원칙

- **자리와 생김새 분리.** 배치(`SpoonLayout`)는 빙수가 계산하거나 사용자가 편집하고, 스킨(`SpoonSkin`)은 요소별 색·그림만 가진다. Delta 식 "화면 전체 그림 + 좌표"는 하지 않는다.
- **예전 빌드 설정과 호환.** `PadPrefs`·`DishPrefs` 에 더하는 필드는 전부 옵셔널, 빠지면 지금과 똑같이 동작. 저장 raw 값(`PadKind` 등)은 바꾸지 않는다.
- **게임 위 발열·메모리.** 흐림 합성 없음(지금과 같음), 스킨 그림은 한 번 디코딩(≤512px)해 재사용, 매 프레임 새로 그리는 것은 눌림 상태 변화뿐.
- **외부 파일은 믿지 않는다**(PLAN 8장, `RumbleShelf` 와 같은 태도): 크기·개수·형식·매직 바이트·경로 검사, 깨진 것은 이유와 함께 거절, 부분 오류는 그 항목만 무시하고 로그.
- **화면 문구는 평범한 한국어**: "스킨", "가상 패드 배치", "배치 편집". 코드 이름은 빙수 테마(아래 표).
- 한 기능씩 커밋, 커밋 메시지·주석 한국어. 게임 원본·`Games/`·팀 ID 커밋 금지.

| 개념 | 화면 | 코드 |
|---|---|---|
| 스킨 값 한 벌 | 스킨 | `SpoonSkin` (있음, 확장) |
| 스킨 읽기·검사·저장소 | — | `SkinShelf` (`Spoon/SkinShelf.swift`) |
| 색 스킨 편집 화면 | 스킨 만들기 | `SkinDesigner` (`Kitchen/SkinDesigner.swift`) |
| 스킨 고르기 줄 | 스킨 | `SkinPicker` (`Kitchen/SkinPicker.swift`) |
| 사용자 배치 한 벌 | 가상 패드 배치 | `PadArrangement` (`Spoon/PadArrangement.swift`) |
| 배치 편집 화면 | 배치 편집 | `SpoonLayoutEditor` (`Spoon/SpoonLayoutEditor.swift`, PLAN 7.1 에 이미 있음) |

## 1. 데이터 모델

### 1.1 `PadPrefs` 확장 (`Kitchen/DishPrefs.swift`)

```swift
var skin: String? = nil                       // 스킨 id. nil = "ice"
var layouts: [String: PadArrangement]? = nil  // 키 "<idiom>.<orientation>.<kind>", 없으면 기본 배치
```

- `PadPrefs.global()`: `spoon.skin`(String), `spoon.layouts`(JSON `Data`) 를 UserDefaults 에서 읽는다. `SettingsView` 의 `globalPad` 바인딩 setter 도 두 키를 쓴다.
- `init(from:)` 에 `decodeIfPresent` 두 줄 추가. 인코딩은 기본 합성.
- `effectiveSkin: String { skin ?? "ice" }`, `arrangement(idiom:orientation:kind:) -> PadArrangement?` 헬퍼.
- Igloo(`Freezer/Igloo.swift`)는 `Prefs/<id>.json` 을 이미 동기화한다. 파일 상한 64KB 안에 들어가는지 확인(배치 4키 × 20요소 ≈ 6KB). 스킨 **파일**은 동기화하지 않는다(용량). 다른 기기에 없는 스킨 id 는 `SkinShelf.skin(id:)` 가 `ice` 로 폴백.

### 1.2 `PadArrangement` (`Spoon/PadArrangement.swift`)

```swift
struct PadArrangement: Codable, Equatable {
    enum Anchor: String, Codable { case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight }
    struct Element: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case button, dpad, stick, orb }
        var type: Kind
        var button: PadButton? = nil      // type == .button (rawValue 대신 이름 문자열로 인코딩: "a","lb",… — PadButton 에 String 변환 추가)
        var side: String? = nil           // type == .stick: "left" | "right"
        var anchor: Anchor
        var x: Double, y: Double          // 배치 포인트 (화면 pt / k, k = scale × deviceFactor)
        var radius: Double                // 배치 포인트. pill 은 반높이, stick 은 baseRadius, dpad 는 dpadRadius
        var pill: Bool? = nil, stretch: Double? = nil, label: String? = nil   // button
        var floating: Bool? = nil         // stick
        var id: String { … type+button+side 로 유일 }
    }
    var elements: [Element]
}
```

- 키: `PadArrangement.key(idiom: UIUserInterfaceIdiom, landscape: Bool, kind: PadKind) -> String` → `"phone.landscape.simple"` 처럼. `.pad` 는 `pad`, 나머지는 `phone`.
- 단위가 배치 포인트인 이유: 기존 크기 슬라이더(0.8~1.3)와 iPad 배율(`SpoonLayout.deviceFactor` 1.4)이 그대로 먹게. 저장할 때 `/k`, 그릴 때 `×k`.
- `anchor` 기준점: 안전 영역 안쪽 모서리·변 가운데. `make` 가 지금 쓰는 `max(safe.left, 16)` 같은 여백은 넣지 않고 순수 안전 영역 기준(여백은 x·y 에 들어 있음).

### 1.3 `SpoonSkin` 확장 (`Spoon/SpoonFace.swift` → 새 파일 `Spoon/SpoonSkin.swift` 로 옮김)

```swift
struct SpoonSkin {
    var id = "ice", name = "얼음", author: String? = nil, license: String? = nil, note: String? = nil
    var ink = Color.white, text: Color? = nil, fill: Color? = nil, shade = Color.black
    var fillTop = 0.3, shadeBottom = 0.3, rim = 1.1, lineWidth: CGFloat = 1
    var press = Color(red: 0.43, green: 0.76, blue: 0.91)
    var dpadFill: Color? = nil, stickFill: Color? = nil
    enum Shape { case circle, squircle(corner: CGFloat) }; var shape = Shape.circle
    enum LabelStyle: String { case xbox, `switch`, playstation, retro, none }
    var labelStyle = LabelStyle.xbox, font = Font.Design.rounded, overrides: [PadButton: String] = [:]
    var buttonColors: [PadButton: Color] = [:]
    struct Picture { var normal: UIImage; var pressed: UIImage?; var pressedArm: UIImage?; var capInsets: UIEdgeInsets?; var showsLabel = true }
    var images: [String: Picture] = [:]      // "button.a", "button.round", "button.pill", "dpad", "stick.base", "stick.knob", "orb"
    var isBundled = true
    static let ice = SpoonSkin()
    func picture(for slot: PadButtonSlot) -> Picture?   // 개별 키 → round/pill 공통 키
    func glyph(_ b: PadButton, layoutLabel: String?) -> String?   // overrides > layoutLabel > style 표 > PadButton.glyph; none 이면 nil
}
```

`labelStyle` 표(스타일 → 버튼 글자)는 README 의 네 세트 그대로 상수로 둔다.

## 2. `SkinShelf` — 읽기·검사·저장소 (`Spoon/SkinShelf.swift`)

- 번들: `Resources/Skins/<id>/`(폴더 리소스, `project.yml` 에 `Rumble` 과 같은 방식으로 `type: folder`, sources `excludes` 에도 추가). 사용자: `Documents/Skins/<id>/`.
- `static func list() -> [SkinSummary]`(id·name·author·isBundled, 번들 먼저 id 순 → 사용자 수정일 순), `static func skin(id:) -> SpoonSkin`(캐시, 없으면 `.ice` 로그 1회), `forget(id)`.
- 읽기: `skin.json` 64KB 상한 → `JSONDecoder` 로 모든 필드 옵셔널인 `RawSkin` → 검사 → `SpoonSkin`. 색은 `#RRGGBB`/`#RRGGBBAA` 만, 틀리면 그 값만 기본. 숫자는 범위로 자른다(README 표의 범위).
- 그림: `images` 각 파일 → 이름 규칙·존재·PNG 매직(`89 50 4E 47 0D 0A 1A 0A`)·픽셀 크기 32~1024(`CGImageSourceCopyPropertiesAtIndex` 로 디코딩 전에 확인) → `CGImageSourceCreateThumbnailAtIndex`(`kCGImageSourceThumbnailMaxPixelSize` 512, `kCGImageSourceCreateThumbnailFromImageAlways`) 로 디코딩 → `UIImage(cgImage:scale:1,orientation:.up)`. 빠진 파일은 그 항목만 무시하고 `[Skin]` 로그. PNG 24개 초과면 거절.
- 가져오기 `static func importZip(at url: URL) throws -> ImportResult`:
  1. `SafeUnzip`(있음) 으로 `Documents/Skins/.import-<uuid>/` 에 풀기. zip 10MB·파일 40개 상한은 풀기 전에 중앙 디렉터리로 확인(`SafeUnzip` 이 주는 항목 목록 사용, 없으면 추가).
  2. 루트(또는 유일한 하위 폴더 — macOS 가 폴더를 압축하면 한 단계 들어감) 에서 `skin.json` 찾기. `__MACOSX`·`.DS_Store` 무시. 그 밖의 확장자가 있으면 거절("스킨 파일이 아닌 것이 들어 있어요: foo.js").
  3. 위 읽기 검사 통과 → `id` 가 번들 id 와 같으면 거절 → `Documents/Skins/<id>/` 를 통째로 교체(옆 이름으로 바꾼 뒤 옮기고, 실패 시 되돌림; `Delivery` 의 업데이트 교체와 같은 수법) → `forget(id)`.
  4. `layouts.json` 이 있으면 `PadArrangementFile`(format 1, `layouts` 사전) 로 읽어 결과에 담는다(적용은 UI 가 묻고 함).
  5. 결과: `ImportResult(id, name, replaced: Bool, layouts: [String: PadArrangement]?, warnings: [String])`.
- 내보내기 `static func exportZip(id:) throws -> URL`: 폴더를 `Library/Caches/Export/<id>.bingsuskin` 으로 압축(ZIPFoundation). 번들 스킨도 가능(양식 용도). `layouts` 를 함께 넣는 변형(`exportZip(id:layouts:)`) 은 편집기 "배치 내보내기"가 쓴다.
- 사용자 스킨 저장 `static func saveUser(_ skin: SpoonSkin / RawSkin) throws`(디자이너가 씀), `removeUser(id)`.
- `Rejection(reason:)` 오류 타입은 `RumbleShelf` 와 같은 모양. 문구 예: "zip 이 10MB 를 넘어요 · 13.2MB", "skin.json 이 없어요", "앱에 든 스킨과 이름이 같아요 (retro-gray)", "PNG 가 아니에요: a.png", "그림이 너무 커요: dpad.png 2048px (1024 이하)".

## 3. 배치 계산 (`Spoon/SpoonModel.swift`)

- 새 진입점 하나로 모은다:
  ```swift
  static func make(prefs: PadPrefs, size: CGSize, safe: …, idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> SpoonLayout
  ```
  내부: 가로/세로·종류로 키를 만들어 `prefs.layouts?[key]` 가 있으면 `resolve(arrangement, …)`, 없으면 지금의 `make(size:safe:kind:scale:floatingStick:leftHanded:)`. 호출처 전부 교체: `SpoonOverlay`, `BowlContainerView`(3곳: 오버레이·눈송이 자리·`padLayout`), `SpoonPreview`, `PauseBoard` 썸네일(있으면).
- `resolve`: 요소마다 `center = anchorPoint + (x, y) × k`, `radius × k`, 화면 밖으로 나가면 반지름만큼 안쪽으로 clamp. 버튼 → `PadButtonSlot`(pill·stretch·label 그대로), dpad → `dpadCenter/Radius`, stick → `StickSlot`(knob = radius×0.46, travel = radius×0.7, floating 이면 zone = 그 쪽 절반 폭(왼쪽 0~W×0.45, 오른쪽 W×0.55~W) × (min(restCenter.y − 3r, H×0.15) ~ H), 아니면 rest 주변 2.5r 정사각), orb → `orbCenter`. 한손 종류에서 `leftHanded` 면 anchor 좌우를 바꾸고 x 부호를 뒤집는다(저장은 오른손 기준).
- 기본 배치 → 배치 변환 `static func arrangement(from layout: SpoonLayout, size:safe:k:orbCenter:) -> PadArrangement`: 요소마다 anchor 를 중심 위치로 고른다(x: `< W×0.35` left, `> W×0.65` right, 그 사이 center / y: `< H×0.5` top, 아니면 bottom), `x,y = (center − anchorPoint)/k`, `radius/k`. 편집기 "기본에서 시작"과 "기본 배치로" 가 쓴다. 변환 뒤 다시 `resolve` 하면 원래 위치와 1pt 안에서 같아야 한다(테스트 §8).
- `SpoonLayout` 에 `hasTriggers: Bool`(lt·rt 둘 다 있음), `hasStick: Bool` 계산 프로퍼티 추가. `BowlContainerView` 가 `needsTriggers` 로 스틱 배치로 바꾸는 판단과 `PauseBoard` 의 "움직이는 스틱" 토글 노출은 `kind` 대신 **계산된 레이아웃**으로 한다(사용자가 기본 배치에 LT/RT 를 더했으면 그대로 쓰게).
- `SpoonTouchUIView` 는 레이아웃만 보므로 변경 없음. `PadButton` 에 `name: String`("a","lb",…) 과 `init?(name:)` 추가(배치·스킨 JSON 키용).

## 4. 그리기 (`Spoon/SpoonFace.swift`)

- `SpoonFace` 는 이미 `skin` 을 받는다. 바뀌는 곳:
  - `button(_:)`: `skin.picture(for: slot)` 이 있으면 `Image(uiImage:)` `.resizable(capInsets:resizingMode: .stretch)` 를 `w×h` 로 그리고 눌림은 `pressed` 그림 또는 `press` 색 오버레이(`blendMode(.plusLighter)` 금지 — 그냥 반투명 채움). 없으면 `spoonSurface` 에 `fill`/`buttonColors`/`shape` 반영. 글자는 `skin.glyph(b, layoutLabel: slot.label)` 가 nil 이거나 `picture.showsLabel == false` 면 안 그림. 폰트 디자인은 `skin.font`.
  - `dpad`: 그림이 있으면 `normal` 을 r×2 로, 눌린 방향은 `pressedArm` 을 90° 단위로 돌려 겹침. 없으면 지금 방식 + `dpadFill`.
  - `stick`: `stick.base`/`stick.knob` 그림, 없으면 지금 방식 + `stickFill`.
  - `spoonSurface`: `shape` squircle 은 `RoundedRectangle(cornerRadius: radius×corner×2, style: .continuous)`; `fill` 이 있으면 단색을 먼저 깔고 그 위에 기존 그라데이션. 불투명도 슬라이더는 지금처럼 전부에 곱한다.
- `SnowOrb` 에 `skin` 인자: `orb` 그림이 있으면 그것, 없으면 지금 재질에 스킨 색. `BowlContainerView.menuButton` 과 홈의 쓰임새에 넘긴다(홈은 `.ice` 고정).
- 미리보기 `SpoonPreview` 에 `skin: SpoonSkin`, `arrangement` 반영(`make(prefs:)` 사용). `PadKindThumb`(PauseBoard) 도 스킨 색을 따르면 좋지만 선택.

## 5. 배치 편집기 `SpoonLayoutEditor` (`Spoon/SpoonLayoutEditor.swift`)

**여는 곳** (세 곳 모두 `fullScreenCover`):
- 일시정지 패널 › 조작 › "배치 편집" 버튼 (이 게임에 저장). 게임은 멈춘 채 뒤에 보인다(웹뷰 위에 덮음, `SpoonOverlay` 는 숨김).
- 설정 › 가상 패드 › "배치 편집" (전역). 배경은 홈과 같은 얼음 그라데이션 + 16:9 게임 자리 표시(세로에서는 `topEdge` 로 계산한 위치, 가로는 `landscapeRect`).
- 이 게임 설정 › 가상 패드(게임별 켜져 있을 때) › "배치 편집".

**편집 대상**: 지금 기기 방향 하나. 상단 띠에 "가로 배치 · 기본" 처럼 방향과 종류를 보여 주고, "세로 배치는 기기를 돌려서 편집해요" 안내. 방향이 바뀌면 편집 중인 변경을 그 방향 키에 자동 저장하지 않고 **먼저 저장할지 묻는다**(되돌리기 스택은 방향별).

**시작 상태**: `prefs.layouts[key]` 가 있으면 그것, 없으면 `arrangement(from: 기본)`. 한손+왼손은 거울로 보여 주고 저장 때 되돌린다.

**조작**:
- 끌기: 요소를 잡으면 햅틱, 4pt 격자 스냅, 다른 요소의 중심 x/y 와 6pt 안이면 맞춰 주고 가는 안내선, 화면 가로 가운데도 안내선. 안전 영역 밖으로 못 나감(반지름 포함). 겹침은 허용.
- 탭 → 선택. 아래 도구 막대: 크기 슬라이더(배치 포인트. button 16~44, pill 11~28, dpad 40~90, stick 32~70, orb 고정), "숨기기", stick 이면 "움직이는 스틱" 토글, pill 이면 "넓게"(stretch 1.3 ↔ 2.7).
- "요소 추가": 없는 요소 목록 시트(모든 `PadButton` 중 없는 것, 십자키, 왼/오른 스틱, 일시정지 버튼은 `MenuButtonPlace == .pad` 일 때만). 추가 위치는 그 요소가 보통 있는 쪽 묶음 근처 빈 자리(왼쪽 요소는 bottomLeft 기준, 그 외 bottomRight).
- 되돌리기/다시 실행(메모리 스택, 50단계), "좌우 뒤집기", "기본 배치로"(이 키 삭제, 확인 알림), "저장", "취소"(변경 있으면 확인).
- 컨트롤러 초점 이동은 넣지 않는다(컨트롤러가 붙어 있으면 가상 패드 자체가 숨겨짐). 접근성 라벨은 요소 이름("A 버튼, 오른쪽 아래에서 50, 96")만.
- 편집 중 그리기는 `SpoonFace`(현재 스킨·불투명도 그대로) + 선택 테두리 + 안내선. 터치는 편집기 전용 `UIViewRepresentable`(멀티터치 불필요, `UIPanGestureRecognizer`/탭) 또는 SwiftUI 제스처 — 요소 hit 판정은 `SpoonLayout.button(at:)`·dpad·stick 영역을 재사용.

**저장**: `setPad { $0.layouts[key] = arrangement }`(게임별이면 `DishPrefsStore.update`, 전역이면 `spoon.layouts`). 저장 직후 뒤의 `SpoonOverlay` 가 새 배치로 보여야 한다(`BowlContainerView.padPrefs` 가 store 를 보므로 자동).

**내보내기/가져오기**: 도구 막대 "…" 메뉴에 "배치 내보내기"(현재 스킨 + 이 기기의 모든 키를 `layouts.json` 으로 묶은 `.bingsuskin` 공유 시트). 가져오기는 스킨 가져오기 흐름이 `layouts` 를 들고 오면 "이 스킨이 권하는 배치도 쓸까요? (phone.landscape.simple 외 2개)" 확인 → 전역 `spoon.layouts` 에 키별로 덮어씀.

## 6. 스킨 고르기·디자이너 (`Kitchen/`)

- `SkinPicker`: 가로 스크롤 썸네일 줄(각 썸네일은 그 스킨으로 그린 작은 `SpoonPreview`, 이름, 선택 표시). 들어가는 곳: `PadPrefsControls`(설정·게임별 공용, `prefs.skin` 바인딩), `PauseBoard` 조작 그룹(`PadKind` 줄 아래, `setPad`). 줄 끝 "관리…" → `SkinLibraryView`.
- `SkinLibraryView`(설정 안 푸시 화면): 번들/내 스킨 목록(이름·만든 사람·라이선스), 행 동작: 고르기, 복제해서 고치기(→ 디자이너), 내보내기(공유 시트), 삭제(내 스킨만, 확인). 상단 "파일에서 가져오기"(`GamePicker` 재사용, zip·`com.minwoo.bingsu.skin`), "새로 만들기"(얼음 복제 → 디자이너).
- `SkinDesigner`(색 스킨만): 위에 큰 `SpoonPreview`(현재 종류, 가로) 라이브, 아래 폼: 이름 / 색(ColorPicker: ink, text, fill(끄기 가능), shade, press, dpad, stick) / 슬라이더(fillTop, shadeBottom, rim, lineWidth) / 모양(원·둥근 사각 + corner) / 글자(style 피커, font 피커, 버튼별 덮어쓰기 8자) / 버튼별 색(A·B·X·Y 토글+ColorPicker, "SNES 색으로"·"Xbox 색으로" 프리셋 버튼). 저장 → `SkinShelf.saveUser`(id: 새 스킨이면 `my-<yyyymmdd-hhmmss>`, 복제면 그대로 새 id; 이름 중복 허용). 그림 스킨을 복제하면 PNG 도 함께 복사되고 디자이너는 색 부분만 편집(안내 문구).
- 설정 › 오픈소스 라이선스 화면에 "패드 스킨" 절: 번들 스킨 중 `author` 가 있는 것 나열.

## 7. 가져오기 입구 (`Shaver/`)

- `Delivery`: zip 을 임시 폴더에 푼 뒤 `RecipeDetector.detect` 전에 `skin.json` 이 있으면 `SkinShelf.importZip` 경로로 넘기고 `DeliveryView` 는 결과 화면 "스킨 '레트로 회색'을 넣었어요 — 지금 쓰기 / 나중에"(+ layouts 질문). 게임 가져오기 상태 머신에 `.skinDone(ImportResult)` 추가. 이미 푼 폴더를 다시 풀지 않도록 `importStaged(root:)` 변형도 둔다.
- `project.yml`: `UTExportedTypeDeclarations` 에 `com.minwoo.bingsu.skin`(conforms `public.zip-archive`, 확장자 `bingsuskin`), `CFBundleDocumentTypes` 에 그 타입 추가(Owner). 기존 `onOpenURL` 경로로 들어온다.
- 디버그: `BINGSU_SKIN=<id>` 강제 스킨, `BINGSU_IMPORT` 는 스킨 zip 도 그대로 받는다.

## 8. 번들 스킨 7종 (`Resources/Skins/`)

색만(`skin.json` 하나): `ice`(지금 값 그대로, 기본), `glass`(어두운 유리: fillTop 0.1, shadeBottom 0.55, rim 0.6), `retro-gray`(README 예시 그대로, labels retro), `neon`(buttonColors a·b·x·y `#FF3C28` 네온 빨강, dpad·stick `#0AB9E6` 네온 파랑, fillTop 0.15), `outline`(fillTop 0, shadeBottom 0, rim 0.9, lineWidth 1.5), `contrast`(fill `#000000`, ink·text `#FFD60A`, rim 1.2, lineWidth 2, press `#FFFFFF`, font default).
그림 스킨 `blocks`(납작한 색 블록: `button.round`·`button.pill`(capInsets)·`dpad`+`pressedArm`·`stick.base`·`stick.knob`·`orb`, 각 256px): `tools/skins/make-blocks.py`(Pillow) 로 생성해 커밋. 이 스킨이 그림 경로 전체를 실제로 검증한다. 예시 zip 은 `docs/skins/examples/blocks.bingsuskin` 로도 둔다(같은 스크립트가 만듦).

## 9. 확인 (시뮬레이터 iPhone 17 Pro · iPad Pro 13, 기존 두 대만)

- 호환: 빌드 23 으로 만든 `Prefs/*.json`·UserDefaults 그대로 두고 새 빌드 실행 → 패드가 이전과 같은 자리·얼음 스킨. 새 빌드로 스킨·배치를 저장한 뒤 빌드 23 코드로 디코딩해도(필드 무시) 깨지지 않음.
- 배치 왕복: 5종 × 가로·세로 × phone/pad 에 대해 `arrangement(from:)` → `resolve` 결과가 원래 레이아웃과 요소마다 1pt 안(디버그 자가 테스트 `BINGSU_SELFTEST=1` 에 추가).
- 편집기: A 를 끌어 옮기고 저장 → 게임에서 그 자리에서 터치가 먹음(`BINGSU_KEYDEBUG=1` 로그), 세로로 돌리면 세로 기본 배치 그대로(키 분리), 크기 슬라이더를 바꾸면 사용자 배치도 비례. LT/RT 를 기본 배치에 추가 → 레조넌스가 스틱 배치로 강제 전환되지 않음. 한손+왼손 거울 저장/복원. "기본 배치로" 뒤 키 삭제 확인.
- 스킨: 7종 각각 5종 배치에서 그려짐(스크린샷 7×5 는 과하니 종류별 하나씩 + blocks 전부). 눌림 표시(그림·색 둘 다). 불투명도 슬라이더가 그림 스킨에도 먹음.
- 가져오기 거절 6가지: 10MB 초과 / `skin.json` 없음 / `format: 2` / 번들 id 충돌 / `.js` 포함 / 가짜 PNG(텍스트에 .png) — 각각 문구 확인. 같은 id 재가져오기 → 덮어씀. `layouts.json` 포함 zip → 질문 → 적용. `.bingsuskin` 을 `xcrun simctl openurl` 로 열기.
- 메모리: 포켓로그 + blocks 스킨에서 앱 메모리가 얼음 대비 +5MB 이내(Xcode 메모리 게이지 또는 `[Thermometer]` 로그). 게임 중 패드 누름으로 디코딩 로그가 반복되지 않음.
- 내보내기 zip 을 다시 가져오기 → 같은 모습.

## 10. 이번 빌드에서 하지 않는 것

버튼→키 매핑 편집(`CutlerySet` 편집), 연사·눌러 고정, Delta `.deltaskin` 읽기, 스킨 파일 iCloud 동기화, 편집기 컨트롤러 조작, 편집기 안 "눌러 보기" 시험 모드, 게임별로 다른 스킨 **그림** 업로드 UI(디자이너는 색만; 그림은 zip 로만).

## 11. 끝낼 때

PLAN.md 로드맵 항목(Phase 1 "입력 프로필 편집기, 가상 패드 레이아웃 편집기")을 `[x]` 로 바꾸고 이 문서처럼 요약 한 단락 + 확인 결과를 적는다. `docs/skins/README.md` 와 구현이 달라진 점이 있으면 README 를 고친다(형식 문서가 기준). `THIRD_PARTY_LICENSES.md` 에 새 외부 그림이 있으면 추가(blocks 는 자체 생성이라 없음). 빌드 번호는 부모 세션이 올린다.

## 12. 구현 중 바뀐 것

명세와 다르게 한 것과 그 까닭. 형식에 닿는 것(1·2·4·6)은 `README.md` 에도 반영했다.

1. **한손 가로 키**: 한손은 가로에서 기본 배치로 그려지므로 `PadArrangement.key` 가 `*.landscape.oneHand` 대신 `*.landscape.simple` 을 돌려준다. 가로에서 한손으로 편집하면 기본 배치를 고치는 것과 같다.
2. **`floating` 생략 = 사용자 설정**: 요소의 `floating` 이 없으면 그때의 "움직이는 스틱" 토글을 따른다. `arrangement(from:)` 은 왼쪽 스틱의 `floating` 을 비워 두고(토글을 계속 따르게) 오른쪽 스틱만 `false` 를 적는다.
3. **스틱 영역 계산**: 움직이는 스틱의 터치 영역은 가로 W×0.4 / 세로 W×0.45 폭, 위쪽 끝은 가로 `min(c.y − 3r, H×0.15)`, 세로 `c.y − 2.5r` 이다. 명세대로 세로에서도 `min(…, H×0.15)` 를 쓰면 화면 위쪽 게임 위까지 스틱 영역이 되어 게임 터치를 가로챈다. 고정 스틱은 rest 둘레 반지름 1.5r(정사각 3r) — 기본 배치의 지금 값과 같게 맞춰 빌드 23 과 터치 영역이 같다.
4. **앱에 든 id + `layouts.json`**: 번들 스킨 id 의 zip 은 거절하지만, `layouts.json` 이 들어 있으면 스킨은 넣지 않고 배치만 권한다(`ImportResult.installed == false`). 편집기 "배치 내보내기"가 얼음 같은 번들 스킨을 쓰는 중이면 `id: "ice"` 로 묶이므로, 이렇게 해야 그 파일을 다른 기기에서 받을 수 있다.
5. **`providesTriggers`·`providesStick` 은 두 방향 중 하나라도**: `padPrefs` 는 방향을 모르는 값이라 "지금 방향의 배치"가 아니라 가로·세로 중 하나라도 LT·RT(스틱)가 있으면 참이다. 그래서 세로 기본 배치에만 LT·RT 를 더해도 레조넌스가 스틱 배치로 바뀌지 않는다(가로에서는 그 사용자가 고친 적 없는 가로 기본 배치라 LT·RT 가 없다). 아래 "남은 것" 참고.
6. **Delivery 스킨 분기 위치**: 명세는 zip 을 푼 뒤 `skin.json` 을 찾고 `importStaged(root:)` 로 넘기라 했지만, 풀기 전에 중앙 디렉터리만 보고(`SkinShelf.looksLikeSkin`: 확장자 `.bingsuskin` 이거나 루트·폴더 하나 아래에 `skin.json`, 앞쪽 400개 항목만) 바로 `importZip` 으로 넘긴다. 큰 게임 zip 을 스킨 검사기로 두 번 풀 일이 없고, 스킨 쪽 검사(10MB·40개·확장자·PNG)가 처음부터 그대로 적용된다. 그래서 `importStaged` 는 없다. 상태는 `.skinDone` 외에 `.skinFailed`(제목 "스킨 가져오기", "주소로 다시 받기" 없이 "다른 파일 고르기"만)를 더했다.
7. **가져온 배치를 어디에 쓰나**: 스킨 관리 화면에서 가져오면 그 화면의 패드 설정(설정이면 전역, 이 게임 설정이면 그 게임)에, Delivery(게임 추가·Files "다음으로 열기")로 들어오면 전역에 쓴다.
8. **일시정지 화면 편집기는 `fullScreenCover` 가 아니라 오버레이**: `BowlContainerView`/`BrassBowlContainerView` 의 ZStack 맨 위에 올린다. 시트를 띄우면 뒤의 웹뷰가 가려지거나 화면 회전 때 다시 배치되는데, 오버레이는 멈춘 게임을 그대로 뒤에 둔다. 닫으면 일시정지 화면으로 돌아오고, 컨트롤러 일시정지 메뉴에도 "배치 편집" 항목(`PauseItem.editLayout`)이 있다. 설정·이 게임 설정의 편집기는 명세대로 `fullScreenCover`.
9. **저장하면 닫힌다**: "저장"은 그 키를 저장하고 편집기를 닫는다. 방향을 돌리면 바꾼 것이 있을 때 저장할지 묻는다(명세대로).
10. **한손 왼손 기본 배치**: 왼손일 때 편집기가 시작하는 기본 배치는 오른손 기본 배치의 거울이다. 빌드 23 의 `makeOneHand` 왼손 배치와 L·− 위치가 몇 pt 다르다(사용자 배치를 저장하지 않으면 게임은 예전 왼손 배치 그대로).
11. **좌우 뒤집기와 어깨 버튼**: 거울로 옮기되 LB·RB, LT·RT 는 짝의 거울 자리로 보낸다(L 이 계속 왼쪽). 한손 왼손 저장에 쓰는 `mirrored()` 는 순수 거울 그대로.
12. **"모든 게임에 적용"이 왼손도 옮긴다**: `PadPrefs.setGlobal` 이 종류·크기·불투명도·스킨·배치와 함께 `leftHanded` 도 전역에 쓴다(전에는 빠져 있었다).
13. **`make-blocks.py` 는 Pillow 없이**: 개발 맥에 Pillow 가 없어 표준 라이브러리만(부호 거리 함수로 모양, zlib 으로 PNG) 쓴다. 누구나 추가 설치 없이 다시 만들 수 있다.
14. **스킨 썸네일은 가로 고정**: `SkinPicker` 썸네일·가져오기 카드는 지금 방향과 상관없이 가로 배치로 그린다(좁은 칸에 세로 배치는 너무 작다).
15. **편집기 "게임 화면" 자리**: 세로 자리 계산을 `BowlContainerView.portraitRect` 로 빼서 게임과 편집기가 같이 쓴다. 편집 중 요소를 끌면 게임 자리도 실제처럼 따라 움직인다.
16. **디버그 스위치 더함**: `BINGSU_PRESS=a,up,…`(그 버튼을 눌린 모양으로 고정, 눌림 그림 확인용), `BINGSU_LAYOUT=1`(게임을 열고 3초 뒤 배치 편집기). 자가 테스트(`BINGSU_SELFTEST=1`)에 앱에 든 스킨 7종 읽기와 내보내기→가져오기 왕복을 더했다.
17. **neon**: 명세 값 그대로(버튼 네온 빨강, 십자키·스틱 네온 파랑, `press`·`labels` 없음 → 기본 눌림 색·Xbox 글자).

### 남은 것 (다음에)

- 5번: 트리거가 꼭 필요한 게임에서 한 방향에만 LT·RT 를 더하면 다른 방향은 LT·RT 없는 기본 배치가 된다. 방향별로 판단하려면 `padPrefs` 가 지금 방향을 알아야 한다.
- 레트로 회색은 README 예시 값(`text #3A3835`, A·B `#8C2F5A`)이라 어두운 배경에서 B 글자 대비가 낮다. 형식 예시를 고칠지는 디자인 판단.
- 편집기의 버튼 메뉴(… → 좌우 뒤집기 등)는 시뮬레이터에서 메뉴가 닫힌 뒤에 반영되어, 바로 찍은 화면은 한 박자 늦다(동작은 맞음).

## 13. 확인 결과 (2026-11-01, iPhone 17 Pro · iPad Pro 13 시뮬레이터)

- **호환**: iPad 에 빌드 23 코드(bc3238b)를 깔아 견본 게임(게임별 설정 `standard`·1.1·라벨 켬)과 레조넌스(전역 따름 → 트리거 때문에 스틱 배치)를 찍고, 같은 데이터 위에 새 빌드를 깔아 다시 찍음 → 세로 화면 아래 40%(패드)에서 다른 픽셀 **0**. 가로는 패드 자리 같고 다른 픽셀은 게임 그림 움직임(얼음 쌓이는 장면·START 깜빡임)뿐. `Prefs/*.json` 은 새 빌드가 열어도 바뀌지 않음. 자가 테스트 `compat ok`(빌드 23 JSON → 새 필드 nil·기본 배치 같음, 새 JSON 을 빌드 23 모양으로 읽기, 깨진 layouts/skin 은 그 값만 버림).
- **배치 왕복**: `roundtrip pass=72 fail=0 maxErr=0.087pt`(iPhone·iPad 둘 다).
- **편집기**: (iPhone) A 를 끌어 저장 → 게임을 다시 켜도 그 자리, 그 자리를 누르면 `[Bowl] key KeyZ`(A). (iPad 가로) 같은 확인, 키 `pad.landscape.standard`. 세로에 LT·RT 를 더한 배치를 저장한 뒤 가로로 돌리면 가로 기본 배치 그대로(키 분리). 같은 사용자 배치를 크기 0.8·1.3 으로 그리면 자리·크기가 비례. 설정 › 배치 편집에서 기본 배치에 LT·RT 추가 → 레조넌스가 스틱 배치로 바뀌지 않고 그 배치로 열림. 한손+왼손: 거울로 보여 주고, A 를 옮겨 저장하면 오른손 기준(`bottomRight`, x −60)으로 저장, 게임에서는 다시 거울. 기본 배치로 → 확인 알림 → 그 키가 `layouts` 에서 지워짐(`[Spoon] 배치 지움 phone.portrait.simple`). 좌우 뒤집기(어깨 버튼 제 쪽), 요소 추가(LT·RT), 숨기기·크기 막대 동작.
- **스킨**: 7종 각각 한 종류씩(얼음·기본, 어두운 유리·스틱, 레트로 회색·레트로, 네온·Xbox 전체, 선만·한손, 대비·기본) + blocks 다섯 종류 전부(세로) + blocks 가로(iPad 레조넌스) 그려짐. `BINGSU_PRESS=a,up,lb` 로 눌림: 그림 스킨은 눌린 그림(round-on·pill-on·dpad-up-on 돌려 쓰기), 색 스킨은 `press` 색. 불투명도 25%·90% 가 blocks 에도 먹음.
- **가져오기**: 거절 6가지 문구 — "zip 이 10MB 를 넘어요 · 11.0MB" / "skin.json 이 없어요" / "format 2 은 읽을 수 없어요 (1 만 읽어요)" / "앱에 든 스킨과 이름이 같아요 (ice)" / "스킨 파일이 아닌 것이 들어 있어요: evil.js" / "PNG 가 아니에요: round.png". 같은 id 다시 가져오기 → "새 판으로 바꿨어요"(덮어씀). `layouts.json` 든 zip → "이 스킨이 권하는 배치도 쓸까요? (iPhone 세로 · 기본)" → "스킨과 배치 쓰기" → 전역 `spoon.skin`·`spoon.layouts` 에 들어가고 게임에 그 배치로 보임. `xcrun simctl openurl … .bingsuskin` → `[Delivery] open url received (bingsuskin)` → 같은 화면.
- **메모리**: 포켓로그 + 얼음 53MB, + blocks 52MB(앱 프로세스 `phys_footprint`, 35초 뒤, 두 번씩). 게임 중 패드를 눌러도 `[Skin] … 읽음` 은 처음 한 번뿐.
- **내보내기 → 다시 가져오기**: 자가 테스트 `export ok` — blocks 복제 → 권하는 배치와 함께 내보내기 → 지우기 → 가져오기 → 파일 11개가 바이트까지 같고 배치도 같음(iPhone·iPad). 공유 시트를 거치는 화면 경로는 손으로 확인하지 않음.

# 애플워치를 게임 컨트롤러로 쓰기 — 조사

작성 2026-11-01 · 조사만 했고 코드는 바꾸지 않았다 · 로드맵 자리(2026-11-01 사용자 결정): **편의성 패치 바로 앞 빌드**

표기: **[확인]** 소스·파일을 직접 읽어 확인 · **[문서]** Apple 공식 문서·가이드라인에 적힌 것 · **[보도]** 포럼·블로그·기사 등 2차 출처 · **[추정]** 근거는 있으나 돌려 보지 않음 · **[미확인]** 확인하지 못함.
Apple 문서는 `developer.apple.com/tutorials/data/documentation/<경로>.json` 원문(2026-11-01 기준)을 읽었다. 링크는 맨 아래 "참고 링크"에 번호로 모았다.

---

## 요약 (한 화면)

**판정: 가능하다. 단 "iPhone 전용, 턴제(메뉴·대화·배틀 명령)용 보조 조작기"까지다.** 실시간 조작(빙수 기본 게임의 A 연타, 필드 이동 길게 누르기)은 기대하지 않는다.

부모 세션의 1차 판단을 출처로 확인한 결과:

| 1차 판단 | 결과 | 근거 |
|---|---|---|
| 블루투스 HID 게임패드로 보이게 할 수 없다 | **맞음** | watchOS 는 `CBPeripheralManager` 로 광고 자체를 못 한다 [문서 1]. `GCVirtualController` 는 iOS·iPadOS·Mac Catalyst 전용 [문서 2]. HID 를 흉내 내는 공개 API 없음 |
| 전용 watchOS 앱 + `WatchConnectivity` 만 가능 | **대체로 맞음, 하나 보탬** | `Network.framework`·Bonjour 는 일반 워치 앱에서 막힘(`ENETDOWN`) [문서 3]. 다만 **워치가 BLE 중앙(central)으로 iPhone·iPad 앱이 연 GATT 서비스에 붙는 길**은 공개 API 로 열려 있다 [문서 1, 4] — 실제로 되는지는 [미확인], 2단계 PoC 후보 |
| 지연 0.1~0.5초라 턴제용 | **턴제용은 맞음, 숫자는 낙관적** | Apple 이 지연 수치를 공개한 적 없음. 보고된 값은 왕복 약 0.25초 ~ 편도 0.8초, 나쁘면 수 초 [보도 5, 6, 7]. Apple 엔지니어: "어느 정도 지연은 예상해야 한다", "초당 두어 개"로 제한하거나 답장으로 역압(back pressure)을 걸라 [보도 7]. → **0.2~1초로 잡고 실측** |
| iPad 는 짝지은 iPhone 이 아니라 불가 | **WatchConnectivity 로는 맞음** | `WCSession.isSupported()` 는 워치와 짝지을 수 있는 iPhone 에서만 true, 그 밖의 기기는 false [문서 8]. BLE 길이라면 iPad 도 이론상 가능 [추정] |
| 화면 꺼짐이 UX 걸림돌 | **맞음, 완화책 있음** | 손목을 내리면 앱이 비활성(inactive)이 되고 기본 2분 뒤 백그라운드로 내려가 멈춘다 [문서 9]. Always On(Series 5 이상, SE 제외) 이면 화면이 남고 탭도 먹는다. 사용자가 앱별로 "1시간 뒤 시계로 돌아가기"를 고르면 최대 1시간 [문서 9, 10]. **컨트롤러 용도의 정당한 백그라운드 세션은 없다**(운동 세션 남용은 심사 위험) [문서 11, 12] |

핵심 제약 다섯 가지:
1. **지연과 빈도**: `sendMessage` 는 무선 큐 전송이라 수백 ms 지연, 초당 몇 개 이상 보내면 밀린다 [보도 7]. 누르고 있기·연타는 약하다.
2. **iPhone 만**: iPad 는 WatchConnectivity 가 없다. iPhone 을 거쳐 iPad 로 중계하는 것도 iPhone 빙수가 백그라운드에서 오래 못 살아 비추천 [추정].
3. **워치 앱이 앞에 있어야 한다**: iPhone→워치 메시지는 워치 앱을 깨우지 않는다 [문서 13]. 워치→iPhone 은 iPhone 앱을 백그라운드에서 깨우지만, 빙수는 게임 중이라 어차피 앞에 있다.
4. **진동은 워치 앱이 활성일 때만**: 손목을 내린 비활성 상태에서는 `WKInterfaceDevice.play` 가 아무 일도 안 한다 [문서 14]. 연달아 부르면 100ms 최소 간격.
5. **쓸 수 있는 버튼은 화면·크라운 회전·더블탭뿐**: 크라운 누름·측면 버튼은 시스템 몫 [문서 15]. 울트라 액션 버튼은 운동·다이빙 앱 시작 용도만 [문서 16].

**권장 첫 PoC (반나절)**: watchOS 앱 타깃을 `project.yml` 에 넣고 버튼 4개(A·B·▲·▼)를 `sendMessage` + 답장으로 보내 iPhone 에서 받고, **왕복 시간 200회의 평균·p95** 를 워치 화면에 찍는다. 이 숫자가 다음 단계(SpoonController 연결)를 할지 정한다.

---

## 1. 지금 입력은 어디로 들어가는가 (빙수 코드)

- 모든 입력은 `SpoonController` 의 `press(_:haptic:)`·`release(_:immediate:)`·`setStick(right:vector:)` 로 모인다 [확인, `BingsuApp/Bingsu/Spoon/SpoonController.swift:37,57,47`]. 거기서 게임 종류에 따라 웹뷰의 `__bingsu.pad(mask, …)`(가상 Gamepad) 또는 `__bingsu.key(code, down)`(KeyboardEvent)로, RPG Maker XP 는 `keySink` 로 간다 [확인, 같은 파일 `sync()`·`send(_:down:)`].
- 너무 짧은 누름은 게임이 프레임 단위로 읽다 놓치므로 **뗌을 누른 지 0.09초 뒤로 미룬다** [확인, `SpoonController.swift:159` `minPress`]. 워치에서 누름·뗌이 한꺼번에 몰려 와도 이 장치가 최소 길이를 보장해 준다 → 워치 쪽은 "탭" 하나만 보내도 된다.
- 실제 컨트롤러는 `LongSpoon` 이 `GCController` 값 변화를 받아 **새로 눌린 버튼은 press, 떼진 버튼은 release(immediate)** 로 넣는다 [확인, `Spoon/LongSpoon.swift:70` `apply`]. 일시정지 화면이 열려 있으면 `menuInput` 으로 넘기고, 홈 버튼은 `onHomeButton`, 게임이 화면에 없으면 `enabled = false` [확인, 같은 파일 14·17·19행].
- `LongSpoon` 은 게임 화면이 뜰 때 만들어진다: 웹 게임 `Bowl/BowlContainerView.swift:170`, RPG Maker XP `BrassBowl/BrassBowlContainerView.swift:202` [확인].
- 진동: 게임 요청(`rumble` 메시지)과 효과음 진동표(`sfx` → `RumbleSet.match` → `Rumble.play(pattern)`)가 `Rumble.shared` 로 모인다 [확인, `Bowl/GlassBowl.swift` 의 `rumble`·`sfx` 처리]. 패턴은 `strong`·`weak`(0…1)·`duration`(초)·`repeats`·`gap`·`sharpness` [확인, `Spoon/RumbleSet.swift:9`]. 블루투스 이어폰 보호 중에는 **0.3초 안에 오는 진동을 건너뛴다** [확인, `Spoon/Rumble.swift:51` `btMinGap`].

→ **워치 입력은 `LongSpoon` 과 똑같은 모양의 새 입력원 하나로 붙이면 된다.** 게임·엔진 쪽은 손댈 것이 없다. 이름 제안(PLAN 7.1 규칙): 코드 `TeaSpoon`(손목 위 작은 숟가락), 화면 문구는 평범하게 "애플워치".

---

## 2. 통신 경로

### 2.1 WatchConnectivity 네 가지 방식

| 방식 | 언제 도착 | 상대가 꺼져 있으면 | 빙수 용도 |
|---|---|---|---|
| `sendMessage` / `sendMessageData` | "가능한 한 빨리", 보낸 순서대로 직렬 전달, 높은 우선순위로 바로 전송 [문서 13, 17] | 오류 핸들러 호출 (`isReachable` 이 true 여야 함) | **버튼 입력**, iPhone→워치 진동 신호 |
| `transferUserInfo` | 백그라운드 큐, 앱이 멈춰도 계속 전송, 도착 보장 [문서 18] | 나중에 전달 | 안 씀 (시뮬레이터 미지원 [문서 18]) |
| `updateApplicationContext` | "기회가 될 때", 상대가 깨어날 때 준비돼 있게. **이전 값을 덮어씀** [문서 19] | 나중에 마지막 값만 | **상태 표시**(게임 이름·온도·연결 상태) |
| `transferFile` | 백그라운드, 크기에 비례 | 나중에 전달 | 안 씀 |

**도달성(`isReachable`) 조건** [문서 20]:
- 워치 쪽에서 true: iPhone 이 범위 안 **그리고** 워치 앱이 전면에서 실행 중이거나, 높은 우선순위 백그라운드(운동 세션, 컴플리케이션 초기 타임라인 로딩) 중.
- iPhone 쪽에서 true: 짝지은 활성 워치가 범위 안, 워치 앱이 실행 중이고 워치 쪽 `isReachable` 이 true.
- **워치 → iPhone `sendMessage` 는 iPhone 앱을 백그라운드에서 깨워 도달 가능하게 만든다. iPhone → 워치는 워치 앱을 깨우지 않는다** [문서 13].
- 손목을 내린 **비활성(inactive, Always On 으로 화면만 남은)** 상태에서 `isReachable` 이 유지되는지는 문서에 없다 → [미확인], PoC 에서 잰다.

**iPhone 앱이 꼭 구현할 것** [문서 21]: 워치 여러 대 지원을 위해 `session(_:activationDidCompleteWith:error:)`·`sessionDidBecomeInactive`·`sessionDidDeactivate` 를 구현하고, 비활성화되면 `activate()` 를 다시 부른다. 구현하지 않으면 워치를 바꿀 때 세션이 꺼지고 **앱이 백그라운드로 가면 시스템이 앱을 종료**한다. 받은 메시지는 백그라운드 스레드의 델리게이트로 직렬 전달 → `@MainActor` 로 넘겨 `SpoonController` 를 부른다.

### 2.2 지연과 메시지 수 한계

Apple 은 지연·빈도 수치를 공개하지 않았다 [문서 13, 21 — 수치 없음]. 문서에는 "백그라운드 전송은 즉시가 아니며 전력 때문에 조금 늦출 수 있다", "바뀐 것만 보내라"는 말뿐이다 [문서 21].

보고된 값 (모두 오래된 OS, 참고만):

| 출처 | 조건 | 값 |
|---|---|---|
| Apple 포럼 9368 (2015, watchOS 2 베타) [보도 7] | 크라운 값을 10~20ms 간격으로 31개 `sendMessageData` | iPhone 도착이 **메시지당 약 200ms 간격, 31개에 4.4초**, 중복·순서 뒤바뀜. Apple 엔지니어 답: 순서 문제는 버그, 지연은 어느 정도 예상해야 하며 **"초당 두어 개"로 줄이거나 답장으로 역압을 걸라** |
| Apple 포럼 29184 (2015, watchOS 2.1, iPhone 5s) [보도 5] | 워치 버튼 → iPhone 소리, 녹음으로 측정 | **편도 약 0.8초**. 답글: 왕복 약 1초 |
| Apple 포럼 20311 (2015-09, watchOS 2.0 무렵) [보도 6] | 1.5초마다 하트비트 왕복 | **왕복 평균 약 0.25초** ("조금 높지만 받아들일 만"), 가끔 전달 실패 |
| Apple 포럼 47765 [보도 22] | 가속도 XYZ 연속 전송 | 1~5초 밀림 |
| Apple 포럼 692393 [보도 23] | 일반 경험담 | "대체로 1~3초" (답장 포함) |
| 블로그 몇 곳 | 출처 없음 | 10~200ms — **근거가 없어 쓰지 않는다** |

정리:
- 최근 기기(블루투스 LE 5.x, watchOS 26)에서 얼마나 좋아졌는지는 **[미확인]**. 공개된 최신 실측을 찾지 못했다.
- 메시지 수 한계: 공식 수치 없음 [미확인]. 실용 기준은 Apple 엔지니어의 "초당 두어 개" + **답장이 오기 전 다음 메시지를 쌓지 않기**(역압) [보도 7]. 빙수의 블루투스 보호 간격 0.3초와도 맞는다.
- 메시지에 **일련번호**를 넣어 중복·순서 뒤바뀜을 받는 쪽에서 버린다 [보도 7 의 버그 보고 대비].

### 2.3 블루투스 HID 게임패드처럼 보이기 — 불가

- 블루투스 HID 장치가 되려면 워치가 주변기기(peripheral)로 광고해야 하는데, **watchOS 에서는 `CBPeripheralManager` 로 서비스를 광고할 수 없다** [문서 1].
- 블루투스 클래식 HID 를 여는 API 도 watchOS 에 없다 [미확인 — 없다는 것을 직접 적은 문서는 못 찾았고, Core Bluetooth 외 블루투스 API 가 watchOS 에 없다는 것으로 판단].
- `GameController` 의 가상 컨트롤러(`GCVirtualController`)는 iOS·iPadOS·Mac Catalyst 전용이고, 그것도 자기 앱 안 화면 패드일 뿐 다른 기기에 HID 로 보이지 않는다 [문서 2].
- 그래서 Delta·Provenance 같은 에뮬레이터도 iOS 가 아는 컨트롤러(MFi·Xbox·PS·키보드)만 지원하고 워치는 지원하지 않는다 [보도 24].

### 2.4 그 밖의 경로

| 경로 | 워치에서 | 판정 |
|---|---|---|
| `Network.framework`·`NWConnection`·Bonjour(`NWBrowser`)·소켓 | 일반 앱은 막힘: `NWConnection` 이 `waiting(ENETDOWN)` 에 머묾. 예외는 오디오 스트리밍 중, CallKit 통화 중, **tvOS 와의 DeviceDiscoveryUI 연결**뿐. BSD 소켓은 어떤 경우에도 안 됨. 시뮬레이터는 항상 허용하니 실기기로 시험 [문서 3] | **불가** (같은 Wi-Fi 의 iPad 직접 연결 안 됨) |
| `URLSession` HTTP(S) | "고수준 네트워크"라 모든 앱에 허용 [문서 3] | iPad 가 로컬 HTTP 서버를 연다면 이론상 닿을 수 있으나, 워치의 요청이 iPhone 을 거쳐 나가는지·사설 IP 에 닿는지·요청마다 지연이 얼마인지 [미확인]. 버튼마다 HTTP 요청은 지연·전력 모두 나쁨 [추정] → 비추천 |
| DeviceDiscoveryUI | 워치는 "광고(Advertises)"만, 찾기(Browses)는 tvOS 만 [문서 25]. 프레임워크 자체도 iOS·iPadOS 26·tvOS 용, watchOS 목록 없음. Wi-Fi Aware 는 iOS·iPadOS 26 전용 [문서 26] | **워치 ↔ iPad 불가** (워치 ↔ Apple TV 만) |
| **Core Bluetooth (워치=중앙, iPhone·iPad=주변기기)** | watchOS 는 중앙(central) 역할 가능 [문서 4]. iPhone·iPad 앱은 `CBPeripheralManager` 로 GATT 서비스를 광고할 수 있고, 앱이 앞에 있는 동안 서비스가 살아 있다 [문서 1]. 워치는 **앱이 전면이거나 백그라운드 세션 중에만** 연결, 새 기기 찾기는 전면에서만 [문서 4]. 앱당 동시 연결 2개 [보도 27, Apple 엔지니어 답] | **가능성 있음 [추정]**: 워치 → "쓰기(응답 없음)"로 버튼 비트를 보내면 BLE 연결 간격(워치 최소 30ms 라는 보도 [보도 28, 표 원문 미확인]) 수준 지연을 기대. **iPad 도 같은 방식으로 된다.** 단 실제로 워치 앱이 iOS 앱의 GATT 서비스에 붙는 사례·심사 사례는 못 찾음 [미확인]. 양쪽에 블루투스 권한 문구(`NSBluetoothAlwaysUsageDescription`) 필요 |

BLE 길의 주의점: 빙수는 이미 **블루투스 컨트롤러 진동과 이어폰 오디오가 폰의 블루투스 무선을 나눠 쓰며 지직거린 일**이 있다 [확인, `Spoon/Rumble.swift` `btSafeKey` 주석]. 워치 BLE 연결을 하나 더 얹으면 같은 문제가 커질 수 있다 [추정]. WatchConnectivity 도 블루투스/Wi-Fi 를 쓰므로 정도 차이일 뿐 같은 위험이 있다 [추정].

---

## 3. 입력 수단

| 수단 | 서드파티 앱에 열림? | 세부 | 출처 |
|---|---|---|---|
| 화면 탭 | 열림 | SwiftUI 버튼. 누름·뗌을 따로 받으려면 `DragGesture(minimumDistance: 0)` 의 시작·끝 [추정, 표준 SwiftUI 기법]. **멀티터치는 기대하지 않는다** (두 버튼 동시 누름) [미확인] | — |
| 스와이프 | 열림, 단 화면 가장자리 스와이프는 시스템 몫(뒤로 가기 등)과 겹치지 않게 | HIG: 시스템 UI 를 여는 제스처(watchOS 가장자리 스와이프)와 충돌하지 말 것 | [문서 29] |
| 디지털 크라운 회전 | 열림 | `digitalCrownRotation(_:from:through:by:sensitivity:isContinuous:isHapticFeedbackEnabled:)` (watchOS 6+), 이벤트형 `DigitalCrownEvent` (watchOS 9+). 대부분 기종이 **선형 햅틱 디텐트**(일정 거리마다 톡)를 기본 제공, 끌 수 있음. 회전하려면 뷰가 `focusable` 이어야 함 | [문서 15, 30, 31] |
| 크라운 누름 | **닫힘** | "watchOS 가 홈 화면 등 시스템 기능에 예약해 두어 앱은 크라운 누름에 반응하지 않는다" | [문서 15] |
| 측면 버튼 | **닫힘** | 공개 API 없음 (독·제어 센터·전원) [미확인 — 명시 문서는 못 찾음, API 목록에 없음] | — |
| 울트라 액션 버튼 | **사실상 닫힘** | 설정 › 액션 버튼에 등록할 수 있는 것은 운동(`StartWorkoutIntent`)·다이빙(`StartDiveIntent`) 앱과 단축어 실행뿐. 앱 안에서 누름을 받는 API 아님 | [문서 16] |
| 더블탭 (엄지·검지 두 번) | 열림, **watchOS 11+** | `.handGestureShortcut(.primaryAction)` 로 화면의 버튼 하나를 주 동작으로. 장면당 하나, 버튼이 화면에 보여야 함, 스크롤·목록이 있으면 그쪽이 우선. 문서상 지원 기종 **Series 9·Ultra 2** (그 뒤 기종 Series 10·11·Ultra 3·SE 3 지원 여부는 [미확인]) | [문서 32, 33, 29] |
| 손목 모션 | 열림 | `CMMotionManager` 최대 100Hz. `CMBatchedSensorManager`(watchOS 10+)는 가속도 800Hz·기기 모션 200Hz 지만 **HealthKit 운동 기록 중**용, Series 8·Ultra 이상 | [보도 34, 문서 35] |

### 3.1 빙수 버튼 매핑 제안

빙수가 노리는 장면은 **메뉴·대화·배틀 명령 고르기**(포켓몬 팬게임의 대부분)다. 필요한 버튼은 ▲▼◀▶·A·B·메뉴(≡)·보기(⧉) 정도.

| 워치 입력 | 빙수 버튼 | 이유 |
|---|---|---|
| 크라운 회전 한 칸(디텐트) | ▲ / ▼ 한 번 탭 | 메뉴 커서 이동에 딱 맞고, 디텐트 톡이 "한 칸 움직였다"는 되먹임이 된다. 빨리 돌려도 **답장 기반 역압으로 쌓지 않고 "남은 칸 수"를 합쳐 보낸다** |
| 화면 오른쪽 큰 버튼 | A | 가장 많이 누르는 버튼 |
| 더블탭 (지원 기종) | A (`primaryAction`) | 한 손으로 누를 수 있음. 장면에 스크롤을 두지 않아야 A 로 간다 |
| 화면 오른쪽 아래 작은 버튼 | B | |
| 화면 왼쪽 작은 십자 | ◀ ▶ (▲▼ 도 같이) | 크라운이 없는 방향 보완. 워치 화면(41~49mm)에 네 방향+A·B 를 다 두면 손가락보다 작아짐 → **좌우만 크게, 상하는 크라운**이 현실적 [추정] |
| 위쪽 띠 두 버튼 | 메뉴 ≡ · 보기 ⧉ | 자주 안 누름 |
| 길게 누르기(아무 데나) | 빙수 일시정지 화면 열기 (`onHomeButton` 과 같은 길) | 컨트롤러 홈 버튼과 같은 역할 |
| 손목 모션 | **쓰지 않음** (PoC 범위 밖) | 정밀도·오작동(손목을 내리는 동작 자체가 화면을 끔)·전력. 나중에 "흔들어 B" 정도 실험 |

대안 배치 "터치판": 화면 전체를 트랙패드처럼 — 스와이프 방향 = 십자키 한 번, 탭 = A, 길게 = B. 버튼이 작아지는 문제가 없지만 가장자리 스와이프 충돌·오인식 위험 [추정]. PoC 는 버튼판으로 하고, 터치판은 사용자 평을 본 뒤.

**누르고 있기**: 필드 이동처럼 방향을 길게 누르는 입력은 지연 흔들림 때문에 끊기거나 "안 떼짐"이 날 수 있다. 대응 (설계안):
- 워치는 누름을 보내고, 누르고 있는 동안 0.4초마다 "아직 누름" 하트비트, 떼면 뗌.
- iPhone 은 하트비트가 1초 넘게 안 오면 스스로 `release` (끊김 보호), 연결이 끊기면 `releaseAll()` (`SpoonController.swift:108`).
- 그래도 이동은 품질이 떨어진다는 전제로, 화면 문구에 "메뉴·배틀용"이라고 정직하게 쓴다.

---

## 4. 화면 유지

| 항목 | 내용 | 출처 |
|---|---|---|
| 손목을 내리면 | 앱이 **비활성(inactive)** 으로 바뀌고, "전면 앱"으로 기본 **2분** 남았다가 백그라운드로 내려가 멈춘다. 크라운을 누르거나 손바닥으로 덮으면 바로 백그라운드 | [문서 9] |
| Always On | watchOS 8 부터 전면 앱의 화면을 손목을 내려도 어둡게 계속 보여 줌(갱신 빈도는 낮음). **화면의 버튼은 계속 눌리며, 누르면 그 동작을 실행하고 앱이 다시 활성으로 돌아온다.** Series 4 이하·SE 는 Always On 없음(SE 2세대도 미지원), 저전력 모드에서도 꺼짐. 사용자가 앱별로 끌 수 있음 | [문서 9, 10] |
| 전면 유지 시간 | 설정 › 일반 › 시계로 돌아가기: 항상 / 2분 뒤 / **1시간 뒤**, 앱별 사용자 지정 가능. watchOS 8+ 에서 **최대 1시간** | [문서 9, 10] |
| 앱이 늘릴 수 있는 것 | `isFrontmostTimeoutExtended = true` → 2분을 **8분**으로 (사용자 설정이 더 길면 그쪽). "계속할 것 같은 활동을 할 때만 켜라" | [문서 36] |
| 탭으로 깨울 때 화면 켜짐 | 설정 › 화면 및 밝기 › 깨우기 지속 시간 › **70초 동안 깨우기** (탭으로 깨운 경우만, 손목 들기는 해당 없음) | [문서 10, 보도 37] |
| `WKExtendedRuntimeSession` | 허용 용도는 **셀프 케어(전면, 10분)·마음챙김(전면, 1시간)·물리 치료(백그라운드, 1시간)·스마트 알람(예약, 30분)** 넷뿐. 앱당 한 종류. "기능이 아니라 앱의 의도된 용도로 고르라" | [문서 11] |
| 운동 세션(`HKWorkoutSession`) | 화면·실행·햅틱이 유지되지만, 심사 지침 2.5.1 "HealthKit 은 건강·피트니스 용도로 쓰고 건강 앱과 연동", 2.5.4 "백그라운드 서비스는 의도된 용도로만" | [문서 12] |

판단:
- **게임 컨트롤러는 확장 실행 세션 네 용도 어디에도 들지 않는다.** 마음챙김으로 1시간을 버는 것, 운동 세션으로 화면을 붙잡는 것은 **2.5.1·2.5.4 위반으로 거절될 위험이 크다** [문서 11, 12 — 거절 실사례는 못 찾음, 판단은 추정]. 공개 저장소·TestFlight 외부 심사를 받는 빙수에는 맞지 않는다.
- **정당한 방법**: ① Always On 기본 켬(설정 불필요) → 손목을 내려도 버튼이 보이고 눌린다 ② 게임 중에만 `isFrontmostTimeoutExtended = true`(8분) ③ 워치 앱 첫 화면에 "더 오래 켜 두려면: 설정 › 일반 › 시계로 돌아가기 › 빙수 › 1시간 뒤" 안내 ④ 손목 내림(`isLuminanceReduced`·`scenePhase == .inactive`)이면 화면을 어둡게 단순화.
- 비활성 상태에서 탭했을 때 **메시지가 바로 나가는지, 첫 탭이 활성 전환에 먹히는지**는 [미확인] — PoC 측정 항목.

---

## 5. 되먹임

### 5.1 진동 (`WKInterfaceDevice.current().play(_:)`)

- 종류는 고정 목록뿐 [문서 38]: `notification`·`directionUp`·`directionDown`·`success`·`failure`·`retry`·`start`·`stop`·`click`·`navigationGenericManeuver`·`navigationLeftTurn`·`navigationRightTurn`·(수중 깊이 2종). 세기·길이를 고를 수 없다.
- **앱이 비활성·백그라운드면 아무 효과 없음**(운동 세션 예외). 엔진이 울리는 중에 또 부르면 멈추고 **100ms 최소 지연** 뒤 새로 울림. 자주 쓰면 전력 소모 [문서 14].
- 워치에 CoreHaptics(`CHHapticEngine`)로 패턴을 짜는 길은 watchOS 문서에서 확인하지 못함 [미확인].

빙수 진동표 → 워치 햅틱으로 줄이기 (설계안):
- iPhone 의 `Rumble.play(pattern)` 이 울릴 때 **같은 시점에 한 바이트 등급만** 워치로 보낸다(`sendMessage`, 답장 없음). 패턴 전체를 보내지 않는다.
- 등급: `base = max(strong, weak*0.6)` (이미 `Rumble.play` 가 쓰는 식, [확인, `Rumble.swift` `play(_ p:)`])
  - `base ≥ 0.7` 또는 `duration ≥ 0.4` → `.failure` (가장 묵직하게 느껴지는 편 [추정]) — 피격 강·기절
  - `0.35 ≤ base < 0.7` → `.click` 두 번 대신 `.directionDown` [추정] — 일반 피격
  - `base < 0.35` → `.click` — 가벼운 효과
  - 레벨업·잡기 성공처럼 표에 "좋은 일"을 표시할 수 있게 되면 `.success` (진동표 형식에 필드를 더하는 일이라 나중)
  - `repeats > 1`(볼 흔들림)은 **한 번만** — 워치는 100ms 간격 제약에 메시지 지연까지 더해 박자가 안 맞는다
- 빈도 제한: **0.3초 안에 다시 오면 버린다**(`btMinGap` 과 같은 값). 워치 앱이 비활성이면 iPhone 이 아예 보내지 않는다(도달 불가 → 오류 비용만).
- 기본값: 워치 진동 **끔**, 설정에서 켬 [추정 — 지연 때문에 효과음과 박자가 어긋나 거슬릴 수 있음]. 버튼을 누른 손맛은 워치 자체 `.click` 을 바로(메시지 없이) 울리는 편이 낫다.

### 5.2 워치 화면에 보여 줄 수 있는 것

`updateApplicationContext`(마지막 값만 유지)로 iPhone 이 보내는 작은 사전 하나:
- 연결 상태: 워치 쪽 `isReachable` + iPhone 이 보낸 "게임 중 / 게임 목록 / 일시정지" 상태
- 현재 게임 이름 (`Dish` 의 표시 이름. 사용자가 넣은 게임 이름일 뿐 식별자가 아니어서 8.2 진단 규칙과 충돌 없음 [추정])
- 성능 상태 4단계(원활·양호·뜨거움·위험, PLAN 7.2 색) — `Thermometer` 값에서 이름만
- 컨트롤러 연결 여부 (실제 컨트롤러가 붙으면 워치는 "컨트롤러가 연결돼 있어요" 안내만 하고 입력은 그대로 받을지 결정 필요)
- 게임 화면 내용: 웹뷰 스냅샷을 작은 그림으로 보내는 것은 기술적으로 가능하지만(`transferFile`/`sendMessageData`) 지연·전력·용량 때문에 **범위 밖**으로 둔다 [추정].

---

## 6. 프로젝트·배포

### 6.1 xcodegen 설정 (예시, 아직 넣지 않음)

XcodeGen 2.46.0(설치된 버전) 은 **iOS 앱의 의존성 중 `platform: watchOS` 인 `application` 타깃을 자동으로 "Embed Watch Content"(`$(CONTENTS_FOLDER_PATH)/Watch`) 단계에 넣는다** [확인, XcodeGen `Sources/XcodeGenKit/PBXProjGenerator.swift` 787행·1303행, `xcodegen --version` 2.46.0]. 단일 타깃 워치 앱(Xcode 14+ 형식, 확장 타깃 없음)으로 간다. `supportedDestinations` 로 한 타깃에 워치를 섞으면 Embed 단계가 안 생기는 문제가 보고됨 → 독립 타깃으로 [보도 39].

```yaml
options:
  deploymentTarget:
    iOS: "26.0"
    watchOS: "26.0"          # 6.3 참고

targets:
  Bingsu:
    # … 지금 그대로 …
    dependencies:
      - package: ZIPFoundation
      - package: SwiftGlass
      - target: BingsuWatch    # → Bingsu.app/Watch/BingsuWatch.app 로 들어감

  BingsuWatch:
    type: application
    platform: watchOS
    sources:
      - path: BingsuWatch
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.minwoo.bingsu.watchkitapp
        PRODUCT_NAME: BingsuWatch          # 번들 이름 영문 (8.2b 서명 봉인 교훈)
        TARGETED_DEVICE_FAMILY: "4"        # 전역 "1,2" 를 덮어씀
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: 빙수
        INFOPLIST_KEY_WKCompanionAppBundleIdentifier: com.minwoo.bingsu
        INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp: NO
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
    info:
      path: BingsuWatch/Info.plist
      properties:
        WKApplication: true                 # info: 블록을 쓰면 이 키가 빠져 설치가 거부된 사례 → 직접 적음
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
```

- `WKApplication` 이 빠지면 installd 가 워치 번들을 거부한 사례, `WKCompanionAppBundleIdentifier` 로 iOS 앱과 짝짓기 [보도 40]. 커스텀 Info.plist 를 쓰면 `INFOPLIST_KEY_*` 가 반영되지 않는 문제는 iOS 쪽에서 이미 겪음(8.2b, 90474) → 워치도 **`info.properties` 에 직접 적는 쪽으로 통일**하는 게 안전 [추정].
- 번들 ID 는 iOS 앱 ID 로 시작해야 한다(`com.minwoo.bingsu.watchkitapp`) [추정 — Xcode 템플릿 규칙, 문서 원문 미확인].
- `postBuildScripts`(BrassBowl 넣기)는 iOS 타깃에만 있으니 워치에 영향 없음 [확인, `project.yml`].
- 버전 두 값은 전역 `MARKETING_VERSION`·`CURRENT_PROJECT_VERSION` 을 같이 쓴다 → **iOS 와 워치 빌드 번호가 늘 같아야** App Store Connect 가 받는다 [추정].

### 6.2 서명·TestFlight·심사에 더해지는 것

- **App ID 하나 더**: `com.minwoo.bingsu.watchkitapp`. 자동 서명이면 Xcode 계정이 만들지만, 클라우드 서명·`destination: upload` 경로(8.2b)에서 새 ID 가 자동 등록되는지는 [미확인] → 첫 업로드 전 developer 포털 Identifiers 에 미리 등록. 워치는 iCloud 권한이 필요 없다(저장 데이터를 안 다룸). 팀 ID 는 지금처럼 명령줄로만.
- **스크린샷**: 워치 앱이 있으면 **Apple Watch 스크린샷 필수**, 한 가지 크기를 모든 언어에 같게. 예: 416×496(Series 10·11·12), 422×514(Ultra 3·4), 368×448(Series 4~6·SE) [문서 41].
- **아이콘**: 워치 앱 아이콘(1024 단일)과, 메타데이터 아이콘이 iOS 와 비슷해야 함(2.3.8) [문서 12].
- **독립 실행**: `WKRunsIndependentlyOfCompanionApp = NO` (iPhone 빙수 없이는 쓸모없음). 워치 App Store 단독 판매 안 함.
- **TestFlight**: 같은 업로드에 워치 앱이 들어가고, 테스터는 iPhone 의 Watch 앱(또는 자동 설치)으로 깐다 [추정 — 문서 원문 미확인].
- **심사**: 워치 앱만을 위한 별도 조항은 찾지 못함. 걸릴 수 있는 것은 4.2(최소 기능) — "버튼 몇 개 리모컨"이 너무 빈약해 보이지 않게 연결 상태·게임 이름·안내를 넣는다 [추정]. 운동·확장 세션을 쓰지 않으면 2.5.1·2.5.4 위험 없음.

### 6.3 최소 watchOS

- 빙수 iOS 최소가 26.0 [확인, `project.yml`]. watchOS 26 은 Series 6 이상·SE 2·모든 Ultra 지원 [보도 42].
- **watchOS 27 은 Series 6·7·8·SE 2·Ultra 1 을 빼고 Series 9 이상·SE 3·Ultra 2 이상만** 지원하며 iPhone 은 iOS 27 이 필요 [보도 42, 43]. → 워치 최소는 **26.0** 이 맞다 (더블탭 커스텀 `primaryAction` 은 watchOS 11+ 라 26 이면 충분 [문서 32]).

### 6.4 GPLv3 고지

- 워치 코드는 같은 저장소·같은 저작자의 GPLv3 코드로 들어가므로 **라이선스 자체는 바뀌지 않는다** [추정].
- 워치 앱에 서드파티 라이브러리를 넣지 않으면 `THIRD_PARTY_LICENSES.md` 도 그대로. 넣으면 iOS 와 같은 방식으로 추가.
- 워치 화면에 라이선스 화면을 따로 두는 의무: GPLv3 5(d) 의 "적절한 법적 고지"는 대화형 인터페이스에 해당하지만, 하나의 App Store 제품으로 묶여 iOS 앱의 설정 › 오픈소스 라이선스에서 보이면 충분하다고 본다 [추정 — 법률 판단 아님]. 원하면 워치 앱 "정보" 줄에 "GPLv3 · iPhone 의 빙수 설정에서 전문 보기" 한 줄.
- App Store 배포와 GPL 의 긴장(mkxp-z 등 서드파티 GPL 코드)은 이미 iOS 앱에 있는 문제이고 워치 타깃이 더하는 것은 없다 [추정].

### 6.5 선례

| 선례 | 방식 | 평 |
|---|---|---|
| WappyBird (GitHub NilStack, MIT) | 플래피 버드 클론을 워치로 조작, `sendMessage` 사용 예시가 목적. "아주 단순한" 시도라고 스스로 적음 | 지연 언급 없음, 사용자 평 [미확인] [보도 44] |
| Bowling Central (2015, Apple TV 게임) | 워치 모션 센서로 볼링 공 던지기 — watchOS 2 에서 센서가 열리며 발표 | 출시 후 평 [미확인] [보도 45] |
| Giovanni (오픈소스 워치용 게임보이 에뮬레이터 시제품, 2017) | 워치 안에서 게임을 돌리고 크라운 = 위·아래, 스와이프·탭 = 나머지 | 크라운을 방향키로 쓴 선례 [보도 46] |
| A Tiny Game of Pong (워치 게임) | 개발자 말: "watchOS 가 서드파티 앱을 조절(throttle)하는 것 같아 가끔 랙이 있다" | [보도 47] |
| VirtualGameController (robreuss) | iOS·tvOS·macOS·watchOS 용 소프트웨어 컨트롤러 라이브러리, 약 7년 전 마지막 갱신 | 지금 watchOS 네트워크 제약(문서 3)에서 동작할지 [미확인] [보도 48] |
| Apple 리모컨 앱(Apple TV), 카메라 리모트, Keynote 리모컨 | 워치를 리모컨으로 — Apple 1차 앱이라 같은 API 를 쓰는지 [미확인] | — |

**워치를 iPhone 게임의 게임패드로 쓰는, 지금 유지되는 공개 앱은 찾지 못했다** [미확인]. 시장에 없는 이유 자체가 지연·화면 꺼짐 제약이라고 본다 [추정].

---

## 7. 권장 설계

**iPhone 전용 턴제 보조 조작기 (WatchConnectivity)** 로 간다. iPad 중계는 하지 않는다.

- iPad 중계(워치 → iPhone → iPad)는 ① iPhone 빙수가 앞에 없으면 WC 로 깨워도 잠깐만 살고 ② iPhone → iPad 로컬 네트워크 연결이 백그라운드에서 유지되지 않으며 ③ 무선 홉이 하나 늘어 지연이 더 커진다 [추정]. 들이는 품에 비해 얻는 것이 없다.
- iPad 가 꼭 필요해지면 **BLE(워치 central → iPad peripheral)** 를 별도 PoC 로 본다(2.4). 이 길이 되면 iPhone 도 같은 길로 바꿀 수 있고 지연도 더 낮을 수 있다 [추정].

구조 (설계안, 코드 이름은 7.1 표에 넣을 후보):

```
[워치 BingsuWatch]
  버튼판 화면 ─ 크라운(▲▼) · A · B · ◀▶ · ≡ · ⧉ · 길게=일시정지
     │ sendMessage {s: 일련번호, b: PadButton.rawValue, e: 0 탭/1 누름/2 뗌/3 하트비트}  (답장으로 역압)
     ▼
[iPhone 빙수]
  TeaSpoonLink (앱 시작 때 WCSession 활성화, 델리게이트 3종 구현, 하나뿐)
     │ @MainActor 로 넘김 · 일련번호로 중복·역순 버림 · 하트비트 1초 끊기면 release
     ▼
  TeaSpoon (게임 화면마다, LongSpoon 과 같은 모양: enabled · menuInput · onHomeButton)
     ▼
  SpoonController.press / release   ← 게임 쪽 변경 없음
     
  역방향: Rumble.play(pattern) → 등급 1바이트 → 워치 .click/.directionDown/.failure (0.3초 제한, 기본 끔)
          게임 이름·상태·온도 → updateApplicationContext
```

- 탭은 "탭" 하나로 보내고 iPhone 에서 `press` 직후 `release` — `minPress` 0.09초가 게임이 놓치지 않게 해 준다 [확인, `SpoonController.swift:159`].
- 일시정지 화면이 열려 있으면 `LongSpoon.menuInput` 처럼 워치 입력도 일시정지 화면 조작으로 [확인, `BowlContainerView.swift:286` 의 `pauseInput`].
- 설정 문구(7장 규칙): 설정 › 컨트롤러 › "애플워치" — "메뉴·배틀 같은 턴제 조작에 알맞아요. 필드 이동은 조금 늦을 수 있어요."

---

## 8. PoC 순서 (반나절 단위)

| 단계 | 할 일 | 끝 기준 |
|---|---|---|
| **P1** 타깃 | `project.yml` 에 `BingsuWatch` 추가(6.1), 빈 SwiftUI 화면, 양쪽 `WCSession` 활성화, 워치 화면에 `activationState`·`isReachable` 표시. 시뮬레이터 짝(iPhone 17 + Watch)에서 빌드·설치 | iOS 빌드 안에 `Watch/BingsuWatch.app` 이 들어가고, 시뮬레이터 워치에 "연결됨" |
| **P2** 버튼 4개 + 지연 측정 | A·B·▲·▼ 를 `sendMessage` + 답장(iPhone 이 받자마자 빈 답장). 워치에서 보낸 시각~답장 시각(왕복)을 같은 시계로 재서 200회 평균·p50·p95·최대·오류 수를 화면에 | 숫자가 나온다 (시뮬레이터 값은 참고만 — 문서 3·18 처럼 시뮬레이터는 실기기와 다르게 동작) |
| **P3** 실기기 지연 | 실기기(iPhone + 사용자 워치)에서 P2 를 조건별로: ① 손목 듦 ② 손목 내림(Always On) 뒤 탭 ③ IINE 컨트롤러·블루투스 이어폰 연결 중 ④ iPhone Wi-Fi 끔(블루투스만) ⑤ 연타(초당 5회) | 조건별 표. **판단선: 손목 듦 p95 왕복 ≤ 300ms 면 진행, 600ms 넘으면 WC 중단하고 BLE PoC 검토** [추정 기준] |
| **P4** SpoonController 연결 | `TeaSpoon` 을 `LongSpoon` 옆에 붙여 실제 게임(턴제 웹 게임 메뉴·배틀, RPG Maker XP 메뉴)에서 조작. 일시정지 화면 조작·길게 눌러 일시정지 | 메뉴 이동·배틀 명령이 워치만으로 됨, 안 떼짐 0회 |
| **P5** 누르고 있기 | ▶ 를 2·5초 누르는 동안 iPhone 에서 끊김(뗌→누름) 횟수, 뗀 뒤 실제 뗌까지 걸린 시간, 하트비트 간격 0.3/0.5초 비교 | 분당 끊김 수 표 |
| **P6** 크라운 | 디텐트 한 칸 = ▲/▼ 한 번, 빨리 돌릴 때 합치기 | 칸 수와 실제 커서 이동 수 일치율 |
| **P7** 되먹임 | 진동 등급 → 워치 햅틱(기본 끔), 게임 이름·상태 `updateApplicationContext`, 워치 화면 문구 | 진동이 효과음과 어긋나는 정도를 사용자가 듣고 판단 |
| (선택) **P8** BLE | iPad 앱이 GATT 서비스 광고, 워치가 붙어 "쓰기(응답 없음)"로 버튼 전송, P3 와 같은 표 | 워치 → iPad 가 실기기에서 되는지, 지연 비교 |

### 8.1 측정할 수치

- 왕복 지연: 평균·p50·**p95**·최대 (조건별 200회 이상). 편도는 왕복의 절반으로 어림(두 기기 시계를 맞추지 않으므로)
- 오류: `errorHandler` 횟수, 도달 불가 전환 횟수(10분 플레이당), 중복·역순 도착 수(일련번호로)
- 누르고 있기: 분당 끊김 수, 뗌 지연, 안 떼짐(1초 넘게 남은 누름) 횟수
- 손목 내림 뒤 첫 탭: 탭 → iPhone 도착 시간, 첫 탭이 버려지는지
- 전력: 30분 플레이 동안 워치 배터리 %, iPhone 온도 상태(기존 `Thermometer` 기록)
- 블루투스 혼잡: 컨트롤러 진동·이어폰 지직거림이 워치 연결로 늘어나는지(귀로 확인 + `Rumble.firesPerSecond`)

### 8.2 막힐 위험이 큰 지점

1. **지연 p95** — 가장 큰 위험. 보고값 상단(0.8초 이상)이면 턴제도 답답하다 [보도 5, 7].
2. **손목 내림 상태의 도달성** — 비활성 상태에서 `isReachable` 이 꺼지면 "손목을 들고 있어야 하는 컨트롤러"가 된다 [미확인].
3. **안 떼짐** — 뗌 메시지 유실·지연. 하트비트 + 끊기면 `releaseAll()` 로 막아야 한다.
4. **WCSession 수명** — 델리게이트 3종을 안 만들면 워치를 바꿀 때 iPhone 빙수가 백그라운드에서 종료될 수 있다 [문서 21]. 게임 중 앱 종료는 저장 데이터 위험(7.5 강제 종료 복구)과 연결된다.
5. **블루투스 무선 나눠 쓰기** — 이미 겪은 이어폰 지직거림이 커질 수 있다 [확인 근거, 추정 영향].
6. **xcodegen Info.plist 키 누락** — `WKApplication` 누락 시 설치 거부 [보도 40].
7. **시뮬레이터와 실기기 차이** — `transferUserInfo` 미지원, 네트워크 제약 미적용 [문서 3, 18]. 지연 판단은 실기기 값으로만.

---

## 참고 링크

Apple 문서 (원문 JSON: `https://developer.apple.com/tutorials/data/documentation/<경로>.json`)
1. CBPeripheralManager — https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager ("watchOS, tvOS, visionOS 에서는 광고 불가")
2. GCVirtualController — https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller (iOS·iPadOS·Mac Catalyst 15+)
3. TN3135: Low-level networking on watchOS — https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos (개정 2026-07-16)
4. WWDC21 "Connect Bluetooth devices to Apple Watch" — https://developer.apple.com/videos/play/wwdc2021/10005/
8. WCSession.isSupported() — https://developer.apple.com/documentation/watchconnectivity/wcsession/issupported()
9. Designing your app for the Always On state — https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state
10. Apple Watch 사용 설명서 "Turn on and wake Apple Watch" (watchOS 26) — https://support.apple.com/guide/watch/apd748b87e2a/26/watchos
11. Using extended runtime sessions — https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions · WKExtendedRuntimeSession — https://developer.apple.com/documentation/watchkit/wkextendedruntimesession
12. App Review Guidelines (2.3.8, 2.5.1, 2.5.4, 5.1.3) — https://developer.apple.com/app-store/review/guidelines/
13. WCSession.sendMessage(_:replyHandler:errorHandler:) — https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)
14. WKInterfaceDevice.play(_:) — https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:)
15. HIG Digital Crown — https://developer.apple.com/design/human-interface-guidelines/digital-crown ("앱은 크라운 누름에 반응하지 않는다")
16. Responding to the Action button on Apple Watch Ultra — https://developer.apple.com/documentation/appintents/actionbuttonarticle
17. WCSession.sendMessageData — https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessagedata(_:replyhandler:errorhandler:)
18. WCSession.transferUserInfo(_:) — https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:) ("시뮬레이터 미지원")
19. WCSession.updateApplicationContext(_:) — https://developer.apple.com/documentation/watchconnectivity/wcsession/updateapplicationcontext(_:)
20. WCSession.isReachable — https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable
21. WCSession (개요·여러 워치·전송 방식) — https://developer.apple.com/documentation/watchconnectivity/wcsession
25. NSApplicationServices — https://developer.apple.com/documentation/bundleresources/information-property-list/nsapplicationservices · DeviceDiscoveryUI — https://developer.apple.com/documentation/devicediscoveryui
26. Wi-Fi Aware — https://developer.apple.com/documentation/wifiaware
29. HIG Gestures (더블탭·시스템 제스처 충돌) — https://developer.apple.com/design/human-interface-guidelines/gestures
30. digitalCrownRotation(_:from:through:by:sensitivity:isContinuous:isHapticFeedbackEnabled:) — https://developer.apple.com/documentation/swiftui/view/digitalcrownrotation(_:from:through:by:sensitivity:iscontinuous:ishapticfeedbackenabled:)
31. DigitalCrownEvent — https://developer.apple.com/documentation/swiftui/digitalcrownevent
32. Enabling double tap — https://developer.apple.com/documentation/watchos-apps/enabling-double-tap
33. handGestureShortcut(_:isEnabled:) — https://developer.apple.com/documentation/swiftui/view/handgestureshortcut(_:isenabled:)
35. CMBatchedSensorManager — https://developer.apple.com/documentation/coremotion/cmbatchedsensormanager
36. WKExtension.isFrontmostTimeoutExtended — https://developer.apple.com/documentation/watchkit/wkextension/isfrontmosttimeoutextended
38. WKHapticType — https://developer.apple.com/documentation/watchkit/wkhaptictype
41. App Store Connect 스크린샷 규격 — https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/

포럼·기사·저장소 (2차 출처)
5. Apple 포럼 "Apple watch latency using WatchConnectivity" (2015, 편도 0.8초) — https://developer.apple.com/forums/thread/29184
6. Apple 포럼 "WCSession sendMessage reliability" (하트비트 왕복 약 0.25초) — https://developer.apple.com/forums/thread/20311
7. Apple 포럼 "WatchConnectivity sendMessageData slowness" (2015, Apple 엔지니어 답) — https://developer.apple.com/forums/thread/9368
22. Apple 포럼 "WatchConnectivity sendMessage Lag" (1~5초) — https://developer.apple.com/forums/thread/47765
23. Apple 포럼 "How much time … to receive a reply" (1~3초) — https://origin-devforums.apple.com/forums/thread/692393
24. Delta FAQ 컨트롤러 — https://faq.deltaemulator.com/using-delta/controllers
27. Apple 포럼 "WatchOS CoreBluetooth maximum peripheral connections" (앱당 2개, Apple 엔지니어) — https://developer.apple.com/forums/thread/738861
28. WWDC21 10005 노트(플랫폼 비교표: watchOS central 2연결·최소 간격 30ms — 검색 요약으로만 봄, 페이지는 열리지 않아 표 원문 미확인) — https://www.wwdcnotes.com/notes/wwdc21/10005
34. WWDC23 "What's new in Core Motion" 노트 (100Hz / 800Hz·200Hz) — https://wwdcnotes.com/notes/wwdc23/10179
37. iMore "How to keep your Apple Watch screen on longer" — https://www.imore.com/how-keep-your-apple-watch-screen-longer
39. XcodeGen PR #1470 (supportedDestinations 워치 Embed 누락) — https://github.com/yonaskolb/XcodeGen/pull/1470
40. cascade PR #1 (`WKApplication` 누락으로 설치 거부, `WKCompanionAppBundleIdentifier`) — https://github.com/JacobStephens2/cascade/pull/1
42. AppleInsider "watchOS 27 supported by just five Apple Watch models" (2026-06-08) — https://appleinsider.com/articles/26/06/08/watchos-27-supported-by-just-five-apple-watch-models
43. Macworld "Apple just made about a million Apple Watches obsolete" — https://www.macworld.com/article/3159669/apple-just-made-about-a-million-apple-watches-obsolete.html
44. WappyBird — https://github.com/NilStack/WappyBird
45. TechCrunch "Bowling Central Will Turn Your Apple Watch Into A Wii Remote For Apple TV" (2015) — https://techcrunch.com/?p=1175140
46. 9to5Mac "Giovanni Apple Watch Game Boy emulator prototype" (2017) — https://9to5mac.com/2017/03/20/giovanni-apple-watch-game-boy-emulator-prototype/
47. Product Hunt "a tiny game of pong" — https://www.producthunt.com/products/a-tiny-game-of-pong
48. VirtualGameController — https://gittrend.io/repo/robreuss/VirtualGameController

빙수 파일 (이번에 읽은 것)
- `BingsuApp/Bingsu/Spoon/SpoonController.swift` · `LongSpoon.swift` · `Rumble.swift` · `RumbleSet.swift` · `SpoonModel.swift`(PadButton)
- `BingsuApp/Bingsu/Bowl/BowlContainerView.swift` · `BrassBowl/BrassBowlContainerView.swift` · `Bowl/GlassBowl.swift`
- `BingsuApp/project.yml` · `PLAN.md` 7장·8장

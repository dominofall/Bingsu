# 주소로 넣은 웹 게임: 위협 분석과 대응 (2026-11-04)

사용자가 "게임 추가 › 주소로 웹 게임 추가"로 넣은 https 주소를 `GlassBowl`(WKWebView)이 전체화면으로 띄운다.
그 페이지가 악의적일 때 앱과 기기에 무엇을 할 수 있는지 코드로 따져 보고, 막을 방법을 우선순위대로 적는다.
PLAN 8.2 "웹 게임은 신뢰하지 않는다"의 3차 점검이다 (1차 Codex 보고서 대조, 2차 웹뷰·동기화 검토에 이어).

> **빌드 45 (2026-11-15) 에서 정한 범위:** 사용자 판단으로 F·H·I 와 개인정보 탈취 방어(비밀번호·카드 입력 경고, 닮은 주소 경고, 사기 사이트 경고), 로컬 웹 게임 온라인 차단만 했다.
> A·B·C·D·E·G 와 원격 전체화면 끄기는 "필요해지면" 으로 남긴다(포켓로그 같은 정상 게임에서도 나올 수 있는 성가심 수준이라 급하지 않음). J·K 는 앱이 막을 수 없다. 한 일은 **§5**.

## 0. 어디까지 닿는가

페이지는 WebKit 의 **WebContent 프로세스**(앱과 다른 샌드박스)에서 돈다. 앱 프로세스 메모리, 앱 컨테이너 파일, 키체인,
다른 게임의 웹 저장소(게임마다 `WKWebsiteDataStore(forIdentifier:)` 가 다름)에는 닿지 못한다.
페이지가 앱에 손댈 수 있는 길은 앱이 열어 준 것뿐이다.

| 길 | 어디 | 지금 상태 |
|---|---|---|
| 메시지 핸들러 `freezer`·`thermometer`·`bowl`·`rumble`·`sfx` (+ MV 전용 `mv`, DEBUG `diag`) | `GlassBowl.Coordinator.userContentController` | 값은 형식·범위 검증, 주 프레임만 받음. **빈도·횟수 제한 없음** |
| 네비게이션 위임 `decidePolicyFor` | `GlassBowl.Coordinator` | 다른 호스트는 사파리·로그인 시트·물어보기. **http·https 가 아닌 스킴은 그대로 통과(`.allow`)** |
| 새 창 `createWebViewWith` | 〃 | http·https 면 묻지 않고 사파리로 연다 |
| UI 위임(JS 대화상자, 카메라·마이크, 모션 권한) | 〃 | 구현 안 함 → alert·confirm·prompt 는 조용히 무시됨(좋음). 카메라·마이크·모션은 WebKit 기본 동작 |
| iOS 가 주는 웹 API (저장소, Web Audio, 전체화면, 로컬 네트워크, 위치) | WebKit | 전체화면 켜짐(`isElementFullscreenEnabled`), 로컬 네트워크 문구 있음, 카메라·위치 문구 없음 |
| 사용자 눈 | 화면 전체, 주소창 없음 | 로그인 시트만 실제 호스트·자물쇠 표시. 일시정지 화면은 주소를 안 보여 줌 |

이미 잘 막혀 있는 것 (코드 근거):
- 원격 게임은 `freezerEnabled == false` → localStorage 를 파일로 쓰지 않고, `freezer` 메시지는 버린다. 로그인 토큰이 파일·iCloud 로 새지 않는다 (`GlassBowl.makeUIView`, `Igloo` 의 `!dish.isRemote` 가드 6곳).
- 네이티브 → 페이지로 가는 값은 숫자(볼륨·fps·패드 축)와 고정 키 코드뿐이다. 페이지가 읽어서 득 볼 앱 데이터가 없다.
- 다른 호스트로의 주 프레임 이동은 전부 `cancel` 되므로 교차 사이트 유니버설 링크(다른 앱 열기)도 같이 막힌다. 서버 리다이렉트도 `decidePolicyFor` 를 다시 타므로 우회 못 한다.
- `createWebViewWith` 는 http·https 만 열고 웹뷰를 돌려주지 않는다. `allowsLinkPreview`·뒤로 가기 제스처 끔. `isInspectable` 은 DEBUG 만.
- 릴리스 로그는 빙수 스크립트의 사건 이름만 남긴다(`bowlEvents`). 페이지 문자열이 로그에 안 찍힌다.
- `WebGames.json` 은 파일 공유가 꺼져 있어 밖에서 못 고치고, 읽을 때 `normalize` 로 다시 검증한다. 앱 URL 스킴은 Drive 되돌림 하나뿐이고 `onOpenURL` 은 `file://` 만 가져오기로 보낸다 → 웹 페이지가 앱 안 기능을 깊은 링크로 부를 길이 없다.
- 인증서 검증은 WebKit 기본(`didReceive challenge` 미구현)이라 가짜 인증서는 거부된다. ATS 예외 없음.

물리적으로 기기를 망가뜨릴 길은 없다. 현실적인 피해는 네 가지다: **앱 먹통**(메인 스레드 고갈, 재시작 반복),
**자원 소모**(발열·배터리·저장 공간), **성가심**(진동 폭주, 사파리로 튕김, 전화 걸기 창), **속이기**(가짜 로그인 화면).
그리고 WebKit 자체 취약점은 앱이 막을 수 없고 iOS 업데이트에 기댄다.

## 1. 위협 시나리오와 대응

심각도: 높음 = 앱이 먹통이 되거나 사용자가 벗어나기 어렵다 · 중 = 자원 소모나 속임수 · 낮음 = 성가심.

### A. 메시지 폭주로 앱 메인 스레드 고갈 — 높음
페이지가 `webkit.messageHandlers.bowl.postMessage(...)` 를 초당 수만 번 부르면, 메시지마다 앱 메인 스레드에서 `NSLog`
(`bowl`), `Task { @MainActor }` 생성(`thermometer`·`sfx`·`rumble`), 햅틱 호출이 돈다. 페이지가 아니라 **앱이** 굳고,
오래 가면 워치독이 앱을 죽인다. 본문을 수십 MB 문자열로 보내면 직렬화 비용과 앱 메모리도 같이 뛴다.

대응 (`GlassBowl.Coordinator`):
- 핸들러마다 초당 상한을 두고 넘으면 **그 핸들러를 떼어 낸다**(`removeScriptMessageHandler(forName:)`). 빙수 스크립트가 보내는 빈도는 정해져 있다: `thermometer` 1/s, `freezer` 최대 1/5s, `bowl` 사건 몇 개, `sfx`·`rumble` 은 효과음 빈도. 상한 예: `thermometer` 5, `freezer` 2, `bowl` 30, `sfx` 40, `rumble` 40 (초당). 떼어 내면 로그 한 줄 + 그 게임 성능 기록에 표시. 게임을 다시 열면 복구.
- 본문 크기 상한: `message.body` 가 문자열·사전이면 전체 길이를 먼저 재고(예: 64KB) 넘으면 버린다. (`freezer` 는 이미 `Freezer.maxBytes` 로 재지만 원격은 어차피 끔.)
- 문자열을 `NSLog` 에 넣는 DEBUG 경로도 길이 300 은 유지하되 초당 상한 뒤에 둔다.

### B. 진동 폭주 — 중
`rumble`(값 범위는 자름)과 `sfx`(이름 → 진동표) 는 횟수 제한이 없다. `Rumble.play` 는 블루투스 보호가 켜진 때만 0.3초 간격을 둔다.
컨트롤러·폰 햅틱을 쉬지 않고 울리면 배터리와 모터를 소모하고, 사용자는 게임을 끄는 것 말고 멈출 수 없다.

대응 (`Rumble`): 게임 요청 진동에 **초당 누적 길이 상한**(예: 1초에 0.6초)과 최소 간격(50ms)을 둔다. 보이지 않을 때(홈 뒤·다른 앱)는 무시. 넘치면 버리기만 하고 로그는 1분에 한 줄.

### C. 메모리 폭주 → WebContent 종료 → 무한 재시작 — 중~높음
페이지가 메모리를 계속 먹으면 iOS 가 WebContent 를 죽이고, `webViewWebContentProcessDidTerminate` 가 바로 `reload()` 한다.
악성 페이지는 뜨자마자 또 먹으므로 **죽고 → 다시 뜨고 → 죽는 고리**가 된다. 토스트는 두 번째부터 화질을 권하지만 고리를 끊지 않는다.

대응 (`GlassBowl.Coordinator` + `BowlContainerView.restarted`): 10분 안에 3번째 종료부터는 다시 불러오지 않고 "이 게임이 계속 멈춰요" 화면(나가기 / 한 번 더 시도)을 띄운다. 횟수는 이미 `crashes` 로 센다.

### D. CPU 스핀·발열 — 중
페이지가 워커·`setTimeout` 루프로 CPU 를 다 쓰면 rAF 제한(`setFpsCap`)으로는 못 막는다. 열 상태가 올라가면 자동 프레임 제한이 30 으로 내리지만 그것도 rAF 뿐이다.
홈 뒤에 숨겨 둔 게임은 `__bingsu.pause()` 를 부르는데, 이는 페이지가 **따를 수도 안 따를 수도 있는** 부탁이다.

대응:
- 열 상태 `.critical` 이면 웹뷰를 멈추고 안내한다. 멈춤은 페이지에 부탁하지 않고 네이티브가 한다: 웹뷰를 화면 밖·`isHidden` 으로 두면 WebKit 이 rAF·타이머를 스로틀하고, 그래도 뜨거우면 "게임을 닫을까요?" 를 묻는다.
- 홈 뒤에 숨긴 뒤 일정 시간(예: 10분)이 지나면 닫기를 제안한다 (iOS 백그라운드는 OS 가 멈추므로 홈 화면 뒤에 숨은 때만 문제).

### E. 저장 공간 채우기 — 중
페이지는 자기 출처의 IndexedDB·Cache API 를 WebKit 쿼터까지 채울 수 있고, 하위 프레임으로 출처를 늘리면 더 채운다.
앱은 저장소 크기를 공개 API 로 못 잰다. 지금은 게임을 목록에서 지울 때만 저장소를 지운다.

대응: 이 게임 설정에 "웹 저장소 비우기"(쿠키·로그인은 남기고 캐시·IndexedDB·Cache 만, 또는 전부) 를 넣는다. `fetchDataRecords(ofTypes:)` 로 **어느 출처가 데이터를 두었는지** 목록은 보여 줄 수 있다(크기는 못 봄). 우리 `audioCache` 스크립트는 아는 게임(포켓로그)에만 붙으므로 모르는 호스트에서 Cache 를 키우지 않는다 — 이 조건을 유지한다.

### F. 웹이 아닌 스킴으로 이동 → 전화·외부 앱 — 중
`ExternalLink.route` 는 http·https 가 아니면 `.stay` 를 돌려주고 `decidePolicyFor` 는 `.allow` 한다.
`tel:`·`facetime:`·`sms:`·`itms-apps:`·설치된 앱의 사용자 지정 스킴을 주 프레임이나 하위 프레임이 열면 WebKit 이 시스템에 넘길 수 있다
(사용자 제스처가 있는 경우 iOS 가 "전화를 걸까요?" 같은 창을 띄우거나 다른 앱으로 보낸다). 게임을 하는 중에는 화면 아무 데나 누르는 것이 제스처다.

대응 (`GlassBowl.Coordinator.decidePolicyFor`): 원격 게임은 주 프레임·하위 프레임 모두 **`http`·`https`·`about`·`blob`·`data` 만 `.allow`**, 나머지는 `.cancel` + 로그. (MV 는 이미 자기 스킴 밖을 거부한다. Electron 도 마찬가지.)

### G. 사파리·다른 앱으로 튕기기 — 낮음
링크 클릭(`linkActivated`)과 사용자 제스처가 있는 `window.open` 은 묻지 않고 사파리를 연다. 페이지가 화면 전체를 링크로 만들면 누를 때마다 앱을 떠난다.
사파리에서 다시 App Store·유니버설 링크로 이어질 수 있다.

대응: 게임이 스스로 옮기는 경우에 쓰는 `askToOpen`(실제 호스트를 보여 주고 묻고, 두 번 거절하면 버림)을 **클릭과 새 창에도 똑같이** 쓴다. 게임 안 링크는 드물고, 묻는 창이 더 안전하다.

### H. 가짜 화면(피싱) — 중
주소창이 없는 전체화면이라 페이지가 빙수의 일시정지 화면이나 "Apple ID 비밀번호" 창을 흉내 낼 수 있다. 로그인 시트는 실제 호스트를 보이지만 게임 화면 자체는 어디인지 안 보인다.
또 `isElementFullscreenEnabled` 가 켜져 있어 페이지가 `requestFullscreen()` 하면 WebKit 의 전체화면 뷰가 **빙수의 일시정지 버튼 위**에 올라온다 (WebKit 이 닫기 버튼을 주지만 사용자는 빙수 버튼이 사라진 것으로 보인다).

대응:
- 일시정지 화면 머리에 **지금 주소의 호스트**를 보여 준다 (`webView.url?.host`, 로그인 시트와 같은 자물쇠 표시).
- 원격 게임은 `isElementFullscreenEnabled = false`. 이미 전체화면이라 게임이 잃는 것이 없다. 포켓로그·포켓본크가 전체화면 호출 실패를 어떻게 다루는지 시뮬레이터로 확인한 뒤 적용.
- JS 대화상자(`runJavaScriptAlertPanel` 등)는 **앞으로도 구현하지 않는다**는 규칙을 PLAN 8.2 에 적는다. 구현하면 페이지가 앱 이름을 단 시스템 창을 띄울 수 있다.
- 사용자 안내(베타 가이드): 빙수는 게임 화면 안에서 비밀번호를 묻지 않는다. 로그인은 위에 주소가 보이는 시트에서만.

### I. 카메라·마이크·모션·위치 요청 — 낮음~중
Info.plist 에 카메라·마이크·위치 설명 문구가 없다. `requestMediaCapturePermissionFor` 를 구현하지 않아 페이지의 `getUserMedia` 는 WebKit 기본(물어봄)으로 간다.
설명 문구 없이 권한 요청이 앱 프로세스까지 가면 iOS 가 **앱을 종료**할 수 있다(TCC 규칙). WebKit 이 먼저 거르는지는 확실하지 않다.
위치는 CoreLocation 이 문구 없이는 거부하므로 창이 안 뜨고, 모션 권한(`requestDeviceOrientationAndMotionPermissionFor`)은 기본이 물어보기다.

대응: 두 위임 메서드를 구현해 원격 게임은 **무조건 `.deny`**. 시뮬레이터에서 `getUserMedia`·`DeviceMotionEvent.requestPermission` 을 부르는 테스트 페이지로 종료 여부를 확인한다. (`NSLocalNetworkUsageDescription` 은 파티! 통신 대전용이라 유지. 페이지가 LAN 주소로 fetch 하면 빙수 이름으로 권한 창이 뜬다 — 문구가 정직하므로 그대로 두고 가이드에 적는다.)

### J. 소리 크기 우회 — 낮음
빙수의 볼륨은 `AudioContext` 생성자를 감싼 GainNode 다. 페이지가 `iframe.contentWindow.AudioContext` 나 `<audio>` 요소를 쓰면 우회된다. 앱 세션이 `.playback` 이라 무음 스위치도 안 듣는다.
대응: 막을 공개 API 가 없다. 사용자 설정이 "부탁"임을 문서에 적고, 기기 볼륨 버튼에 맡긴다. (알려진 게임에서는 동작하므로 기능은 유지.)

### K. WebKit 자체 취약점 — 낮은 확률, 큰 피해
브라우저 엔진 0-day 는 앱이 못 막는다. 피해 범위는 WebContent 샌드박스와 그 게임의 저장소까지다.
대응: 베타 가이드에 iOS 최신 유지 권고. 선택지로 `defaultWebpagePreferences.isLockdownModeEnabled`(iOS 16+) 게임별 옵션 "보안 강화 모드"를 검토했으나, JIT·일부 WebGL·Gamepad API 가 꺼져 **대부분 게임이 안 돌아간다** → 기본 끔, 넣더라도 설명과 함께 선택.

### L. 그 밖에 확인한 것 (문제 없음)
- 하위 도메인 로그인 시트: `*.<게임 호스트>` 만 허용하는데 게임 호스트 주인이 곧 공격자인 경우뿐이라 추가 위험 없음. 시트는 https 만 열고 호스트를 보여 준다.
- 저장소 번호: `WebStoreID` SHA-256. `pokerogue.net.evil.com` 은 `.pokerogue.net` 접미사가 아니라 포켓로그 저장소를 못 받는다.
- 다운로드: `navigationResponse` 정책을 구현하지 않아 첨부 파일 응답은 실패로 끝나고 파일이 남지 않는다. 이 상태를 유지한다.
- 하위 프레임의 메시지는 `frameInfo.isMainFrame` 으로 버린다. 앱이 주입한 스크립트는 주 프레임에만 들어간다.

## 2. 적용 순서

| 차수 | 항목 | 손댈 곳 |
|---|---|---|
| 1차 (다음 빌드) | A 메시지 빈도·크기 상한 / F 비웹 스킴 차단 / C 재시작 고리 끊기 / I 카메라·모션 거부 / B 진동 상한 | `GlassBowl.swift`, `BowlContainerView.swift`, `Rumble.swift` |
| 2차 | H 일시정지 화면에 호스트 표시 + 원격 전체화면 끔 / G 클릭·새 창도 물어보기 / D 열 상태 critical 멈춤·숨긴 게임 닫기 제안 | `PauseBoard.swift`, `GlassBowl.swift`, `BowlContainerView.swift` |
| 3차 | E 웹 저장소 비우기·출처 목록 / K 보안 강화 모드 검토 / PLAN 8.2·베타 가이드 문구 | `DishSettingsView.swift`, `PLAN.md`, `docs/beta/guide.md` |

## 3. 검증: 악성 흉내 페이지

`tools/` 에 정적 HTML 하나를 두고 로컬 http 서버 + `BINGSU_ALLOW_HTTP=1` 로 시뮬레이터에 넣는다. 버튼마다 한 시나리오:
1. `bowl` 에 초당 10만 번 postMessage (A) → 앱이 안 굳고 핸들러가 떨어져 나가는지, 로그 한 줄
2. 100MB 문자열 postMessage (A) → 버려지고 앱 메모리가 튀지 않는지
3. `rumble` 1ms 간격 무한 (B) → 초당 누적 길이 상한
4. 1초마다 200MB 배열 할당 (C) → 3번째 종료 뒤 안내 화면, 더 이상 reload 없음
5. 워커 4개 무한 루프 (D) → 열 상태 변화와 멈춤 (실기기)
6. `location = "tel:114"`, `<a href="facetime:...">`, `itms-apps:` (F) → 아무 창도 안 뜸
7. `window.open("https://example.com")`, 전체 화면 링크 (G) → 물어보는 창, 두 번 거절 뒤 조용
8. `requestFullscreen()` (H) → 거부되고 빙수 버튼 그대로
9. `getUserMedia`, `DeviceMotionEvent.requestPermission()` (I) → 거부, 앱 종료 없음
10. IndexedDB 에 1GB 쓰기 (E) → 설정에서 비우기로 회수

포켓로그·포켓본크·기본 게임 회귀: 패드·효과음 진동·음악 저장·로그인 시트가 그대로인지.

## 4. 확인하지 못한 것 (실기기·시뮬레이터로 볼 것)
- `tel:` 등을 `.allow` 했을 때 지금 WKWebView 가 실제로 시스템 창을 띄우는지 (F 는 어느 쪽이든 차단이 맞다)
- 설명 문구 없이 `getUserMedia` 가 앱을 종료시키는지 (I)
- WebKit 전체화면 뷰가 빙수 버튼을 덮는지, 닫기 버튼 위치 (H)
- 게임 하나가 채울 수 있는 WebKit 쿼터 실제 값 (E)

## 5. 빌드 45 에서 한 것 (2026-11-15)

사용자 결정: 카메라·마이크는 게임 개발자에게 맡기되 **플레이어 동의 없이는 넘기지 않는다**. 로컬 웹 게임의 온라인 접속은 **기본 켬, 게임별로 끄기**.

| 항목 | 한 일 | 손댄 곳 |
|---|---|---|
| F 비웹 스킴 | 원격 게임은 주 프레임·하위 프레임 모두 `http`·`https`·`about`·`blob`·`data` 만 허용, 나머지는 취소 + 로그 `blocked non-web scheme` | `GlassBowl.decidePolicyFor`, `ExternalLink.isPageScheme` |
| H 어디인지 보이기 | 일시정지 화면 제목 아래에 지금 페이지 호스트(https 는 자물쇠, 아니면 주황 열린 자물쇠) | `PauseBoard.pageURL` |
| 비밀번호·카드 입력 경고 | 원격 게임의 모든 프레임에 `focusin` 감시 스크립트. 비밀번호(type·가림 글꼴·autocomplete·이름), 카드(cc-*·카드 번호·CVC) 칸에 들어가면 위에 배너 "이 입력란은 〈실제 프레임 호스트〉 사이트의 것이에요" 8초. 호스트는 페이지가 아니라 `frameInfo.securityOrigin` 에서 읽어 속일 수 없다 | `CredentialGuard`, `BowlContainerView.CredentialBanner` |
| 닮은 주소 경고 | 주소로 추가할 때 알려진 사이트(포켓로그·구글·애플·디스코드·네이버·카카오·페이팔·스팀 등)와 철자 1~2자 차이, 이름을 끼워 넣은 다른 도메인, 한글·키릴 등 비ASCII·`xn--` 이면 "이 주소가 맞나요?" (취소 / 그래도 추가). github.io·itch.io 같은 호스팅 하위 도메인은 비교 안 함. 입력 아래 "열리는 사이트: 호스트" 상시 표시 | `HostCheck`(WebGames.swift), `AddWebGameView` |
| 사기 사이트 | `isFraudulentWebsiteWarningEnabled = true` (사파리와 같은 세이프 브라우징 경고) | `GlassBowl.makeUIView` |
| I 카메라·마이크·모션 | 두 위임 메서드 구현. 빙수가 먼저 "〈카메라〉 사용을 허락할까요?"(게임 이름·주소 표시) 를 묻고, 허용해야 iOS 권한 창으로 간다. 게임 자기 출처의 답만 게임별로 기억(`DishPrefs.media`), 다른 출처(광고 iframe 등)는 매번 묻고 기억 안 함. 창이 떠 있는 동안 온 요청은 거부. 이 게임 설정 › 권한 에서 바꾸기·"다음에 다시 묻기". Info.plist 카메라·마이크 문구 추가 | `GlassBowl.askMedia`, `MediaConsent`, `DishSettingsView`, `project.yml` |
| 로컬 웹 게임 온라인 차단 | 팥빙수(Electron)·녹차빙수(MV·MZ) 도 이 게임 설정 › 온라인 접속 허용 스위치. 끄면 콘텐츠 규칙으로 `http(s)`·`ws(s)` 전부 차단 + 모든 프레임에서 `RTCPeerConnection` 등 제거. 다음 실행부터 적용 | `OfflineRules`, `DishSettingsView` |

확인 (시뮬레이터, DEBUG):
- 시험 페이지(로컬 http + `BINGSU_ALLOW_HTTP=1`): 카드 칸 → 배너 "127.0.0.1", 다른 출처 iframe 의 가림 칸 → 배너 "localhost". `tel:`·`itms-apps:` 차단 로그. 모션 → 빙수 창 → 허용 안 함 → 기억, 두 번째는 조용히 거부. 카메라 → 허용 → 페이지가 스트림 받음, 앱 종료 없음. 일시정지 화면에 127.0.0.1 + 주황 자물쇠
- 운빨던전(iPad, 온라인 끔, `BINGSU_SELFTEST=1`): `offline rules on`, `selftest offline fetch=blocked ws=blocked rtc=gone`, 게임 정상 실행. 설정 화면에 온라인 스위치(끔)와 문구 표시
- 포켓로그 회귀(iPhone): 정상 로드, 차단 로그 없음, 로그인 창 비밀번호 칸 → 배너 "pokerogue.net", 키보드·암호 자동 채우기 정상
- 닮은 주소 판정은 따로 돌린 스크립트로 확인(pokeroque.net·pokerogue.net.evil.com·goggle.com·키릴 o 의 gооgle.com 경고, example.github.io·mygame.itch.io·pokerogue.net 통과). **추가 화면의 경고 창 자체는 시뮬레이터 글자 입력이 안 돼 못 봄**

알려진 한계:
- 캔버스에 직접 그린 입력란(게임 엔진 UI)은 감지 못 한다. 배너는 HTML 입력란만
- `about:blank`·`srcdoc` 프레임의 WebRTC 는 완전히 못 막을 수 있다(스크립트 주입 시점 차이). 일반 http(s) 요청은 콘텐츠 규칙이 막는다
- 시뮬레이터에는 카메라·마이크 장치가 없어 iOS 권한 창 단계와 마이크 실제 스트림은 **실기기에서 확인할 것**
- 닮은 주소 목록은 손으로 고른 이름뿐이다. 목록에 없는 사이트를 흉내 낸 주소는 못 잡는다

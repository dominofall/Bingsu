# Google Drive 저장 데이터 동기화 — 사전 조사

작성 2026-11-01. 로드맵 "저장 데이터 클라우드 동기화 2차(Google Drive·Dropbox 어댑터)"(`PLAN.md` Phase 2) 를 만들기 전 조사. **코드는 바꾸지 않았다.** 사실마다 출처(URL 또는 읽은 파일)를 달았고, 확인하지 못한 것은 **미확인** 으로 표시했다. 실제 클라이언트 ID 같은 값은 적지 않는다(`PLAN.md` 8장).

---

## 0. 요약 (한 화면)

**권장: (A) Google Drive REST API v3 를 직접 호출 + `drive.appdata` 범위 + SDK 없이 `ASWebAuthenticationSession` + PKCE.**

- `drive.appdata` 와 `drive.file` 은 Google 이 **비민감(non-sensitive)** 으로 분류하므로 OAuth 앱 검증이 의무가 아니다. 민감·제한 범위만 검증을 요구한다 ([범위 분류](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), [검증 FAQ](https://support.google.com/cloud/answer/13463073)).
- iOS OAuth 클라이언트는 클라이언트 시크릿이 없고(`PLAN.md` 8.1 "PKCE 공개 클라이언트" 원칙과 일치), 리다이렉트는 클라이언트 ID 를 뒤집은 URL 스킴(`com.googleusercontent.apps.<id>:/oauth2redirect`) 이다. Google 자체 SDK 도 같은 스킴을 쓴다 ([Sign-In 설정](https://developers.google.com/identity/sign-in/ios/start-integrating)).
- 필요한 API 는 다섯 개뿐이다: `files.list(spaces=appDataFolder)`, `files.create`(multipart ≤5MB, resumable >5MB), `files.get?alt=media`, `files.update`(PATCH), `files.delete`. 변경 감지는 `changes.getStartPageToken` + `changes.list(spaces=appDataFolder)`.
- SDK(B) 는 Apache-2.0 이라 GPLv3 빙수에 넣는 것 자체는 문제없지만, 의존성 4개(GoogleSignIn·GTMAppAuth·AppAuth·GTMSessionFetcher) 가 모두 Apple 의 "개인정보 영향 SDK 목록"에 올라 있고, Objective-C 라이브러리라 Swift 코드가 늘어나는 것에 비해 얻는 게 토큰 관리뿐이다.
- Files 앱 경유(C) 는 **폴더 선택이 Google Drive·Dropbox 제공자에서 회색으로 비활성** 이라(Apple 포럼·DTS 답변, 2021) 전체 동기화 어댑터로 쓸 수 없다. 파일 하나씩 "가져오기·내보내기"는 이미 지금 UI 로 된다.
- 지금 `IglooShelf`(동기 5함수, 경로 기반) 를 그대로 Drive 에 끼우려면 **경로↔파일 ID 매핑, 비동기·네트워크 오류, 계정 상태, 백엔드별 state.json, ConflictView 의 "iCloud" 고정 문구** 다섯 군데를 손봐야 한다(3.7).

**첫 PoC (반나절):** Google Cloud 프로젝트 + iOS 클라이언트 만들기 → 빈 앱에서 `ASWebAuthenticationSession` 으로 동의 화면 → 토큰 교환(PKCE) → `files.create` 로 appDataFolder 에 `hello.json` 올리고 `files.list` 로 보기. 여기까지 되면 나머지는 Igloo 재사용이다.

**막힐 위험이 큰 지점:** ① 프로덕션 동의 화면에 "소유한 도메인의 홈페이지·개인정보 처리방침 URL" 이 필요한데 지금 처리방침은 claude.ai Artifact 다(도메인 필요). ② Testing 상태에서는 갱신 토큰이 7일 만에 만료되고 테스터 100명 제한. ③ `drive.appdata` 는 PC 에서 파일이 보이지 않으므로 "PC(Windows)와 공유"(`PLAN.md` 3.4 표) 를 바라면 `drive.file`+보이는 폴더로 바꿔야 한다(둘 다 비민감이라 전환 비용은 낮다).

---

## 1. 지금 iCloud 동기화가 어떻게 돼 있나 (읽은 것)

읽은 파일: `BingsuApp/Bingsu/Freezer/Igloo.swift`, `Freezer/Freezer.swift`, `Kitchen/ConflictView.swift`, `Kitchen/FreezerSection.swift`, `Kitchen/SavedDataView.swift`, `PLAN.md`(3.4, Phase 2 iCloud 항목, 8장), `BingsuApp/project.yml`, `Bingsu.entitlements`, `docs/beta/privacy.html`.

### 1.1 파일 배치 (컨테이너 `Documents/` 기준, 로컬 `Documents/` 와 같은 모양)

| 클라우드 경로 | 내용 | 규칙 |
|---|---|---|
| `Saves/<dataPathApp>/save.json` | 로컬 save.json + 올린 기기 정보 `device`·`model`·`playSeconds`·`uploadedAt` | savedAt 3자 비교(아래) |
| `Saves/<dataPathApp>/backups/*.json` | 백업 | 양쪽 합집합, 지우기는 퍼뜨리지 않음 |
| `Prefs/<id>.json` | 게임별 설정 (≤64KB) | 수정 시각이 늦은 쪽이 이김, `recommendedQuality` 는 로컬 유지 |
| `Covers/<파일>` | 표지 (≤8MB, jpg/png) | 없는 쪽에 복사 |

### 1.2 판단 규칙 (`IglooEngine.reconcile`)

로컬 `savedAt`(L), 클라우드 `savedAt`(C), 이 기기가 마지막으로 맞춘 `savedAt`(B, `Library/Application Support/Igloo/state.json`).
L == C 같음 · L == B → 클라우드가 새것(내려받기) · C == B → 로컬이 새것(올리기) · 내용이 같으면 충돌 아님 · 그 밖 → **충돌**(덮어쓰지 않고 `ConflictView` 로 묻는다, 고르지 않은 쪽은 `backups/` 에).
클라우드 파일은 신뢰하지 않는다: `Freezer.validate`(≤16MB, `format`·`version`, 키 정규식 `^<prefix>[A-Za-z0-9_.-]+$`, 문자열 값) + `savedAt` 범위 검사. 깨진 클라우드 파일은 내려받지도, 그 위에 올리지도 않는다.

### 1.3 백엔드 추상화 `IglooShelf` (지금)

```swift
protocol IglooShelf {
    func read(_ path: String, maxBytes: Int) throws -> Data?   // 없으면 nil, 크면 tooLarge
    func write(_ path: String, _ data: Data, modified: Date?) throws
    func list(_ dir: String) -> [String]
    func modified(_ path: String) -> Date?
    func remove(_ path: String) throws
}
```
- **동기 함수**이고 `Igloo.queue`(직렬 utility 큐) 에서만 돈다. `ICloudShelf` 는 `NSFileCoordinator` 로 읽고 쓰며, 아직 안 내려온 파일은 `startDownloadingUbiquitousItem` 뒤 최대 4초 기다린다.
- 동기화 시점: `prepareOpen`(게임 열기 직전) · `afterPlay`(종료·백그라운드, `beginBackgroundTask` 로 짧게) · `syncAll`(앱 활성화·"지금 동기화") · `forget`(저장 데이터 삭제).

### 1.4 iCloud 에 묶여 있는 지점 (Drive 를 붙일 때 손봐야 함)

| 위치 | 내용 |
|---|---|
| `Igloo.enabledKey = "bingsu.icloudSync"` | 토글 하나. 백엔드 선택 개념이 없다 |
| `Igloo.Availability` 와 `statusText` | `noAccount`/`unavailable` 문구가 "iCloud 에 로그인돼 있지 않아요" 등 iCloud 전용 |
| `Igloo.makeEngine` | `ubiquityIdentityToken`·`url(forUbiquityContainerIdentifier:)` 로만 선반을 만든다 |
| `IglooEngine.isOutOfSpace` | `NSFileWriteOutOfSpaceError`/`ENOSPC` 만 본다 → Drive 는 HTTP 403 `storageQuotaExceeded` |
| `IglooState`(state.json) | 백엔드 구분 없이 하나. B 값은 **백엔드마다** 달라야 한다 |
| `ConflictView` | 카드 제목 "iCloud", 아이콘 `icloud`, 안내문 "이 기기와 iCloud 에…" 고정 |
| `FreezerSection`·설정 화면 | "iCloud 동기화" 라벨 |
| `SavedDataView` 삭제 문구 | "이 기기와 iCloud 에서 … 지워지고" |
| `docs/beta/privacy.html` 3절 | iCloud 만 설명 |

---

## 2. 비교표

### 2.1 Google Drive — 세 가지 접근

| 항목 | (A) REST v3 직접 + `drive.appdata` + ASWebAuthenticationSession/PKCE | (B) Google Sign-In iOS SDK + GoogleAPIClientForREST | (C) Files 앱 Google Drive File Provider (API 없음) |
|---|---|---|---|
| 인증 | iOS 클라이언트(시크릿 없음), PKCE S256, 되돌림 = 뒤집은 클라이언트 ID 스킴. 토큰 교환·갱신·Keychain 저장을 직접 구현 | SDK 가 로그인·토큰 갱신·Keychain 복원(`restorePreviousSignIn`) 처리. `addScopes` 로 `drive.appdata` 추가 | 없음. 사용자가 Drive 앱에 로그인돼 있어야 함 |
| 의존성 | 없음 (URLSession, CryptoKit, AuthenticationServices, Security) | SwiftPM 패키지 4종: GoogleSignIn(10.x, iOS 15+), AppAuth 3.0, GTMAppAuth 6.0, GTMSessionFetcher 4~5.x. Drive 클라이언트는 Objective-C 생성 코드 | 없음 |
| 라이선스 | 해당 없음 | 모두 Apache-2.0 → GPLv3 안에 포함 가능(단방향 호환). THIRD_PARTY_LICENSES 에 4건 추가 | 해당 없음 |
| 개인정보 매니페스트 | 앱 자체 매니페스트만 (빙수는 아직 없음 — 후속 과제, 3.5) | 4개 모두 Apple "개인정보 영향 SDK 목록"에 있어 매니페스트 필수. 서명은 바이너리 배포에만 요구(SwiftPM 소스 빌드는 해당 없음) | — |
| 범위·검증 | `drive.appdata` 비민감 → 검증 의무 없음. 로고·이름 표시를 원하면 브랜드 검증(선택) | 동일 | — |
| 사용자에게 보이나 | 안 보임(숨은 앱 데이터). Drive 설정 › 앱 관리에서 크기 확인·삭제만 가능 | 동일 | 사용자가 고른 폴더에 그대로 보임 |
| PC 공유 | 불가(우리 앱만 읽음). 원하면 `drive.file` 로 전환 | 동일 | 가능(Drive 데스크톱으로 보임) |
| 백그라운드·오프라인 | 네트워크 필요. 짧은 올리기는 `beginBackgroundTask`, 더 길면 백그라운드 URLSession | 동일 | 앱이 전경일 때만 안전. 제공자가 로컬 사본을 지우면 다시 내려받아야 함 |
| 변경 감지·충돌 | `changes.list`, `md5Checksum`, `version`, `appProperties` 활용 가능 | 동일 | 파일 수정 시각만 |
| 결정적 제약 | 없음 | 앱 크기 증가(수치 미확인), Objective-C 의존 | **폴더 선택이 Google Drive 제공자에서 비활성**(DTS 확인, 2021 · iOS 26 재확인 미확인), 북마크 만료, Drive 앱 설치 필요 |
| 공수(추정) | 인증 1~1.5일 + 선반 1일 + Igloo 추상화 1일 + 화면 0.5일 ≈ **4일** | 인증 0.5일 + 선반 1일 + 추상화 1일 + 라이선스·매니페스트 0.5일 ≈ **3일** (대신 유지보수 부담) | 전체 동기화 불가. 파일 단위 "내보내기/가져오기"는 이미 있음 |

### 2.2 Dropbox — 같은 셋 (짧게)

| 항목 | (A) HTTP API v2 직접 + App folder + PKCE | (B) SwiftyDropbox SDK | (C) Files 앱 Dropbox File Provider |
|---|---|---|---|
| 인증 | 코드 플로 + PKCE(시크릿 없는 앱용), `token_access_type=offline` 로 갱신 토큰, 짧은 수명 액세스 토큰 | SDK 가 PKCE 코드 플로·짧은 토큰 자동 갱신 처리. iOS 12+, SwiftPM, MIT | 없음 |
| 범위 | 앱 폴더(`Apps/<앱 이름>/`) 읽기·쓰기만. 사용자에게 **보임**(PC 에서도 보임) | 동일 | 사용자가 고른 폴더 |
| 심사 | Google 식 범위 검증은 없음. 대신 Development 상태는 500명까지 연결, **50명 넘으면 2주 안에 Production 신청** 안 하면 새 연결 동결. 심사 무료 | 동일 | — |
| 제약 | `files/upload` 한 요청 150MB(16MB 파일엔 충분), `content_hash`·`client_modified`·`rev` 로 충돌 판정, `list_folder` 커서 + `longpoll` | 동일 | 폴더 선택은 Dropbox 제공자도 회색(2021 보고). 2022~23 iPadOS 포럼에 불안정 보고 |
| 평가 | Drive 어댑터를 만들면 거의 같은 모양으로 추가 가능(폴더가 보인다는 점이 다름) | 라이선스 가볍고 의존성 1개라 B 가 Drive 보다 매력적 | 부적합 |

---

## 3. 항목별 상세

### 3.1 (A) REST API v3 직접 + ASWebAuthenticationSession + PKCE

**OAuth 클라이언트.** Google Cloud 콘솔 › Google Auth Platform › Clients 에서 **iOS 종류**로 만든다. 입력: 이름, 번들 ID(`com.minwoo.bingsu`), App Store ID(출시 뒤 선택), Team ID(선택, App Check 쓸 때 필수) ([OAuth 2.0 for iOS & Desktop Apps](https://developers.google.com/accounts/docs/OAuth2InstalledApp)). iOS 클라이언트에는 시크릿이 없고 토큰 요청에 `client_secret` 을 보내지 않는다 ([native-app](https://developers.google.com/identity/protocols/oauth2/native-app)). 플랫폼마다 따로 클라이언트를 만들고, 네이티브 앱에 "웹" 종류를 쓰지 말라는 정책이 있다 ([OAuth 정책](https://developers.google.com/identity/protocols/oauth2/policies)).

**되돌림 URL.** 뒤집은 클라이언트 ID 스킴 `com.googleusercontent.apps.<id>:/oauth2redirect`. native-app 문서에 "Custom URI schemes are no longer supported due to the risk of app impersonation" 라는 경고가 있으나 구체 문장은 **Android·Chrome 앱**을 가리키고, Google Sign-In iOS 설정 문서는 지금도 `CFBundleURLTypes` 에 뒤집은 클라이언트 ID 스킴을 넣으라고 한다 ([start-integrating](https://developers.google.com/identity/sign-in/ios/start-integrating)). 즉 **iOS 클라이언트는 이 스킴을 그대로 쓴다**고 보되, SDK 없이 쓸 때도 거부되지 않는지는 PoC 1단계에서 확인(미확인). → **인증 요청까지는 확인(2026-11-01, §7)**: 이 스킴의 `redirect_uri` 로 보낸 요청에 Google 이 오류 없이 계정 입력 화면을 띄움. 토큰 교환은 실제 계정 연결 때 확인. 루프백(`127.0.0.1`) 은 iOS 에서 지원 중단 ([native-app](https://developers.google.com/identity/protocols/oauth2/native-app)).

**브라우저.** 내장 웹뷰(WKWebView) 는 `disallowed_useragent` 로 차단된다. Google 이 권하는 iOS 라이브러리는 Google Sign-In 과 **AppAuth-iOS** 인데, AppAuth-iOS 가 하는 일이 바로 `ASWebAuthenticationSession` + PKCE 이므로 ([AppAuth-iOS](https://github.com/openid/AppAuth-iOS), Apache-2.0, iOS 15+) 같은 방식을 직접 쓰는 것은 정책상 문제없다. `ASWebAuthenticationSession` 은 `presentationContextProvider` 가 필요하고 전경에서만 시작할 수 있으며, `prefersEphemeralWebBrowserSession = true` 면 Safari 쿠키를 공유하지 않는다(빙수처럼 "계정 고르기"를 매번 보여 주는 쪽이 안전) ([Apple 문서](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)). iOS 17.4+ 는 `.https(host:path:)` 콜백도 되지만 Google iOS 클라이언트가 https 되돌림을 받는지는 미확인 → 스킴 방식 유지.

**PKCE.** `code_verifier` 43~128자, `code_challenge = base64url(SHA256(verifier))`, `code_challenge_method=S256`. 토큰 엔드포인트 `POST https://oauth2.googleapis.com/token` 에 `client_id, code, code_verifier, grant_type=authorization_code, redirect_uri` ([native-app](https://developers.google.com/identity/protocols/oauth2/native-app)). CryptoKit 의 `SHA256` 로 충분.

**토큰.** 설치형 앱에는 갱신 토큰이 항상 나온다. 액세스 토큰은 응답의 `expires_in` 만큼만 유효(보통 1시간, 일반 지식). 갱신: `grant_type=refresh_token`(`client_secret` 없이). 갱신 토큰이 죽는 조건 ([oauth2#expiration](https://developers.google.com/identity/protocols/oauth2#expiration)):
- 사용자가 계정에서 접근 철회
- **6개월 미사용**
- **클라이언트당 계정당 갱신 토큰 100개** 초과 시 가장 오래된 것 무효(기기마다 하나씩이라 문제없음)
- **Testing 상태 프로젝트는 7일**(이름·이메일·프로필 범위만 쓰는 앱은 예외 — 우리는 `drive.appdata` 라 해당)
- 갱신 실패는 `invalid_grant` → 다시 로그인 유도
철회는 `https://oauth2.googleapis.com/revoke` (앱 안 "연결 해제" 버튼, 3.5 의 5.1.1(v) 요건).

**Keychain.** `PLAN.md` 8.2: 토큰은 Keychain 에만. 속성은 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 권장(백그라운드 올리기 때 읽을 수 있고, iCloud 키체인으로 다른 기기에 복사되지 않음 — 기기마다 자기 갱신 토큰을 받는 설계와 맞음). Google 정책도 "저장 시 암호화, 평문 전송 금지" ([OAuth 정책](https://developers.google.com/identity/protocols/oauth2/policies)).

**범위·동의 화면·검증.**
- `drive.appdata`(별칭 `drive.appfolder`) 와 `drive.file` 은 **비민감**, `drive`·`drive.readonly`·`drive.metadata.readonly` 는 **제한(restricted)** ([api-specific-auth](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)).
- 비민감 범위만 쓰면 앱 검증이 의무가 아니다. 동의 화면에 앱 이름·로고를 띄우려면 "브랜드 검증"(가벼운 절차) 이 필요하고, 없으면 도메인만 보인다 ([검증 FAQ](https://support.google.com/cloud/answer/13463073), [브랜딩 관리](https://support.google.com/cloud/answer/10311615)).
- 사용자 유형 External. **Testing**: 테스트 사용자 최대 100명, "확인되지 않은 앱" 경고, 승인 7일 뒤 만료. **In production**("Publish app"): 아무 Google 계정이나 가능. 미검증 경고가 뜨는 앱은 평생 100명 신규 사용자 제한 — 이 경고는 민감·제한 범위에 묶여 있어 비민감만 쓰면 뜨지 않는 것으로 읽히나 문서가 명시하지 않음(**미확인**, PoC 에서 Production 전환 뒤 실제 동의 화면으로 확인) ([앱 대상 관리](https://support.google.com/cloud/answer/15549945)).
- External production 앱은 홈페이지·개인정보 처리방침·서비스 약관 링크가 필수이고, 홈페이지는 **소유·확인한 도메인**에 있어야 하며 처리방침은 그 도메인에 두고 동의 화면과 같은 URL 을 쓰라고 한다 ([브랜딩 관리](https://support.google.com/cloud/answer/10311615)). 코드가 요청하는 범위와 동의 화면에 등록한 범위가 다르면 미검증 화면이 뜬다 ([검증 FAQ](https://support.google.com/cloud/answer/13461325)).
- Google API Services User Data Policy: 처리방침에 "Google 사용자 데이터를 어떻게 접근·사용·저장·공유하는지" 를 적고, 공개 전에 OAuth 클라이언트 설정에 URL 을 넣는다. Limited Use 조항은 민감·제한 범위에 적용 ([User Data Policy](https://developers.google.com/terms/api-services-user-data-policy)).

**필요한 호출.** (모두 `Authorization: Bearer`)
| 할 일 | 호출 |
|---|---|
| 목록 | `GET /drive/v3/files?spaces=appDataFolder&fields=files(id,name,size,md5Checksum,modifiedTime,version,appProperties)&pageSize=1000` 또는 `q='appDataFolder' in parents and name='save.json'` ([search](https://developers.google.com/workspace/drive/api/guides/search-files)) |
| 만들기 ≤5MB | `POST /upload/drive/v3/files?uploadType=multipart` (메타 `{name, parents:["appDataFolder"], appProperties, modifiedTime}` + 본문) |
| 만들기 >5MB | `POST /upload/drive/v3/files?uploadType=resumable` → 세션 URI 에 `PUT`(256KB 배수 조각, 세션 1주일 유효, 끊기면 `Content-Range: bytes */N` 으로 위치 조회 → 308) ([manage-uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads)) |
| 내려받기 | `GET /drive/v3/files/{id}?alt=media` ([appdata](https://developers.google.com/workspace/drive/api/guides/appdata)) |
| 덮어쓰기 | `PATCH /upload/drive/v3/files/{id}?uploadType=multipart|resumable` ([files.update](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/update)) |
| 지우기 | `DELETE /drive/v3/files/{id}` (appDataFolder 파일은 휴지통 불가 → 바로 삭제) |
| 변경 감지 | `GET /drive/v3/changes/startPageToken` → `GET /drive/v3/changes?pageToken=…&spaces=appDataFolder&includeRemoved=true` ([changes.list](https://developers.google.com/workspace/drive/api/reference/rest/v3/changes/list)) |
| 용량 | `GET /drive/v3/about?fields=storageQuota` |

**오류 처리** ([handle-errors](https://developers.google.com/workspace/drive/api/guides/handle-errors)): 401 `authError` → 갱신, 실패면 재로그인 · 403 `storageQuotaExceeded` → `quotaFull` · 403 `userRateLimitExceeded`/`rateLimitExceeded`, 429, 5xx → 지수 백오프(`min(2^n + 난수(≤1s), 32~64s)`) · 404 → 파일 없음으로 처리.

### 3.2 (B) Google Sign-In iOS SDK + GoogleAPIClientForREST

- **배포:** SwiftPM(`https://github.com/google/GoogleSignIn-iOS`, 제품 `GoogleSignIn`·`GoogleSignInSwift`). CocoaPods 는 폐기 예정. 10.0.0 부터 AppAuth 3.0·GTMAppAuth 6.0 으로 올라가며 **iOS 15+**(빙수 배포 대상 iOS 26 이라 문제없음) ([릴리스 노트](https://developers.google.com/identity/sign-in/ios/release), [저장소](https://github.com/google/GoogleSignIn-iOS)).
- **Drive 호출:** [google-api-objectivec-client-for-rest](https://github.com/google/google-api-objectivec-client-for-rest)(Apache-2.0, SwiftPM 지원, GTMSessionFetcher 기반, Objective-C). `GIDGoogleUser.fetcherAuthorizer()` 로 인증자를 넘기거나, `refreshTokensIfNeeded` 뒤 `user.accessToken.tokenString` 을 직접 헤더에 넣어 REST 를 부를 수도 있다 ([api-access](https://developers.google.com/identity/sign-in/ios/api-access)). 추가 범위는 `addScopes(_:presenting:)`, 승인 여부는 `grantedScopes`.
- **설정:** Info.plist `GIDClientID` + `CFBundleURLTypes` 에 뒤집은 클라이언트 ID. Keychain 에 자격 증명을 두려면 Apple 발급 인증서로 서명돼 있어야 함 ([start-integrating](https://developers.google.com/identity/sign-in/ios/start-integrating)).
- **라이선스:** GoogleSignIn·AppAuth·GTMAppAuth·GTMSessionFetcher·GoogleAPIClientForREST 모두 Apache-2.0. ASF 는 "GPLv3 는 Apache 2.0 코드를 받아들인다"(단방향: Apache 프로젝트가 GPL 코드를 넣는 건 불가) ([ASF GPL 호환성](https://www.apache.org/licenses/GPL-compatibility.html)). GPLv3 로 배포하는 빙수에 넣어도 된다. `THIRD_PARTY_LICENSES.md` 에 5건 추가.
- **개인정보 매니페스트:** GoogleSignIn 은 7.1.0 에서 PrivacyInfo 추가 ([릴리스 노트](https://developers.google.com/identity/sign-in/ios/release)). GoogleSignIn·GTMAppAuth·GTMSessionFetcher·AppAuth 는 Apple 의 [서드파티 SDK 요구 목록](https://developer.apple.com/support/third-party-SDK-requirements/)에 있어 **매니페스트 필수**, 서명은 바이너리 의존일 때만(SwiftPM 소스 빌드는 서명 대상 아님). AppAuth·GTMSessionFetcher 의 매니페스트 포함 여부는 **미확인**(패키지 안 `PrivacyInfo.xcprivacy` 유무로 확인).
- **크기:** 공식 수치 없음(**미확인**). 직접 재려면 SDK 유무로 아카이브 크기 비교.
- **평가:** 얻는 것은 토큰 저장·갱신·세션 복원뿐. 비용은 Objective-C 의존성 5개, 매니페스트 점검, 생성 코드가 Drive 전체 API 를 포함. 빙수 코드베이스가 "의존성은 버전 고정 + 라이선스 표기"(8.2) 를 지키고 있어 넣을 수는 있지만 A 의 인증 코드는 200~300줄 수준이라 득이 작다.

### 3.3 (C) Files 앱의 Google Drive File Provider

- **폴더 선택 불가.** Apple 문서는 "iOS 13 부터 어느 파일 제공자에서든 디렉터리를 고를 수 있다"고 하지만([Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)), 실제로는 `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])` 에서 **Google Drive·Dropbox·Box·OneDrive 가 모두 회색**이고 Secure ShellFish 같은 일부만 된다는 보고가 반복된다. DTS 엔지니어가 "working as designed 답변을 보낸 적 없다"며 버그(FB9703910) 추적을 언급했으나 해결 소식은 없다(2021-10, iOS 13~15) ([포럼 691738](https://developer.apple.com/forums/thread/691738), [포럼 120257](https://developer.apple.com/forums/thread/120257)). iOS 16 부터 `NSFileProviderReplicatedExtension` 제공자는 폴더 선택이 가능하다는 답변이 있으나 Google Drive 가 이를 쓰는지는 **미확인**. 2024~25년 다른 앱(Mindwtr 이슈 #210) 도 같은 회색 현상을 보고 ([GitHub](https://github.com/dongdongbh/Mindwtr/issues/210)). **iOS 26 에서 재확인 미확인** — 확인은 시뮬레이터가 아니라 Drive 앱을 깐 실기기에서만 가능.
- **파일 단위는 된다.** 파일 하나를 고르면 그 파일에만 security-scoped 접근이 생기고 폴더는 못 본다. 북마크는 `url.bookmarkData()`(iOS 에는 `withSecurityScope` 옵션이 없음) 로 저장, 해석 때 `isStale` 이면 다시 만들고 실패하면 다시 고르게 해야 한다. iOS 업데이트 때 북마크가 강제 만료된 사례도 있다 ([포럼 657988](https://developer.apple.com/forums/thread/657988), [포럼 797469](https://developer.apple.com/forums/thread/797469)).
- **제약:** 제공자가 로컬 사본을 지우면 다시 내려받아야 하고(전경·네트워크 필요), 앱이 전경일 때만 안전하게 쓸 수 있으며, Google Drive 앱이 설치·로그인돼 있어야 한다. Dropbox 도 Files 통합에 오프라인 접근 등 기능 빠짐을 공식 인정 ([Dropbox 도움말](https://help.dropbox.com/ko-kr/integrations/ios-files-app)).
- **결론:** 자동 동기화 어댑터로는 부적합. 다만 사용자가 백업 JSON 을 Drive 폴더에 **직접** 저장·불러오는 건 지금 `fileExporter`/`fileImporter` 로 이미 되므로(`UIFileSharingEnabled: false` 와 무관) "수동 Drive 백업" 요구는 추가 작업 없이 안내 문구로 해결된다.

### 3.4 Dropbox (짧게)

- **API:** 코드 플로 + PKCE(시크릿 못 지키는 앱용), `token_access_type=offline` 으로 갱신 토큰, 액세스 토큰은 짧은 수명(정확한 길이는 응답 `expires_in`; 문서는 숫자를 안 적음). 되돌림 URI 는 App Console 에 정확히 등록 ([Dropbox OAuth 가이드](https://docs.dropboxapi.com/dropbox-api/docs/oauth)). App folder 권한은 `Apps/<앱 이름>/` 안만 읽고 쓴다 ([개발자 가이드](https://docs.dropboxapi.com/dropbox-api/docs/developer-resources/developer-guide)). 세부 범위 이름(`files.content.write` 등) 은 엔드포인트별 문서에 있음(미확인 — 콘솔 Permissions 탭에서 체크).
- **상태:** Development 는 총 500명까지 연결 가능하되 **50명을 넘기면 2주 안에 Production 신청**해야 하고, 50명 전에는 보통 심사하지 않음. 승인 뒤 앱 이름 변경 불가. 무료 ([개발자 가이드](https://docs.dropboxapi.com/dropbox-api/docs/developer-resources/developer-guide)).
- **파일:** `files/upload` 한 요청 150MB(초과 시 `payload_too_large`), `content_hash` 불일치 오류 있음 ([SDK 문서](https://dropbox.github.io/dropbox-sdk-obj-c/api-docs/latest/Enums/DBFILESUploadSessionAppendErrorTag.html)). 해시 알고리즘·`client_modified`·`rev`·`list_folder/longpoll`·429 처리는 [HTTP 레퍼런스](https://www.dropbox.com/developers/documentation/http/documentation)와 [content-hash 문서](https://docs.dropboxapi.com/dropbox-api/docs/technical-reference/content-hash)에서 구현 때 확인(이번 조사에서 본문을 못 읽음, 미확인).
- **SDK:** [SwiftyDropbox](https://github.com/dropbox/swiftydropbox) MIT, SwiftPM, iOS 12+, PKCE 코드 플로와 토큰 갱신 내장. 의존성이 가벼워 Dropbox 는 SDK 를 써도 부담이 작다.
- **Files 앱:** Dropbox 제공자도 폴더 선택 회색(3.3 과 같은 포럼). 부적합.
- **PC 공유:** 앱 폴더가 사용자에게 보이므로 Windows Dropbox 클라이언트로 그대로 내려온다 — `PLAN.md` 3.4 표의 "PC 공유 가능" 은 Dropbox 쪽이 맞고, Drive 는 `drive.appdata` 면 불가.

### 3.5 App Store 심사·정책

- **4.8 로그인 서비스.** 조건은 "서드파티 로그인으로 **앱의 주 계정(primary account)** 을 만들거나 인증할 때". 빙수에는 계정이 없고 Google 연결은 저장소 접근일 뿐이므로 해당하지 않는다. 예외 조항에도 "특정 서드파티 서비스의 클라이언트로, 사용자가 자기 콘텐츠에 접근하려고 그 계정에 직접 로그인하는 앱"이 있다 ([가이드라인 4.8](https://developer.apple.com/app-store/review/guidelines/#login-services)). 심사관이 오해해 4.8 로 거절하는 사례는 있으므로([포럼 711724](https://developer.apple.com/forums/thread/711724)) **심사 메모에 "Google 계정 연결은 로그인이 아니라 사용자의 Drive 에 저장 데이터를 두기 위한 선택 기능이며, 앱 계정·회원가입이 없다"** 를 미리 적는다. 화면 문구도 "로그인" 대신 "Google Drive 연결" 로.
- **5.1.1(v) 계정 로그인.** "소셜 네트워크 자격 증명을 철회하고 데이터 접근을 끊는 장치를 앱 안에 둘 것, 토큰은 기기 밖에 저장하지 말 것, 앱이 쓰는 동안 직접 연결에만 쓸 것" → 앱 안 **"연결 해제"**(Keychain 삭제 + revoke 호출), 토큰은 Keychain(기기 전용) 에만. 지금 설계와 맞는다.
- **개인정보 처리방침(`docs/beta/privacy.html`).** 3절 옆에 "Google Drive 동기화" 절 추가: 사용자가 직접 연결을 켤 때만, 이용자 본인 Google 계정의 숨은 앱 전용 공간에 저장 데이터·게임별 설정·표지가 복사되고, 개발자는 볼 수 없으며, Google 이 보관하고 Google 개인정보 처리방침을 따른다는 것, 토큰은 기기 안에만, 연결 해제 방법, Drive 설정 › 앱 관리에서 사용자가 직접 지울 수 있음. Google 쪽 요건(접근·사용·저장·공유 명시, 공개 URL) 도 이 문구로 충족 ([User Data Policy](https://developers.google.com/terms/api-services-user-data-policy)). App Store "앱 개인정보" 라벨은 개발자가 수집하는 데이터가 없으므로 그대로 "수집 안 함"으로 볼 수 있다(판단, Apple 정의상 사용자 본인 계정으로 보내는 것은 개발자 수집이 아님 — 제출 때 정의 재확인).
- **네트워크 권한.** iOS 에는 인터넷 접근 권한 항목이 없고, HTTPS 만 쓰므로 ATS 예외도 필요 없다(8.2 "ATS 예외를 두지 않는다" 유지). `NSLocalNetworkUsageDescription` 과는 무관.
- **수출 규정.** `ITSAppUsesNonExemptEncryption: false` 그대로. OAuth 는 HTTPS 위에서 도는 표준 TLS 이고 Keychain 은 OS 암호화라 면제 범주를 벗어나지 않는다 ([Apple 문서](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations) — 페이지 본문은 못 읽어 일반 지식으로 정리, 변경 없음으로 판단).
- **개인정보 매니페스트(앱 자체).** 빙수에 `PrivacyInfo.xcprivacy` 가 없다(`find` 로 확인). `UserDefaults`(`@AppStorage`) 를 이미 쓰므로 Drive 와 무관하게 "필요 사유 API" 신고가 필요할 수 있음 — **후속 과제**로 분리(이 조사 범위 밖).

### 3.6 동기화 설계에 필요한 사실

| 주제 | 사실 | 출처 |
|---|---|---|
| appDataFolder 성격 | 앱 전용 숨은 폴더. 사용자가 Drive UI 로 볼 수 없고 다른 앱도 못 본다. 공유·공간 이동·휴지통 불가(`notSupportedForAppDataFolderFiles`). 사용자가 Drive 에서 앱을 제거하면 폴더가 지워진다 | [appdata](https://developers.google.com/workspace/drive/api/guides/appdata) |
| 사용자 관리 | Drive(웹) 설정 › 앱 관리에서 앱별 숨은 데이터 **크기 확인·삭제·연결 해제** 가능, 내용은 못 봄 | 서드파티 가이드 다수(예: [Daylio FAQ](https://daylio.net/faq/?p=62)); Google 도움말 원문 미확인 |
| 용량 한도 | 사용자 Drive 용량(무료 15GB) 을 쓴다고 보는 게 안전. `about.storageQuota.usage`(모든 서비스 합) 과 `usageInDrive` 가 따로 있어 appData 가 어느 쪽에 잡히는지 **미확인** → PoC 에서 파일 올린 뒤 `about.get` 으로 확인 | [about](https://developers.google.com/drive/api/reference/rest/v3/about) |
| 파일 수 한도 | 폴더당 직계 50만 개, 계정당 생성 항목 5억 개 | [Drive 한도](https://support.google.com/a/answer/2490100) |
| 요청 할당량 | 프로젝트당 분당 1,000,000 단위, 사용자당 분당 325,000 단위, 프로젝트당 하루 1TB 송출. 초과 시 403/429 → 지수 백오프 | [limits](https://developers.google.com/workspace/drive/api/guides/limits) |
| 업로드 종류 | ≤5MB simple/multipart, >5MB resumable(256KB 배수 조각, 세션 URI 1주일). 최대 5,120GB | [manage-uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads), [files.update](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/update) |
| 메타데이터 | `appProperties`: 키+값 합쳐 124바이트/개, 앱당 파일당 30개, API 키로는 못 읽고 OAuth 토큰으로만. `q` 로 검색 가능(`appProperties has { key='device' and value='iPad' }`) | [properties](https://developers.google.com/workspace/drive/api/guides/properties), [search](https://developers.google.com/workspace/drive/api/guides/search-files) |
| 시각 | `modifiedTime` 은 쓰기 가능(설정하면 `modifiedByMeTime` 도 갱신), `createdTime`·`version`·`headRevisionId`·`md5Checksum`·`sha256Checksum` 은 출력 전용. `version` 은 서버 쪽 변경마다 단조 증가 | [files](https://developers.google.com/workspace/drive/api/reference/rest/v3/files) |
| 변경 감지 | `changes.getStartPageToken` → `changes.list(pageToken, spaces=appDataFolder, includeRemoved=true)`. 토큰은 만료되지 않음. 변경 항목은 `fileId`·`time`·`removed`·`file` | [changes.list](https://developers.google.com/workspace/drive/api/reference/rest/v3/changes/list), [changes](https://developers.google.com/workspace/drive/api/reference/rest/v3/changes) |
| 조건부 쓰기 | v3 `files.update` 에 `If-Match`/etag 전제 조건이 **문서화돼 있지 않다**(v3 File 리소스에 etag 필드 없음). 서드파티 구현은 v2 etag 로 우회 | [files.update](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/update), [gogcli PR](https://github.com/openclaw/gogcli/pull/929) |
| 폴더 | appDataFolder 아래 하위 폴더를 만들 수 있다는 사례가 흔하지만 공식 문서에서 명시를 못 찾음(**미확인**). 구현은 평평한 배치라 이 문제를 피함(§7) | — |

**설계에 반영할 것**

1. **경로 ↔ 파일 ID.** Igloo 는 상대 경로(`Saves/<게임>/save.json`) 로 말한다. Drive 는 ID 로 말한다. 권장: appDataFolder 에 **평평하게** 두고 `appProperties.path` 에 상대 경로를, `name` 에는 경로의 `/` 를 `__` 로 바꾼 이름을 둔다(하위 폴더 생성 여부 미확인 문제를 피하고, `files.list` 한 번(≤1000개) 으로 전체 목록을 얻는다). `appProperties` 에 `device`(≤40자)·`model`·`savedAt`·`uploadedAt` 을 넣으면 save.json 을 내려받지 않고도 ConflictView 카드를 채울 수 있다(124바이트/개 한도 안).
2. **내려받기 건너뛰기.** 로컬 파일의 MD5 를 `md5Checksum` 과 비교해 같으면 내려받지 않는다(16MB save.json 을 매번 받지 않게). `savedAt` 은 지금처럼 JSON 안 값이 기준이고 `appProperties.savedAt` 은 캐시.
3. **충돌 판정은 지금 규칙 유지(L/C/B).** `modifiedTime`·`version` 은 보조. v3 에 조건부 쓰기가 없으므로 **두 기기가 동시에 올리면 마지막 쓰기가 이긴다** — 완화: 올리기 직전 `files.get(fields=version,md5Checksum)` 로 C 가 B 와 여전히 같은지 확인하고, 다르면 올리지 않고 다음 reconcile 로 넘긴다(창은 남지만 Igloo 가 "덮어쓰지 않음" 원칙을 지키는 데 충분). 더 엄격히 하려면 `save.json` 을 덮어쓰지 않고 `save-<uploadedAt>-<device>.json` 으로 새로 만들고 읽을 때 최신 것을 고르는 append 전략(파일이 늘어나니 오래된 것 정리 필요).
4. **백엔드별 B.** `IglooState` 를 백엔드 키(`icloud`/`drive`) 로 나눈다. 한 기기에서 iCloud 와 Drive 를 **동시에** 켜면 3자 병합이 되므로, 1차는 **한 번에 하나만 활성**(설정에서 "iCloud / Google Drive / 끔" 고르기) 을 권한다.
5. **오프라인·토큰 만료.** 네트워크 없음 → 조용히 건너뛰고 상태 줄 "오프라인". 401 → 갱신 → `invalid_grant` 면 `availability = .signedOut` 로 바꾸고 상태 줄 "Google Drive 연결이 끊겼어요 · 다시 연결", 동기화는 중단(로컬은 그대로). 갱신 토큰 6개월 미사용 만료도 같은 길.
6. **여러 기기, 한 계정.** 기기마다 자기 갱신 토큰(클라이언트당 100개 한도 안). `changes.list` 토큰도 기기마다 보관. 두 기기가 동시에 첫 업로드를 하면 같은 이름 파일이 둘 생길 수 있다(Drive 는 이름 중복을 허용) → 목록에서 같은 `path` 가 둘이면 `savedAt` 큰 쪽을 C 로 쓰고 나머지는 `backups/` 로 내린 뒤 지운다.
7. **백그라운드.** 지금처럼 `beginBackgroundTask`(약 30초) 면 16MB 한 번 올리기는 보통 되지만, 안전하게 하려면 백그라운드 `URLSession`(`background(withIdentifier:)`) 로 resumable 업로드를 넘긴다. 1차 PoC 는 전경 + 기존 backgroundTask 로.
8. **검증 유지.** 내려받은 모든 것은 지금처럼 `Freezer.validate`·`safeFileName`·크기 상한을 거친다. `appProperties` 값도 신뢰하지 않는다(`IglooEngine.clean` 으로 40자 제한 등).

### 3.7 어댑터 프로토콜 초안 (iCloud·Drive 공통)

**원칙:** `IglooEngine` 의 판단 로직(reconcile/resolve/syncBackups/syncPrefs/syncCover) 은 손대지 않고, 선반(`IglooShelf`) 과 바깥 껍데기(`Igloo` 의 준비·상태·문구) 만 백엔드별로 나눈다. 엔진은 이미 `Igloo.queue`(직렬 utility 큐) 안에서 동기적으로 도니, Drive 선반은 **그 큐 안에서 네트워크 호출을 동기적으로 기다리는 래퍼**(`URLSession` + 세마포어 또는 `async` 를 큐 안에서 블로킹) 로 시작하면 엔진을 비동기로 고치지 않아도 된다. 나중에 엔진을 `async` 로 바꾸는 것은 별도 리팩터.

```swift
/// 선반 종류. state.json·토글 키·화면 문구의 키가 된다
enum IglooShelfKind: String { case icloud, drive /*, dropbox */ }

protocol IglooShelf {
    var kind: IglooShelfKind { get }
    /// 충돌 카드·토스트·상태 줄에 쓰는 이름 ("iCloud", "Google Drive") 과 SF 심볼 ("icloud", "externaldrive.badge.icloud" 등)
    var displayName: String { get }
    var symbolName: String { get }

    // 지금 다섯 함수 그대로 (동기, Igloo.queue 안에서만)
    func read(_ path: String, maxBytes: Int) throws -> Data?
    func write(_ path: String, _ data: Data, modified: Date?) throws
    func list(_ dir: String) -> [String]
    func modified(_ path: String) -> Date?
    func remove(_ path: String) throws

    // 새로 필요한 것
    /// 내려받기 전에 같은지 보려고. 모르면 nil (iCloud 는 nil 또는 로컬 계산)
    func checksum(_ path: String) -> String?
    /// 백엔드별 오류 분류: 용량 부족·인증 만료·오프라인·그 밖
    func classify(_ error: Error) -> IglooShelfError
    /// 변경 감지 토큰(있으면). iCloud 는 nil → 지금처럼 매번 비교
    func changesSince(_ token: String?) throws -> (changedPaths: [String]?, nextToken: String?)
}

enum IglooShelfError { case quotaFull, signedOut, offline, tooLarge, other }

/// 선반을 만들고 계정 상태를 말해 주는 쪽 (Igloo.makeEngine 이 이것을 부른다)
protocol IglooShelfProvider {
    var kind: IglooShelfKind { get }
    func availability() async -> Igloo.Availability      // .ready / .noAccount(signedOut) / .unavailable / .offline
    func makeShelf() async -> IglooShelf?
    // Drive 전용 (iCloud 는 no-op): 연결·해제
    func connect(presenting: ASPresentationAnchor) async throws
    func disconnect() async                               // Keychain 삭제 + revoke
    var accountLabel: String? { get }                     // "rhe…@gmail.com" 같은 표시(선택, 토큰에 email 범위를 안 넣으면 nil)
}
```

**Igloo 쪽 변경 (코드 아닌 목록):**
- `Igloo.enabledKey` → `bingsu.syncBackend` (`off`/`icloud`/`drive`). 기존 `bingsu.icloudSync` true/false 는 첫 실행에 이전.
- `IglooState.load(kind:)` 로 백엔드별 파일(`Igloo/state-icloud.json`, `state-drive.json`). 백엔드를 바꾸면 B 가 없으니 첫 동기화에서 "둘이 다르면 충돌" 규칙이 그대로 작동한다(안전).
- `IglooEngine.isOutOfSpace(error)` → `shelf.classify(error) == .quotaFull`.
- `Igloo.statusText` 문구에 `shelf.displayName` 과 `.signedOut`/`.offline` 추가.
- `ConflictView`: `card(title: conflict.shelfName, systemImage: conflict.shelfSymbol)`, 안내문 "이 기기와 \(shelfName) 에 서로 다른 저장 데이터가 있어요". `IglooConflict` 에 `shelfName`·`shelfSymbol` 두 필드 추가.
- `FreezerSection`·설정 화면: "iCloud 동기화" → "클라우드 동기화" 행 + 백엔드 고르기 + Drive 면 "Google 계정 연결/해제" 버튼과 계정 표시.
- `SavedDataView` 삭제 문구: "이 기기와 \(shelfName) 에서…".
- `DriveShelf` 내부: 시작 때 `files.list(spaces=appDataFolder, fields=…)` 한 번으로 `path → (id, md5, modifiedTime, size)` 캐시를 만들고 `list/modified/checksum` 은 캐시로 답한다. `write` 는 캐시에 id 가 있으면 PATCH, 없으면 POST(응답 id 를 캐시에). `remove("Saves/<폴더>")` 는 접두사 매칭으로 여러 파일 DELETE.
- 네이밍: 선반 이름은 빙수 관례대로 `DriveShelf`(또는 "선반" 계열 한글 주석), 인증 부분은 `Freezer/DriveTicket.swift` 같은 식으로(최종 이름은 구현 세션에서).

---

## 4. 권장안과 PoC 순서

### 4.1 권장: (A) REST 직접 + `drive.appdata` + ASWebAuthenticationSession/PKCE

이유:
1. **빙수 보안 원칙과 그대로 맞는다.** 시크릿 없는 공개 클라이언트, 앱 폴더 범위 최소화, 토큰은 Keychain(8.1·8.2). 의존성 0 이라 `THIRD_PARTY_LICENSES`·매니페스트·크기 걱정이 없다.
2. **검증 부담이 없다.** 비민감 범위라 OAuth 앱 검증 의무 없음. 필요한 건 Production 전환 + 처리방침 URL.
3. **Igloo 재사용률이 높다.** 필요한 Drive 호출이 5~7개뿐이고, 선반 인터페이스가 작아 엔진 로직을 그대로 쓴다. B 로 가도 선반 구현량은 같다.

**결정 포인트(사용자):** `PLAN.md` 3.4 표가 Google Drive 의 장점으로 "PC(Windows)와도 공유 가능"을 들었는데, `drive.appdata` 는 사용자에게 **보이지 않아** PC 에서 쓸 수 없다. PC 공유가 목표면 `drive.file`(역시 비민감) 로 `내 드라이브/Bingsu/Saves/…` 에 보이는 파일을 만들어야 한다. 차이: 사용자가 Drive 웹·PC 에서 파일을 지우거나 바꿀 수 있으므로 검증(`Freezer.validate`) 이 더 중요해지고, 폴더 ID 탐색이 한 단계 늘며, 모바일에서는 Google Picker 를 못 써 "앱이 만든 파일"만 보인다(다른 설치가 같은 OAuth 클라이언트로 만든 파일을 볼 수 있는지는 **미확인** — `drive.file` 의 "앱" 단위가 프로젝트인지 확인 필요). 권장은 **1차 appdata, PC 공유는 Dropbox(앱 폴더가 보임) 로 해결**. 이 결정은 PoC 2단계 전에 하면 된다.

### 4.2 PoC 순서 (반나절 단위)

| 단계 | 할 일 | 끝 조건 |
|---|---|---|
| 0 (개발자, 콘솔) | 5장 목록대로 프로젝트·동의 화면(Testing)·iOS 클라이언트 만들기, 테스트 사용자에 본인 계정 추가 | 클라이언트 ID 확보(저장소에는 넣지 않음) |
| 1 | 빈 iOS 프로젝트(또는 빙수 DEBUG 전용 화면) 에서 `ASWebAuthenticationSession` + PKCE 로 동의 화면 → 코드 → 토큰 교환. 클라이언트 ID 는 `Secrets.xcconfig` → Info.plist `BINGSU_GOOGLE_CLIENT_ID` + URL 스킴 | 액세스·갱신 토큰을 받아 Keychain 에 저장, 앱 재시작 뒤 갱신 성공 |
| 2 | `files.create(multipart)` 로 appDataFolder 에 `hello.json`, `files.list(spaces=appDataFolder)`, `files.get?alt=media`, `files.update`, `files.delete`. `about.get` 으로 용량 변화 확인(3.6 미확인 해소) | 5개 호출 성공, 두 번째 기기(또는 시뮬레이터 2대) 에서 같은 파일 보임 |
| 3 | 6MB 넘는 파일로 resumable 업로드 + 중간에 끊고 재개 | 308 → 이어서 200 |
| 4 | `IglooShelf` 확장(3.7) + `DriveShelf`(목록 캐시, path↔id) + `IglooShelfProvider`. `BINGSU_FAKE_ICLOUD` 처럼 `BINGSU_FAKE_DRIVE=<폴더>` 가짜 선반도 만들어 시뮬레이터 검증 | 시뮬레이터 2대 가짜 폴더로 Phase 2 iCloud 검증 시나리오 재현(첫 업로드·내려받기·충돌·거부) |
| 5 | 실제 Drive 로 iPhone ↔ iPad 레조넌스 이어하기, 토큰 만료·오프라인·용량 부족 분기, `changes.list` 로 "지금 동기화" 비용 줄이기 | TestFlight 빌드 1개 |
| 6 | 화면(백엔드 고르기·연결/해제·상태 줄·ConflictView 이름), 처리방침 절 추가, 동의 화면 Production 전환, 심사 메모 | 외부 베타 |

### 4.3 막힐 위험이 큰 지점

1. **도메인.** Production 동의 화면은 소유·확인한 도메인의 홈페이지·처리방침·약관 URL 을 요구한다. 지금 처리방침은 claude.ai Artifact. GitHub Pages(`<user>.github.io`) 가 "소유 도메인"으로 인정되는지 **미확인** → 값싼 도메인 하나를 사서 README·처리방침·약관을 두는 것이 가장 확실. 이게 없으면 Testing(7일 토큰·100명) 에 머문다.
2. **Testing 상태의 7일 만료.** 외부 베타 기간에 Production 으로 못 가면 테스터가 7일마다 다시 연결해야 한다. 상태 줄과 "다시 연결" 흐름을 처음부터 만든다.
3. **커스텀 스킴 되돌림.** SDK 없이 `ASWebAuthenticationSession` 으로 뒤집은 클라이언트 ID 스킴이 거부되면(native-app 문서의 경고 문구) AppAuth-iOS(Apache-2.0, 의존성 1개) 로 대체. 1단계에서 바로 드러난다.
4. **appDataFolder 가 사용자 용량을 쓰는지.** 쓴다면(가능성 높음) 15GB 무료 사용자에게 백업 합집합이 쌓이지 않게 **백업 보존 개수 규칙**(`PLAN.md` "백업·옛 표지 정리 규칙" 미완) 을 Drive 와 함께 넣어야 한다.
5. **동시 쓰기 경합.** v3 에 조건부 쓰기가 없다. 3.6-3 의 "올리기 직전 재확인" 으로 창을 줄이되, 두 기기에서 동시에 종료하는 시나리오를 5단계에서 일부러 재현한다.
6. **4.8 오해 거절.** 심사 메모로 선제 설명(3.5).

---

## 5. 개발자(사용자) 가 Google Cloud 콘솔에서 직접 할 일

1. [console.cloud.google.com](https://console.cloud.google.com) 에서 새 프로젝트(예: `bingsu`). 정책상 개발·프로덕션 프로젝트를 나누라고 하므로 PoC 는 `bingsu-dev`, 출시는 `bingsu` 로 둘 다 만들어도 된다.
2. **API 및 서비스 › 라이브러리** 에서 **Google Drive API** 사용 설정.
3. **Google Auth Platform › Branding**(옛 OAuth 동의 화면): 앱 이름 "빙수", 지원 이메일, (나중에) 홈페이지·처리방침·약관 URL, 승인된 도메인. 로고는 넣지 않는다(넣으면 브랜드 검증 절차가 생김).
4. **Audience**: 사용자 유형 External, 상태 Testing, 테스트 사용자에 본인 Google 계정(과 테스터 계정) 추가. 출시 직전에 "Publish app".
5. **Data Access**(범위): `https://www.googleapis.com/auth/drive.appdata` 하나만 추가(비민감으로 표시되는지 확인). 코드가 요청하는 범위와 반드시 일치.
6. **Clients**: 유형 **iOS**, 이름, 번들 ID `com.minwoo.bingsu`, Team ID(선택), App Store ID(출시 뒤). 생성된 클라이언트 ID 를 `BingsuApp/Secrets.xcconfig`(gitignore) 에 `BINGSU_GOOGLE_CLIENT_ID=…` 로, 템플릿 `Secrets.example.xcconfig` 에는 빈 값. 뒤집은 스킴(`com.googleusercontent.apps.<id>`) 도 같은 파일에서 파생.
7. 출시 전: Production 전환 → 실제 동의 화면에 미검증 경고가 없는지 확인 → (원하면) Verify Branding.
8. 외부 베타 안내문(`docs/beta/guide.md`) 에 "Google Drive 연결은 선택, 7일마다 다시 연결(Testing 동안)" 문구.

Dropbox 를 할 때: [App Console](https://www.dropbox.com/developers/apps) 에서 Scoped access · **App folder** · 이름 "Bingsu" → Permissions 에서 파일 읽기·쓰기 범위 체크 → Redirect URI 등록 → App key 를 같은 `Secrets.xcconfig` 에. 50명 넘기 전 Production 신청.

---

## 6. 참고 링크

**읽은 파일**
- `BingsuApp/Bingsu/Freezer/Igloo.swift`, `Freezer/Freezer.swift`, `Kitchen/ConflictView.swift`, `Kitchen/FreezerSection.swift`, `Kitchen/SavedDataView.swift`
- `PLAN.md` 3.4 · Phase 2 iCloud 항목 · 8장, `BingsuApp/project.yml`, `BingsuApp/Bingsu/Bingsu.entitlements`, `docs/beta/privacy.html`, `THIRD_PARTY_LICENSES.md`

**Google Drive API**
- 앱 데이터 폴더: https://developers.google.com/workspace/drive/api/guides/appdata
- 범위 분류: https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- 사용 한도: https://developers.google.com/workspace/drive/api/guides/limits
- 업로드(simple/multipart/resumable): https://developers.google.com/workspace/drive/api/guides/manage-uploads
- 사용자 지정 속성(appProperties): https://developers.google.com/workspace/drive/api/guides/properties
- 검색 쿼리: https://developers.google.com/workspace/drive/api/guides/search-files
- 변경 감지: https://developers.google.com/workspace/drive/api/guides/manage-changes , https://developers.google.com/workspace/drive/api/reference/rest/v3/changes/list , https://developers.google.com/workspace/drive/api/reference/rest/v3/changes
- File 리소스: https://developers.google.com/workspace/drive/api/reference/rest/v3/files , files.update: https://developers.google.com/workspace/drive/api/reference/rest/v3/files/update , about: https://developers.google.com/drive/api/reference/rest/v3/about
- 오류 처리: https://developers.google.com/workspace/drive/api/guides/handle-errors
- Picker(모바일은 `drive.file` 단독만): https://developers.google.com/workspace/drive/picker
- Drive 항목 한도: https://support.google.com/a/answer/2490100

**Google OAuth**
- 네이티브 앱 OAuth(PKCE, 토큰, 되돌림): https://developers.google.com/identity/protocols/oauth2/native-app
- iOS 클라이언트 만들기(번들 ID·Team ID·App Store ID): https://developers.google.com/accounts/docs/OAuth2InstalledApp
- 토큰 만료 조건: https://developers.google.com/identity/protocols/oauth2#expiration
- OAuth 정책: https://developers.google.com/identity/protocols/oauth2/policies
- User Data Policy: https://developers.google.com/terms/api-services-user-data-policy
- 검증 FAQ(비민감은 검증 불필요, 브랜드 검증): https://support.google.com/cloud/answer/13463073
- 앱 대상 관리(Testing 100명·7일, Production): https://support.google.com/cloud/answer/15549945
- 브랜딩(홈페이지·처리방침·도메인 요건): https://support.google.com/cloud/answer/10311615
- 검증 제출(범위 불일치 경고): https://support.google.com/cloud/answer/13461325

**Google SDK**
- GoogleSignIn-iOS: https://github.com/google/GoogleSignIn-iOS , 릴리스 노트: https://developers.google.com/identity/sign-in/ios/release
- 설정·범위·토큰: https://developers.google.com/identity/sign-in/ios/start-integrating , https://developers.google.com/identity/sign-in/ios/api-access
- GoogleAPIClientForREST: https://github.com/google/google-api-objectivec-client-for-rest
- AppAuth-iOS: https://github.com/openid/AppAuth-iOS
- Apache-2.0 ↔ GPLv3: https://www.apache.org/licenses/GPL-compatibility.html

**Apple**
- 가이드라인 4.8·5.1.1: https://developer.apple.com/app-store/review/guidelines/
- 서드파티 SDK 요구(매니페스트·서명 목록): https://developer.apple.com/support/third-party-SDK-requirements/
- 수출 규정: https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations
- ASWebAuthenticationSession: https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession
- 디렉터리 접근(문서 선택기·북마크): https://developer.apple.com/documentation/uikit/providing-access-to-directories
- 서드파티 제공자 폴더 선택 불가 보고: https://developer.apple.com/forums/thread/691738 , https://developer.apple.com/forums/thread/120257 , 북마크 만료: https://developer.apple.com/forums/thread/657988 , iOS 북마크 모델: https://developer.apple.com/forums/thread/797469
- 4.8 오해 거절 사례: https://developer.apple.com/forums/thread/711724

**Dropbox**
- 개발자 가이드(App folder, Development/Production, 50명): https://docs.dropboxapi.com/dropbox-api/docs/developer-resources/developer-guide
- OAuth 가이드(PKCE, offline): https://docs.dropboxapi.com/dropbox-api/docs/oauth
- HTTP 레퍼런스: https://www.dropbox.com/developers/documentation/http/documentation , content_hash: https://docs.dropboxapi.com/dropbox-api/docs/technical-reference/content-hash
- SwiftyDropbox: https://github.com/dropbox/swiftydropbox
- Files 앱 통합 한계: https://help.dropbox.com/ko-kr/integrations/ios-files-app

## 7. 구현 뒤 갱신 (2026-11-01, 빌드 25 구현 세션)

구현과 시뮬레이터 확인으로 알게 된 것. 실제 Google 계정은 연결하지 않았으므로(사용자 몫) 토큰·Drive 서버 동작에 관한 미확인은 그대로 둔다. 자세한 확인 결과는 [`IMPLEMENTATION.md`](IMPLEMENTATION.md) 끝.

| 항목(앞 절) | 결과 |
|---|---|
| 뒤집은 클라이언트 ID 스킴을 SDK 없이 써도 되나(§3.1) | **인증 요청은 통과.** 시뮬레이터에서 `ASWebAuthenticationSession`(ephemeral) 으로 `accounts.google.com/o/oauth2/v2/auth`(PKCE S256, `drive.appdata`, `redirect_uri=<스킴>:/oauth2redirect`) 를 열면 `redirect_uri`·클라이언트 오류 없이 "Google 계정으로 로그인 · 빙수(으)로 이동" 화면이 뜬다. 코드 → 토큰 교환과 갱신 토큰 발급은 **미확인**(계정 필요) |
| 스킴 등록·되돌림 수신 | `CFBundleURLTypes` 에 xcconfig 변수로 등록한 스킴을 `simctl openurl` 로 열면 iOS 가 "'빙수'에서 열겠습니까?" 를 묻고 앱이 받는다. 진행 중인 연결이 없을 때는 앱이 버린다(가져오기 경로와 섞이지 않음). 연결 중의 되돌림은 `ASWebAuthenticationSession` 이 받는 것을 흉내 서버로 끝까지 확인(PKCE·`state` 검사 포함) |
| 디버그 흉내 서버 `http://127.0.0.1` 과 ATS(§3.5 네트워크) | iOS 26 시뮬레이터에서 ATS 예외·`NSAllowsLocalNetworking`·`URLSessionDelegate` 없이 된다. 그래서 릴리스 Info.plist 는 그대로 |
| appDataFolder 하위 폴더(§3.6) | 평평한 배치(`Saves__<게임>__save.json` + `appProperties.path`) 로 구현해 확인할 필요가 없어짐. 여전히 **미확인** |
| appProperties 124바이트(§3.6) | 키+값 UTF-8 기준으로 잘라 넣음(`DriveShelf.fit`). 실제 Drive 가 거부하는 경계는 **미확인**(흉내 서버는 검사 안 함) |
| appData 용량이 `usage`/`usageInDrive` 어디에 잡히나(§3.6) | **미확인** (흉내 서버로는 알 수 없음). `DriveCounter.freeBytes()` 는 만들어 두었으나 화면에 쓰지 않음 |
| Production 전환 뒤 미검증 경고(§3.1 동의 화면) | **미확인** (Testing 상태 그대로) |
| Testing 7일 갱신 토큰 만료 | **미확인**. 만료 시 앱 동작(`invalid_grant` → 키체인 비움 → "Google Drive 연결이 끊겼어요 · 다시 연결해 주세요", 로컬 그대로, 다시 연결하면 밀린 올리기 이어서) 은 흉내 서버로 확인 |


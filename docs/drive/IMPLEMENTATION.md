# Google Drive 저장 데이터 동기화 — 구현 명세 (빌드 25)

2026-11-01 결정. 조사 문서 [`research.md`](research.md)(특히 §1.4·§3.6·§3.7·§4) 를 바탕으로 한다. 이 파일은 구현 세션(Opus, 워크트리)용 명세이고, 사용자 결정은 "**(A) Drive REST v3 직접 호출 + `drive.appdata` + `ASWebAuthenticationSession`/PKCE, SDK 없음**" 이다. 구현 중 명세와 다르게 해야 하면 이 파일 끝에 "구현 중 바뀐 것" 절로 적는다.

## 0. 원칙

- **엔진은 그대로, 선반만 바꾼다.** `IglooEngine` 의 판단 로직(reconcile/resolve/syncBackups/syncPrefs/syncCover) 은 손대지 않는다. `IglooShelf` 를 넓히고 `DriveShelf` 를 더하며, 바깥 껍데기(`Igloo` 의 준비·상태·문구) 를 백엔드별로 나눈다.
- **한 번에 하나.** 동기화 백엔드는 끔 / iCloud / Google Drive 중 하나만 활성. 예전 토글 `bingsu.icloudSync`(true/false) 는 첫 실행 때 `bingsu.syncBackend` 로 옮긴다(true → `icloud`, false → `off`).
- **클라우드는 믿지 않는다**(PLAN 8장): 내려받은 모든 것은 지금처럼 `Freezer.validate`·`safeFileName`·크기 상한을 거친다. `appProperties` 값도 `IglooEngine.clean` 으로 자른다.
- **비밀값은 저장소 밖.** OAuth 클라이언트 ID 는 `Keys/LOCAL_NOTES.md` 8행(사용자가 2026-11-01 콘솔에서 만들어 적어 둠, gitignore) 에서 읽어 **`BingsuApp/Secrets.xcconfig`(gitignore) 에만** 둔다. 로그·커밋·문서·채팅에 값을 쓰지 않는다. 클라이언트 ID 가 없어도 빌드는 되고 Drive 항목만 "준비 중"으로 숨긴다.
- 실제 Google 계정 로그인은 구현 세션이 할 수 없다(사용자 계정). 그래서 **가짜 선반**(`BINGSU_FAKE_DRIVE`) 과 **Drive API 흉내 서버**(`tools/drive-mock/`) 로 시뮬레이터에서 끝까지 검증하고, 실제 계정 연결은 사용자가 TestFlight 에서 한다.
- 화면 문구는 평범한 한국어("클라우드 동기화", "Google Drive 연결"). "로그인"이라는 말은 쓰지 않는다(심사 4.8 오해 방지, research §3.5). 코드 이름은 빙수 테마.

| 개념 | 화면 | 코드 |
|---|---|---|
| 선반 종류 | 끔 / iCloud / Google Drive | `IglooShelfKind` (`off`·`icloud`·`drive`) |
| Drive 선반 | — | `DriveShelf` (`Freezer/DriveShelf.swift`) |
| Drive 인증(토큰·PKCE·Keychain) | Google Drive 연결 | `DriveTicket` (`Freezer/DriveTicket.swift`) |
| Drive REST 호출 | — | `DriveCounter` (`Freezer/DriveCounter.swift`, "카운터 = 창구") |
| 선반 공급자(계정 상태·연결·해제) | — | `IglooShelfProvider` + `ICloudProvider`·`DriveProvider` |
| 가짜 Drive 선반(디버그) | — | `FakeDriveShelf` (`BINGSU_FAKE_DRIVE=<폴더>`) |

## 1. 선반 인터페이스 (`Freezer/Igloo.swift`)

research §3.7 초안 그대로, 이름만 확정:

```swift
enum IglooShelfKind: String, CaseIterable { case off, icloud, drive
    var label: String  // "끔" "iCloud" "Google Drive"
    var symbol: String // "" "icloud" "externaldrive.badge.icloud" (SF Symbols 에 없으면 "externaldrive")
}
enum IglooShelfError { case quotaFull, signedOut, offline, tooLarge, other }

protocol IglooShelf {
    var kind: IglooShelfKind { get }
    func read(_ path: String, maxBytes: Int) throws -> Data?
    func write(_ path: String, _ data: Data, modified: Date?) throws
    func list(_ dir: String) -> [String]
    func modified(_ path: String) -> Date?
    func remove(_ path: String) throws
    func checksum(_ path: String) -> String?          // MD5 16진, 모르면 nil
    func classify(_ error: Error) -> IglooShelfError
}
protocol IglooShelfProvider {
    var kind: IglooShelfKind { get }
    func availability() async -> Igloo.Availability   // .ready / .noAccount / .unavailable / .offline
    func makeShelf() async -> IglooShelf?
    func connect(anchor: ASPresentationAnchor) async throws   // iCloud 는 no-op
    func disconnect() async                                   // iCloud 는 no-op
    var accountLabel: String? { get }                         // Drive: 연결됨 표시용. 이메일은 받지 않으므로 "연결됨 · <연결한 날짜>" 로
}
```

- `ICloudShelf` 는 `checksum` 에서 로컬 파일 MD5 를 계산하거나 nil, `classify` 는 지금 `isOutOfSpace` 로직을 옮긴다.
- `Igloo.Availability` 에 `.offline` 추가. `statusText` 는 `shelf.kind.label` 을 써서 "Google Drive 연결이 끊겼어요 · 다시 연결", "오프라인 · 다음에 다시 맞춰요" 등.
- `IglooState.load(kind:)` → `Library/Application Support/Igloo/state-<kind>.json`. 기존 `state.json` 은 `state-icloud.json` 으로 한 번 옮긴다.
- `IglooConflict` 에 `shelfName`·`shelfSymbol` 추가 → `ConflictView` 카드 제목·아이콘·안내문("이 기기와 \(shelfName) 에 서로 다른 저장 데이터가 있어요"). `SavedDataView` 삭제 문구도 같은 이름.
- `IglooEngine.isOutOfSpace(error)` 호출을 `shelf.classify(error) == .quotaFull` 로. `.signedOut` 이면 그 동기화를 멈추고 `Igloo.availability = .noAccount` 로 바꾼다(로컬은 손대지 않음). `.offline` 은 조용히 건너뛰고 상태 줄만.
- 엔진은 지금처럼 `Igloo.queue` 안에서 동기적으로 돈다. `DriveShelf` 는 그 큐 안에서 `URLSession` 호출을 세마포어로 기다리는 동기 래퍼다(요청당 타임아웃 60초, resumable 업로드는 조각당). 엔진을 async 로 바꾸지 않는다.

## 2. `DriveTicket` — 인증 (`Freezer/DriveTicket.swift`)

- 클라이언트 ID: Info.plist `BINGSU_GOOGLE_CLIENT_ID`(xcconfig 변수) 를 읽는다. 비어 있으면 `DriveProvider.isConfigured == false` → 설정 화면에서 Drive 선택지를 "준비 중" 으로 비활성.
- 되돌림 스킴: 클라이언트 ID `<n>-<x>.apps.googleusercontent.com` → `com.googleusercontent.apps.<n>-<x>`. Info.plist `CFBundleURLTypes` 에 `$(BINGSU_GOOGLE_REVERSED_CLIENT_ID)` 로 등록(xcconfig 에서 둘 다 정의). `ASWebAuthenticationSession(url:callbackURLScheme: 그 스킴)` 에 `prefersEphemeralWebBrowserSession = true`.
- PKCE: `code_verifier` 64자(영숫자·`-._~`), `code_challenge = base64url(SHA256(verifier))`, `S256`. 인증 URL `https://accounts.google.com/o/oauth2/v2/auth` 에 `client_id, redirect_uri=<스킴>:/oauth2redirect, response_type=code, scope=https://www.googleapis.com/auth/drive.appdata, code_challenge, code_challenge_method, state(난수), access_type=offline, prompt=consent`. `state` 불일치는 거절.
- 토큰 교환·갱신: `POST https://oauth2.googleapis.com/token`(`client_secret` 없음). 응답의 `access_token`·`expires_in`·`refresh_token` 을 Keychain 에 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 로 저장(서비스 `com.minwoo.bingsu.drive`, 계정 `default`). 액세스 토큰은 만료 60초 전부터 갱신. 갱신이 `invalid_grant` 면 Keychain 을 비우고 `.signedOut`.
- 해제: `POST https://oauth2.googleapis.com/revoke?token=<refresh>` 시도(실패해도 진행) → Keychain 삭제 → `state-drive.json` 삭제. 화면 "Google Drive 연결 해제".
- 되돌림 URL 은 `ASWebAuthenticationSession` 이 받으므로 `onOpenURL` 쪽 변경은 없다(기존 zip·스킨 열기 경로와 섞이지 않게, 그 스킴은 `MenuBoardStore.pendingImport` 로 보내지 않는다).
- 디버그: `BINGSU_DRIVE_BASE_URL=<http://127.0.0.1:포트>`(흉내 서버; `BINGSU_ALLOW_HTTP=1` 과 함께만, 릴리스 빌드에서는 무시), `BINGSU_DRIVE_TOKEN=<문자열>`(흉내 서버용 고정 토큰, Keychain 생략).

## 3. `DriveCounter` — REST 호출 (`Freezer/DriveCounter.swift`)

모두 `Authorization: Bearer`, JSON. 기본 주소 `https://www.googleapis.com`, 업로드는 `/upload/drive/v3/files`.

| 함수 | 호출 |
|---|---|
| `listAll()` | `GET /drive/v3/files?spaces=appDataFolder&pageSize=1000&fields=nextPageToken,files(id,name,size,md5Checksum,modifiedTime,appProperties)` 페이지 끝까지 |
| `create(name, appProperties, data, modifiedTime)` | ≤5MB `uploadType=multipart`(메타 JSON + 본문), >5MB `uploadType=resumable` → 세션 URI 에 `PUT`(조각 4MB = 256KB 배수), 끊기면 `Content-Range: bytes */N` 으로 위치 조회 후 이어서 |
| `update(id, data, modifiedTime)` | `PATCH /upload/drive/v3/files/{id}?uploadType=multipart|resumable` |
| `download(id, maxBytes)` | `GET /drive/v3/files/{id}?alt=media`, `Content-Length` 또는 받은 양이 상한을 넘으면 끊고 `tooLarge` |
| `get(id)` | `GET /drive/v3/files/{id}?fields=id,version,md5Checksum,modifiedTime` (올리기 직전 재확인) |
| `delete(id)` | `DELETE /drive/v3/files/{id}` |
| `about()` | `GET /drive/v3/about?fields=storageQuota` (상태 줄 "Drive 남은 공간" 과 PoC 확인용) |

오류 분류(research §3.1 끝): 401 → 갱신 뒤 한 번 재시도, 실패면 `.signedOut`; 403 `storageQuotaExceeded` → `.quotaFull`; 403 `userRateLimitExceeded`·`rateLimitExceeded`·429·5xx → 지수 백오프(1·2·4·8초 + 난수 ≤1초, 최대 4회) 뒤 `.other`; `URLError.notConnectedToInternet`·`networkConnectionLost`·`timedOut` → `.offline`; 404 → 파일 없음(nil). `changes.list` 는 이번 빌드에서 쓰지 않는다(`listAll` 한 번이면 충분, 파일 수 ≤ 수백).

## 4. `DriveShelf` — 경로 ↔ 파일 (`Freezer/DriveShelf.swift`)

- appDataFolder 에 **평평하게** 둔다(하위 폴더 미확인 문제 회피). `name` 은 경로의 `/` 를 `__` 로 바꾼 것(`Saves__pokemon-resonance__save.json`), `appProperties.path` 에 원래 상대 경로, 그 밖에 `device`(≤40자)·`model`·`savedAt`·`uploadedAt`(각 124바이트 한도 안).
- 선반을 만들 때 `listAll()` 한 번으로 `path → (id, size, md5, modifiedTime)` 캐시. `list(dir)`·`modified`·`checksum` 은 캐시로 답한다. 같은 `path` 가 둘이면 `modifiedTime` 큰 쪽을 쓰고 나머지 id 는 `duplicates` 에 두었다가 그 경로를 성공적으로 맞춘 뒤 지운다(research §3.6-6).
- `read`: 캐시에 없으면 nil. 크기가 `maxBytes` 를 넘으면 내려받지 않고 `IglooError.tooLarge`. 로컬 파일의 MD5 가 `md5` 와 같으면 **엔진이 비교 전에 건너뛸 수 있게** `checksum` 으로 노출(엔진 수정 없이: `reconcile` 이 지금처럼 읽어도 되지만, `read` 안에서 "직전에 같은 md5 를 내려받은 적 있으면 디스크 캐시(`Library/Caches/Drive/<id>-<md5>`) 에서 돌려준다" 로 네트워크를 아낀다).
- `write`: 올리기 직전 `get(id)` 로 `md5` 가 캐시와 같은지 확인, 다르면 `IglooShelfError.other` 로 올리지 않고(다음 reconcile 이 충돌로 판단) 로그 `[Igloo] drive: 다른 기기가 먼저 올렸어요 · 다음에`. 캐시에 id 가 있으면 PATCH, 없으면 POST → 응답 id 를 캐시에.
- `remove(path)`: 경로 하나 또는 접두사(`Saves/<폴더>/`) 에 맞는 파일 전부 DELETE.
- **백업 상한(Drive 만):** `syncBackups` 뒤 클라우드의 `Saves/<게임>/backups/` 가 20개를 넘으면 오래된 것부터 클라우드에서만 지운다(로컬은 그대로). research §4.3-4 (사용자 Drive 용량을 씀). `[Igloo] drive: 백업 n개 정리` 로그.
- 모든 네트워크 호출은 `Igloo.queue` 안에서 동기 대기. `afterPlay` 의 `beginBackgroundTask`(약 30초) 안에 16MB 를 못 올리면 다음 `syncAll` 로 미룬다(지금 iCloud 와 같은 태도). 백그라운드 `URLSession` 은 이번 빌드에서 하지 않는다.

## 5. `Igloo` 껍데기와 화면

- `Igloo.backendKey = "bingsu.syncBackend"`(`IglooShelfKind.rawValue`). 첫 실행 이전: `bingsu.icloudSync` 가 있으면 true→`icloud`, false→`off`, 없으면 `icloud`(지금 기본과 같음).
- `Igloo.makeEngine` 은 `provider(for: kind)` → `availability()` → `makeShelf()`. `DriveProvider.availability`: 클라이언트 ID 없음 → `.unavailable`, Keychain 에 갱신 토큰 없음 → `.noAccount`, 네트워크 없음(`NWPathMonitor`) → `.offline`, 그 밖 `.ready`.
- 설정 › 저장 데이터(`FreezerSection`·`SettingsView`): "iCloud 동기화" 토글 → **"클라우드 동기화" 피커**(끔 / iCloud / Google Drive, 세그먼트). Drive 선택 시 아래에 "Google Drive 연결" 버튼(미연결) 또는 "연결됨 · 11월 1일" + "연결 해제"(연결됨), 상태 줄(`statusText`), "지금 동기화". 백엔드를 바꾸면 안내 한 줄: "다른 저장소로 바꾸면 처음 맞출 때 양쪽이 다르면 물어봐요."
- `ConflictView`·`SavedDataView`·토스트 문구에 선반 이름.
- 게임별 설정·표지는 지금과 같은 경로로 Drive 에도 올라간다(엔진 그대로).

## 6. 빌드 설정 (`BingsuApp/project.yml`)

- `configFiles: { Debug: Secrets.xcconfig, Release: Secrets.xcconfig }`(타깃 수준) + `Secrets.example.xcconfig`(커밋, 빈 값) + `.gitignore` 에 `BingsuApp/Secrets.xcconfig`. xcconfig 내용:
  ```
  BINGSU_GOOGLE_CLIENT_ID = <n>-<x>.apps.googleusercontent.com
  BINGSU_GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.<n>-<x>
  ```
  xcconfig 가 없을 때도 빌드가 되게, 두 변수의 기본값을 `project.yml` settings 에 빈 문자열로 둔다(xcconfig 가 덮어씀).
- Info.plist(`project.yml` info.properties): `BINGSU_GOOGLE_CLIENT_ID: $(BINGSU_GOOGLE_CLIENT_ID)`, `CFBundleURLTypes` 에 스킴 `$(BINGSU_GOOGLE_REVERSED_CLIENT_ID)`(빈 값이면 iOS 가 무시하는지 확인; 문제가 되면 `BINGSU_GOOGLE_REVERSED_CLIENT_ID` 기본값을 `bingsu-drive-unset` 같은 더미로).
- 구현 세션은 `Keys/LOCAL_NOTES.md` 8행의 값으로 로컬 `Secrets.xcconfig` 를 만들어 빌드한다. **값을 출력하거나 커밋하지 않는다**(`git status` 로 추적되지 않는지 확인). 공개본 검사(`tools/export-public.sh`) 에 `apps.googleusercontent.com` 패턴 금지를 추가한다.
- ATS 예외 없음. 흉내 서버(`http://127.0.0.1`) 는 디버그 빌드의 `BINGSU_ALLOW_HTTP=1` 때만 `NSAllowsLocalNetworking` 없이도 되는지 확인하고, 안 되면 디버그 전용 Info.plist 분기 대신 흉내 서버를 **https 자체 서명**으로 올리지 말고 `URLSessionDelegate` 로 127.0.0.1 만 허용(디버그 전용 코드).

## 7. 검증 도구

- `FakeDriveShelf`(`BINGSU_FAKE_DRIVE=<폴더>`, 디버그): `BINGSU_FAKE_ICLOUD` 와 같은 모양으로 폴더를 Drive 처럼 쓴다. 엔진·화면 흐름(첫 업로드·내려받기·충돌·거부·삭제) 을 시뮬레이터 2대에서 재현.
- `tools/drive-mock/server.py`(표준 라이브러리만): `/token`(고정 토큰 발급·갱신, `invalid_grant` 모드), `/drive/v3/files`(list·get·delete), `/upload/drive/v3/files`(multipart·resumable, 308 위치 조회), `/drive/v3/about`, 403 `storageQuotaExceeded`·429 를 강제하는 스위치(`?mock=quota` 같은 헤더 또는 환경 변수). 파일은 폴더에 저장해 두 시뮬레이터가 같은 서버를 보게 한다. README 에 띄우는 법.
- 디버그 자가 테스트(`BINGSU_SELFTEST=1`) 에: PKCE 챌린지 벡터(RFC 7636 부록 B 값), 경로↔이름 변환 왕복, 오류 분류 표, 토글 이전(`icloudSync` → `syncBackend`).

## 8. 확인 (시뮬레이터 iPhone 17 Pro · iPad Pro 13, 기존 두 대)

- 호환: 빌드 24 데이터(`bingsu.icloudSync` true, `Igloo/state.json`) 로 시작 → 피커가 iCloud, `state-icloud.json` 으로 이전, 동기화 결과 동일.
- 흉내 서버로 Drive: (a) 레조넌스 저장 뒤 종료 → 서버 폴더에 `Saves__pokemon-resonance__save.json` + appProperties (b) 두 번째 시뮬레이터에서 열기 전 내려받기 → 이어하기 (c) 양쪽에서 다르게 저장 → ConflictView 에 "Google Drive" 카드, 로컬/클라우드 선택 각각 (d) 서버 `quota` 모드 → 상태 줄 "Google Drive 공간이 부족해요", 로컬 영향 없음 (e) `invalid_grant` 모드 → "연결이 끊겼어요 · 다시 연결", 동기화 중단 (f) 서버 끔 → "오프라인", 다음 `syncAll` 에서 재개 (g) 6MB 넘는 파일(백업 여러 개 또는 표지) resumable, 조각 중간에 서버 끊고 재시작 → 308 → 완료 (h) 백업 25개 → 클라우드 20개로 정리, 로컬 25개 그대로 (i) 연결 해제 → Keychain·state 삭제, 피커는 그대로 Drive 에 "연결" 버튼.
- 실제 Google 동의 화면은 **시뮬레이터에서 버튼을 눌러 `ASWebAuthenticationSession` 이 뜨는 것까지만** 확인(계정 입력은 하지 않음). 되돌림 스킴 등록은 `xcrun simctl openurl <udid> "<스킴>:/oauth2redirect?code=x&state=y"` 로 앱이 받는지(세션이 없을 땐 무시) 확인.
- 비밀값: `git grep -n "apps.googleusercontent.com"` 결과가 `Secrets.example.xcconfig`·문서의 자리표시자뿐. `tools/export-public.sh` 를 임시 폴더로 돌려 통과.
- 메모리·발열 영향 없음(네트워크는 열기 전·종료 뒤에만).

## 9. 이번 빌드에서 하지 않는 것

Dropbox, `drive.file`(보이는 폴더, PC 공유), `changes.list`, 백그라운드 `URLSession` 업로드, iCloud 와 Drive 동시 활성, 이메일 표시(범위 추가 없음), 엔진 async 전환, 스킨 파일 동기화.

## 10. 끝낼 때

- `docs/beta/privacy.html` 에 "Google Drive 동기화" 절(research §3.5 문구: 사용자가 켤 때만, 본인 계정의 숨은 앱 전용 공간, 개발자는 볼 수 없음, 토큰은 기기 안, 해제 방법, Drive 설정 › 앱 관리에서 삭제 가능). 게시(아티팩트 갱신) 는 부모 세션이 한다.
- `docs/beta/testflight-info.md` §3 심사 메모에 4.8 선제 설명 한 단락, §2 에 빌드 25 테스트 문안 초안(Testing 상태라 7일마다 다시 연결 안내 포함), `docs/beta/guide.md` 에 Drive 연결 안내.
- PLAN.md 로드맵 "저장 데이터 클라우드 동기화 2차" 항목을 `[x]` 로 바꾸고 요약·확인 결과 기록. `research.md` 의 "미확인" 중 구현에서 확인된 것(스킴 되돌림 동작 등 시뮬레이터에서 알 수 있는 것) 을 갱신.
- 빌드 번호는 부모 세션이 올린다.

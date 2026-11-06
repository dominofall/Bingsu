import SwiftUI
import AVFoundation

@main
struct BingsuApp: App {
    @StateObject private var menu = MenuBoardStore()
    /// 앱 내 다운로드(백그라운드 URLSession)의 깨우기 이벤트를 받는다 — Shaver/Courier.swift
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 게임 소리는 기본으로 무음 스위치와 상관없이 나게 한다. 컨트롤러 햅틱 엔진이 오디오 세션을 건드려도
        // 분류가 바뀌지 않도록 앱에서 고정한다 (2026-10-29: 진동 추가 뒤 소리가 안 나던 문제)
        Self.configureAudioSession()
    }

    /// 설정 "무음 모드에서도 소리 재생" (기본 켬). 끄면 무음 스위치를 따르고 다른 앱 소리와 섞인다
    static let playInSilentKey = "bingsu.playInSilentMode"

    /// 소리 설정("무음 모드에서도 소리 재생"·게임별 소리 크기)이 바뀌었을 때. 켜 둔 게임 화면이 받아 바로 적용한다
    static let soundPrefsChanged = Notification.Name("bingsu.soundPrefsChanged")

    /// 게임 소리 크기 (0~1, 기본 1). 모든 게임 공통 — 설정 › 게임 중, 일시정지 화면에서 바꾼다
    static let gameVolumeKey = "bingsu.gameVolume"
    static var gameVolume: Double {
        let d = UserDefaults.standard
        return d.object(forKey: gameVolumeKey) == nil ? 1 : min(1, max(0, d.double(forKey: gameVolumeKey)))
    }
    /// 5% 단위로 저장하고 켜 둔 게임이 바로 따르게 알린다
    static func setGameVolume(_ v: Double) {
        UserDefaults.standard.set(min(1, max(0, (v * 20).rounded() / 20)), forKey: gameVolumeKey)
        NotificationCenter.default.post(name: soundPrefsChanged, object: nil)
    }

    /// 지금 화면에 보이는 게임. 게임별 "무음 모드에서도 소리 재생"을 고를 때 쓴다 (홈이면 nil → 전역 설정)
    @MainActor static var audioDishID: String?

    /// 무음 모드에서도 소리를 낼지: 게임별 설정이 있으면 그것, 없으면 설정 › 게임 중의 값
    @MainActor static func playInSilent(for dishID: String?) -> Bool {
        if let dishID, let own = DishPrefsStore.shared.prefs(for: dishID).playInSilent { return own }
        return UserDefaults.standard.object(forKey: playInSilentKey) as? Bool ?? true
    }

    /// 이 게임만 "무음 모드에서도 소리 재생"을 정하고 바로 적용한다 (일시정지 화면 "다른 앱 소리와 함께 듣기"는 이 값의 반대)
    @MainActor static func setPlayInSilent(_ on: Bool, for dishID: String) {
        DishPrefsStore.shared.update(dishID) { $0.playInSilent = on }
        configureAudioSession()
        NotificationCenter.default.post(name: soundPrefsChanged, object: nil)
    }

    @MainActor static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let inSilent = playInSilent(for: audioDishID)
        do {
            try session.setCategory(inSilent ? .playback : .ambient, mode: .default, options: [])
            // 출력 버퍼를 넉넉히(약 20ms): 기본(수 ms)이면 기기가 뜨겁거나 바쁠 때 버퍼를 못 채워 지지직거릴 수 있다.
            // WebKit 이 자기 값으로 덮을 수도 있어 실제 값은 로그로 확인한다
            try? session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            NSLog("[Bingsu] audio session io=\(String(format: "%.1f", session.ioBufferDuration * 1000))ms sr=\(Int(session.sampleRate))")
        } catch {
            NSLog("[Bingsu] audio session: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MenuBoardView()
                .environmentObject(menu)
                .onOpenURL { url in
                    // Files 앱 "다음으로 열기" / 공유 시트로 받은 zip. LSSupportsOpeningDocumentsInPlace 라서
                    // Files 의 원본을 가리키는 security-scoped URL 이 올 수 있다 → Delivery.start 가 접근을 열고 닫는다.
                    // 다른 앱이 보낸 사본은 Documents/Inbox 에 오며 가져온 뒤 지운다.
                    // Google Drive 동의 화면의 되돌림 주소는 ASWebAuthenticationSession 이 받는다. 여기로 오면(진행 중인 연결 없음) 버린다
                    if let s = url.scheme, s == DriveTicket.config?.redirectScheme {
                        NSLog("[Drive] 되돌림 주소 받음 — 진행 중인 연결이 없어 무시"); return
                    }
                    guard url.isFileURL else { return }
                    NSLog("[Delivery] open url received (\(url.pathExtension))")
                    menu.pendingImport = url
                }
                .task {
                    #if DEBUG
                    // 디버그 자가 테스트: 가상 패드 배치 왕복·예전 설정 호환 (게임 쪽 자가 테스트는 GlassBowl)
                    if DevEnv["BINGSU_SELFTEST"] == "1" { SpoonSelfTest.run(); IglooSelfTest.run(); GreenTeaSelfTest.run() }
                    // 디버그: BINGSU_DRIVE_CONNECT=1 이면 켤 때 "Google Drive 연결" 을 누른 것처럼 (흉내 서버 동의 화면 → 토큰, 결과는 로그)
                    if DevEnv["BINGSU_DRIVE_CONNECT"] == "1" {
                        try? await Task.sleep(for: .seconds(2))
                        let err = await Igloo.shared.connectDrive()
                        NSLog("[Drive] 자동 연결 \(err == nil ? "끝" : "실패: \(err!)") · \(Igloo.shared.statusText)")
                    }
                    #endif
                    // 디버그: BINGSU_ADDWEB="이름|https://..." 로 웹 게임 추가 경로 실행 (시뮬레이터 검증용; 결과는 로그)
                    if let spec = DevEnv["BINGSU_ADDWEB"], let bar = spec.firstIndex(of: "|") {
                        do { try menu.addWebGame(title: String(spec[..<bar]), url: String(spec[spec.index(after: bar)...])); NSLog("[WebGames] added") }
                        catch { NSLog("[WebGames] rejected: \(error.localizedDescription)") }
                    }
                    // 디버그: BINGSU_DOWNLOAD=<주소> 로 앱 내 다운로드 자동 시작 (로컬 http 는 BINGSU_ALLOW_HTTP=1 도 필요).
                    // BINGSU_DOWNLOAD_PAUSE=<초> 면 그 시간 뒤 일시정지하고 2초 뒤 재개한다 (이어받기 확인용)
                    if let u = DevEnv["BINGSU_DOWNLOAD"] {
                        try? await Task.sleep(for: .seconds(1))
                        do { try Courier.shared.start(u) } catch { NSLog("[Courier] rejected: \(error.localizedDescription)") }
                        if let s = DevEnv["BINGSU_DOWNLOAD_PAUSE"].flatMap(Double.init) {
                            try? await Task.sleep(for: .seconds(s))
                            Courier.shared.pause()
                            try? await Task.sleep(for: .seconds(2))
                            Courier.shared.resume()
                        }
                    }
                    // 디버그: BINGSU_IMPORT=/path/to.zip 로 가져오기 자동 실행 (시뮬레이터 검증용).
                    // 상대 경로면 앱 Documents 기준 (실기기: devicectl 로 Documents 에 넣은 zip)
                    if let p = DevEnv["BINGSU_IMPORT"] {
                        try? await Task.sleep(for: .seconds(1))
                        menu.pendingImport = p.hasPrefix("/") ? URL(fileURLWithPath: p)
                            : URL.documentsDirectory.appendingPathComponent(p)
                    }
                }
        }
    }
}

/// 개발용 환경 변수(`BINGSU_*`)는 모두 여기서 읽는다. Release 에서는 아무것도 돌려주지 않아 자동 실행·로그 같은 개발 기능이 꺼진다
enum DevEnv {
    static subscript(_ name: String) -> String? {
        #if DEBUG
        ProcessInfo.processInfo.environment[name]
        #else
        nil
        #endif
    }
}

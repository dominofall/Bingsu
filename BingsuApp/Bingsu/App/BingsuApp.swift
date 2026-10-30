import SwiftUI
import AVFoundation

@main
struct BingsuApp: App {
    @StateObject private var menu = MenuBoardStore()
    /// 앱 내 다운로드(백그라운드 URLSession)의 깨우기 이벤트를 받는다 — Shaver/Courier.swift
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 게임 소리는 무음 스위치와 상관없이 나게 한다. 컨트롤러 햅틱 엔진이 오디오 세션을 건드려도
        // 분류가 바뀌지 않도록 앱에서 고정한다 (2026-10-29: 진동 추가 뒤 소리가 안 나던 문제)
        Self.configureAudioSession()
    }

    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
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
                    guard url.isFileURL else { return }
                    NSLog("[Delivery] open url received (\(url.pathExtension))")
                    menu.pendingImport = url
                }
                .task {
                    // 디버그: BINGSU_ADDWEB="이름|https://..." 로 웹 게임 추가 경로 실행 (시뮬레이터 검증용; 결과는 로그)
                    if let spec = ProcessInfo.processInfo.environment["BINGSU_ADDWEB"], let bar = spec.firstIndex(of: "|") {
                        do { try menu.addWebGame(title: String(spec[..<bar]), url: String(spec[spec.index(after: bar)...])); NSLog("[WebGames] added") }
                        catch { NSLog("[WebGames] rejected: \(error.localizedDescription)") }
                    }
                    // 디버그: BINGSU_DOWNLOAD=<주소> 로 앱 내 다운로드 자동 시작 (로컬 http 는 BINGSU_ALLOW_HTTP=1 도 필요).
                    // BINGSU_DOWNLOAD_PAUSE=<초> 면 그 시간 뒤 일시정지하고 2초 뒤 재개한다 (이어받기 확인용)
                    if let u = ProcessInfo.processInfo.environment["BINGSU_DOWNLOAD"] {
                        try? await Task.sleep(for: .seconds(1))
                        do { try Courier.shared.start(u) } catch { NSLog("[Courier] rejected: \(error.localizedDescription)") }
                        if let s = ProcessInfo.processInfo.environment["BINGSU_DOWNLOAD_PAUSE"].flatMap(Double.init) {
                            try? await Task.sleep(for: .seconds(s))
                            Courier.shared.pause()
                            try? await Task.sleep(for: .seconds(2))
                            Courier.shared.resume()
                        }
                    }
                    // 디버그: BINGSU_IMPORT=/path/to.zip 로 가져오기 자동 실행 (시뮬레이터 검증용).
                    // 상대 경로면 앱 Documents 기준 (실기기: devicectl 로 Documents 에 넣은 zip)
                    if let p = ProcessInfo.processInfo.environment["BINGSU_IMPORT"] {
                        try? await Task.sleep(for: .seconds(1))
                        menu.pendingImport = p.hasPrefix("/") ? URL(fileURLWithPath: p)
                            : URL.documentsDirectory.appendingPathComponent(p)
                    }
                }
        }
    }
}

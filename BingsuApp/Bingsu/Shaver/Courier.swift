import Foundation
import Combine
import UIKit

/// 앱 내 다운로드: 사용자가 직접 넣은 https 주소의 게임 zip 을 백그라운드 URLSession 으로 받는다.
/// - 백그라운드 세션이라 앱을 내리거나 시스템이 앱을 꺼도 nsurlsessiond 가 이어 받는다. 끝나면 앱을 깨워
///   `AppDelegate.handleEventsForBackgroundURLSession` → 같은 identifier 로 세션을 다시 만들어 결과를 받는다.
/// - 받은 파일은 `Library/Caches/Downloads/<slug>.zip`(백업 제외). 가져오기가 그 파일을 임시 폴더로 옮겨 쓰므로 설치가 끝나면 남지 않는다.
/// - 일시정지는 이어받기 데이터(`<slug>.resume`)를 남기고 취소, 재개는 그 데이터로 새 작업. 동시에 하나만 받는다.
/// - 받은 파일은 신뢰하지 않는다. zip 인지·손상 여부는 가져오기의 `SafeUnzip` 이 그대로 거른다.
/// - 진단 로그에는 호스트만 남긴다 (경로·쿼리에 토큰이 있을 수 있다).
@MainActor
final class Courier: NSObject, ObservableObject {
    static let shared = Courier()
    /// 받을 수 있는 가장 큰 파일. 서버가 크기를 알려 주지 않아도 받는 중에 넘으면 멈춘다
    nonisolated static let maxBytes = Int64(SafeUnzip.maxUncompressedBytes)
    static let sessionID = "com.minwoo.bingsu.courier"

    enum State: Equatable {
        case idle
        case checking                                    // HEAD 로 크기·여유 공간 확인
        case downloading(received: Int64, total: Int64, speed: Double, remaining: TimeInterval?)
        case paused(received: Int64, total: Int64)
        case failed(String)
        case done(URL)                                   // 다 받음 → 가져오기 대기

        var fraction: Double? {
            switch self {
            case .downloading(let r, let t, _, _), .paused(let r, let t): return t > 0 ? min(1, Double(r) / Double(t)) : nil
            case .done: return 1
            default: return nil
            }
        }
        /// 받는 중·멈춤·확인 중 — 새 내려받기를 시작할 수 없는 상태
        var isActive: Bool {
            switch self {
            case .checking, .downloading, .paused: return true
            default: return false
            }
        }
    }

    enum CourierError: LocalizedError {
        case badURL, notHTTPS, hasCredentials, localHost, busy
        case notEnoughSpace(needed: Int64, free: Int64)
        case http(Int)
        case redirectedAway(String)
        case tooLarge
        case network(String)
        var errorDescription: String? {
            switch self {
            case .badURL: return "주소 형식이 아니에요. 예: https://example.com/game.zip"
            case .notHTTPS: return "https:// 로 시작하는 주소만 받을 수 있어요"
            case .hasCredentials: return "주소에 아이디·비밀번호를 넣을 수 없어요"
            case .localHost: return "이 주소는 쓸 수 없어요"
            case .busy: return "이미 내려받는 중이에요"
            case .notEnoughSpace(let n, let f):
                return "저장 공간이 부족해요 · 필요 \(Courier.bytes(n)), 남은 공간 \(Courier.bytes(f))"
            case .http(let code): return "서버가 파일을 주지 않았어요 (\(code))"
            case .redirectedAway(let host): return "다른 주소로 넘어가서 받지 않았어요 · \(host)"
            case .tooLarge: return "파일이 너무 커요 · \(Courier.bytes(Courier.maxBytes)) 까지 받을 수 있어요"
            case .network(let why): return "내려받지 못했어요 · \(why)"
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// 화면에 보일 파일 이름 (서버가 알려준 이름, 없으면 주소 끝)
    @Published private(set) var fileName = ""
    /// 받는 호스트 (리다이렉트 끝 호스트. 화면에 보여 어디서 받는지 알 수 있게)
    @Published private(set) var host = ""
    /// 이어받기 데이터가 있는지 (일시정지 또는 네트워크 끊김)
    @Published private(set) var canResume = false

    /// 시스템이 백그라운드에서 앱을 깨웠을 때 받은 완료 핸들러. 세션 이벤트를 다 처리하면 부른다.
    var backgroundCompletion: (() -> Void)?

    /// 디버그 빌드에서 `BINGSU_ALLOW_HTTP=1` 일 때만 http·localhost·사설 주소 허용 (로컬 서버 검증용)
    nonisolated static var allowLocal: Bool {
        #if DEBUG
        return DevEnv["BINGSU_ALLOW_HTTP"] == "1"
        #else
        return false
        #endif
    }

    nonisolated static let downloadsDir: URL = {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var d = dir; try? d.setResourceValues(values)
        return dir
    }()

    /// 마지막으로 받은 주소 (호스트+경로만, 쿼리·조각 없음). 입력란 미리 채우기용
    static var lastAddress: String? { UserDefaults.standard.string(forKey: Keys.lastAddress) }

    private enum Keys {
        static let lastAddress = "courier.lastAddress"
        static let slug = "courier.slug"           // 지금 받는(또는 멈춘) 파일 이름 바탕
        static let fileName = "courier.fileName"
        static let host = "courier.host"
        static let doneFile = "courier.doneFile"   // 다 받고 아직 가져오지 않은 파일 이름 (Downloads 안)
        static let failure = "courier.failure"     // 앱이 꺼진 사이 실패했을 때 이유
    }

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    /// 메모리에만 두는 전체 주소 (처음부터 다시 받기용). 앱이 다시 켜지면 작업의 originalRequest 에서 되찾는다.
    private var sourceURL: URL?
    private var slug = ""
    private var total: Int64 = 0
    private var lastSample: (time: Date, bytes: Int64)?
    private var speed: Double = 0
    private var lastLoggedTenth = -1

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        // 델리게이트는 백그라운드 큐에서 불린다. 파일 옮기기는 거기서 바로 하고 상태만 메인으로 넘긴다.
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        restore()
    }

    // MARK: - 시작 · 멈춤 · 재개 · 취소

    /// 주소 검증 → HEAD 로 크기 확인 → 여유 공간 검사 → 백그라운드 내려받기.
    /// 검증 실패는 바로 던지고(입력 화면에 문구), 그 뒤 실패는 `.failed` 상태로 알린다.
    func start(_ raw: String) throws {
        guard !state.isActive else { throw CourierError.busy }
        let url: URL
        do { url = try WebGames.normalize(raw, allowLocal: Self.allowLocal) }
        catch let e as WebGames.AddError {
            switch e {
            case .notHTTPS: throw CourierError.notHTTPS
            case .hasCredentials: throw CourierError.hasCredentials
            case .localHost: throw CourierError.localHost
            default: throw CourierError.badURL
            }
        }
        clearLeftovers()
        sourceURL = url
        slug = Self.makeSlug(url)
        host = url.host ?? ""
        fileName = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? "\(host).zip" : url.lastPathComponent
        canResume = false
        rememberAddress(url)
        saveJob()
        state = .checking
        NSLog("[Courier] start host=\(host)")
        Task { await preflight(url) }
    }

    func pause() {
        guard case .downloading(let r, let t, _, _) = state, let task else { return }
        state = .paused(received: r, total: t)
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.saveResumeData(data) }
                NSLog("[Courier] paused at \(r) bytes resumeData=\(data?.count ?? 0)")
            }
        })
        self.task = nil
    }

    /// 이어받기 데이터로 다시 받기. 데이터가 없으면(서버가 이어받기를 안 받아 줌) 처음부터.
    func resume() {
        if case .downloading = state { return }
        if let data = try? Data(contentsOf: resumeFile) {
            try? FileManager.default.removeItem(at: resumeFile)
            let t = session.downloadTask(withResumeData: data)
            begin(t, from: currentReceived)
            NSLog("[Courier] resumed from \(currentReceived) bytes")
        } else if let url = sourceURL {
            NSLog("[Courier] no resume data — restarting host=\(url.host ?? "")")
            begin(session.downloadTask(with: url), from: 0)
        } else {
            state = .failed("이어받을 수 없어요 · 주소를 다시 넣어 주세요")
        }
        canResume = false
    }

    func cancel() {
        task?.cancel()
        task = nil
        clearLeftovers()
        state = .idle
        NSLog("[Courier] cancelled")
    }

    /// 다 받은 파일을 가져오기에 넘겼다 → 대기 표시를 지운다 (파일은 가져오기가 옮겨 간다)
    func handedOff() {
        UserDefaults.standard.removeObject(forKey: Keys.doneFile)
        state = .idle
    }

    /// 실패 화면에서 입력으로 돌아갈 때
    func reset() {
        if case .failed = state, !canResume { clearLeftovers(); state = .idle }
    }

    // MARK: - 내부

    private var resumeFile: URL { Self.downloadsDir.appendingPathComponent("\(slug).resume") }
    private var currentReceived: Int64 {
        switch state {
        case .downloading(let r, _, _, _), .paused(let r, _): return r
        default: return 0
        }
    }

    private func preflight(_ url: URL) async {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 20
        var expected: Int64 = -1
        if let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse {
            if let final = http.url, final.host != url.host {
                // 리다이렉트 끝도 같은 규칙으로 검사 (https, 사설 주소 아님)
                if (try? WebGames.normalize(final.absoluteString, allowLocal: Self.allowLocal)) == nil {
                    fail(.redirectedAway(final.host ?? "?")); return
                }
                host = final.host ?? host
                saveJob()
            }
            if http.statusCode >= 400, http.statusCode != 405 { fail(.http(http.statusCode)); return }
            expected = http.expectedContentLength
            if let name = http.suggestedFilename, !name.isEmpty, http.value(forHTTPHeaderField: "Content-Disposition") != nil { fileName = name; saveJob() }
        }
        // HEAD 를 안 받아 주는 서버도 있다 → 크기를 모르면 검사 없이 받는다
        if expected > Self.maxBytes { fail(.tooLarge); return }
        if expected > 0 {
            let free = Int64(SafeUnzip.freeSpace(at: Self.downloadsDir))
            let need = expected * 2 + 200 * 1024 * 1024 // maxBytes 이하라 넘치지 않는다
            NSLog("[Courier] head size=\(expected) free=\(free)")
            if free > 0, need > free { fail(.notEnoughSpace(needed: need, free: free)); return }
        }
        guard case .checking = state else { return } // 그사이 취소됨
        total = max(0, expected)
        begin(session.downloadTask(with: url), from: 0)
    }

    private func begin(_ t: URLSessionDownloadTask, from received: Int64) {
        task = t
        lastSample = nil
        speed = 0
        lastLoggedTenth = -1
        state = .downloading(received: received, total: total, speed: 0, remaining: nil)
        t.resume()
    }

    private func fail(_ e: CourierError) {
        NSLog("[Courier] failed: \(e.localizedDescription)")
        task = nil
        state = .failed(e.localizedDescription)
    }

    private func progress(_ t: URLSessionDownloadTask, written: Int64, expected: Int64) {
        guard t == task || task == nil else { return }
        if task == nil { task = t }
        if case .paused = state { return }
        if written > Self.maxBytes || expected > Self.maxBytes {
            t.cancel(); task = nil
            try? FileManager.default.removeItem(at: resumeFile)
            fail(.tooLarge); return
        }
        if expected > 0 { total = expected }
        let now = Date()
        if let s = lastSample {
            let dt = now.timeIntervalSince(s.time)
            guard dt >= 0.5 || written == total else { return }
            let inst = Double(written - s.bytes) / max(dt, 0.001)
            speed = speed == 0 ? inst : speed * 0.7 + inst * 0.3
        }
        lastSample = (now, written)
        // 크기를 모르고 시작했을 수도 있어 받는 중에도 여유 공간을 본다 (풀 자리 200MB 는 남긴다)
        let free = Int64(clamping: SafeUnzip.freeSpace(at: Self.downloadsDir))
        if free > 0, free < 200 * 1024 * 1024 {
            t.cancel(); task = nil
            try? FileManager.default.removeItem(at: resumeFile)
            fail(.notEnoughSpace(needed: max(total, written) + 200 * 1024 * 1024, free: free)); return
        }
        let remaining: TimeInterval? = speed > 1 && total > 0 ? Double(total - written) / speed : nil
        state = .downloading(received: written, total: total, speed: speed, remaining: remaining)
        if total > 0 {
            let tenth = Int(Double(written) / Double(total) * 10)
            if tenth != lastLoggedTenth { lastLoggedTenth = tenth; NSLog("[Courier] progress \(written)/\(total)") }
        }
    }

    /// 백그라운드 큐에서 이미 옮긴 파일을 받는다
    private func finished(_ t: URLSessionDownloadTask, file: URL?, error: CourierError?, name: String?) {
        task = nil
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            fail(error)
            return
        }
        guard let file else { return }
        if let name, !name.isEmpty { fileName = name }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        NSLog("[Courier] done \(size) bytes host=\(host)")
        UserDefaults.standard.set(file.lastPathComponent, forKey: Keys.doneFile)
        saveJob()
        try? FileManager.default.removeItem(at: resumeFile)
        canResume = false
        state = .done(file)
    }

    /// 네트워크 끊김 등: 이어받기 데이터가 있으면 남겨 "이어받기"를 제안한다
    private func networkFailed(_ t: URLSessionTask, error: NSError) {
        guard t == task || task == nil else { return }
        task = nil
        if error.code == NSURLErrorCancelled, case .paused = state { return } // 일시정지
        if error.code == NSURLErrorCancelled, case .idle = state { return }   // 취소
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            saveResumeData(data)
        }
        NSLog("[Courier] network error \(error.code) resumable=\(canResume)")
        let why = error.localizedDescription
        UserDefaults.standard.set(why, forKey: Keys.failure)
        state = .failed(CourierError.network(why).localizedDescription)
    }

    private func saveResumeData(_ data: Data) {
        try? data.write(to: resumeFile, options: .atomic)
        canResume = true
    }

    private func rememberAddress(_ url: URL) {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil; c?.fragment = nil; c?.user = nil; c?.password = nil
        if let s = c?.string { UserDefaults.standard.set(s, forKey: Keys.lastAddress) }
    }

    private func saveJob() {
        let d = UserDefaults.standard
        d.set(slug, forKey: Keys.slug); d.set(fileName, forKey: Keys.fileName); d.set(host, forKey: Keys.host)
        d.removeObject(forKey: Keys.failure)
    }

    /// 이전 작업의 남은 파일(멈춘 이어받기 데이터, 가져오지 않은 파일)을 지운다
    private func clearLeftovers() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: Self.downloadsDir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
        for k in [Keys.slug, Keys.fileName, Keys.host, Keys.doneFile, Keys.failure] { UserDefaults.standard.removeObject(forKey: k) }
        canResume = false
        total = 0
    }

    /// 앱이 다시 켜졌을 때: 세션에 살아 있는 작업, 멈춘 이어받기 데이터, 다 받은 파일을 되찾는다
    private func restore() {
        let d = UserDefaults.standard
        slug = d.string(forKey: Keys.slug) ?? ""
        fileName = d.string(forKey: Keys.fileName) ?? ""
        host = d.string(forKey: Keys.host) ?? ""
        guard !slug.isEmpty else { return }
        if let done = d.string(forKey: Keys.doneFile) {
            let f = Self.downloadsDir.appendingPathComponent(done)
            if FileManager.default.fileExists(atPath: f.path) { state = .done(f); NSLog("[Courier] restored done file"); return }
            d.removeObject(forKey: Keys.doneFile)
        }
        if FileManager.default.fileExists(atPath: resumeFile.path) {
            canResume = true
            if let why = d.string(forKey: Keys.failure) { state = .failed(CourierError.network(why).localizedDescription) }
            else { state = .paused(received: 0, total: 0) }
        }
        session.getAllTasks { [weak self] tasks in
            let t = tasks.compactMap { $0 as? URLSessionDownloadTask }.first { $0.state == .running || $0.state == .suspended }
            Task { @MainActor in
                guard let self, let t else { return }
                self.task = t
                self.sourceURL = t.originalRequest?.url
                self.total = max(0, t.countOfBytesExpectedToReceive)
                self.state = .downloading(received: t.countOfBytesReceived, total: self.total, speed: 0, remaining: nil)
                if t.state == .suspended { t.resume() }
                NSLog("[Courier] reattached running task at \(t.countOfBytesReceived) bytes")
            }
        }
    }

    nonisolated static func makeSlug(_ url: URL) -> String {
        let last = url.deletingPathExtension().lastPathComponent
        return Delivery.slug(last.isEmpty || last == "/" ? (url.host ?? "download") : last)
    }

    nonisolated static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// 가져오기가 이 폴더의 파일을 복사하지 않고 옮겨 쓰도록 판별 (큰 zip 이 두 벌 생기지 않게)
    nonisolated static func isDownloadedFile(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == downloadsDir.standardizedFileURL.path
    }
}

// MARK: - URLSessionDownloadDelegate (백그라운드 큐)

extension Courier: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in self.progress(downloadTask, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        NSLog("[Courier] server resumed at offset \(fileOffset)/\(expectedTotalBytes)")
    }

    /// 임시 파일은 이 메서드가 돌아오면 지워지므로 여기서 바로 옮긴다
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let http = downloadTask.response as? HTTPURLResponse
        let slug = UserDefaults.standard.string(forKey: "courier.slug").flatMap { $0.isEmpty ? nil : $0 }
            ?? downloadTask.originalRequest?.url.map(Courier.makeSlug) ?? "download"
        var error: Courier.CourierError?
        if let code = http?.statusCode, !(200..<300).contains(code) { error = .http(code) }
        // 백그라운드 세션은 리다이렉트를 스스로 따라가므로 끝 주소를 여기서 다시 검사한다
        // (리다이렉트가 없었으면 시작할 때 검사한 주소 그대로라 다시 보지 않는다)
        let original = downloadTask.originalRequest?.url
        if error == nil, let final = http?.url,
           final.host != original?.host || final.scheme != original?.scheme,
           (try? WebGames.normalize(final.absoluteString, allowLocal: Courier.allowLocal)) == nil {
            error = .redirectedAway(final.host ?? "?")
        }
        // 받는 중 검사(progress)를 지나쳐도 다 받은 파일의 실제 크기로 한 번 더 본다
        if error == nil, let n = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(n) > Courier.maxBytes {
            error = .tooLarge
        }
        var dest: URL?
        if error == nil {
            let fm = FileManager.default
            let d = Courier.downloadsDir.appendingPathComponent("\(slug).zip")
            try? fm.removeItem(at: d)
            do { try fm.moveItem(at: location, to: d); dest = d }
            catch { NSLog("[Courier] move failed: \(error.localizedDescription)") }
            if dest == nil { error = .network("받은 파일을 옮기지 못했어요") }
        }
        let name = http?.suggestedFilename
        let finalHost = http?.url?.host
        Task { @MainActor in
            if let finalHost { self.host = finalHost }
            self.finished(downloadTask, file: dest, error: error, name: name)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError? else { return }
        Task { @MainActor in self.networkFailed(task, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            NSLog("[Courier] background events finished")
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

/// 백그라운드 세션 이벤트를 받으려면 UIApplicationDelegate 가 필요하다
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = Courier.shared // 같은 identifier 로 세션을 다시 만들어 앱이 꺼진 사이의 결과를 받는다
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Courier.sessionID else { completionHandler(); return }
        NSLog("[Courier] woken for background session events")
        Courier.shared.backgroundCompletion = completionHandler
    }
}

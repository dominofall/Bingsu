import Foundation
import AuthenticationServices
import CryptoKit
import Security

/// Google Drive 오류. 화면·엔진은 `DriveShelf.classify` 로 `IglooShelfError` 를 본다
enum DriveError: Error, Equatable {
    /// 클라이언트 ID 가 빌드에 없음 (Secrets.xcconfig 없이 빌드)
    case notConfigured
    /// 갱신 토큰이 없거나 죽음(`invalid_grant`) — 다시 연결해야 한다
    case signedOut
    case quotaFull
    /// 403 rate limit·429·5xx 를 몇 번 기다려도 안 됨
    case rateLimited
    case tooLarge
    /// 올리기 직전 확인에서 다른 기기가 먼저 올린 것을 봄 (덮어쓰지 않음)
    case changedRemotely
    /// 동의 화면에서 거절 · state 불일치 · 응답 모양이 이상함
    case denied
    case badResponse
    case http(Int, String?)

    var logText: String {
        switch self {
        case .notConfigured: return "클라이언트 ID 없음"
        case .signedOut: return "연결 끊김"
        case .quotaFull: return "Drive 공간 부족"
        case .rateLimited: return "요청 제한"
        case .tooLarge: return "크기 초과"
        case .changedRemotely: return "다른 기기가 먼저 올림"
        case .denied: return "거절"
        case .badResponse: return "응답 이상"
        case .http(let c, let r): return "HTTP \(c)\(r.map { " \($0)" } ?? "")"
        }
    }

    var userText: String? {
        switch self {
        case .notConfigured: return "Google Drive 는 준비 중이에요."
        case .denied: return "Google Drive 연결을 허용하지 않았어요."
        default: return nil
        }
    }
}

/// Google Drive 연결 (OAuth 2.0 공개 클라이언트 + PKCE, SDK 없음). 토큰은 Keychain(이 기기 전용) 에만 둔다 (PLAN 8.2).
/// 화면 문구는 "Google Drive 연결" — 앱 계정이 아니라 사용자의 Drive 에 저장 데이터를 두는 연결이다 (심사 4.8).
/// 토큰 갱신은 `Igloo.queue` 안에서 동기적으로, 연결(동의 화면)은 메인에서 async 로.
final class DriveTicket: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DriveTicket()

    struct Config {
        let clientID: String
        /// 클라이언트 ID 를 뒤집은 되돌림 스킴 (`com.googleusercontent.apps.<n>-<x>`)
        let redirectScheme: String
        let authURL: URL
        let tokenURL: URL
        let revokeURL: URL
        let apiBase: URL
        /// 흉내 서버용 고정 토큰 (디버그). 있으면 Keychain 을 쓰지 않는다
        let fixedToken: String?
        /// 흉내 서버 (디버그) — Keychain 항목을 실제 연결과 나눈다
        let mock: Bool
        var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
    }

    static let scope = "https://www.googleapis.com/auth/drive.appdata"

    /// 빌드에 클라이언트 ID 가 없으면 nil (Drive 선택지를 "준비 중" 으로)
    static let config: Config? = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "BINGSU_GOOGLE_CLIENT_ID") as? String ?? "").trimmingCharacters(in: .whitespaces)
        let plistID = raw.contains(".") && !raw.contains("$(") ? raw : nil
        #if DEBUG
        // 흉내 서버(tools/drive-mock): BINGSU_ALLOW_HTTP=1 과 함께일 때만, 127.0.0.1/localhost 만
        let env = ProcessInfo.processInfo.environment
        if env["BINGSU_ALLOW_HTTP"] == "1", let s = env["BINGSU_DRIVE_BASE_URL"], let base = URL(string: s),
           base.scheme == "http", ["127.0.0.1", "localhost"].contains(base.host ?? "") {
            let id = plistID ?? "bingsu.mock"
            NSLog("[Drive] 흉내 서버 사용")
            return Config(clientID: id, redirectScheme: reversed(id),
                          authURL: base.appendingPathComponent("o/oauth2/v2/auth"), tokenURL: base.appendingPathComponent("token"),
                          revokeURL: base.appendingPathComponent("revoke"), apiBase: base,
                          fixedToken: env["BINGSU_DRIVE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }, mock: true)
        }
        #endif
        guard let id = plistID else { return nil }
        return Config(clientID: id, redirectScheme: reversed(id),
                      authURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                      tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
                      revokeURL: URL(string: "https://oauth2.googleapis.com/revoke")!,
                      apiBase: URL(string: "https://www.googleapis.com")!, fixedToken: nil, mock: false)
    }()

    /// "a.b.c" → "c.b.a" (iOS 클라이언트 ID 를 되돌림 스킴으로)
    static func reversed(_ id: String) -> String { id.split(separator: ".").reversed().joined(separator: ".") }

    // MARK: PKCE (RFC 7636)

    private static let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 영숫자·`-._~` 66자에서 고른 난수 문자열. 198(=66×3) 이상인 바이트는 버려 치우침 없이
    static func randomString(_ n: Int) -> String {
        var out: [Character] = []
        while out.count < n {
            var bytes = [UInt8](repeating: 0, count: n)
            if SecRandomCopyBytes(kSecRandomDefault, n, &bytes) != errSecSuccess {
                for i in 0..<n { bytes[i] = UInt8.random(in: 0...255) }
            }
            for b in bytes where Int(b) < unreserved.count * 3 && out.count < n { out.append(unreserved[Int(b) % unreserved.count]) }
        }
        return String(out)
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: 토큰 (Keychain)

    struct Tokens: Codable {
        var access: String?
        var expiresAt: Date?
        var refresh: String
        var connectedAt: Date
    }

    private let lock = NSLock()
    private var cached: Tokens?
    private var loaded = false
    private var anchor: ASPresentationAnchor?
    private var authSession: ASWebAuthenticationSession?

    private static let service = "com.minwoo.bingsu.drive"
    private static var account: String { config?.mock == true ? "mock" : "default" }
    /// 갱신 실패(invalid_grant) 로 끊겼는지 — 상태 줄 "연결이 끊겼어요" (비밀값 아님)
    static let lostKey = "bingsu.drive.lost"

    private func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
    }

    private func loadTokens() -> Tokens? {
        lock.lock(); defer { lock.unlock() }
        if loaded { return cached }
        var q = keychainQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess, let d = out as? Data { cached = try? JSONDecoder().decode(Tokens.self, from: d) }
        else if status != errSecItemNotFound { NSLog("[Drive] Keychain 읽기 실패 \(status)") }
        loaded = true
        return cached
    }

    private func saveTokens(_ t: Tokens) {
        lock.lock(); defer { lock.unlock() }
        cached = t; loaded = true
        guard let d = try? JSONEncoder().encode(t) else { return }
        let q = keychainQuery()
        let attrs: [String: Any] = [kSecValueData as String: d,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add.merge(attrs) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { NSLog("[Drive] Keychain 쓰기 실패 \(status)") }
    }

    private func clearTokens() {
        lock.lock(); defer { lock.unlock() }
        cached = nil; loaded = true
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    var isConnected: Bool { Self.config?.fixedToken != nil || loadTokens() != nil }
    var lostConnection: Bool { UserDefaults.standard.bool(forKey: Self.lostKey) }

    /// "연결됨 · 11월 1일" (이메일은 받지 않는다: 범위를 drive.appdata 하나로)
    var accountLabel: String? {
        if Self.config?.fixedToken != nil { return "연결됨 · 고정 토큰(디버그)" }
        guard let t = loadTokens() else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M월 d일"
        return "연결됨 · \(f.string(from: t.connectedAt))"
    }

    // MARK: 연결

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor ?? ASPresentationAnchor() }

    /// 동의 화면 → 인증 코드 → 토큰 교환 → Keychain
    @MainActor
    func connect(anchor: ASPresentationAnchor) async throws {
        guard let cfg = Self.config else { throw DriveError.notConfigured }
        let verifier = Self.randomString(64)
        let state = Self.randomString(32)
        var comps = URLComponents(url: cfg.authURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: cfg.clientID), .init(name: "redirect_uri", value: cfg.redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state), .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        self.anchor = anchor
        let callback: URL = try await withCheckedThrowingContinuation { c in
            var resumed = false
            let s = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: cfg.redirectScheme) { url, error in
                DispatchQueue.main.async {
                    guard !resumed else { return }
                    resumed = true
                    if let url { c.resume(returning: url) } else { c.resume(throwing: error ?? DriveError.badResponse) }
                }
            }
            s.presentationContextProvider = self
            // Safari 쿠키를 나누지 않는다: 매번 계정을 고르게
            s.prefersEphemeralWebBrowserSession = true
            authSession = s
            if !s.start() { DispatchQueue.main.async { guard !resumed else { return }; resumed = true; c.resume(throwing: DriveError.badResponse) } }
        }
        authSession = nil
        self.anchor = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard item("state") == state else { NSLog("[Drive] 되돌림 state 불일치 — 거절"); throw DriveError.denied }
        if item("error") != nil { throw DriveError.denied }
        guard let code = item("code"), !code.isEmpty else { throw DriveError.badResponse }

        let body = Self.form(["client_id": cfg.clientID, "code": code, "code_verifier": verifier,
                              "grant_type": "authorization_code", "redirect_uri": cfg.redirectURI])
        var req = URLRequest(url: cfg.tokenURL, timeoutInterval: DriveCounter.timeout)
        req.httpMethod = "POST"; req.httpBody = body
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (d, r) = try await DriveCounter.plainSession.data(for: req)
        guard let http = r as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let access = obj["access_token"] as? String, let refresh = obj["refresh_token"] as? String else {
            NSLog("[Drive] 토큰 교환 실패 (\((r as? HTTPURLResponse)?.statusCode ?? 0))")
            throw DriveError.badResponse
        }
        let expires = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        saveTokens(Tokens(access: access, expiresAt: Date().addingTimeInterval(expires), refresh: refresh, connectedAt: Date()))
        UserDefaults.standard.removeObject(forKey: Self.lostKey)
        NSLog("[Drive] 연결됨")
    }

    /// 연결 해제: 갱신 토큰 철회(실패해도 진행) → Keychain 삭제
    func disconnect() async {
        if let cfg = Self.config, let t = loadTokens() {
            // 토큰은 주소가 아니라 본문으로 보낸다 (서버·프록시 기록에 남지 않게)
            var req = URLRequest(url: cfg.revokeURL, timeoutInterval: 15)
            req.httpMethod = "POST"; req.httpBody = Self.form(["token": t.refresh])
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let status = (try? await DriveCounter.plainSession.data(for: req)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
            NSLog("[Drive] 철회 \(status.map(String.init) ?? "실패(무시)")")
        }
        clearTokens()
        UserDefaults.standard.removeObject(forKey: Self.lostKey)
    }

    // MARK: 액세스 토큰 (Igloo.queue 안에서 동기)

    /// 만료 60초 전부터 새로 받는다. 갱신 토큰이 죽었으면 Keychain 을 비우고 `.signedOut`
    func accessToken(forceRefresh: Bool = false) throws -> String {
        guard let cfg = Self.config else { throw DriveError.notConfigured }
        if let fixed = cfg.fixedToken { return fixed }
        guard let t = loadTokens() else { throw DriveError.signedOut }
        if !forceRefresh, let a = t.access, let exp = t.expiresAt, exp.timeIntervalSinceNow > 60 { return a }

        var req = URLRequest(url: cfg.tokenURL, timeoutInterval: DriveCounter.timeout)
        req.httpMethod = "POST"
        req.httpBody = Self.form(["client_id": cfg.clientID, "grant_type": "refresh_token", "refresh_token": t.refresh])
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (d, r) = try DriveCounter.sendPlain(req)
        let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if r.statusCode == 400 || r.statusCode == 401, (obj?["error"] as? String) == "invalid_grant" {
            NSLog("[Drive] 갱신 토큰 만료·철회 (invalid_grant) — 다시 연결 필요")
            clearTokens()
            UserDefaults.standard.set(true, forKey: Self.lostKey)
            throw DriveError.signedOut
        }
        guard r.statusCode == 200, let access = obj?["access_token"] as? String else {
            throw r.statusCode >= 500 ? DriveError.rateLimited : DriveError.http(r.statusCode, obj?["error"] as? String)
        }
        var n = t
        n.access = access
        n.expiresAt = Date().addingTimeInterval((obj?["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
        if let newRefresh = obj?["refresh_token"] as? String { n.refresh = newRefresh }
        saveTokens(n)
        NSLog("[Drive] 액세스 토큰 갱신")
        return access
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }
}

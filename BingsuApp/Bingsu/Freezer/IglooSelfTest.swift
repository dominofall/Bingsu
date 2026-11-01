#if DEBUG
import Foundation

/// 디버그 자가 테스트 (`BINGSU_SELFTEST=1`, 앱을 켤 때 한 번). 결과는 `[Igloo] selftest …` 로그.
/// - PKCE: RFC 7636 부록 B 벡터, 난수 verifier 모양
/// - 경로 ↔ Drive 이름 왕복, 클라우드 경로 거부 규칙, appProperties 124바이트 자르기
/// - 오류 분류 표 (Drive 오류·URLError·디스크 가득 → IglooShelfError), Drive 오류 본문·Range 읽기
/// - 선반 이전: 빌드 24 `bingsu.icloudSync` → `bingsu.syncBackend`
enum IglooSelfTest {
    static func run() {
        var fails = 0, checks = 0
        func check(_ c: Bool, _ what: String) { checks += 1; if !c { fails += 1; NSLog("[Igloo] selftest FAIL \(what)") } }

        // PKCE
        check(DriveTicket.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE RFC 7636 B")
        let v = DriveTicket.randomString(64), v2 = DriveTicket.randomString(64)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        check(v.count == 64 && v.allSatisfy { allowed.contains($0) } && v != v2, "verifier 모양")
        check(DriveTicket.reversed("one.two.three") == "three.two.one", "되돌림 스킴 뒤집기")
        let form = String(data: DriveTicket.form(["b": "a b&c", "a": "x/y"]), encoding: .utf8)
        check(form == "a=x%2Fy&b=a%20b%26c", "폼 인코딩 \(form ?? "-")")

        // 경로 ↔ 이름
        for p in ["Saves/pokemon-resonance/save.json", "Saves/g/backups/2026-11-01-1030.json", "Prefs/web-pokerogue-net.json", "Covers/c-1.png"] {
            check(DriveShelf.path(fromName: DriveShelf.name(for: p)) == p && DriveShelf.safePath(p), "왕복 \(p)")
        }
        check(DriveShelf.name(for: "Saves/pokemon-resonance/save.json") == "Saves__pokemon-resonance__save.json", "Drive 이름")
        for bad in ["../x", "Saves/../a.json", "Other/x.json", "Saves/.hidden/save.json", "Saves", "Saves//x", "/Saves/a/save.json", "Saves/a:b/save.json", "Saves/a\\b/save.json"] {
            check(!DriveShelf.safePath(bad), "거부 \(bad)")
        }
        let long = String(repeating: "가", count: 50)
        check(DriveShelf.fit("device", long).map { $0.utf8.count + 6 <= 124 } == true, "appProperties 자르기")

        // 오류 분류
        let table: [(Error, IglooShelfError)] = [
            (DriveError.signedOut, .signedOut), (DriveError.notConfigured, .signedOut), (DriveError.quotaFull, .quotaFull),
            (DriveError.rateLimited, .other), (DriveError.changedRemotely, .other), (DriveError.http(500, nil), .other),
            (DriveError.tooLarge, .tooLarge), (IglooError.tooLarge, .tooLarge), (IglooError.badPayload, .other),
            (URLError(.notConnectedToInternet), .offline), (URLError(.networkConnectionLost), .offline), (URLError(.timedOut), .offline),
            (URLError(.cannotConnectToHost), .offline), (URLError(.badServerResponse), .other),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .quotaFull),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .quotaFull),
        ]
        for (e, want) in table { check(IglooShelfError.from(e) == want, "분류 \(e) → \(want)") }
        check(ICloudShelf(documents: URL(fileURLWithPath: NSTemporaryDirectory()), real: false).classify(URLError(.timedOut)) == .offline, "iCloud 분류")
        let quota = Data(#"{"error":{"errors":[{"domain":"usageLimits","reason":"storageQuotaExceeded"}],"code":403}}"#.utf8)
        check(DriveCounter.errorReason(quota) == "storageQuotaExceeded", "오류 본문 reason")
        let r308 = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 308, httpVersion: nil, headerFields: ["Range": "bytes=0-4194303"])!
        check(DriveCounter.rangeEnd(r308) == 4194303, "Range 끝")
        let f = DriveFile(["id": "abc", "name": "n", "size": "12", "md5Checksum": "ABCD", "modifiedTime": "2026-11-01T10:00:00.123Z", "appProperties": ["path": "Prefs/x.json", "n": 3]])
        check(f?.size == 12 && f?.md5 == "abcd" && f?.modifiedTime != nil && f?.appProperties == ["path": "Prefs/x.json"], "파일 메타 읽기")
        check(DriveFile(["name": "id 없음"]) == nil, "id 없는 파일 거부")
        check(Data("hello".utf8).md5Hex == "5d41402abc4b2a76b9719d911017c592", "MD5")

        // 선반 이전
        let suite = "bingsu.selftest.igloo"
        let cases: [(Bool?, String?, IglooShelfKind)] = [(true, nil, .icloud), (false, nil, .off), (nil, nil, .icloud), (false, "drive", .drive), (true, "bogus", .icloud)]
        for (legacy, existing, want) in cases {
            guard let d = UserDefaults(suiteName: suite) else { check(false, "suite"); break }
            d.removePersistentDomain(forName: suite)
            if let legacy { d.set(legacy, forKey: Igloo.legacyEnabledKey) }
            if let existing { d.set(existing, forKey: Igloo.backendKey) }
            let got = Igloo.migrateBackend(d)
            check(got == want && d.string(forKey: Igloo.backendKey) == want.rawValue, "이전 \(String(describing: legacy))/\(existing ?? "-") → \(got)")
            d.removePersistentDomain(forName: suite)
        }

        NSLog("[Igloo] selftest \(fails == 0 ? "ok" : "FAIL \(fails)") (\(checks)개)")
    }
}
#endif

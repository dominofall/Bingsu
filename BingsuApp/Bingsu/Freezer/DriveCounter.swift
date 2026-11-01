import Foundation

/// Drive 파일 하나의 메타데이터 (목록·올리기 응답). 값은 모두 클라우드에서 온 것이라 쓰는 쪽이 다시 검사한다
struct DriveFile: Equatable {
    var id: String
    var name: String
    var size: Int?
    var md5: String?
    var modifiedTime: Date?
    var appProperties: [String: String]

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = o["name"] as? String ?? ""
        // Drive 는 int64 를 문자열로 준다
        size = (o["size"] as? String).flatMap { Int($0) } ?? (o["size"] as? NSNumber)?.intValue
        md5 = (o["md5Checksum"] as? String)?.lowercased()
        modifiedTime = (o["modifiedTime"] as? String).flatMap(DriveCounter.parseDate)
        appProperties = (o["appProperties"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }
}

/// Drive REST v3 창구 ("카운터"). 모든 호출은 `Igloo.queue` 안에서 동기적으로 기다린다 (요청당 60초).
/// - 401: 토큰을 한 번 새로 받아 다시 · 403 storageQuotaExceeded: `.quotaFull`
/// - 403 rate limit·429·5xx: 1·2·4·8초(+난수 ≤1초) 기다리며 4번까지 · 404: 없음
/// - 5MB 넘는 올리기는 resumable(조각 4MB). 끊기면 `bytes */N` 로 위치를 물어 이어서, 세션은 다음 동기화까지 기억
final class DriveCounter: NSObject, URLSessionDataDelegate {
    static let timeout: TimeInterval = 60
    static let multipartLimit = 5 * 1024 * 1024
    /// 256KB 의 배수
    static let chunkSize = 4 * 1024 * 1024
    static let fileFields = "id,name,size,md5Checksum,modifiedTime,appProperties"

    let ticket: DriveTicket
    let base: URL

    init(ticket: DriveTicket, base: URL) {
        self.ticket = ticket; self.base = base
        super.init()
    }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Self.timeout
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// 토큰 교환·갱신·철회용 (본문 상한 없이 작은 JSON)
    static let plainSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static func sendPlain(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, URLResponse?, Error?)
        plainSession.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
        sem.wait()
        if let e = out.2 { throw e }
        guard let r = out.1 as? HTTPURLResponse else { throw DriveError.badResponse }
        return (out.0 ?? Data(), r)
    }

    // MARK: 요청 하나 (본문 상한)

    private final class Box {
        var data = Data()
        let limit: Int
        var response: HTTPURLResponse?
        var error: Error?
        var over = false
        let done = DispatchSemaphore(value: 0)
        init(limit: Int) { self.limit = limit }
    }
    private let lock = NSLock()
    private var boxes: [Int: Box] = [:]
    private func box(_ t: URLSessionTask) -> Box? { lock.lock(); defer { lock.unlock() }; return boxes[t.taskIdentifier] }

    /// 보내고 끝날 때까지 기다린다. 본문이 `limit` 를 넘으면(Content-Length 또는 받은 양) 끊고 `.tooLarge`
    func send(_ req: URLRequest, limit: Int = 8 * 1024 * 1024) throws -> (Data, HTTPURLResponse) {
        let task = session.dataTask(with: req)
        let b = Box(limit: limit)
        lock.lock(); boxes[task.taskIdentifier] = b; lock.unlock()
        task.resume()
        b.done.wait()
        lock.lock(); boxes[task.taskIdentifier] = nil; lock.unlock()
        if b.over { throw DriveError.tooLarge }
        if let e = b.error { throw e }
        guard let r = b.response else { throw DriveError.badResponse }
        return (b.data, r)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let b = box(dataTask) else { return completionHandler(.cancel) }
        b.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(b.limit) { b.over = true; return completionHandler(.cancel) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let b = box(dataTask) else { return }
        b.data.append(data)
        if b.data.count > b.limit { b.over = true; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let b = box(task) else { return }
        if !b.over { b.error = error }
        b.done.signal()
    }

    /// resumable 의 308(Resume Incomplete) 을 리디렉트로 따라가지 않는다
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(response.statusCode == 308 ? nil : request)
    }

    // MARK: 인증 · 재시도

    /// 토큰을 붙여 보내고 오류를 나눈다. `build` 는 재시도마다 새 요청을 만든다
    func call(limit: Int = 8 * 1024 * 1024, _ build: () throws -> URLRequest) throws -> (Data, HTTPURLResponse) {
        var refreshed = false
        var attempt = 0
        while true {
            var req = try build()
            req.setValue("Bearer \(try ticket.accessToken(forceRefresh: false))", forHTTPHeaderField: "Authorization")
            let (d, r) = try send(req, limit: limit)
            switch r.statusCode {
            case 200..<300, 308:
                return (d, r)
            case 401:
                if !refreshed { refreshed = true; _ = try ticket.accessToken(forceRefresh: true); continue }
                throw DriveError.signedOut
            case 404:
                throw DriveError.http(404, nil)
            default:
                let reason = Self.errorReason(d)
                if reason == "storageQuotaExceeded" { throw DriveError.quotaFull }
                let retry = r.statusCode == 429 || r.statusCode >= 500
                    || (r.statusCode == 403 && ["userRateLimitExceeded", "rateLimitExceeded"].contains(reason ?? ""))
                guard retry else { throw DriveError.http(r.statusCode, reason) }
                guard attempt < 4 else { throw DriveError.rateLimited }
                let wait = pow(2, Double(attempt)) + Double.random(in: 0...1)
                NSLog("[Drive] \(r.statusCode)\(reason.map { " \($0)" } ?? "") — \(String(format: "%.1f", wait))초 뒤 다시")
                Thread.sleep(forTimeInterval: wait)
                attempt += 1
            }
        }
    }

    /// `{"error":{"errors":[{"reason":"…"}]}}` 의 첫 reason
    static func errorReason(_ d: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let e = o["error"] as? [String: Any] else { return nil }
        return ((e["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (e["status"] as? String)
    }

    static func isNotFound(_ error: Error) -> Bool { (error as? DriveError) == .http(404, nil) }

    // MARK: 주소

    private func url(_ path: String, _ query: [String: String]) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }

    private func request(_ method: String, _ u: URL, body: Data? = nil, type: String? = nil) -> URLRequest {
        var r = URLRequest(url: u, timeoutInterval: Self.timeout)
        r.httpMethod = method
        r.httpBody = body
        if let type { r.setValue(type, forHTTPHeaderField: "Content-Type") }
        return r
    }

    private static func json(_ d: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw DriveError.badResponse }
        return o
    }

    // MARK: 호출

    /// appDataFolder 의 파일 전부 (페이지 끝까지)
    func listAll() throws -> [DriveFile] {
        var out: [DriveFile] = []
        var token: String?
        repeat {
            var q = ["spaces": "appDataFolder", "pageSize": "1000", "fields": "nextPageToken,files(\(Self.fileFields))"]
            if let token { q["pageToken"] = token }
            let (d, _) = try call { request("GET", url("drive/v3/files", q)) }
            let o = try Self.json(d)
            out += (o["files"] as? [[String: Any]] ?? []).compactMap(DriveFile.init)
            token = o["nextPageToken"] as? String
        } while token != nil && out.count < 100_000
        return out
    }

    /// 올리기 직전 재확인용. 없으면 nil
    func get(_ id: String) throws -> DriveFile? {
        do {
            let (d, _) = try call { request("GET", url("drive/v3/files/\(id)", ["fields": Self.fileFields])) }
            return DriveFile(try Self.json(d))
        } catch let error where Self.isNotFound(error) { return nil }
    }

    /// 없으면 nil. 본문이 `maxBytes` 를 넘으면 받다가 끊고 `.tooLarge`
    func download(_ id: String, maxBytes: Int) throws -> Data? {
        do { return try call(limit: maxBytes) { request("GET", url("drive/v3/files/\(id)", ["alt": "media"])) }.0 }
        catch let error where Self.isNotFound(error) { return nil }
    }

    func delete(_ id: String) throws {
        do { _ = try call { request("DELETE", url("drive/v3/files/\(id)", [:])) } }
        catch let error where Self.isNotFound(error) {}
    }

    /// 남은 공간 (bytes). 한도가 없는 계정이면 nil
    func freeBytes() throws -> Int64? {
        let (d, _) = try call { request("GET", url("drive/v3/about", ["fields": "storageQuota"])) }
        let q = try Self.json(d)["storageQuota"] as? [String: Any]
        guard let limit = (q?["limit"] as? String).flatMap({ Int64($0) }), let usage = (q?["usage"] as? String).flatMap({ Int64($0) }) else { return nil }
        return max(0, limit - usage)
    }

    func create(name: String, appProperties: [String: String], data: Data, modifiedTime: Date?, key: String) throws -> DriveFile {
        var meta: [String: Any] = ["name": name, "parents": ["appDataFolder"], "appProperties": appProperties]
        if let modifiedTime { meta["modifiedTime"] = Self.formatDate(modifiedTime) }
        return try upload(method: "POST", path: "upload/drive/v3/files", meta: meta, data: data, key: key)
    }

    func update(id: String, appProperties: [String: String], data: Data, modifiedTime: Date?, key: String) throws -> DriveFile {
        var meta: [String: Any] = ["appProperties": appProperties]
        if let modifiedTime { meta["modifiedTime"] = Self.formatDate(modifiedTime) }
        return try upload(method: "PATCH", path: "upload/drive/v3/files/\(id)", meta: meta, data: data, key: key)
    }

    private func upload(method: String, path: String, meta: [String: Any], data: Data, key: String) throws -> DriveFile {
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        if data.count <= Self.multipartLimit {
            let boundary = "bingsu-" + DriveTicket.randomString(24).filter { $0.isLetter || $0.isNumber }
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
            body.append(metaData)
            body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let (d, _) = try call {
                request(method, url(path, ["uploadType": "multipart", "fields": Self.fileFields]), body: body, type: "multipart/related; boundary=\(boundary)")
            }
            guard let f = DriveFile(try Self.json(d)) else { throw DriveError.badResponse }
            return f
        }
        return try resumable(method: method, path: path, metaData: metaData, data: data, key: key)
    }

    // MARK: resumable

    /// 이어 올리기 세션 (경로 + 내용 MD5 → 세션 주소). 같은 내용을 다음 동기화에서 다시 올리면 이어서 한다
    private var sessions: [String: URL] = [:]

    private func resumable(method: String, path: String, metaData: Data, data: Data, key: String) throws -> DriveFile {
        let total = data.count
        let sessionKey = key + "|" + data.md5Hex
        var offset = 0
        var uri = sessions[sessionKey]
        if let u = uri {
            switch try position(u, total: total) {
            case .done(let f): sessions[sessionKey] = nil; return f
            case .at(let n): offset = n; NSLog("[Drive] 이어 올리기 \(n)/\(total)")
            case .gone: uri = nil
            }
        }
        if uri == nil {
            let (_, r) = try call {
                var req = request(method, url(path, ["uploadType": "resumable", "fields": Self.fileFields]), body: metaData, type: "application/json; charset=UTF-8")
                req.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
                req.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
                return req
            }
            guard let loc = r.value(forHTTPHeaderField: "Location"), let u = URL(string: loc),
                  u.scheme == base.scheme, u.host == base.host || u.host?.hasSuffix(".googleapis.com") == true else { throw DriveError.badResponse }
            uri = u
            sessions[sessionKey] = u
            offset = 0
        }
        guard let uri else { throw DriveError.badResponse }
        var lost = 0
        while true {
            let end = min(offset + Self.chunkSize, total)
            let chunk = data.subdata(in: offset..<end)
            let result: (Data, HTTPURLResponse)
            do {
                result = try call {
                    var req = request("PUT", uri, body: chunk)
                    req.setValue("bytes \(offset)-\(end - 1)/\(total)", forHTTPHeaderField: "Content-Range")
                    return req
                }
            } catch {
                // 조각이 끊김: 서버가 어디까지 받았는지 물어 이어서 (1·2·4·8초 기다리며)
                guard IglooShelfError.from(error) == .offline || (error as? DriveError) == .rateLimited, lost < 4 else { throw error }
                Thread.sleep(forTimeInterval: pow(2, Double(lost)) + Double.random(in: 0...1))
                lost += 1
                NSLog("[Drive] 조각 끊김 — 위치 확인 (\(lost))")
                guard let p = try? position(uri, total: total) else { continue }
                switch p {
                case .done(let f): sessions[sessionKey] = nil; return f
                case .at(let n): offset = n; continue
                case .gone: sessions[sessionKey] = nil; throw error
                }
            }
            let (d, r) = result
            if r.statusCode == 308 {
                offset = Self.rangeEnd(r).map { $0 + 1 } ?? 0
                continue
            }
            sessions[sessionKey] = nil
            guard let f = DriveFile(try Self.json(d)) else { throw DriveError.badResponse }
            NSLog("[Drive] 이어 올리기 끝 (\(total / 1024)KB)")
            return f
        }
    }

    private enum Position { case done(DriveFile), at(Int), gone }

    /// `Content-Range: bytes */N` 로 받은 위치를 묻는다
    private func position(_ uri: URL, total: Int) throws -> Position {
        do {
            let (d, r) = try call {
                var req = request("PUT", uri, body: Data())
                req.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
                return req
            }
            if r.statusCode == 308 { return .at(Self.rangeEnd(r).map { $0 + 1 } ?? 0) }
            guard let f = DriveFile(try Self.json(d)) else { return .gone }
            return .done(f)
        } catch let e as DriveError {
            if case .http(let c, _) = e, c == 404 || c == 410 { return .gone }
            throw e
        }
    }

    /// `Range: bytes=0-4194303` 의 끝
    static func rangeEnd(_ r: HTTPURLResponse) -> Int? {
        guard let v = r.value(forHTTPHeaderField: "Range"), let dash = v.lastIndex(of: "-") else { return nil }
        return Int(v[v.index(after: dash)...])
    }

    // MARK: 시각

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }
    static func formatDate(_ d: Date) -> String { isoFrac.string(from: d) }
}

extension IglooShelfError {
    /// Drive 오류 표 (research §3.1): 엔진·자가 테스트가 같이 쓴다
    static func from(_ error: Error) -> IglooShelfError {
        if let e = error as? DriveError {
            switch e {
            case .signedOut, .notConfigured: return .signedOut
            case .quotaFull: return .quotaFull
            case .tooLarge: return .tooLarge
            case .rateLimited, .changedRemotely, .denied, .badResponse, .http: return .other
            }
        }
        return .common(error)
    }
}

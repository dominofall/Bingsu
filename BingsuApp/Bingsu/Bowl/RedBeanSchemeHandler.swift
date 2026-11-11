import Foundation
import WebKit

/// 팥빙수(새 모양 Electron) 스킴 핸들러: `bingsu-app://game/<가상 경로>`. 명세 docs/engines/IMPLEMENTATION-electron.md §3·§4.
///
/// | 가상 경로 | 실제 | 권한 |
/// |---|---|---|
/// | `/app/…` | 게임 폴더 | 읽기만 (대소문자 무시로 다시 찾기, SchemeTree) |
/// | `/userData/…` | `Saves/<dataPathApp>/userData/` | 읽기·쓰기 |
/// | 그 밖 | 없음 | 읽기 404, 쓰기 403 |
///
/// `Saves/<dataPathApp>/save.json` 은 빙수(얼음틀·냉동실)가 쓰는 이름이라 게임의 userData 는 반드시 한 단계 아래에 둔다.
/// 쓰기는 PLAN 8.2 의 두 번째 예외: `/userData/` 아래, 조각마다 1~128바이트·숨김 아님, 깊이 4 이하만 PUT·DELETE·MOVE·MKCOL.
/// 한도는 파일 하나 `Freezer.maxBytes`, 게임 하나 파일 1,000개·합계 512MB (넘으면 507 → 흉내 계층에서 ENOSPC).
/// 같은 출처만 쓰므로 `Access-Control-Allow-Origin` 은 넣지 않는다. 쓰기는 한 줄 큐에서 차례로 처리한다.
final class RedBeanSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "bingsu-app"
    static let origin = "bingsu-app://game"
    static let userDataFolder = "userData"
    static let maxFiles = GreenTeaSchemeHandler.maxSaveFiles
    static let maxTotalBytes = GreenTeaSchemeHandler.maxSaveTotalBytes
    static let maxDepth = 4
    static let maxSegmentBytes = 128

    private let tree: SchemeTree
    /// `Saves/<dataPathApp>/userData/` (없으면 만든다)
    let userData: URL
    private let userDataReal: String
    private let label: String
    private var stopped: Set<ObjectIdentifier> = []
    private let readQueue = DispatchQueue(label: "bingsu.redbean.read", qos: .userInitiated, attributes: .concurrent)
    private let writeQueue = DispatchQueue(label: "bingsu.redbean.write", qos: .userInitiated)
    private let lock = NSLock()
    private var denied = 0
    private var written = 0

    /// `saves` 는 `Freezer(dish:).directory`. `label` 은 로그용 (게임 id)
    init(gameRoot: URL, saves: URL, label: String) {
        tree = SchemeTree(root: gameRoot)
        userData = saves.appendingPathComponent(Self.userDataFolder, isDirectory: true).standardizedFileURL
        try? FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        userDataReal = userData.resolvingSymlinksInPath().standardizedFileURL.path
        self.label = label
    }

    // MARK: 경로 규칙 (자가 테스트가 같은 함수를 부른다)

    enum Target: Equatable {
        /// 게임 폴더 안 (읽기만)
        case app([String])
        /// userData 안 (빈 배열 = userData 폴더 자체)
        case userData([String])
        /// 그 밖 (`/appData`·`/tmp`·`/home` …)
        case none
    }

    static func segments(_ url: URL) -> [String]? {
        guard url.scheme == scheme, url.host == "game", url.port == nil, url.user == nil else { return nil }
        return SchemeTree.segments(path: url.path.removingPercentEncoding ?? url.path)
    }

    static func target(_ parts: [String]) -> Target {
        guard let first = parts.first else { return .none }
        if first == "app" { return .app(Array(parts.dropFirst())) }
        if first == userDataFolder { return .userData(Array(parts.dropFirst())) }
        return .none
    }

    /// userData 안 경로로 쓸 수 있는 조각인가 (1~128바이트, 숨김 아님, 깊이 4 이하)
    static func writablePath(_ rest: [String]) -> Bool {
        !rest.isEmpty && rest.count <= maxDepth
            && rest.allSatisfy { !$0.isEmpty && $0.utf8.count <= maxSegmentBytes && !$0.hasPrefix(".") && $0 != ".." }
    }

    /// 이 메서드·경로를 쓰기로 받는가
    static func writeAllowed(method: String, _ t: Target) -> Bool {
        guard ["PUT", "DELETE", "MOVE", "MKCOL"].contains(method), case .userData(let rest) = t else { return false }
        return writablePath(rest)
    }

    /// 이 PUT 뒤에도 한도 안인가. 같은 경로를 덮어쓰면 그 파일 크기는 빼고 센다
    static func fitsQuota(existing: [String: Int], path: String, size: Int) -> Bool {
        guard size <= Freezer.maxBytes else { return false }
        let total = existing.values.reduce(0, +) - (existing[path] ?? 0) + size
        let count = existing.count + (existing[path] == nil ? 1 : 0)
        return count <= maxFiles && total <= maxTotalBytes
    }

    /// userData 안 모든 파일 (상대 경로 → 크기)
    private func sizes() -> [String: Int] {
        var out: [String: Int] = [:]
        guard let e = FileManager.default.enumerator(at: userData, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return out }
        let base = userDataReal
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let p = u.resolvingSymlinksInPath().standardizedFileURL.path
            guard p.hasPrefix(base + "/") else { continue }
            out[String(p.dropFirst(base.count + 1))] = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return out
    }

    /// userData 안 실제 경로. 링크를 따라 밖으로 나가면 nil
    private func userFile(_ rest: [String]) -> URL? {
        let f = rest.reduce(userData) { $0.appendingPathComponent($1) }.standardizedFileURL
        // 아직 없는 파일은 부모 폴더로 확인한다
        let probe = FileManager.default.fileExists(atPath: f.path) ? f : f.deletingLastPathComponent()
        let real = probe.resolvingSymlinksInPath().standardizedFileURL.path
        guard real == userDataReal || real.hasPrefix(userDataReal + "/") else { return nil }
        return f
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        let request = task.request
        let method = (request.httpMethod ?? "GET").uppercased()
        let respond: (URLResponse, Data?) -> Void = { [weak self] resp, data in
            DispatchQueue.main.async {
                guard let self else { return }
                guard !self.stopped.contains(id) else { self.stopped.remove(id); return }
                task.didReceive(resp)
                if let data { task.didReceive(data) }
                task.didFinish()
            }
        }
        let url = request.url
        guard let url, let parts = Self.segments(url) else {
            if method != "GET" && method != "HEAD" { deny(method, url?.path ?? "?") }
            respond(SchemeFile.status(method == "GET" || method == "HEAD" ? 404 : 403, url: url), nil); return
        }
        let t = Self.target(parts)
        switch method {
        case "GET", "HEAD":
            readQueue.async { [weak self] in
                guard let self else { return }
                let (r, d) = self.read(t, url: url, request: request, head: method == "HEAD")
                respond(r, d)
            }
        case "PUT", "DELETE", "MOVE", "MKCOL":
            guard Self.writeAllowed(method: method, t) else {
                deny(method, "/" + parts.joined(separator: "/"))
                respond(SchemeFile.status(403, url: url), nil); return
            }
            // 본문은 지금 읽는다 (스트림은 이 요청이 살아 있을 때만 읽을 수 있다)
            let body = method == "PUT" ? SchemeTree.readBody(request).data : nil
            writeQueue.async { [weak self] in
                guard let self else { return }
                respond(self.write(method, t, url: url, request: request, body: body), nil)
            }
        default:
            respond(SchemeFile.status(405, url: url), nil)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    // MARK: 읽기

    private func read(_ t: Target, url: URL, request: URLRequest, head: Bool) -> (URLResponse, Data?) {
        switch t {
        case .none: return (SchemeFile.status(404, url: url), nil)
        case .app(let rest):
            guard let f = tree.locate(rest) else { return (SchemeFile.status(404, url: url), nil) }
            return SchemeTree.serve(f, url: url, request: request, head: head, mime: Self.mime(for: f), cors: false)
        case .userData(let rest):
            guard let f = userFile(rest) else { return (SchemeFile.status(404, url: url), nil) }
            return SchemeTree.serve(f, url: url, request: request, head: head, mime: Self.mime(for: f), cors: false)
        }
    }

    private static func mime(for file: URL) -> String {
        file.pathExtension.lowercased() == "wasm" ? "application/wasm" : SchemeFile.mime(for: file)
    }

    // MARK: 쓰기 (userData 만)

    private func write(_ method: String, _ t: Target, url: URL, request: URLRequest, body: Data?) -> URLResponse {
        guard case .userData(let rest) = t, let file = userFile(rest) else { return SchemeFile.status(403, url: url) }
        let fm = FileManager.default
        try? fm.createDirectory(at: userData, withIntermediateDirectories: true)
        let rel = rest.joined(separator: "/")
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: file.path, isDirectory: &isDir)
        let parentOK: Bool = {
            var d: ObjCBool = false
            return fm.fileExists(atPath: file.deletingLastPathComponent().path, isDirectory: &d) && d.boolValue
        }()
        switch method {
        case "PUT":
            guard let body else { return SchemeFile.status(400, url: url) }
            guard parentOK else { return SchemeFile.status(409, url: url) }          // 부모 폴더 없음 → ENOENT
            guard !(exists && isDir.boolValue) else { return SchemeFile.status(409, url: url, headers: ["X-Bingsu-Error": "EISDIR"]) }
            // 쓰기는 한 줄 큐에서만 하므로 세고 쓰는 사이에 폴더가 바뀌지 않는다
            guard Self.fitsQuota(existing: sizes(), path: rel, size: body.count) else {
                NSLog("[RedBean] write PUT \(rel.prefix(120)) over quota \(body.count)B (\(label))")
                return SchemeFile.status(507, url: url)
            }
            do { try body.write(to: file, options: .atomic) } catch {
                NSLog("[RedBean] write PUT \(rel.prefix(120)) failed: \(error.localizedDescription)")
                return SchemeFile.status(500, url: url)
            }
            lock.lock(); written += 1; let n = written; lock.unlock()
            // 저장마다 쓰는 게임이 많아 앞의 50번과 그 뒤 100번마다만 남긴다
            if n <= 50 || n % 100 == 0 { NSLog("[RedBean] write PUT \(rel.prefix(120)) \(body.count)B n=\(n)") }
            return SchemeFile.status(201, url: url)
        case "DELETE":
            guard exists else { return SchemeFile.status(404, url: url) }
            if isDir.boolValue {
                let recursive = request.value(forHTTPHeaderField: "X-Bingsu-Recursive") == "1"
                let empty = ((try? fm.contentsOfDirectory(atPath: file.path)) ?? []).isEmpty
                guard recursive || empty else { return SchemeFile.status(409, url: url, headers: ["X-Bingsu-Error": "ENOTEMPTY"]) }
            }
            do { try fm.removeItem(at: file) } catch { return SchemeFile.status(500, url: url) }
            NSLog("[RedBean] write DELETE \(rel.prefix(120))")
            return SchemeFile.status(204, url: url)
        case "MKCOL":
            if exists { return SchemeFile.status(405, url: url) }                    // 이미 있음 → EEXIST
            guard parentOK else { return SchemeFile.status(409, url: url) }
            do { try fm.createDirectory(at: file, withIntermediateDirectories: false) } catch { return SchemeFile.status(500, url: url) }
            NSLog("[RedBean] write MKCOL \(rel.prefix(120))")
            return SchemeFile.status(201, url: url)
        case "MOVE":
            // 목적지도 userData 안 같은 규칙 (`Destination: bingsu-app://game/userData/<경로>` 또는 `/userData/<경로>`)
            let raw = request.value(forHTTPHeaderField: "Destination") ?? ""
            let destParts: [String]?
            if let u = URL(string: raw), u.scheme != nil { destParts = Self.segments(u) }
            else { destParts = SchemeTree.segments(path: raw.removingPercentEncoding ?? raw) }
            guard let dp = destParts, case .userData(let to) = Self.target(dp), Self.writablePath(to), let dst = userFile(to) else {
                deny("MOVE→", raw)
                return SchemeFile.status(403, url: url)
            }
            guard exists else { return SchemeFile.status(404, url: url) }
            var d: ObjCBool = false
            guard fm.fileExists(atPath: dst.deletingLastPathComponent().path, isDirectory: &d), d.boolValue else { return SchemeFile.status(409, url: url) }
            do {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.moveItem(at: file, to: dst)
            } catch { return SchemeFile.status(500, url: url) }
            NSLog("[RedBean] write MOVE \(rel.prefix(120)) → \(to.joined(separator: "/").prefix(120))")
            return SchemeFile.status(201, url: url)
        default:
            return SchemeFile.status(403, url: url)
        }
    }

    private func deny(_ method: String, _ path: String) {
        lock.lock(); denied += 1; let n = denied; lock.unlock()
        // 게임별 집계: 앞의 20번과 그 뒤 100번마다
        if n <= 20 || n % 100 == 0 { NSLog("[RedBean] write denied \(method) \(path.prefix(160)) (\(label) n=\(n))") }
    }
}

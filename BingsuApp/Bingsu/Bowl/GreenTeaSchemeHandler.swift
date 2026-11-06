import Foundation
import WebKit

/// 녹차빙수(RPG Maker MV·MZ) 스킴 핸들러: `bingsu-mv://game/<경로>` → `<게임 루트>/<경로>`.
///
/// - 읽기(GET·HEAD): 게임 루트 안 파일. Windows 에서 만든 게임은 코드와 파일 이름 대소문자가 다른 일이 많아,
///   정확한 경로가 없으면 조각마다 폴더 목록에서 대소문자 무시로 다시 찾는다(결과는 캐시). `..`·절대 경로·숨김·심볼릭 링크는 404.
///   HEAD 에는 `X-Bingsu-Kind: file|dir`·`X-Bingsu-Mtime`(ms) 머리글(NW.js 흉내의 `fs.statSync`), 폴더 GET 은 이름 배열 JSON(`readdirSync`).
/// - 쓰기: PLAN 8.2 "웹 게임에 파일 API 를 주지 않는다" 의 유일한 예외. 루트 기준 `save/` 아래 정해진 이름만 PUT·DELETE·MOVE,
///   `save` 자체만 MKCOL 을 받고, 실제 파일은 저장 데이터 폴더(`Saves/<dataPathApp>/`)에 쓴다. 그 밖은 403 + 로그.
///   `save/` 의 읽기도 저장 데이터 폴더에서 한다(게임 폴더의 save/ 는 보이지 않는다).
/// 쓰기는 한 줄 큐에서 차례로 처리한다(MZ 는 `파일_` 로 옮기고 → 새로 쓰고 → `_` 지움).
final class GreenTeaSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "bingsu-mv"
    static let origin = "bingsu-mv://game"
    /// 저장 파일 이름 규칙 (명세 §2). 임시 파일(끝 `_`)·MV 백업(`.bak`)까지
    static let saveNamePattern = #"^[A-Za-z0-9_.-]{1,64}\.(rpgsave|rmmzsave)(_|\.bak)?$"#
    /// 게임 하나의 저장 파일 한도. 파일마다 `Freezer.maxBytes` 를 지켜도 이름을 바꿔 가며 쓰면 기기 공간을 다 쓸 수 있다.
    /// 슬롯이 많은 플러그인도 넉넉한 값이다 (슬롯 100개 × 저장·임시·백업 3개)
    static let maxSaveFiles = 1000
    static let maxSaveTotalBytes = 512 * 1024 * 1024

    private let root: URL
    private let rootReal: String
    private let saves: URL
    private let label: String
    private var stopped: Set<ObjectIdentifier> = []
    private let readQueue = DispatchQueue(label: "bingsu.greentea.read", qos: .userInitiated, attributes: .concurrent)
    private let writeQueue = DispatchQueue(label: "bingsu.greentea.write", qos: .userInitiated)
    private let lock = NSLock()
    /// 폴더 경로 → (소문자 이름 → 실제 이름)
    private var listings: [String: [String: String]] = [:]
    private var denied = 0
    private var bodyVia: String?

    /// `saves` 는 `Freezer(dish:).directory`. `label` 은 로그용 (게임 id)
    init(gameRoot: URL, saves: URL, label: String) {
        root = gameRoot.standardizedFileURL
        rootReal = gameRoot.resolvingSymlinksInPath().standardizedFileURL.path
        self.saves = saves
        self.label = label
    }

    // MARK: 경로 규칙 (자가 테스트가 같은 함수를 부른다)

    enum Target: Equatable {
        /// 게임 루트 안 상대 경로 조각
        case game([String])
        /// 저장 데이터 폴더 자체 (`save/`)
        case saveDir
        /// 저장 데이터 폴더 안 파일 이름 (규칙을 지난 것)
        case saveFile(String)
        /// `save/` 아래지만 규칙에 안 맞는 이름
        case saveOther
    }

    /// URL → 경로 조각. 우리 출처가 아니거나 `..`·`\`·`:`·NUL·숨김 조각이 있으면 nil
    static func segments(_ url: URL) -> [String]? {
        guard url.scheme == scheme, url.host == "game", url.port == nil, url.user == nil else { return nil }
        let raw = url.path.removingPercentEncoding ?? url.path
        return segments(path: raw)
    }

    static func segments(path raw: String) -> [String]? {
        if raw.contains("\\") || raw.contains(":") || raw.contains("\0") { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains(where: { $0 == "." || $0 == ".." || $0.hasPrefix(".") }) { return nil }
        return parts
    }

    static func target(_ parts: [String]) -> Target {
        guard let first = parts.first, first.lowercased() == "save" else { return .game(parts) }
        if parts.count == 1 { return .saveDir }
        guard parts.count == 2, isSaveName(parts[1]) else { return .saveOther }
        return .saveFile(parts[1])
    }

    static func isSaveName(_ name: String) -> Bool {
        name.range(of: saveNamePattern, options: .regularExpression) != nil
    }

    /// 이 메서드·경로를 쓰기로 받는가 (MKCOL 은 save 자체만, 나머지는 저장 파일만)
    static func writeAllowed(method: String, _ t: Target) -> Bool {
        switch (method, t) {
        case ("MKCOL", .saveDir): return true
        case ("PUT", .saveFile), ("DELETE", .saveFile), ("MOVE", .saveFile): return true
        default: return false
        }
    }

    /// 이 PUT 뒤에도 한도 안인가. 같은 이름을 덮어쓰면 그 파일 크기는 빼고 센다
    static func fitsQuota(existing: [String: Int], name: String, size: Int) -> Bool {
        let total = existing.values.reduce(0, +) - (existing[name] ?? 0) + size
        let count = existing.count + (existing[name] == nil ? 1 : 0)
        return count <= maxSaveFiles && total <= maxSaveTotalBytes
    }

    /// 저장 폴더의 저장 파일 이름 → 크기
    private func saveSizes() -> [String: Int] {
        var out: [String: Int] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: saves.path)) ?? [] where Self.isSaveName(name) {
            let f = saves.appendingPathComponent(name)
            out[name] = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return out
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
            respond(SchemeFile.status(404, url: url), nil); return
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
                deny(method, parts.joined(separator: "/"))
                respond(SchemeFile.status(403, url: url), nil); return
            }
            // 본문은 지금 읽는다 (스트림은 이 요청이 살아 있을 때만 읽을 수 있다)
            let body = method == "PUT" ? readBody(request) : nil
            writeQueue.async { [weak self] in
                guard let self else { return }
                respond(self.write(method, t, url: url, request: request, body: body), nil)
            }
        case "OPTIONS":
            respond(SchemeFile.status(204, url: url, headers: ["Access-Control-Allow-Origin": "*"]), nil)
        default:
            respond(SchemeFile.status(405, url: url), nil)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    // MARK: 읽기

    private func read(_ t: Target, url: URL, request: URLRequest, head: Bool) -> (URLResponse, Data?) {
        let file: URL
        switch t {
        case .saveOther: return (SchemeFile.status(404, url: url), nil)
        case .saveDir:
            return dirResponse(saves, url: url, head: head, filter: Self.isSaveName)
        case .saveFile(let name):
            file = saves.appendingPathComponent(name)
        case .game(let parts):
            guard let f = locate(parts.isEmpty ? ["index.html"] : parts) else { return (SchemeFile.status(404, url: url), nil) }
            file = f
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) else { return (SchemeFile.status(404, url: url), nil) }
        if isDir.boolValue { return dirResponse(file, url: url, head: head, filter: { !$0.hasPrefix(".") }) }
        let mtime = Self.mtime(file)
        if head {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (SchemeFile.status(200, url: url, headers: ["X-Bingsu-Kind": "file", "X-Bingsu-Mtime": mtime, "Content-Length": "\(size)",
                                                                "Content-Type": Self.mime(for: file), "Access-Control-Allow-Origin": "*"]), nil)
        }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return (SchemeFile.status(404, url: url), nil) }
        return SchemeFile.response(url: url, data: data, mime: Self.mime(for: file), request: request,
                                   extraHeaders: ["X-Bingsu-Kind": "file", "X-Bingsu-Mtime": mtime])
    }

    private func dirResponse(_ dir: URL, url: URL, head: Bool, filter: (String) -> Bool) -> (URLResponse, Data?) {
        let headers = ["X-Bingsu-Kind": "dir", "X-Bingsu-Mtime": Self.mtime(dir), "Content-Type": "application/json",
                       "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]
        if head { return (SchemeFile.status(200, url: url, headers: headers), nil) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter(filter).sorted()
        let data = (try? JSONSerialization.data(withJSONObject: names)) ?? Data("[]".utf8)
        return (SchemeFile.status(200, url: url, headers: headers.merging(["Content-Length": "\(data.count)"]) { $1 }), data)
    }

    /// 게임 루트 안에서 경로를 찾는다. 정확한 경로가 없으면 조각마다 대소문자 무시로 다시 찾는다.
    /// 심볼릭 링크를 따라 루트 밖으로 나가면 nil
    func locate(_ parts: [String]) -> URL? {
        let fm = FileManager.default
        var cur = root
        let exact = parts.reduce(root) { $0.appendingPathComponent($1) }
        if fm.fileExists(atPath: exact.path) {
            cur = exact
        } else {
            for p in parts {
                let next = cur.appendingPathComponent(p)
                if fm.fileExists(atPath: next.path) { cur = next; continue }
                guard let real = listing(cur)[p.lowercased()] else { return nil }
                cur = cur.appendingPathComponent(real)
            }
        }
        let real = cur.resolvingSymlinksInPath().standardizedFileURL.path
        guard real == rootReal || real.hasPrefix(rootReal + "/") else { return nil }
        return cur
    }

    private func listing(_ dir: URL) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let hit = listings[dir.path] { return hit }
        var map: [String: String] = [:]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !n.hasPrefix(".") {
            let k = n.lowercased()
            if map[k] == nil || n < map[k]! { map[k] = n }   // 대소문자만 다른 두 파일이면 늘 같은 쪽
        }
        listings[dir.path] = map
        return map
    }

    private static func mime(for file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        // 암호화 리소스는 게임이 스스로 푼다
        if ["rpgmvp", "rpgmvo", "rpgmvm"].contains(ext) || ext.hasSuffix("_") { return "application/octet-stream" }
        if ext == "wasm" { return "application/wasm" }
        return SchemeFile.mime(for: file)
    }

    private static func mtime(_ u: URL) -> String {
        let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(timeIntervalSince1970: 0)
        return String(Int64((d.timeIntervalSince1970 * 1000).rounded()))
    }

    // MARK: 쓰기 (저장 데이터 폴더만)

    private func write(_ method: String, _ t: Target, url: URL, request: URLRequest, body: Data?) -> URLResponse {
        let fm = FileManager.default
        try? fm.createDirectory(at: saves, withIntermediateDirectories: true)
        let ok = ["Access-Control-Allow-Origin": "*"]
        switch (method, t) {
        case ("MKCOL", .saveDir):
            return SchemeFile.status(201, url: url, headers: ok)
        case ("PUT", .saveFile(let name)):
            guard let body else {
                NSLog("[Bowl] mv write PUT \(name) — 본문 없음")
                return SchemeFile.status(400, url: url)
            }
            guard body.count <= Freezer.maxBytes else {
                NSLog("[Bowl] mv write PUT \(name) too large \(body.count)")
                return SchemeFile.status(413, url: url)
            }
            // 쓰기는 한 줄 큐에서만 하므로 세고 쓰는 사이에 폴더가 바뀌지 않는다
            guard Self.fitsQuota(existing: saveSizes(), name: name, size: body.count) else {
                NSLog("[Bowl] mv write PUT \(name) over quota (\(label))")
                return SchemeFile.status(507, url: url)
            }
            let dest = saves.appendingPathComponent(name)
            do { try body.write(to: dest, options: .atomic) } catch {
                NSLog("[Bowl] mv write PUT \(name) failed: \(error.localizedDescription)")
                return SchemeFile.status(500, url: url)
            }
            NSLog("[Bowl] mv write PUT \(name) \(body.count)B")
            return SchemeFile.status(201, url: url, headers: ok)
        case ("DELETE", .saveFile(let name)):
            let f = saves.appendingPathComponent(name)
            guard fm.fileExists(atPath: f.path) else { return SchemeFile.status(404, url: url) }
            do { try fm.removeItem(at: f) } catch { return SchemeFile.status(500, url: url) }
            NSLog("[Bowl] mv write DELETE \(name)")
            return SchemeFile.status(204, url: url, headers: ok)
        case ("MOVE", .saveFile(let name)):
            // 목적지도 같은 규칙 안 (`Destination: bingsu-mv://game/save/<이름>` 또는 `/save/<이름>`)
            let raw = request.value(forHTTPHeaderField: "Destination") ?? ""
            let destParts: [String]?
            if let u = URL(string: raw), u.scheme != nil { destParts = Self.segments(u) }
            else { destParts = Self.segments(path: raw.removingPercentEncoding ?? raw) }
            guard let dp = destParts, case .saveFile(let to) = Self.target(dp) else {
                deny("MOVE→", raw)
                return SchemeFile.status(403, url: url)
            }
            let src = saves.appendingPathComponent(name), dst = saves.appendingPathComponent(to)
            guard fm.fileExists(atPath: src.path) else { return SchemeFile.status(404, url: url) }
            do {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.moveItem(at: src, to: dst)
            } catch { return SchemeFile.status(500, url: url) }
            NSLog("[Bowl] mv write MOVE \(name) → \(to)")
            return SchemeFile.status(201, url: url, headers: ok)
        default:
            return SchemeFile.status(403, url: url)
        }
    }

    /// PUT 본문: `httpBody`, 없으면 `httpBodyStream`. 어느 길로 왔는지 처음 한 번 남긴다 (명세 §2 "본문 수신 확인")
    private func readBody(_ request: URLRequest) -> Data? {
        var via = "none"
        var out: Data?
        if let b = request.httpBody {
            via = "httpBody"; out = b
        } else if let s = request.httpBodyStream {
            via = "stream"
            s.open(); defer { s.close() }
            var d = Data()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                d.append(buf, count: n)
                if d.count > Freezer.maxBytes { break }
            }
            out = d
        }
        lock.lock()
        let first = bodyVia == nil
        if first { bodyVia = via }
        lock.unlock()
        if first { NSLog("[Bowl] mv put body via=\(via) bytes=\(out?.count ?? -1)") }
        return out
    }

    private func deny(_ method: String, _ path: String) {
        lock.lock(); denied += 1; let n = denied; lock.unlock()
        // 게임별 집계: 앞의 20번과 그 뒤 100번마다
        if n <= 20 || n % 100 == 0 { NSLog("[Bowl] mv write denied \(method) \(path.prefix(160)) (\(label) n=\(n))") }
    }
}

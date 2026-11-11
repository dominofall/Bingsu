import Foundation
import UniformTypeIdentifiers

/// 스킴 핸들러가 같이 쓰는 파일 응답: MIME 고르기와 Range(206·416) 처리.
/// `PokemonSchemeHandler`(옛 Electron)·`GreenTeaSchemeHandler`(MV·MZ)·`RedBeanSchemeHandler`(새 Electron)가 같은 규칙으로 파일을 내준다.
enum SchemeFile {
    static func mime(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "html": return "text/html; charset=utf-8"
        case "json": return "application/json"
        case "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "ttf": return "font/ttf"
        default:
            return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    /// 파일 내용 응답. `Range: bytes=a-b` 면 206(범위 밖이면 416), 아니면 200. HEAD 는 본문 없이 같은 머리글
    /// `cors == false` 면 `Access-Control-Allow-Origin` 을 넣지 않는다 (같은 출처만 쓰는 새 Electron 경로)
    static func response(url: URL, data: Data, mime: String, request: URLRequest,
                         extraHeaders: [String: String] = [:], cors: Bool = true) -> (HTTPURLResponse, Data?) {
        var headers: [String: String] = [
            "Content-Type": mime,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache",
        ]
        if cors { headers["Access-Control-Allow-Origin"] = "*" }
        headers.merge(extraHeaders) { _, new in new }
        // Range 처리 (오디오/비디오 스트리밍)
        if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let total = data.count
            let start = Int(spec.first ?? "") ?? 0
            let end = (spec.count > 1 ? Int(spec[1]) : nil) ?? (total - 1)
            guard start <= end, start < total else {
                headers["Content-Range"] = "bytes */\(total)"
                return (HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: headers)!, nil)
            }
            let clampedEnd = min(end, total - 1)
            let slice = data.subdata(in: start..<(clampedEnd + 1))
            headers["Content-Range"] = "bytes \(start)-\(clampedEnd)/\(total)"
            headers["Content-Length"] = "\(slice.count)"
            return (HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!, slice)
        }
        headers["Content-Length"] = "\(data.count)"
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!,
                request.httpMethod == "HEAD" ? nil : data)
    }

    /// 본문 없는 상태 응답 (403·404·405 …)
    static func status(_ code: Int, url: URL?, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url ?? URL(string: "about:blank")!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

/// 게임 폴더 하나를 읽기 전용으로 내주는 공용 부품 (`GreenTeaSchemeHandler`·`RedBeanSchemeHandler`).
/// - 경로 조각: `..`·`\`·`:`·NUL·숨김 조각은 받지 않는다 (`segments`).
/// - 찾기: 정확한 경로가 없으면 조각마다 폴더 목록에서 대소문자 무시로 다시 찾는다(결과는 캐시). iOS 실기기는 대소문자를 가린다.
///   심볼릭 링크를 따라 루트 밖으로 나가면 nil.
/// - 응답: HEAD 에 `X-Bingsu-Kind: file|dir`·`X-Bingsu-Mtime`(ms), 폴더 GET 은 이름 배열 JSON.
final class SchemeTree {
    let root: URL
    let rootReal: String
    private let lock = NSLock()
    /// 폴더 경로 → (소문자 이름 → 실제 이름)
    private var listings: [String: [String: String]] = [:]

    init(root: URL) {
        self.root = root.standardizedFileURL
        rootReal = root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 경로 글자 → 조각. `..`·`\`·`:`·NUL·숨김 조각이 있으면 nil
    static func segments(path raw: String) -> [String]? {
        if raw.contains("\\") || raw.contains(":") || raw.contains("\0") { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains(where: { $0 == "." || $0 == ".." || $0.hasPrefix(".") }) { return nil }
        return parts
    }

    /// 루트 안에서 경로를 찾는다. 정확한 경로가 없으면 조각마다 대소문자 무시로 다시 찾는다
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

    static func mtime(_ u: URL) -> String {
        let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(timeIntervalSince1970: 0)
        return String(Int64((d.timeIntervalSince1970 * 1000).rounded()))
    }

    /// 있는 파일·폴더 하나를 내준다 (없으면 404). 폴더는 `filter` 를 지난 이름만
    static func serve(_ file: URL, url: URL, request: URLRequest, head: Bool, mime: String, cors: Bool,
                      filter: (String) -> Bool = { !$0.hasPrefix(".") }) -> (URLResponse, Data?) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) else { return (SchemeFile.status(404, url: url), nil) }
        if isDir.boolValue { return dirResponse(file, url: url, head: head, cors: cors, filter: filter) }
        let mtime = Self.mtime(file)
        if head {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var h = ["X-Bingsu-Kind": "file", "X-Bingsu-Mtime": mtime, "Content-Length": "\(size)", "Content-Type": mime]
            if cors { h["Access-Control-Allow-Origin"] = "*" }
            return (SchemeFile.status(200, url: url, headers: h), nil)
        }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return (SchemeFile.status(404, url: url), nil) }
        return SchemeFile.response(url: url, data: data, mime: mime, request: request,
                                   extraHeaders: ["X-Bingsu-Kind": "file", "X-Bingsu-Mtime": mtime], cors: cors)
    }

    static func dirResponse(_ dir: URL, url: URL, head: Bool, cors: Bool, filter: (String) -> Bool) -> (URLResponse, Data?) {
        var headers = ["X-Bingsu-Kind": "dir", "X-Bingsu-Mtime": mtime(dir), "Content-Type": "application/json", "Cache-Control": "no-cache"]
        if cors { headers["Access-Control-Allow-Origin"] = "*" }
        if head { return (SchemeFile.status(200, url: url, headers: headers), nil) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter(filter).sorted()
        let data = (try? JSONSerialization.data(withJSONObject: names)) ?? Data("[]".utf8)
        return (SchemeFile.status(200, url: url, headers: headers.merging(["Content-Length": "\(data.count)"]) { $1 }), data)
    }

    /// PUT 본문: `httpBody`, 없으면 `httpBodyStream`(최대 `limit` + 1 바이트까지만 읽는다). 어느 길이었는지도 돌려준다
    static func readBody(_ request: URLRequest, limit: Int = Freezer.maxBytes) -> (data: Data?, via: String) {
        if let b = request.httpBody { return (b, "httpBody") }
        guard let s = request.httpBodyStream else { return (nil, "none") }
        s.open(); defer { s.close() }
        var d = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            d.append(buf, count: n)
            if d.count > limit { break }
        }
        return (d, "stream")
    }
}

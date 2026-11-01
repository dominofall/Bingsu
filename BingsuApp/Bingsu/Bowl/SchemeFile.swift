import Foundation
import UniformTypeIdentifiers

/// 스킴 핸들러가 같이 쓰는 파일 응답: MIME 고르기와 Range(206·416) 처리.
/// `PokemonSchemeHandler`(Electron)와 `GreenTeaSchemeHandler`(MV·MZ)가 같은 규칙으로 파일을 내준다.
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
    static func response(url: URL, data: Data, mime: String, request: URLRequest,
                         extraHeaders: [String: String] = [:]) -> (HTTPURLResponse, Data?) {
        var headers: [String: String] = [
            "Content-Type": mime,
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
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

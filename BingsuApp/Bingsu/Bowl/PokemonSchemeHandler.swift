import Foundation
import WebKit

/// Electron main.cjs 의 `pokemon://game/...` 프로토콜을 WKWebView 에서 재현한다.
/// storage.cjs resolveGameFile 규칙: assets/ 는 <game>/assets, 그 외는 <game>/dist.
/// 미디어 재생을 위해 Range 요청(206)을 지원한다 (SchemeFile).
final class PokemonSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pokemon"
    static let origin = "pokemon://game"

    private let root: URL
    private var stopped: Set<ObjectIdentifier> = []
    private let queue = DispatchQueue(label: "bingsu.scheme", qos: .userInitiated, attributes: .concurrent)

    init(gameRoot: URL) { self.root = gameRoot }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        let request = task.request
        queue.async { [weak self] in
            guard let self else { return }
            let respond: (URLResponse, Data?) -> Void = { resp, data in
                DispatchQueue.main.async {
                    guard !self.stopped.contains(id) else { self.stopped.remove(id); return }
                    task.didReceive(resp)
                    if let data { task.didReceive(data) }
                    task.didFinish()
                }
            }
            guard let url = request.url, ["GET", "HEAD"].contains(request.httpMethod ?? "GET") else {
                respond(HTTPURLResponse(url: request.url ?? URL(string: Self.origin)!, statusCode: 405, httpVersion: nil, headerFields: nil)!, nil); return
            }
            guard let file = self.resolve(url) else {
                respond(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!, nil); return
            }
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
                respond(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil); return
            }
            let (resp, body) = SchemeFile.response(url: url, data: data, mime: SchemeFile.mime(for: file), request: request)
            respond(resp, body)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    /// storage.cjs resolveGameFile 이식
    func resolve(_ url: URL) -> URL? {
        guard url.scheme == Self.scheme, url.host == "game", url.port == nil, url.user == nil else { return nil }
        var rel = url.path.removingPercentEncoding ?? url.path
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty { rel = "index.html" }
        if rel.contains("\\") || rel.contains(":") || rel.contains("\0") { return nil }
        if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return nil }
        let isAsset = rel.hasPrefix("assets/")
        let base = root.appendingPathComponent(isAsset ? "assets" : "dist", isDirectory: true).standardizedFileURL
        var file = base.appendingPathComponent(isAsset ? String(rel.dropFirst(7)) : rel).standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        if !FileManager.default.fileExists(atPath: file.path),
           rel.range(of: #"^assets/Graphics/Characters/Followers( shiny)?/[^/]+\.png$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            file = base.appendingPathComponent("Graphics/Characters/Followers/000.png")
        }
        return file
    }
}

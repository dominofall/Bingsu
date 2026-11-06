import Foundation

/// 사용자가 주소로 추가한 웹 게임 목록. `Documents/WebGames.json` 에 저장한다.
/// 기본 제공 웹 게임(포켓로그·포켓본크)은 코드에 있고, 여기는 사용자가 넣은 것만.
struct WebGameEntry: Codable, Equatable {
    var id: String       // "web-<호스트-경로 slug>"
    var title: String
    var url: String      // https 만

    static let idPrefix = "web-"
    var dish: Dish? {
        guard let u = URL(string: url) else { return nil }
        return Dish(id: id, title: title, recipe: .webURL, location: u, dataPathApp: id)
    }
}

enum WebGames {
    enum AddError: LocalizedError {
        case emptyTitle, badURL, notHTTPS, hasCredentials, localHost, duplicate(String)
        var errorDescription: String? {
            switch self {
            case .emptyTitle: return "이름을 적어 주세요"
            case .badURL: return "주소 형식이 아니에요. 예: https://example.com/game"
            case .notHTTPS: return "https:// 로 시작하는 주소만 넣을 수 있어요"
            case .hasCredentials: return "주소에 아이디·비밀번호를 넣을 수 없어요"
            case .localHost: return "이 주소는 쓸 수 없어요"
            case .duplicate(let t): return "이미 있는 게임이에요 · \(t)"
            }
        }
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WebGames.json")
    }

    static func load() -> [WebGameEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([WebGameEntry].self, from: data) else { return [] }
        // 파일이 손으로 고쳐졌을 수 있으니 다시 검증해 통과한 것만
        return list.filter { (try? normalize($0.url, allowLocal: DevEnv["BINGSU_ALLOW_HTTP"] == "1")) != nil && !$0.title.isEmpty && $0.id.hasPrefix(WebGameEntry.idPrefix) }
    }

    static func save(_ list: [WebGameEntry]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 주소 검증: https, 호스트 있음, 인증 정보 없음, 로컬/사설 주소 아님. 통과하면 정리된 URL.
    /// `allowLocal`: 디버그 검증용(로컬 HTTP 서버)으로만 http 와 localhost·사설 주소를 허용한다. 내려받기의 `BINGSU_ALLOW_HTTP=1` 에서만 켠다.
    static func normalize(_ raw: String, allowLocal: Bool = false) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let host = c.host?.lowercased(), !host.isEmpty, let url = c.url else { throw AddError.badURL }
        let scheme = c.scheme?.lowercased()
        guard scheme == "https" || (allowLocal && scheme == "http") else { throw AddError.notHTTPS }
        guard c.user == nil, c.password == nil else { throw AddError.hasCredentials }
        if allowLocal { return url }
        guard host.contains("."), !host.hasPrefix("0."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), host != "localhost",
              !host.hasPrefix("127."), !host.hasPrefix("10."), !host.hasPrefix("192.168."), !host.hasPrefix("169.254."),
              !(host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? -1)) else {
            throw AddError.localHost
        }
        return url
    }

    static func makeEntry(title: String, url rawURL: String, existing: [Dish]) throws -> WebGameEntry {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 40 else { throw AddError.emptyTitle }
        let url = try normalize(rawURL, allowLocal: DevEnv["BINGSU_ALLOW_HTTP"] == "1")
        if let dup = existing.first(where: { $0.isRemote && $0.location.host?.lowercased() == url.host?.lowercased() && $0.location.path == url.path }) {
            throw AddError.duplicate(dup.title)
        }
        let base = WebGameEntry.idPrefix + Delivery.slug((url.host ?? "") + url.path)
        var id = base, n = 2
        while existing.contains(where: { $0.id == id }) { id = "\(base)-\(n)"; n += 1 }
        return WebGameEntry(id: id, title: t, url: url.absoluteString)
    }
}

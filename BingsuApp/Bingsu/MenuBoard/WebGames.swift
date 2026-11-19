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

/// 주소로 넣는 게임의 주소 속임수 검사 (보안 3차). 막지는 않고, 넣기 전에 실제 주소와 의심 이유를 보여 주고 묻는다.
/// - 닮은 글자: 영문이 아닌 글자(키릴 `о` 등)가 든 주소, 그런 주소의 영문 표기(`xn--…`)
/// - 닮은 주소: 아는 게임·큰 로그인 업체 주소와 한두 글자만 다르거나(`pokeroque.net`), 그 이름을 다른 주소 안에 넣은 것(`pokerogue.net.example.com`)
enum HostCheck {
    /// 사칭 대상이 되기 쉬운 주소. 이 주소 자체나 그 하위 주소는 괜찮다
    static var known: [String] {
        Dish.KnownWeb.allCases.map(\.host) + ["google.com", "apple.com", "icloud.com", "discord.com", "github.com", "facebook.com",
                                              "microsoft.com", "naver.com", "kakao.com", "paypal.com", "steampowered.com"]
    }

    /// 웹 게임을 많이 올리는 공개 호스팅. 하위 주소는 주인이 저마다 달라 이름 비교를 하지 않는다 (github.io 가 github.com 과 닮았다고 걸리지 않게)
    static let hostingSuffixes = ["github.io", "gitlab.io", "itch.io", "itch.zone", "netlify.app", "vercel.app", "pages.dev", "web.app",
                                  "firebaseapp.com", "glitch.me", "neocities.org", "newgrounds.com", "gamejolt.net"]

    static func warnings(for rawHost: String) -> [String] {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var out: [String] = []
        if host.unicodeScalars.contains(where: { !$0.isASCII }) || host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
            out.append("영문이 아닌 글자가 섞인 주소예요. 모양이 닮은 글자로 다른 사이트를 흉내 낼 수 있어요.")
        }
        let hosted = hostingSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
        for k in known where !hosted && host != k && !host.hasSuffix("." + k) {
            let name = String(k.split(separator: ".").first ?? "")
            let base = registrable(host)
            if name.count >= 5 && host.contains(name) {
                out.append("\(k) 이름을 넣은 다른 사이트예요 (실제: \(base))."); break
            }
            if distance(skeleton(base), skeleton(k)) <= (k.count >= 10 ? 2 : 1) {
                out.append("\(k) 와 철자만 조금 다른 사이트예요 (실제: \(base)). 철자를 확인해 주세요."); break
            }
        }
        return out
    }

    /// 끝의 두 칸 (예: a.b.example.com → example.com). 공개 접미사 목록은 쓰지 않는 근사값
    static func registrable(_ host: String) -> String {
        let parts = host.split(separator: ".")
        return parts.suffix(2).joined(separator: ".")
    }

    /// 헷갈리는 글자를 하나로 모은다 (0→o, 1·i→l, rn→m, vv→w, q→g)
    static func skeleton(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("rn", "m"), ("vv", "w"), ("0", "o"), ("1", "l"), ("i", "l"), ("q", "g"), ("-", "")] { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    /// 편집 거리 (바꾸기·넣기·빼기 한 번 = 1)
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }; if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[y.count]
    }
}

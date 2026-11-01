import Foundation

/// 폴더 안의 파일을 보고 어떤 빙수(엔진)인지 판별한다.
enum RecipeDetector {
    static func detect(folder: URL) -> Dish.Recipe {
        let fm = FileManager.default
        func has(_ rel: String) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(rel).path) }

        // Electron: 이미 풀린 asar (dist/index.html + assets/) 또는 풀기 전 app.asar
        if has("dist/index.html") && has("assets") { return .electron }
        if has("resources/app.asar") { return .electron }
        // mkxp-z / RPG Maker XP·VX·VX Ace: mkxp.json, 암호화 아카이브, ini 의 Scripts=, Data/Scripts.* (RGSSProbe)
        if has("mkxp.json") { return .mkxp }
        let rgss = RGSSProbe.probe(folder: folder)
        if rgss.version != nil && rgss.hasScripts { return .mkxp }
        // RPG Maker MV/MZ (NW.js): package.json main · www/ · 맨 위 index.html + 엔진 코어 (MVMZProbe).
        // package.nw 는 Delivery 가 먼저 풀어 둔다. NW.js 흔적만 있고 MV/MZ 가 아니면 지원하지 않음
        if MVMZProbe.findRoot(folder) != nil { return .rpgMakerMV }
        if has("package.nw") || has("nw.pak") { return .unknown }
        if has("index.html") { return .electron }
        return .unknown
    }

    /// 제목과 dataPathApp 추정 (mkxp.json, package.json, Game.ini 순)
    static func describe(folder: URL, recipe: Dish.Recipe) -> (title: String, dataPathApp: String) {
        let fallback = folder.lastPathComponent
        switch recipe {
        case .mkxp:
            if let json = try? String(contentsOf: folder.appendingPathComponent("mkxp.json"), encoding: .utf8) {
                let title = jsonString(json, key: "windowTitle") ?? iniTitle(folder) ?? fallback
                let data = jsonString(json, key: "dataPathApp") ?? title
                return (title, data)
            }
            let t = iniTitle(folder) ?? fallback
            return (t, t)
        case .electron:
            // 저장 폴더 이름은 package.json 의 name, 제목은 dist/index.html 의 <title>
            var dataPath = fallback
            if let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["name"] as? String, !name.isEmpty { dataPath = name }
            // 닫는 태그는 여는 태그 뒤에서만 찾는다 (거꾸로 놓인 HTML 이면 범위가 뒤집혀 앱이 멈춘다)
            if let html = try? String(contentsOf: folder.appendingPathComponent("dist/index.html"), encoding: .utf8),
               let r = html.range(of: "<title>"), let e = html.range(of: "</title>", range: r.upperBound..<html.endIndex) {
                let t = html[r.upperBound..<e.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return (String(t.prefix(200)), dataPath) }
            }
            return (dataPath, dataPath)
        case .rpgMakerMV:
            guard let p = MVMZProbe.probe(folder: folder) else { return (fallback, fallback) }
            return (p.gameTitle, p.dataPathApp)
        default:
            return (fallback, fallback)
        }
    }

    /// 주석이 섞인 JSON에서 "key": "value" 한 줄만 뽑는다 (mkxp.json은 // 주석이 있어 JSONSerialization이 못 읽음)
    private static func jsonString(_ text: String, key: String) -> String? {
        // split(separator: "\n") 은 CRLF("\r\n" 이 한 글자)를 못 나눈다 — Windows 에서 만든 mkxp.json 은 CRLF 인 경우가 있다
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("//"), t.hasPrefix("\"\(key)\"") else { continue }
            guard let q1 = t.range(of: ":") else { continue }
            let rest = t[q1.upperBound...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("\"") else { continue }
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { continue }
            return String(body[..<end])
        }
        return nil
    }

    /// ini 의 Title= (UTF-8·CP949·Shift-JIS, CRLF, exe 이름을 따라 바뀐 ini 도 — RGSSProbe)
    private static func iniTitle(_ folder: URL) -> String? {
        RGSSProbe.probe(folder: folder).title
    }
}

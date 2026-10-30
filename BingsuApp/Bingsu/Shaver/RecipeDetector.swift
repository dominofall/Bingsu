import Foundation

/// 폴더 안의 파일을 보고 어떤 빙수(엔진)인지 판별한다.
enum RecipeDetector {
    static func detect(folder: URL) -> Dish.Recipe {
        let fm = FileManager.default
        func has(_ rel: String) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(rel).path) }

        // Electron: 이미 풀린 asar (dist/index.html + assets/) 또는 풀기 전 app.asar
        if has("dist/index.html") && has("assets") { return .electron }
        if has("resources/app.asar") { return .electron }
        // mkxp-z / RPG Maker XP
        if has("mkxp.json") || (has("Game.ini") && has("Data/Scripts.rxdata")) { return .mkxp }
        // RPG Maker MV/MZ (NW.js)
        if has("package.nw") || has("nw.pak") || has("www/index.html") { return .rpgMakerMV }
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

    private static func iniTitle(_ folder: URL) -> String? {
        guard let ini = try? String(contentsOf: folder.appendingPathComponent("Game.ini"), encoding: .utf8) else { return nil }
        for line in ini.split(whereSeparator: \.isNewline) where line.hasPrefix("Title=") {
            return String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

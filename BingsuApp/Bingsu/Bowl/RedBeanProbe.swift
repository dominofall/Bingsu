import Foundation

/// 팥빙수(Electron) 게임 폴더 판별 (순수 함수: 파일을 글자로 훑기만 하고 게임 코드를 실행하지 않는다).
/// 명세 docs/engines/IMPLEMENTATION-electron.md §2.
///
/// - 옛 모양(`dist/index.html` + `assets/`, 레조넌스)은 여기서 다루지 않는다(`isLegacyShape`). 그 게임은 지금처럼 `ElectronInfo` 없이 연다.
/// - 새 모양: `package.json` 이 있고 `main`(없으면 `index.js`)이 가리키는 JS 파일이 있으면 Electron 앱으로 본다.
///   메인 스크립트의 `loadFile`·`loadURL` 에서 시작 화면을, 화면 쪽 코드의 이벤트 듣기 수에서 조작 방식을 고른다.
enum RedBeanProbe {
    enum Failure: Error, Equatable {
        /// 시작 화면(`*.html`)을 찾지 못함
        case noEntry
        /// `loadURL('https://…')` 처럼 온라인 주소를 여는 앱
        case remoteURL
    }

    struct Result: Equatable, Sendable {
        var info: ElectronInfo
        var title: String
        /// `package.json` 의 `name` (저장 폴더 이름)
        var packageName: String?
        var version: String?
        /// 조작 방식 판단에 쓴 수 (로그·자가 테스트용)
        var keyListeners: Int
        var pointerListeners: Int
        var gamepad: Bool
        /// 게임이 듣는 키 (`info.keys` 와 같음, 로그용)
        var keys: [String] { info.keys ?? [] }
    }

    /// 옛 Electron 모양 (레조넌스): 풀린 asar 의 `dist/index.html` + `assets/`
    static func isLegacyShape(_ folder: URL) -> Bool {
        exists(folder, "dist/index.html") && exists(folder, "assets")
    }

    /// `package.json` 의 `main`(없으면 `index.js`)이 가리키는 JS 파일이 있는가. 있으면 그 상대 경로
    static func mainScript(_ folder: URL) -> String? {
        guard let pkg = MVMZProbe.json(folder, "package.json") else { return nil }
        let raw = (pkg["main"] as? String) ?? "index.js"
        guard var m = cleanRelative(raw) else { return nil }
        // Node 는 `main: "main"` 이면 main.js 를 찾는다
        if !exists(folder, m) || isDirectory(folder, m) {
            if exists(folder, m + ".js") { m += ".js" }
            else if exists(folder, m + "/index.js") { m += "/index.js" }
            else { return nil }
        }
        let ext = (m as NSString).pathExtension.lowercased()
        guard ["js", "cjs", "mjs"].contains(ext) else { return nil }
        return m
    }

    /// 새 모양 Electron 앱인가 (옛 모양이 아니고 메인 스크립트가 있음)
    static func looksLikeApp(_ folder: URL) -> Bool {
        !isLegacyShape(folder) && mainScript(folder) != nil
    }

    /// 새 모양 Electron 앱을 읽는다. 앱이 아니면 nil, 앱인데 열 수 없으면 `.failure`
    static func probe(folder: URL) -> Swift.Result<Result, Failure>? {
        guard !isLegacyShape(folder), let main = mainScript(folder) else { return nil }
        let pkg = MVMZProbe.json(folder, "package.json") ?? [:]
        let mainText = text(folder, main) ?? ""
        let mainDir = (main as NSString).deletingLastPathComponent

        // 시작 화면: loadFile·loadURL 안의 .html 글자 → 폴더별 index.html
        var remote = false
        var entry: String?
        search: for lits in loadCalls(mainText) {
            for lit in lits {
                if lit.hasPrefix("http://") || lit.hasPrefix("https://") {
                    if lit.hasPrefix("http://localhost") || lit.hasPrefix("http://127.0.0.1") { continue }   // 개발용 서버 주소
                    remote = true; continue
                }
                guard let rel = htmlPath(lit) else { continue }
                // path.join(__dirname, '..', 'web', 'index.html') 처럼 조각으로 나뉜 것은 이어 붙여 본다 (게임 폴더 밖은 안 됨)
                let joined = lits.count > 1 ? lits.joined(separator: "/") : nil
                let tries = [joined.flatMap { normalize(join(mainDir, $0)) }, joined.flatMap { normalize($0) }, rel, join(mainDir, rel)].compactMap { $0 }
                if let hit = tries.first(where: { exists(folder, $0) && !isDirectory(folder, $0) }) { entry = hit; break search }
            }
        }
        if entry == nil {
            let fallbacks = [join(mainDir, "index.html"), "index.html"] + ["dist", "build", "public", "app", "src", "renderer"].map { "\($0)/index.html" }
            entry = fallbacks.first { exists(folder, $0) }
            // 온라인 주소만 여는 앱은 로컬 index.html 이 있어도 원격으로 본다 (loadFile 이 없음)
            if remote, !mainText.contains("loadFile") { entry = nil }
        }
        guard let entry else { return .failure(remote ? .remoteURL : .noEntry) }

        // 화면 쪽 설정 (정적 힌트, 실행 때 BrowserWindow 의 webPreferences 로 다시 맞춘다)
        let prefs = webPreferences(mainText)
        var preload: String?
        if let p = prefs.preload {
            preload = [normalize(join(mainDir, p)), normalize(p)].compactMap { $0 }.first { exists(folder, $0) && !isDirectory(folder, $0) }
        }

        // 조작 방식: 화면 쪽 .js·.html 의 이벤트 듣기 수
        let counts = listenerCounts(folder, skip: main)
        let pointer = !counts.gamepad && counts.pointer > 0 && counts.keys * 5 <= counts.pointer

        // 네이티브 애드온 (.node): 가져오기는 하되 이름을 적어 둔다
        let addons = files(folder, maxCount: 20_000).filter { $0.lowercased().hasSuffix(".node") }.prefix(20).map { $0 }

        var title = (pkg["productName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty, let html = text(folder, entry, limit: 2 * 1024 * 1024) { title = htmlTitle(html) ?? "" }
        let name = (pkg["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = name ?? "" }
        if title.isEmpty { title = folder.lastPathComponent }

        let info = ElectronInfo(main: main, entry: entry, inputStyle: pointer ? .pointer : .pad,
                                nodeIntegration: prefs.nodeIntegration, preload: preload, nativeAddons: addons,
                                keys: StrawKeys.top(counts.keyNames))
        return .success(Result(info: info, title: String(title.prefix(200)), packageName: (name?.isEmpty ?? true) ? nil : name,
                               version: (pkg["version"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               keyListeners: counts.keys, pointerListeners: counts.pointer, gamepad: counts.gamepad))
    }

    // MARK: 글자 훑기

    /// `loadFile(…)`·`loadURL(…)` 괄호 안의 따옴표 글자들 (앞에서부터)
    static func loadTargets(_ js: String) -> [String] { loadCalls(js).flatMap { $0 } }

    /// `..` 를 풀어 게임 폴더 안 상대 경로로. 폴더 밖으로 나가면 nil
    static func normalize(_ raw: String) -> String? {
        var out: [String] = []
        for part in raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init) {
            if part == "." || part.isEmpty { continue }
            if part == ".." { if out.isEmpty { return nil }; out.removeLast(); continue }
            out.append(part)
        }
        return out.isEmpty ? nil : cleanRelative(out.joined(separator: "/"))
    }

    /// 호출마다의 따옴표 글자들
    static func loadCalls(_ js: String) -> [[String]] {
        var out: [[String]] = []
        let call = try! NSRegularExpression(pattern: #"\.load(File|URL)\s*\(([^;\n]{0,300})"#)
        let lit = try! NSRegularExpression(pattern: #"['"`]([^'"`]{1,260})['"`]"#)
        let ns = js as NSString
        for m in call.matches(in: js, range: NSRange(location: 0, length: ns.length)) {
            let args = ns.substring(with: m.range(at: 2))
            let a = args as NSString
            out.append(lit.matches(in: args, range: NSRange(location: 0, length: a.length)).map { a.substring(with: $0.range(at: 1)) })
        }
        return out
    }

    /// 따옴표 글자 하나를 상대 html 경로로 (`file://${__dirname}/index.html` → `index.html`). html 이 아니면 nil
    static func htmlPath(_ lit: String) -> String? {
        var s = lit
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        guard s.lowercased().hasSuffix(".html") || s.lowercased().hasSuffix(".htm") else { return nil }
        s = s.replacingOccurrences(of: #"^file:/*"#, with: "", options: .regularExpression)
        // 템플릿 조각(${__dirname} 등)은 지운다
        s = s.replacingOccurrences(of: #"\$\{[^}]*\}"#, with: "", options: .regularExpression)
        return cleanRelative(s)
    }

    /// `webPreferences` 의 nodeIntegration·preload (글자로만, 못 읽으면 기본값 = 둘 다 없음)
    static func webPreferences(_ js: String) -> (nodeIntegration: Bool, preload: String?) {
        let node = js.range(of: #"nodeIntegration\s*:\s*true"#, options: .regularExpression) != nil
        var preload: String?
        let re = try! NSRegularExpression(pattern: #"preload\s*:\s*([^\n}]{1,200})"#)
        let ns = js as NSString
        if let m = re.firstMatch(in: js, range: NSRange(location: 0, length: ns.length)) {
            let expr = ns.substring(with: m.range(at: 1))
            // 따옴표 글자들을 처음 .js 로 끝나는 것까지 이어 붙인다 (path.join(__dirname, '..', 'pre', 'preload.js') → ../pre/preload.js)
            let lit = try! NSRegularExpression(pattern: #"['"`]([^'"`]{1,200})['"`]"#)
            let e = expr as NSString
            var parts: [String] = []
            for l in lit.matches(in: expr, range: NSRange(location: 0, length: e.length)) {
                let piece = e.substring(with: l.range(at: 1)).replacingOccurrences(of: #"\$\{[^}]*\}"#, with: "", options: .regularExpression)
                parts.append(piece)
                if piece.lowercased().hasSuffix(".js") || piece.lowercased().hasSuffix(".cjs") { preload = parts.joined(separator: "/"); break }
            }
        }
        return (node, preload)
    }

    struct Counts: Equatable {
        var keys = 0, pointer = 0, gamepad = false
        /// 게임이 비교하는 키 이름(code)별 나온 수 (터치 조작 §10)
        var keyNames: [String: Int] = [:]
    }

    /// 화면 쪽 코드의 이벤트 듣기 수. `node_modules`·숨김·메인 스크립트는 빼고, 큰 파일(4MB 넘음)은 건너뛴다
    static func listenerCounts(_ folder: URL, skip main: String) -> Counts {
        var c = Counts()
        let keyRe = try! NSRegularExpression(pattern: #"addEventListener\s*\(\s*['"`]key(down|up|press)['"`]|\bonkey(down|up|press)\s*="#)
        let ptrRe = try! NSRegularExpression(pattern: #"addEventListener\s*\(\s*['"`](click|dblclick|contextmenu|wheel|mouse[a-z]+|pointer[a-z]+)['"`]|\bon(click|dblclick|contextmenu|mouse[a-z]+|pointer[a-z]+)\s*="#)
        for rel in files(folder, maxCount: 5000) where rel != main {
            let ext = (rel as NSString).pathExtension.lowercased()
            guard ["js", "html", "htm", "cjs", "mjs"].contains(ext), let s = text(folder, rel, limit: 4 * 1024 * 1024) else { continue }
            let r = NSRange(location: 0, length: (s as NSString).length)
            let k = keyRe.numberOfMatches(in: s, range: r)
            c.keys += k
            c.pointer += ptrRe.numberOfMatches(in: s, range: r)
            StrawKeys.count(in: s, listensKeys: k > 0 || s.contains("'keydown'") || s.contains("\"keydown\""), into: &c.keyNames)
            if !c.gamepad, s.contains("getGamepads") || s.contains("gamepadconnected") { c.gamepad = true }
        }
        return c
    }

    static func htmlTitle(_ html: String) -> String? {
        guard let r = html.range(of: "<title>", options: .caseInsensitive),
              let e = html.range(of: "</title>", options: .caseInsensitive, range: r.upperBound..<html.endIndex) else { return nil }
        let t = html[r.upperBound..<e.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: 경로

    /// 게임 폴더 안 상대 경로로 정리. `..`·숨김 조각·절대 경로·`:` 는 nil
    static func cleanRelative(_ raw: String) -> String? {
        var m = raw.replacingOccurrences(of: "\\", with: "/")
        while m.hasPrefix("./") { m.removeFirst(2) }
        while m.hasPrefix("/") { m.removeFirst() }
        let parts = m.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !m.contains(":"), !m.contains("\0"),
              !parts.contains(where: { $0 == ".." || $0.hasPrefix(".") }) else { return nil }
        return parts.joined(separator: "/")
    }

    private static func join(_ dir: String, _ rel: String) -> String { dir.isEmpty ? rel : dir + "/" + rel }

    private static func exists(_ base: URL, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: base.appendingPathComponent(rel).path)
    }

    private static func isDirectory(_ base: URL, _ rel: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(rel).path, isDirectory: &d) && d.boolValue
    }

    private static func text(_ base: URL, _ rel: String, limit: Int = 8 * 1024 * 1024) -> String? {
        let url = base.appendingPathComponent(rel)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit,
              let d = try? Data(contentsOf: url) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    /// 게임 폴더 안 파일 상대 경로 (숨김·node_modules 아래는 뺌, 많으면 앞에서 자름)
    private static func files(_ folder: URL, maxCount: Int) -> [String] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let base = folder.standardizedFileURL.path
        var out: [String] = []
        for case let u as URL in e {
            if u.lastPathComponent == "node_modules" { e.skipDescendants(); continue }
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(base + "/") else { continue }
            out.append(String(p.dropFirst(base.count + 1)))
            if out.count >= maxCount { break }
        }
        return out
    }
}

/// 가져올 때 정해 bingsu.json 에 적는 Electron 정보 (새 모양만. 옛 모양 레조넌스는 nil)
struct ElectronInfo: Hashable, Sendable {
    enum InputStyle: String, Sendable { case pad, pointer }
    /// 메인 스크립트 (게임 폴더 기준 상대 경로)
    var main: String
    /// 시작 화면 (게임 폴더 기준 상대 경로)
    var entry: String
    var inputStyle: InputStyle
    /// 글자로 읽은 webPreferences.nodeIntegration (실행 때 BrowserWindow 가 다시 알려 준다)
    var nodeIntegration = false
    /// 글자로 읽은 preload 스크립트 (상대 경로)
    var preload: String?
    /// 게임 안의 네이티브 애드온(.node) 이름. 실행 때 require 하면 compat 기록
    var nativeAddons: [String] = []
    /// 게임 코드가 듣는 키(`KeyboardEvent.code`, 많이 나온 순 12개까지). nil = 이 판별 전에 가져온 게임 (터치 조작 §10)
    var keys: [String]?

    var manifest: [String: Any] {
        var m: [String: Any] = ["main": main, "entry": entry, "inputStyle": inputStyle.rawValue, "nodeIntegration": nodeIntegration]
        if let preload { m["preload"] = preload }
        if !nativeAddons.isEmpty { m["nativeAddons"] = nativeAddons }
        if let keys { m["keys"] = keys }
        return m
    }

    init(main: String, entry: String, inputStyle: InputStyle, nodeIntegration: Bool = false, preload: String? = nil, nativeAddons: [String] = [],
         keys: [String]? = nil) {
        self.main = main; self.entry = entry; self.inputStyle = inputStyle
        self.nodeIntegration = nodeIntegration; self.preload = preload; self.nativeAddons = nativeAddons; self.keys = keys
    }

    /// bingsu.json 의 `electron`. 경로가 게임 폴더 밖을 가리키면 버린다
    init?(manifest m: [String: Any]) {
        guard let main = (m["main"] as? String).flatMap(RedBeanProbe.cleanRelative),
              let entry = (m["entry"] as? String).flatMap(RedBeanProbe.cleanRelative) else { return nil }
        let preload = (m["preload"] as? String).flatMap(RedBeanProbe.cleanRelative)
        self.init(main: main, entry: entry, inputStyle: (m["inputStyle"] as? String).flatMap(InputStyle.init) ?? .pad,
                  nodeIntegration: m["nodeIntegration"] as? Bool ?? false, preload: preload,
                  nativeAddons: (m["nativeAddons"] as? [String] ?? []).prefix(20).map { String($0.prefix(200)) },
                  keys: StrawKeys.sanitize(m["keys"] as? [Any]))
    }
}

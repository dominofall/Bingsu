import Foundation

/// RPG Maker MV·MZ 게임 폴더 판별 (순수 함수: 파일을 읽기만 하고 아무것도 실행하지 않는다).
///
/// 게임 루트(`index.html` 이 있는 폴더)는 셋 중 하나:
/// (a) `package.json` 의 `main` 이 가리키는 파일의 폴더, (b) `www/index.html` + `www/js/`, (c) 맨 위 `index.html` + 엔진 코어 + `data/System.json`.
/// 엔진은 `js/rmmz_core.js` 가 있으면 MZ, `js/rpg_core.js` 면 MV.
enum MVMZProbe {
    struct Result: Equatable, Sendable {
        var engine: MVMZInfo.Engine
        /// 게임 폴더 기준 상대 경로 (`""` 또는 `www` 등)
        var root: String
        var gameTitle: String
        /// MZ `System.json` 의 `advanced.gameId` (MZ 전용, 없으면 nil)
        var gameId: Int?
        /// `package.json` 의 `name` (MV/MZ 기본값이면 nil)
        var packageName: String?
        var packageVersion: String?
        var encryptedImages: Bool
        var encryptedAudio: Bool
        /// 32글자 16진수 (암호화 배포본만)
        var encryptionKey: String?
        /// 타이틀 그림 이름 (`img/titles1/<이름>`)
        var title1Name: String?

        var info: MVMZInfo {
            MVMZInfo(engine: engine, root: root, gameTitle: gameTitle, encryptedImages: encryptedImages, encryptedAudio: encryptedAudio)
        }

        /// 저장 폴더 이름: MZ 는 gameId 가 있으면 `mz-<gameId>`, 아니면 package.json name → System.json gameTitle 순.
        /// 업데이트해도 바뀌지 않는 값이어야 한다 (`Dish.folderName` 이 한 단계 폴더 이름으로 고친다)
        var dataPathApp: String {
            if engine == .mz, let id = gameId { return "mz-\(id)" }
            if let n = packageName { return n }
            return gameTitle
        }
    }

    /// MV·MZ 프로젝트 기본 package.json 이름. 게임마다 같아서 저장 폴더 이름으로 쓰면 서로 섞인다
    static let genericPackageNames: Set<String> = ["kadokawa/rpgmv", "rmmz-game", "rmmv-game", "rpgmv", "rpgmz", "game", "nw", "nwjs"]

    static func probe(folder: URL) -> Result? {
        guard let root = findRoot(folder) else { return nil }
        let base = root.isEmpty ? folder : folder.appendingPathComponent(root, isDirectory: true)
        let mz = exists(base, "js/rmmz_core.js")
        let mv = exists(base, "js/rpg_core.js")
        // 코어 파일 이름이 없으면(드물게 하나로 합친 배포) System.json 의 advanced 로 MZ 를 가린다
        let system = json(base, "data/System.json")
        let advanced = system?["advanced"] as? [String: Any]
        let engine: MVMZInfo.Engine = mz ? .mz : mv ? .mv : (advanced != nil ? .mz : .mv)

        let pkg = json(folder, "package.json") ?? json(base, "package.json")
        var pkgName = (pkg?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = pkgName, n.isEmpty || genericPackageNames.contains(n.lowercased()) { pkgName = nil }
        let windowTitle = ((pkg?["window"] as? [String: Any])?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var title = (system?["gameTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { title = windowTitle ?? "" }
        if title.isEmpty { title = folder.lastPathComponent }

        let gameId = (advanced?["gameId"] as? NSNumber)?.intValue
        let key = (system?["encryptionKey"] as? String).flatMap { k -> String? in
            let t = k.trimmingCharacters(in: .whitespaces)
            return t.count == 32 && t.allSatisfy(\.isHexDigit) ? t.lowercased() : nil
        }
        let t1 = (system?["title1Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Result(engine: engine, root: root, gameTitle: String(title.prefix(200)), gameId: gameId == 0 ? nil : gameId,
                      packageName: pkgName, packageVersion: pkg?["version"] as? String,
                      encryptedImages: system?["hasEncryptedImages"] as? Bool ?? false,
                      encryptedAudio: system?["hasEncryptedAudio"] as? Bool ?? false,
                      encryptionKey: key, title1Name: t1)
    }

    /// 게임 루트(상대 경로). MV·MZ 가 아니면 nil
    static func findRoot(_ folder: URL) -> String? {
        // (a) package.json main
        if let pkg = json(folder, "package.json"), let main = pkg["main"] as? String {
            var m = main.replacingOccurrences(of: "\\", with: "/")
            while m.hasPrefix("./") { m.removeFirst(2) }
            while m.hasPrefix("/") { m.removeFirst() }
            // 쿼리·조각, app:// 같은 앞부분은 떼고 상대 경로만 본다
            if let q = m.firstIndex(where: { $0 == "?" || $0 == "#" }) { m = String(m[..<q]) }
            let parts = m.split(separator: "/").map(String.init)
            if !parts.isEmpty, !m.contains(":"), !parts.contains(".."), !parts.contains(where: { $0.hasPrefix(".") }) {
                let dir = parts.dropLast().joined(separator: "/")
                if parts.last?.lowercased().hasSuffix(".html") == true, exists(folder, m), isEngineRoot(folder, dir) { return dir }
            }
        }
        // (b) www/
        if exists(folder, "www/index.html"), exists(folder, "www/js"), isEngineRoot(folder, "www") { return "www" }
        // (c) 맨 위
        if exists(folder, "index.html"), isEngineRoot(folder, ""), exists(folder, "data/System.json") { return "" }
        return nil
    }

    /// 루트 후보에 엔진 코어 또는 System.json 이 있는가
    private static func isEngineRoot(_ folder: URL, _ dir: String) -> Bool {
        let base = dir.isEmpty ? folder : folder.appendingPathComponent(dir, isDirectory: true)
        return exists(base, "js/rmmz_core.js") || exists(base, "js/rpg_core.js") || exists(base, "data/System.json")
    }

    /// 실행 파일 하나로 묶인 NW.js 게임(Enigma 등): `Game.exe`·`nw.pak` 은 있는데 `www/`·`index.html`·`package.nw` 가 없다
    static func looksPackedInExe(_ folder: URL) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() }
        let hasExe = names.contains { $0.hasSuffix(".exe") }
        return hasExe && names.contains("nw.pak") && !names.contains("www") && !names.contains("index.html") && !names.contains("package.nw")
    }

    // MARK: 읽기

    private static func exists(_ base: URL, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: base.appendingPathComponent(rel).path)
    }

    /// 작은 JSON 만 읽는다 (System.json 은 보통 수십 KB). BOM 은 떼고 읽는다
    static func json(_ base: URL, _ rel: String) -> [String: Any]? {
        let url = base.appendingPathComponent(rel)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 8 * 1024 * 1024,
              var data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// 가져올 때 정해 bingsu.json 에 적는 MV·MZ 정보
struct MVMZInfo: Hashable, Sendable {
    enum Engine: String, Sendable { case mv, mz }
    var engine: Engine
    /// 게임 폴더 기준 상대 경로 (`""` 또는 `www`)
    var root: String
    var gameTitle: String
    var encryptedImages = false
    var encryptedAudio = false

    var manifest: [String: Any] {
        ["engine": engine.rawValue, "root": root, "gameTitle": gameTitle,
         "encryptedImages": encryptedImages, "encryptedAudio": encryptedAudio]
    }

    init(engine: Engine, root: String, gameTitle: String, encryptedImages: Bool = false, encryptedAudio: Bool = false) {
        self.engine = engine; self.root = root; self.gameTitle = gameTitle
        self.encryptedImages = encryptedImages; self.encryptedAudio = encryptedAudio
    }

    /// bingsu.json 의 `mvmz`. 루트가 게임 폴더 밖을 가리키면 버린다
    init?(manifest m: [String: Any]) {
        guard let e = (m["engine"] as? String).flatMap(Engine.init), let root = m["root"] as? String else { return nil }
        let parts = root.split(separator: "/")
        guard !root.hasPrefix("/"), !root.contains("\\"), !root.contains(":"), !parts.contains(where: { $0 == ".." || $0.hasPrefix(".") }) else { return nil }
        self.init(engine: e, root: root, gameTitle: m["gameTitle"] as? String ?? "",
                  encryptedImages: m["encryptedImages"] as? Bool ?? false, encryptedAudio: m["encryptedAudio"] as? Bool ?? false)
    }
}

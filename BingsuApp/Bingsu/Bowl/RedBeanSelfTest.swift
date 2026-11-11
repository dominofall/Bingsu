#if DEBUG
import Foundation

/// 디버그 자가 테스트 (`BINGSU_SELFTEST=1`, 앱을 켤 때 한 번). 결과는 `[RedBean] selftest …` 로그. 명세 IMPLEMENTATION-electron.md §8.
/// - 스킴 핸들러 쓰기 규칙: `/userData/` 아래만 PUT·DELETE·MOVE·MKCOL, `/app`·그 밖은 거부. 깊이·조각 길이·숨김
/// - 한도: 파일 하나 16MB, 1,000개, 합계 512MB (덮어쓰기는 그 파일 크기를 빼고 센다)
/// - 얼음틀이 묶는 이름: `userData/` 아래, `.tmp` 아님
/// - `RedBeanProbe` 가 `tools/compat-fixtures/` 의 세 게임을 읽은 결과 (소스 경로에서 읽는다. 시뮬레이터에서만)
enum RedBeanSelfTest {
    static func run() {
        var fails = 0, checks = 0
        func check(_ c: Bool, _ what: String) { checks += 1; if !c { fails += 1; NSLog("[RedBean] selftest FAIL \(what)") } }
        typealias H = RedBeanSchemeHandler
        func allowed(_ method: String, _ path: String) -> Bool {
            guard let parts = SchemeTree.segments(path: path) else { return false }
            return H.writeAllowed(method: method, H.target(parts))
        }

        // 경로 규칙 표
        let deep = "/userData/a/b/c/d/e.json"
        let table: [(String, String, Bool)] = [
            ("PUT", "/userData/settings.json", true),
            ("PUT", "/userData/save.json", true),            // 게임의 save.json 은 한 단계 아래라 괜찮다
            ("PUT", "/userData/pokedex.json.tmp", true),
            ("MOVE", "/userData/pokedex.json", true),
            ("DELETE", "/userData/pokedex.json.bak", true),
            ("MKCOL", "/userData/saves", true),
            ("PUT", "/userData/saves/slot1.json", true),
            ("PUT", "/userData/a/b/c/d.json", true),         // 깊이 4
            ("PUT", deep, false),                            // 깊이 5
            ("MKCOL", "/userData", false),                   // 폴더 자체
            ("DELETE", "/userData", false),
            ("PUT", "/app/index.html", false),
            ("PUT", "/app/package.json", false),
            ("DELETE", "/app/main.js", false),
            ("PUT", "/appData/x.json", false),
            ("PUT", "/tmp/x.txt", false),
            ("PUT", "/home/Documents/x.txt", false),
            ("PUT", "/save.json", false),
            ("PUT", "/userData/../save.json", false),
            ("PUT", "/userData/.hidden", false),
            ("PUT", "/userData/sub/.git", false),
            ("PUT", "/userData/" + String(repeating: "a", count: 129), false),
            ("POST", "/userData/settings.json", false),
            ("GET", "/userData/settings.json", false),       // 쓰기 메서드만 허용 대상
        ]
        for (m, p, want) in table { check(allowed(m, p) == want, "\(m) \(p) → \(want ? "허용" : "거부")") }
        check(H.segments(URL(string: "bingsu-app://evil/userData/x.json")!) == nil, "다른 호스트 거부")
        check(H.segments(URL(string: "bingsu-mv://game/userData/x.json")!) == nil, "다른 스킴 거부")
        check(H.target(["app", "index.html"]) == .app(["index.html"]) && H.target(["userData"]) == .userData([])
              && H.target(["userData", "a.json"]) == .userData(["a.json"]) && H.target(["appData"]) == .none, "대상 분류")

        // 한도
        let mb = 1024 * 1024
        check(H.fitsQuota(existing: [:], path: "a", size: 16 * mb), "16MB 허용")
        check(!H.fitsQuota(existing: [:], path: "a", size: 17 * mb), "17MB 거부")
        var many: [String: Int] = [:]
        for i in 0..<1000 { many["f\(i)"] = 10 }
        check(!H.fitsQuota(existing: many, path: "new", size: 1), "1,001번째 파일 거부")
        check(H.fitsQuota(existing: many, path: "f3", size: 1), "1,000개일 때 덮어쓰기 허용")
        var big: [String: Int] = [:]
        for i in 0..<32 { big["b\(i)"] = 16 * mb }
        check(!H.fitsQuota(existing: big, path: "more", size: 1), "합계 512MB 넘음 거부")
        check(H.fitsQuota(existing: big, path: "b0", size: 15 * mb), "합계 안에서 덮어쓰기 허용")

        // 얼음틀이 묶는 이름
        for (rel, want) in [("userData/settings.json", true), ("userData/saves/slot1.json", true), ("userData/pokedex.json.tmp", false),
                            ("save.json", false), ("userData/.x", false), ("userData/../save.json", false), ("other/x.json", false),
                            ("userData/a/b/c/d/e.json", false)] {
            check(IceTray.safeUserDataPath(rel) == want, "얼음틀 이름 \(rel) → \(want)")
        }

        // 판별 (글자 훑기)
        check(RedBeanProbe.htmlPath("file://${__dirname}/index.html") == "index.html", "htmlPath 템플릿")
        check(RedBeanProbe.normalize("src/../web/index.html") == "web/index.html" && RedBeanProbe.normalize("../x.html") == nil, "normalize")
        check(RedBeanProbe.webPreferences("webPreferences: { preload: path.join(__dirname, 'pre', 'preload.js'), nodeIntegration: true }")
              == (nodeIntegration: true, preload: "pre/preload.js"), "webPreferences 힌트")
        check(RedBeanProbe.webPreferences("webPreferences: {\n  preload: path.join(__dirname, 'preload.js'),\n  contextIsolation: true\n}")
              == (nodeIntegration: false, preload: "preload.js"), "webPreferences 여러 줄")
        check(RedBeanProbe.loadCalls("win.loadFile(path.join(__dirname, '..', 'web', 'index.html'));") == [["..", "web", "index.html"]], "loadCalls")
        let info = ElectronInfo(main: "src/main.js", entry: "web/index.html", inputStyle: .pointer, nodeIntegration: false, preload: "src/preload.js")
        check(ElectronInfo(manifest: info.manifest) == info, "bingsu.json electron 왕복")
        check(ElectronInfo(manifest: ["main": "../x.js", "entry": "index.html", "inputStyle": "pad"]) == nil, "bingsu.json 나쁜 경로 거부")

        // 시험용 게임 세 개
        let fixtures = DevEnv["BINGSU_FIXTURES"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("tools/compat-fixtures")
        func probe(_ name: String) -> RedBeanProbe.Result? {
            let f = fixtures.appendingPathComponent(name)
            guard RedBeanProbe.looksLikeApp(f) else { return nil }
            if case .success(let r)? = RedBeanProbe.probe(folder: f) { return r }
            return nil
        }
        if FileManager.default.fileExists(atPath: fixtures.path) {
            let node = probe("electron-node")
            check(node?.info.main == "main.js" && node?.info.entry == "index.html" && node?.info.nodeIntegration == true
                  && node?.info.preload == nil && node?.title == "빙수 시험 노드" && node?.packageName == "bingsu-fixture-node"
                  && node?.version == "1.2.3", "시험 노드 판별 \(String(describing: node?.info))")
            let pre = probe("electron-preload")
            check(pre?.info.main == "src/main.js" && pre?.info.entry == "web/index.html" && pre?.info.nodeIntegration == false
                  && pre?.info.preload == "src/preload.js", "시험 프리로드 판별 \(String(describing: pre?.info))")
            let plain = probe("electron-plain")
            check(plain?.info.main == "main.js" && plain?.info.entry == "page/index.html" && plain?.info.nodeIntegration == false
                  && plain?.title == "빙수 시험 기본" && plain?.packageName == "bingsu-fixture-plain", "시험 기본 판별 \(String(describing: plain?.info))")
            check(node?.info.inputStyle == .pointer && plain?.info.inputStyle == .pad, "조작 방식 node=\(String(describing: node?.info.inputStyle)) plain=\(String(describing: plain?.info.inputStyle))")
        } else {
            NSLog("[RedBean] selftest fixtures not found at \(fixtures.path) (skipped)")
        }

        NSLog("[RedBean] selftest \(fails == 0 ? "OK" : "FAIL") checks=\(checks) fails=\(fails)")
    }
}
#endif

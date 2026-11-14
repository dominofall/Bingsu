#if DEBUG
import Foundation

/// 디버그 자가 테스트 (`BINGSU_SELFTEST=1`, 앱을 켤 때 한 번). 결과는 `[Topping] selftest …` 로그.
/// 패치 경로 맞추기·건너뛰기·경로 탈출 막기·적용 뒤 되돌리기가 원래 바이트로 돌아오는지를 가짜 게임으로 본다.
enum ToppingSelfTest {
    static func run() {
        var fails = 0, checks = 0
        func check(_ c: Bool, _ what: String) { checks += 1; if !c { fails += 1; NSLog("[Topping] selftest FAIL \(what)") } }
        let fm = FileManager.default
        let id = "selftest-topping-\(UUID().uuidString.prefix(8).lowercased())"
        let game = MenuBoardStore.gamesDir.appendingPathComponent(id, isDirectory: true)
        let scratch = fm.temporaryDirectory.appendingPathComponent("topping-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: game); try? fm.removeItem(at: scratch); Topping.forget(id) }
        func put(_ base: URL, _ rel: String, _ text: String) {
            let u = base.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: u)
        }
        func read(_ base: URL, _ rel: String) -> String? { (try? Data(contentsOf: base.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) } }

        // 가짜 RPG Maker 게임
        for (rel, text) in [("Game.ini", "[Game]\nTitle=T\nScripts=Data\\Scripts.rxdata"), ("mkxp.json", "{\n\"dataPathApp\": \"T\"\n}"),
                            ("Data/Scripts.rxdata", "orig-scripts"), ("Data/System.rxdata", "sys"), ("Data/Map001.rxdata", "map1"),
                            ("Graphics/Pictures/bag1.png", "orig-bag"), ("Fonts/pkmnem.ttf", "orig-font"), ("bingsu.json", "{\"title\":\"T\",\"recipe\":\"mkxp\"}")] {
            put(game, rel, text)
        }
        let dish = Dish(id: id, title: "T", recipe: .mkxp, location: game, dataPathApp: "T")
        check(Topping.isImported(dish), "Games/<id> 게임은 가져온 게임")
        check(!Topping.isImported(Dish(id: "x", title: "x", recipe: .mkxp, location: scratch, dataPathApp: "x")), "Games 밖 폴더는 아님")

        // 이름 조각
        check(Topping.safeComponent("..") == nil && Topping.safeComponent(".") == nil && Topping.safeComponent("a/b") == nil
              && Topping.safeComponent("a\\b") == nil && Topping.safeComponent("C:") == nil && Topping.safeComponent("") == nil
              && Topping.safeComponent("a\u{0}b") == nil && Topping.safeComponent("Map001.rxdata") == "Map001.rxdata", "안전한 이름 조각")
        check(!Topping.inside(game.appendingPathComponent("../other/x"), game) && Topping.inside(game.appendingPathComponent("Data/new/x"), game)
              && !Topping.inside(game, game), "게임 폴더 안 판정")

        // 1) 최상위 폴더 한 겹 + 대소문자 다름 + 영수증·저장 파일은 건너뜀
        let p1 = scratch.appendingPathComponent("p1/staged", isDirectory: true)
        put(p1, "Pokemon Z KR/data/scripts.rxdata", "kr-scripts")
        put(p1, "Pokemon Z KR/Graphics/Pictures/bag1.png", "kr-bag")
        put(p1, "Pokemon Z KR/Fonts/kr-dp.ttf", "kr-font")
        put(p1, "Pokemon Z KR/data/korean.dat", "kr-dat")
        put(p1, "Pokemon Z KR/mkxp.json", "{\n\"dataPathApp\": \"T\"\n}")
        put(p1, "Pokemon Z KR/bingsu.json", "{\"title\":\"evil\"}")
        put(p1, "Pokemon Z KR/Save01.rvdata2", "save")
        put(p1, "Pokemon Z KR/번역표/README.md", "doc")
        put(p1, "Pokemon Z KR/mod.json", "{\"name\":\"테스트 한글 패치 v1\"}")
        check(Topping.looksLikeRGSSPatch(p1.appendingPathComponent("Pokemon Z KR")), "mkxp.json 이 있어도 System 데이터가 없으면 패치")
        check(!Topping.looksLikeRGSSPatch(game), "게임 본체는 패치가 아님")
        let a1 = Topping.align(p1, to: dish)
        check(a1?.root.lastPathComponent == "Pokemon Z KR", "맨 위 폴더 한 겹 벗김 \(a1?.root.lastPathComponent ?? "nil")")
        do {
            let plan = try Topping.plan(work: scratch.appendingPathComponent("p1"), staged: p1, dish: dish, sourceName: "kr.zip")
            let targets = Set(plan.items.map(\.target))
            check(plan.name == "테스트 한글 패치 v1", "이름은 mod.json \(plan.name)")
            check(targets.contains("Data/Scripts.rxdata") && targets.contains("Graphics/Pictures/bag1.png"), "게임 쪽 대소문자로 맞춤 \(targets.sorted())")
            check(!targets.contains("bingsu.json") && !targets.contains("Save01.rvdata2"), "영수증·저장 파일 건너뜀")
            check(plan.replacedCount == 3 && plan.addedCount == 4, "바꿈 3 · 새로 4 \(plan.items.map { ($0.replaces ? "R:" : "A:") + $0.target }) 건너뜀 \(plan.skipped)")
            let r = try Topping.apply(plan)
            check(read(game, "Data/Scripts.rxdata") == "kr-scripts" && read(game, "Fonts/kr-dp.ttf") == "kr-font"
                  && read(game, "번역표/README.md") == "doc", "적용됨")
            check(read(game, "bingsu.json")?.contains("evil") == false, "영수증 그대로")
            check(!fm.fileExists(atPath: game.appendingPathComponent("data").path) || read(game, "Data/Map001.rxdata") == "map1", "Data 폴더 하나로 (맵 그대로)")
            check(Topping.records(for: id).count == 1 && r.complete, "기록 1개")

            // 2) 두 번째 패치: Data/ 하나뿐인 zip (맨 위 폴더를 벗기면 안 된다)
            let p2 = scratch.appendingPathComponent("p2/staged", isDirectory: true)
            put(p2, "Data/Scripts.rxdata", "pad-scripts")
            let a2 = Topping.align(p2, to: dish)
            check(a2?.root == p2, "Data 하나뿐인 패치는 맨 위 그대로")
            let plan2 = try Topping.plan(work: scratch.appendingPathComponent("p2"), staged: p2, dish: dish, sourceName: "pad.zip")
            try Topping.apply(plan2)
            check(read(game, "Data/Scripts.rxdata") == "pad-scripts", "두 번째 패치 적용")

            // 되돌리기: 마지막부터
            try Topping.revertLast(dish)
            check(read(game, "Data/Scripts.rxdata") == "kr-scripts", "두 번째만 되돌림")
            try Topping.revertLast(dish)
            check(read(game, "Data/Scripts.rxdata") == "orig-scripts" && read(game, "Graphics/Pictures/bag1.png") == "orig-bag"
                  && read(game, "Fonts/pkmnem.ttf") == "orig-font", "원본으로 돌아옴")
            check(!fm.fileExists(atPath: game.appendingPathComponent("Fonts/kr-dp.ttf").path)
                  && !fm.fileExists(atPath: game.appendingPathComponent("번역표").path), "새 파일·새 폴더 지움")
            check(Topping.records(for: id).isEmpty, "기록 없음")
            do { try Topping.revertLast(dish); check(false, "되돌릴 것 없으면 오류") } catch { check(true, "") }
        } catch {
            check(false, "적용·되돌리기 \(error.localizedDescription)")
        }

        // 3) 다른 게임의 패치: 겹치는 곳 없음
        let p3 = scratch.appendingPathComponent("p3/staged", isDirectory: true)
        put(p3, "www/js/plugins.js", "x")
        check(Topping.align(p3, to: dish) == nil, "겹치는 곳 없으면 거절")

        // 4) 게임 폴더 안 링크: 그 길로는 쓰지 않는다
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: game.appendingPathComponent("Audio"), withDestinationURL: outside)
        let p4 = scratch.appendingPathComponent("p4/staged", isDirectory: true)
        put(p4, "Audio/SE/x.ogg", "evil")
        put(p4, "Data/Map001.rxdata", "m")
        do {
            _ = try Topping.plan(work: scratch.appendingPathComponent("p4"), staged: p4, dish: dish, sourceName: "evil.zip")
            check(false, "링크 길 거절")
        } catch { check(true, "") }
        check(!fm.fileExists(atPath: outside.appendingPathComponent("SE/x.ogg").path), "게임 밖에 쓰지 않음")

        // 5) 조작된 기록(경로 탈출)으로 되돌리기 → 거절, 밖의 파일 그대로
        if let shelf = Topping.folder(for: id) {
            let dir = shelf.appendingPathComponent("001", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            put(scratch, "victim.txt", "keep")
            let evil = "{\"id\":\"001\",\"name\":\"x\",\"sourceName\":\"x\",\"appliedAt\":\"2026-11-14T00:00:00Z\",\"base\":\"\",\"replaced\":[],\"added\":[\"../../../../tmp/victim.txt\"],\"createdDirs\":[],\"complete\":true}"
            try? Data(evil.utf8).write(to: dir.appendingPathComponent(Topping.recordName))
            do { try Topping.revertLast(dish); check(false, "탈출 기록 거절") } catch { check(true, "") }
            check(read(scratch, "victim.txt") == "keep", "밖의 파일 그대로")
        }
        check(Topping.folder(for: "../x") == nil, "id 에 경로 문자 거절")

        // 6) "업데이트"로 고른 zip 이 게임 전체인지, 게임 이름(ini)은 있지만 일부만 든 패치인지
        let part = scratch.appendingPathComponent("p6/staged", isDirectory: true)
        put(part, "Game.ini", "[Game]\nTitle=T")
        put(part, "Data/Scripts.rxdata", "new-scripts")
        check(Topping.isPartial(part, comparedTo: game), "ini 는 있어도 System 데이터가 없으면 일부")
        let full = scratch.appendingPathComponent("p7/staged", isDirectory: true)
        for rel in ["Game.ini", "Data/Scripts.rxdata", "Data/system.rxdata", "Data/Map001.rxdata"] { put(full, rel, "x") }
        check(!Topping.isPartial(full, comparedTo: game), "System 데이터가 있으면 게임 전체 (대소문자 무관)")
        let packed = scratch.appendingPathComponent("p8/staged", isDirectory: true)
        put(packed, "Game.rgssad", "x")
        put(game, "Game.rgssad", "x")
        check(!Topping.isPartial(packed, comparedTo: game), "암호화 아카이브로 묶은 새 버전은 게임 전체")
        check(!Topping.isPartial(part, comparedTo: scratch.appendingPathComponent("outside")), "본체를 모르는 게임은 판단하지 않음")

        // 7) 이 게임용 패치인가: 지문 없는 패치 — 같은 파일이 있으면 맞음, 크기가 전혀 다르면 경고
        let a100 = String(repeating: "a", count: 100)
        for i in 0..<12 { put(game, "Graphics/Fit/f\(i).png", a100) }
        for i in 0..<25 { put(game, "Graphics/Man/m\(i).png", String(repeating: "m", count: 50 + i)) }
        func warnings(_ name: String, _ files: [(String, String)]) -> [String] {
            let st = scratch.appendingPathComponent("\(name)/staged", isDirectory: true)
            for (rel, text) in files { put(st, rel, text) }
            return (try? Topping.plan(work: scratch.appendingPathComponent(name), staged: st, dish: dish, sourceName: "\(name).zip"))?.warnings ?? ["plan 실패"]
        }
        let fitWord = "이 게임용 패치가 아닌"
        let right = warnings("p9", (0..<12).map { ("Graphics/Fit/f\($0).png", $0 < 6 ? a100 : String(repeating: "b", count: 110)) })
        check(right.isEmpty, "같은 파일이 섞인 패치는 경고 없음 \(right)")
        let wrong = warnings("p10", (0..<12).map { ("Graphics/Fit/f\($0).png", String(repeating: "z", count: 2000)) })
        check(wrong.contains { $0.hasPrefix(fitWord) }, "크기가 전혀 다른 패치는 경고 \(wrong)")
        let few = warnings("p11", [("Graphics/Fit/f0.png", "x")] + (0..<11).map { ("Other/n\($0).png", "n") })
        check(few.contains { $0.hasPrefix(fitWord) }, "게임에 있는 파일이 적으면 경고 \(few)")

        // 8) 지문(modkit manifest.json): 패치가 바꾸지 않는 원본 파일 크기가 맞으면 경고 없음, 다르면 경고
        func manifest(_ delta: Int) -> String {
            let rows = (0..<25).map { "\"Graphics/Man/m\($0).png\": [\(50 + $0 + delta), 0]" } + ["\"Data/Map001.rxdata\": [9, 0]"]
            return "{\"modkit_manifest\": 1, \"game\": \"T\", \"exclude\": [\"mod.json\"], \"files\": {\(rows.joined(separator: ", "))}}"
        }
        let mOK = warnings("p12", [("Data/Map001.rxdata", "map1-kr-x"), ("manifest.json", manifest(0))])
        check(!mOK.contains { $0.hasPrefix(fitWord) }, "지문 크기가 맞으면 경고 없음 \(mOK)")
        let mBad = warnings("p13", [("Data/Map001.rxdata", "map1-kr-x"), ("manifest.json", manifest(7))])
        check(mBad.contains { $0.hasPrefix(fitWord) }, "지문 크기가 다르면 경고 \(mBad)")

        // 9) 스크립트 파일을 풀 수 없는 패치 → 시작되지 않을 수 있다는 경고
        let broken = warnings("p14", [("Data/Scripts.rxdata", "not marshal")])
        check(broken.contains { $0.hasPrefix("이 패치를 적용하면 게임이 시작되지 않을 수 있어요") }, "깨진 스크립트 경고 \(broken)")

        NSLog("[Topping] selftest \(checks - fails)/\(checks) \(fails == 0 ? "OK" : "FAIL")")
    }
}
#endif

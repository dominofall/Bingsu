#if DEBUG
import Foundation
import UIKit

/// 디버그 자가 테스트 (`BINGSU_SELFTEST=1`, 앱을 켤 때 한 번). 결과는 `[Straw] selftest …` 로그.
/// 터치 조작 명세 docs/engines/IMPLEMENTATION-touch.md: 키 모으기(§10)·키 고르기와 키 줄 자리(§7)·확대 범위(§6)·
/// 게임별 설정의 옛 파일 읽기(§8)·시험용 화면 touch-lab 판별.
enum StrawSelfTest {
    @MainActor static func run() {
        var fails = 0, checks = 0
        func check(_ c: Bool, _ what: String) { checks += 1; if !c { fails += 1; NSLog("[Straw] selftest FAIL \(what)") } }

        // 키 이름
        check(StrawKeys.code(forKey: "Escape") == "Escape" && StrawKeys.code(forKey: "Esc") == "Escape" && StrawKeys.code(forKey: " ") == "Space"
              && StrawKeys.code(forKey: "Left") == "ArrowLeft" && StrawKeys.code(forKey: "a") == "KeyA" && StrawKeys.code(forKey: "Z") == "KeyZ"
              && StrawKeys.code(forKey: "7") == "Digit7" && StrawKeys.code(forKey: "F12") == "F12" && StrawKeys.code(forKey: "F13") == nil
              && StrawKeys.code(forKey: "가") == nil && StrawKeys.code(forKey: "Meta") == nil, "e.key → code")
        check(StrawKeys.code(forKeyCode: 27) == "Escape" && StrawKeys.code(forKeyCode: 32) == "Space" && StrawKeys.code(forKeyCode: 37) == "ArrowLeft"
              && StrawKeys.code(forKeyCode: 65) == "KeyA" && StrawKeys.code(forKeyCode: 112) == "F1" && StrawKeys.code(forKeyCode: 999) == nil, "keyCode → code")
        check(StrawKeys.label("Escape") == "Esc" && StrawKeys.label("ArrowLeft") == "←" && StrawKeys.label("KeyZ") == "Z"
              && StrawKeys.label("Digit3") == "3" && StrawKeys.label("Space") == "Space", "키 글자")

        // 키 모으기
        let listening = """
        document.addEventListener('keydown', (e) => {
          if (e.key === 'Escape') close();
          if ("Enter" == e.key || e.keyCode === 32) ok();
          switch (e.code) { case 'ArrowLeft': prev(); break; case "ArrowRight": next(); break; }
          switch (ev.key) { case 'z': attack(); break; case 'Bogus': break; }
          if (event.which == 40) down();
          if (e.code !== 'KeyQ') {}
        });
        """
        var tally: [String: Int] = [:]
        StrawKeys.count(in: listening, listensKeys: true, into: &tally)
        check(tally == ["Escape": 1, "Enter": 1, "Space": 1, "ArrowLeft": 1, "ArrowRight": 1, "KeyZ": 1, "ArrowDown": 1, "KeyQ": 1], "키 모으기 \(tally)")
        var quiet: [String: Int] = [:]
        StrawKeys.count(in: "switch (state) { case 'a': break; case 'Escape': break; }", listensKeys: false, into: &quiet)
        check(quiet.isEmpty, "키를 듣지 않는 파일의 case 는 세지 않음 \(quiet)")
        let many = Dictionary(uniqueKeysWithValues: (0..<20).map { ("Digit\($0 % 10)" + ($0 < 10 ? "" : "x"), 20 - $0) })
            .filter { StrawKeys.known.contains($0.key) }
        check(StrawKeys.top(many).count <= 12 && StrawKeys.top(["Space": 1, "Escape": 3, "Enter": 1]) == ["Escape", "Enter", "Space"], "많이 나온 순")
        check(StrawKeys.sanitize(nil) == nil && StrawKeys.sanitize([]) == [] && StrawKeys.sanitize(["Escape", "Bogus", "Escape", 3, "KeyZ"]) == ["Escape", "KeyZ"]
              && StrawKeys.sanitize((0..<30).map { _ in "Enter" } + ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "Tab"])?.count == 12,
              "파일에서 읽은 키 거르기")

        // 키 고르기 (§7)
        check(StrawKeys.pick(nil) == ["Escape", "Enter", "Space"] && StrawKeys.pick([]) == ["Escape", "Enter", "Space"], "키 없으면 Esc·Enter·Space")
        check(StrawKeys.pick(["KeyZ", "ArrowRight", "Escape", "F1", "ArrowLeft", "Space", "Enter", "KeyX"])
              == ["Escape", "Enter", "Space", "ArrowLeft", "ArrowRight", "KeyZ"], "키 순서와 6개 \(StrawKeys.pick(["KeyZ", "ArrowRight", "Escape", "F1", "ArrowLeft", "Space", "Enter", "KeyX"]))")
        check(StrawKeys.pick(["ArrowDown", "ArrowUp"]) == ["ArrowUp", "ArrowDown"], "방향키만")

        // 키 줄 자리
        func ok(_ o: KeyStripPlace.Output, screen: CGSize, game: CGRect, avoid: [CGRect], _ what: String) {
            let inScreen = o.frames.allSatisfy { CGRect(origin: .zero, size: screen).contains($0) }
            let noAvoid = o.frames.allSatisfy { f in !avoid.contains { $0.intersects(f) } }
            let noOverlap = zip(o.frames, o.frames.dropFirst()).allSatisfy { !$0.intersects($1) }
            let offGame = o.overlay || o.frames.allSatisfy { !$0.intersects(game) }
            check(inScreen && noAvoid && noOverlap && offGame, "\(what) 자리 \(o)")
        }
        // iPhone 17 Pro 가로: 양옆 띠 약 80pt, 눈송이 오른쪽 위
        let phoneL = CGSize(width: 874, height: 402), gameL = CGRect(x: 79.65, y: 0, width: 714.7, height: 402)
        let orbR = CGRect(x: 874 - 10 - 48, y: 10, width: 48, height: 48), resetL = CGRect(x: 72, y: 10, width: 150, height: 48)
        let insL = UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)
        let a = KeyStripPlace.place(count: 6, screen: phoneL, safe: insL, game: gameL, avoid: [orbR, resetL], island: .left)
        ok(a, screen: phoneL, game: gameL, avoid: [orbR, resetL], "iPhone 가로")
        check(!a.overlay && a.frames.allSatisfy { $0.minX >= gameL.maxX }, "iPhone 가로는 카메라 반대쪽(오른쪽) 띠")
        let b = KeyStripPlace.place(count: 3, screen: phoneL, safe: insL, game: gameL, avoid: [orbR, resetL], island: .right)
        check(!b.overlay && b.frames.allSatisfy { $0.maxX <= gameL.minX }, "카메라가 오른쪽이면 왼쪽 띠 \(b)")
        // iPhone 세로: 게임 아래
        let phoneP = CGSize(width: 402, height: 874), gameP = CGRect(x: 0, y: 324, width: 402, height: 226.1)
        let insP = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
        let c = KeyStripPlace.place(count: 5, screen: phoneP, safe: insP, game: gameP, avoid: [CGRect(x: 344, y: 10, width: 48, height: 48)], island: nil)
        ok(c, screen: phoneP, game: gameP, avoid: [], "iPhone 세로")
        check(!c.overlay && c.frames.allSatisfy { $0.minY >= gameP.maxY }, "iPhone 세로는 게임 아래")
        // iPad Pro 13 가로: 위아래 띠
        let padL = CGSize(width: 1376, height: 1032), gameD = CGRect(x: 0, y: 129, width: 1376, height: 774)
        let insD = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
        let d = KeyStripPlace.place(count: 5, screen: padL, safe: insD, game: gameD, avoid: [CGRect(x: 1318, y: 10, width: 48, height: 48)], island: nil)
        ok(d, screen: padL, game: gameD, avoid: [], "iPad 가로")
        check(!d.overlay && d.frames.allSatisfy { $0.minY >= gameD.maxY }, "iPad 가로는 아래 띠")
        // 빈 띠가 없으면 겹치기
        let full = CGRect(origin: .zero, size: phoneL)
        let e = KeyStripPlace.place(count: 3, screen: phoneL, safe: insL, game: full, avoid: [orbR], island: .left)
        check(e.overlay && e.frames.count == 3 && e.frames.allSatisfy { full.contains($0) }, "띠 없으면 게임 위 반투명 \(e)")
        check(KeyStripPlace.place(count: 0, screen: phoneL, safe: insL, game: gameL, avoid: [], island: nil).frames.isEmpty, "키 0개")

        // 게임별 설정: 예전 파일·모르는 값
        let dec = JSONDecoder()
        let old = try? dec.decode(DishPrefs.self, from: Data(#"{"quality":"high","pixelSharp":true}"#.utf8))
        check(old != nil && old?.inputStyle == nil && old?.keyStrip == nil, "예전 게임별 설정 읽기")
        let weird = try? dec.decode(DishPrefs.self, from: Data(#"{"inputStyle":"joystick","keyStrip":false}"#.utf8))
        check(weird?.inputStyle == "joystick" && weird?.keyStrip == false, "모르는 조작 방식 글자도 파일은 읽힘")

        // bingsu.json 의 keys
        var info = ElectronInfo(main: "main.js", entry: "index.html", inputStyle: .pointer, keys: ["Escape", "ArrowLeft"])
        check(ElectronInfo(manifest: info.manifest) == info, "keys 왕복")
        info.keys = nil
        check(ElectronInfo(manifest: info.manifest)?.keys == nil, "keys 없는 예전 파일")
        var m = info.manifest; m["keys"] = ["Escape", "rm -rf", "Escape", 7]
        check(ElectronInfo(manifest: m)?.keys == ["Escape"], "keys 거르기")

        // 시험용 화면 touch-lab 판별 (소스 경로에서, 시뮬레이터에서만)
        let fixtures = DevEnv["BINGSU_FIXTURES"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("tools/compat-fixtures")
        let lab = fixtures.appendingPathComponent("touch-lab")
        if FileManager.default.fileExists(atPath: lab.path) {
            if case .success(let r)? = RedBeanProbe.probe(folder: lab) {
                check(r.info.inputStyle == .pointer && r.packageName == "bingsu-fixture-touch", "touch-lab 판별 \(r.info)")
                check(r.keys.first == "Escape" && Set(r.keys) == ["Escape", "Enter", "Space", "ArrowLeft", "ArrowRight"], "touch-lab 키 \(r.keys)")
                check(StrawKeys.pick(r.info.keys) == ["Escape", "Enter", "Space", "ArrowLeft", "ArrowRight"], "touch-lab 키 줄")
            } else { check(false, "touch-lab 판별 실패") }
            for name in ["electron-node", "electron-plain", "electron-preload"] {
                if case .success(let r)? = RedBeanProbe.probe(folder: fixtures.appendingPathComponent(name)) {
                    check(r.info.keys != nil, "\(name) keys 적힘 \(r.keys)")
                }
            }
        } else {
            NSLog("[Straw] selftest fixtures not found at \(fixtures.path) (skipped)")
        }

        NSLog("[Straw] selftest \(fails == 0 ? "OK" : "FAIL") checks=\(checks) fails=\(fails)")
    }
}
#endif

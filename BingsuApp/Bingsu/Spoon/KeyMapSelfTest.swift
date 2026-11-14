#if DEBUG
import Foundation
import UIKit

/// 키 설정 자가 테스트 (`BINGSU_SELFTEST=1` 또는 `BINGSU_KEYMAPTEST=1`). 결과는 `[Keys] selftest …` 로그.
/// 실제 컨트롤러·키보드 없이 확인할 수 있는 것: 자리 바꾸기, 저장 왕복·깨진 값, 전역·게임별 저장, 컨트롤러 버튼 → 게임 키,
/// 하드웨어 키 길 고르기(바뀐 키·글자 입력·잡기), 키 표와 엔진 스캔코드.
enum KeyMapSelfTest {
    @MainActor
    static func run() {
        var fails: [String] = []
        func check(_ c: Bool, _ what: String) { if !c { fails.append(what) } }

        // 1) 자리 바꾸기: X 를 확인(A)으로 → A 버튼은 X 가 하던 일
        var m = KeyMap()
        m.assign(pad: .x, to: .pad(.a))
        check(m.target(pad: .x) == .pad(.a) && m.target(pad: .a) == .pad(.x), "swap")
        check(m.warnings(label: { $0.displayName }).isEmpty, "swap no warnings")
        m.assign(pad: .x, to: .pad(.x))   // 되돌리기
        check(m.isDefault, "swap back \(m.pad)")
        m.assign(pad: .y, to: .key("KeyQ"))
        check(m.target(pad: .y) == .key("KeyQ") && !m.warnings(label: { $0.displayName }).isEmpty, "key target leaves Y unreachable")
        // 키보드 목록: 버튼 하나에 키 하나, 다른 버튼에 있던 키는 옮겨 온다
        var k = KeyMap()
        check(k.keys(for: .a).isEmpty, "unassigned key row")
        k.assignKey("KeyJ", to: .a); k.assignKey("KeyK", to: .a)
        check(k.keys(for: .a) == ["KeyK"] && k.target(key: "KeyJ") == nil, "assign replaces \(k.keys)")
        k.assignKey("KeyK", to: .b)
        check(k.keys(for: .a).isEmpty && k.keys(for: .b) == ["KeyK"], "assign moves key")
        k.clearKeys(for: .b)
        check(k.keys.isEmpty, "clear row")
        for p in KeyProfile.all {
            k.applyProfile(p)
            check(k.matches(p) && k.keys.count == p.keys.count && k.warnings(label: { $0.displayName }).isEmpty, "profile \(p.id)")
            for c in p.keys.keys where !KeyCatalog.isKnown(c) { check(false, "profile key \(c)") }
        }
        // 지정한 키가 게임 원래 키를 대신한다 (XP: 확인 C). 프로필 WASD → C·방향키는 꺼지고, 다른 일로 바꾼 A·S·D 는 그대로
        if let wasd = KeyProfile.all.first(where: { $0.id == "wasd" }) {
            var w = KeyMap(); w.applyProfile(wasd)
            let g = w.gameKeys(.rpgMakerXP)
            check(g["KeyC"] == .off && g["ArrowUp"] == .off && g["KeyJ"] == .pad(.a) && g["KeyA"] == .pad(.left), "profile replaces native \(g.filter { $0.value == .off }.keys.sorted())")
            var one = KeyMap(); one.assignKey("KeyJ", to: .a)
            let g1 = one.gameKeys(.rpgMakerXP)
            check(g1["KeyC"] == .off && g1["KeyX"] == nil && g1.count == 2, "one row replaces only its key \(g1)")
            check(KeyMap().gameKeys(.rpgMakerXP).isEmpty, "game default keeps native")
        }
        m.setKey("KeyW", .pad(.up)); m.setKey("ArrowUp", .pad(.up))
        m.setKey("KeyZ", .key("KeyZ"))
        check(m.target(key: "KeyZ") == nil, "same key is no change")

        // 2) 저장 왕복과 깨진 값
        if let d = try? JSONEncoder().encode(m), let back = try? JSONDecoder().decode(KeyMap.self, from: d) {
            check(back == m, "round trip")
        } else { check(false, "encode") }
        let broken = #"{"v":1,"pad":{"a":"pad:b","zz":"pad:a","x":"pad:home","y":"key:Key<script>","lb":"off"},"keys":{"KeyW":"pad:up","');alert(1);//":"pad:a","KeyE":"key:F13","KeyR":42}}"#
        if let b = try? JSONDecoder().decode(KeyMap.self, from: Data(broken.utf8)) {
            check(b.target(pad: .a) == .pad(.b) && b.target(pad: .lb) == .off && b.target(pad: .x) == .pad(.x) && b.target(pad: .y) == .pad(.y), "broken pad filtered")
            check(b.keys == ["KeyW": .pad(.up)], "broken keys filtered \(b.keys)")
        } else { check(false, "broken decode") }
        // 예전 게임 설정 파일(keyMap 없음)과 keyMap 모양이 이상한 파일도 나머지는 읽힌다
        check((try? JSONDecoder().decode(DishPrefs.self, from: Data(#"{"pad":null,"keyStrip":true}"#.utf8)))?.keyMap == nil, "old dish prefs")
        let odd = try? JSONDecoder().decode(DishPrefs.self, from: Data(#"{"keyStrip":true,"keyMap":"nope"}"#.utf8))
        check(odd?.keyStrip == true && odd?.keyMap?.isDefault == true, "odd keyMap keeps prefs")

        // 3) 전역·게임별
        let store = KeyMapStore.shared, id = "selftest-keymap"
        let savedGlobal = store.global
        var g = KeyMap(); g.setKey("KeyJ", .pad(.a))
        store.setGlobal(g)
        check(store.effective(id) == g && !store.usesOwn(id), "game follows global")
        var own = g; own.assign(pad: .b, to: .pad(.a))
        store.set(own, for: id)
        check(store.effective(id) == own && store.effective(nil) == g, "game override")
        store.update(dishID: id) { $0.setKey("KeyK", .key("Enter")) }
        check(store.effective(id).target(key: "KeyK") == .key("Enter") && store.global.target(key: "KeyK") == nil, "update goes to game")
        DishPrefsStore.shared.reloadFromDisk()
        check(store.effective(id).target(key: "KeyK") == .key("Enter"), "game override from disk")
        DishPrefsStore.shared.remove(id)
        check(store.effective(id) == g, "removed game falls back to global")
        store.setGlobal(savedGlobal)

        // 4) 컨트롤러 버튼 → 게임에 보낼 것 (RPG Maker XP: A=C)
        var cm = KeyMap(); cm.assign(pad: .x, to: .pad(.a)); cm.setPad(.y, .key("F5")); cm.setPad(.lb, .off)
        let r = LongSpoon.mapped([.x, .y, .lb, .up], cm)
        check(r.pads == [.a, .up] && r.keys == ["F5"], "controller mapped \(r)")
        let spoon = SpoonController()
        spoon.cutlery = .rpgMakerXP
        var sent: [String] = []
        spoon.keySink = { c, d in sent.append("\(c)\(d ? "+" : "-")") }
        for b in r.pads { spoon.press(b, haptic: false) }
        for k in r.keys { spoon.setDirectKey(k, down: true) }
        check(Set(sent) == ["KeyC+", "ArrowUp+", "F5+"], "spoon keys \(sent)")
        spoon.releaseAll()

        // 5) 하드웨어 키 길 고르기 (RPG Maker: SDL 처리기 감싸기)
        var s = HardKeys.Snapshot()
        let tok = s.token
        let w = KeyCatalog.hid("KeyW")!, z = KeyCatalog.hid("KeyZ")!
        s.map = [w: .pad(.up)]
        check(HardKeys.route(&s, token: tok, raw: z, pressed: true) == .pass, "unmapped passes")
        check(HardKeys.route(&s, token: tok, raw: w, pressed: true) == .mapped(.pad(.up)), "mapped down")
        s.passthrough = true   // 누른 채 글자 화면이 열려도 뗌은 같은 대상으로
        check(HardKeys.route(&s, token: tok, raw: w, pressed: false) == .mapped(.pad(.up)), "mapped up after passthrough")
        check(HardKeys.route(&s, token: tok, raw: w, pressed: true) == .pass, "text screen passes")
        s.passthrough = false; s.textSink = true
        check(HardKeys.route(&s, token: tok, raw: w, pressed: true) == .text, "text sink")
        s.textSink = false; s.capture = true
        check(HardKeys.route(&s, token: tok, raw: z, pressed: true) == .swallow, "capture swallows")
        check(HardKeys.route(&s, token: UUID(), raw: w, pressed: true) == .pass, "stale wrapper passes")

        // 6) 키 표: 번호·이름이 겹치지 않고, RPG Maker 엔진 스캔코드와 같다
        check(Set(KeyCatalog.all.map(\.hid)).count == KeyCatalog.all.count, "hid unique")
        for e in KeyCatalog.all where BrassKeys.scancode(e.code) != Int32(e.hid) { check(false, "scancode \(e.code)") }
        for g in KeyCatalog.groups { for c in g.1 where !KeyCatalog.isKnown(c) { check(false, "group \(c)") } }

        NSLog("[Keys] selftest \(fails.isEmpty ? "ok" : "FAIL " + fails.joined(separator: " | "))")
    }
}
#endif

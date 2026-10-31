#if DEBUG
import Foundation
import UIKit

/// 디버그 자가 테스트 (`BINGSU_SELFTEST=1`, 앱을 켤 때 한 번). 결과는 `[Spoon] selftest …` 로그.
/// - 배치 왕복: 다섯 종류 × 가로·세로 × iPhone·iPad × 크기 3단계 × 손 두 가지의 기본 배치를 사용자 배치로 바꾸고(JSON 왕복 포함)
///   다시 풀면 요소마다 1pt 안에서 같은 자리인지
/// - 호환: 빌드 23 의 패드 설정 JSON 이 그대로 읽히고 기본 배치·얼음 스킨이 되는지, 새 필드가 든 JSON 을 빌드 23 모양으로 읽어도 깨지지 않는지
/// - 깨진 배치: layouts 가 엉망이어도 나머지 패드 설정은 남는지
/// - 스킨: 앱에 든 7종이 경고 없이 읽히는지, 내보낸 .bingsuskin 을 다시 가져오면 파일이 바이트까지 같은지
enum SpoonSelfTest {
    static func run() {
        roundTrip()
        compatibility()
        skins()
        exportRoundTrip()
    }

    /// blocks 를 사용자 스킨으로 복제 → 권하는 배치와 함께 내보내기 → 지우기 → 그 zip 가져오기 → 파일·배치가 같은지. 끝나면 지운다
    static func exportRoundTrip() {
        let id = "selftest-blocks", fm = FileManager.default
        var ok = true
        func check(_ c: Bool, _ what: String) { if !c { ok = false; log("FAIL export \(what)") } }
        func files() -> [String: Data] {
            guard let f = SkinShelf.folder(for: id), let names = try? fm.contentsOfDirectory(atPath: f.path) else { return [:] }
            return Dictionary(uniqueKeysWithValues: names.compactMap { n in (try? Data(contentsOf: f.appendingPathComponent(n))).map { (n, $0) } })
        }
        defer { SkinShelf.removeUser(id) }
        do {
            guard let src = SkinShelf.folder(for: "blocks") else { check(false, "blocks 없음"); return }
            var raw = try SkinShelf.load(folder: src, strict: true).raw
            raw.id = id; raw.name = "자가 테스트"
            try SkinShelf.saveUser(raw, copyingImagesFrom: src)
            let before = files()
            let size = CGSize(width: 393, height: 852), safe: SpoonLayout.Insets = (59, 0, 34, 0)
            let base = SpoonLayout.make(prefs: PadPrefs(kind: .retro), size: size, safe: safe, idiom: .phone)
            let layouts = ["phone.portrait.retro": SpoonLayout.arrangement(from: base, size: size, safe: safe, k: 1)]
            let zip = try SkinShelf.exportZip(id: id, layouts: layouts)
            defer { try? fm.removeItem(at: zip) }
            SkinShelf.removeUser(id)
            check(SkinShelf.folder(for: id) == nil, "지운 뒤에도 남음")
            let r = try SkinShelf.importZip(at: zip)
            check(r.id == id && r.installed && !r.replaced && r.warnings.isEmpty, "결과 \(r)")
            check(r.layouts == layouts, "배치가 다름")
            var after = files()
            after["layouts.json"] = nil
            check(before.count == 11 && after == before, "파일 \(before.count)개 → \(after.count)개, 같음 \(after == before)")
            check(SkinShelf.skin(id: id).images.count == 6, "그림 수")
        } catch {
            check(false, error.localizedDescription)
        }
        log("selftest export \(ok ? "ok" : "FAIL")")
    }

    /// 앱에 든 스킨이 전부 경고 없이 읽히는지
    static func skins() {
        let list = SkinShelf.list()
        var bad: [String] = []
        for s in list where s.isBundled {
            guard let folder = SkinShelf.folder(for: s.id), let r = try? SkinShelf.load(folder: folder, strict: true) else { bad.append(s.id); continue }
            if !r.warnings.isEmpty { bad.append("\(s.id)(\(r.warnings.joined(separator: "; ")))") }
            log("skin \(s.id) \(r.skin.name) 그림 \(r.skin.images.count)")
        }
        log("selftest skins \(list.filter(\.isBundled).count)/\(SkinShelf.bundledIDs.count) \(bad.isEmpty ? "ok" : "FAIL " + bad.joined(separator: ", "))")
    }

    private static let screens: [(UIUserInterfaceIdiom, CGSize, SpoonLayout.Insets)] = [
        (.phone, CGSize(width: 852, height: 393), (0, 59, 21, 59)),
        (.phone, CGSize(width: 393, height: 852), (59, 0, 34, 0)),
        (.pad, CGSize(width: 1376, height: 1032), (24, 0, 20, 0)),
        (.pad, CGSize(width: 1032, height: 1376), (24, 0, 20, 0)),
    ]

    static func roundTrip() {
        var pass = 0, fail = 0, worst: CGFloat = 0
        for (idiom, size, safe) in screens {
            for kind in PadKind.allCases {
                for scale in [0.8, 1.0, 1.3] {
                    for left in [false, true] where kind == .oneHand || !left {
                        let prefs = PadPrefs(kind: kind, scale: scale, leftHanded: left)
                        let base = SpoonLayout.make(prefs: prefs, size: size, safe: safe, idiom: idiom)
                        let k = CGFloat(scale) * SpoonLayout.deviceFactor(idiom)
                        let a = SpoonLayout.arrangement(from: base, size: size, safe: safe, k: k, orbCenter: base.betweenViewMenu)
                        // 파일로 저장했다 읽는 것까지
                        guard let data = try? JSONEncoder().encode(a), let back = try? JSONDecoder().decode(PadArrangement.self, from: data) else {
                            fail += 1; log("FAIL encode \(kind) \(size)"); continue
                        }
                        let out = SpoonLayout.resolve(back, size: size, safe: safe, k: k, floatingStick: prefs.floatingStick)
                        let err = difference(base, out)
                        worst = max(worst, err.value)
                        if err.value <= 1, err.problem == nil { pass += 1 } else {
                            fail += 1
                            log("FAIL \(idiom == .pad ? "pad" : "phone") \(Int(size.width))x\(Int(size.height)) \(kind.rawValue) ×\(scale)\(left ? " 왼손" : "") err=\(err.value) \(err.problem ?? "")")
                        }
                    }
                }
            }
        }
        log("selftest roundtrip pass=\(pass) fail=\(fail) maxErr=\(String(format: "%.3f", worst))pt")
    }

    /// 두 배치의 요소별 최대 차이(pt). 요소가 빠졌거나 모양이 다르면 problem
    private static func difference(_ a: SpoonLayout, _ b: SpoonLayout) -> (value: CGFloat, problem: String?) {
        var m: CGFloat = 0
        func d(_ p: CGPoint, _ q: CGPoint) { m = max(m, abs(p.x - q.x), abs(p.y - q.y)) }
        func r(_ x: CGFloat, _ y: CGFloat) { m = max(m, abs(x - y)) }
        guard a.buttons.count == b.buttons.count else { return (m, "buttons \(a.buttons.count)≠\(b.buttons.count)") }
        for s in a.buttons {
            guard let t = b.buttons.first(where: { $0.button == s.button }) else { return (m, "missing \(s.button.name)") }
            d(s.center, t.center); r(s.radius, t.radius)
            if s.pill != t.pill || s.label != t.label || abs(s.stretch - t.stretch) > 0.001 { return (m, "shape \(s.button.name)") }
        }
        if (a.dpadCenter == nil) != (b.dpadCenter == nil) { return (m, "dpad") }
        if let p = a.dpadCenter, let q = b.dpadCenter { d(p, q); r(a.dpadRadius, b.dpadRadius) }
        for (s, t) in [(a.leftStick, b.leftStick), (a.rightStick, b.rightStick)] {
            if (s == nil) != (t == nil) { return (m, "stick") }
            if let s, let t {
                d(s.restCenter, t.restCenter); r(s.baseRadius, t.baseRadius)
                if s.floating != t.floating { return (m, "floating") }
            }
        }
        if (a.betweenViewMenu == nil) != (b.betweenViewMenu == nil) { return (m, "orb") }
        if let p = a.betweenViewMenu, let q = b.betweenViewMenu { d(p, q) }
        return (m, nil)
    }

    /// 빌드 23 의 PadPrefs 모양 (새 필드 없이 합성 Decodable — 모르는 키는 무시한다)
    private struct Build23Pad: Decodable {
        var kind: PadKind, scale: Double, opacity: Double, floatingStick: Bool, showLabels: Bool, haptics: Bool, leftHanded: Bool
    }
    private struct Build23Dish: Decodable { var pad: Build23Pad?; var coverFile: String? }

    static func compatibility() {
        var ok = true
        func check(_ c: Bool, _ what: String) { if !c { ok = false; log("FAIL compat \(what)") } }
        // 1) 빌드 23 이 쓴 게임별 설정 → 새 필드 nil, 기본 배치 그대로
        let old = #"{"pad":{"kind":"standard","scale":1.1,"opacity":0.5,"floatingStick":false,"showLabels":true,"haptics":true,"leftHanded":false},"fpsLimit":"fps30"}"#
        if let p = try? JSONDecoder().decode(DishPrefs.self, from: Data(old.utf8)), let pad = p.pad {
            check(pad.skin == nil && pad.layouts == nil && pad.effectiveSkin == SpoonSkin.defaultID, "old fields")
            check(pad.kind == .standard && pad.scale == 1.1 && !pad.floatingStick, "old values")
            let size = CGSize(width: 852, height: 393), safe: SpoonLayout.Insets = (0, 59, 21, 59)
            let a = SpoonLayout.make(prefs: pad, size: size, safe: safe, idiom: .phone)
            let b = SpoonLayout.make(size: size, safe: safe, kind: .standard, scale: 1.1, floatingStick: false, idiom: .phone)
            check(difference(a, b).value == 0 && difference(a, b).problem == nil, "old layout")
        } else { check(false, "decode build 23 json") }
        // 2) 새 빌드가 쓴 설정을 빌드 23 모양으로 읽기
        var pad = PadPrefs(kind: .simple, skin: "retro-gray")
        let size = CGSize(width: 852, height: 393), safe: SpoonLayout.Insets = (0, 59, 21, 59)
        let base = SpoonLayout.make(prefs: pad, size: size, safe: safe, idiom: .phone)
        pad.layouts = ["phone.landscape.simple": SpoonLayout.arrangement(from: base, size: size, safe: safe, k: 1)]
        if let d = try? JSONEncoder().encode(DishPrefs(pad: pad)) {
            check((try? JSONDecoder().decode(Build23Dish.self, from: d))?.pad?.kind == .simple, "new json read by build 23")
            check((try? JSONDecoder().decode(DishPrefs.self, from: d))?.pad == pad, "new json round trip")
            check(d.count < 8 * 1024, "size \(d.count)")
        } else { check(false, "encode") }
        // 3) 깨진 배치·스킨 값: 패드 설정은 남고 그 값만 버림
        let broken = #"{"pad":{"kind":"retro","scale":0.9,"opacity":0.5,"floatingStick":true,"showLabels":false,"haptics":false,"leftHanded":false,"skin":42,"layouts":{"phone.landscape.retro":{"elements":[{"type":"button","button":"zz","anchor":"topLeft","x":1,"y":2,"radius":3},{"type":"dpad","anchor":"bottomLeft","x":90,"y":-90,"radius":60}]},"bad.key":{"elements":[]},"pad.portrait.full":"nope"}}}"#
        if let p = try? JSONDecoder().decode(DishPrefs.self, from: Data(broken.utf8)), let pad = p.pad {
            check(pad.kind == .retro && !pad.haptics && pad.skin == nil, "broken keeps others")
            check(pad.layouts?.keys.sorted() == ["phone.landscape.retro"] && pad.layouts?["phone.landscape.retro"]?.elements.count == 1, "broken layouts filtered")
        } else { check(false, "decode broken json") }
        log("selftest compat \(ok ? "ok" : "FAIL")")
    }

    private static func log(_ m: String) { NSLog("[Spoon] \(m)") }
}
#endif

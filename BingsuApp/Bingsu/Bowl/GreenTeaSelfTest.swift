#if DEBUG
import Foundation

/// 디버그 자가 테스트 (`BINGSU_SELFTEST=1`, 앱을 켤 때 한 번). 결과는 `[GreenTea] selftest …` 로그.
/// - 스킴 핸들러 쓰기 규칙: `save/` 아래 저장 이름만 PUT·DELETE·MOVE, `save` 자체만 MKCOL, 그 밖은 거부
/// - 경로 조각: `..`·`\`·`:`·숨김 거부
/// - 암호화 표지 풀기 왕복, package.json 기본 이름은 저장 폴더 이름으로 안 씀
enum GreenTeaSelfTest {
    static func run() {
        var fails = 0, checks = 0
        func check(_ c: Bool, _ what: String) { checks += 1; if !c { fails += 1; NSLog("[GreenTea] selftest FAIL \(what)") } }
        typealias H = GreenTeaSchemeHandler
        func allowed(_ method: String, _ path: String) -> Bool {
            guard let parts = H.segments(path: path) else { return false }
            return H.writeAllowed(method: method, H.target(parts))
        }

        // 경로 규칙 표 (명세 §8: 10개 이상)
        let table: [(String, String, Bool)] = [
            ("PUT", "/save/file1.rmmzsave", true),
            ("PUT", "/save/global.rpgsave", true),
            ("PUT", "/save/file1.rmmzsave_", true),        // MZ 저장 중 임시 이름
            ("PUT", "/save/file3.rpgsave.bak", true),      // MV 백업
            ("MOVE", "/Save/config.rmmzsave", true),       // 폴더 이름 대소문자는 무시
            ("DELETE", "/save/file1.rmmzsave_", true),
            ("MKCOL", "/save", true),
            ("MKCOL", "/save/sub", false),
            ("PUT", "/save", false),
            ("PUT", "/data/System.json", false),
            ("PUT", "/index.html", false),
            ("PUT", "/save/../data/file1.rpgsave", false),
            ("PUT", "/save/sub/file1.rpgsave", false),
            ("PUT", "/save/screenshot.png", false),
            ("PUT", "/save/save.json", false),
            ("PUT", "/save/.file1.rpgsave", false),
            ("PUT", "/save/file1.RPGSAVE", false),         // 확장자는 규칙 그대로 (소문자)
            ("PUT", "/save/" + String(repeating: "a", count: 65) + ".rpgsave", false),
            ("DELETE", "/save", false),
            ("POST", "/save/file1.rpgsave", false),
        ]
        for (m, p, want) in table { check(allowed(m, p) == want, "\(m) \(p) → \(want ? "허용" : "거부")") }

        // 경로 조각 거부
        for bad in ["/a/../b", "/a\\b", "/C:/x", "/.git/config", "/img/\0.png"] { check(H.segments(path: bad) == nil, "조각 거부 \(bad)") }
        check(H.segments(path: "/img/titles1/Title.png") == ["img", "titles1", "Title.png"], "조각 나누기")
        check(H.target(["save"]) == .saveDir && H.target(["save", "file1.rpgsave"]) == .saveFile("file1.rpgsave")
              && H.target(["save", "x.png"]) == .saveOther && H.target(["img", "a.png"]) == .game(["img", "a.png"]), "대상 분류")
        check(H.segments(URL(string: "bingsu-mv://evil/save/file1.rpgsave")!) == nil, "다른 호스트 거부")

        // 암호화 표지: 머리 16바이트 + XOR 16바이트 왕복
        let key = "0123456789abcdef0123456789abcdef"
        let plain = Data((0..<64).map { UInt8($0 * 3 & 0xff) })
        var enc = Data("RPGMV".utf8) + Data([0, 0, 0, 0, 3, 1, 0, 0, 0, 0, 0])
        var head = [UInt8](plain.prefix(16))
        let kb = RPGMakerCrypt.keyBytes(key)!
        for i in 0..<16 { head[i] ^= kb[i] }
        enc += Data(head) + plain.dropFirst(16)
        check(RPGMakerCrypt.decrypt(enc, keyHex: key) == plain, "암호화 풀기 왕복")
        check(RPGMakerCrypt.decrypt(Data(repeating: 0, count: 64), keyHex: key) == nil, "머리 없는 파일 거부")

        // 저장 폴더 이름
        check(MVMZProbe.genericPackageNames.contains("kadokawa/rpgmv") && MVMZProbe.genericPackageNames.contains("rmmz-game"), "기본 package 이름")
        check(Delivery.isMVMZSave("file1.rpgsave") && Delivery.isMVMZSave("global.rmmzsave") && !Delivery.isMVMZSave("file1.rmmzsave_")
              && !Delivery.isMVMZSave("file1.rpgsave.bak"), "PC 세이브 옮기기 이름")
        check(IceTray.safeName("file1.rmmzsave", recipe: .rpgMakerMV) && !IceTray.safeName("file1.rmmzsave_", recipe: .rpgMakerMV)
              && !IceTray.safeName("file1.rpgsave.bak", recipe: .rpgMakerMV) && IceTray.safeName("Game.rxdata"), "얼음틀 확장자")

        NSLog("[GreenTea] selftest \(fails == 0 ? "OK" : "FAILED") \(checks - fails)/\(checks)")
    }
}
#endif

#if DEBUG
import Foundation
import UIKit
import ZIPFoundation

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

        // 저장 폴더 한도
        let mb = 1024 * 1024
        check(H.fitsQuota(existing: [:], name: "file1.rmmzsave", size: 16 * mb), "한도: 빈 폴더")
        check(!H.fitsQuota(existing: ["a.rmmzsave": H.maxSaveTotalBytes], name: "b.rmmzsave", size: 1), "한도: 합계 초과")
        check(H.fitsQuota(existing: ["a.rmmzsave": H.maxSaveTotalBytes], name: "a.rmmzsave", size: 16 * mb), "한도: 덮어쓰기는 옛 크기를 뺀다")
        let full = Dictionary(uniqueKeysWithValues: (0..<H.maxSaveFiles).map { ("f\($0).rmmzsave", 1) })
        check(!H.fitsQuota(existing: full, name: "new.rmmzsave", size: 1), "한도: 파일 수 초과")
        check(H.fitsQuota(existing: full, name: "f0.rmmzsave", size: 1), "한도: 파일 수가 찼어도 덮어쓰기는 된다")

        // zip 항목 겹침
        func ledgerOK(_ items: [(String, Bool)]) -> Bool {
            var l = SafeUnzip.PathLedger()
            return items.allSatisfy { l.add($0.0.split(separator: "/").map(String.init), isDirectory: $0.1) }
        }
        check(ledgerOK([("Data", true), ("Data/a.rxdata", false), ("Data", true), ("Data/b.rxdata", false)]), "zip: 폴더 항목은 겹쳐도 된다")
        check(!ledgerOK([("a.txt", false), ("a.txt", false)]), "zip: 같은 파일 둘")
        check(!ledgerOK([("caf\u{E9}.txt", false), ("cafe\u{301}.txt", false)]), "zip: 정규화만 다른 이름")
        check(!ledgerOK([("a", false), ("a/b.txt", false)]), "zip: 파일 아래 파일")
        check(!ledgerOK([("a/b.txt", false), ("a", false)]), "zip: 폴더와 같은 이름의 파일")
        check(!ledgerOK([("a", true), ("a", false)]), "zip: 폴더 항목과 같은 이름의 파일")
        check(ledgerOK([("Data/a.txt", false), ("data/a.txt", false)]), "zip: 대소문자만 다르면 따로 둔다")

        // zip 항목 이름 풀기
        let all256 = Data((0...255).map { UInt8($0) })
        check(String(data: all256, encoding: SafeUnzip.cp437)?.data(using: SafeUnzip.cp437) == all256, "zip 이름: CP437 왕복이 바이트를 그대로 돌려준다")
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        check(SafeUnzip.decodeName(Data("Docs/조작키 안내.txt".decomposedStringWithCanonicalMapping.utf8)).precomposedStringWithCanonicalMapping == "Docs/조작키 안내.txt", "zip 이름: 표시 없는 UTF-8 한글")
        check(SafeUnzip.decodeName("Graphics/주인공.png".data(using: cp949)!) == "Graphics/주인공.png", "zip 이름: CP949 한글")
        check(SafeUnzip.decodeName("Graphics/ゆうしゃ.png".data(using: .shiftJIS)!) == "Graphics/ゆうしゃ.png", "zip 이름: Shift-JIS 가나")
        func comps(_ s: String) -> [String]? { SafeUnzip.safeComponents(s) }
        check(comps(#"g/Graphics/Characters/\237W\272\361_\305\326\272\361\265\345.png"#) == ["g", "Graphics", "Characters", "웉비_텅비드.png"], "zip 이름: 맥 8진수 이스케이프 → CP949 이름")
        check(comps("g/Docs/조작키.txt".decomposedStringWithCanonicalMapping) == ["g", "Docs", "조작키.txt"], "zip 이름: NFD 조각은 NFC 로")
        check(comps(#"..\..\evil"#) == nil, #"zip 이름: ..\..\evil 거부"#)
        check(comps(#"a\b"#) == nil, #"zip 이름: a\b 거부"#)
        check(comps(#"a\057b"#) == nil, #"zip 이름: \057(/) 복원 거부"#)
        check(comps(#"a\134b"#) == nil, #"zip 이름: \134(\) 복원 거부"#)
        check(comps(#"\056\056"#) == nil, #"zip 이름: \056\056(..) 복원 거부"#)
        check(comps(#"a\000b"#) == nil, #"zip 이름: \000 복원 거부"#)
        check(comps(#"a\400"#) == nil && comps(#"a\12"#) == nil, "zip 이름: 8진수 3자리(0-377)가 아니면 거부")
        check(comps("a/../b") == nil && comps("/a") == nil && comps("a:b") == nil, "zip 이름: .. · 절대 경로 · 콜론 거부")

        // Info-ZIP Unicode Path (0x7075): 버전 1 + 원래 이름 바이트의 CRC32 + UTF-8 이름
        do {
            let orig = Data("Audio/BGM/Route 1.mid".utf8), name = Data("Audio/BGM/Routé 1.mid".utf8)
            func field(version: UInt8, crc: UInt32) -> Data {
                var body = Data([version]); withUnsafeBytes(of: crc.littleEndian) { body.append(contentsOf: $0) }; body.append(name)
                var f = Data([0x75, 0x70, UInt8(body.count & 255), UInt8(body.count >> 8)]); f.append(body); return f
            }
            let other = Data([0x0A, 0x00, 0x04, 0x00, 1, 2, 3, 4]) // 앞에 다른 확장 영역(NTFS 시각 등)이 있어도 찾는다
            let crc = orig.crc32(checksum: 0)
            check(SafeUnzip.unicodePath(extra: other + field(version: 1, crc: crc), nameBytes: orig) == "Audio/BGM/Routé 1.mid", "0x7075: CRC 가 맞으면 그 이름")
            check(SafeUnzip.unicodePath(extra: field(version: 1, crc: crc ^ 1), nameBytes: orig) == nil, "0x7075: CRC 가 틀리면 무시")
            check(SafeUnzip.unicodePath(extra: field(version: 2, crc: crc), nameBytes: orig) == nil, "0x7075: 버전이 1이 아니면 무시")
            check(SafeUnzip.unicodePath(extra: Data([0x75, 0x70, 0xFF, 0x00, 1]), nameBytes: orig) == nil, "0x7075: 길이가 넘치면 무시")
        }

        // 같은 경로의 파일이 다시 나올 때: 크기·CRC32 가 같으면 건너뛰고, 다르면 따로 알린다
        do {
            typealias ID = SafeUnzip.PathLedger.FileID
            var l = SafeUnzip.PathLedger()
            let bgm = ["Audio", "BGM", "Route 1.mid"]
            check(l.add(bgm, isDirectory: false, id: ID(size: 5822, crc: 1)) == .added, "zip 중복: 첫 항목")
            check(l.add(bgm, isDirectory: false, id: ID(size: 5822, crc: 1)) == .sameFile, "zip 중복: 같은 크기·CRC 는 건너뜀")
            check(l.add(["Audio", "BGM", "Route 1.mid".decomposedStringWithCanonicalMapping], isDirectory: false, id: ID(size: 5822, crc: 1)) == .sameFile, "zip 중복: 정규화만 다른 같은 내용")
            check(l.add(bgm, isDirectory: false, id: ID(size: 5822, crc: 2)) == .differentFile, "zip 중복: CRC 가 다르면 거부")
            check(l.add(bgm, isDirectory: false, id: ID(size: 5823, crc: 1)) == .differentFile, "zip 중복: 크기가 다르면 거부")
            check(l.add(bgm, isDirectory: true, id: nil) == .clash, "zip 중복: 같은 이름의 폴더")
        }
        func dupZip(_ second: Data) -> Result<[String], Error> {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("greentea-dup-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let zipURL = dir.appendingPathComponent("dup.zip")
                let archive = try Archive(url: zipURL, accessMode: .create)
                for body in [Data("MThd same".utf8), second] {
                    try archive.addEntry(with: "Audio/BGM/Route 1.mid", type: .file, uncompressedSize: Int64(body.count),
                                         provider: { pos, size in body.subdata(in: Int(pos)..<Int(pos) + size) })
                }
                let cn = SafeUnzip.centralNames(zipURL)
                check(cn?.count == 2 && cn?.allSatisfy { $0.raw == Data("Audio/BGM/Route 1.mid".utf8) && $0.unicode == nil } == true, "중앙 디렉터리 직접 읽기")
                let out = dir.appendingPathComponent("out")
                try SafeUnzip.unzip(zipURL, to: out, progress: { _ in })
                return .success(try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("Audio/BGM").path))
            } catch { return .failure(error) }
        }
        if case .success(let names) = dupZip(Data("MThd same".utf8)) { check(names == ["Route 1.mid"], "zip 중복: 같은 내용이면 하나만 풀림") }
        else { check(false, "zip 중복: 같은 내용인데 거부됨") }
        if case .failure(let e) = dupZip(Data("MThd diff".utf8)), case .duplicateName? = e as? SafeUnzip.UnzipError { check(true, "zip 중복: 다른 내용은 거부") }
        else { check(false, "zip 중복: 다른 내용인데 통과하거나 다른 오류") }

        // 게임 밖 주소 (로그인 시트는 실제 로그인 주소만)
        func route(_ s: String, game: String = "game.example", clicked: Bool = false) -> ExternalLink.Route { ExternalLink.route(URL(string: s)!, gameHost: game, clicked: clicked) }
        check(route("https://accounts.google.com/o/oauth2") == .loginSheet && route("https://DISCORD.com/oauth2") == .loginSheet, "주소: 로그인 업체")
        check(route("https://api.game.example/auth") == .loginSheet, "주소: 게임의 하위 주소")
        check(route("https://game.example/x") == .stay && route("https://GAME.example/x") == .stay, "주소: 게임 안")
        check(route("https://evil.example/login") == .ask, "주소: 모르는 곳")
        check(route("https://accounts.google.com.evil.example/") == .ask && route("https://notgame.example/") == .ask, "주소: 비슷한 이름")
        check(route("https://accounts.google.com@evil.example/") == .ask && route("https://u@accounts.google.com/") == .ask, "주소: 사용자 정보 속임")
        check(route("http://accounts.google.com/") == .ask && route("https://accounts.google.com:8443/") == .ask, "주소: 암호화 없음·다른 포트")
        check(route("https://evil.example/", clicked: true) == .safari, "주소: 누른 링크는 사파리")
        check(route("httpx://evil.example/") == .stay && !ExternalLink.isWeb(URL(string: "httpx://a")!) && !ExternalLink.isWeb(URL(string: "file:///a")!), "주소: http 로 시작하는 다른 방식")

        // 웹 저장소 번호
        check(WebStoreID.legacyID("dragon1") == WebStoreID.legacyID("dragona"), "저장소: 예전 방식은 겹친다")
        check(WebStoreID.hashedID("dragon1") != WebStoreID.hashedID("dragona"), "저장소: 새 방식은 안 겹친다")
        var storeTable: [String: String] = [:]
        WebStoreID.adoptLegacy(["dragon1", "dragona", "other"], table: &storeTable)
        check(storeTable["dragon1"] == WebStoreID.legacyID("dragon1").uuidString && storeTable["other"] == WebStoreID.legacyID("other").uuidString, "저장소: 있던 게임은 번호 유지")
        check(storeTable["dragona"] == nil, "저장소: 겹친 게임은 옮기지 않는다")
        check(WebStoreID.assign("dragona", table: &storeTable) == WebStoreID.hashedID("dragona"), "저장소: 겹친 게임은 새 번호")
        check(WebStoreID.assign("dragon1", table: &storeTable) == WebStoreID.legacyID("dragon1"), "저장소: 표에 있으면 그대로")
        check(WebStoreID.assign("dragona", table: &storeTable) == WebStoreID.hashedID("dragona"), "저장소: 다시 물어도 같다")

        // 저장 폴더 이름 비교
        check(Delivery.saveFolderKey(dataPathApp: "my/game", title: "t") == "my_game", "저장 폴더: 고친 이름으로 비교")
        check(Delivery.saveFolderKey(dataPathApp: " ..caf\u{65}\u{301} ", title: "t") == "caf\u{E9}", "저장 폴더: 앞 점·공백·정규화")

        // 표지 그림
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        let bigPNG = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000), format: rendererFormat).pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        }
        let shrunk = CoverImage.load(data: bigPNG)
        check(shrunk.map { Int($0.size.width) == CoverImage.maxSide && Int($0.size.height) == CoverImage.maxSide / 2 } == true, "표지: 큰 그림은 줄여 읽는다")
        check(CoverImage.isAcceptable(bigPNG) && !CoverImage.isAcceptable(Data("nope".utf8)), "표지: PNG 만 받는다")
        check(CoverImage.fits(width: 8000, height: 8000) && !CoverImage.fits(width: 8001, height: 8000) && !CoverImage.fits(width: 0, height: 5) && !CoverImage.fits(width: Int.max, height: 2), "표지: 픽셀 한도")
        func crc32(_ d: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in d { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) } }
            return ~c
        }
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        let ihdr: [UInt8] = Array("IHDR".utf8) + be(60000) + be(60000) + [8, 6, 0, 0, 0]
        let bomb = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be(13) + ihdr + be(crc32(ihdr)))
        check(CoverImage.load(data: bomb) == nil && !CoverImage.isAcceptable(bomb), "표지: 60000×60000 머리 거부")
        // Game.exe 아이콘처럼 .ico 로 감싼 BMP (16×16)
        var bmp = Data([40, 0, 0, 0, 16, 0, 0, 0, 32, 0, 0, 0, 1, 0, 32, 0])
        bmp += [UInt8](repeating: 0, count: 24) + [UInt8](repeating: 0x80, count: 16 * 16 * 4) + [UInt8](repeating: 0, count: 16 * 4)
        var icoFile = Data([0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0])
        icoFile += withUnsafeBytes(of: UInt32(bmp.count).littleEndian) { Data($0) }
        icoFile += withUnsafeBytes(of: UInt32(22).littleEndian) { Data($0) }
        icoFile += bmp
        check(CoverImage.load(data: icoFile) != nil, "표지: BMP 아이콘")

        // 백업 한도
        check(IglooEngine.canDownloadBackup(count: 0, bytes: 0), "백업: 빈 폴더")
        check(!IglooEngine.canDownloadBackup(count: IglooEngine.maxLocalBackups, bytes: 0), "백업: 개수 한도")
        check(!IglooEngine.canDownloadBackup(count: 1, bytes: IglooEngine.maxLocalBackupBytes - Freezer.maxBytes + 1), "백업: 용량 한도")

        // 심볼릭 링크 (Electron 핸들러, 폴더 가져오기)
        let linkDir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString)", isDirectory: true)
        let gameDir = linkDir.appendingPathComponent("game", isDirectory: true), dist = gameDir.appendingPathComponent("dist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try? Data("a".utf8).write(to: dist.appendingPathComponent("index.html"))
        try? Data("s".utf8).write(to: linkDir.appendingPathComponent("secret.txt"))
        check(!Delivery.containsLink(in: gameDir), "링크: 없는 폴더")
        let pokemon = PokemonSchemeHandler(gameRoot: gameDir)
        check(pokemon.resolve(URL(string: "pokemon://game/index.html")!) != nil, "링크: 보통 파일은 읽는다")
        try? FileManager.default.createSymbolicLink(at: dist.appendingPathComponent("out.txt"), withDestinationURL: linkDir.appendingPathComponent("secret.txt"))
        check(pokemon.resolve(URL(string: "pokemon://game/out.txt")!) == nil, "링크: 밖을 가리키면 안 읽는다")
        check(Delivery.containsLink(in: gameDir), "링크: 폴더 가져오기 거부")
        try? FileManager.default.removeItem(at: linkDir)

        NSLog("[GreenTea] selftest \(fails == 0 ? "OK" : "FAILED") \(checks - fails)/\(checks)")
    }
}
#endif

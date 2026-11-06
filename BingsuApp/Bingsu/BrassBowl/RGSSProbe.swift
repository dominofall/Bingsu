import Foundation

/// RPG Maker 스크립트 엔진 판 (RGSS1 = XP, RGSS2 = VX, RGSS3 = VX Ace). 엔진 설정 `rgssVersion` 값 그대로
enum RGSSVersion: Int, Codable, Comparable {
    case xp = 1, vx = 2, vxAce = 3

    static func < (a: RGSSVersion, b: RGSSVersion) -> Bool { a.rawValue < b.rawValue }
}

/// 게임 폴더를 보고 RGSS 판·RTP 를 정한다. 가져올 때(RecipeDetector)와 실행할 때(BrassBowlEngine) 같은 규칙을 쓴다.
/// 파일을 읽기만 하고 아무것도 바꾸지 않는다. 판별 순서는 docs/engines/IMPLEMENTATION-vx.md §1
/// (엔진 config.cpp 의 자동 판별 + empo MkxpProfile 을 합친 것):
/// 1. `mkxp.json` 의 `rgssVersion`(1~3)  2. 맨 위 `Game.rgss3a`/`Game.rgss2a`/`Game.rgssad`
/// 3. 맨 위 ini 의 `Scripts=` 확장자  4. `Data/Scripts.*`  5. ini `Library=` 의 `RGSS3`/`RGSS2`/`RGSS1`
enum RGSSProbe {
    struct Result: Equatable {
        /// 판별한 판. nil 이면 RPG Maker XP·VX·VX Ace 게임 단서가 없다
        var version: RGSSVersion?
        /// ini 의 `RTP=`(VX·Ace) 또는 `RTP1=`(XP) 값. 비었으면 nil
        var rtp: String?
        /// RTP 를 쓰는데 엔진 기본 스크립트가 꼭 읽는 그림(VX·Ace `Graphics/System/IconSet`, XP `Graphics/Windowskins`)이 게임에 없다
        /// → RTP 를 넣어야 제대로 보인다
        var needsRTP: Bool
        /// 게임 실행에 쓰는 스크립트가 실제로 있다 (아카이브, `Data/Scripts.*`, ini 가 가리키는 파일)
        var hasScripts: Bool
        /// 맨 위 ini 의 `Title=`
        var title: String?
    }

    static let archiveNames: [(String, RGSSVersion)] = [("game.rgss3a", .vxAce), ("game.rgss2a", .vx), ("game.rgssad", .xp)]
    static let scriptExtensions: [(String, RGSSVersion)] = [("rvdata2", .vxAce), ("rvdata", .vx), ("rxdata", .xp)]

    static func probe(folder: URL) -> Result {
        let top = entries(folder)
        let ini = gameIni(folder, top: top)
        let fields = ini.map { iniFields($0) } ?? [:]

        // 판
        var version: RGSSVersion? = mkxpJSONVersion(folder, top: top)
        let archive = archiveNames.first { a in top[a.0] != nil }
        if version == nil { version = archive?.1 }
        if version == nil, let s = fields["scripts"] { version = scriptsVersion(s) }
        let dataScripts = dataScriptsFile(folder, top: top)
        if version == nil { version = dataScripts?.1 }
        if version == nil, let lib = fields["library"]?.lowercased() {
            if lib.contains("rgss3") { version = .vxAce } else if lib.contains("rgss2") { version = .vx } else if lib.contains("rgss1") { version = .xp }
        }
        if let env = DevEnv["BINGSU_RGSS"], let n = Int(env), let v = RGSSVersion(rawValue: n) { version = v }

        // 스크립트가 실제로 있나
        var hasScripts = archive != nil || dataScripts != nil
        if !hasScripts, let s = fields["scripts"], !s.isEmpty { hasScripts = resolve(folder, s) != nil }

        // RTP
        let rtp = [fields["rtp"], fields["rtp1"]].compactMap { $0 }.first { !$0.isEmpty }
        var needsRTP = false
        if rtp != nil {
            // RTP 없이 돌게 만든 게임은 엔진 기본 스크립트가 꼭 읽는 그림을 직접 넣는다:
            // VX·Ace 는 Graphics/System/IconSet, XP 는 Graphics/Windowskins. 폴더와 아카이브(이름표만 읽음) 둘 다 본다
            let marker = (version ?? .xp) == .xp ? "graphics/windowskins/" : "graphics/system/iconset."
            var has = looseHas(folder, marker)
            if !has, let a = archive, let url = top[a.0] {
                // 이름표를 못 읽으면 필요 없다고 본다 (잘못 안내하지 않게)
                has = RGSSArchive.entryNames(url)?.contains { $0.lowercased().replacingOccurrences(of: "\\", with: "/").hasPrefix(marker) } ?? true
            }
            needsRTP = !has
        }
        let title = fields["title"].flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        return Result(version: version, rtp: rtp.map { String($0.prefix(80)) }, needsRTP: needsRTP, hasScripts: hasScripts, title: title)
    }

    /// 판만 (실행 때). 단서가 없으면 XP
    static func version(folder: URL) -> RGSSVersion { probe(folder: folder).version ?? .xp }

    // MARK: 파일 찾기 (Windows 처럼 대소문자 무시)

    /// 맨 위 항목: 소문자 이름 → URL
    private static func entries(_ folder: URL) -> [String: URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var out: [String: URL] = [:]
        for n in names.sorted() where !n.hasPrefix(".") { out[n.lowercased()] = out[n.lowercased()] ?? folder.appendingPathComponent(n) }
        return out
    }

    /// "Data\Scripts.rvdata2" 같은 상대 경로를 대소문자 무시로 찾는다. `..`·절대 경로는 받지 않는다
    static func resolve(_ folder: URL, _ rel: String) -> URL? {
        let parts = rel.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty, !parts.contains(".."), !rel.hasPrefix("/"), !rel.contains(":") else { return nil }
        var cur = folder
        for p in parts {
            guard let next = entries(cur)[p.lowercased()] else { return nil }
            cur = next
        }
        return cur
    }

    /// "graphics/system/iconset." 같은 소문자 접두어에 맞는 파일이 폴더에 있나 (대소문자 무시)
    private static func looseHas(_ folder: URL, _ marker: String) -> Bool {
        var parts = marker.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let namePrefix = parts.removeLast()
        guard let dir = resolve(folder, parts.joined(separator: "/")) else { return false }
        return entries(dir).keys.contains { $0.hasPrefix(namePrefix) && !$0.isEmpty }
    }

    private static func gameIni(_ folder: URL, top: [String: URL]) -> URL? {
        if let u = top["game.ini"] { return u }
        // exe 이름을 바꾸면 ini 이름도 따라 바뀐다. Scripts= 가 있는 ini 를 고른다
        for (name, url) in top.sorted(by: { $0.key < $1.key }) where name.hasSuffix(".ini") {
            if iniFields(url)["scripts"] != nil { return url }
        }
        return nil
    }

    private static func dataScriptsFile(_ folder: URL, top: [String: URL]) -> (URL, RGSSVersion)? {
        guard let data = top["data"] else { return nil }
        let inside = entries(data)
        for (ext, v) in scriptExtensions { if let u = inside["scripts." + ext] { return (u, v) } }
        return nil
    }

    private static func scriptsVersion(_ value: String) -> RGSSVersion? {
        let ext = (value.replacingOccurrences(of: "\\", with: "/") as NSString).pathExtension.lowercased()
        return scriptExtensions.first { $0.0 == ext }?.1
    }

    /// `mkxp.json` 의 `"rgssVersion": n` (주석 줄 무시). 0·없음이면 nil
    private static func mkxpJSONVersion(_ folder: URL, top: [String: URL]) -> RGSSVersion? {
        guard let u = top["mkxp.json"], let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("//"), t.hasPrefix("\"rgssVersion\""), let c = t.firstIndex(of: ":") else { continue }
            let num = t[t.index(after: c)...].prefix { $0 == " " || $0.isNumber }.trimmingCharacters(in: .whitespaces)
            return Int(num).flatMap(RGSSVersion.init(rawValue:))
        }
        return nil
    }

    // MARK: ini 읽기

    /// `[Game]` 칸(없으면 칸 밖)의 `키=값`. 키는 소문자. 64KB 넘는 파일은 읽지 않는다
    static func iniFields(_ url: URL) -> [String: String] {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 64 * 1024,
              let data = try? Data(contentsOf: url), let text = decodeText(data) else { return [:] }
        var out: [String: String] = [:]
        var section = ""
        // split(whereSeparator: \.isNewline) 는 CRLF 를 한 줄 끝으로 본다
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { section = line.dropFirst().dropLast().lowercased(); continue }
            guard section == "" || section == "game", !line.hasPrefix(";"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    /// ini 글자 풀기: UTF-8 → (일본어로 보이면 Shift-JIS) → CP949 → Shift-JIS.
    /// CP949 는 거의 어떤 바이트든 풀어 버려 Shift-JIS 일본어 제목이 엉뚱한 한글이 되므로, Shift-JIS 로 풀었을 때 가나가 있고
    /// 반각 가나(한국어 CP949 를 Shift-JIS 로 풀면 나오는 것)가 없으면 일본어로 본다
    static func decodeText(_ data: Data) -> String? {
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        if let s = String(data: d, encoding: .utf8) { return s }
        let sjis = String(data: d, encoding: .shiftJIS)
        if let s = sjis, looksJapanese(s) { return s }
        if let s = String(data: d, encoding: cp949) { return s }
        return sjis
    }

    private static let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    private static func looksJapanese(_ s: String) -> Bool {
        var kana = false
        for u in s.unicodeScalars {
            if (0xFF61...0xFF9F).contains(u.value) { return false }
            if (0x3040...0x30FF).contains(u.value) { kana = true }
        }
        return kana
    }
}

/// 암호화 아카이브(`Game.rgssad`·`.rgss2a`·`.rgss3a`)의 파일 이름표만 읽는다(내용은 풀지 않는다).
/// 형식: RGSSAD v1(XP·VX) 은 항목마다 이름 길이·이름·크기가 키로 가려져 있고 내용이 뒤따른다, v3(VX Ace) 은 앞에 이름표가 모여 있다.
/// 엔진 src/crypto/rgssad.cpp 와 같은 규칙. 이상한 값이 나오면 nil
enum RGSSArchive {
    static func entryNames(_ url: URL, limit: Int = 200_000) -> [String]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let total = try? fh.seekToEnd(), (try? fh.seek(toOffset: 0)) != nil,
              let head = try? fh.read(upToCount: 8), head.count == 8, head.prefix(7) == Data("RGSSAD\0".utf8) else { return nil }
        func u32() -> UInt32? {
            guard let d = try? fh.read(upToCount: 4), d.count == 4 else { return nil }
            return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        var names: [String] = []
        switch head[7] {
        case 1:
            var key: UInt32 = 0xDEADCAFE
            func next() { key = key &* 7 &+ 3 }
            while names.count < limit {
                let pos = (try? fh.offset()) ?? total
                if pos >= total { break }
                guard let rawLen = u32() else { return nil }
                let len = rawLen ^ key; next()
                guard len > 0, len <= 512, let nameBytes = try? fh.read(upToCount: Int(len)), nameBytes.count == Int(len) else { return nil }
                var plain = [UInt8](repeating: 0, count: nameBytes.count)
                for (i, b) in nameBytes.enumerated() { plain[i] = b ^ UInt8(key & 0xFF); next() }
                guard let rawSize = u32() else { return nil }
                let size = UInt64(rawSize ^ key); next()
                guard let here = try? fh.offset(), here + size <= total, (try? fh.seek(toOffset: here + size)) != nil else { return nil }
                names.append(String(decoding: plain, as: UTF8.self))
            }
        case 3:
            guard let base = u32() else { return nil }
            let key = base &* 9 &+ 3
            while names.count < limit {
                guard let off = u32(), let size = u32(), u32() != nil, let rawLen = u32() else { return nil }
                if off ^ key == 0 { break }
                let len = rawLen ^ key
                guard UInt64(off ^ key) + UInt64(size ^ key) <= total, len > 0, len <= 512,
                      let nameBytes = try? fh.read(upToCount: Int(len)), nameBytes.count == Int(len) else { return nil }
                let plain = nameBytes.enumerated().map { i, b in b ^ UInt8((key >> (8 * UInt32(i % 4))) & 0xFF) }
                names.append(String(decoding: plain, as: UTF8.self))
            }
        default:
            return nil
        }
        return names
    }
}

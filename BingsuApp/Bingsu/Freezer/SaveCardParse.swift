import Foundation
import UIKit

/// 세이브 카드(빌드 49)의 두 번째 길: 게임이 옆 정보를 남기지 않은 세이브(PC 에서 가져온 것·예전 것)를 파일에서 읽는다.
/// 읽기만 하고, 크기·깊이·개수를 묶어 이상한 파일이 앱을 멈추지 않게 한다. 못 읽으면 nil (카드는 시각만 보인다).
/// - RPG Maker XP·VX·VX Ace·Essentials: Ruby Marshal 을 앞에서부터 필요한 만큼만 읽는다 (`Marshal`)
/// - MV·MZ: 게임의 저장 목록(global)에 칸별 이름·캐릭터·플레이 시간이 있다. MZ 는 zlib, MV 는 LZString(base64)
enum SaveCardParse {
    static let maxFileBytes = 16 * 1024 * 1024

    // MARK: Ruby Marshal (읽기 전용 최소판)

    indirect enum RV {
        case none, bool(Bool), int(Int), float(Double)
        case str(String)
        case sym(String)
        case array([RV])
        case hash([(RV, RV)])
        case object(String, [String: RV])
        case user(String)          // _dump 로 쓴 객체 (Table·Color 등). 내용은 안 본다
        case other

        var int: Int? { if case .int(let i) = self { return i }; return nil }
        var string: String? {
            switch self { case .str(let s), .sym(let s): return s; default: return nil }
        }
        var array: [RV]? { if case .array(let a) = self { return a }; return nil }
        var className: String? {
            switch self { case .object(let c, _), .user(let c): return c; default: return nil }
        }
        func ivar(_ name: String) -> RV? {
            if case .object(_, let iv) = self { return iv["@" + name] }
            return nil
        }
        /// 기호 키 해시에서 값 (`:player`)
        func key(_ name: String) -> RV? {
            guard case .hash(let pairs) = self else { return nil }
            return pairs.first { $0.0.string == name }?.1
        }
    }

    /// Marshal 4.8 읽개. 한 파일 안에 이어 쓴 객체들을 차례로 읽는다
    final class Marshal {
        private let d: [UInt8]
        private var p = 0
        private var syms: [String] = []
        private var objs: [RV] = []
        private var steps = 0
        private static let maxSteps = 2_000_000

        init(_ data: Data) { d = [UInt8](data) }

        var atEnd: Bool { p >= d.count }

        /// 다음 최상위 객체 (머리 4.8 확인)
        func next() -> RV? {
            guard p + 2 <= d.count, d[p] == 4, d[p + 1] == 8 else { return nil }
            p += 2
            syms.removeAll(keepingCapacity: true)
            objs.removeAll(keepingCapacity: true)
            return try? value(0)
        }

        private struct Bad: Error {}

        private func byte() throws -> UInt8 {
            guard p < d.count else { throw Bad() }
            defer { p += 1 }
            return d[p]
        }

        private func long() throws -> Int {
            let c = Int(Int8(bitPattern: try byte()))
            if c == 0 { return 0 }
            if c > 4 { return c - 5 }
            if c < -4 { return c + 5 }
            if c > 0 {
                var x = 0
                for i in 0..<c { x |= Int(try byte()) << (8 * i) }
                return x
            }
            var x = -1
            for i in 0..<(-c) { x &= ~(0xff << (8 * i)); x |= Int(try byte()) << (8 * i) }
            return x
        }

        private func bytes() throws -> [UInt8] {
            let n = try long()
            guard n >= 0, p + n <= d.count else { throw Bad() }
            defer { p += n }
            return Array(d[p..<p + n])
        }

        private func symbol() throws -> String {
            let t = try byte()
            if t == UInt8(ascii: ";") {
                let i = try long()
                guard syms.indices.contains(i) else { throw Bad() }
                return syms[i]
            }
            guard t == UInt8(ascii: ":") else { throw Bad() }
            let s = String(decoding: try bytes(), as: UTF8.self)
            syms.append(s)
            return s
        }

        private func reserve() -> Int { objs.append(.other); return objs.count - 1 }

        private func value(_ depth: Int) throws -> RV {
            steps += 1
            guard depth < 64, steps < Self.maxSteps else { throw Bad() }
            let t = try byte()
            switch t {
            case UInt8(ascii: "0"): return .none
            case UInt8(ascii: "T"): return .bool(true)
            case UInt8(ascii: "F"): return .bool(false)
            case UInt8(ascii: "i"): return .int(try long())
            case UInt8(ascii: ":"): p -= 1; return .sym(try symbol())
            case UInt8(ascii: ";"): p -= 1; return .sym(try symbol())
            case UInt8(ascii: "@"):
                let i = try long()
                return objs.indices.contains(i) ? objs[i] : .other
            case UInt8(ascii: "I"):
                let v = try value(depth + 1)
                let n = try long()
                for _ in 0..<max(0, n) { _ = try symbol(); _ = try value(depth + 1) }
                return v
            case UInt8(ascii: "\""):
                let i = reserve()
                let raw = try bytes()
                // RGSS1·2 는 인코딩 표시 없는 UTF-8. 잘못된 바이트는 대체 문자로
                let v = RV.str(String(decoding: raw, as: UTF8.self))
                objs[i] = v
                return v
            case UInt8(ascii: "f"):
                let i = reserve()
                let s = String(decoding: try bytes(), as: UTF8.self)
                let v = RV.float(Double(s) ?? 0)
                objs[i] = v
                return v
            case UInt8(ascii: "l"):
                let i = reserve()
                _ = try byte()
                let n = try long()
                guard n >= 0, p + n * 2 <= d.count else { throw Bad() }
                p += n * 2
                objs[i] = .other
                return .other
            case UInt8(ascii: "["):
                let i = reserve()
                let n = try long()
                guard n >= 0, n <= 1_000_000 else { throw Bad() }
                var a: [RV] = []
                a.reserveCapacity(min(n, 1024))
                for _ in 0..<n { a.append(try value(depth + 1)) }
                objs[i] = .array(a)
                return .array(a)
            case UInt8(ascii: "{"), UInt8(ascii: "}"):
                let i = reserve()
                let n = try long()
                guard n >= 0, n <= 1_000_000 else { throw Bad() }
                var h: [(RV, RV)] = []
                for _ in 0..<n { let k = try value(depth + 1); h.append((k, try value(depth + 1))) }
                if t == UInt8(ascii: "}") { _ = try value(depth + 1) }
                objs[i] = .hash(h)
                return .hash(h)
            case UInt8(ascii: "o"):
                let i = reserve()
                let cls = try symbol()
                let n = try long()
                guard n >= 0, n <= 100_000 else { throw Bad() }
                var iv: [String: RV] = [:]
                for _ in 0..<n { let k = try symbol(); iv[k] = try value(depth + 1) }
                objs[i] = .object(cls, iv)
                return objs[i]
            case UInt8(ascii: "S"):
                let i = reserve()
                let cls = try symbol()
                let n = try long()
                guard n >= 0, n <= 100_000 else { throw Bad() }
                var iv: [String: RV] = [:]
                for _ in 0..<n { let k = try symbol(); iv["@" + k] = try value(depth + 1) }
                objs[i] = .object(cls, iv)
                return objs[i]
            case UInt8(ascii: "u"):
                let i = reserve()
                let cls = try symbol()
                _ = try bytes()
                objs[i] = .user(cls)
                return .user(cls)
            case UInt8(ascii: "U"):
                let i = reserve()
                let cls = try symbol()
                let inner = try value(depth + 1)
                // marshal_load 객체: 안의 값을 그대로 쓸 수 있으면 그 모양 그대로 (Essentials 일부 클래스)
                let v: RV
                if case .hash = inner { v = inner } else { v = .user(cls) }
                objs[i] = v
                return v
            case UInt8(ascii: "e"):
                _ = try symbol()
                return try value(depth + 1)
            case UInt8(ascii: "C"):
                _ = try symbol()
                return try value(depth + 1)
            case UInt8(ascii: "/"):
                let i = reserve()
                _ = try bytes(); _ = try byte()
                return objs[i]
            case UInt8(ascii: "c"), UInt8(ascii: "m"), UInt8(ascii: "M"):
                let i = reserve()
                _ = try bytes()
                return objs[i]
            case UInt8(ascii: "d"):
                throw Bad()
            default:
                throw Bad()
            }
        }
    }

    /// 파일 앞에서부터 객체를 최대 n 개
    static func marshalObjects(_ url: URL, max n: Int) -> [RV] {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileBytes,
              let data = try? Data(contentsOf: url) else { return [] }
        let m = Marshal(data)
        var out: [RV] = []
        while out.count < n, !m.atEnd, let v = m.next() { out.append(v) }
        return out
    }

    // MARK: RPG Maker XP·VX·VX Ace·Essentials

    /// 세이브 파일에서 카드 정보. `fps` 는 플레이 시간 계산용 (XP·Essentials 40, VX 60)
    static func rgss(_ url: URL, gameFolder: URL, rgss: RGSSVersion) -> SaveCard.Info? {
        let objs = marshalObjects(url, max: 16)
        guard let first = objs.first else { return nil }
        var info = SaveCard.Info()
        let fps = rgss == .xp ? 40.0 : 60.0

        // Essentials v19~21: 해시 하나 (:player, :frame_count, :map_factory …)
        if case .hash = first, let player = first.key("player") {
            trainer(player, into: &info)
            if let f = first.key("frame_count")?.int { info.play = Int(Double(f) / 60.0) }
            if let pt = first.key("stats")?.ivar("play_time"), case .float(let s) = pt { info.play = Int(s) }
            if let gp = first.key("game_player"), let c = gp.ivar("character_name")?.string, !c.isEmpty {
                info.chars = [.init(name: c, index: 0)]
            }
            if let mf = first.key("map_factory"), let maps = mf.ivar("maps")?.array, let m = maps.first, let id = m.ivar("map_id")?.int {
                info.map = mapName(id, gameFolder: gameFolder, rgss: rgss)
            }
            return info
        }
        // VX Ace: 머리 해시 {:characters, :playtime_s} + 내용 해시 {:map …}
        if case .hash = first, let chars = first.key("characters")?.array {
            info.chars = sprites(chars)
            if let s = first.key("playtime_s")?.string { info.play = hms(s) }
            if objs.count > 1, let id = objs[1].key("map")?.ivar("map_id")?.int {
                info.map = mapName(id, gameFolder: gameFolder, rgss: rgss)
            }
            return info
        }
        // 옛 Essentials(v16~18): 트레이너 객체가 맨 앞, 다음 frame_count, … 다섯째가 맵 번호
        if case .object = first, first.ivar("party") != nil {
            trainer(first, into: &info)
            if objs.count > 1, let f = objs[1].int { info.play = Int(Double(f) / fps) }
            if objs.count > 4, let id = objs[4].int { info.map = mapName(id, gameFolder: gameFolder, rgss: rgss) }
            if let gp = objs.first(where: { $0.className == "Game_Player" }), let c = gp.ivar("character_name")?.string, !c.isEmpty {
                info.chars = [.init(name: c, index: 0)]
            }
            return info
        }
        // XP·VX: [[캐릭터 그림, 색조/번호]…], frame_count, … Game_Map
        if let chars = first.array {
            info.chars = sprites(chars)
            if objs.count > 1, let f = objs[1].int { info.play = Int(Double(f) / fps) }
            if let gm = objs.first(where: { $0.className == "Game_Map" }), let id = gm.ivar("map_id")?.int {
                info.map = mapName(id, gameFolder: gameFolder, rgss: rgss)
            }
            if rgss == .xp { info.chars = info.chars?.map { .init(name: $0.name, index: 0) } }   // XP 는 둘째 값이 색조
            return info
        }
        return nil
    }

    private static func sprites(_ a: [RV]) -> [SaveCard.Sprite] {
        a.prefix(4).compactMap { e in
            guard let pair = e.array, let n = pair.first?.string, !n.isEmpty else { return nil }
            return .init(name: n, index: pair.count > 1 ? (pair[1].int ?? 0) : 0)
        }
    }

    private static func trainer(_ t: RV, into info: inout SaveCard.Info) {
        if let n = t.ivar("name")?.string, !n.isEmpty { info.trainer = n }
        if let b = t.ivar("badges")?.array { info.badges = b.filter { if case .bool(true) = $0 { return true }; return false }.count }
        if let party = t.ivar("party")?.array {
            info.party = party.prefix(6).compactMap { pk in
                guard let s = pk.ivar("species") else { return nil }
                if let i = s.int { return String(i) }
                return s.string
            }
        }
    }

    private static func hms(_ s: String) -> Int? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return p[0] * 3600 + p[1] * 60 + p[2]
    }

    private static var mapCache: [String: [Int: String]] = [:]
    private static let cacheLock = NSLock()

    /// Data/MapInfos 에서 맵 이름 (암호화 묶음 게임은 파일이 없어 nil)
    static func mapName(_ id: Int, gameFolder: URL, rgss: RGSSVersion) -> String? {
        let ext = rgss == .xp ? "rxdata" : rgss == .vx ? "rvdata" : "rvdata2"
        let key = gameFolder.path + "|" + ext
        cacheLock.lock()
        if let m = mapCache[key] { cacheLock.unlock(); return m[id] }
        cacheLock.unlock()
        var names: [Int: String] = [:]
        if let u = findFile(gameFolder, ["Data", "MapInfos." + ext]),
           case .hash(let pairs)? = marshalObjects(u, max: 1).first {
            for (k, v) in pairs {
                if let i = k.int, let n = v.ivar("name")?.string { names[i] = n }
            }
        }
        cacheLock.lock(); mapCache[key] = names; cacheLock.unlock()
        return names[id]
    }

    // MARK: MV·MZ

    /// 게임의 저장 목록에서 칸 하나 (`file3.rmmzsave` → 3번). 맵 이름은 그 칸 파일에서
    static func mvmz(_ url: URL, dish: Dish) -> SaveCard.Info? {
        let name = url.deletingPathExtension().lastPathComponent
        let id = name.hasPrefix("file") ? Int(name.dropFirst(4)) : nil
        guard id != nil || Scoop.slot(ofName: url.lastPathComponent) != nil else { return nil }
        let mz = url.pathExtension.lowercased() == "rmmzsave"
        let global = url.deletingLastPathComponent().appendingPathComponent("global." + url.pathExtension)
        var info = SaveCard.Info()
        if let id, let arr = json(global, mz: mz) as? [Any], arr.indices.contains(id), let e = arr[id] as? [String: Any] {
            if let c = e["characters"] as? [[Any]] {
                info.chars = c.prefix(4).compactMap { p in
                    guard let n = p.first as? String, !n.isEmpty else { return nil }
                    return .init(name: n, index: (p.count > 1 ? p[1] as? Int : nil) ?? 0)
                }
            }
            if let pt = e["playtime"] as? String { info.play = hms(pt) }
        }
        let contents = json(url, mz: mz) as? [String: Any]
        // 빙수 상태 저장 칸은 global 목록에 없다: 파일 안 파티·플레이 시간(저장 때 프레임 수)
        if let c = contents, info.chars == nil {
            func arr(_ a: Any?) -> [Any]? { (a as? [Any]) ?? ((a as? [String: Any])?["@a"] as? [Any]) }
            let actors = arr((c["actors"] as? [String: Any])?["_data"])
            let ids = arr((c["party"] as? [String: Any])?["_actors"])?.compactMap { $0 as? Int } ?? []
            let chars: [SaveCard.Sprite] = ids.prefix(4).compactMap { i in
                guard let actors, actors.indices.contains(i), let a = actors[i] as? [String: Any],
                      let n = a["_characterName"] as? String, !n.isEmpty else { return nil }
                return .init(name: n, index: a["_characterIndex"] as? Int ?? 0)
            }
            if !chars.isEmpty { info.chars = chars }
            if info.play == nil, let f = (c["system"] as? [String: Any])?["_framesOnSave"] as? Int, f > 0 { info.play = f / 60 }
        }
        if let c = contents, let map = c["map"] as? [String: Any], let mapId = map["_mapId"] as? Int,
           let root = mvRoot(dish), let mi = findFile(root, ["data", "MapInfos.json"]),
           let d = try? Data(contentsOf: mi), d.count < 8 * 1024 * 1024,
           let infos = (try? JSONSerialization.jsonObject(with: d)) as? [Any], infos.indices.contains(mapId),
           let m = infos[mapId] as? [String: Any], let n = m["name"] as? String, !n.isEmpty {
            info.map = n
        }
        return info.isEmpty ? nil : info
    }

    static func mvRoot(_ dish: Dish) -> URL? {
        guard let r = dish.mvmz?.root else { return dish.location }
        return r.isEmpty ? dish.location : dish.location.appendingPathComponent(r, isDirectory: true)
    }

    /// MZ: zlib 압축을 바이트별 문자로 담은 UTF-8 문자열. MV: LZString base64
    static func json(_ url: URL, mz: Bool) -> Any? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        let text: String?
        if mz {
            guard let s = String(data: data, encoding: .utf8) else { return nil }
            var bin = [UInt8]()
            bin.reserveCapacity(s.unicodeScalars.count)
            for u in s.unicodeScalars { guard u.value < 256 else { return nil }; bin.append(UInt8(u.value)) }
            guard bin.count > 2, let out = try? (Data(bin.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data,
                  out.count < 64 * 1024 * 1024 else { return nil }
            text = String(data: out, encoding: .utf8)
        } else {
            text = LZString.decompressFromBase64(String(decoding: data, as: UTF8.self))
        }
        guard let t = text, let d = t.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    // MARK: 그림

    /// 폴더 안 경로를 대소문자 무시로 찾는다 (게임 폴더 밖으로 나가지 않음)
    static func findFile(_ base: URL, _ parts: [String], exts: [String] = []) -> URL? {
        var dir = base
        let fm = FileManager.default
        for (i, part) in parts.enumerated() {
            guard !part.isEmpty, part != "..", part != ".", !part.contains("/") else { return nil }
            let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let last = i == parts.count - 1
            let wants = last && !exts.isEmpty ? exts.map { (part + "." + $0).lowercased() } : [part.lowercased()]
            guard let hit = items.first(where: { wants.contains($0.lowercased()) }) else { return nil }
            dir = dir.appendingPathComponent(hit, isDirectory: !last)
        }
        let rb = base.standardizedFileURL.resolvingSymlinksInPath().path
        let rd = dir.standardizedFileURL.resolvingSymlinksInPath().path
        return rd.hasPrefix(rb + "/") ? dir : nil
    }

    private static func load(_ url: URL?) -> CGImage? {
        guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 8 * 1024 * 1024 else { return nil }
        return UIImage(contentsOfFile: url.path)?.cgImage
    }

    /// 캐릭터 그림 한 칸 (아래를 보는 가운데 자세). XP·Essentials 는 4×4, VX·Ace·MV·MZ 는 8명(4×2)×(3×4), `$` 로 시작하면 1명
    static func characterImage(_ s: SaveCard.Sprite, dish: Dish) -> UIImage? {
        let mv = dish.recipe == .rpgMakerMV
        let folder: URL?
        let parts: [String]
        if mv { folder = mvRoot(dish); parts = ["img", "characters", s.name] }
        else { folder = dish.location; parts = ["Graphics", "Characters", s.name] }
        guard let folder, let img = load(findFile(folder, parts, exts: ["png"])) else { return nil }
        let W = img.width, H = img.height
        let rect: CGRect
        let xp = !mv && BrassBowlEngine.rgss(for: dish) == .xp
        if xp {
            rect = CGRect(x: 0, y: 0, width: W / 4, height: H / 4)
        } else {
            let single = s.name.hasPrefix("$") || s.name.hasPrefix("!$")
            let pw = single ? W / 3 : W / 12, ph = single ? H / 4 : H / 8
            let i = single ? 0 : max(0, min(7, s.index))
            rect = CGRect(x: ((i % 4) * 3 + 1) * pw, y: (i / 4) * 4 * ph, width: pw, height: ph)
        }
        return img.cropping(to: rect).map { UIImage(cgImage: $0) }
    }

    /// 포켓몬 아이콘 (두 칸짜리 그림의 왼쪽). 옛 Essentials `Graphics/Icons/icon001.png`, 새 판 `Graphics/Pokemon/Icons/BULBASAUR.png`
    static func pokemonIcon(_ species: String, dish: Dish) -> UIImage? {
        let url: URL?
        if let n = Int(species) {
            url = findFile(dish.location, ["Graphics", "Icons", String(format: "icon%03d", n)], exts: ["png"])
        } else {
            url = findFile(dish.location, ["Graphics", "Pokemon", "Icons", species], exts: ["png"])
        }
        guard let img = load(url) else { return nil }
        let side = min(img.height, img.width)
        return img.cropping(to: CGRect(x: 0, y: 0, width: side, height: side)).map { UIImage(cgImage: $0) }
    }
}

/// lz-string 1.4 의 decompressFromBase64 (MV 세이브). MIT, pieroxy
enum LZString {
    private static let keyStr = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    private static let rev: [Character: Int] = Dictionary(uniqueKeysWithValues: keyStr.enumerated().map { ($1, $0) })

    static func decompressFromBase64(_ input: String) -> String? {
        let chars = Array(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !chars.isEmpty, chars.count < 64 * 1024 * 1024 else { return nil }
        return decompress(length: chars.count, resetValue: 32) { i in rev[chars[i]] ?? 0 }
    }

    private static func decompress(length: Int, resetValue: Int, _ next: (Int) -> Int) -> String? {
        var dict: [[UInt16]] = [[0], [1], [2]]
        var enlargeIn = 4, dictSize = 4, numBits = 3
        var result: [UInt16] = []
        var val = next(0), pos = resetValue, index = 1
        func bits(_ n: Int) -> Int? {
            var b = 0, power = 1
            for _ in 0..<n {
                let r = val & pos
                pos >>= 1
                if pos == 0 { pos = resetValue; guard index <= length else { return nil }; val = index < length ? next(index) : 0; index += 1 }
                b |= (r > 0 ? 1 : 0) * power
                power <<= 1
            }
            return b
        }
        guard let first = bits(2) else { return nil }
        var c: [UInt16]
        switch first {
        case 0: guard let v = bits(8) else { return nil }; c = [UInt16(v)]
        case 1: guard let v = bits(16) else { return nil }; c = [UInt16(v)]
        default: return ""
        }
        dict.append(c)
        var w = c
        result += c
        while true {
            guard index <= length + 1, result.count < 128 * 1024 * 1024 else { return nil }
            guard var cc = bits(numBits) else { return nil }
            switch cc {
            case 0, 1:
                guard let v = bits(cc == 0 ? 8 : 16) else { return nil }
                dict.append([UInt16(v)])
                cc = dictSize; dictSize += 1
                enlargeIn -= 1
            case 2:
                return String(decoding: result, as: UTF16.self)
            default: break
            }
            if enlargeIn == 0 { enlargeIn = 1 << numBits; numBits += 1 }
            let entry: [UInt16]
            if cc < dict.count { entry = dict[cc] }
            else if cc == dictSize { entry = w + [w[0]] }
            else { return nil }
            result += entry
            dict.append(w + [entry[0]])
            dictSize += 1
            enlargeIn -= 1
            w = entry
            if enlargeIn == 0 { enlargeIn = 1 << numBits; numBits += 1 }
        }
    }
}

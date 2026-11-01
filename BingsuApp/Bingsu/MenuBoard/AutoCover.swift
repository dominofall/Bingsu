import CryptoKit
import UIKit

/// 사용자가 표지를 고르지 않은 RPG Maker 게임의 기본 표지 (2026-10-31 사용자 결정: 타이틀 이미지 먼저).
/// 1. Graphics/Titles 의 타이틀 이미지  2. Game.exe 아이콘(에센셜 기본 몬스터볼이면 건너뜀)  3. 없으면 nil → 기본 칩.
/// MV·MZ 는 `System.json` 의 `title1Name` → `img/titles1/<이름>.png`(암호화면 `.rpgmvp`·`.png_` 를 풀어서).
/// 게임 폴더에는 아무것도 쓰지 않고, 한 번 찾은 결과는 실행 동안 메모리에 둔다.
enum AutoCover {
    @MainActor private static var cache: [String: UIImage?] = [:]

    @MainActor static func image(for dish: Dish) -> UIImage? {
        guard dish.recipe == .mkxp || dish.recipe == .rpgMakerMV, !dish.isRemote else { return nil }
        let key = dish.location.path
        if let hit = cache[key] { return hit }
        let found = dish.recipe == .rpgMakerMV ? mvTitle(in: dish.gameRoot)
            : titleImage(in: dish.location) ?? exeIcon(in: dish.location)
        cache[key] = found
        return found
    }

    // MARK: 타이틀 이미지

    private static func titleImage(in folder: URL) -> UIImage? {
        let dir = folder.appendingPathComponent("Graphics/Titles", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let images = names.filter { ["png", "jpg", "jpeg"].contains(($0 as NSString).pathExtension.lowercased()) }
        func base(_ n: String) -> String { (n as NSString).deletingPathExtension.lowercased() }
        // 에센셜은 title, 그 밖의 XP 게임은 보통 타이틀 한 장만 둔다. 제작진·스플래시·"시작" 글자 그림은 표지로 안 쓴다
        let skip = ["credit", "splash", "start", "logo"]
        let pick = images.first { base($0) == "title" }
            ?? images.sorted().first { n in !skip.contains { base(n).hasPrefix($0) } }
        return pick.flatMap { UIImage(contentsOfFile: dir.appendingPathComponent($0).path) }
    }

    // MARK: MV·MZ 타이틀

    private static func mvTitle(in root: URL) -> UIImage? {
        guard let system = MVMZProbe.json(root, "data/System.json"), let name = system["title1Name"] as? String, !name.isEmpty,
              !name.contains("/"), !name.contains(".."), !name.hasPrefix(".") else { return nil }
        let fm = FileManager.default
        // 폴더·파일 이름 대소문자가 다를 수 있다 (Windows 에서 만든 게임)
        func child(_ dir: URL, _ n: String) -> URL? {
            let exact = dir.appendingPathComponent(n)
            if fm.fileExists(atPath: exact.path) { return exact }
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).first { $0.lowercased() == n.lowercased() }.map { dir.appendingPathComponent($0) }
        }
        guard let img = child(root, "img"), let dir = child(img, "titles1") else { return nil }
        if let f = child(dir, name + ".png"), let ui = UIImage(contentsOfFile: f.path) { return ui }
        // 암호화 배포본: MV .rpgmvp, MZ .png_
        guard let key = system["encryptionKey"] as? String else { return nil }
        for ext in [".rpgmvp", ".png_"] {
            if let f = child(dir, name + ext), let d = try? Data(contentsOf: f, options: .mappedIfSafe),
               let plain = RPGMakerCrypt.decrypt(d, keyHex: key.lowercased()), let ui = UIImage(data: plain) { return ui }
        }
        return nil
    }

    // MARK: Game.exe 아이콘

    /// 포켓몬 에센셜 Game.exe 에 기본으로 든 몬스터볼 아이콘 (256×256 항목의 SHA-256). 게임마다 같아서 표지로 구별이 안 된다
    private static let defaultIcons: Set<String> = ["9e3a2c6dbda1a4ecd75265c388f8bfcac32c2b0424ec78e356956a4e7945b2ed"]

    private static func exeIcon(in folder: URL) -> UIImage? {
        let exe = folder.appendingPathComponent("Game.exe")
        guard let d = try? Data(contentsOf: exe, options: .alwaysMapped),
              let entry = PEIcons.largest(in: d) else { return nil }
        let hash = SHA256.hash(data: entry.bytes).map { String(format: "%02x", $0) }.joined()
        guard !defaultIcons.contains(hash) else { return nil }
        if entry.bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return UIImage(data: entry.bytes) }
        // BMP 아이콘은 .ico 한 장짜리로 감싸면 ImageIO 가 읽는다
        var ico = Data([0, 0, 1, 0, 1, 0])
        ico += [UInt8(entry.width % 256), UInt8(entry.height % 256), 0, 0, 1, 0, 32, 0]
        ico += withUnsafeBytes(of: UInt32(entry.bytes.count).littleEndian) { Data($0) }
        ico += withUnsafeBytes(of: UInt32(22).littleEndian) { Data($0) }
        return UIImage(data: ico + entry.bytes)
    }
}

/// Windows 실행 파일(PE)의 리소스에서 아이콘(RT_ICON) 항목을 꺼낸다. 고장 난 파일이면 nil
enum PEIcons {
    struct Entry { let bytes: Data; let width: Int; let height: Int }

    static func largest(in d: Data) -> Entry? {
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= d.count ? Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? {
            guard let lo = u16(o), let hi = u16(o + 2) else { return nil }
            return lo | hi << 16
        }
        guard let pe = u32(0x3C), u32(pe) == 0x4550, let nsec = u16(pe + 6), let optSize = u16(pe + 20),
              let magic = u16(pe + 24) else { return nil }
        let dirs = pe + 24 + (magic == 0x10B ? 96 : 112)
        guard let resRVA = u32(dirs + 2 * 8), resRVA > 0 else { return nil }
        // 섹션 표로 RVA → 파일 위치
        var sections: [(va: Int, size: Int, raw: Int)] = []
        for i in 0..<min(nsec, 96) {
            let s = pe + 24 + optSize + i * 40
            guard let vs = u32(s + 8), let va = u32(s + 12), let rs = u32(s + 16), let ro = u32(s + 20) else { return nil }
            sections.append((va, max(vs, rs), ro))
        }
        func offset(_ rva: Int) -> Int? { sections.first { rva >= $0.va && rva < $0.va + $0.size }.map { rva - $0.va + $0.raw } }
        guard let base = offset(resRVA) else { return nil }

        func entries(_ dir: Int) -> [(id: Int, ptr: Int)] {
            guard let named = u16(dir + 12), let ids = u16(dir + 14) else { return [] }
            return (0..<min(named + ids, 512)).compactMap { i in
                guard let id = u32(dir + 16 + i * 8), let ptr = u32(dir + 20 + i * 8) else { return nil }
                return (id, ptr)
            }
        }
        /// 이름·언어 단계를 따라 첫 데이터 항목까지
        func leaf(_ ptr: Int, depth: Int = 0) -> Data? {
            if ptr & 0x8000_0000 != 0 {
                guard depth < 4, let first = entries(base + (ptr & 0x7FFF_FFFF)).first else { return nil }
                return leaf(first.ptr, depth: depth + 1)
            }
            guard let rva = u32(base + ptr), let size = u32(base + ptr + 4), let o = offset(rva),
                  size > 40, o + size <= d.count else { return nil }
            return d.subdata(in: d.startIndex + o ..< d.startIndex + o + size)
        }

        guard let icons = entries(base).first(where: { $0.id == 3 }), icons.ptr & 0x8000_0000 != 0 else { return nil }
        var best: Entry?
        for e in entries(base + (icons.ptr & 0x7FFF_FFFF)) {
            guard let b = leaf(e.ptr) else { continue }
            let w: Int, h: Int
            if b.starts(with: [0x89, 0x50, 0x4E, 0x47]), b.count > 24 {
                w = b[b.startIndex + 16 ..< b.startIndex + 20].reduce(0) { $0 << 8 | Int($1) }
                h = b[b.startIndex + 20 ..< b.startIndex + 24].reduce(0) { $0 << 8 | Int($1) }
            } else {
                let le = { (o: Int) in b[b.startIndex + o ..< b.startIndex + o + 4].reversed().reduce(0) { $0 << 8 | Int($1) } }
                w = le(4); h = le(8) / 2
            }
            if w > (best?.width ?? 0) { best = Entry(bytes: b, width: w, height: h) }
        }
        return best
    }
}

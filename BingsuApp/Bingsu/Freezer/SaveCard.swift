import Foundation
import UIKit

/// 세이브 카드 (빌드 49): 세이브 파일 하나를 "어디서·누가·얼마나" 로 보여 준다. 상태 저장 목록과 세이브 파일 화면이 같이 쓴다.
///
/// 정보 모으는 순서
/// 1. 저장 순간 게임 안 스크립트가 남긴 옆 정보 — RPG Maker(Ruby, `BrassBowlEngine.cardScript`)는 임시 폴더 `bingsu-cards/` 에
///    `<세이브 이름>.txt`·사진·캐릭터 그림을 쓰고, MV·MZ(JS, `BowlScripts.saveCard`)는 메시지로 보낸다. 빙수가 이것을 아래 자리로 옮긴다
/// 2. 옆 정보가 없거나(PC 에서 가져온 세이브) 세이브가 그 뒤 바뀌었으면 파일을 읽는다 (`SaveCardParse`)
/// 3. 그것도 못 하면 저장 시각만
///
/// 자리: `Library/Application Support/SaveCards/<dataPathApp>/<세이브 이름>.json·.jpg·.c0.png…·.p0.png…`.
/// 이 기기에만 둔다 (save.json 묶음·iCloud 에 넣지 않음 — 크기). 세이브 이름은 얼음틀 이름 규칙(`IceTray.safeName`)을 지나야 한다
enum SaveCard {
    struct Sprite: Codable, Equatable {
        var name: String
        var index: Int
    }

    struct Info: Codable, Equatable {
        var map: String?
        /// 플레이 시간(초)
        var play: Int?
        var chars: [Sprite]?
        var trainer: String?
        var badges: Int?
        /// 포켓몬 종 (옛 Essentials 번호, 새 판 기호 이름)
        var party: [String]?
        /// 옆 정보를 쓸 때의 세이브 파일 수정 시각 (그 뒤 바뀌면 옆 정보를 버리고 파일을 읽는다)
        var fileDate: Double?
        /// 게임이 잘라 둔 캐릭터 그림·포켓몬 아이콘 수 (`.c0.png`…, `.p0.png`…)
        var charImages: Int?
        var partyImages: Int?

        var isEmpty: Bool { map == nil && play == nil && (chars ?? []).isEmpty && trainer == nil && (party ?? []).isEmpty }
    }

    /// 화면에 그릴 카드 한 장
    struct Card {
        var info: Info?
        var photo: UIImage?
        var chars: [UIImage] = []
        var party: [UIImage] = []
    }

    // MARK: 자리

    private static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SaveCards", isDirectory: true)

    static func dir(_ dish: Dish) -> URL {
        let name = Dish.isSafeFolder(dish.dataPathApp) ? dish.dataPathApp : "game"
        let d = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 세이브 이름이 안전할 때만 (`Save1.rvdata`, `file3.rmmzsave`)
    static func safe(_ name: String, _ dish: Dish) -> Bool {
        IceTray.safeName(name, recipe: dish.recipe) && !name.contains("/") && name.utf8.count <= 120
    }

    static func photoURL(_ dish: Dish, _ name: String) -> URL? {
        safe(name, dish) ? dir(dish).appendingPathComponent(name + ".jpg") : nil
    }

    private static func infoURL(_ dish: Dish, _ name: String) -> URL? {
        safe(name, dish) ? dir(dish).appendingPathComponent(name + ".json") : nil
    }

    private static func partURL(_ dish: Dish, _ name: String, _ kind: String, _ i: Int) -> URL {
        dir(dish).appendingPathComponent("\(name).\(kind)\(i).png")
    }

    /// 사진을 작게(긴 변 320px) JPEG 로. nil 이면 지난 사진을 지운다
    static func keepPhoto(_ image: UIImage?, _ dish: Dish, _ name: String) {
        guard let u = photoURL(dish, name) else { return }
        guard let image, let small = shrink(image, 320), let d = small.jpegData(compressionQuality: 0.75) else {
            try? FileManager.default.removeItem(at: u); return
        }
        try? d.write(to: u, options: .atomic)
    }

    static func shrink(_ image: UIImage, _ side: CGFloat) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let k = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, (image.size.width * k).rounded()), height: max(1, (image.size.height * k).rounded()))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// 옆 정보 쓰기 (세이브 파일의 지금 수정 시각을 함께). 그림은 따로 (`keepPart`)
    static func keepInfo(_ info: Info, _ dish: Dish, _ name: String) {
        guard let u = infoURL(dish, name) else { return }
        var i = info
        let file = Freezer(dish: dish).directory.appendingPathComponent(name)
        i.fileDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970
        if let d = try? JSONEncoder().encode(i) { try? d.write(to: u, options: .atomic) }
    }

    static func keepPart(_ data: Data, _ dish: Dish, _ name: String, kind: String, _ i: Int) {
        guard safe(name, dish), (0..<6).contains(i), data.count < 512 * 1024, UIImage(data: data) != nil else { return }
        try? data.write(to: partURL(dish, name, kind, i), options: .atomic)
    }

    /// 세이브를 지웠을 때 카드도
    static func forget(_ dish: Dish, _ name: String) {
        guard safe(name, dish) else { return }
        let fm = FileManager.default
        let d = dir(dish)
        for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where f == name + ".jpg" || f == name + ".json" || f.hasPrefix(name + ".c") || f.hasPrefix(name + ".p") {
            try? fm.removeItem(at: d.appendingPathComponent(f))
        }
        cacheLock.lock(); cache[d.path + "/" + name] = nil; cacheLock.unlock()
    }

    // MARK: 읽기

    private static var cache: [String: (Date, Card)] = [:]
    private static let cacheLock = NSLock()

    /// 카드 한 장. 옆 정보가 세이브보다 오래됐으면(다른 기기·PC 세이브로 바뀜) 파일을 읽은 값으로
    static func card(_ dish: Dish, _ name: String) -> Card {
        guard safe(name, dish) else { return Card() }
        let file = Freezer(dish: dish).directory.appendingPathComponent(name)
        let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let key = dir(dish).path + "/" + name
        let infoMod = infoURL(dish, name).flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate } ?? .distantPast
        let stamp = max(mod, infoMod)
        cacheLock.lock()
        if let (t, c) = cache[key], t == stamp { cacheLock.unlock(); return c }
        cacheLock.unlock()

        var out = Card()
        var fresh = false
        if let u = infoURL(dish, name), let d = try? Data(contentsOf: u), d.count < 64 * 1024,
           let info = try? JSONDecoder().decode(Info.self, from: d),
           let fd = info.fileDate, abs(fd - mod.timeIntervalSince1970) < 3 {
            out.info = info
            fresh = true
            for i in 0..<min(info.charImages ?? 0, 6) {
                if let img = UIImage(contentsOfFile: partURL(dish, name, "c", i).path) { out.chars.append(img) }
            }
            for i in 0..<min(info.partyImages ?? 0, 6) {
                if let img = UIImage(contentsOfFile: partURL(dish, name, "p", i).path) { out.party.append(img) }
            }
        }
        if !fresh {
            out.info = parse(dish, file)
        }
        if let info = out.info {
            if out.chars.isEmpty { out.chars = (info.chars ?? []).prefix(4).compactMap { SaveCardParse.characterImage($0, dish: dish) } }
            if out.party.isEmpty { out.party = (info.party ?? []).prefix(6).compactMap { SaveCardParse.pokemonIcon($0, dish: dish) } }
        }
        // 사진은 그 세이브를 쓴 순간의 것만 (세이브가 그 뒤 바뀌었으면 보이지 않음)
        if let pu = photoURL(dish, name), let pd = (try? pu.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           pd.timeIntervalSince1970 >= mod.timeIntervalSince1970 - 3 {
            out.photo = UIImage(contentsOfFile: pu.path)
        }
        cacheLock.lock(); cache[key] = (stamp, out); cacheLock.unlock()
        return out
    }

    private static func parse(_ dish: Dish, _ file: URL) -> Info? {
        switch dish.recipe {
        case .mkxp: return SaveCardParse.rgss(file, gameFolder: dish.location, rgss: BrassBowlEngine.rgss(for: dish))
        case .rpgMakerMV: return SaveCardParse.mvmz(file, dish: dish)
        default: return nil
        }
    }

    // MARK: 게임이 남긴 옆 정보 옮기기 (RPG Maker)

    /// 엔진이 쓰는 임시 자리 (울타리 쓰기 허용 폴더 안)
    static let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("bingsu-cards", isDirectory: true)

    /// `inbox` 의 `<이름>.txt` 를 그 게임 자리로 옮긴다. 줄마다 "키\t값". `file` 이 이 게임 저장 폴더 바로 아래일 때만 받는다
    static func ingest(_ dish: Dish) {
        guard dish.recipe == .mkxp else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: inbox.path) else { return }
        let saves = Freezer(dish: dish).directory.standardizedFileURL.resolvingSymlinksInPath().path
        for f in items where f.hasSuffix(".txt") {
            let txt = inbox.appendingPathComponent(f)
            let base = String(f.dropLast(4))
            // 다른 게임이 남긴 것은 그 게임을 열 때까지 둔다 (하루 지나면 버림)
            var keepForOther = false
            defer {
                if !keepForOther {
                    for g in items where g == f || g.hasPrefix(base + ".") { try? fm.removeItem(at: inbox.appendingPathComponent(g)) }
                }
            }
            guard let size = (try? txt.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 16 * 1024,
                  let text = try? String(contentsOf: txt, encoding: .utf8) else { continue }
            var kv: [String: String] = [:]
            for line in text.split(separator: "\n") {
                let p = line.split(separator: "\t", maxSplits: 1).map(String.init)
                if p.count == 2 { kv[p[0]] = p[1] }
            }
            guard let path = kv["file"] else { continue }
            let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let name = file.lastPathComponent
            guard file.deletingLastPathComponent().path == saves else {
                let age = (try? txt.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map { -$0.timeIntervalSinceNow } ?? 0
                keepForOther = age < 86_400
                continue
            }
            guard name == base, safe(name, dish) else { continue }
            var info = Info()
            info.map = kv["map"].flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
            info.play = kv["play"].flatMap { Int($0) }
            info.trainer = kv["trainer"].flatMap { $0.isEmpty ? nil : String($0.prefix(30)) }
            info.badges = kv["badges"].flatMap { Int($0) }
            info.chars = kv["chars"].map { s in
                s.split(separator: ";").prefix(4).compactMap { e in
                    let p = e.split(separator: "|", maxSplits: 1)
                    guard let n = p.first, !n.isEmpty else { return nil }
                    return Sprite(name: String(n.prefix(80)), index: p.count > 1 ? Int(p[1]) ?? 0 : 0)
                }
            }
            info.party = kv["party"].map { $0.split(separator: ";").prefix(6).map { String($0.prefix(40)) } }
            // 그림: 사진(.jpg·.png), 캐릭터 .c0.png…, 포켓몬 .p0.png…
            for ext in ["jpg", "png"] {
                let u = inbox.appendingPathComponent(base + ".photo." + ext)
                if (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max < 8 * 1024 * 1024,
                   let img = UIImage(contentsOfFile: u.path) {
                    keepPhoto(img, dish, name)
                    break
                }
            }
            var nc = 0, np = 0
            for i in 0..<6 {
                if let d = try? Data(contentsOf: inbox.appendingPathComponent("\(base).c\(i).png")) { keepPart(d, dish, name, kind: "c", nc); nc += 1 }
                if let d = try? Data(contentsOf: inbox.appendingPathComponent("\(base).p\(i).png")) { keepPart(d, dish, name, kind: "p", np); np += 1 }
            }
            info.charImages = nc
            info.partyImages = np
            keepInfo(info, dish, name)
            NSLog("[SaveCard] \(dish.dataPathApp): 옆 정보 받음 (그림 \(nc)·\(np))")
        }
    }

    /// MV·MZ 게임 화면(`BowlScripts.saveCard`, 신뢰하지 않음)이 보낸 카드. 이름·크기·그림을 확인하고 저장
    static func receiveWeb(_ d: [String: Any], _ dish: Dish) {
        guard dish.recipe == .rpgMakerMV, let name = d["name"] as? String,
              name.range(of: #"^(file[0-9]{1,3}|bingsu-(quick|auto|state-[0-9][0-9]))\.(rpgsave|rmmzsave)$"#, options: .regularExpression) != nil,
              safe(name, dish) else { return }
        var info = Info()
        if let m = d["map"] as? String, !m.isEmpty { info.map = String(m.prefix(60)) }
        if let p = (d["play"] as? NSNumber)?.doubleValue, p.isFinite, p >= 0, p < 1e8 { info.play = Int(p) }
        if let cs = d["chars"] as? [[Any]] {
            info.chars = cs.prefix(4).compactMap { c in
                guard let n = c.first as? String, !n.isEmpty else { return nil }
                return Sprite(name: String(n.prefix(80)), index: (c.count > 1 ? (c[1] as? NSNumber)?.intValue : nil) ?? 0)
            }
        }
        func png(_ any: Any?) -> Data? {
            guard let s = any as? String, s.count < 1_400_000, let comma = s.firstIndex(of: ","),
                  s.hasPrefix("data:image/") else { return nil }
            return Data(base64Encoded: String(s[s.index(after: comma)...]))
        }
        // 빙수 상태 저장은 사진을 앱이 찍는다 (Scoop). 게임 저장만 게임 안 맵 화면을
        if Scoop.slot(ofName: name) == nil, let data = png(d["photo"]), let img = UIImage(data: data) {
            keepPhoto(img, dish, name)
        }
        var nc = 0
        for any in ((d["charImages"] as? [Any]) ?? []).prefix(4) {
            if let data = png(any) { keepPart(data, dish, name, kind: "c", nc); nc += 1 }
        }
        info.charImages = nc
        info.partyImages = 0
        keepInfo(info, dish, name)
        NSLog("[SaveCard] \(dish.dataPathApp): 웹 카드 \(name) (그림 \(nc))")
    }

    // MARK: 문구

    /// "슬롯 1"·"빠른 저장"·"상태 저장 3"·"자동 저장". 세이브 칸이 아닌 파일(global·config 등)은 nil
    static func slotLabel(_ name: String) -> String? {
        if let s = Scoop.slot(ofName: name) {
            if case .state(let n) = s { return "상태 저장 \(n)" }
            return s == .auto ? "자동 저장" : "빠른 저장"
        }
        let base = (name as NSString).deletingPathExtension
        let lower = base.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "rpgsave" || ext == "rmmzsave" {
            guard lower.hasPrefix("file"), let n = Int(lower.dropFirst(4)) else { return nil }
            return n == 0 ? "게임 자동 저장" : "슬롯 \(n)"
        }
        guard ["rxdata", "rvdata", "rvdata2"].contains(ext) else { return nil }
        if lower == "game" { return "세이브" }
        for head in ["save", "game_", "game"] where lower.hasPrefix(head) {
            if let n = Int(lower.dropFirst(head.count)) { return "슬롯 \(n)" }
        }
        // 게임이 정한 칸 이름 (Essentials 여러 칸 저장 "세이브 A"·"자동세이브 1" 등)
        return base.isEmpty ? nil : String(base.prefix(16))
    }

    /// "오늘 오후 3:12"·"어제 오후 3:12"·"11월 15일 오후 3:12"
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "오늘 " + time }
        if cal.isDateInYesterday(d) { return "어제 " + time }
        return d.formatted(.dateTime.month().day()) + " " + time
    }

    /// "1시간 23분"·"12분"
    static func playText(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)시간 \(m)분" : "\(max(m, s > 0 ? 1 : 0))분"
    }
}

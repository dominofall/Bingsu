import Foundation

/// 토핑 — 이미 가져온 게임에 패치(바뀐 파일만 든 zip, 예: 한글 패치)를 얹고, 얹은 순서의 반대로 하나씩 걷어 낸다.
///
/// 흐름: zip → 임시 폴더에 안전하게 풀기(`SafeUnzip`: 경로 탈출·심볼릭 링크·크기 검사) → 패치 경로를 게임 폴더에 맞추기(`align`)
/// → 덮어쓸·새로 넣을 파일 목록(`Plan`) → 적용(`apply`): 덮어쓸 원본은 `Toppings/<게임 id>/<순번>/originals/` 로 옮겨 두고
/// 패치 파일을 그 자리로 옮긴다 → 되돌리기(`revertLast`): 새로 넣은 파일을 지우고 원본을 제자리로.
///
/// 지키는 것 (PLAN 8.2):
/// - 게임 폴더(`Games/<id>/`) 밖에는 쓰지 않는다. 모든 대상 경로는 안전한 이름 조각으로만 만들고, 마지막에 게임 폴더 안인지 다시 본다.
///   가는 길에 심볼릭 링크가 있으면 멈춘다.
/// - 저장 데이터(`Documents/Saves`)는 건드리지 않는다. 게임 폴더 안의 PC 저장 파일 모양(Save01.rvdata2·save/file1.rpgsave)과
///   빙수 영수증(`bingsu.json`)은 패치에 있어도 건너뛴다.
/// - 패치 안의 exe·dll·스크립트는 파일로 놓아둘 뿐 실행하지 않는다 (빙수는 어떤 파일도 실행하지 않는다).
/// - 원본과 패치는 같은 볼륨이라 복사 없이 이름 바꾸기만 한다 (800MB 게임이라도 백업 용량이 거의 안 든다).
enum Topping {
    /// 패치 기록·백업 위치. 게임 폴더 밖이라 게임 크기·게임 목록에 섞이지 않는다
    static var shelf: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toppings", isDirectory: true)
    }

    static func folder(for dishID: String) -> URL? {
        guard let safe = safeComponent(dishID) else { return nil }
        return shelf.appendingPathComponent(safe, isDirectory: true)
    }

    /// 적용한 패치 하나의 기록 (`Toppings/<id>/<순번>/record.json`)
    struct Record: Codable, Equatable, Sendable, Identifiable {
        /// 순번 폴더 이름 ("001")
        var id: String
        /// 패치 이름 (mod.json 의 name, 없으면 zip 이름)
        var name: String
        var sourceName: String
        var appliedAt: Date
        /// 게임 폴더 안에서 패치 기준 폴더 ("" = 게임 폴더, MV·MZ 는 "www" 일 수 있다)
        var base: String
        /// 덮어쓴 파일 (원본은 originals/ 에)
        var replaced: [String]
        /// 새로 넣은 파일
        var added: [String]
        /// 새로 만든 폴더 (위에서 아래 순서)
        var createdDirs: [String]
        /// false 면 적용 도중 멈춘 기록 (되돌리기로 치운다)
        var complete: Bool
        /// RPG Maker: 빙수가 고르는 Ruby 가 패치 앞뒤로 어떻게 됐는지 ("18 legacy" → "31 modern"). 진단 정보에만 보인다
        var rubyBefore: String? = nil
        var rubyAfter: String? = nil
    }

    /// 적용 전에 보여 줄 계획
    struct Plan: Sendable {
        struct Item: Sendable, Hashable {
            /// 게임 기준 폴더 안 경로 (게임 쪽 대소문자로 맞춘 것)
            let target: String
            /// 패치 루트 안 경로
            let source: String
            let replaces: Bool
            let bytes: UInt64
        }
        let dish: Dish
        /// 임시 폴더 (적용·취소 뒤 지운다)
        let work: URL
        /// 정렬한 패치 루트 (work 안)
        let root: URL
        /// 게임 쪽 기준 폴더 ("" 또는 MV·MZ 의 루트)
        let base: String
        let name: String
        let sourceName: String
        let items: [Item]
        /// 건너뛴 파일 (저장 파일·숨김 파일·영수증)
        let skipped: [String]
        /// 미리 보기에서 알릴 것
        let notes: [String]
        /// 이 게임용 패치가 아닌 것 같거나 적용하면 게임이 시작되지 않을 것 같은 이유 (경고만, 적용은 막지 않음)
        var warnings: [String] = []

        var replacedCount: Int { items.filter(\.replaces).count }
        var addedCount: Int { items.count - replacedCount }
        var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    }

    enum ToppingError: LocalizedError {
        case notImported
        case noMatch
        case empty
        case unsafePath(String)
        case clash(String)
        case link(String)
        case nothingToRevert
        case busy
        var errorDescription: String? {
            switch self {
            case .notImported: return "가져온 게임에만 패치를 적용할 수 있어요"
            case .noMatch: return "이 게임의 파일과 겹치는 곳이 없어요 · 다른 게임의 패치이거나 게임 파일 전체가 든 zip 일 수 있어요"
            case .empty: return "패치 안에 적용할 파일이 없어요"
            case .unsafePath(let p): return "패치 안에 이상한 경로가 있어 적용하지 않았어요: \(p.prefix(80))"
            case .clash(let p): return "패치의 파일과 게임의 폴더 이름이 겹쳐요: \(p.prefix(80))"
            case .link(let p): return "게임 폴더에 링크가 있어 적용하지 않았어요: \(p.prefix(80))"
            case .nothingToRevert: return "되돌릴 패치가 없어요"
            case .busy: return "다른 작업이 진행 중이에요"
            }
        }
    }

    // MARK: - 풀기

    /// zip(또는 Delivery 가 이미 풀어 둔 폴더)을 `Games/.import-<uuid>/staged` 에 둔다. 다음 가져오기의 `sweepStaleWork` 가 남은 것을 치운다
    static func unpack(_ source: URL, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) throws -> (work: URL, staged: URL) {
        let fm = FileManager.default
        let work = MenuBoardStore.gamesDir.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var ok = false
        defer { if !ok { try? fm.removeItem(at: work) } }
        let local = try Delivery.coordinatedLocalCopy(of: source, into: work, isCancelled: isCancelled)
        let staged = work.appendingPathComponent("staged", isDirectory: true)
        var isDir: ObjCBool = false
        fm.fileExists(atPath: local.path, isDirectory: &isDir)
        if isDir.boolValue {
            if Delivery.containsLink(in: local) { throw Delivery.DeliveryError.linkInFolder }
            if local != staged { try fm.moveItem(at: local, to: staged) }
        } else {
            try SafeUnzip.unzip(local, to: staged, progress: progress, isCancelled: isCancelled)
            try? fm.removeItem(at: local)
        }
        ok = true
        return (work, staged)
    }

    // MARK: - 정렬

    /// 이름 조각 하나가 안전한가 (`..`·`.`·구분자·NUL·제어 문자 없음)
    static func safeComponent(_ s: String) -> String? {
        guard !s.isEmpty, s != ".", s != "..", s.utf8.count <= 255,
              !s.contains("/"), !s.contains("\\"), !s.contains(":"),
              !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return s
    }

    /// 대소문자를 가리지 않고 게임 폴더의 실제 이름을 찾는 목록 캐시
    final class Listing {
        private var cache: [String: [String: String]] = [:]
        /// 폴더 안 이름 (소문자·NFC → 실제 이름)
        func names(in dir: URL) -> [String: String] {
            if let c = cache[dir.path] { return c }
            var map: [String: String] = [:]
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let k = Self.key(n)
                if map[k] == nil || n == k { map[k] = n }
            }
            cache[dir.path] = map
            return map
        }
        static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
    }

    enum Kind { case none, file, dir, link }
    static func kind(_ url: URL) -> Kind {
        guard let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) else { return .none }
        if v.isSymbolicLink == true { return .link }
        if v.isDirectory == true { return .dir }
        return v.isRegularFile == true ? .file : .link // 그 밖의 특수 파일은 링크처럼 거절
    }

    /// 패치 경로 조각을 게임 폴더의 실제 이름으로 맞춘다. 없는 조각은 패치의 이름 그대로
    struct Resolved { var components: [String]; var existingDepth: Int; var finalKind: Kind; var clashAt: String? }
    static func resolve(_ comps: [String], in base: URL, listing: Listing) -> Resolved {
        var out: [String] = []
        var dir = base
        var depth = 0
        for (i, c) in comps.enumerated() {
            let last = i == comps.count - 1
            if depth == i, let real = listing.names(in: dir)[Listing.key(c)] {
                let url = dir.appendingPathComponent(real)
                let k = kind(url)
                out.append(real)
                if last { return Resolved(components: out, existingDepth: depth + 1, finalKind: k, clashAt: k == .link ? out.joined(separator: "/") : nil) }
                if k != .dir { return Resolved(components: out + comps[(i + 1)...], existingDepth: depth + 1, finalKind: .none, clashAt: out.joined(separator: "/")) }
                dir = url
                depth += 1
            } else {
                out.append(c)
            }
        }
        return Resolved(components: out, existingDepth: depth, finalKind: .none, clashAt: nil)
    }

    /// 패치 안 파일 목록 (루트 기준 경로 조각). 숨김·__MACOSX 는 뺀다
    static func files(in root: URL) throws -> [[String]] {
        var out: [[String]] = []
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        let rootComps = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        for case let url as URL in e {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name == "__MACOSX" {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { e.skipDescendants() }
                continue
            }
            let v = try url.resourceValues(forKeys: Set(keys))
            if v.isSymbolicLink == true { throw ToppingError.unsafePath(name) }
            guard v.isRegularFile == true else { continue }
            let comps = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard comps.count > rootComps.count, Array(comps.prefix(rootComps.count)) == rootComps else { throw ToppingError.unsafePath(name) }
            let rel = Array(comps.dropFirst(rootComps.count))
            guard rel.allSatisfy({ safeComponent($0) != nil }) else { throw ToppingError.unsafePath(rel.joined(separator: "/")) }
            out.append(rel)
        }
        return out
    }

    /// 패치 루트 후보: 맨 위, 그리고 폴더 하나뿐이면 그 안으로 (한 겹씩)
    static func rootCandidates(_ staged: URL) -> [URL] {
        var out = [staged]
        var cur = staged
        while true {
            let items = Delivery.visibleItems(cur).filter { $0.lastPathComponent != "__MACOSX" }
            guard items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { break }
            cur = items[0]
            out.append(cur)
        }
        return out
    }

    /// 게임 쪽 기준 후보: 게임 폴더, MV·MZ 면 그 루트(www 등)
    static func baseCandidates(_ dish: Dish) -> [String] {
        var out = [""]
        if let r = dish.mvmz?.root, !r.isEmpty { out.append(r) }
        return out
    }

    struct Alignment { let root: URL; let base: String; let score: Int; let matched: Int }

    /// 패치 루트와 게임 기준 폴더의 짝 중 가장 잘 맞는 것. 점수: 이미 있는 파일 = 3, 부모 폴더가 있는 새 파일 = 1.
    /// 맨 위 폴더 하나만 든 패치(예: `Data/Scripts.rxdata` 만)는 그 폴더가 게임에 있어 맨 위 그대로가 이긴다
    static func align(_ staged: URL, to dish: Dish) -> Alignment? {
        let listing = Listing()
        var best: Alignment?
        for root in rootCandidates(staged) {
            guard let files = try? files(in: root), !files.isEmpty else { continue }
            for base in baseCandidates(dish) {
                let baseURL = base.isEmpty ? dish.location : dish.location.appendingPathComponent(base, isDirectory: true)
                var score = 0, matched = 0
                for f in files.prefix(5000) {
                    let r = resolve(f, in: baseURL, listing: listing)
                    if r.existingDepth == f.count, r.finalKind == .file { score += 3; matched += 1 }
                    else if f.count > 1, r.existingDepth == f.count - 1, r.clashAt == nil { score += 1 }
                }
                if score > 0, score > (best?.score ?? 0) { best = Alignment(root: root, base: base, score: score, matched: matched) }
            }
        }
        return best
    }

    /// 패치만 든 zip 을 가져오려 할 때: 적용할 만한 게임을 잘 맞는 순서로
    static func rank(_ staged: URL, among dishes: [Dish]) -> [(dish: Dish, matched: Int)] {
        dishes.compactMap { d -> (Dish, Int, Int)? in
            guard let a = align(staged, to: d) else { return nil }
            return (d, a.score, a.matched)
        }
        .sorted { $0.1 > $1.1 }
        .map { ($0.0, $0.2) }
    }

    // MARK: - 계획

    /// 저장 파일·영수증·숨김 파일은 패치에 있어도 쓰지 않는다
    static func skips(_ target: [String], base: String) -> Bool {
        guard let name = target.last else { return true }
        if base.isEmpty, target.count == 1, name.lowercased() == Delivery.manifestName { return true }
        if ["thumbs.db", "desktop.ini"].contains(name.lowercased()) { return true }
        if Delivery.isGameFolderSave(name) || Delivery.isMVMZSave(name) { return true }
        if name.range(of: #"^(Game|Save)\d*\.rxdata$"#, options: [.regularExpression, .caseInsensitive]) != nil, target.count == 1 { return true }
        return false
    }

    static func plan(work: URL, staged: URL, dish: Dish, sourceName: String) throws -> Plan {
        guard isImported(dish) else { throw ToppingError.notImported }
        guard let a = align(staged, to: dish) else { throw ToppingError.noMatch }
        let baseURL = a.base.isEmpty ? dish.location : dish.location.appendingPathComponent(a.base, isDirectory: true)
        guard kind(dish.location) == .dir, kind(baseURL) == .dir else { throw ToppingError.link(a.base) }
        let listing = Listing()
        var items: [Plan.Item] = []
        var skipped: [String] = []
        var seen = Set<String>()
        for f in try files(in: a.root) {
            let r = resolve(f, in: baseURL, listing: listing)
            let target = r.components.joined(separator: "/")
            if skips(r.components, base: a.base) { skipped.append(target); continue }
            if let c = r.clashAt { throw ToppingError.clash(c) }
            if r.finalKind == .dir { throw ToppingError.clash(target) }
            // 대소문자만 다른 같은 파일이 패치에 둘 → 거절
            guard seen.insert(Listing.key(target)).inserted else { throw ToppingError.clash(target) }
            guard inside(baseURL.appendingPathComponent(target), dish.location) else { throw ToppingError.unsafePath(target) }
            let src = a.root.appendingPathComponent(f.joined(separator: "/"))
            let bytes = UInt64((try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            items.append(.init(target: target, source: f.joined(separator: "/"), replaces: r.finalKind == .file, bytes: bytes))
        }
        guard !items.isEmpty else { throw ToppingError.empty }
        items.sort { a, b in a.replaces != b.replaces ? a.replaces : a.target.localizedStandardCompare(b.target) == .orderedAscending }

        var notes: [String] = []
        let lower = Set(items.map { Listing.key($0.target) })
        if dish.recipe == .mkxp, lower.contains("mkxp.json") {
            // 빙수는 RPG Maker 게임의 저장 폴더 이름을 mkxp.json 에서 읽는다. 바뀌면 저장 데이터가 안 보이게 된다(지우지는 않음)
            let after = RecipeDetector.describe(folder: a.root, recipe: .mkxp).dataPathApp
            if Dish.folderName(after, fallback: dish.id) != dish.dataPathApp {
                notes.append("이 패치는 저장 폴더 이름을 \u{201C}\(dish.dataPathApp)\u{201D}에서 \u{201C}\(after)\u{201D}(으)로 바꿔요. 지금 저장 데이터는 그대로 남지만 게임에서 안 보일 수 있어요. 되돌리면 다시 보여요.")
            }
        }
        if lower.contains(where: { $0.hasSuffix(".exe") || $0.hasSuffix(".dll") }) {
            notes.append("exe·dll 같은 PC 실행 파일도 들어 있어요. 빙수는 파일로 넣어 둘 뿐 실행하지 않아요.")
        }
        var plan = Plan(dish: dish, work: work, root: a.root, base: a.base, name: patchName(a.root, staged: staged, sourceName: sourceName),
                        sourceName: sourceName, items: items, skipped: skipped, notes: notes)
        plan.warnings = fitWarnings(plan, staged: staged) + scriptWarnings(plan)
        if !plan.warnings.isEmpty { NSLog("[Topping] \(dish.id) 경고: \(plan.warnings.joined(separator: " / "))") }
        return plan
    }

    /// mod.json·manifest.json 의 이름표(모드 도구가 쓰는 것), 없으면 zip 이름
    static func patchName(_ root: URL, staged: URL, sourceName: String) -> String {
        for dir in [root, staged] {
            for file in ["mod.json", "manifest.json"] {
                let url = dir.appendingPathComponent(file)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 << 20,
                      let data = try? Data(contentsOf: url),
                      let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                for key in ["name", "version"] {
                    if let n = Receipt.clean(m[key], limit: Receipt.maxTextLength), !n.isEmpty { return n }
                }
            }
        }
        let base = (sourceName as NSString).deletingPathExtension
        return Receipt.clean(base.isEmpty ? sourceName : base, limit: Receipt.maxTextLength) ?? "패치"
    }

    /// Games/<id> 바로 아래의 가져온 게임인가 (개발용 게임 폴더·기본 게임·웹 게임은 아님)
    static func isImported(_ dish: Dish) -> Bool {
        guard !dish.isRemote, dish.id == dish.location.lastPathComponent else { return false }
        let games = MenuBoardStore.gamesDir.resolvingSymlinksInPath().standardizedFileURL
        return dish.location.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path == games.path
    }

    /// url 이 folder 안인가 (링크를 푼 경로로)
    static func inside(_ url: URL, _ folder: URL) -> Bool {
        let f = folder.resolvingSymlinksInPath().standardizedFileURL.path
        // 아직 없는 파일은 resolvingSymlinks 가 그대로 돌려준다 → 있는 부모까지 풀어 붙인다
        var probe = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            tail.insert(probe.lastPathComponent, at: 0)
            probe = probe.deletingLastPathComponent()
        }
        guard !tail.contains(".."), !tail.contains(".") else { return false }
        let p = tail.reduce(probe.resolvingSymlinksInPath().standardizedFileURL) { $0.appendingPathComponent($1) }.path
        return p.hasPrefix(f + "/")
    }

    // MARK: - 적용 · 되돌리기

    static let recordName = "record.json"
    private static let lock = NSLock()

    static func records(for dishID: String) -> [Record] {
        guard let dir = folder(for: dishID) else { return [] }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.range(of: #"^\d{3,}$"#, options: .regularExpression) != nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return names.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { n in
            let url = dir.appendingPathComponent(n).appendingPathComponent(recordName)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 << 20,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? dec.decode(Record.self, from: data)
        }
    }

    private static func write(_ r: Record, to dir: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(r).write(to: dir.appendingPathComponent(recordName), options: .atomic)
    }

    /// 계획대로 적용한다. 도중에 실패하면 그때까지 바꾼 것을 되돌리고 던진다
    static func apply(_ plan: Plan) throws -> Record {
        guard lock.try() else { throw ToppingError.busy }
        defer { lock.unlock() }
        let fm = FileManager.default
        defer { try? fm.removeItem(at: plan.work) }
        let dish = plan.dish
        guard isImported(dish), let shelfDir = folder(for: dish.id) else { throw ToppingError.notImported }
        let baseURL = plan.base.isEmpty ? dish.location : dish.location.appendingPathComponent(plan.base, isDirectory: true)
        let next = (records(for: dish.id).compactMap { Int($0.id) }.max() ?? 0) + 1
        let seq = String(format: "%03d", next)
        let dir = shelfDir.appendingPathComponent(seq, isDirectory: true)
        let originals = dir.appendingPathComponent("originals", isDirectory: true)
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)

        var record = Record(id: seq, name: plan.name, sourceName: plan.sourceName, appliedAt: Date(), base: plan.base,
                            replaced: [], added: [], createdDirs: [], complete: false)
        if dish.recipe == .mkxp { record.rubyBefore = rubyText(dish.location) }
        try write(record, to: dir)
        do {
            for item in plan.items {
                let comps = item.target.split(separator: "/").map(String.init)
                guard comps.allSatisfy({ safeComponent($0) != nil }) else { throw ToppingError.unsafePath(item.target) }
                let dest = baseURL.appendingPathComponent(item.target)
                guard inside(dest, dish.location) else { throw ToppingError.unsafePath(item.target) }
                // 가는 길의 폴더: 있으면 진짜 폴더인지(링크 아님), 없으면 만들고 기록
                var cur = baseURL
                for c in comps.dropLast() {
                    cur = cur.appendingPathComponent(c, isDirectory: true)
                    switch kind(cur) {
                    case .dir: continue
                    case .none:
                        try fm.createDirectory(at: cur, withIntermediateDirectories: false)
                        record.createdDirs.append(String(cur.path.dropFirst(baseURL.path.count + 1)))
                    default: throw ToppingError.link(item.target)
                    }
                }
                let src = plan.root.appendingPathComponent(item.source)
                guard kind(src) == .file else { throw ToppingError.unsafePath(item.source) }
                switch kind(dest) {
                case .file:
                    let keep = originals.appendingPathComponent(item.target)
                    try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: dest, to: keep)
                    record.replaced.append(item.target)
                    do { try fm.moveItem(at: src, to: dest) } catch { try? fm.moveItem(at: keep, to: dest); record.replaced.removeLast(); throw error }
                case .none:
                    try fm.moveItem(at: src, to: dest)
                    record.added.append(item.target)
                default:
                    throw ToppingError.clash(item.target)
                }
            }
            record.complete = true
            if dish.recipe == .mkxp {
                // 덮은 뒤 파일로 다시 판단 (스크립트 판단 캐시는 Scripts 파일 크기·수정 시각이 키라 새로 읽는다)
                record.rubyAfter = rubyText(dish.location)
                if record.rubyAfter != record.rubyBefore { NSLog("[Topping] \(dish.id) Ruby \(record.rubyBefore ?? "?") → \(record.rubyAfter ?? "?")") }
            }
            try write(record, to: dir)
            NSLog("[Topping] \(dish.id) 적용 \(seq) ‘\(record.name)’: 바꿈 \(record.replaced.count) · 추가 \(record.added.count) · 새 폴더 \(record.createdDirs.count)")
            return record
        } catch {
            NSLog("[Topping] \(dish.id) 적용 실패, 되돌림: \(error.localizedDescription)")
            try? write(record, to: dir)
            try? undo(record, dish: dish, dir: dir)
            throw error
        }
    }

    /// 마지막에 적용한 패치를 걷어 낸다
    @discardableResult
    static func revertLast(_ dish: Dish) throws -> Record {
        guard lock.try() else { throw ToppingError.busy }
        defer { lock.unlock() }
        guard isImported(dish), let shelfDir = folder(for: dish.id), let last = records(for: dish.id).last else { throw ToppingError.nothingToRevert }
        try undo(last, dish: dish, dir: shelfDir.appendingPathComponent(last.id, isDirectory: true))
        NSLog("[Topping] \(dish.id) 되돌림 \(last.id) ‘\(last.name)’: 원본 \(last.replaced.count) · 지움 \(last.added.count)")
        return last
    }

    private static func undo(_ r: Record, dish: Dish, dir: URL) throws {
        let fm = FileManager.default
        guard r.base.split(separator: "/").allSatisfy({ safeComponent(String($0)) != nil }) else { throw ToppingError.unsafePath(r.base) }
        let baseURL = r.base.isEmpty ? dish.location : dish.location.appendingPathComponent(r.base, isDirectory: true)
        let originals = dir.appendingPathComponent("originals", isDirectory: true)
        func target(_ rel: String) throws -> URL {
            guard rel.split(separator: "/").allSatisfy({ safeComponent(String($0)) != nil }) else { throw ToppingError.unsafePath(rel) }
            let u = baseURL.appendingPathComponent(rel)
            guard inside(u, dish.location) else { throw ToppingError.unsafePath(rel) }
            return u
        }
        for rel in r.added {
            let u = try target(rel)
            if kind(u) == .file { try fm.removeItem(at: u) }
        }
        for rel in r.replaced {
            let u = try target(rel)
            let keep = originals.appendingPathComponent(rel)
            guard kind(keep) == .file else { NSLog("[Topping] 원본 없음: \(rel)"); continue }
            if kind(u) == .file { try fm.removeItem(at: u) }
            try fm.moveItem(at: keep, to: u)
        }
        for rel in r.createdDirs.reversed() {
            let u = try target(rel)
            if kind(u) == .dir, ((try? fm.contentsOfDirectory(atPath: u.path)) ?? ["?"]).isEmpty { try? fm.removeItem(at: u) }
        }
        try fm.removeItem(at: dir)
        if let shelfDir = folder(for: dish.id), ((try? fm.contentsOfDirectory(atPath: shelfDir.path)) ?? ["?"]).isEmpty {
            try? fm.removeItem(at: shelfDir)
        }
    }

    /// 게임 파일이 통째로 바뀌거나(업데이트) 지워졌다: 기록·백업은 더 쓸 수 없으니 지운다
    static func forget(_ dishID: String) {
        guard let dir = folder(for: dishID), FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
        NSLog("[Topping] \(dishID) 패치 기록 지움")
    }

    /// 패치만 든 zip 인가 (Delivery 가 새 게임으로 받지 않고 "어느 게임에 적용할까요?"로 돌린다).
    /// RPG Maker: 맨 위에 ini 가 없고, mkxp.json 도 없거나 게임 본체(System 데이터·암호화 아카이브)가 없다.
    /// 포켓몬 Z 한글 패치처럼 원본 mkxp.json 을 같이 넣은 패치가 두 번째 경우다
    static func looksLikeRGSSPatch(_ root: URL) -> Bool {
        let names = Set(Delivery.visibleItems(root).map { $0.lastPathComponent.lowercased() })
        if names.contains(where: { $0.hasSuffix(".ini") }) { return false }
        if !names.contains("mkxp.json") { return true }
        if names.contains(where: { $0.hasSuffix(".rgssad") || $0.hasSuffix(".rgss2a") || $0.hasSuffix(".rgss3a") }) { return false }
        let data = Delivery.visibleItems(root).first { $0.lastPathComponent.lowercased() == "data" }
        let dataNames = data.map { Set(((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []).map { $0.lowercased() }) } ?? []
        return !dataNames.contains(where: { ["system.rxdata", "system.rvdata", "system.rvdata2"].contains($0) })
    }

    /// 게임 본체임을 알려 주는 파일 (System 데이터·암호화 아카이브). 게임 쪽에 있는 것만 비교한다
    static let coreFiles = ["Data/System.rxdata", "Data/System.rvdata", "Data/System.rvdata2",
                            "Game.rgssad", "Game.rgss2a", "Game.rgss3a", "www/data/System.json", "data/System.json"]

    /// "업데이트"로 고른 zip 이 게임 전체가 아니라 그 게임의 일부만 든 패치인가.
    /// 게임 이름(ini·mkxp.json)이 들어 있어 게임으로 보이더라도, 통째로 바꾸면 빠진 파일이 사라지므로 패치로 덮는다.
    /// (1) 게임에 있는 본체 파일이 하나도 없다, 또는 (2) 파일 수가 게임의 30% 아래이고 암호화 아카이브도 없다
    static func isPartial(_ root: URL, comparedTo game: URL) -> Bool {
        // 대소문자만 다른 폴더가 둘(Data/·data/) 있어도 모두 본다
        func has(_ base: URL, _ rel: String) -> Bool {
            var dirs = [base]
            for part in rel.split(separator: "/").map(String.init) {
                dirs = dirs.flatMap { dir in
                    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                        .filter { $0.lowercased() == part.lowercased() }.map { dir.appendingPathComponent($0) }
                }
                if dirs.isEmpty { return false }
            }
            return true
        }
        let cores = coreFiles.filter { has(game, $0) }
        guard !cores.isEmpty else { return false }   // 본체를 알 수 없는 게임(웹·Electron)은 판단하지 않는다
        if !cores.contains(where: { has(root, $0) }) { return true }
        let archived = ["Game.rgssad", "Game.rgss2a", "Game.rgss3a"].contains { has(root, $0) }
        if archived { return false }
        func count(_ u: URL) -> Int {
            var n = 0
            let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            while let f = e?.nextObject() as? URL { if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { n += 1 } }
            return n
        }
        let g = count(game)
        return g >= 100 && count(root) * 10 < g * 3
    }
}

// MARK: - 이 게임용 패치인가 (지문)·적용 뒤 시작할 수 있나 (스크립트)

extension Topping {
    /// 빙수가 이 게임에 고를 Ruby ("31 modern")
    static func rubyText(_ folder: URL) -> String {
        let p = RubyProfile.detect(folder: folder, rgss: RGSSProbe.version(folder: folder))
        return "\(p.ruby) \(p.syntax)"
    }

    /// 게임 폴더의 파일 크기 (기준 폴더 안 경로, 소문자·NFC 키)
    static func sizeIndex(_ base: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        let prefix = base.standardizedFileURL.path.count + 1
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let f = e?.nextObject() as? URL {
            guard let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
            out[Listing.key(String(f.standardizedFileURL.path.dropFirst(prefix)))] = v.fileSize ?? 0
        }
        return out
    }

    /// 패치가 이 게임 것이 아닌 것 같으면 그 이유. 확실하지 않으면 아무것도 돌려주지 않는다(맞는 게임에 경고가 뜨지 않게).
    /// 1) 패치에 지문(modkit `manifest.json`: 패치 뒤 게임 전체의 파일마다 [크기, CRC32])이 있으면 패치가 바꾸지 않는 원본 파일의 크기를 게임과 맞춘다.
    /// 2) 없으면: 패치 파일 중 게임에 이미 있는 비율, 바꿀 파일이 게임 파일과 같거나 크기가 비슷한 비율, Game.ini 게임 이름.
    /// 기준값(2026-11-15): 어나더 레드 Patch/ → 어나더 레드 = 있는 432 중 같은 파일 286 / → 포켓몬 Z = 있는 419 중 같은 1·크기 비슷 14%.
    /// Z 한글 패치 → Z = 지문 크기 일치 98% / → 어나더 레드 = 225 중 7개만 있음
    static func fitWarnings(_ plan: Plan, staged: URL) -> [String] {
        let baseURL = plan.base.isEmpty ? plan.dish.location : plan.dish.location.appendingPathComponent(plan.base, isDirectory: true)
        let head = "이 게임용 패치가 아닌 것 같아요 · "
        var out: [String] = []
        if let m = manifestFiles(plan.root) ?? manifestFiles(staged) {
            let patched = Set(plan.items.map { Listing.key($0.target) })
            let index = sizeIndex(baseURL)
            var checked = 0, same = 0
            for (path, size) in m.files {
                let key = Listing.key(path)
                if patched.contains(key) || m.excluded(path) { continue }
                checked += 1
                if index[key] == size { same += 1 }
            }
            NSLog("[Topping] 지문 \(plan.dish.id): 원본 파일 \(checked)개 중 크기 같음 \(same)")
            if checked >= 20, Double(same) < Double(checked) * 0.7 {
                out.append(head + "패치에 적힌 원본 파일 \(checked)개 중 \(same)개만 이 게임과 크기가 같아요.")
            }
        } else {
            let replaced = plan.items.filter(\.replaces)
            if plan.items.count >= 10, replaced.count * 10 < plan.items.count * 3 {
                out.append(head + "패치 파일 \(plan.items.count)개 중 \(replaced.count)개만 이 게임에 있어요.")
            } else if replaced.count >= 10 {
                var same = 0, close = 0
                for item in replaced {
                    let g = baseURL.appendingPathComponent(item.target), src = plan.root.appendingPathComponent(item.source)
                    let gs = UInt64((try? g.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    if gs == item.bytes, item.bytes <= 64 << 20, let a = try? Data(contentsOf: g), let b = try? Data(contentsOf: src), a == b { same += 1; continue }
                    if abs(log(Double(item.bytes + 1) / Double(gs + 1))) < 0.25 { close += 1 }
                }
                let changed = replaced.count - same
                NSLog("[Topping] 닮은 정도 \(plan.dish.id): 바꿀 \(replaced.count) · 같음 \(same) · 크기 비슷 \(close)/\(changed)")
                if same * 20 < replaced.count, close * 10 < changed * 3 {
                    out.append(head + "바꿀 파일 \(replaced.count)개가 이 게임 파일과 거의 닮지 않았어요(같은 파일 \(same)개).")
                }
            }
        }
        // Game.ini 의 게임 이름이 다르면
        if let pi = Delivery.visibleItems(plan.root).first(where: { $0.lastPathComponent.lowercased() == "game.ini" }),
           let gi = (try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.lowercased() == "game.ini" }),
           let a = RGSSProbe.iniFields(pi)["title"], let b = RGSSProbe.iniFields(gi)["title"], !a.isEmpty, !b.isEmpty, a != b,
           !out.contains(where: { $0.hasPrefix(head) }) {
            out.append(head + "패치의 게임 이름 \u{201C}\(Receipt.clean(a, limit: 40) ?? a)\u{201D}이(가) 이 게임 \u{201C}\(Receipt.clean(b, limit: 40) ?? b)\u{201D}과(와) 달라요.")
        }
        return out
    }

    struct ManifestFiles {
        let files: [String: Int]
        let exclude: [String]
        func excluded(_ path: String) -> Bool {
            exclude.contains { fnmatch($0, path, FNM_CASEFOLD) == 0 }
        }
    }

    /// modkit 지문 (`manifest.json` 의 `modkit_manifest`·`files: {경로: [크기, CRC32]}`). 8MB 넘으면 읽지 않는다
    static func manifestFiles(_ dir: URL) -> ManifestFiles? {
        let url = dir.appendingPathComponent("manifest.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 << 20,
              let data = try? Data(contentsOf: url),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any], m["modkit_manifest"] != nil,
              let files = m["files"] as? [String: Any], !files.isEmpty else { return nil }
        var out: [String: Int] = [:]
        for (k, v) in files {
            if let a = v as? [Any], let n = a.first as? NSNumber { out[k] = n.intValue }
        }
        return out.isEmpty ? nil : ManifestFiles(files: out, exclude: (m["exclude"] as? [String]) ?? [])
    }

    /// RPG Maker: 패치의 스크립트 파일이 덮인 뒤 빙수가 고를 Ruby 로 읽히지 않을 것 같으면 그 이유.
    /// 확실한 경우만: 스크립트 파일을 풀 수 없음, 신형 Ruby 문법인데 덮은 뒤에도 옛 Ruby(1.8·1.9)로 실행됨.
    /// (1.8 문법만이면 빙수가 옛 Ruby 를 고르고, 섞여 있으면 3.1 이 한 스크립트씩 건너뛰며 도는 경우가 있어 — 포켓몬 Z 한글 패치 — 경고하지 않는다)
    static func scriptWarnings(_ plan: Plan) -> [String] {
        let dish = plan.dish
        guard dish.recipe == .mkxp, plan.base.isEmpty,
              let scripts = RGSSProbe.dataScripts(folder: dish.location) else { return [] }
        let rel = Listing.key(String(scripts.standardizedFileURL.path.dropFirst(dish.location.standardizedFileURL.path.count + 1)))
        guard let item = plan.items.first(where: { Listing.key($0.target) == rel }) else { return [] }
        let head = "이 패치를 적용하면 게임이 시작되지 않을 수 있어요 · "
        guard item.bytes <= 64 << 20, let data = try? Data(contentsOf: plan.root.appendingPathComponent(item.source)) else { return [] }
        // Ruby Marshal 이 아니면(헤더 04 08) 엔진도 읽지 못한다. 빙수의 간이 해석기가 모르는 값이 있을 뿐이면 판단하지 않는다
        guard data.count > 2, data[data.startIndex] == 4, data[data.startIndex + 1] == 8 else {
            return [head + "패치의 스크립트 파일(\((item.target as NSString).lastPathComponent))이 RPG Maker 스크립트 형식이 아니에요."]
        }
        guard let code = RubyScriptScan.decodeScripts(data), !code.isEmpty else { return [] }
        let scan = RubyScriptScan.analyze(code)
        // 덮은 뒤 Ruby 3.1 을 고를 조건 (RubyProfile.detect): 맨 위에 mkxp.json 이나 Ruby 3 DLL
        let top = Set(((try? FileManager.default.contentsOfDirectory(atPath: dish.location.path)) ?? []).map { $0.lowercased() })
            .union(plan.items.filter { !$0.target.contains("/") }.map { $0.target.lowercased() })
        let modernAfter = top.contains("mkxp.json") || top.contains { $0.hasPrefix("x64-msvcrt-ruby3") }
        if !modernAfter, scan.modernCount > 0 {
            return [head + "스크립트가 신형 Ruby 문법인데, 이 게임은 옛 Ruby(1.8·1.9)로 실행돼요."]
        }
        return []
    }
}

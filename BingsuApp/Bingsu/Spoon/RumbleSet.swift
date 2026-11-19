import Foundation

/// 효과음 → 컨트롤러 진동 표. 게임이 재생한 소리 이름(폴더·확장자를 뺀 소문자, `RumbleSet.normalize`)으로 고른다.
/// 게임은 직접 진동을 요청하지 않으므로, 피격·기절·볼 흔들림 같은 효과음이 날 때 대신 울린다.
/// 표는 JSON 파일(`Resources/Rumble/<이름>.json`, 형식은 `docs/rumble/README.md`)로 번들에 들어간다:
/// - `events.json` (kind events): 상황(`hit_super` 등)마다 진동 패턴 하나
/// - `base-*.json` (kind base): 여러 게임이 같이 쓰는 이름 표. `fallback: true` 면 게임 표가 없는 게임에도 쓴다
/// - 나머지 (kind game): 게임 하나. `extends` 로 기본 표를 물려받고 다른 점만 적는다
/// 사용자가 게임 설정에서 직접 넣은 표(`Documents/Rumble/<게임 id>.json`)가 있으면 그것을 먼저 쓴다.
/// 파일은 저장소에 PR 로 들어오는 외부 데이터라 믿지 않는다: 크기·개수·값 범위를 검사하고, 깨진 파일은 로그만 남기고 버린다.
struct RumbleSet {
    struct Pattern: Equatable {
        var strong: Float      // 저주파(묵직한) 모터 0...1
        var weak: Float        // 고주파(가벼운) 모터 0...1
        var duration: Double   // 초
        var repeats = 1        // 반복 횟수 (볼 흔들림 등)
        var gap = 0.0          // 반복 사이 간격(초)
        var sharpness: Float? = nil   // 날카로움 0...1. 없으면 strong/weak 중 큰 쪽으로 자동
    }

    /// 효과음 이름 비교 방식. 정규식은 받지 않는다 (외부 파일의 정규식은 느려지게 만들 수 있음)
    enum Match: String {
        case exact, prefix, suffix, contains
        func test(_ name: String, _ sound: String) -> Bool {
            switch self {
            case .exact: return name == sound
            case .prefix: return name.hasPrefix(sound)
            case .suffix: return name.hasSuffix(sound)
            case .contains: return name.contains(sound)
            }
        }
    }

    struct Rule {
        let sound: String   // 정규화한 이름 (소문자, 확장자 없음)
        let match: Match
        let pattern: Pattern
    }

    /// 앞에서부터 먼저 맞는 것을 쓴다.
    let rules: [Rule]
    /// 화면 흔들림(RGSS `start_shake`, MV·MZ `startShake`)에도 울리는가. 게임 표의 `"shake": false` 로 끈다
    var shake = true

    /// 화면 흔들림 → 진동 (docs/rumble/PLAN-defaults.md 4절). power 1~9 → 세기 power/9,
    /// duration(프레임) → 길이 min(duration/40, 0.5)초. speed 는 쓰지 않는다
    static func shakePattern(power: Int, frames: Int) -> Pattern? {
        guard power > 0, frames > 0 else { return nil }
        let s = Float(min(power, 9)) / 9
        return Pattern(strong: s, weak: s * 0.5, duration: min(max(Double(frames) / 40, 0.08), 0.5))
    }

    /// 게임이 넘긴 이름 그대로 받는다 (웹 `Hit.wav`, RGSS `Audio/SE/Battle damage normal` 모두)
    func match(_ raw: String) -> Pattern? {
        let name = Self.normalize(raw)
        return rules.first { $0.match.test(name, $0.sound) }?.pattern
    }

    static let none = RumbleSet(rules: [])

    /// 이 게임에 쓸 표: 사용자 표 → 게임 표(+ 물려받은 기본 표) → 기본 표 (fallback)
    static func forDish(_ dish: Dish) -> RumbleSet {
        RumbleShelf.card(for: dish)?.set ?? RumbleShelf.library.fallback
    }

    /// 지울 확장자: 오디오만. `v1.2 hit` 같은 이름의 점은 그대로 둔다
    static let audioExtensions: Set<String> = ["ogg", "wav", "mp3", "m4a", "mid", "midi", "flac", "aac", "opus", "webm", "wma", "caf"]

    /// 소리 이름을 한 모양으로: 폴더 빼고, 소문자, 앞뒤 공백 빼고, 오디오 확장자 빼고.
    /// RGSS 는 확장자 없이(`Audio/SE/Battle damage normal`), 웹은 확장자와 함께(`hit.wav`) 넘기므로 둘을 맞춘다
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        if let i = s.lastIndex(where: { $0 == "/" || $0 == "\\" }) { s = String(s[s.index(after: i)...]) }
        s = s.trimmingCharacters(in: .whitespaces)
        return stripAudioExtension(s)
    }

    static func stripAudioExtension(_ s: String) -> String {
        guard let dot = s.lastIndex(of: "."), audioExtensions.contains(String(s[s.index(after: dot)...])) else { return s }
        return String(s[..<dot])
    }
}

/// 진동표 파일 하나를 읽은 결과: 어떤 게임에 쓰는지 + 표
struct RumbleCard {
    enum Kind: String { case game, base, events }

    let file: String          // 파일 이름 (확장자 뺌)
    let game: String
    var kind: Kind = .game
    let webHosts: [String]    // 웹 게임 호스트 (하위 도메인 포함)
    let localNames: [String]  // 로컬 게임 dataPathApp 또는 id 에 들어 있는 글자 (소문자)
    var localExact: [String] = []   // 로컬 게임 dataPathApp 또는 id 와 정확히 같은 이름 (소문자)
    var extends: [String] = []      // 물려받은 기본 표 파일 이름 (실제로 붙은 것만)
    var fallback = false            // 기본 표: 게임 표가 없는 게임에도 쓰는가
    var ownRules = 0                // 이 파일에 적힌 규칙 수 (물려받은 것 빼고)
    let set: RumbleSet        // 이 파일 규칙 + 물려받은 규칙 (순서대로)
    var url: URL? = nil       // 읽은 파일 (내보내기용)

    func serves(_ dish: Dish) -> Bool {
        if dish.isRemote {
            guard let host = dish.location.host?.lowercased() else { return false }
            return webHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        let path = dish.dataPathApp.lowercased(), id = dish.id.lowercased()
        return localExact.contains { path == $0 || id == $0 } || localNames.contains { path.contains($0) || id.contains($0) }
    }
}

/// 번들의 `Rumble/*.json` 을 한 번만 읽어 두는 선반. 파일 이름 순서로, 먼저 맞는 게임 파일을 쓴다.
enum RumbleShelf {
    static let format = 1
    static let maxFileBytes = 64 * 1024
    static let maxFiles = 200
    static let maxRules = 200
    static let maxDetect = 8
    static let maxExtends = 8
    static let maxEvents = 64

    /// 번들 표 전체: 상황 패턴 → 기본 표 → 게임 표 순서로 읽은 결과
    struct Library {
        var events: [String: RumbleSet.Pattern] = [:]
        var bases: [String: RumbleCard] = [:]
        var games: [RumbleCard] = []
        var fallback = RumbleSet.none
    }

    static let library: Library = load(from: Bundle.main.url(forResource: "Rumble", withExtension: nil))
    static var shared: [RumbleCard] { library.games }

    /// 사용자가 넣은 게임별 표 폴더. 번들 표와 달리 detect 없이 그 게임에만 쓴다
    static let userDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Rumble", isDirectory: true)

    /// 효과음마다 불리므로 사용자 표는 한 번 읽어 둔다 (없음도 기억)
    private static var userCache: [String: RumbleCard?] = [:]
    private static let lock = NSLock()

    /// 표를 받지 못한 이유 (게임 설정 화면에 그대로 보여 준다)
    struct Rejection: Error { let reason: String }

    static func userURL(for id: String) -> URL {
        userDir.appendingPathComponent(DishPrefsStore.safeName(id) + ".json")
    }

    /// 이 게임에 쓸 표: 사용자 표 → 번들 게임 표. 없으면 nil (그때는 `library.fallback`)
    static func card(for dish: Dish) -> RumbleCard? {
        userCard(for: dish.id) ?? bundledCard(for: dish)
    }

    static func bundledCard(for dish: Dish) -> RumbleCard? {
        shared.first { $0.serves(dish) }
    }

    /// 게임 표가 없을 때 쓰는 기본 표 이름들 (설정 화면 요약용)
    static var fallbackNames: [String] {
        library.bases.values.filter(\.fallback).map(\.file).sorted()
    }

    static func userCard(for id: String) -> RumbleCard? {
        lock.lock(); defer { lock.unlock() }
        if let hit = userCache[id] { return hit }
        let url = userURL(for: id)
        var card: RumbleCard?
        if let data = try? Data(contentsOf: url) {
            do { card = try parse(data, file: url.deletingPathExtension().lastPathComponent, needsDetect: false, library: library).card; card?.url = url }
            catch { log("사용자 표 \(url.lastPathComponent): \((error as? Rejection)?.reason ?? "읽기 실패") (무시)") }
        }
        userCache[id] = .some(card)
        return card
    }

    /// 게임 설정에서 고른 JSON 을 검사해 이 게임의 표로 저장한다. 맞지 않으면 이유와 함께 거절
    @discardableResult
    static func importUserFile(_ data: Data, for id: String) throws -> (rules: Int, skipped: Int) {
        let r = try parse(data, file: DishPrefsStore.safeName(id), needsDetect: false, library: library)
        guard r.card.kind == .game else { throw Rejection(reason: "게임 표만 넣을 수 있어요 (kind \(r.card.kind.rawValue))") }
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: userURL(for: id), options: .atomic)) != nil else {
            throw Rejection(reason: "파일을 저장하지 못했어요")
        }
        forget(id)
        return (r.card.ownRules, r.skipped)
    }

    static func removeUserFile(for id: String) {
        try? FileManager.default.removeItem(at: userURL(for: id))
        forget(id)
    }

    private static func forget(_ id: String) {
        lock.lock(); userCache[id] = nil; lock.unlock()
    }

    /// JSON 원본. 모든 필드를 선택으로 받아 검사는 `parse` 에서 한다
    private struct RawFile: Decodable {
        var format: Int?
        var kind: String?
        var game: String?
        var detect: RawDetect?
        var extends: [String]?
        var fallback: Bool?
        var shake: Bool?
        var rules: [RawRule]?
        var events: [String: RawRule]?
    }
    private struct RawDetect: Decodable {
        var webHosts: [String]?
        var localNames: [String]?
        var localExact: [String]?
    }
    private struct RawRule: Decodable {
        var sound: String?
        var match: String?
        var event: String?
        var strong: Double?
        var weak: Double?
        var duration: Double?
        var repeats: Int?
        var gap: Double?
        var sharpness: Double?
    }

    /// 파일 이름 검사를 통과하고 크기 안인 번들 파일들 (이름 순)
    private static func readFiles(in dir: URL) -> [(file: String, url: URL, data: Data)] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        var out: [(String, URL, Data)] = []
        for name in names.prefix(maxFiles) {
            let file = String(name.dropLast(5))
            guard file.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil else {
                log("\(name): 파일 이름은 영어 소문자·숫자·하이픈만 (무시)"); continue
            }
            let url = dir.appendingPathComponent(name)
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= maxFileBytes,
                  let data = try? Data(contentsOf: url) else {
                log("\(name): 64KB 넘거나 읽을 수 없음 (무시)"); continue
            }
            out.append((file, url, data))
        }
        return out
    }

    private static func kindOf(_ data: Data) -> RumbleCard.Kind? {
        guard let raw = try? JSONDecoder().decode(RawFile.self, from: data) else { return nil }
        return RumbleCard.Kind(rawValue: raw.kind ?? "game")
    }

    static func load(from dir: URL?) -> Library {
        guard let dir else { log("Rumble 폴더 없음"); return Library() }
        let files = readFiles(in: dir)
        var lib = Library()
        // 1) 상황 패턴 (먼저 읽은 파일이 이김)
        for f in files where kindOf(f.data) == .events {
            do {
                for (k, v) in try parseEvents(f.data, file: f.file) where lib.events[k] == nil { lib.events[k] = v }
            } catch { log("\(f.file).json: \((error as? Rejection)?.reason ?? "읽기 실패") (무시)") }
        }
        // 2) 기본 표 (물려받기 없음)
        for f in files where kindOf(f.data) == .base {
            do {
                var card = try parse(f.data, file: f.file, needsDetect: false, library: lib).card
                card.url = f.url
                lib.bases[f.file] = card
            } catch { log("\(f.file).json: \((error as? Rejection)?.reason ?? "읽기 실패") (무시)") }
        }
        let fallbacks = lib.bases.values.filter(\.fallback).sorted { $0.file < $1.file }
        lib.fallback = RumbleSet(rules: fallbacks.flatMap(\.set.rules))
        // 3) 게임 표 (kind 가 틀린 파일은 parse 가 거절)
        for f in files where kindOf(f.data) != .events && kindOf(f.data) != .base {
            do {
                var card = try parse(f.data, file: f.file, needsDetect: true, library: lib).card
                card.url = f.url
                lib.games.append(card)
            } catch { log("\(f.file).json: \((error as? Rejection)?.reason ?? "읽기 실패") (무시)") }
        }
        log("상황 \(lib.events.count)개 · 기본 표 " + lib.bases.values.sorted { $0.file < $1.file }.map { "\($0.file)(\($0.ownRules)\($0.fallback ? ", 기본" : ""))" }.joined(separator: ", ")
            + " · 게임 표 " + lib.games.map { "\($0.file)(\($0.ownRules)\($0.extends.isEmpty ? "" : "+" + $0.extends.joined(separator: "+")))" }.joined(separator: ", "))
        return lib
    }

    private static func decode(_ data: Data, file: String) throws -> RawFile {
        guard data.count <= maxFileBytes else { throw Rejection(reason: "파일이 64KB 를 넘어요") }
        let raw: RawFile
        do { raw = try JSONDecoder().decode(RawFile.self, from: data) } catch {
            log("\(file): JSON 형식 오류 \(String(describing: error).prefix(160))")
            throw Rejection(reason: "JSON 형식이 아니에요")
        }
        guard raw.format == format else {
            throw Rejection(reason: "format \(raw.format.map(String.init) ?? "없음") 은 읽을 수 없어요 (\(format) 만 읽어요)")
        }
        return raw
    }

    /// `events.json`: 상황 이름 → 패턴. 이름은 영어 소문자·숫자·밑줄 32자, 64개까지
    static func parseEvents(_ data: Data, file: String) throws -> [String: RumbleSet.Pattern] {
        let raw = try decode(data, file: file)
        guard raw.kind == RumbleCard.Kind.events.rawValue else { throw Rejection(reason: "kind 가 events 가 아니에요") }
        var out: [String: RumbleSet.Pattern] = [:]
        for (name, r) in (raw.events ?? [:]).sorted(by: { $0.key < $1.key }).prefix(maxEvents) {
            guard name.range(of: #"^[a-z][a-z0-9_]{0,31}$"#, options: .regularExpression) != nil else {
                log("\(file): 상황 이름 \(name.prefix(40)) 은 영어 소문자·숫자·밑줄만 (무시)"); continue
            }
            guard let p = pattern(r, base: nil) else { log("\(file): 상황 \(name) 에 strong·weak·duration 이 없거나 틀림 (무시)"); continue }
            out[name] = p
        }
        guard !out.isEmpty else { throw Rejection(reason: "쓸 수 있는 상황이 없어요") }
        return out
    }

    /// 숫자 필드로 패턴을 만든다. `base` 가 있으면(상황 패턴) 적힌 숫자만 덮어쓴다
    private static func pattern(_ r: RawRule, base: RumbleSet.Pattern?) -> RumbleSet.Pattern? {
        func ok(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
        var p: RumbleSet.Pattern
        if let base {
            p = base
        } else {
            guard let s = ok(r.strong), let w = ok(r.weak), let d = ok(r.duration) else { return nil }
            p = .init(strong: Float(s), weak: Float(w), duration: d)
        }
        if let s = ok(r.strong) { p.strong = Float(clamp(s, 0, 1)) }
        if let w = ok(r.weak) { p.weak = Float(clamp(w, 0, 1)) }
        if let d = ok(r.duration) { p.duration = clamp(d, 0.02, 2) }
        if let n = r.repeats { p.repeats = min(max(n, 1), 10) }
        if let g = ok(r.gap) { p.gap = clamp(g, 0, 1) }
        if let sh = ok(r.sharpness) { p.sharpness = Float(clamp(sh, 0, 1)) }
        p.strong = min(max(p.strong, 0), 1); p.weak = min(max(p.weak, 0), 1); p.duration = clamp(p.duration, 0.02, 2)
        return p
    }

    /// 규칙의 이름을 효과음 이름과 같은 모양으로 바꾼다 (`RumbleSet.normalize`).
    /// 옛 규칙 호환: 점으로 끝나는 prefix(`"hit."` = hit.wav·hit.ogg) 는 점을 뺀 exact 로,
    /// 확장자까지 적은 exact·suffix·prefix 는 확장자를 뺀다(prefix 는 exact 로).
    static func normalizeRule(sound: String, match: RumbleSet.Match) -> (String, RumbleSet.Match)? {
        let s = sound.lowercased().trimmingCharacters(in: .whitespaces)
        var out: (String, RumbleSet.Match)
        switch match {
        case .prefix where s.hasSuffix("."):
            out = (String(s.dropLast()), .exact)
        case .prefix:
            let bare = RumbleSet.stripAudioExtension(s)
            out = bare == s ? (s, .prefix) : (bare, .exact)
        case .exact, .suffix:
            out = (RumbleSet.stripAudioExtension(s), match)
        case .contains:
            out = (s, .contains)
        }
        return out.0.isEmpty ? nil : out
    }

    /// 크기·형식·값 범위를 검사해 표로 만든다. 규칙 하나가 틀리면 그 규칙만 빼고(skipped), 파일 전체가 틀리면 이유와 함께 거절.
    /// `needsDetect` 는 번들 게임 표용: 어떤 게임에 쓰는지 알아볼 조건이 있어야 한다.
    /// `library` 의 상황 패턴으로 `event` 규칙을 풀고, 기본 표로 `extends` 를 붙인다.
    static func parse(_ data: Data, file: String, needsDetect: Bool, library: Library) throws -> (card: RumbleCard, skipped: Int) {
        let raw = try decode(data, file: file)
        guard let kind = RumbleCard.Kind(rawValue: raw.kind ?? "game"), kind != .events else {
            throw Rejection(reason: "kind 는 game 이나 base 만 쓸 수 있어요")
        }
        let game = String((raw.game ?? file).prefix(40))
        let hosts = (raw.detect?.webHosts ?? []).prefix(maxDetect).map { $0.lowercased() }.filter {
            let ok = $0.count <= 253 && $0.contains(".") && $0.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
            if !ok { log("\(file): 호스트 \($0.prefix(60)) 무시") }
            return ok
        }
        func names(_ list: [String]?, _ field: String) -> [String] {
            (list ?? []).prefix(maxDetect).map { $0.lowercased() }.filter {
                let ok = (3...60).contains($0.count)
                if !ok { log("\(file): \(field) 는 3~60자 (\($0.prefix(60)) 무시)") }
                return ok
            }
        }
        let locals = names(raw.detect?.localNames, "localNames"), exact = names(raw.detect?.localExact, "localExact")
        if needsDetect && kind == .game {
            guard !hosts.isEmpty || !locals.isEmpty || !exact.isEmpty else { throw Rejection(reason: "detect 에 게임을 알아볼 조건이 없어요") }
        }

        var rules: [RumbleSet.Rule] = []
        for (i, r) in (raw.rules ?? []).prefix(maxRules).enumerated() {
            guard let sound = r.sound, (1...80).contains(sound.count),
                  let m = RumbleSet.Match(rawValue: r.match ?? ""),
                  let (name, match) = normalizeRule(sound: sound, match: m) else {
                log("\(file): rules[\(i)] 의 sound·match 가 없거나 틀림 (이 규칙만 무시)"); continue
            }
            var base: RumbleSet.Pattern?
            if let ev = r.event {
                guard let p = library.events[ev] else { log("\(file): rules[\(i)] 의 상황 \(ev.prefix(40)) 이 events 에 없음 (이 규칙만 무시)"); continue }
                base = p
            }
            guard let p = pattern(r, base: base) else {
                log("\(file): rules[\(i)] 에 event 나 strong·weak·duration 이 없거나 틀림 (이 규칙만 무시)"); continue
            }
            rules.append(.init(sound: name, match: match, pattern: p))
        }
        let skipped = min(raw.rules?.count ?? 0, maxRules) - rules.count
        let own = rules.count

        var extended: [String] = []
        if kind == .base {
            if !(raw.extends ?? []).isEmpty { log("\(file): 기본 표는 extends 를 쓸 수 없어요 (무시)") }
        } else {
            for name in (raw.extends ?? []).prefix(maxExtends) where !extended.contains(name) {
                guard let b = library.bases[name] else { log("\(file): extends 의 \(name.prefix(40)) 기본 표가 없음 (무시)"); continue }
                extended.append(name)
                rules += b.set.rules
            }
        }
        guard !rules.isEmpty else { throw Rejection(reason: "쓸 수 있는 규칙이 없어요 (sound·match 와 event 또는 strong·weak·duration 확인)") }
        return (RumbleCard(file: file, game: game, kind: kind, webHosts: hosts, localNames: locals, localExact: exact,
                           extends: extended, fallback: kind == .base && raw.fallback == true, ownRules: own,
                           set: RumbleSet(rules: rules, shake: raw.shake ?? true)), skipped)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
    private static func log(_ m: String) { NSLog("[Rumble] \(m)") }
}

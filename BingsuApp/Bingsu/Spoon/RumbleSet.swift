import Foundation

/// 효과음 → 컨트롤러 진동 표. 게임이 재생한 소리 파일 이름(소문자, 확장자 포함)으로 고른다.
/// 게임은 직접 진동을 요청하지 않으므로, 피격·기절·볼 흔들림 같은 효과음이 날 때 대신 울린다.
/// 표는 게임마다 JSON 파일 하나(`Resources/Rumble/<이름>.json`, 형식은 `docs/rumble/README.md`)로 번들에 들어간다.
/// 사용자가 게임 설정에서 직접 넣은 표(`Documents/Rumble/<게임 id>.json`)가 있으면 그것을 먼저 쓴다.
/// 파일은 저장소에 PR 로 들어오는 외부 데이터라 믿지 않는다: 크기·개수·값 범위를 검사하고, 깨진 파일은 로그만 남기고 버린다.
struct RumbleSet {
    struct Pattern {
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
        let sound: String   // 소문자
        let match: Match
        let pattern: Pattern
    }

    /// 앞에서부터 먼저 맞는 것을 쓴다.
    let rules: [Rule]

    func match(_ name: String) -> Pattern? {
        rules.first { $0.match.test(name, $0.sound) }?.pattern
    }

    static let none = RumbleSet(rules: [])

    static func forDish(_ dish: Dish) -> RumbleSet {
        RumbleShelf.card(for: dish)?.set ?? none
    }
}

/// 진동표 파일 하나를 읽은 결과: 어떤 게임에 쓰는지 + 표
struct RumbleCard {
    let file: String          // 파일 이름 (확장자 뺌)
    let game: String
    let webHosts: [String]    // 웹 게임 호스트 (하위 도메인 포함)
    let localNames: [String]  // 로컬 게임 dataPathApp 또는 id 에 들어 있는 글자 (소문자)
    let set: RumbleSet
    var url: URL? = nil       // 읽은 파일 (내보내기용)

    func serves(_ dish: Dish) -> Bool {
        if dish.isRemote {
            guard let host = dish.location.host?.lowercased() else { return false }
            return webHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        let path = dish.dataPathApp.lowercased(), id = dish.id.lowercased()
        return localNames.contains { path.contains($0) || id.contains($0) }
    }
}

/// 번들의 `Rumble/*.json` 을 한 번만 읽어 두는 선반. 파일 이름 순서로, 먼저 맞는 게임 파일을 쓴다.
enum RumbleShelf {
    static let format = 1
    static let maxFileBytes = 64 * 1024
    static let maxFiles = 200
    static let maxRules = 200
    static let maxDetect = 8

    static let shared: [RumbleCard] = load(from: Bundle.main.url(forResource: "Rumble", withExtension: nil))

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

    /// 이 게임에 쓸 표: 사용자 표 → 번들 표
    static func card(for dish: Dish) -> RumbleCard? {
        userCard(for: dish.id) ?? bundledCard(for: dish)
    }

    static func bundledCard(for dish: Dish) -> RumbleCard? {
        shared.first { $0.serves(dish) }
    }

    static func userCard(for id: String) -> RumbleCard? {
        lock.lock(); defer { lock.unlock() }
        if let hit = userCache[id] { return hit }
        let url = userURL(for: id)
        var card: RumbleCard?
        if let data = try? Data(contentsOf: url) {
            do { card = try parse(data, file: url.deletingPathExtension().lastPathComponent, needsDetect: false).card; card?.url = url }
            catch { log("사용자 표 \(url.lastPathComponent): \((error as? Rejection)?.reason ?? "읽기 실패") (무시)") }
        }
        userCache[id] = .some(card)
        return card
    }

    /// 게임 설정에서 고른 JSON 을 검사해 이 게임의 표로 저장한다. 맞지 않으면 이유와 함께 거절
    @discardableResult
    static func importUserFile(_ data: Data, for id: String) throws -> (rules: Int, skipped: Int) {
        let r = try parse(data, file: DishPrefsStore.safeName(id), needsDetect: false)
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: userURL(for: id), options: .atomic)) != nil else {
            throw Rejection(reason: "파일을 저장하지 못했어요")
        }
        forget(id)
        return (r.card.set.rules.count, r.skipped)
    }

    static func removeUserFile(for id: String) {
        try? FileManager.default.removeItem(at: userURL(for: id))
        forget(id)
    }

    private static func forget(_ id: String) {
        lock.lock(); userCache[id] = nil; lock.unlock()
    }

    /// JSON 원본. 모든 필드를 선택으로 받아 검사는 `card(_:file:)` 에서 한다
    private struct RawFile: Decodable {
        var format: Int?
        var game: String?
        var detect: RawDetect?
        var rules: [RawRule]?
    }
    private struct RawDetect: Decodable {
        var webHosts: [String]?
        var localNames: [String]?
    }
    private struct RawRule: Decodable {
        var sound: String?
        var match: String?
        var strong: Double?
        var weak: Double?
        var duration: Double?
        var repeats: Int?
        var gap: Double?
        var sharpness: Double?
    }

    static func load(from dir: URL?) -> [RumbleCard] {
        guard let dir else { log("Rumble 폴더 없음"); return [] }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        var out: [RumbleCard] = []
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
            do {
                var card = try parse(data, file: file, needsDetect: true).card
                card.url = url
                out.append(card)
            } catch { log("\(name): \((error as? Rejection)?.reason ?? "읽기 실패") (무시)") }
        }
        log("진동표 \(out.count)개: " + out.map { "\($0.file)(\($0.set.rules.count))" }.joined(separator: ", "))
        return out
    }

    /// 크기·형식·값 범위를 검사해 표로 만든다. 규칙 하나가 틀리면 그 규칙만 빼고(skipped), 파일 전체가 틀리면 이유와 함께 거절.
    /// `needsDetect` 는 번들 표용: 어떤 게임에 쓰는지 알아볼 조건이 있어야 한다
    static func parse(_ data: Data, file: String, needsDetect: Bool) throws -> (card: RumbleCard, skipped: Int) {
        guard data.count <= maxFileBytes else { throw Rejection(reason: "파일이 64KB 를 넘어요") }
        let raw: RawFile
        do { raw = try JSONDecoder().decode(RawFile.self, from: data) } catch {
            log("\(file): JSON 형식 오류 \(String(describing: error).prefix(160))")
            throw Rejection(reason: "JSON 형식이 아니에요")
        }
        guard raw.format == format else {
            throw Rejection(reason: "format \(raw.format.map(String.init) ?? "없음") 은 읽을 수 없어요 (\(format) 만 읽어요)")
        }
        let game = String((raw.game ?? file).prefix(40))
        let hosts = (raw.detect?.webHosts ?? []).prefix(maxDetect).map { $0.lowercased() }.filter {
            let ok = $0.count <= 253 && $0.contains(".") && $0.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
            if !ok { log("\(file): 호스트 \($0.prefix(60)) 무시") }
            return ok
        }
        let locals = (raw.detect?.localNames ?? []).prefix(maxDetect).map { $0.lowercased() }.filter {
            let ok = (3...60).contains($0.count)
            if !ok { log("\(file): localNames 는 3~60자 (\($0.prefix(60)) 무시)") }
            return ok
        }
        guard !needsDetect || !hosts.isEmpty || !locals.isEmpty else { throw Rejection(reason: "detect 에 게임을 알아볼 조건이 없어요") }

        var rules: [RumbleSet.Rule] = []
        for (i, r) in (raw.rules ?? []).prefix(maxRules).enumerated() {
            guard let sound = r.sound?.lowercased(), (1...80).contains(sound.count),
                  let match = RumbleSet.Match(rawValue: r.match ?? ""),
                  let strong = r.strong, let weak = r.weak, let duration = r.duration,
                  strong.isFinite, weak.isFinite, duration.isFinite else {
                log("\(file): rules[\(i)] 에 sound·match·strong·weak·duration 이 없거나 틀림 (이 규칙만 무시)"); continue
            }
            let gap = r.gap ?? 0, sharp = r.sharpness
            rules.append(.init(sound: sound, match: match, pattern: .init(
                strong: Float(clamp(strong, 0, 1)), weak: Float(clamp(weak, 0, 1)),
                duration: clamp(duration, 0.02, 2),
                repeats: min(max(r.repeats ?? 1, 1), 10),
                gap: gap.isFinite ? clamp(gap, 0, 1) : 0,
                sharpness: sharp.flatMap { $0.isFinite ? Float(clamp($0, 0, 1)) : nil })))
        }
        guard !rules.isEmpty else { throw Rejection(reason: "쓸 수 있는 규칙이 없어요 (sound·match·strong·weak·duration 확인)") }
        let skipped = min(raw.rules?.count ?? 0, maxRules) - rules.count
        return (RumbleCard(file: file, game: game, webHosts: hosts, localNames: locals, set: RumbleSet(rules: rules)), skipped)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
    private static func log(_ m: String) { NSLog("[Rumble] \(m)") }
}

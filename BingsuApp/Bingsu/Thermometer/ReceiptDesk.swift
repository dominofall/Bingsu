import Foundation

/// 진단 정보 창구: 게임 중에 생긴 오류와 마지막으로 연 게임을 적어 둔다 (진단 정보 `ReceiptSlip` 이 읽는다).
/// 게임이 꺼지거나 빙수가 다시 열려도 남도록 `Library/Caches/Receipt/desk.json` 에 작게 저장한다.
/// 적기 전에 `ReceiptSlip.scrub` 으로 파일 위치·IP 를 지운다. 아무 데도 보내지 않는다(사용자가 직접 공유할 때만 나간다).
@MainActor
final class ReceiptDesk {
    static let shared = ReceiptDesk()

    /// 오류 한 줄
    struct Note: Codable, Equatable {
        enum Kind: String, Codable {
            case engine   // RPG Maker 엔진(스크립트) 오류
            case web      // 웹 게임 페이지 오류
            case start    // 게임을 열지 못함
            var label: String {
                switch self {
                case .engine: return "엔진 오류"
                case .web: return "페이지 오류"
                case .start: return "열기 실패"
                }
            }
        }
        var at: Date
        var dishID: String
        var kind: Kind
        var text: String
        /// 스크립트 이름·줄 (RPG Maker 오류 글에서 찾은 것)
        var script: String?
        var line: Int?
        /// 같은 오류가 이어서 난 횟수
        var count = 1
    }

    /// 마지막으로 연 게임과 그때의 실행 설정 (RPG Maker: rgss·Ruby·문법)
    struct Launch: Codable, Equatable {
        var dishID: String
        var at: Date
        var lines: [String]
    }

    private struct Store: Codable {
        var notes: [Note] = []
        var launch: Launch?
    }

    static let maxNotesPerDish = 8
    static let maxNotes = 40
    static let maxTextLength = 600

    private var store = Store()
    private var saveScheduled = false

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Receipt", isDirectory: true)
    }
    private var file: URL { Self.folder.appendingPathComponent("desk.json") }

    private init() {
        if let d = try? Data(contentsOf: file), d.count < 512 * 1024 {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let s = try? dec.decode(Store.self, from: d) { store = s }
        }
    }

    // MARK: 적기

    /// 오류 하나. 같은 글이 이어서 오면 횟수만 올린다 (웹 게임은 같은 오류를 매 프레임 낼 수 있다)
    func noteError(dishID: String, kind: Note.Kind, message: String, source: String? = nil) {
        var text = ReceiptSlip.scrub(message).trimmingCharacters(in: .whitespacesAndNewlines)
        if let source, !source.isEmpty { text += "\n@ " + ReceiptSlip.scrub(source) }
        if text.count > Self.maxTextLength { text = String(text.prefix(Self.maxTextLength)) + "…" }
        guard !text.isEmpty else { return }
        if let i = store.notes.lastIndex(where: { $0.dishID == dishID }), store.notes[i].text == text, store.notes[i].kind == kind {
            store.notes[i].count += 1
            store.notes[i].at = Date()
        } else {
            let (script, line) = Self.scriptLine(message)
            store.notes.append(Note(at: Date(), dishID: dishID, kind: kind, text: text, script: script, line: line))
            // 게임마다 최근 몇 개, 전체도 상한
            let mine = store.notes.indices.filter { store.notes[$0].dishID == dishID }
            if mine.count > Self.maxNotesPerDish { store.notes.remove(at: mine[0]) }
            if store.notes.count > Self.maxNotes { store.notes.removeFirst(store.notes.count - Self.maxNotes) }
        }
        scheduleSave()
    }

    /// 게임을 열었다. RPG Maker 게임은 엔진에 넘긴 설정을 같이 적는다
    func noteLaunch(dishID: String, lines: [String] = []) {
        store.launch = Launch(dishID: dishID, at: Date(), lines: lines.map { ReceiptSlip.scrub($0) })
        UserDefaults.standard.set(dishID, forKey: Self.lastDishKey)
        scheduleSave()
    }

    // MARK: 읽기

    static let lastDishKey = "bingsu.receipt.lastDish"
    /// 마지막으로 연 게임 (설정 › 진단 정보 보내기의 기본 선택)
    var lastDishID: String? { UserDefaults.standard.string(forKey: Self.lastDishKey) }

    func notes(for dishID: String) -> [Note] { store.notes.filter { $0.dishID == dishID } }

    func launch(for dishID: String) -> Launch? { store.launch?.dishID == dishID ? store.launch : nil }

    /// 진단 기록 모두 지우기 (오류·마지막 실행 기록·엔진 화면 기록)
    func clear() {
        store = Store()
        try? FileManager.default.removeItem(at: Self.folder)
        UserDefaults.standard.removeObject(forKey: Self.lastDishKey)
    }

    // MARK: 저장 (오류가 몰려도 1초에 한 번)

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.save()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(store) { try? d.write(to: file, options: .atomic) }
    }

    /// RPG Maker 오류 글에서 스크립트 이름·줄을 찾는다.
    /// "Script 'Foo' line 12: NoMethodError occurred." (RGSS 식) 또는 "Foo:12:in `bar'" (Ruby 백트레이스 식)
    nonisolated static func scriptLine(_ s: String) -> (String?, Int?) {
        // 엔진(binding-mri.cpp)이 만드는 글은 앞의 것. 뒤의 것은 게임이 직접 띄운 백트레이스
        let patterns = [#"Script '([^'\n]{1,80})' line (\d{1,6})"#, #"(?m)^\s*([^:\n/]{1,80}):(\d{1,6}):in "#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges == 3,
                  let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) else { continue }
            let name = String(s[a]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let n = Int(s[b]) else { continue }
            return (name, n)
        }
        return (nil, nil)
    }
}

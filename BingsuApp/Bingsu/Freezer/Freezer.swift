import Foundation

/// 냉동실: Windows %APPDATA%\<게임> 에 해당하는 저장 폴더.  Documents/Saves/<dataPathApp>/
/// Files 앱에 그대로 노출되므로 PC 세이브를 넣거나 꺼낼 수 있다.
///
/// 복원 규칙: save.json 의 `savedAt`(ms) 과 웹뷰 localStorage 의 표식(`markerKey`)을 비교한다.
/// 표식은 네이티브가 save.json 을 쓴 뒤에만 그 시각으로 갱신되므로, 둘이 다르면
/// 파일이 바뀐 것(되돌리기·가져오기·Files 앱으로 넣음)이고 파일을 우선한다.
struct Freezer {
    let dish: Dish

    static let format = "pokemon-resonance-backup"
    /// 원작 Electron validateBackup 과 같은 상한
    static let maxBytes = 16 * 1024 * 1024
    /// localStorage 에 두는 "마지막으로 맞춘 save.json 시각". 게임 키 접두사(rcb./bingsu.)와 겹치지 않게.
    static let markerKey = "__bingsuFreezerAt"

    struct Snapshot {
        var entries: [String: String]
        /// ms since 1970. 메타가 없는 파일(PC 백업을 직접 넣은 경우)은 파일 수정 시각
        var savedAt: Double
    }

    struct Backup: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    enum ImportError: LocalizedError {
        case tooLarge, notBackup, badKey, empty
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "파일이 너무 커요. 16MB 이하 백업 파일만 가져올 수 있어요."
            case .notBackup: return "이 게임의 백업 파일이 아니에요."
            case .badKey: return "백업 안에 이 게임 것이 아닌 데이터가 섞여 있어요."
            case .empty: return "백업 파일이 비어 있어요."
            }
        }
    }

    /// "따로 하나 더 추가"한 사본(id 가 pokemon-resonance-2 등)도 같은 게임이라 저장 폴더 이름으로 본다
    var keyPrefix: String { dish.dataPathApp == "pokemon-resonance" || dish.id == "pokemon-resonance" ? "rcb." : "bingsu." }

    var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let saves = docs.appendingPathComponent("Saves", isDirectory: true).standardizedFileURL
        var dir = saves.appendingPathComponent(dish.dataPathApp, isDirectory: true).standardizedFileURL
        // Dish 가 이미 고친 이름이지만, 쓰는 자리에서도 Saves 바로 아래인지 한 번 더 본다
        if dir.deletingLastPathComponent().path != saves.path || !Dish.isSafeFolder(dish.dataPathApp) {
            NSLog("[Freezer] unsafe save folder name rejected")
            dir = saves.appendingPathComponent("game", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var backupsDirectory: URL { directory.appendingPathComponent("backups", isDirectory: true) }

    /// 웹/Electron 게임의 localStorage 스냅샷. 레조넌스 PC 백업과 같은 포맷 (+ savedAt).
    var localStorageFile: URL { directory.appendingPathComponent("save.json") }

    // MARK: 읽기 / 쓰기

    func loadLocalStorage() -> Snapshot? {
        guard let data = try? Data(contentsOf: localStorageFile), data.count <= Self.maxBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // 레조넌스 백업 포맷 {format, version, data:{...}} 또는 평면 {key: value}
        let dict = (obj["data"] as? [String: Any]) ?? obj
        var out: [String: String] = [:]
        for (k, v) in dict where isValidKey(k) { if let s = v as? String { out[k] = s } }
        guard !out.isEmpty else { return nil }
        let savedAt = (obj["savedAt"] as? NSNumber)?.doubleValue
            ?? ((try? localStorageFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { $0.timeIntervalSince1970 * 1000 } ?? 0)
        return Snapshot(entries: out, savedAt: savedAt.rounded())
    }

    /// `savedAt` 은 웹뷰가 보낸 스냅샷 시각(ms). 성공하면 true — 그때만 웹뷰 표식을 갱신한다.
    @discardableResult
    func saveLocalStorage(_ entries: [String: String], savedAt: Double) -> Bool {
        guard !entries.isEmpty else { return false }
        let payload: [String: Any] = ["format": Self.format, "version": 1, "savedAt": savedAt.rounded(), "data": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return false }
        return write(data, to: localStorageFile)
    }

    var lastSaved: Date? {
        guard FileManager.default.fileExists(atPath: localStorageFile.path) else { return nil }
        if let s = loadLocalStorage() { return Date(timeIntervalSince1970: s.savedAt / 1000) }
        return nil
    }

    private func write(_ data: Data, to url: URL) -> Bool {
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            return (try? data.write(to: url, options: .atomic)) != nil
        }
    }

    func isValidKey(_ k: String) -> Bool {
        guard k.hasPrefix(keyPrefix), k.count > keyPrefix.count else { return false }
        return k.dropFirst(keyPrefix.count).unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || "_.-".unicodeScalars.contains($0)
        }
    }

    // MARK: 백업

    /// 얼려두기: 날짜 붙인 복사본. 같은 분에 또 하면 -2, -3 …
    @discardableResult
    func freeze() -> URL? {
        guard FileManager.default.fileExists(atPath: localStorageFile.path) else { return nil }
        try? FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let base = Self.stamp.string(from: Date())
        var dest = backupsDirectory.appendingPathComponent("\(base).json")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = backupsDirectory.appendingPathComponent("\(base)-\(n).json"); n += 1
        }
        return (try? FileManager.default.copyItem(at: localStorageFile, to: dest)) != nil ? dest : nil
    }

    /// 이미 검증한 저장 데이터(다른 기기 것 등)를 백업 목록에 바로 넣는다. 동기화 충돌에서 고르지 않은 쪽
    @discardableResult
    func freeze(data: Data) -> URL? {
        try? FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let base = Self.stamp.string(from: Date())
        var dest = backupsDirectory.appendingPathComponent("\(base).json")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = backupsDirectory.appendingPathComponent("\(base)-\(n).json"); n += 1
        }
        return (try? data.write(to: dest, options: .atomic)) != nil ? dest : nil
    }

    func backups() -> [Backup] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "json" }.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let date = Self.stamp.date(from: String(name.prefix(15)))
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Backup(url: url, date: date)
        }.sorted { $0.date > $1.date }
    }

    func delete(_ backup: Backup) {
        // 백업 폴더 안의 파일만 지운다
        guard backup.url.deletingLastPathComponent().standardizedFileURL == backupsDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: backup.url)
    }

    /// 백업으로 되돌리기: 백업 파일도 Files 앱으로 바뀔 수 있으니 가져오기와 같은 검증을 거친다.
    func restore(_ backup: Backup) throws {
        try replace(with: Data(contentsOf: backup.url))
    }

    /// PC 백업 가져오기 / 되돌리기 공통: 검증 → 현재 것을 백업 → save.json 교체(savedAt = 지금)
    func replace(with data: Data) throws {
        let entries = try validate(data)
        freeze()
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        guard saveLocalStorage(entries, savedAt: now) else { throw CocoaError(.fileWriteUnknown) }
        Self.markReplaced(dish.dataPathApp)
    }

    /// 가져온 파일은 신뢰하지 않는다: 크기, 형식·버전, 키 정규식, 값은 문자열만.
    func validate(_ data: Data) throws -> [String: String] {
        guard data.count <= Self.maxBytes else { throw ImportError.tooLarge }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["format"] as? String == Self.format,
              (obj["version"] as? NSNumber)?.intValue == 1,
              let dict = obj["data"] as? [String: Any] else { throw ImportError.notBackup }
        var out: [String: String] = [:]
        var total = 0
        for (k, v) in dict {
            guard isValidKey(k) else { throw ImportError.badKey }
            guard let s = v as? String else { throw ImportError.notBackup }
            total += k.utf8.count + s.utf8.count
            if total > Self.maxBytes { throw ImportError.tooLarge }
            out[k] = s
        }
        guard !out.isEmpty else { throw ImportError.empty }
        return out
    }

    /// 내보내기 파일 이름: "포켓몬 레조넌스-백업-2026-10-29.json"
    var exportFileName: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return "\(dish.title)-백업-\(f.string(from: Date())).json"
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: 켜져 있는 게임이 바꾼 파일을 덮어쓰지 않게

    private static let lock = NSLock()
    private static var replaced: [String: Date] = [:]

    static func markReplaced(_ dataPathApp: String) {
        lock.lock(); replaced[dataPathApp] = Date(); lock.unlock()
    }

    /// `openedAt` 이후에 save.json 이 교체됐으면, 그 게임 화면의 스냅샷은 더 이상 쓰지 않는다 (다음 실행 때 파일이 복원됨).
    static func wasReplaced(_ dataPathApp: String, since openedAt: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (replaced[dataPathApp] ?? .distantPast) > openedAt
    }
}

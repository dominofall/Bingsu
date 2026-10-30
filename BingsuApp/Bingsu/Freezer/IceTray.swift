import Foundation
import CryptoKit

/// 얼음틀: 파일로 저장하는 게임(RPG Maker XP — `Game.rxdata` 등)의 저장 파일 ↔ save.json.
///
/// 엔진은 PC 와 똑같이 `Saves/<dataPathApp>/Game.rxdata` 를 읽고 쓴다(PC 세이브와 같은 파일).
/// 백업·되돌리기·iCloud 이어하기(`Freezer`·`Igloo`)는 save.json 하나를 다루므로, 저장 파일들을 base64 로 save.json 에 담아 둔다
/// (키 `bingsu.file.<파일 이름 UTF-8 16진수>` — "세이브 A.rxdata" 처럼 한글·공백 이름도 Freezer 키 규칙을 지나게, 16MB 상한 그대로).
///
/// 어느 쪽이 바뀌었나는 마지막으로 두 쪽을 맞춘 상태(`Library/Application Support/IceTray/<dataPathApp>.json`: save.json 의 savedAt,
/// 파일 지문)와 비교해 정한다.
/// - save.json 만 바뀜(iCloud 에서 내려받음·백업 되돌리기·PC 백업 가져오기) → 파일로 풀어 쓴다
/// - 파일만 바뀜(게임이 저장함) → save.json 으로 묶는다
/// - 둘 다 바뀜 → save.json 쪽을 쓰고, 지금 파일들은 백업으로 남긴다(사용자가 고른 되돌리기·내려받기가 이김)
/// 파일이 모두 사라진 경우는 묶지 않는다(지우기를 퍼뜨리지 않음).
enum IceTray {
    /// 저장 파일로 보는 확장자. 그 밖의 파일(로그 등)은 묶지 않는다
    static let saveExtensions: Set<String> = ["rxdata", "rvdata", "rvdata2", "dat", "sav", "bak", "ini", "txt", "json5"]

    struct Mark: Codable, Equatable {
        var savedAt: Double
        var fingerprint: String
    }

    private static let lock = NSLock()

    private static var markDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IceTray", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func markURL(_ dish: Dish) -> URL {
        markDir.appendingPathComponent(dish.dataPathApp + ".json")
    }

    static func loadMark(_ dish: Dish) -> Mark? {
        guard let d = try? Data(contentsOf: markURL(dish)), d.count < 64 * 1024 else { return nil }
        return try? JSONDecoder().decode(Mark.self, from: d)
    }

    private static func saveMark(_ m: Mark, _ dish: Dish) {
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: markURL(dish), options: .atomic) }
    }

    /// 저장 폴더 바로 아래의 저장 파일들 (하위 폴더·숨김·save.json·임시 파일 제외)
    static func saveFiles(_ fz: Freezer) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: fz.directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return items.filter { u in
            let name = u.lastPathComponent
            guard name != fz.localStorageFile.lastPathComponent, (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return false }
            return safeName(name)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 파일 이름 + 내용 해시. 파일이 없으면 ""
    static func fingerprint(_ files: [URL]) -> String {
        guard !files.isEmpty else { return "" }
        var h = SHA256()
        for f in files {
            h.update(data: Data(f.lastPathComponent.utf8))
            if let d = try? Data(contentsOf: f, options: .mappedIfSafe) { h.update(data: d) }
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum Result: Equatable { case nothing, packed, unpacked, unpackedWithBackup, skipped(String) }

    /// 두 쪽 맞추기. `allowUnpack == false`(게임이 켜져 있음)면 파일은 건드리지 않고 묶기만 한다.
    @discardableResult
    static func sync(_ dish: Dish, allowUnpack: Bool) -> Result {
        guard dish.recipe == .mkxp, !dish.isRemote else { return .nothing }
        lock.lock(); defer { lock.unlock() }
        let fz = Freezer(dish: dish)
        let mark = loadMark(dish)
        let snap = fz.loadLocalStorage()
        let files = saveFiles(fz)
        let fp = fingerprint(files)
        let jsonChanged = snap != nil && snap!.savedAt.rounded() != mark?.savedAt.rounded()
        let filesChanged = !fp.isEmpty && fp != mark?.fingerprint

        if jsonChanged, allowUnpack, let snap {
            var backedUp = false
            if filesChanged, let packed = packData(files, fz: fz, savedAt: now()) {
                backedUp = fz.freeze(data: packed) != nil
            }
            guard unpack(snap, fz: fz) else { return .skipped("파일 쓰기 실패") }
            saveMark(Mark(savedAt: snap.savedAt, fingerprint: fingerprint(saveFiles(fz))), dish)
            NSLog("[IceTray] \(dish.dataPathApp): save.json → 파일 \(snap.entries.count)개\(backedUp ? " (그전 파일은 백업)" : "")")
            return backedUp ? .unpackedWithBackup : .unpacked
        }
        if filesChanged, !(jsonChanged && !allowUnpack) {
            // 파일 수정 시각 중 가장 늦은 것을 저장 시각으로 (PC 에서 넣은 세이브도 그 시각 그대로)
            let latest = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? Date()
            let savedAt = (latest.timeIntervalSince1970 * 1000).rounded()
            guard let entries = entries(files, fz: fz) else { return .skipped("파일이 너무 커요") }
            // 같은 시각이 이미 있으면(같은 ms) 1 올려 다른 저장으로 보이게
            let at = savedAt == mark?.savedAt ? savedAt + 1 : savedAt
            guard fz.saveLocalStorage(entries, savedAt: at) else { return .skipped("save.json 쓰기 실패") }
            saveMark(Mark(savedAt: at, fingerprint: fp), dish)
            NSLog("[IceTray] \(dish.dataPathApp): 파일 \(entries.count)개 → save.json")
            return .packed
        }
        if jsonChanged && !allowUnpack { return .skipped("게임 실행 중") }
        return .nothing
    }

    /// 저장 파일로 받아들이는 이름: 숨김·경로 구분자·`..` 없음, 허용 확장자, 200바이트 이하
    static func safeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 200, !name.hasPrefix("."), !name.contains("/"), !name.contains("\u{0}"),
              !name.contains(".."), !name.hasSuffix(".tmp") else { return false }
        return saveExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func key(_ name: String, fz: Freezer) -> String {
        fz.keyPrefix + "file." + name.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func name(fromKey k: String, fz: Freezer) -> String? {
        let head = fz.keyPrefix + "file."
        guard k.hasPrefix(head) else { return nil }
        let hex = Array(k.dropFirst(head.count))
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var i = 0
        while i < hex.count {
            guard let b = UInt8(String(hex[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b); i += 2
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    private static func entries(_ files: [URL], fz: Freezer) -> [String: String]? {
        var out: [String: String] = [:]
        var total = 0
        for f in files {
            guard let d = try? Data(contentsOf: f) else { continue }
            let s = d.base64EncodedString()
            total += s.utf8.count
            if total > Freezer.maxBytes { return nil }
            out[key(f.lastPathComponent, fz: fz)] = s
        }
        return out.isEmpty ? nil : out
    }

    private static func packData(_ files: [URL], fz: Freezer, savedAt: Double) -> Data? {
        guard let e = entries(files, fz: fz) else { return nil }
        let payload: [String: Any] = ["format": Freezer.format, "version": 1, "savedAt": savedAt, "data": e]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// save.json 의 항목을 파일로. 이름은 Freezer 키 규칙을 지난 것만(경로 구분자·`..` 불가), 값은 base64 여야 한다
    private static func unpack(_ snap: Freezer.Snapshot, fz: Freezer) -> Bool {
        var ok = true
        for (k, v) in snap.entries {
            guard fz.isValidKey(k), let name = Self.name(fromKey: k, fz: fz), safeName(name), name != fz.localStorageFile.lastPathComponent,
                  let data = Data(base64Encoded: v) else { continue }
            let dest = fz.directory.appendingPathComponent(name)
            guard dest.deletingLastPathComponent().standardizedFileURL == fz.directory.standardizedFileURL else { continue }
            if (try? data.write(to: dest, options: .atomic)) == nil { ok = false }
        }
        return ok
    }
}

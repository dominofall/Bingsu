import Foundation
import Network
import AuthenticationServices

/// Google Drive 선반. appDataFolder(사용자에게 보이지 않는 앱 전용 공간) 에 **평평하게** 둔다:
///   name = 경로의 "/" 를 "__" 로 (`Saves__pokemon-resonance__save.json`), appProperties.path = 원래 상대 경로,
///   save.json 은 device·model·savedAt·uploadedAt 도 (충돌 카드를 채울 수 있게, 각 124바이트 안).
/// 동기화 한 번마다(`refresh`) 목록을 한 번 받아 path → 파일 캐시로 list·modified·checksum 에 답한다.
/// v3 에는 조건부 쓰기가 없어, 올리기 직전 md5 를 다시 보고 다른 기기가 먼저 올렸으면 덮어쓰지 않는다.
/// 클라우드 값은 믿지 않는다: path 는 모양을 검사하고, 내용은 엔진이 지금처럼 검증한다.
final class DriveShelf: IglooShelf {
    let kind = IglooShelfKind.drive
    private let counter: DriveCounter

    /// 백업은 클라우드에 게임마다 최근 20개만 (사용자 Drive 용량을 쓴다). 로컬 백업은 그대로
    static let backupCap = 20

    private var files: [String: DriveFile] = [:]
    /// 같은 path 가 둘 이상(두 기기가 동시에 첫 업로드) — 그 경로를 맞춘 뒤 정리한다
    private var duplicates: [String: [DriveFile]] = [:]

    init(counter: DriveCounter) { self.counter = counter }

    // MARK: 경로 ↔ 이름

    static func name(for path: String) -> String { path.replacingOccurrences(of: "/", with: "__") }
    static func path(fromName name: String) -> String { name.replacingOccurrences(of: "__", with: "/") }

    /// 클라우드가 준 경로가 엔진이 쓰는 모양인지 (Saves/·Prefs/·Covers/ 아래, 숨김·".."·"\\"·":" 없음)
    static func safePath(_ p: String) -> Bool {
        let parts = p.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2...4).contains(parts.count), ["Saves", "Prefs", "Covers"].contains(parts[0]), p.utf8.count <= 400 else { return false }
        return parts.allSatisfy { IglooEngine.safeFolder($0) && $0 != ".." }
    }

    static func path(of f: DriveFile) -> String? {
        let p = f.appProperties["path"] ?? path(fromName: f.name)
        return safePath(p) ? p : nil
    }

    /// appProperties 한 개는 키+값 124바이트까지
    static func fit(_ key: String, _ value: String) -> String? {
        var v = value
        while (key.utf8.count + v.utf8.count) > 124, !v.isEmpty { v.removeLast() }
        return v.isEmpty ? nil : v
    }

    private func properties(_ path: String, _ data: Data) -> [String: String] {
        var p: [String: String] = [:]
        // 경로가 길면(120바이트 넘음) 이름에서 되살린다
        if path.utf8.count + 4 <= 124 { p["path"] = path }
        p["uploadedAt"] = String(Int((Date().timeIntervalSince1970 * 1000).rounded()))
        if path.hasSuffix("/save.json"), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let d = IglooEngine.clean(o["device"] as? String) { p["device"] = Self.fit("device", d) }
            if let m = IglooEngine.clean(o["model"] as? String) { p["model"] = Self.fit("model", m) }
            if let at = (o["savedAt"] as? NSNumber)?.doubleValue, at.isFinite { p["savedAt"] = String(Int(at.rounded())) }
        }
        return p
    }

    // MARK: 목록 캐시

    func refresh() throws {
        let all = try counter.listAll()
        var byPath: [String: [DriveFile]] = [:]
        for f in all { if let p = Self.path(of: f) { byPath[p, default: []].append(f) } }
        files = [:]; duplicates = [:]
        for (p, fs) in byPath {
            let sorted = fs.sorted { ($0.modifiedTime ?? .distantPast) > ($1.modifiedTime ?? .distantPast) }
            files[p] = sorted[0]
            if sorted.count > 1 { duplicates[p] = Array(sorted.dropFirst()) }
        }
        NSLog("[Igloo] drive: 목록 \(files.count)개\(duplicates.isEmpty ? "" : " (겹침 \(duplicates.count)개)")")
    }

    func list(_ dir: String) -> [String] {
        files.keys.compactMap { p -> String? in
            let ns = p as NSString
            return ns.deletingLastPathComponent == dir ? ns.lastPathComponent : nil
        }
    }

    func modified(_ path: String) -> Date? { files[path]?.modifiedTime }
    func checksum(_ path: String) -> String? { files[path]?.md5 }

    func classify(_ error: Error) -> IglooShelfError { .from(error) }

    // MARK: 내려받기 캐시 (Library/Caches/Drive/<id>-<md5>)

    private static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Drive", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 파일 id 는 클라우드 값이라 파일 이름에 넣기 전에 모양을 본다
    private static func safeID(_ id: String) -> Bool {
        id.count <= 200 && !id.isEmpty && id.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || "_-".unicodeScalars.contains($0)
        }
    }

    private func cached(_ id: String, _ md5: String) -> Data? {
        guard Self.safeID(id) else { return nil }
        let u = Self.cacheDir.appendingPathComponent("\(id)-\(md5)")
        guard let d = try? Data(contentsOf: u), d.md5Hex == md5 else { return nil }
        return d
    }

    private func store(_ id: String, _ md5: String, _ data: Data, path: String) {
        // 저장 데이터(save.json·백업)만: 매번 16MB 를 받지 않게. 설정·표지는 작거나 한 번만 받는다
        guard Self.safeID(id), path.hasPrefix("Saves/") else { return }
        dropCache(id)
        try? data.write(to: Self.cacheDir.appendingPathComponent("\(id)-\(md5)"), options: .atomic)
    }

    private func dropCache(_ id: String) {
        guard Self.safeID(id) else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.cacheDir.path)) ?? []
        for n in names where n.hasPrefix(id + "-") { try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent(n)) }
    }

    // MARK: 읽기 · 쓰기 · 지우기

    func read(_ path: String, maxBytes: Int) throws -> Data? {
        guard let f = files[path] else { return nil }
        if let s = f.size, s > maxBytes { throw IglooError.tooLarge }
        if let m = f.md5, let d = cached(f.id, m) { settle(path); return d }
        guard let d = try counter.download(f.id, maxBytes: maxBytes) else { files[path] = nil; return nil }
        let m = d.md5Hex
        // 목록을 본 뒤 바뀌었을 수 있다: 올리기 직전 비교의 기준은 실제로 읽은 내용
        files[path]?.md5 = m
        files[path]?.size = d.count
        store(f.id, m, d, path: path)
        settle(path)
        return d
    }

    func write(_ path: String, _ data: Data, modified: Date?) throws {
        let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        if dir.hasSuffix("/backups"), isOlderThanKept(dir, name) {
            NSLog("[Igloo] drive: 오래된 백업이라 올리지 않음 (최근 \(Self.backupCap)개만)")
            return
        }
        let props = properties(path, data)
        let m = data.md5Hex
        var result: DriveFile
        if let f = files[path] {
            // 올리기 직전 재확인: 목록(또는 읽은 내용) 뒤에 다른 기기가 올렸으면 덮어쓰지 않는다
            if let now = try counter.get(f.id) {
                if let a = now.md5, let b = f.md5, a != b {
                    NSLog("[Igloo] drive: 다른 기기가 먼저 올렸어요 · 다음에")
                    throw DriveError.changedRemotely
                }
                result = now.md5 == m && modified == nil ? now
                    : try counter.update(id: f.id, appProperties: props, data: data, modifiedTime: modified, key: path)
            } else {
                result = try counter.create(name: Self.name(for: path), appProperties: props, data: data, modifiedTime: modified, key: path)
            }
        } else {
            result = try counter.create(name: Self.name(for: path), appProperties: props, data: data, modifiedTime: modified, key: path)
        }
        if result.md5 == nil { result.md5 = m }
        if result.size == nil { result.size = data.count }
        if result.modifiedTime == nil { result.modifiedTime = modified ?? Date() }
        if result.appProperties["path"] == nil, props["path"] != nil { result.appProperties = props }
        files[path] = result
        store(result.id, m, data, path: path)
        settle(path)
        if dir.hasSuffix("/backups") { trimBackups(dir) }
    }

    /// 경로 하나 또는 그 아래 전부 ("Saves/<폴더>")
    func remove(_ path: String) throws {
        let keys = files.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
        let dupKeys = duplicates.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
        for k in keys { if let f = files[k] { try counter.delete(f.id); dropCache(f.id); files[k] = nil } }
        for k in dupKeys { for f in duplicates[k] ?? [] { try counter.delete(f.id) }; duplicates[k] = nil }
        if !keys.isEmpty { NSLog("[Igloo] drive: \(keys.count)개 지움") }
    }

    // MARK: 겹친 파일 · 백업 상한

    /// 같은 경로에 남은 다른 파일을 지운다. save.json 이면 그 내용을 클라우드 백업으로 먼저 남긴다 (다른 기기의 첫 저장을 잃지 않게)
    private func settle(_ path: String) {
        guard let dups = duplicates.removeValue(forKey: path) else { return }
        var keep: [DriveFile] = []
        for f in dups {
            if path.hasSuffix("/save.json") {
                guard let d = try? counter.download(f.id, maxBytes: Freezer.maxBytes) else { keep.append(f); continue }
                let dir = (path as NSString).deletingLastPathComponent + "/backups"
                let stamp = Freezer.stamp.string(from: f.modifiedTime ?? Date())
                var n = 1
                while files["\(dir)/\(stamp)-c\(n).json"] != nil { n += 1 }
                do { try write("\(dir)/\(stamp)-c\(n).json", d, modified: nil) } catch { keep.append(f); continue }
            }
            do { try counter.delete(f.id); NSLog("[Igloo] drive: 겹친 파일 정리") } catch { keep.append(f) }
        }
        if !keep.isEmpty { duplicates[path] = keep }
    }

    /// 백업 순서: 이름의 시각(yyyy-MM-dd-HHmm) → 수정 시각 → 이름 ("-2" < "-10")
    private func before(_ a: String, _ b: String, in dir: String) -> Bool {
        func key(_ n: String) -> Date { Freezer.stamp.date(from: String(n.prefix(15))) ?? files["\(dir)/\(n)"]?.modifiedTime ?? .distantPast }
        let ka = key(a), kb = key(b)
        return ka != kb ? ka < kb : a.localizedStandardCompare(b) == .orderedAscending
    }

    private func ordered(_ dir: String) -> [String] { list(dir).sorted { before($0, $1, in: dir) } }

    /// 이미 20개를 두고 있고 그중 가장 오래된 것보다도 오래된 백업이면 올리지 않는다 (지웠다 올렸다를 되풀이하지 않게)
    private func isOlderThanKept(_ dir: String, _ name: String) -> Bool {
        let names = ordered(dir)
        guard names.count >= Self.backupCap, !names.contains(name), let oldest = names.first else { return false }
        return before(name, oldest, in: dir)
    }

    private func trimBackups(_ dir: String) {
        let names = ordered(dir)
        guard names.count > Self.backupCap else { return }
        var n = 0
        for name in names.prefix(names.count - Self.backupCap) {
            guard let f = files["\(dir)/\(name)"] else { continue }
            if (try? counter.delete(f.id)) != nil { files["\(dir)/\(name)"] = nil; dropCache(f.id); n += 1 }
        }
        if n > 0 { NSLog("[Igloo] drive: 백업 \(n)개 정리") }
    }
}

#if DEBUG
/// 가짜 Drive 선반 (`BINGSU_FAKE_DRIVE=<폴더>`): 폴더를 Drive 처럼 쓴다. 화면 흐름(첫 업로드·내려받기·충돌·거부·삭제) 을
/// 시뮬레이터 두 대에서 보려고. 네트워크 경로는 `tools/drive-mock` 흉내 서버로 따로 본다
struct FakeDriveShelf: IglooShelf {
    let folder: ICloudShelf
    var kind: IglooShelfKind { .drive }
    init(root: URL) {
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        folder = ICloudShelf(documents: docs, real: false)
    }
    func read(_ path: String, maxBytes: Int) throws -> Data? { try folder.read(path, maxBytes: maxBytes) }
    func write(_ path: String, _ data: Data, modified: Date?) throws { try folder.write(path, data, modified: modified) }
    func list(_ dir: String) -> [String] { folder.list(dir) }
    func modified(_ path: String) -> Date? { folder.modified(path) }
    func remove(_ path: String) throws { try folder.remove(path) }
    func checksum(_ path: String) -> String? { folder.checksum(path) }
    func classify(_ error: Error) -> IglooShelfError { .from(error) }
}
#endif

/// Drive 선반 공급자: 클라이언트 ID·연결 상태·네트워크를 보고 선반을 만든다
final class DriveProvider: IglooShelfProvider {
    let kind = IglooShelfKind.drive
    let ticket = DriveTicket.shared
    private var counter: DriveCounter?
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _online = true

    init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock(); self._online = p.status == .satisfied; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "bingsu.drive.path", qos: .utility))
    }

    var online: Bool {
        #if DEBUG
        if fakeRoot != nil { return true }
        #endif
        lock.lock(); defer { lock.unlock() }; return _online
    }

    #if DEBUG
    private var fakeRoot: URL? {
        ProcessInfo.processInfo.environment["BINGSU_FAKE_DRIVE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }
    #endif

    /// 빌드에 클라이언트 ID 가 있거나(또는 디버그 가짜·흉내 서버) Drive 를 고를 수 있다
    var isConfigured: Bool {
        #if DEBUG
        if fakeRoot != nil { return true }
        #endif
        return DriveTicket.config != nil
    }

    var isConnected: Bool {
        #if DEBUG
        if fakeRoot != nil { return true }
        #endif
        return ticket.isConnected
    }

    var lostConnection: Bool { ticket.lostConnection }

    func availability() async -> Igloo.Availability {
        #if DEBUG
        if fakeRoot != nil { NSLog("[Igloo] 가짜 Drive 폴더 사용"); return .ready }
        #endif
        guard DriveTicket.config != nil else { return .unavailable }
        guard ticket.isConnected else { return .noAccount }
        guard online else { return .offline }
        return .ready
    }

    func makeShelf() async -> IglooShelf? {
        #if DEBUG
        if let r = fakeRoot { return FakeDriveShelf(root: r) }
        #endif
        guard let cfg = DriveTicket.config else { return nil }
        if counter == nil { counter = DriveCounter(ticket: ticket, base: cfg.apiBase) }
        return counter.map { DriveShelf(counter: $0) }
    }

    @MainActor func connect(anchor: ASPresentationAnchor) async throws { try await ticket.connect(anchor: anchor) }

    func disconnect() async {
        await ticket.disconnect()
        counter = nil
    }

    var accountLabel: String? {
        #if DEBUG
        if fakeRoot != nil { return "연결됨 · 가짜 폴더(디버그)" }
        #endif
        return ticket.accountLabel
    }
}

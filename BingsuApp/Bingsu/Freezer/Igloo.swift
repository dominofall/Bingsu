import Foundation
import UIKit
import Combine
import CryptoKit
import AuthenticationServices

// 이글루: 냉동실(Saves/)과 게임별 설정(Prefs/, Covers/)을 클라우드와 맞춘다.
// 선반(백엔드)은 한 번에 하나: iCloud Documents(`ICloudShelf`) 또는 Google Drive appDataFolder(`DriveShelf`).
// 판단 로직(`IglooEngine`)은 선반 종류를 모르고 상대 경로로만 말한다.
//
// 클라우드 배치 (컨테이너 Documents/ 기준, 로컬 Documents/ 와 같은 모양):
//   Saves/<dataPathApp>/save.json      로컬 save.json + 올린 기기 정보(device, model, playSeconds, uploadedAt)
//   Saves/<dataPathApp>/backups/*.json 백업 (양쪽 합집합. 지우기는 퍼뜨리지 않음)
//   Prefs/<id>.json                    게임별 설정 (수정 시각이 늦은 쪽이 이김, 권장 화질은 기기마다 유지)
//   Covers/<파일>                       표지 이미지 (없는 쪽에 복사)
//
// save.json 판단: 로컬 savedAt(L), 클라우드 savedAt(C), 마지막으로 두 쪽을 맞춘 savedAt(B, 이 기기의 state-<선반>.json).
//   L == C → 같음 · L == B → 클라우드가 새것(내려받기) · C == B → 로컬이 새것(올리기) · 그 밖 → 충돌(덮어쓰지 않음)
// 원격 웹 게임은 로그인 토큰 때문에 저장 데이터를 파일로 꺼내지 않으므로 대상이 아니다 (8.2).
// 클라우드 파일도 신뢰하지 않는다: Freezer.validate(크기·형식·키 정규식·문자열 값)를 거친 것만 쓴다.

/// 선반 종류. 설정 값(`bingsu.syncBackend`)·state 파일 이름·화면 문구의 키
enum IglooShelfKind: String, CaseIterable {
    case off, icloud, drive

    var label: String {
        switch self { case .off: return "끔"; case .icloud: return "iCloud"; case .drive: return "Google Drive" }
    }
    var symbol: String {
        switch self { case .off: return ""; case .icloud: return "icloud"; case .drive: return "externaldrive.badge.icloud" }
    }
}

/// 선반마다 다른 오류를 엔진·화면이 알아듣는 몇 가지로
enum IglooShelfError { case quotaFull, signedOut, offline, tooLarge, other }

/// 클라우드 선반 하나(동기화 백엔드). 경로는 컨테이너 Documents 기준 상대 경로 ("Saves/<게임>/save.json").
/// 모든 함수는 `Igloo.queue` 안에서만, 동기적으로 부른다 (Drive 는 그 안에서 네트워크를 기다린다)
protocol IglooShelf {
    var kind: IglooShelfKind { get }
    /// 없으면 nil. `maxBytes` 보다 크면 읽지 않고 `IglooError.tooLarge`
    func read(_ path: String, maxBytes: Int) throws -> Data?
    func write(_ path: String, _ data: Data, modified: Date?) throws
    /// 폴더 안 파일 이름 (숨김 제외)
    func list(_ dir: String) -> [String]
    func modified(_ path: String) -> Date?
    /// 파일이나 폴더를 지운다 (없으면 그냥 넘어감)
    func remove(_ path: String) throws
    /// 내용 MD5 (16진 소문자). 모르면 nil
    func checksum(_ path: String) -> String?
    func classify(_ error: Error) -> IglooShelfError
    /// 동기화 한 번을 시작하기 전에 클라우드 목록을 새로 본다 (Drive). iCloud 는 할 일 없음
    func refresh() throws
}

extension IglooShelf {
    func refresh() throws {}
}

extension Data {
    /// 내용 MD5 (16진 소문자) — Drive md5Checksum 과 같은 모양
    var md5Hex: String { Insecure.MD5.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

extension IglooShelfError {
    /// 오프라인·용량 부족 같은 공통 오류 (선반이 자기 것을 먼저 보고 모르면 이걸로)
    static func common(_ error: Error) -> IglooShelfError {
        if let e = error as? IglooError, e == .tooLarge { return .tooLarge }
        let e = error as NSError
        if (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError)
            || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC)) { return .quotaFull }
        if e.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff].contains(e.code) { return .offline }
        return .other
    }
}

enum IglooError: Error { case tooLarge, badPayload }

/// iCloud Documents 선반. `real == false` 면 BINGSU_FAKE_ICLOUD 로컬 폴더(시뮬레이터 검증용)라 iCloud API 를 부르지 않는다.
struct ICloudShelf: IglooShelf {
    let documents: URL
    let real: Bool
    var kind: IglooShelfKind { .icloud }
    /// 아직 안 내려온 파일을 기다리는 최대 시간. 넘으면 이번에는 없는 셈 치고 다음 동기화 때 다시 본다
    static let downloadTimeout: TimeInterval = 4

    private func url(_ path: String) -> URL { documents.appendingPathComponent(path) }

    /// iCloud 에만 있고 기기에 아직 없는 파일이면 받기를 시작하고 잠깐 기다린다
    private func ensureDownloaded(_ u: URL) {
        guard real else { return }
        let fm = FileManager.default
        let placeholder = u.deletingLastPathComponent().appendingPathComponent("." + u.lastPathComponent + ".icloud")
        guard fm.fileExists(atPath: u.path) || fm.fileExists(atPath: placeholder.path) else { return }
        func current() -> Bool {
            var v = u; v.removeAllCachedResourceValues()
            guard fm.fileExists(atPath: v.path) else { return false }
            let s = try? v.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            return s == nil || s == .current
        }
        if current() { return }
        try? fm.startDownloadingUbiquitousItem(at: u)
        let deadline = Date().addingTimeInterval(Self.downloadTimeout)
        while !current() && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    }

    func read(_ path: String, maxBytes: Int) throws -> Data? {
        let u = url(path)
        ensureDownloaded(u)
        var result: Result<Data?, Error> = .success(nil)
        var cerr: NSError?
        NSFileCoordinator().coordinate(readingItemAt: u, options: [], error: &cerr) { r in
            guard FileManager.default.fileExists(atPath: r.path) else { return }
            let size = (try? r.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxBytes else { result = .failure(IglooError.tooLarge); return }
            result = Result {
                let d = try Data(contentsOf: r)
                if d.count > maxBytes { throw IglooError.tooLarge }
                return d
            }
        }
        if let cerr { throw cerr }
        return try result.get()
    }

    func write(_ path: String, _ data: Data, modified: Date?) throws {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var werr: Error?
        var cerr: NSError?
        NSFileCoordinator().coordinate(writingItemAt: u, options: .forReplacing, error: &cerr) { w in
            do {
                try data.write(to: w, options: .atomic)
                if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: w.path) }
            } catch { werr = error }
        }
        if let cerr { throw cerr }
        if let werr { throw werr }
    }

    func list(_ dir: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url(dir).path)) ?? []
        return Array(Set(names.compactMap { n -> String? in
            // 아직 안 내려온 iCloud 파일은 ".<이름>.icloud" 로 보일 수 있다
            if n.hasPrefix("."), n.hasSuffix(".icloud") { return String(n.dropFirst().dropLast(7)) }
            return n.hasPrefix(".") ? nil : n
        }))
    }

    func modified(_ path: String) -> Date? {
        let u = url(path)
        ensureDownloaded(u)
        return try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func remove(_ path: String) throws {
        let u = url(path)
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        var rerr: Error?
        var cerr: NSError?
        NSFileCoordinator().coordinate(writingItemAt: u, options: .forDeleting, error: &cerr) { w in
            do { try FileManager.default.removeItem(at: w) } catch { rerr = error }
        }
        if let cerr { throw cerr }
        if let rerr { throw rerr }
    }

    /// iCloud 는 내용 해시를 주지 않는다: 이미 내려와 있는 파일이면 직접 계산 (16MB 이하만)
    func checksum(_ path: String) -> String? {
        let u = url(path)
        guard let size = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Freezer.maxBytes,
              let d = try? Data(contentsOf: u) else { return nil }
        return d.md5Hex
    }

    func classify(_ error: Error) -> IglooShelfError { .common(error) }
}

/// 이 기기의 동기화 기록 (`Library/Application Support/Igloo/state-<선반>.json`, Files 앱에 안 보임).
/// 선반마다 따로 둔다: 다른 선반으로 바꾸면 B 가 없으니 첫 동기화에서 양쪽이 다르면 충돌로 묻는다
struct IglooState: Codable {
    struct Save: Codable, Equatable {
        /// 마지막으로 로컬과 클라우드를 맞춘 save.json 의 savedAt (B)
        var syncedSavedAt: Double?
        var syncedAt: Date?
        var conflict = false
    }
    var saves: [String: Save] = [:]
    var lastSync: Date?

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Igloo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(kind: IglooShelfKind) -> URL { directory.appendingPathComponent("state-\(kind.rawValue).json") }

    /// 빌드 24 까지의 `state.json`(iCloud 하나뿐이던 때) 을 `state-icloud.json` 으로 한 번 옮긴다
    static func migrateLegacy() {
        let fm = FileManager.default
        let old = directory.appendingPathComponent("state.json"), new = fileURL(kind: .icloud)
        guard fm.fileExists(atPath: old.path) else { return }
        if fm.fileExists(atPath: new.path) { try? fm.removeItem(at: old) }
        else if (try? fm.moveItem(at: old, to: new)) != nil { NSLog("[Igloo] state.json → state-icloud.json 옮김") }
    }

    static func load(kind: IglooShelfKind) -> IglooState {
        if kind == .icloud { migrateLegacy() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: fileURL(kind: kind)), let s = try? dec.decode(IglooState.self, from: d) else { return IglooState() }
        return s
    }

    func save(kind: IglooShelfKind) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: Self.fileURL(kind: kind), options: .atomic) }
    }

    static func remove(kind: IglooShelfKind) { try? FileManager.default.removeItem(at: fileURL(kind: kind)) }
}

/// 기기 하나의 저장 데이터 요약 (충돌 화면)
struct IglooSide: Equatable {
    var device: String
    var savedAt: Date
    var playSeconds: Double?
}

/// "어느 저장 데이터로 할까요?" 에 보여 줄 두 쪽
struct IglooConflict: Identifiable, Equatable {
    let dish: Dish
    let local: IglooSide
    let cloud: IglooSide
    /// 클라우드 쪽 카드 제목·아이콘 ("iCloud", "Google Drive")
    var shelfName: String
    var shelfSymbol: String
    var id: String { dish.id }
}

/// 올린 기기 정보 (메인 스레드에서 한 번 읽어 둔다)
struct IglooDevice {
    /// 사용자가 보는 기기 이름 (UIDevice.name: iOS 16+ 에서는 보통 "iPhone"/"iPad"). 충돌 화면·토스트에만 쓰고 로그에는 안 남긴다
    var name: String
    /// "iPhone"/"iPad"
    var model: String
}

/// 실제 파일 작업. 직렬 큐 하나에서만 돈다 (Igloo.queue).
final class IglooEngine {
    let shelf: IglooShelf
    private(set) var state: IglooState
    let device: IglooDevice

    init(shelf: IglooShelf, device: IglooDevice) {
        self.shelf = shelf; self.device = device
        state = IglooState.load(kind: shelf.kind)
    }

    private var name: String { shelf.kind.label }

    enum Outcome {
        case nothing, uploaded
        case downloaded(device: String, savedAt: Double)
        case conflict(IglooConflict)
        case skipped(String)
    }

    struct CloudSave {
        var entries: [String: String]
        var savedAt: Double
        var device: String
        var playSeconds: Double?
        var data: Data
    }

    /// 쓰기 실패 중 저장 공간 부족 (설정 화면 상태 줄)
    private(set) var quotaFull = false
    /// 이번 동기화 중 선반 연결이 끊김(Drive 토큰 만료 등)·네트워크 없음. 끊기면 남은 게임은 건너뛴다 (로컬은 그대로)
    private(set) var signedOut = false
    private(set) var offline = false

    /// 선반 오류를 상태로 남긴다 (용량 부족·연결 끊김·오프라인)
    private func note(_ error: Error) {
        switch shelf.classify(error) {
        case .quotaFull: quotaFull = true
        case .signedOut: signedOut = true
        case .offline: offline = true
        case .tooLarge, .other: break
        }
    }

    /// 동기화 한 번을 시작할 때 (Igloo.run): 지난번 상태를 지우고 선반 목록을 새로 본다
    func begin() throws {
        signedOut = false; offline = false
        do { try shelf.refresh() } catch { note(error); throw error }
    }

    /// 연결이 끊겼거나 네트워크가 없으면 남은 작업을 하지 않는다 (요청마다 시간 초과를 기다리지 않게)
    var halted: Bool { signedOut || offline }

    /// 동기화 한 번이 끝난 뒤 화면에 넘길 상태 (큐 안에서 찍는다)
    struct Snapshot { var state: IglooState; var quotaFull, signedOut, offline, listed: Bool }
    func snapshot(listed: Bool) -> Snapshot {
        Snapshot(state: state, quotaFull: quotaFull, signedOut: signedOut, offline: offline, listed: listed)
    }

    // MARK: 경로

    /// 저장 폴더 이름이 경로로 새지 않는지 ("/", "..", 숨김 금지)
    static func safeFolder(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && !s.contains("/") && !s.contains("\\") && !s.contains(":") && !s.contains("\0") && s.count <= 120
    }

    /// 백업·표지 파일 이름 규칙
    static func safeFileName(_ s: String, ext: [String]) -> Bool {
        guard !s.hasPrefix("."), s.count <= 120, ext.contains((s as NSString).pathExtension.lowercased()) else { return false }
        return s.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || "_.-".unicodeScalars.contains($0)
        }
    }

    private func savePath(_ dish: Dish) -> String { "Saves/\(dish.dataPathApp)/save.json" }

    // MARK: save.json

    /// 클라우드 save.json 을 읽고 검증한다. 없으면 nil, 깨졌으면 throw (로컬은 건드리지 않음)
    func readCloudSave(_ dish: Dish) throws -> CloudSave? {
        guard let data = try shelf.read(savePath(dish), maxBytes: Freezer.maxBytes) else { return nil }
        let fz = Freezer(dish: dish)
        let entries = try fz.validate(data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = (obj["savedAt"] as? NSNumber)?.doubleValue, at.isFinite, at > 0, at < 1e15 else { throw IglooError.badPayload }
        let dev = Self.clean(obj["device"] as? String) ?? Self.clean(obj["model"] as? String) ?? "다른 기기"
        let play = ((obj["playSeconds"] as? NSNumber)?.doubleValue).flatMap { $0.isFinite && $0 >= 0 && $0 < 1e9 ? $0 : nil }
        return CloudSave(entries: entries, savedAt: at.rounded(), device: dev, playSeconds: play, data: data)
    }

    /// 화면에 보일 기기 이름: 제어 문자 빼고 40자까지
    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(40))
    }

    private func upload(_ snap: Freezer.Snapshot, dish: Dish, playSeconds: Double?) throws {
        var payload: [String: Any] = ["format": Freezer.format, "version": 1, "savedAt": snap.savedAt, "data": snap.entries,
                                      "device": device.name, "model": device.model,
                                      "uploadedAt": (Date().timeIntervalSince1970 * 1000).rounded()]
        if let playSeconds { payload["playSeconds"] = playSeconds.rounded() }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= Freezer.maxBytes else { throw IglooError.tooLarge }
        do { try shelf.write(savePath(dish), data, modified: nil); quotaFull = false }
        catch { note(error); throw error }
    }

    /// 사용자가 저장 데이터를 지웠을 때: 클라우드 쪽 그 게임 폴더(save.json·백업)와 이 기기의 맞춘 기록을 지운다.
    /// 안 지우면 다음 동기화 때 iCloud 에서 그대로 다시 내려온다
    func forget(folder: String) -> Bool {
        guard Self.safeFolder(folder) else { return false }
        do { try shelf.remove("Saves/\(folder)") } catch {
            note(error)
            NSLog("[Igloo] \(folder): \(name) 저장 데이터 지우기 실패 (\(Self.reason(error)))"); return false
        }
        state.saves[folder] = nil
        state.save(kind: shelf.kind)
        return true
    }

    private func markSynced(_ key: String, _ savedAt: Double) {
        let now = Date()
        state.saves[key] = IglooState.Save(syncedSavedAt: savedAt, syncedAt: now, conflict: false)
        state.lastSync = now
        state.save(kind: shelf.kind)
    }

    private static func same(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return false }
        return abs(a - b) < 1
    }

    /// 저장 데이터 하나 맞추기. `allowDownload == false` 면(게임이 켜져 있음) 로컬 파일을 바꾸지 않는다.
    func reconcile(_ dish: Dish, allowDownload: Bool, playSeconds: Double?) -> Outcome {
        guard !dish.isRemote, Self.safeFolder(dish.dataPathApp) else { return .skipped("대상 아님") }
        let key = dish.dataPathApp
        // 파일로 저장하는 게임(RPG Maker XP): 게임이 쓴 Game.rxdata 등을 먼저 save.json 에 묶는다 (IceTray)
        IceTray.sync(dish, allowUnpack: allowDownload)
        let fz = Freezer(dish: dish)
        let local = fz.loadLocalStorage()
        let cloud: CloudSave?
        do { cloud = try readCloudSave(dish) } catch {
            note(error)
            if signedOut || offline { NSLog("[Igloo] \(key): \(name) 에 닿지 못함 (\(Self.reason(error))) — 다음에"); return .skipped("연결 안 됨") }
            // 깨진 클라우드 파일은 내려받지도, 그 위에 올리지도 않는다 (다른 기기의 좋은 저장을 지우지 않게)
            NSLog("[Igloo] \(key): \(name) save.json 거부 (\(Self.reason(error))) — 로컬 유지")
            return .skipped("클라우드 파일 거부")
        }
        let base = state.saves[key]?.syncedSavedAt
        let L = local?.savedAt, C = cloud?.savedAt
        NSLog("[Igloo] \(key): L=\(L.map { String(format: "%.0f", $0) } ?? "-") C=\(C.map { String(format: "%.0f", $0) } ?? "-") B=\(base.map { String(format: "%.0f", $0) } ?? "-")")

        switch (local, cloud) {
        case (nil, nil):
            return .nothing
        case (let l?, nil):
            do { try upload(l, dish: dish, playSeconds: playSeconds); markSynced(key, l.savedAt); NSLog("[Igloo] \(key): 올림(첫 업로드)"); return .uploaded }
            catch { NSLog("[Igloo] \(key): 올리기 실패 \(Self.reason(error))"); return .skipped("올리기 실패") }
        case (nil, let c?):
            guard allowDownload else { return .skipped("게임 실행 중") }
            return apply(c, dish: dish)
        case (let l?, let c?):
            if Self.same(l.savedAt, c.savedAt) {
                if !Self.same(base, l.savedAt) || state.saves[key]?.conflict == true { markSynced(key, l.savedAt) }
                return .nothing
            }
            if Self.same(base, l.savedAt) {
                guard allowDownload else { return .skipped("게임 실행 중") }
                return apply(c, dish: dish)
            }
            if Self.same(base, c.savedAt) {
                do { try upload(l, dish: dish, playSeconds: playSeconds); markSynced(key, l.savedAt); NSLog("[Igloo] \(key): 올림"); return .uploaded }
                catch { NSLog("[Igloo] \(key): 올리기 실패 \(Self.reason(error))"); return .skipped("올리기 실패") }
            }
            // 시각만 다르고 내용이 같으면(내려받은 뒤 게임이 같은 내용을 다시 스냅샷) 충돌이 아니다
            if l.entries == c.entries {
                do { try upload(l, dish: dish, playSeconds: playSeconds); markSynced(key, l.savedAt); return .uploaded }
                catch { return .skipped("올리기 실패") }
            }
            // 두 쪽 다 마지막 동기화 뒤에 바뀜 → 덮어쓰지 않고 사용자에게 묻는다
            var s = state.saves[key] ?? IglooState.Save()
            s.conflict = true
            state.saves[key] = s
            state.save(kind: shelf.kind)
            NSLog("[Igloo] \(key): 충돌 — 양쪽 다 바뀜")
            return .conflict(IglooConflict(dish: dish,
                                           local: IglooSide(device: device.name, savedAt: Date(timeIntervalSince1970: l.savedAt / 1000), playSeconds: playSeconds),
                                           cloud: IglooSide(device: c.device, savedAt: Date(timeIntervalSince1970: c.savedAt / 1000), playSeconds: c.playSeconds),
                                           shelfName: shelf.kind.label, shelfSymbol: shelf.kind.symbol))
        }
    }

    /// 클라우드 저장을 로컬 save.json 으로 (savedAt 은 클라우드 값 그대로 → 다음 판단에서 L == C)
    private func apply(_ c: CloudSave, dish: Dish) -> Outcome {
        let fz = Freezer(dish: dish)
        guard fz.saveLocalStorage(c.entries, savedAt: c.savedAt) else { return .skipped("로컬 쓰기 실패") }
        // 게임이 다음에 열릴 때 웹뷰 표식과 파일 savedAt 이 달라 파일이 복원된다
        Freezer.markReplaced(dish.dataPathApp)
        IceTray.sync(dish, allowUnpack: true)   // 파일로 저장하는 게임은 내려받은 것을 바로 파일로
        markSynced(dish.dataPathApp, c.savedAt)
        NSLog("[Igloo] \(dish.dataPathApp): 내려받음 (\(c.entries.count)개 키)")
        return .downloaded(device: c.device, savedAt: c.savedAt)
    }

    /// 충돌 해결: 고른 쪽을 양쪽에 두고, 고르지 않은 쪽은 이 기기 백업에 남긴다 (백업은 동기화로 다른 기기에도 감)
    func resolve(_ dish: Dish, keepLocal: Bool, playSeconds: Double?) -> Outcome {
        let key = dish.dataPathApp
        let fz = Freezer(dish: dish)
        let cloud = try? readCloudSave(dish)
        if keepLocal {
            guard let l = fz.loadLocalStorage() else { return .skipped("로컬 없음") }
            if let cloud { fz.freeze(data: cloud.data) }
            do { try upload(l, dish: dish, playSeconds: playSeconds) } catch {
                NSLog("[Igloo] \(key): 충돌 해결 올리기 실패 \(Self.reason(error))"); return .skipped("올리기 실패")
            }
            markSynced(key, l.savedAt)
            NSLog("[Igloo] \(key): 충돌 해결 — 이 기기 것 유지, \(name) 것은 백업")
            syncBackups(dish)
            return .uploaded
        } else {
            guard let cloud else { return .skipped("클라우드 없음") }
            fz.freeze()
            let r = apply(cloud, dish: dish)
            NSLog("[Igloo] \(key): 충돌 해결 — \(name) 것 사용, 이 기기 것은 백업")
            syncBackups(dish)
            return r
        }
    }

    // MARK: 백업 · 설정 · 표지

    /// 백업은 양쪽 합집합. 내려받는 백업도 검증한다
    func syncBackups(_ dish: Dish) {
        guard !dish.isRemote, Self.safeFolder(dish.dataPathApp) else { return }
        let fz = Freezer(dish: dish)
        let dir = "Saves/\(dish.dataPathApp)/backups"
        let localNames = Set(((try? FileManager.default.contentsOfDirectory(atPath: fz.backupsDirectory.path)) ?? [])
            .filter { Self.safeFileName($0, ext: ["json"]) })
        let cloudNames = Set(shelf.list(dir).filter { Self.safeFileName($0, ext: ["json"]) })
        for n in cloudNames.subtracting(localNames) {
            if halted { return }
            do {
                guard let d = try shelf.read("\(dir)/\(n)", maxBytes: Freezer.maxBytes) else { continue }
                _ = try fz.validate(d)
                try FileManager.default.createDirectory(at: fz.backupsDirectory, withIntermediateDirectories: true)
                try d.write(to: fz.backupsDirectory.appendingPathComponent(n), options: .atomic)
                NSLog("[Igloo] \(dish.dataPathApp): 백업 내려받음 \(n)")
            } catch { note(error); NSLog("[Igloo] \(dish.dataPathApp): 백업 \(n) 거부 (\(Self.reason(error)))") }
        }
        for n in localNames.subtracting(cloudNames) {
            if halted { return }
            let u = fz.backupsDirectory.appendingPathComponent(n)
            guard let size = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Freezer.maxBytes,
                  let d = try? Data(contentsOf: u) else { continue }
            do { try shelf.write("\(dir)/\(n)", d, modified: nil); NSLog("[Igloo] \(dish.dataPathApp): 백업 올림 \(n)") }
            catch { note(error); NSLog("[Igloo] 백업 올리기 실패 \(Self.reason(error))") }
        }
    }

    static let maxPrefsBytes = 64 * 1024
    static let maxCoverBytes = 8 * 1024 * 1024

    /// 게임별 설정: 수정 시각이 늦은 쪽이 이긴다. 권장 화질(벤치마크)은 기기마다 달라 로컬 값을 지킨다.
    /// 설정 파일을 내려받았으면 true (DishPrefsStore 를 다시 읽어야 함)
    func syncPrefs(_ dish: Dish) -> Bool {
        guard !dish.isRemote, !halted else { return false }
        let fm = FileManager.default
        let name = DishPrefsStore.safeName(dish.id) + ".json"
        let lu = DishPrefsStore.prefsDir.appendingPathComponent(name)
        let cp = "Prefs/\(name)"
        let lm = try? lu.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let cm = shelf.modified(cp)
        var changed = false
        if let cm, cm.timeIntervalSince(lm ?? .distantPast) > 1 {
            do {
                guard let d = try shelf.read(cp, maxBytes: Self.maxPrefsBytes) else { return false }
                var p = try JSONDecoder().decode(DishPrefs.self, from: d)
                if let f = p.coverFile, !Self.safeFileName(f, ext: ["jpg", "jpeg", "png"]) { p.coverFile = nil }
                let localPrefs = (try? Data(contentsOf: lu)).flatMap { try? JSONDecoder().decode(DishPrefs.self, from: $0) }
                p.recommendedQuality = localPrefs?.recommendedQuality
                try fm.createDirectory(at: DishPrefsStore.prefsDir, withIntermediateDirectories: true)
                try JSONEncoder().encode(p).write(to: lu, options: .atomic)
                try fm.setAttributes([.modificationDate: cm], ofItemAtPath: lu.path)
                changed = true
                NSLog("[Igloo] 설정 내려받음 \(name)")
            } catch { note(error); NSLog("[Igloo] 설정 \(name) 거부 (\(Self.reason(error)))") }
        } else if let lm, lm.timeIntervalSince(cm ?? .distantPast) > 1,
                  let size = try? lu.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxPrefsBytes,
                  let d = try? Data(contentsOf: lu) {
            do { try shelf.write(cp, d, modified: lm); NSLog("[Igloo] 설정 올림 \(name)") }
            catch { note(error); NSLog("[Igloo] 설정 올리기 실패 \(Self.reason(error))") }
        }
        syncCover(dish)
        return changed
    }

    /// 지금 설정이 가리키는 표지만, 없는 쪽으로 복사한다 (파일 이름에 시각이 붙어 있어 같은 이름 = 같은 그림)
    private func syncCover(_ dish: Dish) {
        let lu = DishPrefsStore.prefsDir.appendingPathComponent(DishPrefsStore.safeName(dish.id) + ".json")
        guard let d = try? Data(contentsOf: lu), let p = try? JSONDecoder().decode(DishPrefs.self, from: d),
              let f = p.coverFile, Self.safeFileName(f, ext: ["jpg", "jpeg", "png"]) else { return }
        let local = DishPrefsStore.coversDir.appendingPathComponent(f)
        let cp = "Covers/\(f)"
        let hasLocal = FileManager.default.fileExists(atPath: local.path)
        let hasCloud = shelf.list("Covers").contains(f)
        if hasLocal && !hasCloud {
            guard let size = try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxCoverBytes,
                  let img = try? Data(contentsOf: local) else { return }
            do { try shelf.write(cp, img, modified: nil); NSLog("[Igloo] 표지 올림") }
            catch { note(error) }
        } else if hasCloud && !hasLocal {
            do {
                guard let img = try shelf.read(cp, maxBytes: Self.maxCoverBytes), UIImage(data: img) != nil else { return }
                try FileManager.default.createDirectory(at: DishPrefsStore.coversDir, withIntermediateDirectories: true)
                try img.write(to: local, options: .atomic)
                NSLog("[Igloo] 표지 내려받음")
            } catch { note(error); NSLog("[Igloo] 표지 거부 (\(Self.reason(error)))") }
        }
    }

    static func reason(_ error: Error) -> String {
        if let e = error as? Freezer.ImportError {
            switch e { case .tooLarge: return "16MB 초과"; case .notBackup: return "형식 아님"; case .badKey: return "키 규칙 위반"; case .empty: return "비어 있음" }
        }
        if let e = error as? IglooError { return e == .tooLarge ? "크기 초과" : "메타 이상" }
        if let e = error as? DriveError { return e.logText }
        let n = error as NSError
        return "\(n.domain) \(n.code)"
    }
}

/// 선반을 만들고 계정 상태를 말해 주는 쪽 (Igloo.makeEngine 이 이것을 부른다). 메인 밖에서 오래 걸릴 수 있는 일은 안에서 넘긴다
protocol IglooShelfProvider: AnyObject {
    var kind: IglooShelfKind { get }
    func availability() async -> Igloo.Availability
    func makeShelf() async -> IglooShelf?
    /// Drive: 연결(동의 화면). iCloud 는 할 일 없음
    @MainActor func connect(anchor: ASPresentationAnchor) async throws
    /// Drive: 토큰 철회·Keychain 삭제. iCloud 는 할 일 없음
    func disconnect() async
    /// 연결됨 표시 ("연결됨 · 11월 1일"). iCloud 는 nil
    var accountLabel: String? { get }
}

/// iCloud Documents. BINGSU_FAKE_ICLOUD=<폴더> 면 그 폴더를 iCloud 처럼 쓴다 (시뮬레이터 검증)
final class ICloudProvider: IglooShelfProvider {
    let kind = IglooShelfKind.icloud
    private var found: ICloudShelf?

    func availability() async -> Igloo.Availability {
        let fake = ProcessInfo.processInfo.environment["BINGSU_FAKE_ICLOUD"]
        let (avail, shelf): (Igloo.Availability, ICloudShelf?) = await withCheckedContinuation { c in
            // url(forUbiquityContainerIdentifier:) 는 오래 걸릴 수 있어 메인 밖에서 부른다
            DispatchQueue.global(qos: .utility).async {
                if let fake, !fake.isEmpty {
                    let docs = URL(fileURLWithPath: fake, isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
                    try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
                    NSLog("[Igloo] 가짜 iCloud 폴더 사용")
                    c.resume(returning: (.ready, ICloudShelf(documents: docs, real: false)))
                } else if FileManager.default.ubiquityIdentityToken == nil {
                    c.resume(returning: (.noAccount, nil))
                } else if let root = FileManager.default.url(forUbiquityContainerIdentifier: Igloo.containerID) {
                    let docs = root.appendingPathComponent("Documents", isDirectory: true)
                    try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
                    c.resume(returning: (.ready, ICloudShelf(documents: docs, real: true)))
                } else {
                    c.resume(returning: (.unavailable, nil))
                }
            }
        }
        found = shelf
        if avail != .ready { NSLog("[Igloo] iCloud 사용 불가 (\(avail == .noAccount ? "로그인 안 됨" : "컨테이너 없음")) — 건너뜀") }
        return avail
    }

    func makeShelf() async -> IglooShelf? { found }
    @MainActor func connect(anchor: ASPresentationAnchor) async throws {}
    func disconnect() async {}
    var accountLabel: String? { nil }
}

/// 동기화 창구 (메인 스레드). 화면은 이것만 본다.
@MainActor
final class Igloo: ObservableObject {
    static let shared = Igloo()
    /// 동기화 선반 (`IglooShelfKind.rawValue`: off·icloud·drive)
    nonisolated static let backendKey = "bingsu.syncBackend"
    /// 빌드 24 까지의 iCloud 켜기/끄기 (첫 실행 때 backendKey 로 옮긴다)
    nonisolated static let legacyEnabledKey = "bingsu.icloudSync"
    nonisolated static let containerID = "iCloud.com.minwoo.bingsu"

    enum Availability: Equatable { case checking, noAccount, unavailable, offline, ready }

    @Published private(set) var backend: IglooShelfKind
    @Published private(set) var availability: Availability = .checking
    @Published private(set) var quotaFull = false
    @Published private(set) var syncing = false
    @Published private(set) var state: IglooState
    /// Drive 연결 표시 ("연결됨 · 11월 1일"), 동의 화면이 떠 있는 동안
    @Published private(set) var accountLabel: String?
    @Published private(set) var connecting = false

    let icloud = ICloudProvider()
    let drive = DriveProvider()

    /// 선반 준비는 한 번만 (동시에 여러 곳에서 불러도 엔진·기록이 하나가 되게)
    private var engineTask: Task<IglooEngine?, Never>?
    private let queue = DispatchQueue(label: "bingsu.igloo", qos: .utility)
    private var dishes: [Dish] = []
    /// 게임을 열 때 한 번 알릴 "다른 기기 저장을 불러왔어요" (dish id → 기기, savedAt)
    private var pendingToasts: [String: (device: String, savedAt: Double)] = [:]
    private let device = IglooDevice(name: UIDevice.current.name, model: UIDevice.current.model)
    private var identityObserver: NSObjectProtocol?

    var enabled: Bool { backend != .off }
    private var provider: IglooShelfProvider? {
        switch backend { case .off: return nil; case .icloud: return icloud; case .drive: return drive }
    }

    /// 예전 토글(true → iCloud, false → 끔, 없음 → iCloud = 빌드 24 기본) 을 선반 값으로 옮기고 지금 값을 돌려준다
    nonisolated static func migrateBackend(_ d: UserDefaults = .standard) -> IglooShelfKind {
        if let raw = d.string(forKey: backendKey), let k = IglooShelfKind(rawValue: raw) { return k }
        let k: IglooShelfKind = (d.object(forKey: legacyEnabledKey) as? Bool ?? true) ? .icloud : .off
        d.set(k.rawValue, forKey: backendKey)
        return k
    }

    private init() {
        let k = Self.migrateBackend()
        backend = k
        state = k == .off ? IglooState() : IglooState.load(kind: k)
        accountLabel = k == .drive ? drive.accountLabel : nil
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let i = Igloo.shared
                guard i.backend == .icloud else { return }
                i.engineTask = nil; i.availability = .checking; await i.syncAll()
            }
        }
    }

    // MARK: 준비

    private func readyEngine() async -> IglooEngine? {
        guard enabled else { return nil }
        if engineTask == nil { engineTask = Task { await self.makeEngine() } }
        let e = await engineTask?.value
        if e == nil || e?.shelf.kind != backend { engineTask = nil; return nil }   // 로그인 안 됨 등: 다음에 다시 확인
        return e
    }

    private func makeEngine() async -> IglooEngine? {
        guard let p = provider else { return nil }
        let avail = await p.availability()
        guard p.kind == backend else { return nil }   // 기다리는 사이 선반을 바꿈
        availability = avail
        guard avail == .ready, let shelf = await p.makeShelf() else { return nil }
        accountLabel = p.accountLabel
        return IglooEngine(shelf: shelf, device: device)
    }

    /// 설정의 "클라우드 동기화" 고르기. 바꾸면 새 선반의 기록으로 처음부터 맞춘다
    func setBackend(_ k: IglooShelfKind) {
        guard k != backend else { return }
        UserDefaults.standard.set(k.rawValue, forKey: Self.backendKey)
        backend = k
        engineTask = nil
        availability = .checking
        quotaFull = false
        state = k == .off ? IglooState() : IglooState.load(kind: k)
        accountLabel = k == .drive ? drive.accountLabel : nil
        NSLog("[Igloo] 선반 바꿈 → \(k.rawValue)")
        if k != .off { Task { await syncAll() } }
    }

    // MARK: Google Drive 연결

    /// "Google Drive 연결": 동의 화면을 띄우고 토큰을 받은 뒤 바로 맞춘다. 실패하면 화면에 보일 문구 (취소는 nil)
    func connectDrive() async -> String? {
        guard let anchor = Self.keyWindow() else { return "화면을 찾지 못했어요. 다시 시도해 주세요." }
        connecting = true
        defer { connecting = false }
        do { try await drive.connect(anchor: anchor) } catch {
            if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { return nil }
            NSLog("[Igloo] drive: 연결 실패 (\(IglooEngine.reason(error)))")
            return (error as? DriveError)?.userText ?? "연결하지 못했어요. 다시 시도해 주세요."
        }
        accountLabel = drive.accountLabel
        engineTask = nil
        availability = .checking
        if backend == .drive { await syncAll() }
        return nil
    }

    /// "연결 해제": 토큰 철회(실패해도 진행) → Keychain·이 기기의 Drive 동기화 기록 삭제. 선반 고르기는 그대로
    func disconnectDrive() async {
        await drive.disconnect()
        await withCheckedContinuation { c in queue.async { IglooState.remove(kind: .drive); c.resume() } }
        engineTask = nil
        accountLabel = nil
        if backend == .drive { state = IglooState(); availability = .noAccount; quotaFull = false }
        NSLog("[Igloo] drive: 연결 해제")
    }

    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    private func run<T>(_ work: @escaping (IglooEngine) -> T) async -> T? {
        guard let e = await readyEngine() else { return nil }
        if backend == .drive, !drive.online { availability = .offline; return nil }
        syncing = true
        // 엔진 상태는 큐 안에서 찍어 온다: 다음 동기화가 큐에서 먼저 begin() 으로 지우기 전에
        let (r, snap): (T?, IglooEngine.Snapshot) = await withCheckedContinuation { c in
            queue.async {
                do { try e.begin() } catch {
                    NSLog("[Igloo] \(e.shelf.kind.label) 목록을 못 읽음 (\(IglooEngine.reason(error))) — 건너뜀")
                    c.resume(returning: (nil, e.snapshot(listed: false))); return
                }
                let r = work(e)
                c.resume(returning: (r, e.snapshot(listed: true)))
            }
        }
        syncing = false
        guard e.shelf.kind == backend else { return r }   // 도는 사이 선반을 바꿈: 새 선반 화면을 덮지 않는다
        state = snap.state
        quotaFull = snap.quotaFull
        if snap.signedOut {
            // 연결이 끊김(갱신 토큰 만료·철회): 동기화를 멈추고 "다시 연결" 을 보인다. 로컬은 그대로
            engineTask = nil
            availability = .noAccount
            accountLabel = drive.accountLabel
            NSLog("[Igloo] \(e.shelf.kind.label) 연결 끊김 — 동기화 멈춤")
        } else if snap.offline {
            availability = .offline
            NSLog("[Igloo] 오프라인 — 다음에 다시")
        } else if snap.listed {
            availability = .ready
        }
        return r
    }

    /// 저장 데이터 지우기의 클라우드 쪽. 동기화가 꺼져 있거나 선반을 못 쓰면 아무것도 안 한다
    func forget(folder: String) async {
        _ = await run { $0.forget(folder: folder) }
    }

    func setDishes(_ d: [Dish]) { dishes = d.filter { !$0.isRemote } }

    /// 이 기기에서 그 게임을 한 시간 (성능 기록 최근 세션 합)
    private func playSeconds(_ dish: Dish) -> Double? {
        guard let s = PerfLogStore.shared.record(for: dish.id)?.sessions, !s.isEmpty else { return nil }
        return s.reduce(0) { $0 + $1.playSeconds }
    }

    // MARK: 동기화 시점

    /// 게임을 열기 직전. 충돌이면 그것을 돌려주고(시트로 묻기), 아니면 nil (필요하면 이미 내려받음)
    func prepareOpen(_ dish: Dish) async -> IglooConflict? {
        guard !dish.isRemote else { return nil }
        let play = playSeconds(dish)
        let out = await run { e -> IglooEngine.Outcome in
            let o = e.reconcile(dish, allowDownload: true, playSeconds: play)
            e.syncBackups(dish)
            return o
        }
        if case .conflict(let c)? = out { return c }
        if case .downloaded(let dev, let at)? = out { pendingToasts[dish.id] = (dev, at) }
        return nil
    }

    /// 게임을 닫거나 홈으로 나간 뒤(flush 가 파일에 닿도록 잠깐 기다림). `stillRunning` 이면 로컬은 바꾸지 않는다
    func afterPlay(_ dish: Dish, stillRunning: Bool) {
        guard !dish.isRemote, enabled else { return }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "igloo-upload")
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            let play = playSeconds(dish)
            let prefsChanged = await run { e -> Bool in
                _ = e.reconcile(dish, allowDownload: !stillRunning, playSeconds: play)
                e.syncBackups(dish)
                return e.syncPrefs(dish)
            }
            if prefsChanged == true { DishPrefsStore.shared.reloadFromDisk() }
            UIApplication.shared.endBackgroundTask(bg)
        }
    }

    /// 앱이 활성화될 때·"지금 동기화". 켜져 있는 게임(`except` 의 dataPathApp)은 건너뛴다
    func syncAll(except running: Set<String> = []) async {
        guard enabled else { return }
        let list = dishes
        let plays = Dictionary(list.map { ($0.id, playSeconds($0)) }, uniquingKeysWith: { a, _ in a })
        let results = await run { e -> (prefs: Bool, downloads: [(String, String, Double)]) in
            var prefs = false
            var downloads: [(String, String, Double)] = []
            for d in list {
                if e.halted { break }
                if !running.contains(d.dataPathApp) {
                    if case .downloaded(let dev, let at) = e.reconcile(d, allowDownload: true, playSeconds: plays[d.id] ?? nil) {
                        downloads.append((d.id, dev, at))
                    }
                    e.syncBackups(d)
                }
                if e.syncPrefs(d) { prefs = true }
            }
            return (prefs, downloads)
        }
        guard let results else { NSLog("[Igloo] 전체 동기화 못 함 · \(statusText)"); return }
        for (id, dev, at) in results.downloads { pendingToasts[id] = (dev, at) }
        if results.prefs { DishPrefsStore.shared.reloadFromDisk() }
        NSLog("[Igloo] 전체 동기화 끝 (\(list.count)개 게임) · \(statusText)")
    }

    func resolve(_ c: IglooConflict, keepLocal: Bool) async {
        let play = playSeconds(c.dish)
        let out = await run { e in e.resolve(c.dish, keepLocal: keepLocal, playSeconds: play) }
        if case .downloaded(let dev, let at)? = out { pendingToasts[c.dish.id] = (dev, at) }
    }

    /// 게임 화면이 뜰 때 한 번: "iPad 의 저장 데이터를 불러왔어요(3분 전)"
    func takeToast(_ dishID: String) -> String? {
        guard let t = pendingToasts.removeValue(forKey: dishID) else { return nil }
        let rel = Self.relative(Date(timeIntervalSince1970: t.savedAt / 1000))
        return "\(backend.label) 에서 \(t.device) 의 저장 데이터를 불러왔어요(\(rel))"
    }

    // MARK: 화면 문구

    func lastSynced(_ dish: Dish) -> Date? { state.saves[dish.dataPathApp]?.syncedAt }

    var statusText: String {
        if !enabled { return "꺼져 있어요" }
        switch availability {
        case .checking: return connecting ? "연결하는 중…" : "확인 중…"
        case .noAccount:
            if backend == .icloud { return "iCloud 에 로그인돼 있지 않아요" }
            return drive.lostConnection ? "Google Drive 연결이 끊겼어요 · 다시 연결해 주세요" : "Google Drive 를 연결해 주세요"
        case .unavailable: return backend == .icloud ? "iCloud 를 쓸 수 없어요" : "Google Drive 는 준비 중이에요"
        case .offline: return "오프라인 · 다음에 다시 맞춰요"
        case .ready:
            if quotaFull { return backend == .icloud ? "iCloud 저장 공간이 부족해요" : "Google Drive 공간이 부족해요" }
            if syncing { return "동기화 중…" }
            let n = state.saves.values.filter { $0.syncedSavedAt != nil }.count
            guard let last = state.lastSync else { return "아직 동기화하지 않았어요" }
            return "마지막 동기화 \(Self.relative(last)) · \(n)개 게임"
        }
    }

    /// 저장 데이터 삭제 문구 등에 쓰는 "이 기기와 iCloud" / "이 기기"
    var placesText: String { enabled ? "이 기기와 \(backend.label)" : "이 기기" }

    static func relative(_ d: Date) -> String {
        if abs(d.timeIntervalSinceNow) < 60 { return "방금" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR"); f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}

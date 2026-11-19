import Foundation
import ZIPFoundation

/// 얼음 조각: 세이브 파일 하나. 설정의 세이브 파일 화면(`Kitchen/SaveFilesView.swift`)이 쓴다.
///
/// - 파일로 저장하는 게임(RPG Maker XP·VX·VX Ace·MV·MZ, 새 모양 Electron 의 `userData/`)은 `IceTray.saveFiles` 가 고른 파일 하나하나.
/// - localStorage 로 저장하는 게임(레조넌스 등)은 save.json 한 줄 (PC 의 "백업 파일 내보내기" 모양).
///
/// 바꾸기·지우기는 게임이 꺼져 있을 때만 한다(`SaveDoor`). 하기 전에 지금 저장 데이터를 백업하고(`Freezer.freeze`),
/// 한 뒤에는 `IceTray.commit` 으로 save.json 묶음과 표식을 바로 맞춘 다음 클라우드에 올린다.
struct IceCube: Identifiable, Hashable {
    /// 저장 폴더 기준 상대 이름 (`Game.rxdata`, `file1.rpgsave`, `userData/save.dat`, `save.json`)
    let name: String
    let url: URL
    let bytes: Int64
    let modified: Date?
    /// localStorage 게임의 save.json 줄
    let isSnapshot: Bool
    var id: String { name }

    /// 파일 이름 (`userData/` 는 떼고)
    var fileName: String {
        let u = RedBeanSchemeHandler.userDataFolder + "/"
        return name.hasPrefix(u) ? String(name.dropFirst(u.count)) : name
    }

    /// 화면에 보일 이름 (`userData/` 는 떼고)
    var displayName: String {
        if isSnapshot { return "저장 데이터 (save.json)" }
        if let label = SaveCard.slotLabel(name) { return label }
        let lower = (name as NSString).deletingPathExtension.lowercased()
        if lower == "global" { return "저장 목록 정보 (\(name))" }
        if lower == "config" { return "게임 설정 (\(name))" }
        let u = RedBeanSchemeHandler.userDataFolder + "/"
        return name.hasPrefix(u) ? String(name.dropFirst(u.count)) : name
    }
}

/// 세이브 파일 화면의 일. 게임 파일·엔진은 건드리지 않는다
enum IceCubes {
    /// 넣을 수 있는 세이브 파일 크기 상한 (save.json 묶음 상한과 같다)
    static let maxBytes = Freezer.maxBytes

    /// 파일 하나하나로 다루는 게임인가 (아니면 save.json 한 줄)
    static func isFileGame(_ dish: Dish) -> Bool {
        !dish.isRemote && (dish.recipe == .mkxp || dish.recipe == .rpgMakerMV || dish.isRedBean)
    }

    // MARK: 목록

    static func list(_ dish: Dish) -> [IceCube] {
        guard !dish.isRemote else { return [] }
        let fz = Freezer(dish: dish)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        if isFileGame(dish) {
            return IceTray.saveFiles(fz).compactMap { u in
                guard let rel = IceTray.relativeName(u, fz: fz) else { return nil }
                let v = try? u.resourceValues(forKeys: Set(keys))
                return IceCube(name: rel, url: u, bytes: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate, isSnapshot: false)
            }
        }
        let u = fz.localStorageFile
        guard FileManager.default.fileExists(atPath: u.path), fz.loadLocalStorage() != nil else { return [] }
        let v = try? u.resourceValues(forKeys: Set(keys))
        return [IceCube(name: u.lastPathComponent, url: u, bytes: Int64(v?.fileSize ?? 0), modified: fz.lastSaved ?? v?.contentModificationDate, isSnapshot: true)]
    }

    // MARK: 바꾸기·지우기

    enum Failure: LocalizedError {
        case running, badName, tooLarge, notForGame, writeFailed, empty
        var errorDescription: String? {
            switch self {
            case .running: return "게임이 켜져 있어요. 게임을 끝낸 뒤에 해 주세요."
            case .badName: return "넣을 수 없는 파일 이름이에요."
            case .tooLarge: return "파일이 너무 커요. 16MB 이하 세이브 파일만 넣을 수 있어요."
            case .notForGame: return "이 게임의 세이브 파일이 아니에요."
            case .writeFailed: return "파일을 쓰지 못했어요. 저장 공간을 확인해 주세요."
            case .empty: return "파일이 비어 있어요."
            }
        }
    }

    /// 세이브 파일 하나를 넣거나 바꾼다. `name` 은 저장 폴더 기준 상대 이름. 바꾸기 전 지금 저장 데이터를 백업한다.
    @MainActor
    static func put(_ data: Data, as name: String, into dish: Dish) throws {
        guard !SaveDoor.shared.isRunning(dish) else { throw Failure.running }
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        let fz = Freezer(dish: dish)
        if !isFileGame(dish) {
            // localStorage 게임: PC 백업 JSON 검증 → 백업 → save.json 교체 (Freezer.replace 가 다 한다)
            try fz.replace(with: data)
            afterChange(dish)
            return
        }
        guard let dest = destination(name, fz: fz) else { throw Failure.badName }
        // 먼저 두 쪽을 맞춘다 (내려받아 둔 save.json 이 아직 파일로 안 풀렸으면 지금 푼다) → 그 상태를 백업
        IceTray.sync(dish, allowUnpack: true)
        fz.freeze()
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: dest, options: .atomic) } catch { throw Failure.writeFailed }
        guard IceTray.commit(dish) else { throw Failure.writeFailed }
        afterChange(dish)
        NSLog("[IceCube] \(dish.dataPathApp): 세이브 파일 넣음 (\(data.count)바이트)")
    }

    /// 세이브 파일 하나를 지운다. 지우기 전 지금 저장 데이터를 백업한다(백업에서 되돌릴 수 있음)
    @MainActor
    static func remove(_ cube: IceCube, from dish: Dish) throws {
        guard !SaveDoor.shared.isRunning(dish) else { throw Failure.running }
        guard isFileGame(dish), !cube.isSnapshot else { throw Failure.notForGame }
        let fz = Freezer(dish: dish)
        guard let dest = destination(cube.name, fz: fz) else { throw Failure.badName }
        IceTray.sync(dish, allowUnpack: true)
        fz.freeze()
        guard (try? dest.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw Failure.badName }
        do { try FileManager.default.removeItem(at: dest) } catch { throw Failure.writeFailed }
        guard IceTray.commit(dish, gone: [cube.name]) else { throw Failure.writeFailed }
        SaveCard.forget(dish, cube.name)
        afterChange(dish)
        NSLog("[IceCube] \(dish.dataPathApp): 세이브 파일 지움")
    }

    /// 켜져 있는 게임 화면이 예전 스냅샷을 다시 쓰지 않게 표시하고, 클라우드 동기화가 켜져 있으면 올린다
    @MainActor
    private static func afterChange(_ dish: Dish) {
        Freezer.markReplaced(dish.dataPathApp)
        Igloo.shared.afterPlay(dish, stillRunning: false)
    }

    /// 상대 이름 → 저장 폴더 안 경로. IceTray 가 묶는 이름 규칙(확장자·숨김·`..`·길이)을 지나야 한다
    static func destination(_ name: String, fz: Freezer) -> URL? {
        if fz.dish.isRedBean {
            guard IceTray.safeUserDataPath(name) else { return nil }
        } else {
            guard IceTray.safeName(name, recipe: fz.dish.recipe), name != fz.localStorageFile.lastPathComponent else { return nil }
            if fz.dish.recipe == .rpgMakerMV,
               name.range(of: GreenTeaSchemeHandler.saveNamePattern, options: .regularExpression) == nil { return nil }
        }
        let dest = name.split(separator: "/").reduce(fz.directory) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        guard dest.path.hasPrefix(fz.directory.standardizedFileURL.path + "/") else { return nil }
        return dest
    }

    // MARK: 내보내기 (PC 에 그대로 넣는 원래 모양)

    /// 내보낼 파일 하나: 원래 이름 그대로 임시 폴더에 복사. localStorage 게임은 PC 백업 JSON 모양 ({format, version, data})
    static func exportFile(_ cube: IceCube, dish: Dish) -> URL? {
        let dir = freshExportDir()
        if cube.isSnapshot {
            let fz = Freezer(dish: dish)
            guard let snap = fz.loadLocalStorage(),
                  let data = try? JSONSerialization.data(withJSONObject: ["format": Freezer.format, "version": 1, "data": snap.entries] as [String: Any],
                                                         options: [.sortedKeys]) else { return nil }
            let u = dir.appendingPathComponent(safeExportName(fz.exportFileName))
            return (try? data.write(to: u, options: .atomic)) != nil ? u : nil
        }
        // 이름은 NFC 로: iOS 파일 이름은 한글이 풀어쓴 모양(NFD)일 수 있는데, Windows 게임은 모아쓴 이름으로 찾는다
        let u = dir.appendingPathComponent(URL(fileURLWithPath: cube.name).lastPathComponent.precomposedStringWithCanonicalMapping)
        return (try? FileManager.default.copyItem(at: cube.url, to: u)) != nil ? u : nil
    }

    /// 여러 개면 zip 하나로. 안의 경로는 PC 폴더에 그대로 풀면 되는 모양 (`userData/` 는 뗀다).
    /// 이름에 한글 등 ASCII 밖 글자가 있으면 하나여도 zip 으로: 파일 시스템이 이름을 풀어쓴 모양(NFD)으로 바꿔
    /// Windows 게임이 못 찾을 수 있는데, zip 안 이름은 모아쓴 모양(NFC)·UTF-8 표시로 그대로 간다
    static func exportAll(_ cubes: [IceCube], dish: Dish) -> URL? {
        if cubes.count == 1, let c = cubes.first, c.isSnapshot || c.displayName.allSatisfy(\.isASCII) { return exportFile(c, dish: dish) }
        guard !cubes.isEmpty else { return nil }
        let base = cubes.count == 1 ? (cubes[0].displayName as NSString).deletingPathExtension : "\(dish.title)-세이브"
        let zip = freshExportDir().appendingPathComponent(safeExportName(URL(fileURLWithPath: base).lastPathComponent + ".zip"))
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            for c in cubes where !c.isSnapshot {
                try archive.addEntry(with: c.displayName.precomposedStringWithCanonicalMapping, fileURL: c.url, compressionMethod: .deflate)
            }
            return zip
        } catch {
            NSLog("[IceCube] zip 만들기 실패: \(error)")
            return nil
        }
    }

    /// 내보낸 파일을 어디에 넣으면 되는지 (한 줄)
    static func pcHint(_ dish: Dish) -> String {
        if !isFileGame(dish) { return "PC에서는 게임의 \"백업 파일 가져오기\"로 넣으면 돼요." }
        if dish.recipe == .rpgMakerMV {
            return dish.mvmz?.engine == .mz
                ? "PC에서는 게임 폴더의 save 폴더에 넣으면 돼요."
                : "PC에서는 게임 폴더의 www\\save 폴더에 넣으면 돼요."
        }
        if dish.isRedBean { return "PC에서는 %APPDATA%\\\(dish.dataPathApp) 폴더에 넣으면 돼요." }
        return "PC에서는 %APPDATA%\\\(dish.dataPathApp) 폴더(Essentials 게임) 또는 Game.exe 가 있는 게임 폴더에 넣으면 돼요."
    }

    private static func freshExportDir() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SaveExport", isDirectory: true)
        try? FileManager.default.removeItem(at: root)   // 지난번 내보낸 사본은 지운다
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func safeExportName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = String(s.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
        return cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }

    // MARK: PC 세이브 넣기 — 맞는 게임·슬롯 제안

    struct Suggestion: Identifiable, Hashable {
        let dish: Dish
        /// 넣을 이름 (저장 폴더 기준). localStorage 게임은 save.json
        let slot: String
        /// 같은 이름 파일이 이미 있음(바꾸기)
        let replaces: Bool
        var id: String { dish.id + "|" + slot }
    }

    enum Rejection: LocalizedError {
        case hidden, badName, symlink, tooLarge, unknown, unreadable
        var errorDescription: String? {
            switch self {
            case .hidden: return "숨김 파일은 넣을 수 없어요."
            case .badName: return "파일 이름에 쓸 수 없는 문자가 있어요."
            case .symlink: return "바로가기(링크) 파일은 넣을 수 없어요. 원래 파일을 골라 주세요."
            case .tooLarge: return "파일이 너무 커요. 16MB 이하 세이브 파일만 넣을 수 있어요."
            case .unknown: return "어느 게임의 세이브 파일인지 알 수 없어요. Game.rxdata·file1.rpgsave 같은 세이브 파일이나 PC 백업 파일(.json)을 골라 주세요."
            case .unreadable: return "파일을 읽을 수 없어요."
            }
        }
    }

    /// 고른 파일을 검사하고 읽는다: 숨김·경로 문자·심볼릭 링크·크기
    static func readPicked(_ url: URL) throws -> (name: String, data: Data) {
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { throw Rejection.hidden }
        guard !name.isEmpty, name.utf8.count <= 200, !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.contains("\u{0}"), name != "..", !name.contains("..") else { throw Rejection.badName }
        let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        if v?.isSymbolicLink == true { throw Rejection.symlink }
        guard v?.isRegularFile != false else { throw Rejection.unreadable }
        if let s = v?.fileSize, s > maxBytes { throw Rejection.tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Rejection.unreadable }
        guard data.count <= maxBytes else { throw Rejection.tooLarge }
        return (name, data)
    }

    /// 내려받은 사본에 붙는 " (1)"·"-1" 같은 꼬리를 뗀 이름 (`file1 (2).rpgsave` → `file1.rpgsave`)
    static func cleanedName(_ name: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension, base = ns.deletingPathExtension
        let trimmed = base.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        let b = trimmed.isEmpty ? base : trimmed
        return ext.isEmpty ? b : b + "." + ext
    }

    /// 파일 이름·확장자·내용으로 맞는 게임과 슬롯을 고른다. 이미 같은 이름 세이브가 있는 게임 → 최근에 저장한 게임 순.
    /// `only` 가 있으면 그 게임만 본다(게임별 화면에서 넣을 때)
    static func suggest(name raw: String, data: Data, dishes: [Dish], only: Dish? = nil) -> [Suggestion] {
        let name = cleanedName(raw)
        let ext = (name as NSString).pathExtension.lowercased()
        let pool = (only.map { [$0] } ?? dishes).filter { !$0.isRemote }
        var out: [(Suggestion, rank: Int, saved: Date)] = []
        for d in pool {
            let fz = Freezer(dish: d)
            let saved = fz.lastSaved ?? .distantPast
            if !isFileGame(d) {
                // localStorage 게임: PC 백업 JSON 이 이 게임의 키 규칙을 지날 때만
                guard ext == "json", (try? fz.validate(data)) != nil else { continue }
                out.append((Suggestion(dish: d, slot: fz.localStorageFile.lastPathComponent, replaces: fz.loadLocalStorage() != nil), 1, saved))
                continue
            }
            var slot = name
            if d.isRedBean {
                // Electron userData: 같은 이름 파일이 있는 자리, 없으면 userData/ 바로 아래
                let existing = list(d).first { URL(fileURLWithPath: $0.name).lastPathComponent == name }
                slot = existing?.name ?? RedBeanSchemeHandler.userDataFolder + "/" + name
                guard destination(slot, fz: fz) != nil else { continue }
                let rank = existing != nil ? 0 : (only != nil ? 2 : -1)
                if rank < 0 { continue }   // 이름만으로는 Electron 게임인지 알 수 없어 전체 제안에서는 같은 이름이 있을 때만
                out.append((Suggestion(dish: d, slot: slot, replaces: existing != nil), rank, saved))
                continue
            }
            guard destination(slot, fz: fz) != nil else { continue }
            let fits: Bool
            switch ext {
            case "rxdata": fits = d.recipe == .mkxp && (d.rgss ?? .xp) == .xp
            case "rvdata": fits = d.recipe == .mkxp && d.rgss == .vx
            case "rvdata2": fits = d.recipe == .mkxp && d.rgss == .vxAce
            case "rpgsave": fits = d.recipe == .rpgMakerMV && d.mvmz?.engine != .mz
            case "rmmzsave": fits = d.recipe == .rpgMakerMV && d.mvmz?.engine == .mz
            default: fits = only != nil   // .sav·.dat 등은 게임별 화면에서 넣을 때만
            }
            guard fits else { continue }
            let exists = FileManager.default.fileExists(atPath: fz.directory.appendingPathComponent(slot).path)
            out.append((Suggestion(dish: d, slot: slot, replaces: exists), exists ? 0 : 1, saved))
        }
        return out.sorted { a, b in a.rank != b.rank ? a.rank < b.rank : a.saved > b.saved }.map(\.0)
    }

    /// 그 게임에서 고를 수 있는 다른 슬롯 (같은 확장자의 지금 세이브 파일들). 제안한 슬롯이 맨 앞
    static func slots(for s: Suggestion) -> [String] {
        guard isFileGame(s.dish) else { return [s.slot] }
        let ext = (s.slot as NSString).pathExtension.lowercased()
        let others = list(s.dish).map(\.name).filter { ($0 as NSString).pathExtension.lowercased() == ext && $0 != s.slot }
        return [s.slot] + others
    }
}

/// 지금 켜져 있는 게임(저장 폴더 이름). 게임 목록(`MenuBoardView`)이 켜고 끌 때 알려 준다.
/// 홈으로 나가 멈춰 둔 게임도 켜져 있는 것으로 본다 — 엔진이 파일을 열고 있을 수 있어 세이브 파일을 바꾸지 않는다.
@MainActor
final class SaveDoor: ObservableObject {
    static let shared = SaveDoor()
    @Published var runningFolder: String?

    func isRunning(_ dish: Dish) -> Bool {
        runningFolder == dish.dataPathApp
            || BrassBowlEngine.shared.runningDishID.map { id in id == dish.id } == true
    }
}

// MARK: 종류와 보여 줄 이름 (세이브 파일 화면의 세 칸)

extension IceCubes {
    /// 세이브 파일 화면에서 어느 칸에 놓을지
    enum Shelf: CaseIterable {
        /// 게임 안 "저장"이 만든 슬롯 (MV·MZ fileN, XP SaveN, Essentials Game.rxdata, localStorage 게임의 save.json)
        case game
        /// 빙수가 만든 저장 (자동 저장·빠른 저장·상태 저장 칸, 빌드 49)
        case bingsu
        /// 세이브가 아닌 게임 파일 (MV·MZ global·config, .bak 등). 바꾸거나 지우면 게임 저장 목록·옵션이 어긋날 수 있다
        case other
    }

    /// 확장자를 뗀 소문자 이름 (`File1.rpgsave` → `file1`)
    private static func base(_ c: IceCube) -> String {
        (URL(fileURLWithPath: c.name).lastPathComponent as NSString).deletingPathExtension.lowercased()
    }

    /// `prefix` 뒤가 숫자뿐이면 그 숫자 (`file12` → 12)
    private static func number(_ s: String, after prefix: String) -> Int? {
        guard s.hasPrefix(prefix) else { return nil }
        let rest = s.dropFirst(prefix.count)
        return rest.isEmpty || !rest.allSatisfy(\.isASCII) ? nil : Int(rest)
    }

    static func shelf(_ c: IceCube, dish: Dish) -> Shelf {
        if c.isSnapshot || dish.isRedBean { return .game }   // Electron userData 는 이름 규칙이 게임마다 달라 한 칸으로
        let b = base(c)
        if b.hasPrefix("bingsu-") { return .bingsu }
        let ext = (c.name as NSString).pathExtension.lowercased()
        switch dish.recipe {
        case .rpgMakerMV:
            return number(b, after: "file") != nil ? .game : .other
        case .mkxp:
            return ["rxdata", "rvdata", "rvdata2"].contains(ext) ? .game : .other
        default:
            return .game
        }
    }

    /// 파일 이름 대신 크게 보여 줄 이름. 모르는 모양이면 nil (파일 이름 그대로)
    static func label(_ c: IceCube, dish: Dish) -> String? {
        if c.isSnapshot || dish.isRedBean { return nil }
        // 세이브 칸 이름은 세이브 카드와 같은 규칙 하나로 (자동·빠른·상태 저장, fileN, SaveN, Game, Essentials 칸 이름)
        if let l = SaveCard.slotLabel(c.name) { return l }
        let b = base(c)
        if b == "global" { return "저장 목록 정보" }
        if b == "config" { return "게임 옵션" }
        return nil
    }

    /// 칸 안 순서: 숫자를 숫자로 (`file2` 가 `file10` 앞)
    static func sorted(_ cubes: [IceCube]) -> [IceCube] {
        cubes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

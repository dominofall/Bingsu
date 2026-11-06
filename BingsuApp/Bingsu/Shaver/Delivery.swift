import Foundation
import Combine

/// 게임 가져오기 파이프라인.
/// zip/폴더 → 임시 폴더에 압축 해제 → (app.asar 풀기) → 게임 확인 → Application Support/Games/<id>/ 등록.
/// 같은 게임(게임 이름·dataPathApp 일치)이 이미 있으면 덮어쓰기 전에 멈추고 업데이트 확인 화면을 띄운다 (7.5).
/// 기존 게임 폴더는 사용자가 고른 뒤 이름 바꾸기 한 번으로 교체하므로, 중간에 취소해도 망가지지 않는다.
@MainActor
final class Delivery: ObservableObject {
    enum Stage: Equatable {
        case idle
        case copying            // 선택한 파일을 앱 안으로 복사
        case unzipping(Double)  // 압축 해제
        case unpacking(Double)  // asar 풀기
        case checking           // 게임 확인
        case confirmUpdate(Pending) // 이미 있는 게임: 업데이트 / 따로 추가 / 취소
        case installing         // 게임 파일 바꾸는 중
        case done(Result)
        /// 게임 대신 패드 스킨 zip(`.bingsuskin` 또는 skin.json 이 든 zip)이었다. 스킨 목록에 넣었고, 쓸지는 화면이 묻는다
        case skinDone(SkinShelf.ImportResult)
        /// 게임 대신 RTP(공용 그림·소리 묶음) zip 이었다. RTP 선반에 넣었다 (이름)
        case rtpDone(String)
        case failed(String)
        /// 스킨으로 알아봤지만 검사에서 거절 (주소로 다시 받기 대신 다른 파일 고르기만)
        case skinFailed(String)

        var title: String {
            switch self {
            case .idle: return ""
            case .copying: return "파일 복사 중"
            case .unzipping: return "압축 해제 중"
            case .unpacking: return "게임 파일 꺼내는 중"
            case .checking: return "게임 확인 중"
            case .confirmUpdate: return "이미 있는 게임이에요"
            case .installing: return "게임 파일 바꾸는 중"
            case .done, .skinDone, .rtpDone: return "준비됐어요"
            case .failed, .skinFailed: return "가져오지 못했어요"
            }
        }
        var fraction: Double? {
            switch self {
            case .unzipping(let f): return f * 0.6
            case .unpacking(let f): return 0.6 + f * 0.35
            case .checking: return 0.97
            case .installing: return 0.99
            case .done, .skinDone, .rtpDone: return 1
            default: return nil
            }
        }
        var isBusy: Bool {
            switch self {
            case .idle, .done, .skinDone, .rtpDone, .failed, .skinFailed: return false
            default: return true
            }
        }
    }

    /// 임시 폴더에 풀어 둔, 아직 등록하지 않은 게임
    struct Staged: Sendable {
        let work: URL       // Games/.import-<uuid>/ (끝나면 지움)
        let root: URL       // 게임 루트 (work 안)
        let recipe: Dish.Recipe
        let title: String
        let dataPathApp: String
        let version: String?
        let sourceName: String
        /// RPG Maker 게임(.mkxp)이면 RGSSProbe 결과
        var rgss: RGSSProbe.Result? = nil
        /// RPG Maker MV·MZ 게임(.rpgMakerMV)이면 MVMZProbe 결과
        var mvmz: MVMZProbe.Result? = nil
    }

    /// 1~4단계 결과: 등록할 게임, 또는 바로 넣은 패드 스킨
    enum Prepared: Sendable {
        case game(Staged)
        case skin(SkinShelf.ImportResult)
        case rtp(String)
    }

    /// 업데이트 확인을 기다리는 가져오기
    struct Pending: Equatable {
        let staged: Staged
        let existing: Dish
        let oldVersion: String?
        static func == (a: Pending, b: Pending) -> Bool { a.staged.work == b.staged.work }
    }

    enum InstallMode: Sendable {
        case new
        case update(Dish, backup: Bool, keepOld: Bool)
        case copy
    }

    struct Result: Equatable {
        let dish: Dish
        let version: String?
        let bytes: UInt64
        let updatedExisting: Bool
        var previousVersion: String? = nil
        var backedUp = false
        var keptOld = false
        /// 게임 폴더에 있던 PC 저장 파일(Save01.rvdata2 등)을 저장 데이터 폴더로 옮긴 수
        var movedSaves = 0
    }

    @Published private(set) var stage: Stage = .idle
    /// 백그라운드 파이프라인에서 읽는 취소 플래그 (스레드 안전). 가져오기마다 새로 만들어, 취소된 작업의 늦은 보고가 다음 가져오기를 덮지 않게 한다.
    private var cancelFlag = CancelFlag()

    /// 게임 폴더에 남기는 메타데이터 파일
    static let manifestName = "bingsu.json"
    /// 업데이트 때 "예전 버전 파일 삭제"를 끄면 예전 폴더를 Games/<id>.old 로 남긴다 (게임 목록에는 안 보임)
    static let oldSuffix = ".old"

    /// 취소: 확인 화면이면 풀어 둔 임시 폴더만 지운다. 기존 게임은 그대로.
    func cancel() {
        cancelFlag.set(true)
        if case .confirmUpdate(let p) = stage { Self.discard(p.staged) }
        if case .installing = stage { return } // 이름 바꾸기 몇 번이라 금방 끝난다. 끝까지 둔다.
        stage = .idle
    }

    /// `preferring`: 게임칩 "새 버전으로 업데이트"로 연 경우 그 게임을 먼저 비교한다.
    func start(from source: URL, preferring targetID: String? = nil, removeWindowsBinaries: Bool = true) {
        guard !stage.isBusy else { NSLog("[Delivery] busy — ignored new import"); return }
        let flag = CancelFlag()
        cancelFlag = flag
        stage = .copying
        let scoped = source.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
                Self.removeInboxCopy(source)
            }
            do {
                Self.sweepStaleWork()
                let prepared = try await Self.prepare(source: source, removeWindowsBinaries: removeWindowsBinaries) { stage in
                    Task { @MainActor in if !flag.value { self?.stage = stage } }
                } isCancelled: { flag.value }
                let staged: Staged
                switch prepared {
                case .skin(let r):
                    NSLog("[Delivery] skin \(r.id) installed=\(r.installed) layouts=\(r.layouts?.count ?? 0)")
                    await MainActor.run { if !flag.value { self?.stage = .skinDone(r) } }
                    return
                case .rtp(let name):
                    await MainActor.run { if !flag.value { self?.stage = .rtpDone(name) } }
                    return
                case .game(let s): staged = s
                }
                if flag.value { Self.discard(staged); return }
                if let existing = Self.findExisting(title: staged.title, dataPathApp: staged.dataPathApp, preferring: targetID) {
                    let old = Self.manifestVersion(existing.location)
                    NSLog("[Delivery] existing game \(existing.id): \(old ?? "?") → \(staged.version ?? "?") — waiting for choice")
                    await MainActor.run {
                        if flag.value { Self.discard(staged) } else { self?.stage = .confirmUpdate(Pending(staged: staged, existing: existing, oldVersion: old)) }
                    }
                } else {
                    await self?.install(staged, mode: .new)
                }
            } catch {
                NSLog("[Delivery] failed: \(error.localizedDescription)")
                let stage: Stage = (error as? SkinShelf.Rejection).map { .skinFailed($0.reason) } ?? .failed(error.localizedDescription)
                await MainActor.run { if !flag.value { self?.stage = stage } }
            }
        }
    }

    /// 확인 화면에서 고른 것 실행
    func confirm(_ mode: InstallMode) {
        guard case .confirmUpdate(let p) = stage else { return }
        Task { await install(p.staged, mode: mode, previousVersion: p.oldVersion) }
    }

    private func install(_ staged: Staged, mode: InstallMode, previousVersion: String? = nil) async {
        stage = .installing
        do {
            var result = try await Task.detached(priority: .userInitiated) { try Self.install(staged, mode: mode) }.value
            result.previousVersion = previousVersion
            NSLog("[Delivery] installed \(result.dish.id) update=\(result.updatedExisting) backup=\(result.backedUp) keptOld=\(result.keptOld)")
            stage = .done(result)
        } catch {
            Self.discard(staged)
            NSLog("[Delivery] install failed: \(error.localizedDescription)")
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - 파이프라인 (백그라운드)

    /// 1~4단계: 임시 폴더에 풀고 게임을 확인한다. 기존 게임은 건드리지 않는다.
    nonisolated static func prepare(source: URL, removeWindowsBinaries: Bool,
                                    report: @escaping (Stage) -> Void, isCancelled: @escaping () -> Bool) async throws -> Prepared {
        let fm = FileManager.default
        let gamesDir = MenuBoardStore.gamesDir
        let work = gamesDir.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var ok = false
        defer { if !ok { try? fm.removeItem(at: work) } }

        // 1) 복사 또는 압축 해제
        let staged = work.appendingPathComponent("staged", isDirectory: true)
        var isDir: ObjCBool = false
        // iCloud Drive·다른 파일 제공자의 파일은 아직 기기에 내려오지 않았을 수 있다(iPad 에서 흔함).
        // NSFileCoordinator 로 읽기를 조정하면 내려받기가 끝날 때까지 기다린 뒤 실제 파일 경로를 준다.
        report(.copying)
        let local = try coordinatedLocalCopy(of: source, into: work, isCancelled: isCancelled)
        fm.fileExists(atPath: local.path, isDirectory: &isDir)
        if isDir.boolValue {
            if containsLink(in: local) { throw DeliveryError.linkInFolder }
            if local != staged { try fm.moveItem(at: local, to: staged) }
        } else if SkinShelf.looksLikeSkin(local) {
            // 패드 스킨: 풀기 전에 중앙 디렉터리만 보고 알아본 뒤 스킨 가져오기(자체 검사·SafeUnzip)로 넘긴다. work 는 defer 가 지운다
            do { return .skin(try SkinShelf.importZip(at: local)) }
            catch let r as SkinShelf.Rejection { throw r }
            catch { throw SkinShelf.Rejection(reason: error.localizedDescription) }
        } else {
            report(.unzipping(0))
            try SafeUnzip.unzip(local, to: staged, progress: { report(.unzipping($0)) }, isCancelled: isCancelled)
            try? fm.removeItem(at: local)
        }

        // 2) 게임 루트 찾기: 최상위에 폴더 하나뿐이면 그 안으로
        var root = staged
        while true {
            let items = visibleItems(root)
            if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { root = items[0] } else { break }
        }

        // 3) asar 풀기 (Electron)
        let asar = root.appendingPathComponent("resources/app.asar")
        if fm.fileExists(atPath: asar.path) {
            report(.unpacking(0))
            let archive = try AsarArchive(url: asar)
            let need = archive.totalBytes
            let free = SafeUnzip.freeSpace(at: gamesDir)
            if free > 0, need + 200 * 1024 * 1024 > free { throw SafeUnzip.UnzipError.notEnoughSpace(needed: need, free: free) }
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try archive.extract(to: unpacked, progress: { report(.unpacking($0)) }, isCancelled: isCancelled)
            // 원본 안내문·크레딧은 보존
            for name in ["먼저 읽어주세요.txt", "패치노트.txt", "CREDITS.txt", "LICENSE"] {
                let f = root.appendingPathComponent(name)
                if fm.fileExists(atPath: f.path) { try? fm.copyItem(at: f, to: unpacked.appendingPathComponent(name)) }
            }
            try fm.removeItem(at: root)
            root = unpacked
        }

        // 3-1) package.nw 풀기 (NW.js 게임을 zip 하나로 묶은 것. MV·MZ 게임이 그 안에 있다)
        let nw = root.appendingPathComponent("package.nw")
        if (try? nw.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, MVMZProbe.findRoot(root) == nil {
            report(.unpacking(0))
            let unpacked = work.appendingPathComponent("nw", isDirectory: true)
            try SafeUnzip.unzip(nw, to: unpacked, progress: { report(.unpacking($0)) }, isCancelled: isCancelled)
            // PC 에서 하던 저장(게임 폴더의 save/)은 새 루트로 옮겨 아래에서 저장 데이터 폴더로 보낸다
            for rel in ["save", "www/save"] {
                let src = root.appendingPathComponent(rel)
                let dst = unpacked.appendingPathComponent("save")
                if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: src, to: dst) }
            }
            try fm.removeItem(at: root)
            root = unpacked
            NSLog("[Delivery] package.nw 풀어서 게임 루트로 씀")
        }

        // 4) 게임 확인
        report(.checking)
        let recipe = RecipeDetector.detect(folder: root)
        if recipe == .unknown, RTPShelf.looksLikeRTP(root) {
            let name = RTPShelf.guessName(root, sourceName: source.lastPathComponent)
            try RTPShelf.install(root, name: name)
            return .rtp(name)
        }
        guard recipe != .unknown else {
            if MVMZProbe.looksPackedInExe(root) { throw DeliveryError.packedInExe }
            throw DeliveryError.unsupported(found: visibleItems(root).map(\.lastPathComponent).sorted())
        }
        let desc = RecipeDetector.describe(folder: root, recipe: recipe)
        let version = Self.readVersion(folder: root, recipe: recipe)
        // RGSS 판·RTP 는 exe·dll 을 지우기 전에 본다 (ini 의 Library= 는 지워진 dll 이름이라 상관없지만 순서를 지킨다)
        let rgss = recipe == .mkxp ? RGSSProbe.probe(folder: root) : nil
        let mvmz = recipe == .rpgMakerMV ? MVMZProbe.probe(folder: root) : nil
        if let m = mvmz {
            NSLog("[Delivery] recipe=rpgMakerMV engine=\(m.engine.rawValue) root=\(m.root.isEmpty ? "." : m.root) dataPathApp=\(m.dataPathApp) encrypted=\(m.encryptedImages ? "img" : "-")/\(m.encryptedAudio ? "audio" : "-")")
        }
        if removeWindowsBinaries { Self.pruneWindowsBinaries(in: root, recipe: recipe) }
        ok = true
        return .game(Staged(work: work, root: root, recipe: recipe, title: desc.title, dataPathApp: desc.dataPathApp,
                            version: version, sourceName: source.lastPathComponent, rgss: rgss, mvmz: mvmz))
    }

    /// 5단계: 등록. 업데이트는 기존 폴더를 옆으로 옮긴 뒤 새 폴더를 그 자리로 옮긴다 (같은 볼륨이라 이름 바꾸기 = 원자적).
    nonisolated static func install(_ s: Staged, mode: InstallMode) throws -> Result {
        let fm = FileManager.default
        let gamesDir = MenuBoardStore.gamesDir
        defer { try? fm.removeItem(at: s.work) }

        var title = s.title
        let id: String
        switch mode {
        case .new:
            id = uniqueID(slug(s.dataPathApp.isEmpty ? s.title : s.dataPathApp))
        case .copy:
            id = uniqueID(slug(s.dataPathApp.isEmpty ? s.title : s.dataPathApp), forceSuffix: true)
            if let n = id.split(separator: "-").last.flatMap({ Int($0) }) { title = "\(s.title) (\(n))" }
        case .update(let dish, _, _):
            id = dish.id
        }

        var manifest: [String: Any] = ["title": title, "dataPathApp": s.dataPathApp, "recipe": s.recipe.rawValue,
                                       "version": s.version ?? "", "importedAt": ISO8601DateFormatter().string(from: Date()),
                                       "sourceName": s.sourceName]
        if let r = s.rgss {
            manifest["rgss"] = (r.version ?? .xp).rawValue
            if let rtp = r.rtp { manifest["rtp"] = rtp }
            manifest["needsRTP"] = r.needsRTP
        }
        if let m = s.mvmz { manifest["mvmz"] = m.info.manifest }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: s.root.appendingPathComponent(manifestName))

        let final = gamesDir.appendingPathComponent(id, isDirectory: true)
        var backedUp = false, keptOld = false
        if case .update(let dish, let backup, let keepOld) = mode {
            // 게임 폴더 밖은 절대 건드리지 않는다
            guard dish.location.standardizedFileURL.deletingLastPathComponent() == gamesDir.standardizedFileURL else {
                throw DeliveryError.cannotReplace
            }
            if backup { backedUp = Freezer(dish: dish).freeze() != nil }
            let aside = gamesDir.appendingPathComponent(".replacing-\(id)-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: final, to: aside)
            do {
                try fm.moveItem(at: s.root, to: final)
            } catch {
                try? fm.moveItem(at: aside, to: final) // 되돌리기
                throw error
            }
            if keepOld {
                let old = gamesDir.appendingPathComponent(id + oldSuffix, isDirectory: true)
                try? fm.removeItem(at: old)
                keptOld = (try? fm.moveItem(at: aside, to: old)) != nil
            }
            if !keptOld { try? fm.removeItem(at: aside) }
        } else {
            try fm.moveItem(at: s.root, to: final)
        }

        let dish = Dish(id: id, title: title, recipe: s.recipe, location: final, dataPathApp: s.dataPathApp,
                        rgss: s.rgss.map { $0.version ?? .xp }, rtp: s.rgss?.rtp, needsRTP: s.rgss?.needsRTP ?? false,
                        mvmz: s.mvmz?.info)
        var result = Result(dish: dish, version: s.version, bytes: folderSize(final), updatedExisting: { if case .update = mode { return true }; return false }())
        result.backedUp = backedUp
        result.keptOld = keptOld
        result.movedSaves = moveGameFolderSaves(dish)
        return result
    }

    /// VX·VX Ace 는 저장 파일을 게임 폴더에 쓴다. 빙수는 엔진 쪽 preload(BrassBowlEngine.savesScript)로 저장 데이터 폴더에 쓰게 하므로,
    /// PC 에서 하던 게임을 저장 파일째 가져오면 그 파일을 저장 데이터 폴더로 옮긴다. 이미 같은 이름이 있으면 덮어쓰지 않고
    /// 저장 데이터 폴더의 `backups/` 에 넣는다(지금 저장이 이긴다). XP 는 건드리지 않는다(Essentials 는 자기 저장 폴더를 쓴다)
    /// MV·MZ 는 PC 에서 `<루트>/save/` 에 저장한다(`file1.rpgsave`·`global.rmmzsave` 등). 빙수는 스킴 핸들러가 그 경로를 저장 데이터 폴더로 돌리므로 같은 규칙으로 옮긴다
    nonisolated static func moveGameFolderSaves(_ dish: Dish) -> Int {
        let fm = FileManager.default
        let folder: URL
        let names: [String]
        if dish.recipe == .rpgMakerMV, dish.mvmz != nil {
            // save 폴더 이름은 대소문자가 다를 수 있다 (Windows 에서 만든 게임)
            let rootItems = (try? fm.contentsOfDirectory(atPath: dish.gameRoot.path)) ?? []
            guard let saveDir = rootItems.first(where: { $0.lowercased() == "save" }) else { return 0 }
            folder = dish.gameRoot.appendingPathComponent(saveDir, isDirectory: true)
            names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter(isMVMZSave)
        } else {
            guard dish.recipe == .mkxp, let v = dish.rgss, v >= .vx else { return 0 }
            folder = dish.location
            names = ((try? fm.contentsOfDirectory(atPath: dish.location.path)) ?? []).filter(isGameFolderSave)
        }
        guard !names.isEmpty else { return 0 }
        let fz = Freezer(dish: dish)
        let saves = fz.directory
        var moved = 0
        for name in names.sorted() {
            let src = folder.appendingPathComponent(name)
            var dest = saves.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                let backups = fz.backupsDirectory
                try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                dest = backups.appendingPathComponent("\(stamp) \(name)")
            }
            if (try? fm.moveItem(at: src, to: dest)) != nil { moved += 1 }
        }
        NSLog("[Delivery] \(dish.id): 게임 폴더의 저장 파일 \(moved)개를 저장 데이터 폴더로 옮김")
        return moved
    }

    /// `Save1.rvdata`·`Save01.rvdata2` 모양 (엔진 preload 가 돌리는 이름과 같은 규칙)
    nonisolated static func isGameFolderSave(_ name: String) -> Bool {
        name.range(of: #"^Save\d*\.(rvdata2|rvdata)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `file1.rpgsave`·`global.rmmzsave` 모양 (스킴 핸들러가 받는 저장 이름에서 임시 `_`·`.bak` 를 뺀 것)
    nonisolated static func isMVMZSave(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_.-]{1,64}\.(rpgsave|rmmzsave)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 폴더 안에 심볼릭 링크가 있는가 (zip 은 SafeUnzip 이 거부한다. 폴더 복사는 링크를 그대로 가져온다)
    nonisolated static func containsLink(in folder: URL) -> Bool {
        let key = URLResourceKey.isSymbolicLinkKey
        if (try? folder.resourceValues(forKeys: [key]).isSymbolicLink) == true { return true }
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [key]) else { return true }
        for case let item as URL in items where (try? item.resourceValues(forKeys: [key]).isSymbolicLink) == true { return true }
        return false
    }

    /// 가져오는 게임이 실제로 쓸 저장 폴더 이름 (Dish 와 같은 규칙으로 고친 뒤 비교한다. APFS 는 유니코드 정규화만 다른 이름을 같게 본다)
    nonisolated static func saveFolderKey(dataPathApp: String, title: String) -> String {
        Dish.folderName(dataPathApp, fallback: slug(dataPathApp.isEmpty ? title : dataPathApp)).precomposedStringWithCanonicalMapping
    }

    /// 같은 게임 찾기: 저장 폴더가 같거나, 저장 폴더 이름이 없으면 제목이 같은 것.
    nonisolated static func findExisting(title: String, dataPathApp: String, preferring targetID: String?) -> Dish? {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: MenuBoardStore.gamesDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasSuffix(oldSuffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let dishes = folders.compactMap { MenuBoardStore.dish(forFolder: $0, id: $0.lastPathComponent) }
        let folder = saveFolderKey(dataPathApp: dataPathApp, title: title)
        let matches = dishes.filter { d in
            d.dataPathApp.precomposedStringWithCanonicalMapping == folder || (dataPathApp.isEmpty && d.title == title)
        }
        if let targetID, let d = matches.first(where: { $0.id == targetID }) { return d }
        let base = slug(dataPathApp.isEmpty ? title : dataPathApp)
        return matches.first(where: { $0.id == base }) ?? matches.first
    }

    nonisolated static func manifestVersion(_ folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = m["version"] as? String, !v.isEmpty else { return nil }
        return v
    }

    /// 이미 쓰는 id 면 -2, -3 … (forceSuffix 면 처음부터 -2)
    nonisolated static func uniqueID(_ base: String, forceSuffix: Bool = false) -> String {
        let fm = FileManager.default
        func taken(_ id: String) -> Bool {
            fm.fileExists(atPath: MenuBoardStore.gamesDir.appendingPathComponent(id).path)
                || MenuBoardStore.deliveryDishes.contains { $0.id == id }
        }
        if !forceSuffix, !taken(base) { return base }
        var n = 2
        while taken("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    nonisolated static func discard(_ s: Staged) {
        try? FileManager.default.removeItem(at: s.work)
    }

    /// 앱이 가져오기 중에 꺼졌으면 임시 폴더가 남는다. 다음 가져오기 때 치운다.
    nonisolated static func sweepStaleWork() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: MenuBoardStore.gamesDir, includingPropertiesForKeys: nil)) ?? [] {
            let n = f.lastPathComponent
            if n.hasPrefix(".import-") || n.hasPrefix(".replacing-") { try? fm.removeItem(at: f) }
        }
    }

    /// 다른 앱이 공유 시트로 보낸 파일은 Documents/Inbox 에 복사돼 온다. 가져온 뒤 지워 용량을 돌려준다.
    nonisolated static func removeInboxCopy(_ source: URL) {
        if isOwnCopy(source) { try? FileManager.default.removeItem(at: source) }
    }

    /// 다른 앱이 넘겨준 Documents/Inbox 사본이나 파일 선택기가 앱 임시 폴더(tmp/…-Inbox)에 만든 복사본인가.
    /// 우리 것이니 다시 복사하지 않고 옮기고, 끝나면 지운다
    nonisolated static func isOwnCopy(_ url: URL) -> Bool {
        let fm = FileManager.default
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = [fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox", isDirectory: true),
                     fm.temporaryDirectory]
        return roots.contains { path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }
    }

    /// 선택한 파일·폴더를 앱 임시 폴더로 가져온다. iCloud 등 아직 내려받지 않은 항목은 조정 읽기가 내려받기를 끝낼 때까지 기다린다.
    /// 폴더는 `staged` 로, 파일은 `source.<확장자>` 로 복사한다. 복사 실패(내려받기 실패 등)는 그대로 던진다.
    nonisolated static func coordinatedLocalCopy(of source: URL, into work: URL, isCancelled: @escaping () -> Bool) throws -> URL {
        let fm = FileManager.default
        if (try? source.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            try? fm.startDownloadingUbiquitousItem(at: source)
        }
        var isDir: ObjCBool = false
        var copyError: Error?
        var coordError: NSError?
        var dest = work.appendingPathComponent("staged", isDirectory: true)
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordError) { real in
            do {
                fm.fileExists(atPath: real.path, isDirectory: &isDir)
                if !isDir.boolValue {
                    dest = work.appendingPathComponent("source." + (real.pathExtension.isEmpty ? "zip" : real.pathExtension))
                }
                if isCancelled() { throw CancellationError() }
                // 앱 내 다운로드로 받은 파일은 복사하지 않고 옮긴다 (큰 zip 이 두 벌 생기지 않게, 끝나면 남지 않게)
                // 선택기가 만든 복사본도 마찬가지로 옮긴다
                if Courier.isDownloadedFile(real) || Self.isOwnCopy(real) { try fm.moveItem(at: real, to: dest) } else { try fm.copyItem(at: real, to: dest) }
            } catch { copyError = error }
        }
        if let coordError { throw DeliveryError.cannotRead(coordError.localizedDescription) }
        if let copyError { throw DeliveryError.cannotRead(copyError.localizedDescription) }
        return dest
    }

    nonisolated static func visibleItems(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set(_ v: Bool) { lock.lock(); flag = v; lock.unlock() }
    }

    enum DeliveryError: LocalizedError {
        case unsupported(found: [String])
        case cannotReplace
        case cannotRead(String)
        case packedInExe
        case linkInFolder
        var errorDescription: String? {
            switch self {
            case .cannotRead(let why): return "파일을 읽어 오지 못했어요 · \(why). iCloud 파일이면 Files 앱에서 먼저 내려받아 주세요"
            case .unsupported(let found):
                guard !found.isEmpty else { return "지원하지 않는 게임이에요 · 압축 안에 파일이 없어요" }
                let shown = found.prefix(6).joined(separator: ", ")
                return "지원하지 않는 게임이에요 · 발견한 파일: \(shown)\(found.count > 6 ? " 외 \(found.count - 6)개" : "")"
            case .cannotReplace: return "기존 게임 폴더를 바꿀 수 없어요."
            case .packedInExe: return "이 게임은 파일이 실행 파일 안에 묶여 있어 열 수 없어요"
            case .linkInFolder: return "폴더 안에 심볼릭 링크가 있어 가져오지 않았어요"
            }
        }
    }

    nonisolated static func readVersion(folder: URL, recipe: Dish.Recipe) -> String? {
        if recipe == .rpgMakerMV { return MVMZProbe.probe(folder: folder)?.packageVersion.flatMap { $0.isEmpty ? nil : $0 } }
        if recipe == .electron,
           let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj["version"] as? String
        }
        return nil
    }

    nonisolated static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "game-\(Int(Date().timeIntervalSince1970))" : trimmed
    }

    /// Windows 실행 파일·런타임은 iOS에서 쓸 일이 없으니 지워 용량을 아낀다. 게임 데이터는 건드리지 않는다.
    nonisolated static func pruneWindowsBinaries(in folder: URL, recipe: Dish.Recipe) {
        let fm = FileManager.default
        let exts: Set<String> = ["exe", "dll", "pak", "bin", "dat"]
        let electronJunk: Set<String> = ["icudtl.dat", "snapshot_blob.bin", "v8_context_snapshot.bin", "resources.pak",
                                         "chrome_100_percent.pak", "chrome_200_percent.pak", "vk_swiftshader_icd.json", "LICENSES.chromium.html"]
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for f in items {
            let name = f.lastPathComponent
            let ext = f.pathExtension.lowercased()
            if ext == "exe" || ext == "dll" { try? fm.removeItem(at: f); continue }
            if recipe == .electron, (electronJunk.contains(name) || name == "locales" || (exts.contains(ext) && name != "soundfont.sf2")) {
                try? fm.removeItem(at: f)
            }
            // MV·MZ: 맨 위의 NW.js 런타임(nw.pak·icudtl.dat·locales 등). 게임 데이터(www/·img/·data/…)는 이름이 달라 건드리지 않는다
            // locales·swiftshader 는 안에 NW.js 파일(.pak·.dll)만 있을 때만 (게임이 번역 폴더를 locales 로 둘 수 있다)
            if recipe == .rpgMakerMV {
                let lower = name.lowercased()
                let runtimeDir = ["locales", "swiftshader", "pnacl"].contains(lower)
                    && ((try? fm.contentsOfDirectory(atPath: f.path)) ?? ["?"]).allSatisfy { ["pak", "dll", "so", "nexe", "json", "info"].contains(($0 as NSString).pathExtension.lowercased()) }
                if runtimeDir || electronJunk.contains(name) || ["nw.pak", "nw_100_percent.pak", "nw_200_percent.pak", "natives_blob.bin", "credits.html"].contains(lower) {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }

    nonisolated static func folderSize(_ url: URL) -> UInt64 {
        var total: UInt64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += UInt64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }
}

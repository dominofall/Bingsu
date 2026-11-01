import Foundation
import Combine
import WebKit

/// 게임 목록: 설치된 게임(Application Support/Games/*)과 기본 웹 게임을 모은다.
@MainActor
final class MenuBoardStore: ObservableObject {
    @Published private(set) var dishes: [Dish] = []
    /// "다음으로 열기"·공유 시트로 받은 파일. 앱이 막 켜지는 중이어도 게임 목록이 뜬 뒤 가져오기를 시작한다.
    @Published var pendingImport: URL?

    /// 게임 파일 폴더. Files 앱에 노출되지 않는 Application Support 에 둔다.
    /// Documents 에 두면 파일 공유로 "나의 iPad › 빙수" 에 수만 개 파일이 노출되고, iPadOS 파일 선택기가 그 폴더를 색인하다 멈춘다
    /// (2026-10-29 실기기 확인: 파일 공유를 끄면 선택기가 정상). 저장 데이터·백업은 Documents (파일 공유는 2026-10-30 꺼서 Files 에는 안 보인다, project.yml).
    static let gamesDir: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Games", isDirectory: true)
        let legacy = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Games", isDirectory: true)
        // 예전 위치(Documents/Games)에서 옮긴다 — 같은 볼륨이라 이름 바꾸기 한 번
        if fm.fileExists(atPath: legacy.path) {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: support, withIntermediateDirectories: true)
                if (try? fm.moveItem(at: legacy, to: dir)) != nil { NSLog("[MenuBoard] Games 폴더를 Application Support 로 옮김") }
            } else {
                // 둘 다 있으면 예전 쪽의 게임을 하나씩 옮기고(겹치면 새 쪽 유지) 빈 폴더를 지운다
                for item in (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? [] {
                    let dest = dir.appendingPathComponent(item.lastPathComponent)
                    if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: item) } else { try? fm.moveItem(at: item, to: dest) }
                }
                try? fm.removeItem(at: legacy)
            }
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 게임 파일은 크고 다시 가져올 수 있으니 iCloud/iTunes 백업에서 제외
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var d = dir; try? d.setResourceValues(values)
        return dir
    }()

    /// 개발 중에는 시뮬레이터가 호스트 파일시스템을 그대로 읽을 수 있어서 Bingsu/Games 를 바로 쓴다.
    static var devGamesDirs: [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["BINGSU_DEV_GAMES"] { dirs.append(URL(fileURLWithPath: env)) }
        #if targetEnvironment(simulator)
        // 저장소의 Games/ — 이 소스 파일 위치(BingsuApp/Bingsu/MenuBoard/)에서 저장소 루트로 올라가 찾는다
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repo.deleteLastPathComponent() }
        dirs.append(repo.appendingPathComponent("Games", isDirectory: true))
        #endif
        return dirs
    }

    /// 기본 제공 웹 게임. 릴리스(TestFlight·심사) 빌드에는 넣지 않는다 — 앱이 특정 팬게임을 내장해 보이지 않게
    /// (2026-10-30 외부 베타 대비 결정). 릴리스에서는 사용자가 "주소로 웹 게임 추가"로 넣고, 조정은 `Dish.knownWeb` 이 호스트로 이어 준다.
    #if DEBUG
    static let deliveryDishes: [Dish] = [
        Dish(id: "pokerogue", title: "포켓로그", recipe: .webURL,
             location: URL(string: "https://pokerogue.net")!, dataPathApp: "pokerogue"),
        // 포켓본크: Three.js 3D 서바이버. 표준 게임패드(스틱 이동·카메라, 십자키 줌)와 터치 UI 둘 다 지원, 진동은 게임이 직접 요청
        Dish(id: "pokebonk", title: "포켓본크", recipe: .webURL,
             location: URL(string: "https://pokebonk.com/?lang=ko")!, dataPathApp: "pokebonk"),
    ]
    #else
    static let deliveryDishes: [Dish] = []
    #endif

    /// 기본 게임 "Bingsu": 빙수가 직접 만든 작은 게임을 번들에 넣어 처음부터 목록이 비지 않게 한다
    /// (2026-10-30 심사 대비 결정). 번들 폴더라 업데이트·삭제는 없다.
    nonisolated static let sampleID = "bingsu-sample"
    static let sampleDish: Dish? = Bundle.main.url(forResource: "SampleGame", withExtension: nil).map {
        Dish(id: sampleID, title: "Bingsu", recipe: .electron, location: $0, dataPathApp: sampleID)
    }
    nonisolated static func isBuiltIn(_ dish: Dish) -> Bool { dish.id == sampleID }

    init() { refresh(); Self.emptyLeftoverTrash() }

    func refresh() {
        var found: [Dish] = []
        let fm = FileManager.default
        for base in [Self.gamesDir] + Self.devGamesDirs {
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for folder in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // 숨김 폴더(가져오기 임시 폴더)와 업데이트 때 남긴 예전 버전(<id>.old)은 목록에 안 보인다
                guard !folder.lastPathComponent.hasPrefix("."), !folder.lastPathComponent.hasSuffix(Delivery.oldSuffix),
                      (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let id = folder.lastPathComponent
                guard id != Self.sampleID, !found.contains(where: { $0.id == id }) else { continue }
                if let dish = Self.dish(forFolder: folder, id: id) { found.append(dish) }
            }
        }
        dishes = found + [Self.sampleDish].compactMap { $0 } + Self.deliveryDishes + WebGames.load().compactMap(\.dish)
    }

    /// 주소로 웹 게임 추가 (검증은 WebGames.makeEntry)
    func addWebGame(title: String, url: String) throws {
        let entry = try WebGames.makeEntry(title: title, url: url, existing: dishes)
        var list = WebGames.load()
        list.append(entry)
        WebGames.save(list)
        refresh()
    }

    /// 사용자가 추가한 웹 게임인가 (기본 제공 포켓로그·포켓본크는 아님)
    static func isCustomWeb(_ dish: Dish) -> Bool { dish.isRemote && dish.id.hasPrefix(WebGameEntry.idPrefix) }

    /// 목록에서 빼기. 그 게임의 웹 저장소(쿠키·localStorage)도 같이 지운다.
    func removeWebGame(_ dish: Dish) {
        guard Self.isCustomWeb(dish) else { return }
        WebGames.save(WebGames.load().filter { $0.id != dish.id })
        let id = GlassBowl.storeID(for: dish)
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        refresh()
    }

    /// 가져오기 때 남긴 bingsu.json 이 있으면 그걸 쓰고, 없으면 폴더를 보고 판별한다.
    nonisolated static func dish(forFolder folder: URL, id: String) -> Dish? {
        if let data = try? Data(contentsOf: folder.appendingPathComponent(Delivery.manifestName)),
           let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = m["title"] as? String, let raw = m["recipe"] as? String, let recipe = Dish.Recipe(rawValue: raw) {
            var dataPath = (m["dataPathApp"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title
            // RPG Maker XP: 저장 폴더는 언제나 게임의 mkxp.json dataPathApp (예전 가져오기가 CRLF 를 못 읽어 Game.ini 제목으로 적었을 수 있음)
            if recipe == .mkxp { dataPath = RecipeDetector.describe(folder: folder, recipe: .mkxp).dataPathApp }
            var dish = Dish(id: id, title: title, recipe: recipe, location: folder, dataPathApp: dataPath)
            if recipe == .mkxp {
                // 빌드 26 전 가져오기에는 rgss 가 없다 → 폴더를 다시 본다
                if let n = m["rgss"] as? Int, let v = RGSSVersion(rawValue: n) {
                    dish.rgss = v
                    dish.rtp = (m["rtp"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    dish.needsRTP = m["needsRTP"] as? Bool ?? false
                } else {
                    Self.applyProbe(&dish)
                }
            }
            return dish
        }
        let recipe = RecipeDetector.detect(folder: folder)
        guard recipe != .unknown else { return nil }
        let d = RecipeDetector.describe(folder: folder, recipe: recipe)
        var dish = Dish(id: id, title: d.title, recipe: recipe, location: folder, dataPathApp: d.dataPathApp)
        if recipe == .mkxp { Self.applyProbe(&dish) }
        return dish
    }

    nonisolated static func applyProbe(_ dish: inout Dish) {
        let p = RGSSProbe.probe(folder: dish.location)
        dish.rgss = p.version ?? .xp
        dish.rtp = p.rtp
        dish.needsRTP = p.needsRTP
    }

    /// 게임 파일만 지운다. 저장 데이터(Saves/)는 남긴다.
    func remove(_ dish: Dish) {
        // /var 와 /private/var 처럼 같은 곳이 다른 경로로 보일 수 있어 심볼릭 링크를 풀어 비교한다
        let games = Self.gamesDir.resolvingSymlinksInPath().standardizedFileURL.path
        guard !dish.isRemote, dish.location.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(games + "/") else { return }
        // 게임 폴더는 파일이 수만 개라 바로 지우면 화면이 몇 초 멈춘다 → 숨김 이름으로 바꿔(즉시) 목록에서 빼고, 실제 지우기는 뒤에서
        let base = dish.location.deletingLastPathComponent()
        for folder in [dish.location, base.appendingPathComponent(dish.id + Delivery.oldSuffix, isDirectory: true)] {
            let trash = base.appendingPathComponent(Self.trashPrefix + UUID().uuidString, isDirectory: true)
            if (try? FileManager.default.moveItem(at: folder, to: trash)) == nil { continue }
            Self.emptyTrash(trash)
        }
        refresh()
    }

    /// 지우는 중인 게임 폴더 이름 앞에 붙는다 (숨김 폴더라 목록에 안 보인다)
    nonisolated static let trashPrefix = ".trash-"

    /// 뒤에서 지운다. 앱이 그 사이 꺼지면 다음 실행 때 `emptyLeftoverTrash` 가 마저 지운다
    nonisolated static func emptyTrash(_ folder: URL) {
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: folder) }
    }

    static func emptyLeftoverTrash() {
        let items = (try? FileManager.default.contentsOfDirectory(at: gamesDir, includingPropertiesForKeys: nil)) ?? []
        for u in items where u.lastPathComponent.hasPrefix(trashPrefix) { emptyTrash(u) }
    }
}

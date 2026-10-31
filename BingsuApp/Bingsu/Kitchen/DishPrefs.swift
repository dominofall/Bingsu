import SwiftUI
import Combine

/// 가상 패드 설정 한 벌. 전역 기본값과 게임별 덮어쓰기에 같이 쓴다.
struct PadPrefs: Codable, Equatable {
    var kind: PadKind = .simple
    var scale: Double = 1.0
    var opacity: Double = 0.55
    var floatingStick = true
    var showLabels = false
    var haptics = true
    var leftHanded = false   // 한손 배치를 왼손 엄지 쪽으로

    /// 전역 설정(@AppStorage 키)에서 읽는다
    static func global(_ d: UserDefaults = .standard) -> PadPrefs {
        var p = PadPrefs()
        if let k = d.string(forKey: "spoon.kind"), let kind = PadKind(rawValue: k) { p.kind = kind }
        if d.object(forKey: "spoon.scale") != nil { p.scale = d.double(forKey: "spoon.scale") }
        if d.object(forKey: "spoon.opacity") != nil { p.opacity = d.double(forKey: "spoon.opacity") }
        if d.object(forKey: "spoon.floatingStick") != nil { p.floatingStick = d.bool(forKey: "spoon.floatingStick") }
        if d.object(forKey: "spoon.showLabels") != nil { p.showLabels = d.bool(forKey: "spoon.showLabels") }
        if d.object(forKey: "spoon.haptics") != nil { p.haptics = d.bool(forKey: "spoon.haptics") }
        p.leftHanded = d.bool(forKey: "spoon.leftHanded")
        return p
    }
}

extension PadPrefs {
    /// 나중에 더한 항목(leftHanded)이 없는 예전 게임별 설정도 읽히게, 빠진 키는 기본값
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PadPrefs()
        kind = try c.decodeIfPresent(PadKind.self, forKey: .kind) ?? d.kind
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        floatingStick = try c.decodeIfPresent(Bool.self, forKey: .floatingStick) ?? d.floatingStick
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? d.showLabels
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        leftHanded = try c.decodeIfPresent(Bool.self, forKey: .leftHanded) ?? d.leftHanded
    }
}

/// 게임 하나의 설정: 패드 덮어쓰기(없으면 전역), 표지 이미지.
struct DishPrefs: Codable, Equatable {
    var pad: PadPrefs?            // nil = 전역 설정 사용
    var coverFile: String?        // Documents/Covers/<파일>
    var quality: Quality?         // 사용자가 고른 화질. nil = 자동(벤치마크 권장값)
    var recommendedQuality: Quality?   // 첫 실행 벤치마크가 정한 권장 화질
    var fpsLimit: FpsLimit?       // 사용자가 고른 프레임 제한. nil = 자동(게임 기본값 + 뜨거워지면 30)
    var playInSilent: Bool?       // 무음 모드에서도 소리 재생. nil = 설정 › 게임 중의 값 (빌드 21 에서 더함, 예전 파일엔 없음 → nil)
    var allowOnline: Bool?        // RPG Maker 게임의 온라인 접속 허용. nil = 켬 (2026-10-31 사용자 결정: 기본 온라인. 빌드 22 에서 더함, 예전 파일엔 없음 → nil)

    /// 실제로 쓸 화질: 직접 고른 값 → 벤치마크 권장 → 높음
    var effectiveQuality: Quality { quality ?? recommendedQuality ?? .high }

    /// 게임을 열 때의 프레임 제한(초당 프레임 수). nil = 제한 없음(화면 주사율 그대로)
    func baseFpsCap(for dish: Dish) -> Int? {
        switch fpsLimit {
        case .fps60: return nil
        case .fps30: return 30
        case nil: return FpsLimit.autoCap(for: dish)
        }
    }
}

/// 프레임 제한. 게임이 매 프레임 화면 전체를 다시 그리므로(포켓로그는 1920×1080 을 멈춰 있을 때도),
/// 초당 횟수를 줄이는 것이 발열을 가장 크게 줄인다 (2026-10-30 사용자 결정).
enum FpsLimit: String, Codable, CaseIterable {
    case fps60, fps30
    var label: String {
        switch self { case .fps60: return "초당 60 (제한 없음)"; case .fps30: return "초당 30" }
    }
    /// 자동일 때 게임 기본값: 턴제라 30 으로 충분한 게임만 처음부터 30
    static func autoCap(for dish: Dish) -> Int? { dish.knownWeb == .pokerogue ? 30 : nil }
}

/// 게임별 설정 저장소. `Documents/Prefs/<dish.id>.json`, 표지는 `Documents/Covers/`.
/// 게임 폴더 밖에 두므로 게임을 다시 가져와도 남는다.
@MainActor
final class DishPrefsStore: ObservableObject {
    static let shared = DishPrefsStore()
    /// 키는 파일 이름과 같은 safeName(id). 게임 id 그대로 쓰면 띄어쓰기·느낌표가 든 id 는 다시 켰을 때 파일과 짝이 안 맞아 설정이 사라졌다
    @Published private(set) var all: [String: DishPrefs] = [:]

    nonisolated private static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    nonisolated static let prefsDir = docs.appendingPathComponent("Prefs", isDirectory: true)
    nonisolated static let coversDir = docs.appendingPathComponent("Covers", isDirectory: true)
    private var prefsDir: URL { Self.prefsDir }
    var coversDir: URL { Self.coversDir }

    private init() { load() }

    func prefs(for id: String) -> DishPrefs { all[Self.safeName(id)] ?? DishPrefs() }

    /// 실제로 쓸 패드 설정: 게임별 값이 있으면 그것, 없으면 전역
    func effectivePad(for id: String) -> PadPrefs { all[Self.safeName(id)]?.pad ?? PadPrefs.global() }

    func coverURL(for id: String) -> URL? {
        guard let f = all[Self.safeName(id)]?.coverFile else { return nil }
        let u = coversDir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func update(_ id: String, _ change: (inout DishPrefs) -> Void) {
        var p = prefs(for: id); change(&p)
        all[Self.safeName(id)] = p
        save(id, p)
    }

    /// 표지 이미지 저장 (JPEG, 긴 변 1024 이하로 줄임)
    func setCover(_ image: UIImage?, for id: String) {
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
        if let old = all[Self.safeName(id)]?.coverFile { try? FileManager.default.removeItem(at: coversDir.appendingPathComponent(old)) }
        guard let image, let data = Self.downscaled(image).jpegData(compressionQuality: 0.88) else {
            update(id) { $0.coverFile = nil }; return
        }
        let name = Self.safeName(id) + "-" + String(Int(Date().timeIntervalSince1970)) + ".jpg"
        try? data.write(to: coversDir.appendingPathComponent(name), options: .atomic)
        update(id) { $0.coverFile = name }
    }

    func remove(_ id: String) {
        setCover(nil, for: id)
        RumbleShelf.removeUserFile(for: id)
        all[Self.safeName(id)] = nil
        try? FileManager.default.removeItem(at: prefsDir.appendingPathComponent(Self.safeName(id) + ".json"))
    }

    /// iCloud 에서 설정 파일을 내려받은 뒤 다시 읽는다 (Igloo)
    func reloadFromDisk() {
        all = [:]
        load()
    }

    // MARK: 파일

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: prefsDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let p = try? JSONDecoder().decode(DishPrefs.self, from: d) {
                all[f.deletingPathExtension().lastPathComponent] = p
            }
        }
    }

    private func save(_ id: String, _ p: DishPrefs) {
        try? FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(p) {
            try? d.write(to: prefsDir.appendingPathComponent(Self.safeName(id) + ".json"), options: .atomic)
        }
    }

    /// `Prefs/<이 이름>.json`. 동기화(Igloo)도 같은 이름을 쓴다
    nonisolated static func safeName(_ id: String) -> String {
        String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
    }

    private static func downscaled(_ img: UIImage, maxSide: CGFloat = 1024) -> UIImage {
        let s = max(img.size.width, img.size.height)
        guard s > maxSide else { return img }
        let k = maxSide / s
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        return UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

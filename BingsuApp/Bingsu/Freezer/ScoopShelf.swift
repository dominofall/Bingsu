import UIKit

/// 상태 저장 칸의 사진·이름 (빌드 49). 저장 파일은 `Saves/<dataPathApp>/` 에 두고 iCloud·백업으로 넘어가지만,
/// 사진·이름은 이 기기에만 둔다(`Library/Application Support/ScoopShelf/<dataPathApp>/`): 다른 기기에서는 사진 없이 시각만 보인다.
/// - 사진: 저장 순간 게임 화면 (일시정지 메뉴가 찍히지 않은 프레임), 긴 변 320px — 세이브 카드 자리(`SaveCard`)에
/// - `names.json`: {칸: 이름}
enum ScoopShelf {
    private static func dir(_ dish: Dish) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoopShelf", isDirectory: true)
        // 저장 폴더 이름을 그대로 (Freezer.directory 와 같은 규칙)
        let name = Dish.isSafeFolder(dish.dataPathApp) ? dish.dataPathApp : "game"
        let d = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 세이브 카드 전(빌드 49 초기) 이 자리에 둔 칸 사진 `<칸>.jpg` 을 세이브 카드 자리로 옮긴다
    static func movePhotos(_ dish: Dish) {
        let fm = FileManager.default
        let d = dir(dish)
        for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".jpg") {
            let tag = String(f.dropLast(4))
            let slot: Scoop.Slot? = tag == "quick" ? .quick : Int(tag).flatMap { (1...Scoop.maxStates).contains($0) ? Scoop.Slot.state($0) : nil }
            let from = d.appendingPathComponent(f)
            if let slot, let n = Scoop.fileName(dish, slot), let to = SaveCard.photoURL(dish, n), !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            }
            try? fm.removeItem(at: from)
        }
    }

    /// 칸 사진은 세이브 카드 자리에 (`SaveCard.photoURL`, 세이브 파일 이름으로)
    static func thumb(_ dish: Dish, _ slot: Scoop.Slot) -> UIImage? {
        guard let n = Scoop.fileName(dish, slot), let u = SaveCard.photoURL(dish, n) else { return nil }
        return UIImage(contentsOfFile: u.path)
    }

    /// 게임 화면을 작게 줄여 둔다. 사진이 없으면 지난 사진을 지운다(다른 상태의 사진이 남지 않게)
    static func keep(_ image: UIImage?, _ dish: Dish, _ slot: Scoop.Slot) {
        guard let n = Scoop.fileName(dish, slot) else { return }
        SaveCard.keepPhoto(image, dish, n)
    }

    private static func namesURL(_ dish: Dish) -> URL { dir(dish).appendingPathComponent("names.json") }

    static func names(_ dish: Dish) -> [String: String] {
        guard let d = try? Data(contentsOf: namesURL(dish)), d.count < 256 * 1024 else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    static func setName(_ name: String?, _ dish: Dish, _ slot: Scoop.Slot) {
        var all = names(dish)
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        all[slot.tag] = t.isEmpty ? nil : String(t.prefix(40))
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: namesURL(dish), options: .atomic) }
    }

    /// 칸을 지울 때 사진·이름도
    static func forget(_ dish: Dish, _ slot: Scoop.Slot) {
        if let n = Scoop.fileName(dish, slot) { SaveCard.forget(dish, n) }
        setName(nil, dish, slot)
    }
}

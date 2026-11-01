import Foundation

/// MIDI 사운드폰트 선반: RPG Maker 게임의 `.mid` 배경음을 FluidSynth 가 소리로 만들 때 쓰는 `.sf2`.
/// 우선순위: 게임 mkxp.json 의 `midiSoundFont`(엔진이 읽음) → 사용자가 넣은 파일 → 앱에 동봉한 파일.
/// 빌드 26 은 동봉 파일이 없다(GPLv3 앱과 함께 줄 수 있고 8MB 이하인 GM 사운드폰트를 찾지 못함, IMPLEMENTATION-vx.md "구현 중 바뀐 것").
/// 사용자 파일은 `Application Support/SoundFont/` 에 하나만 두고 모든 RPG Maker 게임이 같이 쓴다.
enum SoundFontShelf {
    struct Font: Equatable {
        let url: URL
        let name: String
        let bundled: Bool
    }

    /// 너무 큰 파일은 받지 않는다 (FluidSynth 가 통째로 메모리에 올린다)
    static let maxBytes = 512 * 1024 * 1024

    static var userDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundFont", isDirectory: true)
    }

    static var userFont: Font? {
        let items = (try? FileManager.default.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil)) ?? []
        guard let u = items.filter({ $0.pathExtension.lowercased() == "sf2" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
        else { return nil }
        return Font(url: u, name: u.lastPathComponent, bundled: false)
    }

    static var bundledFont: Font? {
        guard let dir = Bundle.main.url(forResource: "SoundFont", withExtension: nil),
              let u = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .first(where: { $0.pathExtension.lowercased() == "sf2" }) else { return nil }
        return Font(url: u, name: u.deletingPathExtension().lastPathComponent, bundled: true)
    }

    /// 엔진에 넘길 파일 (게임 mkxp.json 에 값이 없을 때)
    static var current: Font? { userFont ?? bundledFont }

    struct Rejection: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Files 에서 고른 파일을 넣는다(있던 파일은 바꾼다). 앞 12바이트가 `RIFF....sfbk` 여야 한다
    @discardableResult
    static func importFile(_ src: URL) throws -> Font {
        let ok = src.startAccessingSecurityScopedResource(); defer { if ok { src.stopAccessingSecurityScopedResource() } }
        guard src.pathExtension.lowercased() == "sf2" else { throw Rejection(reason: ".sf2 파일만 넣을 수 있어요") }
        let size = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 12 else { throw Rejection(reason: "파일이 비어 있어요") }
        guard size <= maxBytes else { throw Rejection(reason: "파일이 512MB 를 넘어요") }
        guard let fh = try? FileHandle(forReadingFrom: src), let head = try? fh.read(upToCount: 12) else {
            throw Rejection(reason: "파일을 읽을 수 없어요")
        }
        try? fh.close()
        guard head.count == 12, head.prefix(4) == Data("RIFF".utf8), head.suffix(4) == Data("sfbk".utf8) else {
            throw Rejection(reason: "사운드폰트(.sf2) 파일이 아니에요")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        // 이름은 한 단계 파일 이름으로만
        let name = Dish.folderName(src.deletingPathExtension().lastPathComponent, fallback: "soundfont") + ".sf2"
        let tmp = userDir.appendingPathComponent(".incoming-\(UUID().uuidString).sf2")
        try fm.copyItem(at: src, to: tmp)
        for old in (try? fm.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil)) ?? [] where old != tmp {
            try? fm.removeItem(at: old)
        }
        let dest = userDir.appendingPathComponent(name)
        try fm.moveItem(at: tmp, to: dest)
        NSLog("[SoundFont] 넣음 \(name) (\(size) bytes)")
        return Font(url: dest, name: name, bundled: false)
    }

    static func removeUserFont() {
        try? FileManager.default.removeItem(at: userDir)
    }
}

/// RTP 선반: VX·VX Ace·XP 게임이 따로 쓰는 공용 그림·소리 묶음(RTP). `Application Support/RTP/<이름>/` 에 `Graphics/`·`Audio/` 를 둔다.
/// 이름은 게임 ini 의 `RTP=` 값(대소문자 무시, 보통 RPGVXAce·RPGVX·Standard). 실행 때 엔진 설정 `"RTP"` 로 넘긴다.
/// RTP 설치 파일(exe)은 풀 수 없어서 폴더를 zip 으로 묶어 게임 가져오기로 넣게 한다(Delivery 가 알아봄)
enum RTPShelf {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RTP", isDirectory: true)
    }

    static let knownNames = ["RPGVXAce", "RPGVX", "Standard"]

    static var installed: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// 넣어 둔 RTP 폴더 (이름은 대소문자 무시)
    static func folder(named name: String) -> URL? {
        guard let hit = installed.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return dir.appendingPathComponent(hit, isDirectory: true)
    }

    static func isInstalled(_ name: String) -> Bool { folder(named: name) != nil }

    /// 게임이 아니고 `Graphics/`·`Audio/` 폴더가 있으면 RTP 로 본다
    static func looksLikeRTP(_ root: URL) -> Bool {
        let g = RGSSProbe.resolve(root, "Graphics"), a = RGSSProbe.resolve(root, "Audio")
        guard let g, let a, isDir(g), isDir(a) else { return false }
        return RGSSProbe.probe(folder: root).version == nil
    }

    /// 어떤 RTP 인지: 넣는 쪽이 알려 준 이름 → 폴더·파일 이름 → 안에 든 폴더 모양
    static func guessName(_ root: URL, sourceName: String, preferred: String? = nil) -> String {
        if let p = preferred, !p.isEmpty { return Dish.folderName(p, fallback: "RPGVXAce") }
        for hint in [root.lastPathComponent, (sourceName as NSString).deletingPathExtension].map({ $0.lowercased() }) {
            let compact = hint.filter { $0.isLetter || $0.isNumber }
            if compact.contains("vxace") { return "RPGVXAce" }
            if compact.contains("vx") { return "RPGVX" }
            if compact.contains("rpgxp") || compact.contains("xprtp") || compact.contains("rtpxp") || compact.contains("standard") { return "Standard" }
        }
        if RGSSProbe.resolve(root, "Graphics/Battlebacks1") != nil { return "RPGVXAce" }
        if RGSSProbe.resolve(root, "Graphics/Autotiles") != nil || RGSSProbe.resolve(root, "Graphics/Windowskins") != nil { return "Standard" }
        return "RPGVX"
    }

    /// 풀어 둔 RTP 폴더를 선반으로 옮긴다(같은 이름이 있으면 바꾼다)
    static func install(_ root: URL, name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var d = dir; try? d.setResourceValues(values)
        let dest = dir.appendingPathComponent(name, isDirectory: true)
        if let old = folder(named: name) { try? fm.removeItem(at: old) }
        try fm.moveItem(at: root, to: dest)
        NSLog("[RTP] 넣음 \(name)")
    }

    static func remove(_ name: String) {
        if let f = folder(named: name) { try? FileManager.default.removeItem(at: f) }
    }

    private static func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}

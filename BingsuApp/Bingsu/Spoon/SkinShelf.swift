import SwiftUI
import UIKit
import ImageIO
import Combine
import ZIPFoundation

/// 패드 스킨 선반: 앱에 든 스킨(`Resources/Skins/<id>/`)과 사용자 스킨(`Documents/Skins/<id>/`)을 읽고 검사하고 저장한다.
/// 형식은 `docs/skins/README.md`. 스킨 파일은 PR 로 들어오거나 사용자가 가져오는 외부 데이터라 믿지 않는다(`RumbleShelf` 와 같은 태도):
/// 크기·개수·형식·매직 바이트·경로를 검사하고, 깨진 것은 이유와 함께 거절, 부분 오류는 그 항목만 빼고 로그.
/// 그림은 처음 쓸 때 512px 이하로 한 번 디코딩해 캐시에 두고, 게임 중에는 다시 디코딩하지 않는다.
enum SkinShelf {
    static let format = 1
    static let maxZipBytes = 10 * 1024 * 1024
    static let maxZipFiles = 40
    static let maxUnzippedBytes: UInt64 = 40 * 1024 * 1024
    static let maxJSONBytes = 64 * 1024
    static let maxPNGs = 24
    static let maxPNGBytes = 4 * 1024 * 1024
    static let pixelRange = 32...1024
    static let decodeMaxPixels = 512

    static let bundledIDs = ["ice", "glass", "retro-gray", "neon", "outline", "contrast", "blocks"]
    static let imageKeys: Set<String> = Set(SpoonSkin.skinButtons.map { "button." + $0.name }
                                            + ["button.round", "button.pill", "dpad", "stick.base", "stick.knob", "orb"])

    static var bundledDir: URL? { Bundle.main.url(forResource: "Skins", withExtension: nil) }
    static let userDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Skins", isDirectory: true)
    static var exportDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Export", isDirectory: true)
    }

    /// 스킨을 받지 못한 이유 (화면에 그대로 보여 준다)
    struct Rejection: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    struct Summary: Identifiable, Equatable {
        let id: String
        let name: String
        let author: String?
        let license: String?
        let note: String?
        let isBundled: Bool
        let hasImages: Bool
        let modified: Date
    }

    struct ImportResult: Equatable, Sendable {
        let id: String
        let name: String
        /// 같은 id 의 사용자 스킨을 덮어썼는지
        let replaced: Bool
        /// 스킨을 실제로 넣었는지 (앱에 든 스킨 id 에 배치만 실어 온 경우 false)
        var installed = true
        /// zip 에 든 `layouts.json` (적용은 화면이 묻고 한다)
        let layouts: [String: PadArrangement]?
        let warnings: [String]
    }

    // MARK: 캐시

    private static var cache: [String: SpoonSkin] = [:]
    private static var missingLogged: Set<String> = []
    private static var summaries: [Summary]?
    private static let lock = NSLock()

    /// 스킨 목록이 바뀌었을 때 화면이 다시 그리도록 (가져오기·저장·지우기)
    @MainActor final class Changes: ObservableObject {
        static let shared = Changes()
        @Published private(set) var version = 0
        func bump() { version += 1 }
    }

    private static func changed(_ id: String?) {
        lock.lock()
        if let id { cache[id] = nil; missingLogged.remove(id) } else { cache = [:] }
        summaries = nil
        lock.unlock()
        Task { @MainActor in Changes.shared.bump() }
    }

    static func forget(_ id: String) { changed(id) }

    // MARK: 읽기

    /// 이 패드 설정에 쓸 스킨. 디버그: `BINGSU_SKIN=<id>` 로 강제
    static func skin(for prefs: PadPrefs) -> SpoonSkin {
        #if DEBUG
        if let forced = DevEnv["BINGSU_SKIN"] { return skin(id: forced) }
        #endif
        return skin(id: prefs.effectiveSkin)
    }

    /// id 의 스킨. 없거나 깨졌으면 얼음 (로그는 한 번). 게임 화면이 매번 부르므로 캐시에서 바로 준다
    static func skin(id: String) -> SpoonSkin {
        lock.lock()
        if let s = cache[id] { lock.unlock(); return s }
        lock.unlock()
        var out = SpoonSkin.ice
        if let folder = folder(for: id) {
            do {
                let t0 = Date()
                let s = try load(folder: folder, strict: false).skin
                guard s.id == id else { throw Rejection(reason: "폴더 이름과 skin.json 의 id(\(s.id))가 달라요") }
                out = s
                log("\(id) 읽음 · 그림 \(out.images.count)개 · \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            } catch {
                log("\(id): \((error as? Rejection)?.reason ?? "읽기 실패") → 얼음으로")
            }
        } else {
            lock.lock()
            let first = missingLogged.insert(id).inserted
            lock.unlock()
            if first && id != SpoonSkin.defaultID { log("\(id) 가 이 기기에 없어요 → 얼음으로") }
        }
        lock.lock(); cache[id] = out; lock.unlock()
        return out
    }

    /// 스킨 폴더: 앱에 든 것 먼저, 그다음 사용자 것
    static func folder(for id: String) -> URL? {
        guard isValidID(id) else { return nil }
        let fm = FileManager.default
        if let b = bundledDir?.appendingPathComponent(id, isDirectory: true), fm.fileExists(atPath: b.appendingPathComponent("skin.json").path) { return b }
        let u = userDir.appendingPathComponent(id, isDirectory: true)
        return fm.fileExists(atPath: u.appendingPathComponent("skin.json").path) ? u : nil
    }

    static func isBundled(_ id: String) -> Bool { bundledIDs.contains(id) }

    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9-]{1,39}$"#, options: .regularExpression) != nil
    }

    /// 앱에 든 스킨 먼저(정해진 순서), 그다음 사용자 스킨(최근에 바꾼 것 먼저)
    static func list() -> [Summary] {
        lock.lock()
        if let s = summaries { lock.unlock(); return s }
        lock.unlock()
        var bundled: [Summary] = [], user: [Summary] = []
        let fm = FileManager.default
        for id in bundledIDs {
            if let b = bundledDir?.appendingPathComponent(id), let s = summary(folder: b, bundled: true) { bundled.append(s) }
        }
        let names = (try? fm.contentsOfDirectory(atPath: userDir.path)) ?? []
        for n in names where !n.hasPrefix(".") && isValidID(n) && !isBundled(n) {
            if let s = summary(folder: userDir.appendingPathComponent(n), bundled: false) { user.append(s) }
        }
        user.sort { $0.modified > $1.modified }
        let all = bundled + user
        lock.lock(); summaries = all; lock.unlock()
        return all
    }

    private static func summary(folder: URL, bundled: Bool) -> Summary? {
        let f = folder.appendingPathComponent("skin.json")
        guard let data = readSmall(f, max: maxJSONBytes), let raw = try? JSONDecoder().decode(RawSkin.self, from: data),
              raw.format == format, let id = raw.id, id == folder.lastPathComponent, isValidID(id),
              let name = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            log("\(folder.lastPathComponent): skin.json 을 읽지 못해 목록에서 뺐어요"); return nil
        }
        let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return Summary(id: id, name: String(name.prefix(40)), author: raw.author.map { String($0.prefix(60)) },
                       license: raw.license.map { String($0.prefix(40)) }, note: raw.note.map { String($0.prefix(80)) },
                       isBundled: bundled, hasImages: !(raw.images ?? [:]).isEmpty, modified: date)
    }

    /// 폴더 하나를 스킨으로 읽는다. `strict` 면(가져오기) 그림 문제도 거절, 아니면(이미 넣은 스킨) 그 그림만 빼고 경고
    static func load(folder: URL, strict: Bool) throws -> (skin: SpoonSkin, raw: RawSkin, warnings: [String]) {
        guard let data = readSmall(folder.appendingPathComponent("skin.json"), max: maxJSONBytes) else {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("skin.json").path) {
                throw Rejection(reason: "skin.json 이 64KB 를 넘어요")
            }
            throw Rejection(reason: "skin.json 이 없어요")
        }
        let raw: RawSkin
        do { raw = try JSONDecoder().decode(RawSkin.self, from: data) } catch {
            log("skin.json 형식 오류 \(String(describing: error).prefix(160))")
            throw Rejection(reason: "skin.json 이 JSON 형식이 아니에요")
        }
        if strict {
            let pngs = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.lowercased().hasSuffix(".png") }
            guard pngs.count <= maxPNGs else { throw Rejection(reason: "PNG 가 너무 많아요 · \(pngs.count)개 (\(maxPNGs)개까지)") }
            // 쓰지 않는 PNG 도 검사한다 (이름만 .png 인 다른 파일을 들이지 않게)
            for name in pngs.sorted() { _ = try checkPNG(folder.appendingPathComponent(name)) }
        }
        var (skin, warnings) = try build(raw, folder: folder, strict: strict)
        skin.isBundled = isBundled(skin.id) && folder.deletingLastPathComponent().standardizedFileURL == bundledDir?.standardizedFileURL
        for w in warnings { log("\(skin.id): \(w)") }
        if warnings.count > 20 { warnings = Array(warnings.prefix(20)) + ["… 외 \(warnings.count - 20)개"] }
        return (skin, raw, warnings)
    }

    /// 원본 → 스킨. 맨 위 필드가 틀리면 전체 거절, 색·숫자·글자·그림 하나가 틀리면 그 값만 기본값(경고)
    static func build(_ raw: RawSkin, folder: URL?, strict: Bool) throws -> (SpoonSkin, [String]) {
        guard raw.format == format else {
            throw Rejection(reason: "format \(raw.format.map(String.init) ?? "없음") 은 읽을 수 없어요 (\(format) 만 읽어요)")
        }
        guard let id = raw.id, isValidID(id) else { throw Rejection(reason: "id 는 영어 소문자·숫자·하이픈 2~40자여야 해요") }
        guard let name = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw Rejection(reason: "name 이 없어요") }
        var w: [String] = []
        var s = SpoonSkin()
        s.id = id; s.name = String(name.prefix(40))
        s.author = raw.author.map { String($0.prefix(60)) }
        s.license = raw.license.map { String($0.prefix(40)) }
        s.note = raw.note.map { String($0.prefix(80)) }

        func color(_ v: String?, _ field: String) -> Color? {
            guard let v else { return nil }
            if let c = Color(skinHex: v) { return c }
            w.append("색 \(field) \(v.prefix(12)) 은 #RRGGBB 가 아니라 기본값을 써요"); return nil
        }
        func number(_ v: Double?, _ field: String, _ r: ClosedRange<Double>) -> Double? {
            guard let v else { return nil }
            guard v.isFinite else { w.append("\(field) 값이 숫자가 아니에요"); return nil }
            if !r.contains(v) { w.append("\(field) \(v) 을 \(r.lowerBound)~\(r.upperBound) 로 잘랐어요") }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        if let c = raw.colors {
            s.ink = color(c.ink, "ink") ?? s.ink
            s.text = color(c.text, "text")
            s.fill = color(c.fill, "fill")
            s.shade = color(c.shade, "shade") ?? s.shade
            s.press = color(c.press, "press") ?? s.press
            s.dpadFill = color(c.dpad, "dpad")
            s.stickFill = color(c.stick, "stick")
            s.fillTop = number(c.fillTop, "fillTop", 0...1) ?? s.fillTop
            s.shadeBottom = number(c.shadeBottom, "shadeBottom", 0...1) ?? s.shadeBottom
            s.rim = number(c.rim, "rim", 0...1.5) ?? s.rim
            s.lineWidth = CGFloat(number(c.lineWidth, "lineWidth", 0...4) ?? Double(s.lineWidth))
        }
        if let sh = raw.shape {
            switch sh.kind {
            case "circle"?, nil: s.shape = .circle
            case "squircle"?: s.shape = .squircle(corner: CGFloat(number(sh.corner ?? 0.4, "shape.corner", 0.2...0.5) ?? 0.4))
            case let k?: w.append("shape.kind \(k.prefix(20)) 는 모르는 모양이라 원으로 그려요")
            }
        }
        if let l = raw.labels {
            if let st = l.style {
                if let v = SpoonSkin.LabelStyle(rawValue: st) { s.labelStyle = v } else { w.append("labels.style \(st.prefix(20)) 는 모르는 세트예요") }
            }
            if let f = l.font {
                if let v = SpoonSkin.fonts.first(where: { $0.0 == f }) { s.font = v.1 } else { w.append("labels.font \(f.prefix(20)) 는 모르는 글꼴이에요") }
            }
            for (k, v) in l.overrides ?? [:] {
                guard let b = PadButton(name: k), SpoonSkin.skinButtons.contains(b) else { w.append("labels.overrides 의 \(k.prefix(12)) 는 버튼 이름이 아니에요"); continue }
                s.overrides[b] = String(v.prefix(8))
            }
        }
        for (k, v) in raw.buttonColors ?? [:] {
            guard let b = PadButton(name: k), SpoonSkin.skinButtons.contains(b) else { w.append("buttonColors 의 \(k.prefix(12)) 는 버튼 이름이 아니에요"); continue }
            if let c = color(v, "buttonColors.\(k)") { s.buttonColors[b] = c }
        }
        if let folder {
            for (key, spec) in (raw.images ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard imageKeys.contains(key) else { w.append("images 의 \(key.prefix(20)) 는 모르는 요소예요"); continue }
                guard let normalName = spec.normal else { w.append("images.\(key) 에 normal 이 없어요"); continue }
                do {
                    guard let normal = try picture(folder, normalName, strict: strict, warnings: &w) else { continue }
                    var p = SpoonSkin.Picture(normal: normal.image)
                    p.pressed = try spec.pressed.flatMap { try picture(folder, $0, strict: strict, warnings: &w)?.image }
                    if key == "dpad" { p.pressedArm = try spec.pressedArm.flatMap { try picture(folder, $0, strict: strict, warnings: &w)?.image } }
                    if let ins = spec.capInsets?.edgeInsets {
                        // 원본 픽셀 기준 → 디코딩한 그림 픽셀 기준
                        let f = normal.factor
                        p.capInsets = UIEdgeInsets(top: ins.top * f, left: ins.left * f, bottom: ins.bottom * f, right: ins.right * f)
                    }
                    p.showsLabel = spec.label ?? true
                    s.images[key] = p
                }
            }
        }
        return (s, w)
    }

    /// 그림 하나 읽기. 원본 크기 대비 디코딩한 비율(factor)도 준다
    private static func picture(_ folder: URL, _ name: String, strict: Bool, warnings w: inout [String]) throws -> (image: UIImage, factor: CGFloat)? {
        guard name.range(of: #"^[a-z0-9_-]{1,60}\.png$"#, options: .regularExpression) != nil else {
            if strict { throw Rejection(reason: "그림 이름은 영어 소문자·숫자·_·- 와 .png 만 돼요: \(name.prefix(40))") }
            w.append("그림 이름 \(name.prefix(40)) 이 규칙에 안 맞아 뺐어요"); return nil
        }
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { w.append("\(name) 이 없어 그 그림은 뺐어요"); return nil }
        do {
            let px = try checkPNG(url)
            guard let image = decode(url) else { throw Rejection(reason: "그림을 읽지 못했어요: \(name)") }
            return (image, CGFloat(image.cgImage?.width ?? px.width) / CGFloat(max(px.width, 1)))
        } catch let r as Rejection {
            if strict { throw r }
            w.append(r.reason + " (뺐어요)"); return nil
        }
    }

    /// PNG 검사: 크기 상한, 매직 바이트, 디코딩 전에 픽셀 크기(32~1024)
    @discardableResult
    static func checkPNG(_ url: URL) throws -> (width: Int, height: Int) {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxPNGBytes else { throw Rejection(reason: "그림 파일이 너무 커요: \(name) (4MB 까지)") }
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw Rejection(reason: "그림을 읽지 못했어요: \(name)") }
        let head = (try? fh.read(upToCount: 8)) ?? Data()
        try? fh.close()
        guard Array(head) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { throw Rejection(reason: "PNG 가 아니에요: \(name)") }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw Rejection(reason: "PNG 가 아니에요: \(name)")
        }
        guard pixelRange.contains(w), pixelRange.contains(h) else {
            let big = max(w, h) > pixelRange.upperBound
            throw Rejection(reason: big ? "그림이 너무 커요: \(name) \(max(w, h))px (\(pixelRange.upperBound) 이하)"
                                        : "그림이 너무 작아요: \(name) \(min(w, h))px (\(pixelRange.lowerBound) 이상)")
        }
        return (w, h)
    }

    /// 512px 이하로 한 번 디코딩 (게임 위 메모리)
    private static func decode(_ url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: decodeMaxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    private static func readSmall(_ url: URL, max: Int) -> Data? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= max else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: 가져오기

    /// `.bingsuskin`(또는 skin.json 이 든 zip) 가져오기. 검사를 다 통과해야 `Documents/Skins/<id>/` 를 바꾼다
    static func importZip(at url: URL) throws -> ImportResult {
        let fm = FileManager.default
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxZipBytes else { throw Rejection(reason: "zip 이 10MB 를 넘어요 · " + String(format: "%.1fMB", Double(size) / 1_048_576)) }
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            throw Rejection(reason: SafeUnzip.classifyOpenFailure(url).errorDescription ?? "zip 파일이 아니에요")
        }
        // 풀기 전에 목록으로 개수·크기 확인
        var files = 0, total: UInt64 = 0
        for e in archive {
            let comps = e.path.split(separator: "/").map(String.init)
            if comps.contains(where: { $0 == "__MACOSX" || $0 == ".DS_Store" }) { continue }
            if e.type == .symlink { throw Rejection(reason: "zip 안에 링크가 있어요: \(e.path.prefix(60))") }
            guard e.type == .file else { continue }
            files += 1; total += e.uncompressedSize
        }
        guard files <= maxZipFiles else { throw Rejection(reason: "파일이 너무 많아요 · \(files)개 (\(maxZipFiles)개까지)") }
        guard total <= maxUnzippedBytes else { throw Rejection(reason: "압축을 풀면 너무 커요 · " + SafeUnzip.bytes(total)) }

        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        sweepStaleWork()
        let work = userDir.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let staged = work.appendingPathComponent("staged", isDirectory: true)
        do { try SafeUnzip.unzip(url, to: staged, progress: { _ in }) } catch {
            throw Rejection(reason: (error as? LocalizedError)?.errorDescription ?? "압축을 풀지 못했어요")
        }
        // 루트: skin.json 이 바로 있거나, 하나뿐인 폴더 안 (macOS 가 폴더를 압축하면 한 단계 들어감)
        var root = staged
        if !fm.fileExists(atPath: root.appendingPathComponent("skin.json").path) {
            let items = Delivery.visibleItems(root)
            if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { root = items[0] }
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("skin.json").path) else { throw Rejection(reason: "skin.json 이 없어요") }
        // 스킨에 들어갈 수 있는 것: PNG, skin.json, layouts.json 뿐
        if let walker = fm.enumerator(at: staged, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let f as URL in walker {
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let n = f.lastPathComponent
                if n == ".DS_Store" { continue }
                let atRoot = f.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
                if n.lowercased().hasSuffix(".png") || (atRoot && (n == "skin.json" || n == "layouts.json")) { continue }
                throw Rejection(reason: "스킨 파일이 아닌 것이 들어 있어요: \(n.prefix(40))")
            }
        }
        let loaded = try load(folder: root, strict: true)
        var warnings = loaded.warnings
        var layouts: [String: PadArrangement]?
        let lf = root.appendingPathComponent("layouts.json")
        if fm.fileExists(atPath: lf.path) {
            do {
                guard let d = readSmall(lf, max: PadArrangementFile.maxBytes) else { throw Rejection(reason: "layouts.json 이 64KB 를 넘어요") }
                let l = try PadArrangementFile.parse(d)
                layouts = l.isEmpty ? nil : l
                if l.isEmpty { warnings.append("layouts.json 에 쓸 수 있는 배치가 없어요") }
            } catch {
                warnings.append(((error as? Rejection)?.reason ?? "layouts.json 을 읽지 못했어요") + " — 배치는 빼고 스킨만 넣어요")
            }
        }
        let id = loaded.skin.id
        if isBundled(id) {
            // 앱에 든 스킨 + 배치 (편집기 "배치 내보내기"로 만든 파일): 스킨은 그대로 두고 배치만 가져온다
            guard let layouts else { throw Rejection(reason: "앱에 든 스킨과 이름이 같아요 (\(id))") }
            log("가져오기: 앱에 든 스킨 \(id) + 배치 \(layouts.count)개")
            return ImportResult(id: id, name: skin(id: id).name, replaced: false, installed: false, layouts: layouts, warnings: warnings)
        }
        // 깨끗한 폴더로 옮겨 담기 (쓸 파일만): skin.json, layouts.json, 루트의 PNG
        let clean = work.appendingPathComponent("clean", isDirectory: true)
        try fm.createDirectory(at: clean, withIntermediateDirectories: true)
        for n in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where n == "skin.json" || n == "layouts.json" || n.lowercased().hasSuffix(".png") {
            try fm.copyItem(at: root.appendingPathComponent(n), to: clean.appendingPathComponent(n))
        }
        let replaced = try install(clean, id: id)
        log("가져오기: \(id) \(replaced ? "덮어씀" : "새로") · 경고 \(warnings.count) · 배치 \(layouts?.count ?? 0)")
        return ImportResult(id: id, name: loaded.skin.name, replaced: replaced, layouts: layouts, warnings: warnings)
    }

    /// `Documents/Skins/<id>/` 를 통째로 바꾼다: 옛 폴더를 옆 이름으로 옮긴 뒤 새 폴더를 그 자리로 (실패하면 되돌림)
    @discardableResult
    private static func install(_ folder: URL, id: String) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        let final = userDir.appendingPathComponent(id, isDirectory: true)
        let existed = fm.fileExists(atPath: final.path)
        if existed {
            let aside = userDir.appendingPathComponent(".replacing-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: final, to: aside)
            do { try fm.moveItem(at: folder, to: final) } catch {
                try? fm.moveItem(at: aside, to: final)
                throw Rejection(reason: "스킨을 저장하지 못했어요")
            }
            try? fm.removeItem(at: aside)
        } else {
            do { try fm.moveItem(at: folder, to: final) } catch { throw Rejection(reason: "스킨을 저장하지 못했어요") }
        }
        changed(id)
        return existed
    }

    /// 지난번에 끊긴 가져오기·교체의 찌꺼기
    private static func sweepStaleWork() {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: userDir.path)) ?? [] where n.hasPrefix(".import-") || n.hasPrefix(".replacing-") {
            try? fm.removeItem(at: userDir.appendingPathComponent(n))
        }
    }

    // MARK: 저장 · 지우기 · 내보내기

    /// 스킨 만들기에서 저장. `copyingImagesFrom` 은 복제한 스킨 폴더(그림 스킨의 PNG 를 함께 옮긴다)
    static func saveUser(_ raw: RawSkin, copyingImagesFrom source: URL? = nil) throws {
        guard let id = raw.id, !isBundled(id) else { throw Rejection(reason: "앱에 든 스킨은 덮어쓸 수 없어요") }
        _ = try build(raw, folder: nil, strict: false)
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        let work = userDir.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try e.encode(raw)
        guard data.count <= maxJSONBytes else { throw Rejection(reason: "skin.json 이 64KB 를 넘어요") }
        try data.write(to: work.appendingPathComponent("skin.json"))
        if let source {
            let names = Set((raw.images ?? [:]).values.flatMap { [$0.normal, $0.pressed, $0.pressedArm].compactMap { $0 } })
            for n in names where n.range(of: #"^[a-z0-9_-]{1,60}\.png$"#, options: .regularExpression) != nil {
                let from = source.appendingPathComponent(n)
                if fm.fileExists(atPath: from.path) { try fm.copyItem(at: from, to: work.appendingPathComponent(n)) }
            }
        }
        try install(work, id: id)
    }

    static func removeUser(_ id: String) {
        guard isValidID(id), !isBundled(id) else { return }
        try? FileManager.default.removeItem(at: userDir.appendingPathComponent(id, isDirectory: true))
        changed(id)
    }

    /// 스킨 폴더를 `.bingsuskin` 으로 묶는다. 앱에 든 스킨도 된다(양식 용도). `layouts` 가 있으면 `layouts.json` 으로 함께
    static func exportZip(id: String, layouts: [String: PadArrangement]? = nil) throws -> URL {
        guard let folder = folder(for: id) else { throw Rejection(reason: "스킨을 찾지 못했어요") }
        let fm = FileManager.default
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let tmp = exportDir.appendingPathComponent(id, isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        for n in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where n == "skin.json" || n.lowercased().hasSuffix(".png")
            || (n == "layouts.json" && layouts == nil) {
            try fm.copyItem(at: folder.appendingPathComponent(n), to: tmp.appendingPathComponent(n))
        }
        if let layouts, !layouts.isEmpty { try PadArrangementFile.encode(layouts).write(to: tmp.appendingPathComponent("layouts.json")) }
        let out = exportDir.appendingPathComponent(id + ".bingsuskin")
        try? fm.removeItem(at: out)
        try fm.zipItem(at: tmp, to: out, shouldKeepParent: false)
        log("내보내기 \(out.lastPathComponent) · 배치 \(layouts?.count ?? 0)")
        return out
    }

    /// zip 안에 skin.json 이 있는지 (게임 가져오기가 풀기 전에 스킨인지 알아본다). 루트 또는 폴더 하나 아래
    static func looksLikeSkin(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "bingsuskin" { return true }
        guard let archive = try? Archive(url: url, accessMode: .read) else { return false }
        var n = 0
        for e in archive {
            n += 1
            if n > 400 { return false }   // 게임 zip 은 크다: 앞쪽만 본다
            let comps = e.path.split(separator: "/").map(String.init)
            if comps.first == "__MACOSX" { continue }
            if comps.last == "skin.json" && comps.count <= 2 { return true }
        }
        return false
    }

    private static func log(_ m: String) { NSLog("[Skin] \(m)") }
}

/// `skin.json` 원본. 모든 필드를 선택으로 받고, 타입이 틀린 값은 그 값만 없는 것으로 친다(검사는 `SkinShelf.build`).
/// 스킨 만들기가 이것을 고쳐 그대로 저장한다
struct RawSkin: Codable, Equatable {
    var format: Int? = 1
    var id: String?
    var name: String?
    var author: String? = nil
    var license: String? = nil
    var note: String? = nil
    var colors: Colors? = nil
    var shape: ShapeSpec? = nil
    var labels: Labels? = nil
    var buttonColors: [String: String]? = nil
    var images: [String: ImageSpec]? = nil

    struct Colors: Codable, Equatable {
        var ink: String? = nil, text: String? = nil, fill: String? = nil
        var fillTop: Double? = nil, shadeBottom: Double? = nil
        var shade: String? = nil, rim: Double? = nil, lineWidth: Double? = nil
        var press: String? = nil, dpad: String? = nil, stick: String? = nil
    }
    struct ShapeSpec: Codable, Equatable {
        var kind: String? = nil
        var corner: Double? = nil
    }
    struct Labels: Codable, Equatable {
        var style: String? = nil
        var font: String? = nil
        var overrides: [String: String]? = nil
    }
    struct ImageSpec: Codable, Equatable {
        var normal: String? = nil
        var pressed: String? = nil
        var pressedArm: String? = nil
        var capInsets: Insets? = nil
        var label: Bool? = nil
    }
    /// 9-slice 안쪽 여백(px): 숫자 하나 또는 {top,left,bottom,right}
    enum Insets: Codable, Equatable {
        case all(Double)
        case each(top: Double, left: Double, bottom: Double, right: Double)

        var edgeInsets: UIEdgeInsets? {
            func c(_ v: Double) -> CGFloat { CGFloat(v.isFinite ? min(max(v, 0), 512) : 0) }
            switch self {
            case .all(let v): return UIEdgeInsets(top: c(v), left: c(v), bottom: c(v), right: c(v))
            case let .each(t, l, b, r): return UIEdgeInsets(top: c(t), left: c(l), bottom: c(b), right: c(r))
            }
        }
        private enum K: String, CodingKey { case top, left, bottom, right }
        init(from decoder: Decoder) throws {
            if let v = try? decoder.singleValueContainer().decode(Double.self) { self = .all(v); return }
            let c = try decoder.container(keyedBy: K.self)
            func v(_ k: K) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)).flatMap { $0 } ?? 0 }
            self = .each(top: v(.top), left: v(.left), bottom: v(.bottom), right: v(.right))
        }
        func encode(to encoder: Encoder) throws {
            switch self {
            case .all(let v): var c = encoder.singleValueContainer(); try c.encode(v)
            case let .each(t, l, b, r):
                var c = encoder.container(keyedBy: K.self)
                try c.encode(t, forKey: .top); try c.encode(l, forKey: .left); try c.encode(b, forKey: .bottom); try c.encode(r, forKey: .right)
            }
        }
    }
}

// 타입이 틀린 값(색에 숫자 등)이 파일 전체를 깨지 않게 필드마다 따로 읽는다. 메모리와이즈 init 을 남기려고 확장에 둔다
private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ k: Key) -> T? { (try? decodeIfPresent(T.self, forKey: k)).flatMap { $0 } }
}

extension RawSkin {
    private enum K: String, CodingKey { case format, id, name, author, license, note, colors, shape, labels, buttonColors, images }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        format = c.lenient(.format); id = c.lenient(.id); name = c.lenient(.name)
        author = c.lenient(.author); license = c.lenient(.license); note = c.lenient(.note)
        colors = c.lenient(.colors); shape = c.lenient(.shape); labels = c.lenient(.labels)
        buttonColors = (c.lenient(.buttonColors) as [String: Lenient<String>]?)?.compactMapValues(\.value)
        images = (c.lenient(.images) as [String: Lenient<ImageSpec>]?)?.compactMapValues(\.value)
    }
}

extension RawSkin.Colors {
    private enum K: String, CodingKey { case ink, text, fill, fillTop, shadeBottom, shade, rim, lineWidth, press, dpad, stick }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        ink = c.lenient(.ink); text = c.lenient(.text); fill = c.lenient(.fill)
        fillTop = c.lenient(.fillTop); shadeBottom = c.lenient(.shadeBottom); shade = c.lenient(.shade)
        rim = c.lenient(.rim); lineWidth = c.lenient(.lineWidth)
        press = c.lenient(.press); dpad = c.lenient(.dpad); stick = c.lenient(.stick)
    }
}

extension RawSkin.ShapeSpec {
    private enum K: String, CodingKey { case kind, corner }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        kind = c.lenient(.kind); corner = c.lenient(.corner)
    }
}

extension RawSkin.Labels {
    private enum K: String, CodingKey { case style, font, overrides }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        style = c.lenient(.style); font = c.lenient(.font)
        overrides = (c.lenient(.overrides) as [String: Lenient<String>]?)?.compactMapValues(\.value)
    }
}

extension RawSkin.ImageSpec {
    private enum K: String, CodingKey { case normal, pressed, pressedArm, capInsets, label }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        normal = c.lenient(.normal); pressed = c.lenient(.pressed); pressedArm = c.lenient(.pressedArm)
        capInsets = c.lenient(.capInsets); label = c.lenient(.label)
    }
}

/// 사전 안의 값 하나가 틀려도 사전 전체를 버리지 않게
struct Lenient<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(T.self) }
}

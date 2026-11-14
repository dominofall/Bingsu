import Foundation
import UIKit
import WebKit
import GameController

/// 진단 정보 (PLAN 7.1 코드 이름 `Receipt`. 가져온 기록 `Receipt`(bingsu.json)와 이름이 겹치지 않게 `ReceiptSlip`).
/// 사용자가 게임 문제를 제보할 때 직접 공유하는 글 한 장. 자동으로 보내지 않는다.
///
/// 담는 것: 앱·기기 모델·iOS 버전, 게임 종류·판별 결과·크기(폴더 이름만), 화면 크기·게임 자리·엔진 해상도,
/// 최근 오류(스크립트 이름·줄), 성능 요약, 입력 방식(종류만).
/// 담지 않는 것(PLAN 8장): 기기 이름, 파일 전체 경로(사용자 폴더), 저장 데이터 내용, 계정, IP, 웹 게임 주소의 경로·쿼리.
struct ReceiptSlip {
    struct Line: Hashable {
        var key: String
        var value: String
    }
    struct Section: Hashable {
        var title: String
        var lines: [Line] = []
        /// 키 없이 그대로 적는 줄 (엔진 기록·오류 글)
        var raw: [String] = []
        var isEmpty: Bool { lines.isEmpty && raw.isEmpty }
    }

    var made = Date()
    var sections: [Section] = []

    /// 공유할 글. 미리보기도 이 글을 그대로 보여 준다 (보이는 것 = 보내는 것)
    var text: String {
        var out = "빙수 진단 정보\n만든 때: \(Self.stamp(made))\n"
        for s in sections where !s.isEmpty {
            out += "\n[\(s.title)]\n"
            for l in s.lines { out += "\(l.key): \(l.value)\n" }
            for r in s.raw { out += r + "\n" }
        }
        return out
    }

    /// 파일 이름 (공유 시트). 예: 빙수-진단-1114-1830.txt
    var fileName: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMdd-HHmm"
        return "빙수-진단-\(f.string(from: made)).txt"
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: 식별 정보 지우기

    /// 글에서 사용자를 알아볼 수 있는 것을 지운다:
    /// 앱 컨테이너·앱 그룹·시뮬레이터 경로(UUID·사용자 폴더 포함) → "…/", 맥 사용자 폴더 이름 → `…`(공개본 검사가 그 경로 글자를 찾으므로 코드에 그대로 쓰지 않는다),
    /// IPv4 주소 → `x.x.x.x`, IPv6 비슷한 것 → `x:x::x`, 전자우편 → `(메일)`, 주소의 쿼리·조각 → 뺌
    nonisolated static func scrub(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            // 앱·앱 그룹·번들 컨테이너 (기기·시뮬레이터 모두, 기기의 번들은 소문자 containers): 그 앞은 통째로 지운다
            (#"(?i)(?:file://)?[^\s'"`()<>]*?/Containers/(?:Data/Application|Shared/AppGroup|Bundle/Application|Data/PluginKitPlugin)/[0-9A-Fa-f-]{36}/"#, "…/"),
            (#"(?:file://)?/(?:private/)?var/mobile/[^\s'"`()<>]*"#, "…"),
            (#"/Use[r]s/[^/\s'"`()<>]+"#, "/Use" + "rs/…"),
            (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, "(UUID)"),
            (#"\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b"#, "x.x.x.x"),
            (#"\b(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}\b"#, "x:x::x"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "(메일)"),
            // http(s) 주소의 쿼리·조각 (토큰이 들어 있을 수 있다)
            (#"(https?://[^\s?#'"`]+)[?#][^\s'"`]*"#, "$1"),
        ]
        for (p, r) in rules {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: r)
        }
        return t
    }

    /// 게임이 보낸 글(믿지 않음): 제어 문자 빼고 길이 자르고 식별 정보 지우기
    nonisolated static func clean(_ s: String, limit: Int) -> String {
        let scalars = s.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        let t = scrub(String(String.UnicodeScalarView(scalars)))
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }
}

// MARK: - 만들기

/// 게임 화면이 알려 주는 지금 상태 (게임 중에 만들 때만. 설정에서 만들면 없음)
struct ReceiptLive {
    /// 게임 그림이 실제로 그려지는 자리 (창 기준 점)
    var gameFrame: CGRect?
    /// 입력 방식 줄 (종류만, 제품 이름·식별자 없음)
    var input: [ReceiptSlip.Line] = []
    /// 화면 쪽 덧붙일 줄 (가상 패드·키보드가 떠 있는지 등)
    var screenExtra: [ReceiptSlip.Line] = []
    /// 웹 게임: 페이지 크기·캔버스를 물어볼 웹뷰
    weak var webView: WKWebView?
}

/// 게임 화면 → 진단 정보 시트 (`sheet(item:)` 로 넘겨 시트가 예전 값을 잡지 않게)
struct ReceiptRequest: Identifiable {
    let id = UUID()
    var live: ReceiptLive
    var screenshot: UIImage?
}

@MainActor
extension ReceiptSlip {
    /// 진단 정보 만들기. `dish` 가 nil 이면 앱·기기만. 게임 폴더 크기는 백그라운드에서 센다
    static func make(dish: Dish?, live: ReceiptLive?) async -> ReceiptSlip {
        var slip = ReceiptSlip()
        slip.sections.append(appSection())
        guard let dish else { return slip }
        slip.sections.append(await gameSection(dish))
        if let live { slip.sections.append(await screenSection(dish, live)) }
        if dish.recipe == .mkxp {
            slip.sections.append(engineSection(dish))
            slip.sections.append(engineTraceSection())
        }
        slip.sections.append(errorSection(dish))
        slip.sections.append(perfSection(dish))
        if let live, !live.input.isEmpty { slip.sections.append(Section(title: "입력", lines: live.input)) }
        return slip
    }

    // MARK: 앱·기기

    static func appSection() -> Section {
        var s = Section(title: "앱·기기")
        s.lines.append(Line(key: "앱 버전", value: PerfLogStore.appVersion))
        s.lines.append(Line(key: "기기 모델", value: PerfLogStore.deviceModel))
        s.lines.append(Line(key: "iOS", value: UIDevice.current.systemVersion))
        s.lines.append(Line(key: "메모리", value: String(format: "%.0f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)))
        if let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage {
            s.lines.append(Line(key: "남은 저장 공간", value: String(format: "약 %.0f GB", Double(free) / 1_000_000_000)))
        }
        s.lines.append(Line(key: "언어", value: Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "?"))
        s.lines.append(Line(key: "발열", value: thermalText(ProcessInfo.processInfo.thermalState.rawValue)))
        if ProcessInfo.processInfo.isLowPowerModeEnabled { s.lines.append(Line(key: "저전력 모드", value: "켜짐")) }
        return s
    }

    // MARK: 게임

    static func gameSection(_ dish: Dish) async -> Section {
        var s = Section(title: "게임")
        s.lines.append(Line(key: "이름", value: clean(dish.title, limit: 80)))
        s.lines.append(Line(key: "종류", value: kindText(dish)))
        if dish.isRemote {
            // 주소는 호스트만 (경로·쿼리에 로그인 정보가 들어 있을 수 있다)
            s.lines.append(Line(key: "주소", value: dish.location.host ?? "?"))
            return s
        }
        s.lines.append(Line(key: "폴더 이름", value: clean(dish.location.lastPathComponent, limit: 80)))
        let folder = dish.location
        let (receipt, bytes) = await Task.detached(priority: .userInitiated) { () -> (Receipt, UInt64) in
            (Receipt.read(folder: folder), Delivery.folderSize(folder))
        }.value
        s.lines.append(Line(key: "크기", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        if let v = receipt.version, !v.isEmpty { s.lines.append(Line(key: "버전", value: clean(v, limit: 40))) }
        if let src = receipt.sourceName { s.lines.append(Line(key: "가져온 파일", value: clean(src, limit: 120))) }
        switch dish.recipe {
        case .mkxp:
            let rgss = BrassBowlEngine.rgss(for: dish)
            s.lines.append(Line(key: "RGSS", value: "\(rgss.rawValue) (\(rgssName(rgss)))"))
            // Ruby 는 빙수가 고른다 (사용자 설정 없음, 예전 rubyOverride 는 읽지 않음)
            let auto = RubyProfile.detect(folder: folder, rgss: rgss)
            s.lines.append(Line(key: "Ruby 자동 판별", value: "\(rubyText(auto.ruby)) · 문법 \(auto.syntax)"))
            // 패치가 Ruby 판단을 바꿨으면 (예: 포켓몬 Z 원본 1.8 → 한글 패치 뒤 3.1). 미리 보기 화면에는 보이지 않는다
            for r in Topping.records(for: dish.id) {
                guard let before = r.rubyBefore, let after = r.rubyAfter, before != after else { continue }
                func text(_ v: String) -> String {
                    let p = v.split(separator: " ").map(String.init)
                    return p.isEmpty ? v : rubyText(p[0]) + (p.count > 1 ? " · \(p[1])" : "")
                }
                s.lines.append(Line(key: "패치 뒤 Ruby", value: "\(clean(r.name, limit: 60)): \(text(before)) → \(text(after))"))
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            s.lines.append(Line(key: "mkxp.json", value: names.contains("mkxp.json") ? "있음" : "없음"))
            if let rtp = dish.rtp {
                s.lines.append(Line(key: "RTP", value: "\(clean(rtp, limit: 40)) · \(RTPShelf.isInstalled(rtp) ? "넣음" : (dish.needsRTP ? "없음(필요)" : "없음"))"))
            }
        case .rpgMakerMV:
            if let m = dish.mvmz {
                s.lines.append(Line(key: "엔진", value: m.engine == .mz ? "RPG Maker MZ" : "RPG Maker MV"))
                s.lines.append(Line(key: "게임 위치", value: m.root.isEmpty ? "맨 위" : clean(m.root, limit: 40)))
                s.lines.append(Line(key: "암호화", value: "그림 \(m.encryptedImages ? "예" : "아니오") · 소리 \(m.encryptedAudio ? "예" : "아니오")"))
            }
        case .electron:
            if let e = dish.electron {
                s.lines.append(Line(key: "조작", value: e.inputStyle == .pad ? "키보드·패드" : "터치·마우스"))
                s.lines.append(Line(key: "nodeIntegration", value: e.nodeIntegration ? "켜짐" : "꺼짐"))
                if !e.nativeAddons.isEmpty { s.lines.append(Line(key: "네이티브 애드온", value: "\(e.nativeAddons.count)개")) }
            } else {
                s.lines.append(Line(key: "모양", value: "옛 모양(dist+assets)"))
            }
        default: break
        }
        return s
    }

    // MARK: 화면

    static func screenSection(_ dish: Dish, _ live: ReceiptLive) async -> Section {
        var s = Section(title: "화면")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let win = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        let W = win?.bounds.width ?? 0, H = win?.bounds.height ?? 0
        if let scene {
            s.lines.append(Line(key: "창 크기", value: "\(pt(W))×\(pt(H)) pt (화면 \(pt(scene.screen.bounds.width))×\(pt(scene.screen.bounds.height)), 배율 \(Int(scene.screen.scale))x)"))
            s.lines.append(Line(key: "방향", value: orientationText(scene.effectiveGeometry.interfaceOrientation)))
        }
        if let i = win?.safeAreaInsets {
            s.lines.append(Line(key: "안전 영역", value: "위 \(pt(i.top)) · 아래 \(pt(i.bottom)) · 왼쪽 \(pt(i.left)) · 오른쪽 \(pt(i.right))"))
        }
        if let r = live.gameFrame, r.width > 0, r.height > 0 {
            s.lines.append(Line(key: "게임 화면 자리", value: "x \(pt(r.minX)) · y \(pt(r.minY)) · \(pt(r.width))×\(pt(r.height)) (비율 \(String(format: "%.3f", r.width / r.height)))"))
            if W > 0 {
                // 가로로 치우침: 왼쪽 여백과 오른쪽 여백의 차 (0 이면 가운데)
                let dx = (W - r.maxX) - r.minX
                s.lines.append(Line(key: "좌우 여백 차", value: "\(pt(dx)) pt" + (abs(dx) > 2 ? (dx > 0 ? " (왼쪽으로 치우침)" : " (오른쪽으로 치우침)") : " (가운데)")))
            }
        }
        s.lines += live.screenExtra
        if dish.recipe == .mkxp {
            s.lines += BrassBowlEngine.shared.receiptScreenLines()
        } else if let wv = live.webView {
            s.lines += await webScreenLines(wv)
        }
        return s
    }

    /// 웹 게임 페이지에 화면 크기·캔버스·엔진 이름을 묻는다. 게임 쪽 값이라 숫자 범위와 글자를 검사한다
    static func webScreenLines(_ wv: WKWebView) async -> [Line] {
        let js = """
        (() => { try {
          const cs = Array.from(document.querySelectorAll('canvas')).sort((a, b) => b.width * b.height - a.width * a.height).slice(0, 2)
            .map(c => [c.width, c.height, Math.round(c.clientWidth), Math.round(c.clientHeight)]);
          let eng = '';
          if (window.Utils && Utils.RPGMAKER_NAME) eng = 'RPG Maker ' + Utils.RPGMAKER_NAME + ' ' + (Utils.RPGMAKER_VERSION || '');
          else if (window.Phaser && Phaser.VERSION) eng = 'Phaser ' + Phaser.VERSION;
          else if (window.PIXI && PIXI.VERSION) eng = 'PixiJS ' + PIXI.VERSION;
          else if (window.cc && cc.ENGINE_VERSION) eng = 'Cocos ' + cc.ENGINE_VERSION;
          else if (window.createUnityInstance) eng = 'Unity WebGL';
          else if (window.Godot || window.Engine && window.Engine.prototype && window.Engine.prototype.startGame) eng = 'Godot';
          return JSON.stringify({ w: innerWidth, h: innerHeight, dpr: devicePixelRatio, c: cs, e: eng });
        } catch (e) { return ''; } })()
        """
        let raw: String? = await withCheckedContinuation { cont in
            wv.evaluateJavaScript(js) { r, _ in cont.resume(returning: r as? String) }
        }
        guard let raw, raw.count < 4000, let d = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return [Line(key: "페이지", value: "읽지 못함")]
        }
        func num(_ v: Any?, _ max: Double) -> Double? {
            guard let n = (v as? NSNumber)?.doubleValue, n.isFinite, n >= 0, n <= max else { return nil }
            return n
        }
        var out: [Line] = []
        if let w = num(d["w"], 20000), let h = num(d["h"], 20000) {
            let dpr = num(d["dpr"], 10).map { String(format: "%.2f", $0) } ?? "?"
            out.append(Line(key: "페이지 크기", value: "\(Int(w))×\(Int(h)) CSS px · devicePixelRatio \(dpr)"))
        }
        if let cs = d["c"] as? [[Any]] {
            for (i, c) in cs.prefix(2).enumerated() {
                let v = c.prefix(4).compactMap { num($0, 50000) }.map { Int($0) }
                guard v.count == 4 else { continue }
                out.append(Line(key: i == 0 ? "캔버스" : "캔버스 2", value: "\(v[0])×\(v[1]) (보이는 크기 \(v[2])×\(v[3]))"))
            }
            if cs.isEmpty { out.append(Line(key: "캔버스", value: "없음")) }
        }
        if let e = d["e"] as? String, !e.isEmpty {
            let safe = String(e.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " .-_".unicodeScalars.contains($0) }.prefix(48).map(Character.init))
            out.append(Line(key: "웹 엔진", value: safe))
        }
        return out
    }

    // MARK: RPG Maker 엔진

    static func engineSection(_ dish: Dish) -> Section {
        var s = Section(title: "RPG Maker 엔진")
        let e = BrassBowlEngine.shared
        if let launch = ReceiptDesk.shared.launch(for: dish.id) {
            s.lines.append(Line(key: "마지막 실행", value: stamp(launch.at)))
            s.raw += launch.lines.map { "실행 설정: " + $0 }
        }
        switch e.phase {
        case .idle: s.lines.append(Line(key: "상태", value: "이번에 켠 적 없음"))
        case .booting(let id): s.lines.append(Line(key: "상태", value: id == dish.id ? "여는 중" : "다른 게임 실행 중"))
        case .playing(let id): s.lines.append(Line(key: "상태", value: id == dish.id ? "실행 중" : "다른 게임 실행 중"))
        case .ended(let id, let clean): s.lines.append(Line(key: "상태", value: id == dish.id ? (clean ? "끝남" : "멈춤(비정상 종료)") : "다른 게임이 끝남"))
        }
        // 엔진이 알려 준 RGSS·Ruby·문법·ANGLE·GPU (이번 프로세스에서 엔진을 불러온 경우만)
        let details = e.details
        if !details.isEmpty { s.raw += details.split(separator: "\n").map { "엔진: " + clean(String($0), limit: 80) } }
        return s
    }

    /// 마지막 실행에서 게임 쪽 Ruby 가 적은 핵심 줄 (화면 크기·resize·게임이 원하는 크기). BrassBowlEngine.receiptScript
    static func engineTraceSection() -> Section {
        var s = Section(title: "엔진 기록 (마지막 실행)")
        let url = BrassBowlEngine.receiptTraceFile
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16 * 1024,
              let t = try? String(contentsOf: url, encoding: .utf8) else {
            s.raw.append("(기록 없음)")
            return s
        }
        s.raw += t.split(separator: "\n").suffix(30).map { clean(String($0), limit: 160) }
        return s
    }

    // MARK: 오류

    static func errorSection(_ dish: Dish) -> Section {
        var s = Section(title: "최근 오류")
        let notes = ReceiptDesk.shared.notes(for: dish.id)
        if notes.isEmpty { s.raw.append("(없음)"); return s }
        for n in notes.suffix(5).reversed() {
            var head = "- \(stamp(n.at)) \(n.kind.label)"
            if let sc = n.script { head += " · 스크립트 '\(sc)'" + (n.line.map { " \($0)줄" } ?? "") }
            if n.count > 1 { head += " · \(n.count)번" }
            s.raw.append(head)
            s.raw += n.text.split(separator: "\n", omittingEmptySubsequences: true).prefix(8).map { "    " + $0 }
        }
        return s
    }

    // MARK: 성능

    static func perfSection(_ dish: Dish) -> Section {
        var s = Section(title: "성능 (마지막 기록)")
        guard let r = PerfLogStore.shared.record(for: dish.id) else { s.raw.append("(기록 없음)"); return s }
        if let x = r.sessions.last {
            s.lines.append(Line(key: "때", value: "\(stamp(x.start)) · 플레이 \(Int(x.playSeconds / 60))분 \(Int(x.playSeconds) % 60)초"))
            s.lines.append(Line(key: "FPS", value: String(format: "평균 %.1f · 최저 %.1f · 프레임 p95 %.1f ms · 끊김 %d", x.avgFps, x.minFps, x.p95ms, x.stutters)))
            s.lines.append(Line(key: "메모리 피크", value: "\(Int(x.memoryPeakMB)) MB (앱)"))
            s.lines.append(Line(key: "최고 발열", value: thermalText(x.thermalMax)))
            s.lines.append(Line(key: "화질", value: x.quality.label + (x.fpsCap.map { " · 프레임 제한 \($0)" } ?? "")))
            if r.sessions.count > 1 {
                let avg = r.sessions.map(\.avgFps).reduce(0, +) / Double(r.sessions.count)
                s.lines.append(Line(key: "지난 \(r.sessions.count)번 평균", value: String(format: "%.1f FPS", avg)))
            }
        }
        if let b = r.benchmark {
            s.lines.append(Line(key: "벤치마크", value: String(format: "평균 %.1f FPS · p95 %.1f ms → %@", b.avgFps, b.p95ms, b.quality.label)))
        }
        if let rs = r.restarts, !rs.isEmpty {
            for x in rs.suffix(3).reversed() {
                let kind = x.kind == .crash ? "웹 프로세스 꺼짐(메모리 부족 추정)" : "게임이 스스로 새로고침"
                s.raw.append("- \(stamp(x.at)) \(kind) · 연 지 \(Int(x.afterSeconds))초 · 앱 메모리 \(Int(x.memoryMB)) MB · 발열 \(thermalText(x.thermal))\(x.background ? " · 백그라운드" : "")")
            }
        }
        return s
    }

    // MARK: 도우미

    static func kindText(_ dish: Dish) -> String {
        switch dish.recipe {
        case .mkxp: return "RPG Maker \(rgssName(BrassBowlEngine.rgss(for: dish))) (놋그릇 엔진)"
        case .rpgMakerMV: return dish.mvmz?.engine == .mz ? "RPG Maker MZ (웹뷰)" : "RPG Maker MV (웹뷰)"
        case .electron: return dish.isRedBean ? "Electron (웹뷰, 새 모양)" : "Electron (웹뷰)"
        case .webURL: return "웹 게임" + (dish.knownWeb.map { " (\($0.rawValue))" } ?? "")
        case .unknown: return "알 수 없음"
        }
    }

    static func rgssName(_ v: RGSSVersion) -> String {
        switch v { case .xp: return "XP"; case .vx: return "VX"; case .vxAce: return "VX Ace" }
    }

    static func rubyText(_ r: String) -> String {
        switch r { case "18": return "Ruby 1.8"; case "19": return "Ruby 1.9"; case "31": return "Ruby 3.1"; default: return "Ruby \(r)" }
    }

    static func thermalText(_ raw: Int) -> String {
        switch raw { case 0: return "보통"; case 1: return "약간 따뜻함"; case 2: return "뜨거움"; case 3: return "매우 뜨거움"; default: return "?" }
    }

    static func orientationText(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: return "세로"
        case .portraitUpsideDown: return "세로(거꾸로)"
        case .landscapeLeft: return "가로(왼쪽)"
        case .landscapeRight: return "가로(오른쪽)"
        default: return "알 수 없음"
        }
    }

    static func pt(_ v: CGFloat) -> String {
        abs(v - v.rounded()) < 0.05 ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }
}

// MARK: - 입력 방식 (종류만)

@MainActor
extension ReceiptSlip {
    /// 게임 화면이 알려 준 입력 상태를 줄로. 컨트롤러는 iOS 가 본 종류(productCategory)만, 제품 이름·식별자는 넣지 않는다
    static func inputLines(padShown: Bool, padKind: PadKind, watch: Bool, table: Bool, gameKeyboard: Bool) -> [Line] {
        var out: [Line] = []
        out.append(Line(key: "가상 패드", value: padShown ? "보임 · \(padKind.label)" : "숨김"))
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil && !$0.isSnapshot }.map(\.productCategory)
        out.append(Line(key: "컨트롤러", value: pads.isEmpty ? "없음" : pads.map { clean($0, limit: 40) }.joined(separator: ", ")))
        if watch { out.append(Line(key: "애플워치 컨트롤러", value: "연결됨")) }
        if table { out.append(Line(key: "iPhone 컨트롤러", value: "연결됨")) }
        out.append(Line(key: "하드웨어 키보드", value: GCKeyboard.coalesced != nil ? "있음" : "없음"))
        if gameKeyboard { out.append(Line(key: "게임 키보드", value: "떠 있음")) }
        return out
    }
}

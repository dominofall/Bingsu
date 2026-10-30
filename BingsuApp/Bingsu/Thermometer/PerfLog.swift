import Foundation
import Combine
import UIKit

/// 화질 단계. 낮음은 웹뷰의 `devicePixelRatio` 를 0.75 로 덮어써 렌더 해상도를 낮춘다.
enum Quality: String, Codable, CaseIterable {
    case high, medium, low
    var label: String {
        switch self { case .high: return "높음"; case .medium: return "보통"; case .low: return "낮음" }
    }
    /// nil 이면 기기 값 그대로
    var renderScale: Double? { self == .low ? 0.75 : nil }

    /// 첫 실행 벤치마크 등급 규칙
    static func grade(avgFps: Double, p95: Double) -> Quality {
        if avgFps >= 55 && p95 <= 20 { return .high }
        if avgFps >= 40 { return .medium }
        return .low
    }
}

/// 실행 한 번의 요약. 진단 리포트용이라 사용자 식별 정보는 넣지 않는다 (기기 모델·iOS·앱 버전·수치만).
struct PerfSession: Codable, Equatable, Identifiable {
    var start: Date
    var end: Date
    /// "홈으로" 멈춰 둔 시간·백그라운드는 뺀 실제 플레이 시간(초)
    var playSeconds: Double
    var avgFps: Double
    var minFps: Double
    /// 1초 샘플 p95 들의 95번째 값 (ms)
    var p95ms: Double
    var stutters: Int
    /// ProcessInfo.ThermalState rawValue 최고값 (0 nominal … 3 critical)
    var thermalMax: Int
    var memoryPeakMB: Double
    var device: String
    var os: String
    var app: String
    var quality: Quality
    var samples: Int
    /// 이 실행에서 건 프레임 제한 중 가장 낮은 값 (nil = 제한 없음). 뜨거워져 자동으로 건 것도 포함
    var fpsCap: Int?

    var id: Date { start }
    var chill: Thermometer.Chill {
        Thermometer.chill(fps: avgFps, p95: p95ms, thermal: ProcessInfo.ThermalState(rawValue: thermalMax) ?? .nominal,
                          target: Double(fpsCap ?? 60))
    }
}

/// 첫 실행 벤치마크 결과
struct PerfBenchmark: Codable, Equatable {
    var at: Date
    var avgFps: Double
    var p95ms: Double
    var quality: Quality
    var device: String
}

/// 게임이 처음부터 다시 뜬 일 하나 (진단용, 식별 정보 없음)
struct PerfRestart: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// WebKit 웹 콘텐츠 프로세스가 죽어(대개 iOS 가 메모리 부족으로 정리) 앱이 다시 불러옴
        case crash
        /// 게임 페이지가 스스로 새로고침함 (`location.reload()` 등: 새 버전 배포·연결 끊김 처리)
        case gameReload
    }
    var at: Date
    var kind: Kind
    /// 게임을 연 뒤 몇 초 만인가
    var afterSeconds: Double
    /// 앱 프로세스 메모리 (웹 콘텐츠 프로세스 메모리는 앱에서 볼 수 없음)
    var memoryMB: Double
    /// ProcessInfo.ThermalState rawValue
    var thermal: Int
    /// 게임이 안 보일 때(홈·다른 앱)였나
    var background: Bool
    var quality: Quality
    var device: String
    var os: String
    var app: String

    var id: Date { at }
}

/// 게임 하나의 성능 기록 파일 (`Documents/Perf/<dish id>.json`)
struct PerfRecord: Codable, Equatable {
    var title: String
    var sessions: [PerfSession] = []
    var benchmark: PerfBenchmark?
    /// 재시작 기록 (최근 20개). 이전 버전 파일에는 없으므로 옵셔널
    var restarts: [PerfRestart]?
}

/// 성능 기록 저장소. 화면 표시(HUD) 여부와 상관없이 항상 남긴다.
@MainActor
final class PerfLogStore: ObservableObject {
    static let shared = PerfLogStore()
    static let maxSessions = 30
    @Published private(set) var all: [String: PerfRecord] = [:]

    private var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Perf", isDirectory: true)
    }

    private init() { load() }

    func record(for id: String) -> PerfRecord? { all[id] }

    /// 가장 최근 벤치마크 (게임 제목과 함께)
    var latestBenchmark: (title: String, bench: PerfBenchmark)? {
        all.values.compactMap { r in r.benchmark.map { (r.title, $0) } }.max { $0.1.at < $1.1.at }
    }

    /// 같은 시작 시각의 세션이 있으면 바꾸고(진행 중 저장), 없으면 끝에 붙인다. 최근 30개만 유지.
    func upsert(_ s: PerfSession, id: String, title: String) {
        var r = all[id] ?? PerfRecord(title: title)
        r.title = title
        if let i = r.sessions.lastIndex(where: { $0.start == s.start }) { r.sessions[i] = s } else { r.sessions.append(s) }
        if r.sessions.count > Self.maxSessions { r.sessions.removeFirst(r.sessions.count - Self.maxSessions) }
        all[id] = r
        save(id, r)
    }

    static let maxRestarts = 20

    func addRestart(_ x: PerfRestart, id: String, title: String) {
        var r = all[id] ?? PerfRecord(title: title)
        var list = r.restarts ?? []
        list.append(x)
        if list.count > Self.maxRestarts { list.removeFirst(list.count - Self.maxRestarts) }
        r.restarts = list
        all[id] = r
        save(id, r)
    }

    func setBenchmark(_ b: PerfBenchmark, id: String, title: String) {
        var r = all[id] ?? PerfRecord(title: title)
        r.benchmark = b
        all[id] = r
        save(id, r)
    }

    func clear(_ id: String) {
        all[id] = nil
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    func clearAll() {
        all = [:]
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 파일

    private func fileURL(_ id: String) -> URL { dir.appendingPathComponent(Self.safeName(id) + ".json") }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let r = try? dec.decode(PerfRecord.self, from: d) {
                all[f.deletingPathExtension().lastPathComponent] = r
            }
        }
    }

    private func save(_ id: String, _ r: PerfRecord) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(r) { try? d.write(to: fileURL(id), options: .atomic) }
    }

    static func safeName(_ id: String) -> String {
        String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
    }

    // MARK: 기기 정보 (식별자 없이 모델·버전만)

    /// 예: iPhone17,3. 시뮬레이터는 흉내 내는 모델 식별자
    static let deviceModel: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim + " (시뮬레이터)" }
        var u = utsname(); uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }()
    static var osVersion: String { "iOS " + UIDevice.current.systemVersion }
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// 게임 화면 하나가 열려 있는 동안의 기록기. 온도계 샘플을 모아 세션 요약을 만들고, 처음이면 벤치마크도 한다.
@MainActor
final class PerfRecorder: ObservableObject {
    static let benchmarkSeconds: TimeInterval = 20
    static let benchmarkMinSamples = 5

    let dishID: String
    let title: String
    let quality: Quality
    /// 벤치마크가 끝나면 부른다 (토스트용)
    var onBenchmark: ((PerfBenchmark) -> Void)?
    /// 지금 걸린 프레임 제한. 벤치마크 등급을 60 기준으로 환산하고, 세션에 가장 낮은 값을 남긴다
    var fpsCap: Int? {
        didSet {
            if let c = fpsCap { lowestCap = min(lowestCap ?? c, c) }
            // 벤치마크 도중 제한이 바뀌면 섞인 값이라 다음 실행으로 미룬다
            if fpsCap != oldValue, benchStart != nil, benchPending { benchPaused = true }
        }
    }
    private var lowestCap: Int?

    private let start = Date()
    private var activeSince: Date? = Date()
    private var playSeconds: TimeInterval = 0
    private var fpsSum = 0.0, fpsMin = Double.infinity, count = 0
    private var p95s: [Double] = []
    private var stutters = 0
    private var thermalMax = ProcessInfo.processInfo.thermalState.rawValue
    private var memoryPeak = 0.0
    private var lastSaved = Date()

    // 벤치마크: 첫 샘플부터 20초
    private var benchPending: Bool
    private var benchStart: Date?
    private var benchPaused = false
    private var benchFps: [Double] = [], benchP95: [Double] = []

    init(dishID: String, title: String, quality: Quality) {
        self.dishID = dishID; self.title = title; self.quality = quality
        benchPending = PerfLogStore.shared.record(for: dishID)?.benchmark == nil
    }

    /// 게임이 보이는지(홈으로 멈춰 둠·백그라운드면 false)
    func setActive(_ on: Bool) {
        let now = Date()
        if on, activeSince == nil { activeSince = now }
        if !on, let s = activeSince {
            playSeconds += now.timeIntervalSince(s); activeSince = nil
            if benchStart != nil, benchPending { benchPaused = true }
            save()
        }
    }

    func ingest(fps: Double, p95: Double, stutters st: Int, memoryMB: Double, thermal: ProcessInfo.ThermalState) {
        guard activeSince != nil, fps > 0 else { return }
        count += 1; fpsSum += fps; fpsMin = min(fpsMin, fps)
        p95s.append(p95)
        stutters += st
        thermalMax = max(thermalMax, thermal.rawValue)
        memoryPeak = max(memoryPeak, memoryMB)
        benchmark(fps: fps, p95: p95)
        if Date().timeIntervalSince(lastSaved) > 30 { save() }
    }

    /// 게임이 처음부터 다시 떴다: 지금까지의 세션을 저장하고 재시작 한 줄을 남긴다
    func noteRestart(_ kind: PerfRestart.Kind, memoryMB: Double, thermal: ProcessInfo.ThermalState, background: Bool) {
        save()
        let x = PerfRestart(at: Date(), kind: kind, afterSeconds: Date().timeIntervalSince(start).rounded(), memoryMB: memoryMB.rounded(),
                            thermal: thermal.rawValue, background: background, quality: quality,
                            device: PerfLogStore.deviceModel, os: PerfLogStore.osVersion, app: PerfLogStore.appVersion)
        PerfLogStore.shared.addRestart(x, id: dishID, title: title)
        NSLog("[Bowl] restart \(kind.rawValue) after=\(Int(x.afterSeconds))s mem=\(Int(x.memoryMB))MB thermal=\(x.thermal) bg=\(background)")
    }

    func thermalChanged(_ t: ProcessInfo.ThermalState) { thermalMax = max(thermalMax, t.rawValue) }

    /// 지금까지를 세션 한 줄로 저장 (같은 세션이면 덮어씀)
    func save() {
        lastSaved = Date()
        guard count > 0 else { return }
        let now = Date()
        let played = playSeconds + (activeSince.map { now.timeIntervalSince($0) } ?? 0)
        let s = PerfSession(start: start, end: now, playSeconds: played.rounded(), avgFps: fpsSum / Double(count),
                            minFps: fpsMin, p95ms: Self.percentile(p95s, 0.95), stutters: stutters, thermalMax: thermalMax,
                            memoryPeakMB: memoryPeak.rounded(), device: PerfLogStore.deviceModel, os: PerfLogStore.osVersion,
                            app: PerfLogStore.appVersion, quality: quality, samples: count, fpsCap: lowestCap)
        PerfLogStore.shared.upsert(s, id: dishID, title: title)
        NSLog("[Bowl] perf saved \(dishID) sessions=\(PerfLogStore.shared.record(for: dishID)?.sessions.count ?? 0) play=\(Int(played))s avg=\(String(format: "%.1f", s.avgFps))fps samples=\(count)")
    }

    private func benchmark(fps: Double, p95: Double) {
        guard benchPending else { return }
        let now = Date()
        if benchStart == nil { benchStart = now }
        benchFps.append(fps); benchP95.append(p95)
        guard now.timeIntervalSince(benchStart!) >= Self.benchmarkSeconds else { return }
        benchPending = false
        // 중간에 멈췄거나 샘플이 모자라면 다음 실행으로 미룬다
        guard !benchPaused, benchFps.count >= Self.benchmarkMinSamples else {
            NSLog("[Bowl] benchmark deferred paused=\(benchPaused) samples=\(benchFps.count)"); return
        }
        let avg = benchFps.reduce(0, +) / Double(benchFps.count)
        let p = Self.percentile(benchP95, 0.95)
        // 프레임 제한 중이면 60 기준으로 환산해 등급을 매긴다 (30 제한에서 30fps 는 "다 나온 것")
        let k = 60 / Double(fpsCap ?? 60)
        let b = PerfBenchmark(at: now, avgFps: avg, p95ms: p, quality: Quality.grade(avgFps: avg * k, p95: p / k), device: PerfLogStore.deviceModel)
        PerfLogStore.shared.setBenchmark(b, id: dishID, title: title)
        DishPrefsStore.shared.update(dishID) { $0.recommendedQuality = b.quality }
        NSLog("[Bowl] benchmark \(dishID) avg=\(String(format: "%.1f", avg)) p95=\(String(format: "%.1f", p))ms -> \(b.quality.label)")
        onBenchmark?(b)
    }

    static func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * q))]
    }
}

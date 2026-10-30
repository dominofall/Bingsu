import Foundation
import Combine
import UIKit

/// 온도계: 게임이 얼마나 시원하게 돌아가는지.
@MainActor
final class Thermometer: ObservableObject {
    enum Chill: String {
        case frost = "원활", cool = "양호", melting = "뜨거움", melted = "위험"
        var color: UIColor {
            switch self {
            case .frost: return UIColor(red: 0.43, green: 0.76, blue: 0.91, alpha: 1)
            case .cool: return UIColor(red: 0.18, green: 0.47, blue: 0.81, alpha: 1)
            case .melting: return UIColor(red: 0.91, green: 0.53, blue: 0.16, alpha: 1)
            case .melted: return UIColor(red: 0.83, green: 0.25, blue: 0.25, alpha: 1)
            }
        }
    }

    @Published var fps: Double = 0
    @Published var frameP95ms: Double = 0
    @Published var stutters: Int = 0
    /// 마지막 1초 샘플의 끊김 수 (stutters 는 누적)
    private(set) var lastStutters = 0
    @Published var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var memoryMB: Double = 0

    /// 소리 진단 (설정 › 게임 중 › 소리 문제 진단): 게임의 AudioContext 상태. 게임이 보낸 값이라 범위를 검증한다
    struct AudioStat: Equatable {
        var sampleRate: Double
        var state: String
        var latencyMs: Double
        /// 소리 시계(초). running 인데 멈춰 있으면 출력이 죽은 것
        var clock: Double?
        /// 마지막 디코딩에 걸린 시간·그 뒤 지난 시간 (없으면 nil)
        var decodeMs: Double?
        var decodeAgoSec: Double?

        init?(_ any: Any?) {
            guard let d = any as? [String: Any],
                  let sr = (d["sr"] as? NSNumber)?.doubleValue, sr.isFinite, sr >= 3000, sr <= 768_000,
                  let st = d["state"] as? String, ["running", "suspended", "closed", "interrupted"].contains(st),
                  let lat = (d["lat"] as? NSNumber)?.doubleValue, lat.isFinite, lat >= 0, lat <= 10 else { return nil }
            sampleRate = sr; state = st; latencyMs = lat * 1000
            if let t = (d["t"] as? NSNumber)?.doubleValue, t.isFinite, t >= 0, t <= 1e7 { clock = t }
            if let m = (d["decMs"] as? NSNumber)?.doubleValue, m.isFinite, m >= 0, m <= 600_000,
               let a = (d["decAgo"] as? NSNumber)?.doubleValue, a.isFinite, a >= 0, a <= 86_400_000 {
                decodeMs = m; decodeAgoSec = a / 1000
            }
        }
    }
    @Published var audio: AudioStat?

    private var cancellables: Set<AnyCancellable> = []
    private var history: [Double] = []
    /// 샘플마다 부른다 (성능 기록기 `PerfRecorder`)
    var onSample: ((Thermometer) -> Void)?

    init() {
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.thermal = ProcessInfo.processInfo.thermalState }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
            .store(in: &cancellables)
    }

    /// 웹뷰에서 1초마다 보내는 샘플
    func ingest(fps: Double, p95: Double, stutters: Int, audio: AudioStat? = nil) {
        self.fps = fps
        if self.audio != audio { self.audio = audio }
        self.frameP95ms = p95
        self.stutters += stutters
        lastStutters = stutters
        history.append(fps); if history.count > 60 { history.removeFirst() }
        memoryMB = Double(Self.residentMemory()) / 1_048_576
        onSample?(self)
    }

    /// 지금 목표 프레임 수 (프레임 제한이 걸려 있으면 그 값). 상태 판정 기준을 맞춘다
    var fpsTarget: Double = 60

    var chill: Chill { Self.chill(fps: fps, p95: frameP95ms, thermal: thermal, target: fpsTarget) }

    /// 상태 규칙 (7.2). HUD 와 세션 요약이 같이 쓴다.
    /// `target`: 목표 fps (60, 프레임 제한이면 30). 기준을 목표에 비례해 맞춘다
    nonisolated static func chill(fps: Double, p95: Double, thermal: ProcessInfo.ThermalState, target: Double = 60) -> Chill {
        switch thermal {
        case .critical: return .melted
        case .serious: return .melting
        default: break
        }
        let k = target / 60
        if fps > 0 && (fps < 45 * k || p95 > 33 / k) { return .melting }
        if fps > 0 && fps < 58 * k { return .cool }
        return .frost
    }

    var fpsHistory: [Double] { history }

    private static func residentMemory() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

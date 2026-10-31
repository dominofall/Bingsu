#if DEBUG
import Foundation

/// 디버그 빌드 전용 측정 기록 (빌드 23 포켓로그 멈춤·다시 불러옴 원인 찾기).
/// `Documents/Diag/<게임>-<시각>.log` 에 한 줄씩: 연 뒤 초, 앱 메모리, 발열 단계, 내용.
/// 웹 콘텐츠 프로세스 메모리는 앱에서 못 읽으므로 페이지 쪽 수치(WebGL 텍스처·오디오 디코딩 등)를 함께 남긴다.
final class DiagLog {
    private let handle: FileHandle
    private let start = Date()
    private let queue = DispatchQueue(label: "bingsu.diag")

    init?(dishID: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Diag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "MMdd-HHmmss"
        let safe = dishID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        let url = dir.appendingPathComponent(String(safe) + "-" + f.string(from: Date()) + ".log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        write("open \(dishID)")
    }

    deinit { try? handle.close() }

    func write(_ s: String) {
        let t = Date().timeIntervalSince(start)
        let mb = Double(Thermometer.residentMemory()) / 1_048_576
        let th = ProcessInfo.processInfo.thermalState.rawValue
        let line = String(format: "%8.1f %4.0fMB th%d ", t, mb, th) + s + "\n"
        queue.async { [handle] in try? handle.write(contentsOf: Data(line.utf8)) }
    }
}
#endif

import Foundation
import ZIPFoundation

/// 압축 해제. 압축 파일을 신뢰하지 않는다:
/// - 항목 경로를 정규화해 대상 폴더 밖이면 거부 (zip slip)
/// - 심볼릭 링크 항목 거부
/// - 풀기 전에 선언된 크기 합계와 여유 공간 검사 (zip bomb)
/// - 풀면서 실제로 나온 바이트가 선언 크기를 넘으면 멈추고, 다 푼 뒤 크기·CRC32 를 선언값과 맞춰 본다
enum SafeUnzip {
    enum UnzipError: LocalizedError {
        case notAZip, truncated(UInt64), corrupted, empty
        case tooLarge(UInt64), tooManyEntries, notEnoughSpace(needed: UInt64, free: UInt64), unsafePath(String)
        var errorDescription: String? {
            switch self {
            case .notAZip: return "zip 파일이 아니에요"
            case .truncated(let n): return "내려받다가 끊긴 것 같아요 · 파일 크기 \(SafeUnzip.megabytes(n))"
            case .corrupted: return "압축 파일이 손상됐어요 · 내려받다가 끊긴 것 같아요"
            case .empty: return "압축 파일 안에 아무것도 없어요"
            // 크기는 압축 파일이 선언한 값이라 Int64 를 넘을 수 있다 → clamping (그냥 Int64(n) 이면 앱이 멈춤)
            case .tooLarge: return "압축을 풀면 \(SafeUnzip.bytes(SafeUnzip.maxUncompressedBytes))보다 커서 가져올 수 없어요."
            case .notEnoughSpace(let n, let f): return "저장 공간이 부족해요. 필요 \(SafeUnzip.bytes(n)), 남은 공간 \(SafeUnzip.bytes(f))"
            case .tooManyEntries: return "압축 파일 안에 파일이 너무 많아요 (\(SafeUnzip.maxEntries)개까지)"
            case .unsafePath(let p): return "압축 파일 안에 이상한 경로가 있어요: \(p.prefix(80))"
            }
        }
    }

    static let maxUncompressedBytes: UInt64 = 8 * 1024 * 1024 * 1024 // 8 GB
    /// 빈 파일·폴더만 잔뜩 든 압축도 거른다 (크기 합계로는 안 걸림)
    static let maxEntries = 200_000
    static let maxPathBytes = 1024

    static func freeSpace(at url: URL) -> UInt64 {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// zip 을 destination 아래로 푼다
    static func unzip(_ zipURL: URL, to destination: URL, progress: (Double) -> Void, isCancelled: () -> Bool = { false }) throws {
        guard let archive = try? Archive(url: zipURL, accessMode: .read) else { throw classifyOpenFailure(zipURL) }
        let fm = FileManager.default
        let destBase = destination.standardizedFileURL

        // 1) 사전 검사
        var total: UInt64 = 0
        var plan: [(Entry, URL)] = []
        var count = 0
        for entry in archive {
            count += 1
            guard count <= maxEntries else { throw UnzipError.tooManyEntries }
            if count % 1000 == 0, isCancelled() { throw CocoaError(.userCancelled) }
            let raw = entry.path
            if raw.utf8.count > maxPathBytes { throw UnzipError.unsafePath(raw) }
            if entry.type == .symlink { throw UnzipError.unsafePath(raw) }
            if raw.contains("\0") || raw.hasPrefix("/") || raw.contains("\\") || raw.contains(":") { throw UnzipError.unsafePath(raw) }
            let comps = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if comps.contains("..") { throw UnzipError.unsafePath(raw) }
            if comps.isEmpty { continue }
            if comps.contains(where: { $0 == "__MACOSX" || $0 == ".DS_Store" }) { continue }
            let target = destBase.appendingPathComponent(comps.joined(separator: "/")).standardizedFileURL
            guard target.path.hasPrefix(destBase.path + "/") else { throw UnzipError.unsafePath(raw) }
            let (sum, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= maxUncompressedBytes else { throw UnzipError.tooLarge(overflow ? .max : sum) }
            total = sum
            plan.append((entry, target))
        }
        guard !plan.isEmpty else { throw UnzipError.empty }
        let free = freeSpace(at: destination.deletingLastPathComponent())
        if free > 0, total + 200 * 1024 * 1024 > free { throw UnzipError.notEnoughSpace(needed: total, free: free) }

        // 2) 풀기
        try fm.createDirectory(at: destBase, withIntermediateDirectories: true)
        var done: UInt64 = 0
        let denom = Double(max(total, 1))
        for (entry, target) in plan {
            if isCancelled() { throw CocoaError(.userCancelled) }
            if entry.type == .directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true); continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try? fm.removeItem(at: target)
            let size = entry.uncompressedSize
            guard fm.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let out = try FileHandle(forWritingTo: target)
            var written: UInt64 = 0
            do {
                defer { try? out.close() }
                // 선언 크기를 넘는 순간 멈춘다: 헤더를 속인 압축 폭탄이 공간을 다 쓰지 못하게
                let crc = try archive.extract(entry, skipCRC32: false, progress: nil) { chunk in
                    if isCancelled() { throw CocoaError(.userCancelled) } // 큰 파일 하나를 푸는 중에도 취소에 반응
                    written += UInt64(chunk.count)
                    guard written <= size else { throw UnzipError.corrupted }
                    try out.write(contentsOf: chunk)
                }
                guard written == size, crc == entry.checksum else { throw UnzipError.corrupted }
            } catch let e as UnzipError {
                throw e
            } catch {
                // 파일 시스템 오류(공간 부족 등)는 그대로, ZIPFoundation 오류(압축 데이터)는 손상으로
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain { throw error }
                throw UnzipError.corrupted
            }
            done += size
            progress(Double(done) / denom)
        }
        progress(1)
    }

    /// 열지 못한 이유 가리기: 앞 4바이트가 zip 서명(PK\u{3}\u{4} 또는 빈 zip PK\u{5}\u{6})이 아니면 zip 이 아니고,
    /// 서명은 맞는데 끝의 중앙 디렉터리를 못 찾으면 내려받다 잘린 것이다.
    static func classifyOpenFailure(_ url: URL) -> UnzipError {
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let fh = try? FileHandle(forReadingFrom: url) else { return .notAZip }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 4)) ?? Data()
        let local: [UInt8] = [0x50, 0x4B, 0x03, 0x04], emptyEnd: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard Array(head) == local || Array(head) == emptyEnd else { return .notAZip }
        return .truncated(size)
    }

    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }

    static func megabytes(_ n: UInt64) -> String {
        let mb = Double(n) / 1_000_000
        return mb < 10 ? String(format: "%.1f MB", mb) : String(format: "%.0f MB", mb)
    }
}

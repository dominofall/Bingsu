import Foundation

/// Electron asar 읽기 전용 파서.
/// 포맷: [u32 LE = 4][u32 LE headerPickleSize][u32 LE headerPickleSize-4 (사실상)][u32 LE jsonLen][json][파일 데이터...]
/// 파일 데이터 시작 오프셋 = 8 + headerPickleSize. 각 항목은 {"size": n, "offset": "문자열 숫자"}.
/// 보안: 모든 offset+size 가 파일 범위 안인지(넘침 포함) 확인하고, 음수·소수 크기와 지나친 항목 수·합계는 거부하며,
/// "link" 항목(심볼릭 링크)은 풀지 않는다.
struct AsarArchive {
    struct Entry {
        let path: String        // 아카이브 안 상대 경로 (슬래시 구분)
        let offset: UInt64
        let size: UInt64
        let unpacked: Bool
    }

    let url: URL
    let entries: [Entry]
    let dataBase: UInt64
    let fileLength: UInt64

    enum AsarError: LocalizedError {
        case badHeader, badJSON, outOfRange(String), tooLarge
        var errorDescription: String? {
            switch self {
            case .badHeader: return "asar 헤더를 읽을 수 없어요."
            case .badJSON: return "asar 목록이 손상됐어요."
            case .outOfRange(let p): return "asar 항목이 파일 범위를 벗어났어요: \(p)"
            case .tooLarge: return "asar 안 파일이 너무 많거나 커요."
            }
        }
    }

    static let maxEntries = 200_000
    static let maxHeaderBytes = 64 * 1024 * 1024 // 읽기 전에 거른다 (JSON 을 통째로 메모리에 올리므로)
    static let maxDepth = 64
    static let maxTotalBytes: UInt64 = SafeUnzip.maxUncompressedBytes

    /// JSON 숫자를 0 이상의 정수로. 음수·소수·불리언은 nil
    private static func whole(_ v: Any?) -> UInt64? {
        if let s = v as? String { return UInt64(s) }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d >= 0, d == d.rounded(), d < 9.0e18 else { return nil }
        return n.uint64Value
    }

    init(url: URL) throws {
        self.url = url
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        fileLength = try fh.seekToEnd()
        try fh.seek(toOffset: 0)
        guard let head = try fh.read(upToCount: 16), head.count == 16 else { throw AsarError.badHeader }
        func u32(_ i: Int) -> UInt32 { head.subdata(in: i..<(i + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        guard u32(0) == 4 else { throw AsarError.badHeader }
        let headerPickleSize = UInt64(u32(4))
        let jsonLen = Int(u32(12))
        guard jsonLen > 0, UInt64(jsonLen) + 16 <= fileLength, UInt64(jsonLen) <= headerPickleSize else { throw AsarError.badHeader }
        guard jsonLen <= Self.maxHeaderBytes else { throw AsarError.tooLarge }
        guard let json = try fh.read(upToCount: jsonLen), json.count == jsonLen,
              let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw AsarError.badJSON }
        let dataBase = 8 + headerPickleSize // headerPickleSize 는 u32 라 넘치지 않는다
        let fileLength = self.fileLength
        self.dataBase = dataBase

        var out: [Entry] = []
        var total: UInt64 = 0
        var nodes = 0
        func walk(_ node: [String: Any], prefix: String, depth: Int) throws {
            guard let files = node["files"] as? [String: Any] else { return }
            guard depth <= Self.maxDepth else { throw AsarError.tooLarge }
            for (name, raw) in files {
                nodes += 1
                guard nodes <= Self.maxEntries else { throw AsarError.tooLarge }
                guard let item = raw as? [String: Any] else { continue }
                // 경로 안전성: 이름에 슬래시·역슬래시·NUL·.. 금지
                guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\0"), name != "..", name != "." else { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if item["files"] != nil { try walk(item, prefix: path, depth: depth + 1); continue }
                if item["link"] != nil { continue } // 심볼릭 링크는 풀지 않는다
                guard let size = item["size"] == nil ? 0 : Self.whole(item["size"]) else { throw AsarError.outOfRange(path) }
                let unpacked = (item["unpacked"] as? Bool) ?? false
                let offset: UInt64
                if item["offset"] == nil { offset = 0 }
                else if let v = Self.whole(item["offset"]) { offset = v }
                else { throw AsarError.outOfRange(path) }
                if !unpacked {
                    let (start, o1) = dataBase.addingReportingOverflow(offset)
                    let (end, o2) = start.addingReportingOverflow(size)
                    guard !o1, !o2, end <= fileLength else { throw AsarError.outOfRange(path) }
                }
                let (sum, o3) = total.addingReportingOverflow(size)
                guard !o3, sum <= Self.maxTotalBytes, out.count < Self.maxEntries else { throw AsarError.tooLarge }
                total = sum
                out.append(Entry(path: path, offset: offset, size: size, unpacked: unpacked))
            }
        }
        try walk(root, prefix: "", depth: 0)
        entries = out
    }

    var totalBytes: UInt64 { entries.reduce(0) { $0 + $1.size } }

    /// 모든 항목을 `destination/` 아래로 푼다. unpacked 항목은 `<asar>.unpacked/` 옆 폴더에서 복사한다.
    func extract(to destination: URL, progress: (Double) -> Void, isCancelled: () -> Bool = { false }) throws {
        let fm = FileManager.default
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let unpackedDir = url.deletingPathExtension().appendingPathExtension("asar.unpacked")
        let total = Double(max(totalBytes, 1))
        var done: UInt64 = 0
        let chunk = 4 * 1024 * 1024
        let destBase = destination.standardizedFileURL

        for e in entries {
            if isCancelled() { throw CocoaError(.userCancelled) }
            let target = destBase.appendingPathComponent(e.path).standardizedFileURL
            guard target.path.hasPrefix(destBase.path + "/") else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if e.unpacked {
                // asar 밖 파일: 일반 파일이고 실제 크기가 목록의 크기와 같을 때만 복사한다 (링크·크기 속임 거부)
                let src = unpackedDir.appendingPathComponent(e.path)
                if let a = try? fm.attributesOfItem(atPath: src.path),
                   a[.type] as? FileAttributeType == .typeRegular,
                   (a[.size] as? NSNumber)?.uint64Value == e.size {
                    _ = try? fm.removeItem(at: target); try fm.copyItem(at: src, to: target)
                } else if fm.fileExists(atPath: src.path) || (try? fm.destinationOfSymbolicLink(atPath: src.path)) != nil {
                    throw AsarError.outOfRange(e.path)
                }
                done += e.size; progress(Double(done) / total); continue
            }
            fm.createFile(atPath: target.path, contents: nil)
            let out = try FileHandle(forWritingTo: target)
            try fh.seek(toOffset: dataBase + e.offset)
            var remaining = Int(e.size)
            while remaining > 0 {
                guard let data = try fh.read(upToCount: min(chunk, remaining)), !data.isEmpty else { break }
                try out.write(contentsOf: data)
                remaining -= data.count
                done += UInt64(data.count)
                progress(Double(done) / total)
            }
            try out.close()
        }
    }
}

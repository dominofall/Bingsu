import Foundation
import ZIPFoundation

/// 압축 해제. 압축 파일을 신뢰하지 않는다:
/// - 항목 경로를 정규화해 대상 폴더 밖이면 거부 (zip slip)
/// - 심볼릭 링크 항목 거부
/// - 풀기 전에 선언된 크기 합계와 여유 공간 검사 (zip bomb)
/// - 풀면서 실제로 나온 바이트가 선언 크기를 넘으면 멈추고, 다 푼 뒤 크기·CRC32 를 선언값과 맞춰 본다
/// - 같은 경로의 파일이 둘이거나 파일과 폴더 이름이 겹치면 거부 (앞 항목을 덮어써 풀린 결과가 목록과 달라진다).
///   단 크기·CRC32 까지 같은 중복 파일은 뒤 항목을 건너뛴다
/// - 항목 이름은 UTF-8 표시가 없어도 UTF-8·Shift-JIS·CP949 로 풀고, 맥의 `\ddd` 이스케이프를 되돌린다 (entryName·safeComponents)
enum SafeUnzip {
    /// 항목 경로가 앞 항목과 겹치는지 본다. APFS 는 유니코드 정규화만 다른 이름을 같게 보므로 NFC 로 맞춘다.
    /// 대소문자는 구분한다: iOS 기기의 파일 시스템이 구분하고, 대소문자만 다른 폴더가 든 게임도 있다
    struct PathLedger {
        /// 파일 경로 → 선언된 크기·CRC32 (모르면 nil: 겹치면 늘 다른 파일로 본다)
        private var files: [String: FileID?] = [:]
        private var dirs = Set<String>()

        struct FileID: Equatable { let size: UInt64; let crc: UInt32 }

        enum Outcome: Equatable {
            case added
            /// 앞 항목과 경로·크기·CRC32 가 같은 파일: 건너뛰어도 풀린 결과가 목록과 같다.
            /// 윈도우에서 만든 zip 은 코드 페이지에 없는 글자를 비슷한 글자로 바꿔 적어(é → e) 이름만 다르던 두 파일이 같은 경로가 된다
            case sameFile
            /// 같은 경로인데 내용이 다른 파일
            case differentFile
            /// 파일과 폴더 이름이 겹침
            case clash
        }

        /// 겹치면 false (같은 내용의 중복 파일도 false: 크기·CRC 를 모르므로)
        mutating func add(_ comps: [String], isDirectory: Bool) -> Bool {
            add(comps, isDirectory: isDirectory, id: nil) == .added
        }

        mutating func add(_ comps: [String], isDirectory: Bool, id: FileID?) -> Outcome {
            let names = comps.map(\.precomposedStringWithCanonicalMapping)
            for n in 1..<max(names.count, 1) {
                let parent = names[0..<n].joined(separator: "/")
                if files[parent] != nil { return .clash }
                dirs.insert(parent)
            }
            let path = names.joined(separator: "/")
            if isDirectory {
                if files[path] != nil { return .clash }
                dirs.insert(path)
                return .added
            }
            if dirs.contains(path) { return .clash }
            if let first = files[path] {
                if let first, let id, first == id { return .sameFile }
                return .differentFile
            }
            files[path] = .some(id)
            return .added
        }
    }

    enum UnzipError: LocalizedError {
        case notAZip, truncated(UInt64), corrupted, empty
        case tooLarge(UInt64), tooManyEntries, notEnoughSpace(needed: UInt64, free: UInt64), unsafePath(String)
        case duplicateName(String)
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
            case .duplicateName(let p): return "압축 파일 안에 같은 이름의 파일이 두 개 있어요 (내용이 달라요): \(p.prefix(80))"
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
        var ledger = PathLedger()
        var count = 0
        let central = centralNames(zipURL)
        for entry in archive {
            count += 1
            guard count <= maxEntries else { throw UnzipError.tooManyEntries }
            if count % 1000 == 0, isCancelled() { throw CocoaError(.userCancelled) }
            let bytes = nameBytes(entry)
            // 같은 순서의 중앙 디렉터리 항목이 이름 바이트·CRC 까지 같을 때만 그 Unicode Path 이름을 쓴다
            var unicode: String?
            if let central, count <= central.count, central[count - 1].raw == bytes, central[count - 1].crc == entry.checksum {
                unicode = central[count - 1].unicode
            }
            let raw = unicode ?? decodeName(bytes)
            if raw.utf8.count > maxPathBytes { throw UnzipError.unsafePath(raw) }
            if entry.type == .symlink { throw UnzipError.unsafePath(raw) }
            // 맥 부속 파일은 이름이 어떻든 풀지 않으니 이름 검사보다 먼저 건너뛴다
            let rawComps = raw.split(separator: "/", omittingEmptySubsequences: true)
            if rawComps.contains(where: { $0 == "__MACOSX" || $0 == ".DS_Store" }) { continue }
            guard let comps = safeComponents(raw) else { throw UnzipError.unsafePath(raw) }
            if comps.isEmpty { continue }
            if comps.joined(separator: "/").utf8.count > maxPathBytes { throw UnzipError.unsafePath(raw) }
            let target = destBase.appendingPathComponent(comps.joined(separator: "/")).standardizedFileURL
            guard target.path.hasPrefix(destBase.path + "/") else { throw UnzipError.unsafePath(raw) }
            let isDir = entry.type == .directory
            switch ledger.add(comps, isDirectory: isDir, id: isDir ? nil : .init(size: entry.uncompressedSize, crc: entry.checksum)) {
            case .added: break
            case .sameFile: continue // 앞 항목만 푼다 (풀 때 그 항목의 크기·CRC 를 확인한다)
            case .differentFile: throw UnzipError.duplicateName(comps.joined(separator: "/"))
            case .clash: throw UnzipError.unsafePath(raw)
            }
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

    // MARK: 항목 이름

    /// CP437 은 256 바이트가 모두 서로 다른 글자라 왕복하면 원래 바이트가 나온다 (ZIPFoundation 은 이름 바이트를 공개하지 않는다)
    static let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    /// 압축 파일에 적힌 항목 이름 바이트
    static func nameBytes(_ entry: Entry) -> Data {
        entry.path(using: cp437).data(using: cp437) ?? Data(entry.path.utf8)
    }

    /// 항목 이름. UTF-8 표시(bit 11)가 없는 zip 이 많다: 맥에서 만든 zip 은 UTF-8, 한국어 윈도우에서 만든 zip 은 CP949,
    /// 일본어 윈도우는 Shift-JIS 로 적는다. ZIPFoundation 은 표시가 없으면 CP437 로 풀어 한글이 깨지므로
    /// 바이트를 직접 UTF-8 → Shift-JIS(일본어로 보이면) → CP949 → Shift-JIS → CP437 순으로 푼다 (ini 와 같은 규칙, RGSSProbe)
    static func entryName(_ entry: Entry) -> String { decodeName(nameBytes(entry)) }

    // MARK: Info-ZIP Unicode Path (0x7075)

    /// 중앙 디렉터리 항목 하나: 이름 바이트·CRC32 와, 맞는 Unicode Path 확장 영역이 있으면 그 이름
    struct CentralName { let raw: Data; let crc: UInt32; let unicode: String? }

    /// 윈도우 압축 프로그램은 코드 페이지(CP949 등)로 못 적는 글자를 비슷한 글자로 바꿔 이름에 적고(é → e),
    /// 원래 이름은 확장 영역 0x7075 에 UTF-8 로 따로 넣는다. ZIPFoundation 은 확장 영역을 공개하지 않아 중앙 디렉터리를 직접 읽는다.
    /// 항목 순서대로 돌려준다 (ZIPFoundation 도 같은 순서로 돈다). 읽지 못하면 nil — 그때는 이름 바이트만 쓴다
    static func centralNames(_ url: URL) -> [CentralName]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size >= 22 else { return nil }
        let tailLen = min(size, 22 + 65_535)
        guard (try? fh.seek(toOffset: size - tailLen)) != nil, let tailData = try? fh.read(upToCount: Int(tailLen)) else { return nil }
        let tail = [UInt8](tailData)
        func le(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64? {
            guard o >= 0, o + n <= b.count else { return nil }
            var v: UInt64 = 0
            for i in (0..<n).reversed() { v = v << 8 | UInt64(b[o + i]) }
            return v
        }
        // 끝의 디렉터리 끝 표지(PK 5 6)
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 5, tail[i + 3] == 6 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0, var count = le(tail, eocd + 10, 2), var cdSize = le(tail, eocd + 12, 4), var cdOffset = le(tail, eocd + 16, 4)
        else { return nil }
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64: 표지 앞 20바이트의 위치 표(PK 6 7)가 ZIP64 디렉터리 끝(PK 6 6)을 가리킨다
            guard le(tail, eocd - 20, 4) == 0x0706_4B50, let z64 = le(tail, eocd - 20 + 8, 8), z64 < size,
                  (try? fh.seek(toOffset: z64)) != nil, let rec = try? fh.read(upToCount: 56) else { return nil }
            let r = [UInt8](rec)
            guard le(r, 0, 4) == 0x0606_4B50, let c = le(r, 32, 8), let s = le(r, 40, 8), let o = le(r, 48, 8) else { return nil }
            (count, cdSize, cdOffset) = (c, s, o)
        }
        guard cdSize <= 512 * 1024 * 1024, cdOffset <= size, cdSize <= size - cdOffset, count <= UInt64(maxEntries),
              (try? fh.seek(toOffset: cdOffset)) != nil, let cdData = try? fh.read(upToCount: Int(cdSize)) else { return nil }
        let cd = [UInt8](cdData)
        var out: [CentralName] = []
        out.reserveCapacity(Int(count))
        var p = 0
        while out.count < Int(count) {
            guard le(cd, p, 4) == 0x0201_4B50, let flags = le(cd, p + 8, 2), let crc = le(cd, p + 16, 4),
                  let nameLen = le(cd, p + 28, 2), let extraLen = le(cd, p + 30, 2), let commentLen = le(cd, p + 32, 2)
            else { return nil }
            let nameStart = p + 46, extraStart = nameStart + Int(nameLen), next = extraStart + Int(extraLen) + Int(commentLen)
            guard next <= cd.count else { return nil }
            let raw = Data(cd[nameStart..<extraStart])
            // UTF-8 표시가 있는 항목은 이름 바이트가 이미 UTF-8 이다
            let unicode = flags & 0x800 != 0 ? nil : unicodePath(extra: Data(cd[extraStart..<extraStart + Int(extraLen)]), nameBytes: raw)
            out.append(CentralName(raw: raw, crc: UInt32(crc), unicode: unicode))
            p = next
        }
        return out
    }

    /// 확장 영역들에서 0x7075 를 찾아 이름을 꺼낸다. 형식: 버전(1) + 원래 이름 바이트의 CRC32 + UTF-8 이름.
    /// 버전이 1이 아니거나 CRC 가 맞지 않으면(나중에 이름만 바뀐 항목) 쓰지 않는다
    static func unicodePath(extra: Data, nameBytes: Data) -> String? {
        let b = [UInt8](extra)
        var p = 0
        while p + 4 <= b.count {
            let id = Int(b[p]) | Int(b[p + 1]) << 8, len = Int(b[p + 2]) | Int(b[p + 3]) << 8
            let body = p + 4
            guard body + len <= b.count else { return nil }
            if id == 0x7075 {
                guard len >= 6, b[body] == 1 else { return nil }
                let crc = UInt32(b[body + 1]) | UInt32(b[body + 2]) << 8 | UInt32(b[body + 3]) << 16 | UInt32(b[body + 4]) << 24
                guard crc == nameBytes.crc32(checksum: 0) else { return nil }
                guard let s = String(data: Data(b[(body + 5)..<(body + len)]), encoding: .utf8), !s.isEmpty else { return nil }
                return s
            }
            p = body + len
        }
        return nil
    }

    static func decodeName(_ bytes: Data) -> String {
        RGSSProbe.decodeText(bytes) ?? String(data: bytes, encoding: cp437) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// 경로를 안전한 조각으로 나눈다. 위험하면 nil.
    /// 맥은 UTF-8 이 아닌 이름 바이트를 `\` + 8진수 3자리로 바꿔 적는다(예: CP949 이름 → `\237W\272\361…`).
    /// 그런 조각은 바이트로 되돌려 다시 풀고, 되돌린 뒤에도 `\` 가 남으면 윈도우식 구분자(`..\..\x`)로 보고 거부한다.
    /// 조각은 NFC 로 맞춘다: 맥 zip 의 한글은 풀어 쓴 자모(NFD)인데 게임 데이터는 NFC 로 이름을 부른다
    static func safeComponents(_ name: String) -> [String]? {
        if name.contains("\0") || name.hasPrefix("/") || name.contains(":") { return nil }
        var out: [String] = []
        for part in name.split(separator: "/", omittingEmptySubsequences: true) {
            var comp = String(part)
            if comp.contains("\\") {
                guard let restored = unescapeOctal(comp) else { return nil }
                comp = restored
            }
            if comp == ".." { return nil }
            out.append(comp.precomposedStringWithCanonicalMapping)
        }
        return out
    }

    /// `\ddd`(첫 자리 0-3) 를 바이트로 되돌려 다시 푼다. 이스케이프가 아닌 `\` 가 있거나 결과에 구분자·특수 글자가 생기면 nil
    static func unescapeOctal(_ comp: String) -> String? {
        let src = Array(comp.utf8)
        var bytes: [UInt8] = []
        var i = 0
        func octal(_ b: UInt8, max: UInt8) -> UInt8? { (0x30...max).contains(b) ? b - 0x30 : nil }
        while i < src.count {
            if src[i] == 0x5C {
                guard i + 3 < src.count,
                      let a = octal(src[i + 1], max: 0x33), let b = octal(src[i + 2], max: 0x37), let c = octal(src[i + 3], max: 0x37)
                else { return nil }
                bytes.append(a << 6 | b << 3 | c)
                i += 4
            } else {
                bytes.append(src[i]); i += 1
            }
        }
        let s = decodeName(Data(bytes))
        if s.isEmpty || s == "." || s == ".." { return nil }
        if s.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || $0 == "\0" }) { return nil }
        return s
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

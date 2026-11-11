import Foundation

/// 영수증: 가져올 때 게임 폴더에 적어 둔 `bingsu.json` 에서 사람에게 보여 줄 기록만 읽는다.
/// 파일은 믿지 않는다. 너무 크면 읽지 않고, 글자는 줄바꿈·제어 문자를 빼고 길이를 자르고, 이상한 날짜는 없음으로 본다.
/// 각 값이 nil 이면 "기록이 없다"(키가 없거나 읽을 수 없음)는 뜻이다.
struct Receipt: Equatable, Sendable {
    var title: String?
    /// nil: 키가 없음(예전 게임). "": 가져올 때 버전을 몰랐음.
    var version: String?
    /// 가져온 파일 이름 (zip 이름 등)
    var sourceName: String?
    var importedAt: Date?

    /// 기록 파일을 이 크기까지만 읽는다 (게임 엔진 정보가 같이 들어 있어 몇 KB 는 된다)
    static let maxFileBytes = 1 << 20
    static let maxTextLength = 120
    static let maxVersionLength = 40

    /// 게임 폴더의 `bingsu.json` 을 읽는다. 없거나 읽을 수 없으면 빈 영수증.
    static func read(folder: URL) -> Receipt {
        // Delivery.manifestName 과 같은 이름 (그쪽은 메인 액터라 백그라운드에서 읽으려고 따로 적는다)
        let url = folder.appendingPathComponent("bingsu.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileBytes,
              let data = try? Data(contentsOf: url) else { return Receipt() }
        return parse(data)
    }

    /// 순수 함수: JSON 바이트 → 영수증. `now` 는 시험용.
    static func parse(_ data: Data, now: Date = Date()) -> Receipt {
        guard data.count <= maxFileBytes,
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Receipt() }
        var r = Receipt()
        r.title = clean(m["title"], limit: maxTextLength).flatMap { $0.isEmpty ? nil : $0 }
        // 버전은 빈 글자도 뜻이 있다 (가져올 때 몰랐음) → 그대로 둔다
        r.version = clean(m["version"], limit: maxVersionLength)
        r.sourceName = clean(m["sourceName"], limit: maxTextLength).flatMap { $0.isEmpty ? nil : $0 }
        r.importedAt = date(m["importedAt"], now: now)
        return r
    }

    /// 글자만 받는다. 줄바꿈·제어 문자는 빼고, 앞뒤 공백을 지우고, 길면 잘라 "…" 을 붙인다.
    static func clean(_ value: Any?, limit: Int) -> String? {
        guard let s = value as? String else { return nil }
        let scalars = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        let t = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }

    /// ISO8601 날짜. 빙수가 나오기 전(2024년 이전)이거나 내일보다 뒤면 믿지 않는다.
    static func date(_ value: Any?, now: Date) -> Date? {
        guard let s = value as? String, s.count <= 40 else { return nil }
        let f = ISO8601DateFormatter()
        var d = f.date(from: s)
        if d == nil { f.formatOptions.insert(.withFractionalSeconds); d = f.date(from: s) }
        guard let d, d >= Date(timeIntervalSince1970: 1_704_067_200), d <= now.addingTimeInterval(86_400) else { return nil }
        return d
    }

    /// "2026년 11월 11일 오후 3:04" (기기 언어와 상관없이 한국어)
    static func dateText(_ d: Date) -> String {
        d.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "ko_KR")))
    }
}

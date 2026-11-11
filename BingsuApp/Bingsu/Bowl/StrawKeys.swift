import Foundation

/// 터치 조작의 키보드 키 (명세 docs/engines/IMPLEMENTATION-touch.md §7, §10).
/// 게임 코드에서 듣는 키를 글자로 모으고(판별), 키 줄에 띄울 키를 고른다. 키는 `KeyboardEvent.code` 글자로 다룬다.
enum StrawKeys {
    /// 아는 키 (`KeyboardEvent.code`). 이 밖의 글자는 받지 않는다 (파일·게임 코드를 믿지 않음)
    static let known: Set<String> = {
        var s: Set<String> = ["Escape", "Enter", "Space", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
                              "Tab", "Backspace", "Delete", "Home", "End", "PageUp", "PageDown",
                              "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight"]
        for c in UnicodeScalar("A").value...UnicodeScalar("Z").value { s.insert("Key" + String(UnicodeScalar(c)!)) }
        for d in 0...9 { s.insert("Digit\(d)") }
        for f in 1...12 { s.insert("F\(f)") }
        return s
    }()

    /// `e.key` 글자 → code. 글자 하나(a, A, 1)는 KeyA·Digit1
    static func code(forKey raw: String) -> String? {
        switch raw {
        case "Escape", "Esc": return "Escape"
        case "Enter": return "Enter"
        case " ", "Spacebar", "Space": return "Space"
        case "ArrowUp", "Up": return "ArrowUp"
        case "ArrowDown", "Down": return "ArrowDown"
        case "ArrowLeft", "Left": return "ArrowLeft"
        case "ArrowRight", "Right": return "ArrowRight"
        case "Tab": return "Tab"
        case "Backspace": return "Backspace"
        case "Delete", "Del": return "Delete"
        case "Home": return "Home"
        case "End": return "End"
        case "PageUp": return "PageUp"
        case "PageDown": return "PageDown"
        case "Shift": return "ShiftLeft"
        case "Control": return "ControlLeft"
        default: break
        }
        if raw.count == 1, let c = raw.unicodeScalars.first {
            if CharacterSet.decimalDigits.contains(c), c.isASCII { return "Digit" + raw }
            if c.isASCII, CharacterSet.letters.contains(c) { return "Key" + raw.uppercased() }
        }
        if raw.hasPrefix("F"), let n = Int(raw.dropFirst()), (1...12).contains(n) { return "F\(n)" }
        return nil
    }

    /// `keyCode`·`which` 숫자 → code
    static func code(forKeyCode n: Int) -> String? {
        switch n {
        case 27: return "Escape"
        case 13: return "Enter"
        case 32: return "Space"
        case 37: return "ArrowLeft"
        case 38: return "ArrowUp"
        case 39: return "ArrowRight"
        case 40: return "ArrowDown"
        case 9: return "Tab"
        case 8: return "Backspace"
        case 46: return "Delete"
        case 36: return "Home"
        case 35: return "End"
        case 33: return "PageUp"
        case 34: return "PageDown"
        case 16: return "ShiftLeft"
        case 17: return "ControlLeft"
        case 48...57: return "Digit\(n - 48)"
        case 65...90: return "Key" + String(UnicodeScalar(UInt8(n)))
        case 112...123: return "F\(n - 111)"
        default: return nil
        }
    }

    /// 화면에 쓸 글자
    static func label(_ code: String) -> String {
        switch code {
        case "Escape": return "Esc"
        case "ArrowUp": return "↑"
        case "ArrowDown": return "↓"
        case "ArrowLeft": return "←"
        case "ArrowRight": return "→"
        case "Backspace": return "⌫"
        case "Delete": return "Del"
        case "PageUp": return "PgUp"
        case "PageDown": return "PgDn"
        case "ShiftLeft", "ShiftRight": return "Shift"
        case "ControlLeft", "ControlRight": return "Ctrl"
        default: break
        }
        if code.hasPrefix("Key"), code.count == 4 { return String(code.dropFirst(3)) }
        if code.hasPrefix("Digit"), code.count == 6 { return String(code.dropFirst(5)) }
        return code
    }

    // MARK: 모으기 (§10)

    private static let keyEq = try! NSRegularExpression(pattern: #"\.key\s*[!=]==?\s*(['"`])([^'"`\n]{1,12})\1"#)
    private static let keyEqRev = try! NSRegularExpression(pattern: #"(['"`])([^'"`\n]{1,12})\1\s*[!=]==?\s*[\w$.\[\]]*\.key\b"#)
    private static let codeEq = try! NSRegularExpression(pattern: #"\.code\s*[!=]==?\s*(['"`])([A-Za-z0-9]{2,20})\1"#)
    private static let codeEqRev = try! NSRegularExpression(pattern: #"(['"`])([A-Za-z0-9]{2,20})\1\s*[!=]==?\s*[\w$.\[\]]*\.code\b"#)
    private static let numEq = try! NSRegularExpression(pattern: #"\.(?:keyCode|which)\s*[!=]==?\s*(\d{1,3})\b"#)
    private static let numEqRev = try! NSRegularExpression(pattern: #"\b(\d{1,3})\s*[!=]==?\s*[\w$.\[\]]*\.(?:keyCode|which)\b"#)
    private static let caseStr = try! NSRegularExpression(pattern: #"\bcase\s*(['"`])([^'"`\n]{1,12})\1\s*:"#)

    /// 글자 하나(파일 하나)에서 키를 센다. `listensKeys` 가 참이면(그 파일이 keydown·keyup 을 들음) `case '…':` 도 센다
    static func count(in s: String, listensKeys: Bool, into tally: inout [String: Int]) {
        let ns = s as NSString
        let r = NSRange(location: 0, length: ns.length)
        func take(_ re: NSRegularExpression, group: Int, map: (String) -> String?) {
            for m in re.matches(in: s, range: r) {
                if let c = map(ns.substring(with: m.range(at: group))), known.contains(c) { tally[c, default: 0] += 1 }
            }
        }
        take(keyEq, group: 2, map: code(forKey:))
        take(keyEqRev, group: 2, map: code(forKey:))
        take(codeEq, group: 2, map: { $0 })
        take(codeEqRev, group: 2, map: { $0 })
        take(numEq, group: 1, map: { Int($0).flatMap(code(forKeyCode:)) })
        take(numEqRev, group: 1, map: { Int($0).flatMap(code(forKeyCode:)) })
        if listensKeys { take(caseStr, group: 2, map: { code(forKey: $0) ?? (known.contains($0) ? $0 : nil) }) }
    }

    /// 센 것을 많이 나온 순으로 최대 12개 (같으면 키 줄 순서)
    static func top(_ tally: [String: Int], limit: Int = 12) -> [String] {
        tally.sorted { a, b in a.value != b.value ? a.value > b.value : rank(a.key) < rank(b.key) }.prefix(limit).map(\.key)
    }

    /// 파일에서 읽은 목록: 아는 이름만, 겹침 없이, 12개까지
    static func sanitize(_ raw: [Any]?) -> [String]? {
        guard let raw else { return nil }
        var out: [String] = []
        for case let s as String in raw where known.contains(s) && !out.contains(s) {
            out.append(s)
            if out.count == 12 { break }
        }
        return out
    }

    // MARK: 키 줄에 띄울 키 (§7)

    static let fallback = ["Escape", "Enter", "Space"]

    /// 최대 6개, Esc → Enter → Space → 방향키(← → ↑ ↓) → 그 밖(판별 순서). 찾은 것이 없거나 예전에 가져온 게임이면 Esc·Enter·Space
    static func pick(_ found: [String]?) -> [String] {
        guard let found, !found.isEmpty else { return fallback }
        let order = found.enumerated().map { (i, c) in (c, rank(c), i) }
        return order.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }.prefix(6).map(\.0)
    }

    private static func rank(_ c: String) -> Int {
        switch c {
        case "Escape": return 0
        case "Enter": return 1
        case "Space": return 2
        case "ArrowLeft": return 3
        case "ArrowRight": return 4
        case "ArrowUp": return 5
        case "ArrowDown": return 6
        default: return 10
        }
    }
}

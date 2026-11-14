import Foundation
import Combine

/// 키 설정 (컨트롤러 버튼 · 하드웨어 키보드 키 → 게임에 보낼 것).
///
/// - 컨트롤러: 실제 버튼(`PadButton`) 하나마다 무엇을 할지. 기본은 같은 버튼(A → A). 게임은 그 버튼을 지금처럼
///   `CutlerySet` 으로 받는다(키보드 게임은 키로, 패드 게임은 가상 Gamepad 로). 버튼에 키보드 키를 바로 붙일 수도 있다.
/// - 하드웨어 키보드: 바꾼 키만 적는다. 적지 않은 키는 지금처럼 게임에 그대로 간다.
/// - 범위: 전역(`KeyMapStore.global`, UserDefaults) + 게임별 덮어쓰기(`DishPrefs.keyMap`, `Documents/Prefs/<id>.json`, iCloud 동기화).
///   게임별 값은 패드 설정처럼 통째로 덮어쓴다(nil = 전역). 게임을 지우면 그 게임의 설정 파일과 함께 지워진다.
enum KeyTarget: Hashable {
    case pad(PadButton)
    case key(String)   // KeyboardEvent.code, `KeyCatalog` 에 있는 것만
    case off

    /// 저장 형식: "pad:a" · "key:KeyC" · "off"
    var stored: String {
        switch self {
        case .pad(let b): return "pad:" + b.name
        case .key(let c): return "key:" + c
        case .off: return "off"
        }
    }

    /// 다른 기기·iCloud 에서 온 값도 이 길을 지난다. 모르는 버튼·키는 버린다 (키 코드는 웹뷰 스크립트에 들어가므로 표에 있는 것만)
    init?(stored s: String) {
        if s == "off" { self = .off; return }
        if s.hasPrefix("pad:"), let b = PadButton(name: String(s.dropFirst(4))), b != .home { self = .pad(b); return }
        if s.hasPrefix("key:"), KeyCatalog.isKnown(String(s.dropFirst(4))) { self = .key(String(s.dropFirst(4))); return }
        return nil
    }
}

struct KeyMap: Equatable {
    /// 실제 컨트롤러 버튼 → 할 일. 기본(같은 버튼)과 같은 값은 넣지 않는다
    private(set) var pad: [PadButton: KeyTarget] = [:]
    /// 하드웨어 키(KeyboardEvent.code) → 할 일. 여기 없는 키는 그대로 게임에 간다
    private(set) var keys: [String: KeyTarget] = [:]

    static let empty = KeyMap()
    var isDefault: Bool { pad.isEmpty && keys.isEmpty }

    /// 바꿀 수 있는 컨트롤러 버튼 (홈 버튼은 늘 일시정지라 빼고, 스틱 움직임은 그대로 이동)
    static let remappable: [PadButton] = [.a, .b, .x, .y, .lb, .rb, .lt, .rt, .view, .menu, .l3, .r3, .up, .down, .left, .right]

    func target(pad b: PadButton) -> KeyTarget { pad[b] ?? .pad(b) }
    func target(key code: String) -> KeyTarget? { keys[code] }

    /// 이 기능(가상 패드 버튼)을 누르는 실제 버튼들
    func physical(for fn: PadButton) -> [PadButton] {
        Self.remappable.filter { target(pad: $0) == .pad(fn) }
    }

    /// 실제 버튼 `p` 에 할 일을 정한다. 패드 버튼끼리는 자리를 바꿔(swap) 어느 기능도 버튼을 잃지 않게 한다:
    /// p 가 하던 일은, 그 기능을 하던 다른 버튼이 넘겨받는다.
    mutating func assign(pad p: PadButton, to t: KeyTarget) {
        guard Self.remappable.contains(p) else { return }
        let old = target(pad: p)
        if old == t { return }
        if case .pad = t {
            for q in Self.remappable where q != p && target(pad: q) == t { setPad(q, old) }
        }
        setPad(p, t)
    }

    /// 자리 바꾸기 없이 그대로 적는다 (되돌리기·불러오기용)
    mutating func setPad(_ p: PadButton, _ t: KeyTarget?) {
        guard Self.remappable.contains(p) else { return }
        if let t, t != .pad(p) { pad[p] = t } else { pad[p] = nil }
    }

    mutating func setKey(_ code: String, _ t: KeyTarget?) {
        guard KeyCatalog.isKnown(code) else { return }
        // 같은 키를 그 키로 보내는 것은 바꾸지 않은 것과 같다
        if let t, t != .key(code) { keys[code] = t } else { keys[code] = nil }
    }

    mutating func resetPad() { pad = [:] }
    mutating func resetKeys() { keys = [:] }

    // MARK: 키보드 → 게임 버튼 (키 설정 › 키보드 목록)

    /// 이 게임 버튼을 누르는 키보드 키들 (보통 하나)
    func keys(for fn: PadButton) -> [String] {
        keys.filter { $0.value == .pad(fn) }.map(\.key).sorted { (KeyCatalog.hid($0) ?? 0) < (KeyCatalog.hid($1) ?? 0) }
    }

    /// 이 게임 버튼에 키 하나를 지정한다. 그 버튼에 있던 키는 풀리고, 이 키가 다른 버튼에 있었으면 옮겨 온다
    mutating func assignKey(_ code: String, to fn: PadButton) {
        guard KeyCatalog.isKnown(code) else { return }
        clearKeys(for: fn)
        keys[code] = .pad(fn)
    }

    mutating func clearKeys(for fn: PadButton) {
        for c in keys(for: fn) { keys[c] = nil }
    }

    /// 프로필을 넣는다 (바꾼 키보드 키는 모두 그 프로필로)
    mutating func applyProfile(_ p: KeyProfile) {
        keys = [:]
        for (c, b) in p.keys { setKey(c, .pad(b)) }
    }

    /// 이 게임에서 실제로 쓸 키보드 표. 키를 지정한 게임 버튼은 게임이 원래 쓰던 키(회색)를 대신하므로
    /// 그 원래 키는 끈다 (다른 일로 직접 바꾼 키는 그대로). 같은 원래 키를 쓰는 버튼이 여럿이면 모두 지정됐을 때만 끈다
    func gameKeys(_ c: CutlerySet?) -> [String: KeyTarget] {
        var out = keys
        guard let c, c.transport == .keyboard else { return out }
        var byNative: [String: [PadButton]] = [:]
        for fn in Self.remappable { if let k = c.keys[fn], KeyCatalog.isKnown(k) { byNative[k, default: []].append(fn) } }
        for (k, fns) in byNative where keys[k] == nil && fns.allSatisfy({ !keys(for: $0).isEmpty }) { out[k] = .off }
        return out
    }

    func matches(_ p: KeyProfile) -> Bool { keys == p.keys.mapValues { .pad($0) } }

    // MARK: 겹침 경고

    struct Warning: Hashable { let text: String }

    /// 화면에 띄울 경고. `fns` = 이 게임에서 뜻이 있는 패드 기능 (nil 이면 모두)
    func warnings(fns: Set<PadButton>? = nil, label: (PadButton) -> String) -> [Warning] {
        var out: [Warning] = []
        for fn in Self.remappable where (fns?.contains(fn) ?? true) && physical(for: fn).isEmpty {
            out.append(Warning(text: "‘\(label(fn))’을(를) 누를 컨트롤러 버튼이 없어요"))
        }
        // 컨트롤러 버튼 둘이 같은 일을 하면
        var byTarget: [KeyTarget: [PadButton]] = [:]
        for p in Self.remappable { let t = target(pad: p); if t != .off { byTarget[t, default: []].append(p) } }
        for (t, ps) in byTarget where ps.count > 1 {
            out.append(Warning(text: "\(ps.map(\.displayName).joined(separator: "·")) 버튼이 모두 \(t.describe(label: label))을(를) 보내요"))
        }
        // 다른 키로 바뀐 키를 다시 다른 키의 대상으로 쓰면, 그 키를 눌렀을 때와 결과가 달라 헷갈린다
        for (c, t) in keys {
            if case .key(let to) = t, let t2 = keys[to], t2 != .key(c) {
                out.append(Warning(text: "\(KeyCatalog.label(c)) → \(KeyCatalog.label(to)) 인데, \(KeyCatalog.label(to)) 키는 다시 \(t2.describe(label: label))(으)로 바뀌어 있어요. 바뀐 키는 원래 키로 보내요"))
            }
        }
        return out.sorted { $0.text < $1.text }
    }
}

/// 키보드 기본 배치 프로필 (키 설정 › 키보드 맨 위). 키 → 게임 버튼
struct KeyProfile: Identifiable, Equatable {
    let id: String
    let title: String
    let keys: [String: PadButton]

    /// "방향키 + Z X"는 게임 기본과 거의 같아 헷갈려서 뺐다 (2026-11-14 사용자)
    static let all: [KeyProfile] = [
        KeyProfile(id: "wasd", title: "WASD + J K", keys: [
            "KeyW": .up, "KeyS": .down, "KeyA": .left, "KeyD": .right,
            "KeyJ": .a, "KeyK": .b, "KeyU": .x, "KeyI": .y, "KeyQ": .lb, "KeyE": .rb,
            "Enter": .menu, "ShiftLeft": .view]),
    ]
}

extension KeyTarget {
    func describe(label: (PadButton) -> String) -> String {
        switch self {
        case .pad(let b): return label(b)
        case .key(let c): return "\(KeyCatalog.label(c)) 키"
        case .off: return "없음"
        }
    }
}

// MARK: 저장 형식

extension KeyMap: Codable {
    private enum CodingKeys: String, CodingKey { case v, pad, keys }

    /// 깨진 항목 하나 때문에 나머지를 잃지 않게 항목별로 읽는다 (다른 기기·iCloud 에서 온 파일)
    init(from decoder: Decoder) throws {
        // 모양이 아예 다르면(다른 판의 파일) 빈 설정으로 읽어 게임 설정 파일 전체를 잃지 않는다
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        let p = (try? c.decodeIfPresent([String: LossyString].self, forKey: .pad)).flatMap { $0 } ?? [:]
        let k = (try? c.decodeIfPresent([String: LossyString].self, forKey: .keys)).flatMap { $0 } ?? [:]
        for (name, v) in p.prefix(32) {
            if let b = PadButton(name: name), let t = v.value.flatMap(KeyTarget.init(stored:)) { setPad(b, t) }
        }
        for (code, v) in k.prefix(160) {
            if let t = v.value.flatMap(KeyTarget.init(stored:)) { setKey(code, t) }
        }
    }

    /// 글자가 아닌 값 하나 때문에 묶음 전체를 잃지 않게
    private struct LossyString: Decodable {
        let value: String?
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(String.self) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .v)
        try c.encode(Dictionary(uniqueKeysWithValues: pad.map { ($0.key.name, $0.value.stored) }), forKey: .pad)
        try c.encode(keys.mapValues(\.stored), forKey: .keys)
    }
}

// MARK: 버튼 이름 (화면용)

extension PadButton {
    /// 키 설정 화면의 실제 버튼 이름
    var displayName: String {
        switch self {
        case .a: return "A"; case .b: return "B"; case .x: return "X"; case .y: return "Y"
        case .lb: return "LB"; case .rb: return "RB"; case .lt: return "LT"; case .rt: return "RT"
        case .view: return "보기"; case .menu: return "메뉴"
        case .l3: return "왼쪽 스틱 누르기"; case .r3: return "오른쪽 스틱 누르기"
        case .up: return "↑"; case .down: return "↓"; case .left: return "←"; case .right: return "→"
        case .home: return "홈"
        }
    }
}

// MARK: 키보드 키 표

/// 키 설정에서 쓸 수 있는 키: KeyboardEvent.code ↔ USB HID 사용 번호(= GCKeyCode 원시값 = SDL 스캔코드) ↔ 화면 이름.
/// Caps Lock·한/영(Lang1)·⌘ 는 빼 둔다 (글자 입력의 한/영 전환과 iOS 단축키에 쓰인다)
enum KeyCatalog {
    struct Entry { let code: String; let hid: Int; let label: String }

    static let all: [Entry] = {
        var e: [Entry] = []
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { e.append(Entry(code: "Key\(c)", hid: 4 + i, label: String(c))) }
        for n in 1...9 { e.append(Entry(code: "Digit\(n)", hid: 29 + n, label: "\(n)")) }
        e.append(Entry(code: "Digit0", hid: 39, label: "0"))
        e += [Entry(code: "Enter", hid: 40, label: "Enter"), Entry(code: "Escape", hid: 41, label: "Esc"),
              Entry(code: "Backspace", hid: 42, label: "⌫"), Entry(code: "Tab", hid: 43, label: "Tab"),
              Entry(code: "Space", hid: 44, label: "Space"),
              Entry(code: "Minus", hid: 45, label: "-"), Entry(code: "Equal", hid: 46, label: "="),
              Entry(code: "BracketLeft", hid: 47, label: "["), Entry(code: "BracketRight", hid: 48, label: "]"),
              Entry(code: "Backslash", hid: 49, label: "\\"), Entry(code: "Semicolon", hid: 51, label: ";"),
              Entry(code: "Quote", hid: 52, label: "'"), Entry(code: "Backquote", hid: 53, label: "`"),
              Entry(code: "Comma", hid: 54, label: ","), Entry(code: "Period", hid: 55, label: "."),
              Entry(code: "Slash", hid: 56, label: "/")]
        for n in 1...12 { e.append(Entry(code: "F\(n)", hid: 57 + n, label: "F\(n)")) }
        e += [Entry(code: "Insert", hid: 73, label: "Insert"), Entry(code: "Home", hid: 74, label: "Home"),
              Entry(code: "PageUp", hid: 75, label: "PgUp"), Entry(code: "Delete", hid: 76, label: "Del"),
              Entry(code: "End", hid: 77, label: "End"), Entry(code: "PageDown", hid: 78, label: "PgDn"),
              Entry(code: "ArrowRight", hid: 79, label: "→"), Entry(code: "ArrowLeft", hid: 80, label: "←"),
              Entry(code: "ArrowDown", hid: 81, label: "↓"), Entry(code: "ArrowUp", hid: 82, label: "↑")]
        for n in 1...9 { e.append(Entry(code: "Numpad\(n)", hid: 88 + n, label: "숫자패드 \(n)")) }
        e.append(Entry(code: "Numpad0", hid: 98, label: "숫자패드 0"))
        e += [Entry(code: "ControlLeft", hid: 224, label: "왼쪽 Ctrl"), Entry(code: "ShiftLeft", hid: 225, label: "왼쪽 Shift"),
              Entry(code: "AltLeft", hid: 226, label: "왼쪽 Alt"), Entry(code: "ControlRight", hid: 228, label: "오른쪽 Ctrl"),
              Entry(code: "ShiftRight", hid: 229, label: "오른쪽 Shift")]
        return e
    }()

    private static let byCode: [String: Entry] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })
    private static let byHID: [Int: Entry] = Dictionary(uniqueKeysWithValues: all.map { ($0.hid, $0) })

    static func isKnown(_ code: String) -> Bool { byCode[code] != nil }
    static func hid(_ code: String) -> Int? { byCode[code]?.hid }
    static func code(hid: Int) -> String? { byHID[hid]?.code }
    static func label(_ code: String) -> String { byCode[code]?.label ?? code }

    /// 고르기 화면의 묶음
    static let groups: [(String, [String])] = [
        ("글자", all.filter { $0.code.hasPrefix("Key") }.map(\.code)),
        ("숫자", all.filter { $0.code.hasPrefix("Digit") }.map(\.code)),
        ("자주 쓰는 키", ["Enter", "Escape", "Space", "Tab", "Backspace", "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight", "AltLeft",
                      "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]),
        ("F 키", all.filter { $0.code.hasPrefix("F") && $0.code.count <= 3 }.map(\.code)),
        ("기호·편집", ["Minus", "Equal", "BracketLeft", "BracketRight", "Backslash", "Semicolon", "Quote", "Backquote", "Comma", "Period", "Slash",
                    "Insert", "Delete", "Home", "End", "PageUp", "PageDown"]),
        ("숫자패드", all.filter { $0.code.hasPrefix("Numpad") }.map(\.code)),
    ]
}

// MARK: 저장소

/// 전역 키 설정(UserDefaults `keys.map`)과 게임별 덮어쓰기(DishPrefs.keyMap)를 읽고 쓴다.
@MainActor
final class KeyMapStore: ObservableObject {
    static let shared = KeyMapStore()
    static let globalKey = "keys.map"

    @Published private(set) var global: KeyMap

    private init() {
        global = UserDefaults.standard.data(forKey: Self.globalKey).flatMap { try? JSONDecoder().decode(KeyMap.self, from: $0) } ?? .empty
    }

    /// 이 게임에 실제로 쓸 값: 게임별 값이 있으면 그것, 없으면 전역
    func effective(_ dishID: String?) -> KeyMap {
        if let dishID, let own = DishPrefsStore.shared.prefs(for: dishID).keyMap { return own }
        return global
    }

    func usesOwn(_ dishID: String) -> Bool { DishPrefsStore.shared.prefs(for: dishID).keyMap != nil }

    func setGlobal(_ m: KeyMap) {
        global = m
        if m.isDefault { UserDefaults.standard.removeObject(forKey: Self.globalKey) }
        else { UserDefaults.standard.set(try? JSONEncoder().encode(m), forKey: Self.globalKey) }
        changed()
    }

    /// 게임별 값. nil = 전역을 따른다
    func set(_ m: KeyMap?, for dishID: String) {
        objectWillChange.send()
        DishPrefsStore.shared.update(dishID) { $0.keyMap = m }
        changed()
    }

    /// 범위에 맞춰 쓴다: 게임이 자기 값을 쓰고 있으면 그 게임에, 아니면 전역에
    func update(dishID: String?, _ change: (inout KeyMap) -> Void) {
        var m = effective(dishID); change(&m)
        if let dishID, usesOwn(dishID) { set(m, for: dishID) } else { setGlobal(m) }
    }

    private func changed() { HardKeys.shared.mapChanged() }
}

import Foundation

extension CutlerySet {
    /// RPG Maker XP (Pokémon Essentials) — PC 키보드 배치 그대로. Essentials 게임이 흔히 안내하는 조작키 기준:
    /// A버튼 C, B버튼 X(누르고 있으면 달리기), 메뉴·가방 Z(Input::ACTION), 등록 아이템 D(SPECIAL), L A, R S, 배틀 배속 Q.
    /// 엔진의 기본 키 연결(mkxp-z)과 Essentials 가 같은 키를 쓰므로 PC 에서 키보드로 하는 것과 똑같이 들어간다.
    static let rpgMakerXP = CutlerySet(
        transport: .keyboard,
        labels: [.field: [.a: "확인", .b: "취소·달리기", .x: "메뉴", .y: "등록", .lb: "L", .rb: "R",
                          .rt: "배속", .view: "배속", .menu: "메뉴"]],
        keys: [.a: "KeyC", .b: "KeyX", .x: "KeyZ", .y: "KeyD", .lb: "KeyA", .rb: "KeyS", .rt: "KeyQ",
               .view: "KeyQ", .menu: "KeyZ",
               .up: "ArrowUp", .down: "ArrowDown", .left: "ArrowLeft", .right: "ArrowRight"],
        stickKeys: [.up: "ArrowUp", .down: "ArrowDown", .left: "ArrowLeft", .right: "ArrowRight"])
}

/// KeyboardEvent.code → SDL 스캔코드(USB HID, app_bridge.h 의 MKXP_SCANCODE_*). 모르는 키는 nil
enum BrassKeys {
    static func scancode(_ code: String) -> Int32? {
        if code.hasPrefix("Key"), code.count == 4, let c = code.unicodeScalars.last, ("A"..."Z").contains(c) {
            return 4 + Int32(c.value - UnicodeScalar("A").value)
        }
        if code.hasPrefix("Digit"), code.count == 6, let n = Int32(code.suffix(1)) { return n == 0 ? 39 : 29 + n }
        if code.hasPrefix("F"), let n = Int32(code.dropFirst()), (1...12).contains(n) { return 57 + n }
        switch code {
        case "Enter": return 40
        case "Escape": return 41
        case "Backspace": return 42
        case "Tab": return 43
        case "Space": return 44
        case "ArrowRight": return 79
        case "ArrowLeft": return 80
        case "ArrowDown": return 81
        case "ArrowUp": return 82
        case "ControlLeft": return 224
        case "ShiftLeft": return 225
        case "AltLeft": return 226
        default: return nil
        }
    }
}

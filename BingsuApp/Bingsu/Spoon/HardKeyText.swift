import GameController

/// 하드웨어 키보드로 글자 넣기 (빌드 42).
/// 게임이 글자를 요청하는 화면(`Input.text_input`)은 iOS 글자 칸(SDL 화면 키보드)을 꺼 두어서 하드웨어 키보드 글자가 들어가지 않는다.
/// 그래서 키를 GCKeyboard 로 직접 읽어 글자로 바꾸고, 한글은 HangulComposer(두벌식)로 조합해 게임 키보드와 같은 길(`TextOp`)로 보낸다.
/// 키 자체(Enter·Esc·방향키·지우기)는 SDL 이 그대로 게임에 보내므로 여기서는 글자만 만든다.
/// 한/영: 한/영 키(Lang1), Caps Lock, 오른쪽 Alt.
/// 키는 `HardKeys` 가 SDL 의 키보드 처리기를 감싼 자리에서 받아 온다 (처리기를 직접 바꿔 끼우면 SDL 이 키를 못 받는다).
@MainActor
final class HardKeyText {
    static let shared = HardKeyText()

    private var composer = HangulComposer()
    private var korean = true
    private var shiftDown = 0
    private var send: ((GameKeyboard.TextOp) -> Void)?

    static var connected: Bool { GCKeyboard.coalesced != nil }

    func start(korean: Bool, send: @escaping (GameKeyboard.TextOp) -> Void) {
        self.korean = korean
        self.send = send
        composer.reset()
        shiftDown = 0
        HardKeys.shared.setTextSink { code, pressed in HardKeyText.shared.key(code, pressed) }
    }

    func stop() {
        guard send != nil else { return }
        HardKeys.shared.setTextSink(nil)
        send = nil
        composer.reset()
    }

    private func key(_ code: GCKeyCode, _ pressed: Bool) {
        guard let send else { return }
        if code == .leftShift || code == .rightShift { shiftDown = max(0, shiftDown + (pressed ? 1 : -1)); return }
        guard pressed else { return }
        let shift = shiftDown > 0
        switch code {
        case .LANG1, .capsLock, .rightAlt:
            korean.toggle(); composer.reset()
        case .spacebar:
            composer.reset(); send(.edit(back: 0, text: " "))
        case .deleteOrBackspace:
            // 지우기 키는 SDL 이 게임에 보내 한 글자를 지운다. 조합 중이면 한 단계 앞 글자를 다시 넣는다
            if let e = composer.backspace(), !e.text.isEmpty { send(.edit(back: 0, text: e.text)) }
        case .returnOrEnter, .escape, .tab, .upArrow, .downArrow, .leftArrow, .rightArrow:
            composer.reset()
        default:
            guard let t = Self.text(code, shift: shift, korean: korean) else { return }
            let e = composer.input(t)
            if e.back > 0 || !e.text.isEmpty { send(.edit(back: e.back, text: e.text)) }
        }
    }

    private static let letters: [GCKeyCode: Character] = [
        .keyA: "a", .keyB: "b", .keyC: "c", .keyD: "d", .keyE: "e", .keyF: "f", .keyG: "g", .keyH: "h", .keyI: "i",
        .keyJ: "j", .keyK: "k", .keyL: "l", .keyM: "m", .keyN: "n", .keyO: "o", .keyP: "p", .keyQ: "q", .keyR: "r",
        .keyS: "s", .keyT: "t", .keyU: "u", .keyV: "v", .keyW: "w", .keyX: "x", .keyY: "y", .keyZ: "z"]
    private static let others: [GCKeyCode: (String, String)] = [
        .one: ("1", "!"), .two: ("2", "@"), .three: ("3", "#"), .four: ("4", "$"), .five: ("5", "%"),
        .six: ("6", "^"), .seven: ("7", "&"), .eight: ("8", "*"), .nine: ("9", "("), .zero: ("0", ")"),
        .hyphen: ("-", "_"), .equalSign: ("=", "+"), .openBracket: ("[", "{"), .closeBracket: ("]", "}"),
        .backslash: ("\\", "|"), .semicolon: (";", ":"), .quote: ("'", "\""), .graveAccentAndTilde: ("`", "~"),
        .comma: (",", "<"), .period: (".", ">"), .slash: ("/", "?")]

    static func text(_ code: GCKeyCode, shift: Bool, korean: Bool) -> String? {
        if let c = letters[code] {
            if korean { return (shift ? GameKeyboard.koShift[c] : nil) ?? GameKeyboard.ko[c] }
            return shift ? String(c).uppercased() : String(c)
        }
        if let p = others[code] { return shift ? p.1 : p.0 }
        return nil
    }
}

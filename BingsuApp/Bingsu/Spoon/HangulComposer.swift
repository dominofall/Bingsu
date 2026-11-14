import Foundation

/// 두벌식 한글 조합 (빌드 42).
/// 게임이 글자를 요청하는 화면(`Input.text_input`)은 키가 아니라 완성 글자를 받는다.
/// 그래서 빙수 게임 키보드가 자모를 직접 조합하고, 화면에 보이는 글자를 바꾸는 방법을 `Edit` 로 알려 준다:
/// 앞 글자 `back` 개를 지우고 `text` 를 넣는다. 조합 중인 글자는 한 글자뿐이라 back 은 0 또는 1.
struct HangulComposer {
    struct Edit: Equatable { var back: Int; var text: String }

    private struct Block: Equatable {
        var cho: String? = nil
        var jung: String? = nil
        var jong: String? = nil
        var isEmpty: Bool { cho == nil && jung == nil && jong == nil }
    }

    private var block = Block()
    /// 지금 글자를 만들어 온 단계 (⌫ 로 한 단계씩 되돌림)
    private var history: [Block] = []

    static let choList = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ").map(String.init)
    static let jungList = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ").map(String.init)
    static let jongList = [""] + Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ").map(String.init)
    static let vowelPairs: [String: String] = ["ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ"]
    static let jongPairs: [String: String] = ["ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ",
                                               "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ"]

    static func isVowel(_ j: String) -> Bool { jungList.contains(j) }

    var composing: String { Self.render(block) }

    /// 자모 하나를 넣는다. 자모가 아니면 조합을 끝내고 그대로 넣는다
    mutating func input(_ j: String) -> Edit {
        let before = composing
        guard Self.isVowel(j) || Self.choList.contains(j) else {
            reset()
            return Edit(back: 0, text: j)
        }
        var committed = ""
        var started = false
        let old = block
        if Self.isVowel(j) {
            if let jong = block.jong {
                // 받침이 다음 글자 첫소리로 넘어간다 (겹받침이면 뒤 자음만)
                let parts = Self.jongPairs.first(where: { $0.value == jong })?.key.map(String.init)
                var prev = block
                prev.jong = parts?.first
                committed = Self.render(prev)
                let cho = parts?.last ?? jong
                start(Block(cho: cho))
                history.append(block)
                block.jung = j
                started = true
            } else if let jung = block.jung {
                if let pair = Self.vowelPairs[jung + j] { block.jung = pair }
                else { committed = before; start(Block(jung: j)); started = true }
            } else {
                block.jung = j
            }
        } else {
            if let jong = block.jong {
                if let pair = Self.jongPairs[jong + j] { block.jong = pair }
                else { committed = before; start(Block(cho: j)); started = true }
            } else if block.cho != nil, block.jung != nil, Self.jongList.contains(j) {
                block.jong = j
            } else if block.isEmpty {
                block.cho = j
            } else {
                committed = before; start(Block(cho: j)); started = true
            }
        }
        if !started { history.append(old) }   // 같은 글자를 고치는 중: 단계 기록
        let after = committed + composing
        if committed == before && !before.isEmpty {
            return Edit(back: 0, text: composing)          // 앞 글자는 그대로 두고 새 글자만
        }
        return Edit(back: before.isEmpty ? 0 : 1, text: after)
    }

    /// ⌫: 조합 중이면 한 단계 되돌린 Edit, 아니면 nil (게임에 지우기 키를 보낸다)
    mutating func backspace() -> Edit? {
        guard !block.isEmpty else { return nil }
        block = history.popLast() ?? Block()
        if block.isEmpty { history = [] }
        return Edit(back: 1, text: composing)
    }

    /// 조합을 끝낸다 (글자는 이미 게임에 들어가 있다)
    mutating func reset() {
        block = Block()
        history = []
    }

    /// 새 글자를 시작한다. 첫소리+가운뎃소리로 시작하면 ⌫ 가 첫소리로 돌아가게 단계를 남긴다
    private mutating func start(_ b: Block) {
        history = [Block()]
        block = b
    }

    private static func render(_ b: Block) -> String {
        if let c = b.cho, let v = b.jung,
           let ci = choList.firstIndex(of: c), let vi = jungList.firstIndex(of: v) {
            let ji = jongList.firstIndex(of: b.jong ?? "") ?? 0
            let code = 0xAC00 + (ci * 21 + vi) * 28 + ji
            return UnicodeScalar(code).map { String(Character($0)) } ?? ""
        }
        return b.cho ?? b.jung ?? ""
    }
}

import SwiftUI
import UIKit

/// 게임 키보드 (2026-11-13, 시안 design/game-keyboard-v2.html · 아이콘 design/keyboard-icons.html).
/// 키를 직접 읽는 게임 화면(두벌식 이름 입력, Enter·Esc 를 기다리는 화면 등)에서 패드 대신 쓰는 자판.
/// 누른 자리의 키를 그대로 게임에 보내고(누를 때 누름, 뗄 때 뗌), 한글 조합은 게임이 한다.
/// 글자 모드(빌드 42): 게임이 글자를 요청하는 화면(`Input.text_input`)에서는 키 대신 글자를 보낸다. 한글은 빙수가 조합(HangulComposer).
///
/// 배치는 iPhone 키보드 그대로(사람들이 이미 익숙함). 맨 아래 줄 [123][🌐 한/영][스페이스][확인], 그 아래 왼쪽(iOS 🌐 자리)에 🎮 패드로.
/// 위 줄은 ❄(빙수 메뉴) · esc · 방향키 · ⋯(tab·ctrl·alt·F키). iPad 는 iPad 키보드 배치.
/// 색은 빙수 홈 하늘빛 위에 얼음 키, 확인은 빙수 파랑. 아이콘은 한 벌(24칸, 선 1.6)로 에셋 kb.*
struct GameKeyboard: View {
    /// 키 이름(KeyQ, Enter …)과 누름/뗌
    let send: (String, Bool) -> Void
    let onPad: () -> Void
    /// ❄: 빙수 메뉴(일시정지)
    var onMenu: () -> Void = {}
    var haptics = true
    var startKorean = true
    /// 게임이 알려 준 한/영 상태(두벌식 이름 입력 화면). 알 때는 자판 글자를 이것에 맞춘다
    var gameKorean: Bool? = nil
    /// 글자 모드: 게임이 글자를 요청하는 중. 글자·지우기·키 누르기를 `type` 으로 보낸다
    var textMode = false
    var type: (TextOp) -> Void = { _ in }

    enum TextOp: Equatable {
        /// 앞 글자 back 개를 지우고 text 를 넣는다
        case edit(back: Int, text: String)
        /// 키 하나를 눌렀다 뗀다 (Enter·Esc·방향키 …)
        case tap(String)
    }

    enum Lang { case ko, en }
    enum Page { case abc, num }

    @State private var lang: Lang = .ko
    @State private var page: Page = .abc
    /// 0 꺼짐, 1 다음 키 한 번, 2 고정
    @State private var shift = 0
    @State private var lastShiftTap = Date.distantPast
    @State private var mods: Set<String> = []
    @State private var held: [String: [String]] = [:]
    @State private var didStart = false
    @State private var pacer = KeyPacer()
    @State private var composer = HangulComposer()
    /// 위 줄 ⋯ 를 눌러 tab·ctrl·alt·F키를 펼쳤는지
    @State private var moreOpen = false

    static func isWide(_ width: CGFloat) -> Bool { width >= 600 }

    /// 화면 맨 아래부터 차지하는 높이 (게임 화면 자리 계산용)
    static func height(width: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let m = Metrics(width: width)
        return m.bar + m.rowGap + m.keyH * 4 + m.rowGap * 3 + m.foot + max(bottomInset, 8)
    }

    struct Metrics {
        let wide: Bool
        let keyH: CGFloat, bar: CGFloat, rowGap: CGFloat, gap: CGFloat, foot: CGFloat, side: CGFloat
        init(width: CGFloat) {
            wide = GameKeyboard.isWide(width)
            keyH = wide ? 56 : 42
            bar = wide ? 50 : 46
            rowGap = wide ? 10 : 11
            gap = wide ? 10 : 6
            foot = wide ? 10 : 46
            side = wide ? 6 : 3
        }
        var letterFont: CGFloat { wide ? 24 : 22 }
        var fnFont: CGFloat { wide ? 17 : 16 }
        var icon: CGFloat { wide ? 26 : 24 }
    }

    // MARK: 자판 정보

    static let letterRows: [[Character]] = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
    static let ko: [Character: String] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ"]
    static let koShift: [Character: String] = ["q": "ㅃ", "w": "ㅉ", "e": "ㄸ", "r": "ㄲ", "t": "ㅆ", "o": "ㅒ", "p": "ㅖ"]

    struct Sym { let label: String; let code: String; let shifted: Bool }
    static let numRows: [[Sym]] = [
        (1...10).map { n in Sym(label: "\(n % 10)", code: "Digit\(n % 10)", shifted: false) },
        [Sym(label: "-", code: "Minus", shifted: false), Sym(label: "/", code: "Slash", shifted: false),
         Sym(label: ":", code: "Semicolon", shifted: true), Sym(label: ";", code: "Semicolon", shifted: false),
         Sym(label: "(", code: "Digit9", shifted: true), Sym(label: ")", code: "Digit0", shifted: true),
         Sym(label: "$", code: "Digit4", shifted: true), Sym(label: "&", code: "Digit7", shifted: true),
         Sym(label: "@", code: "Digit2", shifted: true), Sym(label: "\"", code: "Quote", shifted: true)],
        [Sym(label: ".", code: "Period", shifted: false), Sym(label: ",", code: "Comma", shifted: false),
         Sym(label: "?", code: "Slash", shifted: true), Sym(label: "!", code: "Digit1", shifted: true),
         Sym(label: "'", code: "Quote", shifted: false)]
    ]
    struct Chip: Hashable { let label: String; let code: String; var mod = false; var icon: String? = nil; var turn: Double = 0 }
    /// 위 줄 기본: esc 와 방향키
    static let arrowChips: [Chip] = [
        Chip(label: "←", code: "ArrowLeft", icon: "kb.arrow", turn: -90), Chip(label: "↑", code: "ArrowUp", icon: "kb.arrow"),
        Chip(label: "↓", code: "ArrowDown", icon: "kb.arrow", turn: 180), Chip(label: "→", code: "ArrowRight", icon: "kb.arrow", turn: 90)]
    /// ⋯ 를 펼치면
    static let moreChips: [Chip] = [
        Chip(label: "tab", code: "Tab"), Chip(label: "ctrl", code: "ControlLeft", mod: true), Chip(label: "alt", code: "AltLeft", mod: true)]
        + (1...12).map { Chip(label: "F\($0)", code: "F\($0)") }

    // MARK: 화면

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let m = Metrics(width: W)
            VStack(spacing: 0) {
                topBar(m)
                VStack(spacing: m.rowGap) {
                    if m.wide { wideRows(width: W - m.side * 2, m: m) } else { phoneRows(width: W - m.side * 2, m: m) }
                }
                .padding(.horizontal, m.side)
                .padding(.top, m.rowGap)
                if !m.wide { phoneFoot(width: W - m.side * 2, m: m).padding(.horizontal, m.side) }
                Spacer(minLength: 0)
            }
            .frame(width: W, height: geo.size.height, alignment: .top)
            .background(LinearGradient(colors: [KB.tray1, KB.tray2, KB.tray3], startPoint: .top, endPoint: .bottom))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
        }
        .onAppear {
            if !didStart { lang = (gameKorean ?? startKorean) ? .ko : .en; didStart = true }
        }
        .onChange(of: gameKorean) { _, k in
            if let k { lang = k ? .ko : .en; page = .abc }
        }
        .onChange(of: textMode) { _, _ in composer.reset() }
        .onDisappear { releaseAll(); composer.reset() }
    }

    // MARK: 위 줄

    private func topBar(_ m: Metrics) -> some View {
        HStack(spacing: 6) {
            chipButton(icon: "kb.snow", label: "빙수 메뉴", m: m) { releaseAll(); composer.reset(); onMenu() }
            if moreOpen {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(Self.moreChips, id: \.self) { keyChip($0, m) } }
                }
            } else {
                keyChip(Chip(label: "esc", code: "Escape"), m)
                Spacer(minLength: 4)
                ForEach(Self.arrowChips, id: \.self) { keyChip($0, m) }
                Spacer(minLength: 4)
            }
            chipButton(icon: "kb.more", label: moreOpen ? "닫기" : "더 많은 키", m: m, on: moreOpen) {
                withAnimation(.easeOut(duration: 0.15)) { moreOpen.toggle() }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: m.bar)
        .background(KB.bar)
    }

    private func chipShape(_ m: Metrics) -> CGSize { CGSize(width: m.wide ? 52 : 42, height: m.wide ? 36 : 32) }

    /// 누르고 떼는 동안 키를 보내는 위 줄 단추 (esc·방향키·tab·ctrl·alt·F키)
    private func keyChip(_ c: Chip, _ m: Metrics) -> some View {
        let on = c.mod && mods.contains(c.code)
        let s = chipShape(m)
        return Button(action: {}) {
            Group {
                if let icon = c.icon {
                    Image(icon).renderingMode(.template).resizable().frame(width: 18, height: 18).rotationEffect(.degrees(c.turn))
                } else {
                    Text(c.label).font(.system(size: m.wide ? 16 : 15, weight: .medium))
                }
            }
            .frame(minWidth: s.width, minHeight: s.height)
            .padding(.horizontal, c.icon == nil && c.label.count > 2 ? 6 : 0)
        }
        .buttonStyle(HoldStyle(base: on ? KB.ok : KB.chip, pressed: KB.fn, ink: on ? KB.okInk : KB.chipInk, radius: 9) { down in
            if c.mod {
                if down { tick(); if mods.contains(c.code) { mods.remove(c.code) } else { mods.insert(c.code) } }
                return
            }
            if textMode { if down { tick(); composer.reset(); type(.tap(c.code)) }; return }
            if down { press(c.code, label: c.code) } else { release(c.code) }
        })
        .accessibilityLabel(c.label)
    }

    /// 누르면 바로 동작하는 위 줄 단추 (❄ · ⋯)
    private func chipButton(icon: String, label: String, m: Metrics, on: Bool = false, action: @escaping () -> Void) -> some View {
        let s = chipShape(m)
        return Button { tick(); action() } label: {
            Image(icon).renderingMode(.template).resizable().frame(width: 20, height: 20)
                .frame(width: s.width - 6, height: s.height)
        }
        .buttonStyle(HoldStyle(base: on ? KB.ok : KB.chip, pressed: KB.fn, ink: on ? KB.okInk : KB.chipInk, radius: 9) { _ in })
        .accessibilityLabel(label)
    }

    // MARK: 자판 (iPhone)

    @ViewBuilder
    private func phoneRows(width W: CGFloat, m: Metrics) -> some View {
        let u = W / 10
        let k = u - m.gap
        HStack(spacing: m.gap) { firstRow(keyW: k, m: m) }
        HStack(spacing: m.gap) { secondRow(keyW: k, m: m) }
        HStack(spacing: 0) {
            let sideW = page == .abc ? u * 1.36 - m.gap : (W - 5 * u * 1.4) / 2 - m.gap
            if page == .abc { shiftKey(w: sideW, m: m) } else { fnKey(w: sideW, m: m, label: "#+=") {} }
            Spacer(minLength: 0)
            HStack(spacing: m.gap) { thirdRow(keyW: page == .abc ? k : u * 1.4 - m.gap, m: m) }
            Spacer(minLength: 0)
            backKey(w: sideW, m: m)
        }
        HStack(spacing: m.gap) {
            pageKey(w: u * 1.25 - m.gap, m: m)
            langKey(w: u * 1.25 - m.gap, m: m)
            spaceKey(w: W - u * 5 - m.gap, m: m)
            returnKey(w: u * 2.5 - m.gap, m: m)
        }
    }

    /// iOS 🌐 자리: 패드로 돌아가기. 🎤 자리는 비운다
    private func phoneFoot(width W: CGFloat, m: Metrics) -> some View {
        let u = W / 10
        return HStack {
            Button { releaseAll(); composer.reset(); onPad() } label: {
                Image("kb.pad").renderingMode(.template).resizable().frame(width: 26, height: 26)
                    .frame(width: u * 1.25, height: m.foot)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(KB.fnInk)
            .accessibilityLabel("패드로 돌아가기")
            Spacer()
        }
        .frame(height: m.foot)
    }

    // MARK: 자판 (iPad)

    @ViewBuilder
    private func wideRows(width W: CGFloat, m: Metrics) -> some View {
        let U = W / 12.6
        let k = U - m.gap
        HStack(spacing: m.gap) {
            keyCap(w: U * 1.3 - m.gap, m: m, style: .fn, code: "Tab") { Text("tab").font(.system(size: m.fnFont)) }
            firstRow(keyW: k, m: m)
            backKey(w: U * 1.3 - m.gap, m: m)
        }
        HStack(spacing: m.gap) {
            langKey(w: U * 1.6 - m.gap, m: m)
            secondRow(keyW: k, m: m)
            returnKey(w: W - U * 1.6 - CGFloat(page == .abc ? 9 : 10) * U - m.gap, m: m)
        }
        HStack(spacing: m.gap) {
            let n = CGFloat(page == .abc ? 7 : 5)
            let sideW = (W - n * U) / 2 - m.gap
            if page == .abc { shiftKey(w: sideW, m: m) } else { fnKey(w: sideW, m: m, label: "#+=") {} }
            thirdRow(keyW: k, m: m)
            if page == .abc { shiftKey(w: sideW, m: m) } else { fnKey(w: sideW, m: m, label: "#+=") {} }
        }
        HStack(spacing: m.gap) {
            pageKey(w: U * 1.6 - m.gap, m: m)
            padKey(w: U * 1.3 - m.gap, m: m)
            spaceKey(w: W - U * 1.6 * 2 - U * 1.3 * 2 - m.gap, m: m)
            padKey(w: U * 1.3 - m.gap, m: m)
            pageKey(w: U * 1.6 - m.gap, m: m)
        }
    }

    @ViewBuilder private func firstRow(keyW: CGFloat, m: Metrics) -> some View {
        if page == .abc { ForEach(Self.letterRows[0], id: \.self) { letterKey($0, w: keyW, m: m) } }
        else { ForEach(Array(Self.numRows[0].enumerated()), id: \.offset) { symKey($0.element, w: keyW, m: m) } }
    }
    @ViewBuilder private func secondRow(keyW: CGFloat, m: Metrics) -> some View {
        if page == .abc { ForEach(Self.letterRows[1], id: \.self) { letterKey($0, w: keyW, m: m) } }
        else { ForEach(Array(Self.numRows[1].enumerated()), id: \.offset) { symKey($0.element, w: keyW, m: m) } }
    }
    @ViewBuilder private func thirdRow(keyW: CGFloat, m: Metrics) -> some View {
        if page == .abc { ForEach(Self.letterRows[2], id: \.self) { letterKey($0, w: keyW, m: m) } }
        else { ForEach(Array(Self.numRows[2].enumerated()), id: \.offset) { symKey($0.element, w: keyW, m: m) } }
    }

    // MARK: 키 종류

    private func cap(_ c: Character) -> String {
        if lang == .ko { return (shift > 0 ? Self.koShift[c] : nil) ?? Self.ko[c] ?? String(c) }
        return shift > 0 ? String(c).uppercased() : String(c)
    }

    private func icon(_ name: String, _ m: Metrics) -> some View {
        Image(name).renderingMode(.template).resizable().frame(width: m.icon, height: m.icon)
    }

    private func letterKey(_ c: Character, w: CGFloat, m: Metrics) -> some View {
        let label = cap(c)
        let code = "Key" + String(c).uppercased()
        return KeyCapView(width: w, height: m.keyH, style: .letter, pop: label) {
            Text(label).font(.system(size: m.letterFont))
        } onChange: { down in
            if textMode { if down { tick(); typeText(label) } else { afterLetter() }; return }
            if down { press(code, label: label, shifted: shift > 0) } else { release(code); afterLetter() }
        }
        .accessibilityLabel(label)
    }

    private func symKey(_ s: Sym, w: CGFloat, m: Metrics) -> some View {
        KeyCapView(width: w, height: m.keyH, style: .letter, pop: s.label) {
            Text(s.label).font(.system(size: m.letterFont))
        } onChange: { down in
            if textMode { if down { tick(); typeText(s.label) } else { afterLetter() }; return }
            if down { press(s.code, label: s.label, shifted: s.shifted) } else { release(s.code); afterLetter() }
        }
        .accessibilityLabel(s.label)
    }

    /// 누르는 동안 누르고 있는 키 (지우기·확인·스페이스·tab)
    private func keyCap<L: View>(w: CGFloat, m: Metrics, style: KeyCapView<L>.Style, code: String, @ViewBuilder label: @escaping () -> L) -> some View {
        KeyCapView(width: w, height: m.keyH, style: style, pop: nil, label: label) { down in
            if textMode { if down { tick(); typeKey(code) } else { afterLetter() }; return }
            if down { press(code, label: code) } else { release(code); afterLetter() }
        }
    }

    private func fnKey(w: CGFloat, m: Metrics, label: String, action: @escaping () -> Void) -> some View {
        KeyCapView(width: w, height: m.keyH, style: .fn, pop: nil) {
            Text(label).font(.system(size: m.fnFont))
        } onChange: { down in
            if down { tick() } else { action() }
        }
    }

    private func shiftKey(w: CGFloat, m: Metrics) -> some View {
        KeyCapView(width: w, height: m.keyH, style: shift > 0 ? .on : .fn, pop: nil) {
            icon(shift == 2 ? "kb.capslock" : (shift == 1 ? "kb.shift.on" : "kb.shift"), m)
        } onChange: { down in
            guard down else { return }
            tick()
            let now = Date()
            if shift == 0 { shift = 1 }
            else if shift == 1 && now.timeIntervalSince(lastShiftTap) < 0.35 { shift = 2 }
            else { shift = 0 }
            lastShiftTap = now
        }
        .accessibilityLabel("Shift")
    }

    private func backKey(w: CGFloat, m: Metrics) -> some View {
        keyCap(w: w, m: m, style: .fn, code: "Backspace") { icon("kb.delete", m) }
            .accessibilityLabel("지우기")
    }

    /// Enter. 이름 입력·키 입력 모두 "확인" (게임 문구 "Enter 키로 확인" 과도 맞음)
    private func returnKey(w: CGFloat, m: Metrics) -> some View {
        keyCap(w: w, m: m, style: .ok, code: "Enter") { Text("확인").font(.system(size: m.fnFont + 1, weight: .semibold)) }
            .accessibilityLabel("확인 (Enter)")
    }

    /// 글자 없이 오른쪽 아래에 작은 한/영 표시 (iOS 처럼)
    private func spaceKey(w: CGFloat, m: Metrics) -> some View {
        keyCap(w: w, m: m, style: .letter, code: "Space") {
            Text(lang == .ko ? "한" : "영")
                .font(.system(size: 11))
                .foregroundStyle(KB.hint)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 9).padding(.bottom, 6)
        }
        .accessibilityLabel("스페이스")
    }

    private func langKey(w: CGFloat, m: Metrics) -> some View {
        KeyCapView(width: w, height: m.keyH, style: .fn, pop: nil) {
            icon("kb.globe", m)
        } onChange: { down in
            if textMode {
                if down { tick(); composer.reset(); lang = lang == .ko ? .en : .ko; page = .abc }
                return
            }
            if down {
                press("AltRight", label: "한/영")
                lang = lang == .ko ? .en : .ko
                page = .abc
            } else { release("AltRight") }
        }
        .accessibilityLabel("한/영 바꾸기")
    }

    private func padKey(w: CGFloat, m: Metrics) -> some View {
        KeyCapView(width: w, height: m.keyH, style: .fn, pop: nil) {
            icon("kb.pad", m)
        } onChange: { down in
            if down { tick() } else { releaseAll(); composer.reset(); onPad() }
        }
        .accessibilityLabel("패드로 돌아가기")
    }

    private func pageKey(w: CGFloat, m: Metrics) -> some View {
        fnKey(w: w, m: m, label: page == .abc ? "123" : (lang == .ko ? "가" : "ABC")) {
            page = page == .abc ? .num : .abc
        }
    }

    // MARK: 보내기

    /// 키를 누른다. Shift·ctrl·alt 가 함께면 그 키를 먼저 누른다. 같은 키를 다른 손가락이 이미 누르고 있으면 무시
    private func press(_ code: String, label: String, shifted: Bool = false) {
        guard held[code] == nil else { return }
        var with: [String] = []
        if shifted { with.append("ShiftLeft") }
        with += mods.sorted()
        pacer.emit(with.map { ($0, true) } + [(code, true)], send: send)
        held[code] = with
        tick()
    }

    private func release(_ code: String) {
        guard let with = held.removeValue(forKey: code) else { return }
        pacer.emit([(code, false)] + with.reversed().map { ($0, false) }, send: send)
        if !with.isEmpty { mods.subtract(with) }
    }

    // MARK: 글자 모드

    /// 자모면 조합하고, 아니면(영문·숫자·기호) 조합을 끝내고 그대로 넣는다
    private func typeText(_ t: String) {
        let e = composer.input(t)
        if e.back > 0 || !e.text.isEmpty { type(.edit(back: e.back, text: e.text)) }
    }

    private func typeKey(_ code: String) {
        switch code {
        case "Space":
            composer.reset(); type(.edit(back: 0, text: " "))
        case "Backspace":
            if let e = composer.backspace() { type(.edit(back: e.back, text: e.text)) } else { type(.tap("Backspace")) }
        default:
            composer.reset(); type(.tap(code))
        }
    }

    private func afterLetter() {
        if shift == 1 { shift = 0 }
    }

    private func releaseAll() {
        for code in held.keys { release(code) }
    }

    private func tick() {
        guard haptics else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    }
}

// MARK: - 키 하나

/// 손가락이 닿는 순간 누르고 뗄 때 뗀다. 키 사이 틈(바깥 여백)까지 이 키로 받는다
struct KeyCapView<Label: View>: View {
    enum Style { case letter, fn, on, ok }
    let width: CGFloat
    let height: CGFloat
    let style: Style
    let pop: String?
    @ViewBuilder let label: () -> Label
    let onChange: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        let fill: Color = switch style {
        case .letter: pressed ? KB.fn : KB.key
        case .fn: pressed ? KB.key : KB.fn
        case .on: KB.key
        case .ok: pressed ? KB.okPressed : KB.ok
        }
        let ink: Color = switch style {
        case .letter, .on: KB.ink
        case .fn: KB.fnInk
        case .ok: KB.okInk
        }
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(fill)
            .shadow(color: style == .fn ? .clear : KB.shadow, radius: 0, x: 0, y: 1)
            .overlay { label().foregroundStyle(ink) }
            .frame(width: max(0, width), height: height)
            .padding(.horizontal, 0)
            .contentShape(Rectangle().inset(by: -4))
            .overlay(alignment: .bottom) {
                if pressed, let pop {
                    Text(pop).font(.system(size: 32))
                        .foregroundStyle(KB.ink)
                        .frame(width: max(52, width + 16), height: 58)
                        .background(KB.popBack, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: KB.shadow, radius: 6, y: 3)
                        .offset(y: -height + 2)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; onChange(true) } }
                    .onEnded { _ in if pressed { pressed = false; onChange(false) } }
            )
            .zIndex(pressed ? 1 : 0)
    }
}

/// 위 줄 단추: 가로로 넘길 수 있게 Button 을 쓰고, 눌림 상태로 누름/뗌을 보낸다
private struct HoldStyle: ButtonStyle {
    let base: Color
    let pressed: Color
    let ink: Color
    let radius: CGFloat
    let onChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ink)
            .background(configuration.isPressed ? pressed : base, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: KB.shadow, radius: 0, x: 0, y: 1)
            .onChange(of: configuration.isPressed) { _, p in onChange(p) }
    }
}

/// 게임 키보드 색 (밝게/어둡게). 빙수 홈 하늘빛 + 얼음 키 + 시럽 남색, 확인은 빙수 파랑(Palette.accent)
enum KB {
    private static func dyn(_ light: UInt32, _ la: CGFloat = 1, _ dark: UInt32, _ da: CGFloat = 1) -> Color {
        let l = rgb(light, la), d = rgb(dark, da)
        return Color(uiColor: UIColor(dynamicProvider: { t in t.userInterfaceStyle == .dark ? d : l }))
    }
    private static func rgb(_ hex: UInt32, _ a: CGFloat) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    static let tray1 = dyn(0xD9E7FB, 1, 0x1C2945, 1)
    static let tray2 = dyn(0xE8F0F7, 1, 0x121C2B, 1)
    static let tray3 = dyn(0xEDF0F2, 1, 0x0F1421, 1)
    static let bar = dyn(0xFFFFFF, 0.45, 0xFFFFFF, 0.04)
    static let key = dyn(0xFFFFFF, 0.94, 0xFFFFFF, 0.13)
    static let popBack = dyn(0xFFFFFF, 1, 0x34405A, 1)
    static let fn = dyn(0x2F62C8, 0.10, 0xFFFFFF, 0.06)
    static let chip = dyn(0xFFFFFF, 0.85, 0xFFFFFF, 0.10)
    static let ink = dyn(0x1F3F94, 1, 0xF2F7FB, 1)
    static let fnInk = dyn(0x1F3F94, 1, 0xC9D6EE, 1)
    static let chipInk = dyn(0x1F3F94, 1, 0xE6EEFB, 1)
    static let ok = dyn(0x2F62C8, 1, 0x7AA4F4, 1)
    static let okPressed = dyn(0x1F3F94, 1, 0x9DB8F0, 1)
    static let okInk = dyn(0xFFFFFF, 1, 0x0B1730, 1)
    static let hint = dyn(0x5B6B8A, 1, 0x93A3C2, 1)
    static let shadow = dyn(0x1F3F94, 0.22, 0x000000, 0.45)
}

/// 키 하나의 누름·뗌 사이를 최소 시간만큼 벌린다.
/// 게임은 한 프레임(약 16ms)에 한 번 키 상태를 읽어서, 짧게 톡 친 키는 누름과 뗌이 같은 프레임 안에 끝나 놓친다.
/// 묶음(같이 누른 Shift·ctrl 포함)은 순서를 지킨 채 한꺼번에 보낸다.
final class KeyPacer {
    static let minGap: CFTimeInterval = 0.07   // 약 4프레임
    private var last: [String: CFTimeInterval] = [:]

    func emit(_ batch: [(String, Bool)], send: @escaping (String, Bool) -> Void) {
        let now = CACurrentMediaTime()
        let at = max(now, batch.compactMap { last[$0.0].map { $0 + Self.minGap } }.max() ?? now)
        for (c, _) in batch { last[c] = at }
        if at <= now {
            for (c, d) in batch { send(c, d) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + (at - now)) { for (c, d) in batch { send(c, d) } }
        }
    }
}

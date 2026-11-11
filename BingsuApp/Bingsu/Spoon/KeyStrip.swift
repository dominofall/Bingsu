import SwiftUI
import UIKit
import WebKit

/// 터치 조작의 키보드 키 줄 (명세 docs/engines/IMPLEMENTATION-touch.md §7).
/// PC 게임이 쓰는 키 몇 개(Esc·Enter·Space·방향키 등)를 게임 화면 밖 빈 띠에 작게 띄운다. 글자 입력용 키보드가 아니다.

/// 키 줄의 자리 (순수 함수, 자가 테스트 대상). 좌표는 화면 전체(안전 영역 무시) 기준
enum KeyStripPlace {
    static let key: CGFloat = 38
    static let gap: CGFloat = 6
    /// 이보다 좁은 띠에는 넣지 않고 게임 가장자리에 겹친다
    static let minBand: CGFloat = 44

    enum Side: Equatable { case left, right }

    struct Output: Equatable {
        var frames: [CGRect]
        /// 게임 위에 겹쳐 놓음 (반투명하게 그린다)
        var overlay: Bool
    }

    /// - Parameters:
    ///   - screen: 화면 크기
    ///   - safe: 안전 영역 여백
    ///   - game: 게임 화면 자리
    ///   - avoid: 겹치면 안 되는 단추 자리 (눈송이)
    ///   - island: 가로 화면에서 카메라(다이내믹 아일랜드)가 있는 쪽. 그쪽 띠는 다른 쪽이 안 될 때만 쓴다
    static func place(count n: Int, screen: CGSize, safe: UIEdgeInsets, game: CGRect, avoid: [CGRect], island: Side?) -> Output {
        guard n > 0 else { return Output(frames: [], overlay: false) }
        let W = screen.width, H = screen.height
        let long = CGFloat(n) * key + CGFloat(n - 1) * gap
        let bottomEdge = H - max(safe.bottom, 8)

        if W > H {
            // 가로: 양옆 띠에 세로로 (카메라 없는 쪽 먼저, 그다음 오른쪽)
            let bands: [(Side, CGFloat)] = [(.right, W - game.maxX), (.left, game.minX)]
            let ordered = bands.sorted { a, b in
                if (a.0 == island) != (b.0 == island) { return b.0 == island }
                return a.0 == .right
            }
            for (side, band) in ordered where band >= minBand {
                let cx = side == .right ? game.maxX + band / 2 : band / 2
                let col = CGRect(x: cx - key / 2, y: 0, width: key, height: H)
                var top = max(safe.top, 8), bottom = bottomEdge
                for a in avoid where a.intersects(col.insetBy(dx: -4, dy: 0)) {
                    if a.midY < H / 2 { top = max(top, a.maxY + 8) } else { bottom = min(bottom, a.minY - 8) }
                }
                guard bottom - top >= long else { continue }
                let y0 = top + (bottom - top - long) / 2
                return Output(frames: (0..<n).map { CGRect(x: cx - key / 2, y: y0 + CGFloat($0) * (key + gap), width: key, height: key) }, overlay: false)
            }
            // 위아래 띠(iPad 가로처럼 게임이 폭을 채운 경우): 아래 띠에 가로로
            let below = bottomEdge - game.maxY
            if below >= minBand, let row = row(n: n, long: long, cy: game.maxY + below / 2, cx: game.midX, W: W, safe: safe, avoid: avoid) {
                return Output(frames: row, overlay: false)
            }
        } else {
            // 세로: 게임 바로 아래
            let below = bottomEdge - game.maxY
            if below >= minBand {
                let cy = game.maxY + min(below / 2, 12 + key / 2)
                if let row = row(n: n, long: long, cy: cy, cx: W / 2, W: W, safe: safe, avoid: avoid) { return Output(frames: row, overlay: false) }
            }
        }
        // 빈 띠가 없으면 게임 오른쪽 아래 가장자리에 겹친다
        let y = min(game.maxY, bottomEdge) - 8 - key
        let x1 = min(game.maxX, W - max(safe.right, 8)) - 8
        return Output(frames: (0..<n).map { i in
            CGRect(x: x1 - long + CGFloat(i) * (key + gap), y: y, width: key, height: key)
        }, overlay: true)
    }

    /// 가운데 맞춘 가로 한 줄. 화면 밖으로 나가거나 피할 단추와 겹치면 nil
    private static func row(n: Int, long: CGFloat, cy: CGFloat, cx: CGFloat, W: CGFloat, safe: UIEdgeInsets, avoid: [CGRect]) -> [CGRect]? {
        let minX = max(safe.left, 8), maxX = W - max(safe.right, 8)
        guard long <= maxX - minX else { return nil }
        let x0 = min(max(cx - long / 2, minX), maxX - long)
        let frames = (0..<n).map { CGRect(x: x0 + CGFloat($0) * (key + gap), y: cy - key / 2, width: key, height: key) }
        let all = frames.reduce(CGRect.null) { $0.union($1) }
        return avoid.contains { $0.intersects(all) } ? nil : frames
    }

    /// 가로 화면에서 카메라가 있는 쪽 (가로 안전 영역이 있는 iPhone 만)
    @MainActor static func islandSide() -> Side? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let w = scene.windows.first, w.safeAreaInsets.left > 20 || w.safeAreaInsets.right > 20 else { return nil }
        switch scene.effectiveGeometry.interfaceOrientation {
        case .landscapeRight: return .left    // 기기 윗부분(카메라)이 왼쪽
        case .landscapeLeft: return .right
        default: return nil
        }
    }
}

/// 키 누르기·떼기·되풀이를 웹 페이지로 보낸다 (`__bingsu.key(code, down, repeat)`, 가상 패드와 같은 길)
@MainActor
final class KeyStripController: ObservableObject {
    weak var webView: WKWebView?
    var haptics = true
    @Published private(set) var down: Set<String> = []
    private var timers: [String: Timer] = [:]
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    /// PC 처럼 누르고 있으면 0.4초 뒤부터 되풀이 (초당 약 30번)
    static let repeatDelay: TimeInterval = 0.4
    static let repeatEvery: TimeInterval = 1.0 / 30

    func press(_ code: String) {
        guard StrawKeys.known.contains(code), !down.contains(code) else { return }
        down.insert(code)
        send(code, down: true, again: false)
        if haptics { haptic.impactOccurred(intensity: 0.5) }
        let t = Timer(timeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRepeat(code) }
        }
        RunLoop.main.add(t, forMode: .common)
        timers[code] = t
    }

    func release(_ code: String) {
        guard down.contains(code) else { return }
        timers.removeValue(forKey: code)?.invalidate()
        down.remove(code)
        send(code, down: false, again: false)
    }

    func releaseAll() { for c in down { release(c) } }

    private func startRepeat(_ code: String) {
        guard down.contains(code) else { return }
        let t = Timer(timeInterval: Self.repeatEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(code, down: true, again: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        timers[code] = t
    }

    private func send(_ code: String, down: Bool, again: Bool) {
        // code 는 아는 키 이름(영문·숫자)뿐이라 그대로 넣어도 된다
        webView?.evaluateJavaScript("window.__bingsu && __bingsu.key(\"\(code)\", \(down), \(again))", completionHandler: nil)
    }
}

/// 화면에 그리는 키 줄
struct KeyStripView: View {
    @ObservedObject var controller: KeyStripController
    let keys: [String]
    /// 키 자리 (KeyStripPlace.place)
    let place: KeyStripPlace.Output
    /// 가상 패드 설정의 투명도
    let opacity: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(keys.enumerated()), id: \.element) { i, code in
                if i < place.frames.count {
                    let f = place.frames[i]
                    KeyCap(label: StrawKeys.label(code), pressed: controller.down.contains(code))
                        .frame(width: f.width, height: f.height)
                        .contentShape(Rectangle().inset(by: -3))
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in controller.press(code) }
                            .onEnded { _ in controller.release(code) })
                        .position(x: f.midX, y: f.midY)
                        .accessibilityLabel("\(StrawKeys.label(code)) 키")
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .opacity(place.overlay ? min(opacity, 0.45) : max(opacity, 0.45))
        .ignoresSafeArea()
        .onDisappear { controller.releaseAll() }
    }
}

private struct KeyCap: View {
    let label: String
    let pressed: Bool

    var body: some View {
        let arrow = label.count == 1 && "←→↑↓".contains(label)
        Text(label)
            .font(.system(size: arrow ? 18 : 12, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(pressed ? 0.75 : 0.5)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white.opacity(pressed ? 0.7 : 0.3), lineWidth: 1))
            .scaleEffect(pressed ? 0.94 : 1)
    }
}

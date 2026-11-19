import UIKit
import SwiftUI

/// 게임 화면 자리 규칙 — RPG Maker 러너(`BrassBowlContainerView`), 고정 비율 웹 게임(`BowlContainerView`),
/// 배치 편집기의 자리 표시가 모두 이것을 쓴다.
///
/// 규칙: 쓸 수 있는 영역(눈송이 줄·패드·게임 키보드·안전 영역을 뺀 곳) 안에서 게임 비율을 지키며 가장 크게,
/// 가로·세로 모두 가운데. 영역은 부르는 쪽이 그때그때(회전·창 크기·해상도·패드·키보드가 바뀔 때마다) 다시 계산해 넘긴다.
/// 좌표는 모두 화면 전체(안전 영역을 무시한) 기준.
enum GameFrame {
    /// `area` 안에 `aspect`(가로/세로)를 지켜 가장 크게, 가운데
    static func fit(aspect: CGFloat, in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return .zero }
        guard aspect.isFinite, aspect > 0 else { return area }
        var w = area.width, h = w / aspect
        if h > area.height { h = area.height; w = h * aspect }
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// 세로 화면에서 쓸 수 있는 영역: 위 안전 영역 + `band`(눈송이 줄, 눈송이가 패드 안이면 작게) 아래부터
    /// 패드 맨 윗줄(`padTop`, 패드가 없으면 아래 안전 영역) 위까지. 좌우는 안전 영역 안
    static func portraitArea(size: CGSize, insets: UIEdgeInsets, band: CGFloat, padTop: CGFloat?) -> CGRect {
        let fold = HingeStore.shared.pose.halfFoldLine(size: size, insets: insets)
        // 카메라 피하기(세로): 띠가 오른쪽이면 카메라는 오른쪽 위 — 게임을 카메라 아래로 내린다
        let cameraTop = avoidCamera && hasCameraStrip(insets) && insets.right > insets.left
            ? cameraExtent(strip: insets.right) + 4 : 0
        let insets = underCamera(insets, landscape: false)
        // 반 접기: 눈송이는 아래 화면에 있으니 위 게임 화면은 눈송이 줄 없이 꽉 채운다
        let top = max(insets.top + (fold == nil ? band : 0), cameraTop)
        var bottom = padTop.map { $0 - 12 } ?? (size.height - insets.bottom)
        // 반 접기: 게임은 접히는 선 위에만 (아래 절반은 책상 쪽이라 패드 자리)
        if let fold { bottom = min(bottom, fold - 8) }
        let area = CGRect(x: insets.left, y: top,
                          width: max(0, size.width - insets.left - insets.right), height: max(0, bottom - top))
        return fold == nil ? area : halfFoldInset(area)
    }

    /// 반 접기 + 카메라 피하기: 위 화면의 둥근 모서리에 게임 귀퉁이가 잘리지 않게 상하좌우로 조금 띄운다 (사용자 2026-11-19)
    static func halfFoldInset(_ area: CGRect) -> CGRect {
        guard avoidCamera else { return area }
        return area.insetBy(dx: 16, dy: 16)
    }

    /// 가로 화면에서 쓸 수 있는 영역: 좌우 안전 영역(노치) 안, 높이는 전체.
    /// 홈 표시줄은 게임 중 숨으므로 위아래 안전 영역은 빼지 않는다 (엔진 자동 배치와 같은 규칙).
    /// iOS 는 가로에서 좌우 안전 영역을 같게 주므로 가운데는 화면 가운데와 같다
    static func landscapeArea(size: CGSize, insets: UIEdgeInsets) -> CGRect {
        let insets = underCamera(insets, landscape: true)
        return CGRect(x: insets.left, y: 0, width: max(0, size.width - insets.left - insets.right), height: size.height)
    }

    /// 좌우 안전 영역이 한쪽에만 있으면 iPhone Duo 바깥 화면의 카메라·상태 띠다 (다른 iPhone 은 가로에서 좌우가 같고 세로에서 둘 다 0)
    static func hasCameraStrip(_ insets: UIEdgeInsets) -> Bool { abs(insets.left - insets.right) > 1 }

    /// 카메라 원이 화면 모서리에서 끝나는 거리. 띠(84pt) 안에서 카메라는 29~66pt 를 차지한다 (시뮬레이터에서 잼, 2026-11-18).
    /// 가로에서는 카메라가 위 구석에 있으므로 이 값이 카메라 오른쪽 끝(좌우)이자 아래 끝(위아래)이다
    static func cameraExtent(strip: CGFloat) -> CGFloat { (strip * 66 / 84).rounded(.up) }

    /// 메뉴 단추(눈송이)를 왼쪽 위에 둘지. 원하는 구석에 카메라가 있으면(Duo 바깥 화면) 반대쪽 위 구석으로 옮긴다.
    /// 세로: 띠가 오른쪽이면 카메라는 오른쪽 위. 가로: 띠가 왼쪽이면 카메라는 왼쪽 위(띠가 오른쪽이면 텐트라 카메라는 오른쪽 아래)
    static func orbLeading(_ wantLeading: Bool) -> Bool {
        let ins = windowInsets()
        guard hasCameraStrip(ins) else { return wantLeading }
        let stripRight = ins.right > ins.left
        let portrait = UIScreen.main.bounds.height > UIScreen.main.bounds.width
        guard portrait ? stripRight : !stripRight else { return wantLeading }   // 카메라가 위 구석일 때만
        let cameraLeading = !stripRight
        return wantLeading == cameraLeading ? !wantLeading : wantLeading
    }

    /// "카메라 피해서 가운데" (일시정지 › 화면·성능, 카메라 띠가 있는 화면에서만 보임). 모든 게임 공통
    static let avoidCameraKey = "bingsu.avoidCameraStrip"
    /// 카메라 피하기를 켰으면 이미 정한 게임 자리 `r` 을 카메라 밖으로 옮긴다 (웹 게임, `BowlContainerView.gameRect`).
    /// `aspect` 가 nil 이면 비율 없이 화면에 맞추는 게임(남는 자리를 그대로 씀).
    /// 가로: 양옆을 카메라 끝만큼 비우고 위에 붙인다. 세로(카메라 오른쪽 위): 게임을 카메라 아래로 내린다
    static func avoidCameraRect(_ r: CGRect, screen: CGSize, aspect: CGFloat?) -> CGRect {
        let ins = windowInsets()
        guard avoidCamera, hasCameraStrip(ins) else { return r }
        let ext = cameraExtent(strip: max(ins.left, ins.right))
        if screen.width > screen.height {
            guard let aspect else { return CGRect(x: ext, y: r.minY, width: screen.width - ext * 2, height: r.height) }
            return avoidCameraLandscape(aspect: aspect, screen: screen, insets: ins)
        }
        guard ins.right > ins.left else { return r }
        let top = ext + 4
        guard r.minY < top else { return r }
        let area = CGRect(x: r.minX, y: top, width: r.width, height: max(0, r.maxY - top))
        return aspect.map { fit(aspect: $0, in: area) } ?? area
    }

    /// 가로 바깥 화면에서 카메라를 피한 게임 자리. 두 가지 중 큰 쪽:
    /// - 양옆: 카메라 끝만큼 양옆을 비우고 위에 붙임 (4:3 처럼 높이가 넉넉한 게임)
    /// - 아래(텐트면 위): 카메라 높이만큼 비우고 폭 가득 (포켓로그 16:9 처럼 납작한 게임, 사용자 2026-11-18)
    /// 띠가 왼쪽이면 카메라는 왼쪽 위, 오른쪽이면(텐트) 오른쪽 아래
    static func avoidCameraLandscape(aspect: CGFloat, screen: CGSize, insets ins: UIEdgeInsets) -> CGRect {
        let W = screen.width, H = screen.height
        let ext = cameraExtent(strip: max(ins.left, ins.right))
        var side = fit(aspect: aspect, in: CGRect(x: ext, y: 0, width: W - ext * 2, height: H))
        side.origin.y = 0
        let cameraTop = ins.left > ins.right
        var below = fit(aspect: aspect, in: CGRect(x: 0, y: cameraTop ? ext : 0, width: W, height: H - ext))
        below.origin.y = cameraTop ? ext : 0
        return below.width * below.height > side.width * side.height ? below : side
    }

    /// iPhone Duo 인지 (경첩이 있거나 지금 카메라 띠가 보이는 화면). 카메라 피하기 줄을 보일지 정할 때
    static var isDuo: Bool { HingeStore.shared.pose.available || hasCameraStrip(windowInsets()) }
    static var avoidCamera: Bool { UserDefaults.standard.bool(forKey: avoidCameraKey) }

    /// 게임 화면 자리에 쓸 좌우 안전 영역. 카메라 띠가 있으면
    /// - 기본: 띠를 무시하고 화면 가득 (사용자 2026-11-18: 카메라가 게임을 조금 가려도 크게 보이는 게 낫다)
    /// - 카메라 피하기(가로): 카메라 오른쪽 끝까지만 비우고 반대쪽에도 같은 폭을 비워 정가운데 (빈 곳은 `CameraSideBands` 가 채운다).
    ///   위아래는 가운데가 아니라 위에 붙인다 (사용자 2026-11-18, `BrassBowlContainerView.gameRect`)
    ///   세로는 띠가 화면 높이 전체라 양옆을 맞추면 게임이 2/3 로 줄므로 좌우는 그대로 두고 `portraitArea` 가 카메라 아래로 내린다
    /// 패드·메뉴는 이와 상관없이 띠를 피한다
    static func underCamera(_ insets: UIEdgeInsets, landscape: Bool) -> UIEdgeInsets {
        guard hasCameraStrip(insets) else { return insets }
        var i = insets
        let m = avoidCamera && landscape ? cameraExtent(strip: max(insets.left, insets.right)) : 0
        i.left = m; i.right = m
        return i
    }

    /// 보이는 창이 가로인지 (컨트롤러 초점 순서처럼 화면 크기를 따로 받지 않는 곳에서)
    static func windowIsLandscape() -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState != .unattached }.flatMap(\.windows).filter { !$0.isHidden }
        guard let b = (windows.first(where: \.isKeyWindow) ?? windows.first)?.bounds else { return false }
        return b.width > b.height
    }

    /// 창의 실제 안전 영역. ignoresSafeArea 한 GeometryReader 에서는 0 이 나오므로 창에서 읽는다.
    /// RPG Maker 엔진(SDL)이 만든 숨은 창이 키 창이 되어 있을 수 있어서, 보이는 창을 먼저 고른다
    static func windowInsets() -> UIEdgeInsets {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState != .unattached }.flatMap(\.windows)
        let visible = windows.filter { !$0.isHidden }
        return (visible.first(where: \.isKeyWindow) ?? visible.first ?? windows.first)?.safeAreaInsets ?? .zero
    }
}

/// "카메라 피해서 가운데" 일 때 게임 화면 양옆 빈 곳을 채우는 띠 (iPhone Duo 바깥 화면).
/// 게임기 테두리처럼 어두운 남색에 눈송이를 옅게, 게임 쪽 가장자리에 가는 빛 줄. 터치는 받지 않는다
struct CameraSideBands: View {
    /// 게임 화면 자리 (화면 전체 좌표)
    let game: CGRect
    let screen: CGSize

    /// 양옆 여백을 따로 칠하지 않고, 화면 전체에 깔린 한 장의 바탕을 게임 화면 자리만 뚫어서 보여 준다.
    /// 무늬가 화면 좌표로 놓이므로 왼쪽 여백에서 게임 밑을 지나 오른쪽 여백으로 그대로 이어진다.
    var body: some View {
        SnowBackdrop(screen: screen, region: { size in
            var holes = Path(CGRect(origin: .zero, size: size))
            holes.addRect(game)
            return holes
        }, eoFill: true, floating: game)
    }
}

/// 반 접기(노트북 모양)에서 접히는 선 아래, 가상 컨트롤러 밑에 까는 바탕.
/// 카메라 피하기 여백과 같은 남색 눈송이 바탕이라 기기 아래 몸통처럼 보인다
struct HalfFoldPadBase: View {
    /// 접히는 선의 y (화면 전체 좌표)
    let fold: CGFloat
    let screen: CGSize
    /// 게임 화면 자리. 주면 위 화면의 게임 둘레 여백도 같은 바탕으로 칠한다 (사용자 2026-11-19: 검은 여백 대신 무늬)
    var game: CGRect? = nil

    var body: some View {
        ZStack(alignment: .top) {
            if let game {
                // 뚫는 자리는 접히는 선 위까지만 — 화면 가득 그리는 게임이어도 아래 절반은 바탕
                let hole = game.intersection(CGRect(x: 0, y: 0, width: screen.width, height: fold))
                SnowBackdrop(screen: screen, region: { size in
                    var p = Path(CGRect(origin: .zero, size: size))
                    if !hole.isNull { p.addRect(hole) }
                    return p
                }, eoFill: true, floating: hole.isNull ? nil : hole)
            } else {
                SnowBackdrop(screen: screen, region: { size in
                    Path(CGRect(x: 0, y: fold, width: size.width, height: size.height - fold))
                })
            }
            // 접히는 선에 옅은 빛 한 줄 — 위 화면과 아래 몸통의 경계
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1).offset(y: fold)
        }
        .frame(width: screen.width, height: screen.height, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 남색 그라데이션 + 엇갈린 눈송이 격자. `region` 안만 칠한다. 무늬는 화면 좌표에 놓여 어디에 깔아도 이어진다
struct SnowBackdrop: View {
    let screen: CGSize
    let region: (CGSize) -> Path
    var eoFill = false
    /// 이 자리가 바탕 위에 떠 있는 듯 가장자리에 그림자
    var floating: CGRect? = nil

    var body: some View {
        Canvas { ctx, size in
            ctx.clip(to: region(size), style: FillStyle(eoFill: eoFill))

            let full = CGRect(origin: .zero, size: size)
            ctx.fill(Path(full), with: .linearGradient(
                Gradient(colors: [Color(red: 0.08, green: 0.11, blue: 0.20), Color(red: 0.04, green: 0.06, blue: 0.11)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: size.height)))

            if let big = ctx.resolveSymbol(id: 0), let small = ctx.resolveSymbol(id: 1) {
                let step: CGFloat = 44
                var row = 0
                var y = step / 2
                while y < size.height + step {
                    var x = (row % 2 == 0 ? step / 2 : step) - step
                    var col = 0
                    while x < size.width + step {
                        ctx.draw((row + col) % 3 == 0 ? big : small, at: CGPoint(x: x, y: y))
                        x += step; col += 1
                    }
                    y += step * 0.866; row += 1
                }
            }

            if let floating {
                var shadow = ctx
                shadow.addFilter(.shadow(color: .black.opacity(0.55), radius: 10))
                shadow.fill(Path(floating), with: .color(.black))
            }
        } symbols: {
            Image(systemName: "snowflake").font(.system(size: 14, weight: .light))
                .foregroundStyle(.white.opacity(0.10)).tag(0)
            Image(systemName: "snowflake").font(.system(size: 8, weight: .light))
                .foregroundStyle(.white.opacity(0.07)).tag(1)
        }
        .frame(width: screen.width, height: screen.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 구석의 메뉴 단추(눈송이). 보통은 화면 위 구석, 반 접기(노트북 모양)면 세운 게임 화면이 아니라
/// 책상 쪽 아래 화면의 위쪽 가운데(접히는 선 바로 아래)에 둔다 — 손이 닿는 쪽이고 게임을 가리지 않는다 (사용자 2026-11-19)
struct CornerOrb<Orb: View>: View {
    let orb: Orb
    /// 왼쪽 구석을 원하는지 (카메라가 그 구석에 있으면 `GameFrame.orbLeading` 이 반대로 옮긴다)
    let wantLeading: Bool
    let inset: CGFloat
    @ObservedObject private var hinge = HingeStore.shared

    init(_ orb: Orb, wantLeading: Bool, inset: CGFloat) {
        self.orb = orb; self.wantLeading = wantLeading; self.inset = inset
    }

    var body: some View {
        GeometryReader { geo in
            let ins = GameFrame.windowInsets()
            let full = CGSize(width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                              height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            let fold = hinge.pose.halfFoldLine(size: full, insets: ins)
            VStack(spacing: 0) {
                if let fold { Color.clear.frame(height: fold) }
                if fold != nil {
                    HStack { Spacer(); orb; Spacer() }   // 반 접기: 아래 화면 위쪽 가운데 (사용자 2026-11-19)
                } else {
                    HStack { if GameFrame.orbLeading(wantLeading) { orb; Spacer() } else { Spacer(); orb } }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, inset)
            .padding(.top, fold == nil ? inset : 24)   // 반 접기: 접히는 선에서 조금 떨어지게
            .padding(.bottom, inset)
        }
        .ignoresSafeArea()
    }
}

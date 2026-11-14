import UIKit

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
        let top = insets.top + band
        let bottom = padTop.map { $0 - 12 } ?? (size.height - insets.bottom)
        return CGRect(x: insets.left, y: top,
                      width: max(0, size.width - insets.left - insets.right), height: max(0, bottom - top))
    }

    /// 가로 화면에서 쓸 수 있는 영역: 좌우 안전 영역(노치) 안, 높이는 전체.
    /// 홈 표시줄은 게임 중 숨으므로 위아래 안전 영역은 빼지 않는다 (엔진 자동 배치와 같은 규칙).
    /// iOS 는 가로에서 좌우 안전 영역을 같게 주므로 가운데는 화면 가운데와 같다
    static func landscapeArea(size: CGSize, insets: UIEdgeInsets) -> CGRect {
        CGRect(x: insets.left, y: 0, width: max(0, size.width - insets.left - insets.right), height: size.height)
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

import Foundation

/// 게임 중 일시정지(눈송이) 버튼 자리
enum MenuButtonPlace: String, CaseIterable {
    case topRight, topLeft, pad

    var label: String {
        switch self {
        case .topRight: return "오른쪽 위 구석"
        case .topLeft: return "왼쪽 위 구석"
        case .pad: return "패드 안 (− + 사이)"
        }
    }
}

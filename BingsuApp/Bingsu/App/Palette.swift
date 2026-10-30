import SwiftUI
import UIKit

/// 7.6 비주얼 가이드의 색. 라이트/다크를 시스템 설정에 따라 자동으로 바꾼다.
enum Palette {
    static let background = adaptive(light: 0xECEFF3, dark: 0x0F1520)   // 바탕
    static let card       = adaptive(light: 0xF6FAFC, dark: 0x172030)   // 카드·시트
    static let sky        = adaptive(light: 0xD9E7FB, dark: 0x1C2A45)   // 하늘빛·강조 바탕
    static let accent     = adaptive(light: 0x2F62C8, dark: 0x7AA4F4)   // 포인트(그릇 파랑)
    static let syrup      = adaptive(light: 0x1F3F94, dark: 0x9DB8F0)   // 제목 강조(시럽 남색)
    static let ribbon     = adaptive(light: 0xEE6A55, dark: 0xF38371)   // 작은 강조(리본 코랄)
    static let shadow     = adaptive(light: 0x000000, dark: 0x000000)

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

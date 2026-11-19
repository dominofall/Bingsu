import SwiftUI
import UIKit
import GameController

/// 접히는 iPhone(iPhone Duo)의 경첩 상태. 경첩이 없는 기기나 iOS 27.1 미만이면 `available == false`
struct HingePose: Equatable {
    var available = false
    /// 경첩 각도(도). 0 = 닫힘, 180 = 다 폄
    var degrees: CGFloat = 0

    /// 텐트 모양(뒤집은 V 로 세움): 바깥 화면이 켜진 채 경첩이 벌어져 있다.
    /// 시뮬레이터(iOS 27.2, 2026-11-18)에서 잰 것:
    /// - 반쯤 열면 iOS 가 켤 화면을 고른다 — 약 110° 아래면 바깥 화면(180° 돌아 카메라가 오른쪽 아래), 위면 안쪽 화면
    /// - 바깥 화면이 켜져 있는 동안 `UIHinge.status` 는 82° 에서도 `.closed` 다. 그래서 상태가 아니라 각도로 판단한다
    /// 바깥 화면인지는 카메라 띠(좌우 안전 영역이 한쪽에만)로 안다
    func isTent(insets: UIEdgeInsets) -> Bool {
        available && degrees >= Self.tentMinDegrees && GameFrame.hasCameraStrip(insets)
    }
    /// 이보다 덜 벌어졌으면 손에 쥔 닫힌 폰으로 본다
    static let tentMinDegrees: CGFloat = 25

    /// 반 접기(노트북 모양): 안쪽 화면이 세로로 켜진 채 경첩이 벌어져 있다. 경첩은 화면 가운데를 가로지르므로
    /// 위 절반은 세운 화면, 아래 절반은 책상에 닿는 쪽. 접히는 선의 y(화면 전체 좌표)를 돌려준다, 아니면 nil.
    /// 시뮬레이터에서 안쪽 화면은 반쯤 열면 669×951(세로), 다 펴면 951×669(가로)
    func halfFoldLine(size: CGSize, insets: UIEdgeInsets) -> CGFloat? {
        guard available, degrees >= Self.tentMinDegrees, degrees <= Self.halfFoldMaxDegrees,
              size.height > size.width, !GameFrame.hasCameraStrip(insets) else { return nil }
        return size.height / 2
    }
    /// 이보다 더 펴졌으면 다 편 화면으로 본다
    static let halfFoldMaxDegrees: CGFloat = 165
}

/// 앱 전체가 함께 보는 경첩 상태. `HingeReader` 를 앱 맨 아래 뷰에 하나 두고 여기에 쓴다
final class HingeStore: ObservableObject {
    static let shared = HingeStore()
    @Published var pose = HingePose()
}

/// 경첩 상태를 읽어 `pose` 에 넣는 보이지 않는 뷰 (`UIHingeInteraction`, iOS 27.1+)
struct HingeReader: UIViewRepresentable {
    @Binding var pose: HingePose

    final class Coordinator { var pose: Binding<HingePose>; init(_ p: Binding<HingePose>) { pose = p } }
    func makeCoordinator() -> Coordinator { Coordinator($pose) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        if #available(iOS 27.1, *) {
            let c = context.coordinator
            v.addInteraction(UIHingeInteraction { _, update in
                var p = HingePose()
                if let h = update.hinge {
                    // 화면 배치에 쓰므로 5° 단위로 (각도 갱신마다 다시 그리지 않게)
                    p = HingePose(available: true, degrees: (h.angle * 180 / .pi / 5).rounded() * 5)
                    #if DEBUG
                    print("[Hinge] status \(h.status.rawValue) \(Int(h.angle * 180 / .pi))°")
                    #endif
                }
                if c.pose.wrappedValue != p { c.pose.wrappedValue = p }
            })
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.pose = $pose }
}

/// 반 접기(노트북 모양)로 세워 두고 컨트롤러로 할 때 접히는 선 아래 절반 (가상 패드 대신).
/// 컨트롤러 상태와 저장·불러오기·일시정지 단추. 바탕은 패드 바탕과 같은 남색 눈송이
struct HalfFoldStandPanel: View {
    let fold: CGFloat
    let screen: CGSize
    /// nil 이면 저장 단추를 안 보인다 (빠른 저장을 못 하는 게임)
    var onSave: (() -> Void)?
    var onLoad: (() -> Void)?
    let onPause: () -> Void
    @State private var pad = PadInfo.read()

    struct PadInfo: Equatable {
        var name: String?
        var battery: Int?
        static func read() -> PadInfo {
            let c = GCController.current ?? GCController.controllers().first { $0.extendedGamepad != nil }
            guard let c else { return PadInfo() }
            var b: Int?
            if let bat = c.battery, bat.batteryState != .unknown || bat.batteryLevel > 0 { b = Int((bat.batteryLevel * 100).rounded()) }
            return PadInfo(name: c.vendorName ?? "컨트롤러", battery: b)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            HalfFoldPadBase(fold: fold, screen: screen)
            VStack(spacing: 22) {
                HStack(spacing: 8) {
                    Image(systemName: pad.name == nil ? "gamecontroller" : "gamecontroller.fill")
                    Text(pad.name ?? "컨트롤러 없음").lineLimit(1)
                    if let b = pad.battery {
                        Image(systemName: b > 60 ? "battery.75" : b > 25 ? "battery.50" : "battery.25")
                        Text("\(b)%").monospacedDigit()
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))

                HStack(spacing: 14) {
                    if let onSave { tile("저장", "square.and.arrow.down", onSave) }
                    if let onLoad { tile("불러오기", "arrow.uturn.backward", onLoad) }
                    tile("일시정지", "pause.fill", onPause)
                }
            }
            .padding(.horizontal, 24)
            .frame(width: screen.width, height: screen.height - fold)
            .offset(y: fold)
        }
        .frame(width: screen.width, height: screen.height, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidBecomeCurrent)) { _ in pad = PadInfo.read() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in pad = PadInfo.read() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in pad = PadInfo.read() }
    }

    private func tile(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 150).frame(height: 96)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

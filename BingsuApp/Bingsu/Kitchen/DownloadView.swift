import SwiftUI
import UIKit

/// 게임 추가 › 주소로 zip 내려받기. 주소를 넣으면 같은 시트가 진행 화면으로 바뀐다.
/// 다 받으면 게임 목록이 이 시트를 닫고 가져오기 화면(DeliveryView)으로 넘긴다.
struct DownloadView: View {
    @ObservedObject var courier: Courier
    @Environment(\.dismiss) private var dismiss
    @State private var address = Courier.lastAddress ?? ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch courier.state {
                case .idle: form
                case .failed(let msg): failure(msg)
                default: progress
                }
            }
            .navigationTitle("주소로 내려받기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(courier.state == .idle ? "취소" : "닫기") { dismiss() }
                }
                if courier.state == .idle {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("내려받기") { start() }.disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var form: some View {
        Form {
            Section {
                HStack {
                    TextField("주소", text: $address, prompt: Text("https://.../game.zip"))
                        .focused($focused)
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { start() }
                    Button {
                        if let s = UIPasteboard.general.string { address = s.trimmingCharacters(in: .whitespacesAndNewlines); error = nil }
                    } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("붙여넣기")
                }
            } header: {
                Text("게임 zip 주소")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let error { Text(error).foregroundStyle(.red) }
                    Text("게임 zip 파일의 https 주소를 넣어요. 앱을 내려도 계속 받고, 다 받으면 바로 가져오기를 시작해요. 받은 파일은 zip 파일 가져오기와 똑같이 검사해요.")
                }
            }
        }
        .onAppear { if address.isEmpty { focused = true } }
    }

    private var progress: some View {
        VStack(spacing: 18) {
            Spacer()
            IceBowl(fraction: courier.state.fraction ?? 0, indeterminate: courier.state.fraction == nil)
                .frame(width: 170, height: 170)
            VStack(spacing: 4) {
                Text(courier.fileName).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                if !courier.host.isEmpty { Text(courier.host).font(.caption).foregroundStyle(.secondary) }
            }
            if let f = courier.state.fraction {
                Text("\(Int(f * 100))%").font(.title2.bold().monospacedDigit()).foregroundStyle(Palette.accent)
                    .contentTransition(.numericText()).animation(.easeOut(duration: 0.2), value: Int(f * 100))
            }
            Text(detail).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("취소", role: .destructive) { courier.cancel() }
                    .buttonStyle(.bordered)
                switch courier.state {
                case .downloading:
                    Button { courier.pause() } label: { Label("일시정지", systemImage: "pause.fill") }
                        .buttonStyle(.borderedProminent).tint(Palette.accent)
                case .paused:
                    Button { courier.resume() } label: { Label("재개", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(Palette.accent)
                default: EmptyView()
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }

    private var detail: String {
        switch courier.state {
        case .checking: return "파일 크기 확인 중"
        case .downloading(let r, let t, let speed, let remaining):
            var parts = [Self.amount(r, t)]
            if speed > 0 { parts.append("\(Courier.bytes(Int64(speed)))/초") }
            if let remaining { parts.append(Self.duration(remaining) + " 남음") }
            return parts.joined(separator: " · ")
        case .paused(let r, let t): return "일시정지 · " + Self.amount(r, t)
        case .done: return "다 받았어요 · 가져오기를 시작해요"
        default: return ""
        }
    }

    private func failure(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("내려받지 못했어요").font(.title3.bold())
            Text(msg).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if courier.canResume {
                Button { courier.resume() } label: { Text("이어받기").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                Button("주소 다시 넣기") { courier.cancel() }
            } else {
                Button { courier.reset() } label: { Text("주소 다시 넣기").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
            }
            Spacer()
        }
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }

    private func start() {
        do {
            try courier.start(address)
            error = nil
            focused = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "120 MB / 1.1 GB · 42%"
    static func amount(_ r: Int64, _ t: Int64) -> String {
        guard t > 0 else { return Courier.bytes(r) }
        return "\(Courier.bytes(r)) / \(Courier.bytes(t)) · \(Int(Double(r) / Double(t) * 100))%"
    }

    static func duration(_ s: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .short
        f.calendar?.locale = Locale(identifier: "ko_KR")
        return f.string(from: s) ?? ""
    }
}

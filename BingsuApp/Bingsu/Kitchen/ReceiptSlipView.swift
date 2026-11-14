import SwiftUI
import UIKit

/// 진단 정보 보내기: 보낼 글을 그대로 보여 주고, 사용자가 공유 시트·복사로 직접 보낸다. 자동으로 보내지 않는다.
/// 게임 중(일시정지 화면·게임 오류)에는 그 게임과 지금 화면 상태를 담고, 원하면 지금 게임 화면도 함께 넣는다.
/// 설정에서 열면 게임을 고른다(기본은 마지막으로 연 게임). 화면 상태는 게임 중에만 알 수 있다.
struct ReceiptSlipView: View {
    var dish: Dish?
    var live: ReceiptLive?
    var screenshot: UIImage?
    /// 설정에서 열 때 고를 게임들
    var choices: [Dish] = []

    @Environment(\.dismiss) private var dismiss
    @State private var pickedID: String = ""
    @State private var slip: ReceiptSlip?
    @State private var includeShot = false
    @State private var copied = false
    /// 이 시트가 들어 있는 창을 찾는 데 쓰는 빈 뷰 (RPG Maker 게임 중에는 엔진 SDL 창이 따로 있다)
    @State private var anchor = ReceiptAnchor.Box()

    private var current: Dish? {
        choices.isEmpty ? dish : choices.first { $0.id == pickedID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("문제를 알릴 때 이 내용을 함께 보내 주시면 원인을 찾기 쉬워요. 아래 글이 보내는 내용 전부예요.")
                        .font(.subheadline)
                } footer: {
                    Text("기기 이름·계정·저장 데이터·파일 위치·IP 주소는 담지 않아요. 빙수가 저절로 보내는 일은 없어요.")
                }

                if !choices.isEmpty {
                    Section {
                        Picker("게임", selection: $pickedID) {
                            Text("게임 없이 (앱·기기만)").tag("")
                            ForEach(choices) { d in Text(d.title).tag(d.id) }
                        }
                    } footer: {
                        Text("게임 화면 크기 같은 정보는 게임 중 일시정지 화면에서 보낼 때만 담겨요.")
                    }
                }

                if let screenshot {
                    Section {
                        Toggle("지금 게임 화면 함께 보내기", isOn: $includeShot).tint(Palette.accent)
                        if includeShot {
                            Image(uiImage: screenshot).resizable().interpolation(.none).scaledToFit()
                                .frame(maxHeight: 220).frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    } footer: {
                        Text("게임 화면에 보이는 이름 같은 글자도 같이 보내져요.")
                    }
                }

                Section("보낼 내용") {
                    if let slip {
                        Text(slip.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 10) { ProgressView(); Text("모으는 중…").foregroundStyle(.secondary) }
                    }
                }

                Section {
                    Button { share() } label: { Label("공유하기", systemImage: "square.and.arrow.up") }
                        .disabled(slip == nil)
                        .background(ReceiptAnchor(box: anchor))
                    Button { copy() } label: { Label(copied ? "복사했어요" : "글만 복사", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .disabled(slip == nil)
                } footer: {
                    Text("공유하기는 글을 작은 파일(.txt)로\(includeShot && screenshot != nil ? ", 게임 화면은 그림으로" : "") 보내요. 메일·메시지·파일 앱에 저장 중에서 고르세요.")
                }
            }
            .tint(Palette.accent)
            .navigationTitle("진단 정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
        .onAppear {
            if !choices.isEmpty, pickedID.isEmpty {
                let last = ReceiptDesk.shared.lastDishID
                pickedID = choices.first { $0.id == last }?.id ?? dish?.id ?? ""
            }
        }
        .task(id: pickedID) {
            slip = nil
            copied = false
            let made = await ReceiptSlip.make(dish: current, live: choices.isEmpty ? live : nil)
            if !Task.isCancelled { slip = made }
            #if DEBUG
            // 시뮬레이터 확인용: 보낼 글을 그대로 파일로 (BINGSU_RECEIPT 로 띄웠을 때만)
            if DevEnv["BINGSU_RECEIPT"] != nil {
                try? FileManager.default.createDirectory(at: ReceiptDesk.folder, withIntermediateDirectories: true)
                try? made.text.write(to: ReceiptDesk.folder.appendingPathComponent("debug-last.txt"), atomically: true, encoding: .utf8)
                // BINGSU_RECEIPT_SHARE=1: 게임 화면을 켠 채로 공유 시트까지 띄운다
                if DevEnv["BINGSU_RECEIPT_SHARE"] == "1" {
                    includeShot = screenshot != nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { share() }
                }
            }
            #endif
        }
    }

    private func copy() {
        guard let slip else { return }
        UIPasteboard.general.string = slip.text
        copied = true
    }

    /// 공유 시트 (UIKit 으로 직접 띄운다: 시트 위 시트에서도 안정적이고 iPad 는 팝오버 자리가 필요하다)
    private func share() {
        guard let slip else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReceiptShare", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var items: [Any] = []
        let txt = dir.appendingPathComponent(slip.fileName)
        if (try? slip.text.write(to: txt, atomically: true, encoding: .utf8)) != nil { items.append(txt) } else { items.append(slip.text) }
        if includeShot, let png = screenshot?.pngData() {
            let shot = dir.appendingPathComponent(slip.fileName.replacingOccurrences(of: ".txt", with: ".png"))
            if (try? png.write(to: shot)) != nil { items.append(shot) }
        }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let top = anchor.topController() else { return }
        if let pop = vc.popoverPresentationController {
            if let v = anchor.view, v.window != nil {
                pop.sourceView = v
                pop.sourceRect = v.bounds
            } else {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
        }
        top.present(vc, animated: true)
    }
}

/// 공유 단추 뒤에 까는 빈 UIView. 그 뷰의 창에서 맨 위 화면을 찾아 공유 시트를 띄운다
struct ReceiptAnchor: UIViewRepresentable {
    final class Box {
        weak var view: UIView?
        func topController() -> UIViewController? {
            let win = view?.window ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }
            var top = win?.rootViewController
            while let p = top?.presentedViewController, !p.isBeingDismissed { top = p }
            return top
        }
    }
    let box: Box
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        box.view = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { box.view = uiView }
}

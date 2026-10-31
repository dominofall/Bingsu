import SwiftUI
import UniformTypeIdentifiers

/// zip 고르기. iPad 실기기에서 SwiftUI `fileImporter` 와 시트에 끼운 UIKit 선택기가 모두
/// "최근 항목" 껍데기만 뜨고 멈추는 보고가 있어(2026-10-29, TestFlight 3·4), 다른 앱들과 같은 방식으로
/// UIDocumentPickerViewController 를 창에서 직접 present 한다. 고른 zip 은 앱 임시 폴더의 복사본이라 Delivery 가 옮겨 쓰고 지운다.
struct GamePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    /// 고를 수 있는 형식 (게임은 zip, 스킨 목록은 .bingsuskin·zip)
    var types: [UTType] = [.zip]
    var onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> Host { let h = Host(); h.types = types; return h }

    func updateUIViewController(_ host: Host, context: Context) {
        host.onPick = { url in isPresented = false; onPick(url) }
        host.types = types
        if isPresented { host.presentIfNeeded() } else { host.dismissIfNeeded() }
    }

    /// 보이지 않는 호스트 뷰 컨트롤러. 여기서 선택기를 present 한다.
    final class Host: UIViewController, UIDocumentPickerDelegate {
        var onPick: ((URL?) -> Void)?
        var types: [UTType] = [.zip]
        private weak var picker: UIDocumentPickerViewController?

        private var waits = 0

        /// 창의 맨 위 화면. 보이지 않는 이 호스트에서 띄우면 iPad 에서 선택기 내용이 빈 화면으로 남는 경우가 있어
        /// 실제로 보이는 맨 위 화면에서 띄운다
        private var topmost: UIViewController? {
            var top = view.window?.rootViewController
            while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
            return top
        }

        func presentIfNeeded() {
            guard picker == nil else { return }
            guard view.window != nil, let top = topmost, top.presentedViewController == nil else {
                // 창이 아직 없거나 다른 창이 닫히는 중: 잠깐 뒤 다시 (3초 넘게 못 띄우면 포기하고 알림)
                waits += 1
                if waits % 10 == 0 { NSLog("[Picker] 아직 못 띄움 (window=\(view.window != nil), top=\(String(describing: topmost.map { type(of: $0) })))") }
                if waits < 30 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.presentIfNeeded() } }
                else { waits = 0; onPick?(nil) }
                return
            }
            waits = 0
            // zip 만, 복사본으로 받는다: iOS 가 앱 임시 폴더로 복사해 건네줘 원본 접근 권한·조정 절차가 없다 (다른 앱들처럼 창이 빨리 뜬다).
            // 폴더 가져오기는 뺐다 (2026-10-30 사용자 결정, zip 만)
            let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            vc.allowsMultipleSelection = false
            vc.shouldShowFileExtensions = true
            vc.delegate = self
            vc.modalPresentationStyle = .formSheet
            picker = vc
            NSLog("[Picker] present from \(type(of: top)) (scene=\(view.window?.windowScene?.activationState.rawValue ?? -1))")
            top.present(vc, animated: true) { NSLog("[Picker] presented · view=\(vc.view.bounds.size) · children=\(vc.children.count)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak vc] in
                guard let vc else { NSLog("[Picker] 5s: picker gone"); return }
                NSLog("[Picker] 5s: isBeingPresented=\(vc.isBeingPresented) presenting=\(vc.presentingViewController != nil) view=\(vc.view.bounds.size) subviews=\(vc.view.subviews.count) userInteraction=\(vc.view.isUserInteractionEnabled)")
            }
        }

        func dismissIfNeeded() {
            if let p = picker, p.presentingViewController != nil { p.dismiss(animated: true) }
            picker = nil
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { NSLog("[Picker] picked"); picker = nil; onPick?(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { NSLog("[Picker] cancelled"); picker = nil; onPick?(nil) }
    }
}

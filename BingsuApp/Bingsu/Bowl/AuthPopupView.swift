import SwiftUI
import WebKit

struct AuthRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// 웹 게임의 외부 로그인(구글·디스코드) 팝업. 게임과 같은 쿠키 저장소를 쓰므로
/// 로그인 뒤 게임 사이트로 돌아오면 쿠키가 게임 웹뷰에도 보인다. 그때 시트를 닫고 게임을 새로 고친다.
/// 어떤 주소로 열지는 ExternalLink.route 가 정한다.
struct AuthPopupView: View {
    let dish: Dish
    let url: URL
    let onReturn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host: String?
    @State private var secure = true

    var body: some View {
        NavigationStack {
            AuthWebView(dish: dish, url: url, host: $host, secure: $secure) { dismiss(); onReturn() }
                .ignoresSafeArea(edges: .bottom)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                    // 페이지 제목은 페이지가 정하므로 쓰지 않는다. 지금 화면의 실제 주소를 보여 주고, 길면 끝(진짜 도메인)을 남긴다
                    ToolbarItem(placement: .principal) {
                        Label(host ?? url.host ?? "", systemImage: secure ? "lock.fill" : "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1).truncationMode(.head)
                    }
                }
        }
    }
}

private struct AuthWebView: UIViewRepresentable {
    let dish: Dish
    let url: URL
    @Binding var host: String?
    @Binding var secure: Bool
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(host: dish.location.host ?? "", onReturn: onReturn, shownHost: $host, secure: $secure) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: GlassBowl.storeID(for: dish))
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = GlassBowl.safariUserAgent
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: url))
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let host: String; let onReturn: () -> Void; var shownHost: Binding<String?>; var secure: Binding<Bool>
        var returned = false
        init(host: String, onReturn: @escaping () -> Void, shownHost: Binding<String?>, secure: Binding<Bool>) {
            self.host = host; self.onReturn = onReturn; self.shownHost = shownHost; self.secure = secure
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let isMain = action.targetFrame?.isMainFrame ?? true
            // 게임 사이트로 돌아오면 (로그인 완료) 팝업은 할 일을 다 한 것
            if let h = action.request.url?.host, h == host, isMain, !returned {
                returned = true
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.onReturn() }
                return
            }
            // 로그인 화면이 암호화되지 않은 주소로 넘어가지 않게 한다
            if isMain, let scheme = action.request.url?.scheme?.lowercased(), scheme != "https", scheme != "about" {
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
        /// 주소는 화면이 실제로 바뀐 뒤에 바꾼다 (불러오는 중의 webView.url 은 아직 옛 화면 위에 새 주소를 보여 줄 수 있다)
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { show(webView) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { show(webView) }
        private func show(_ webView: WKWebView) {
            shownHost.wrappedValue = webView.url?.host
            secure.wrappedValue = webView.url?.scheme?.lowercased() == "https" && webView.hasOnlySecureContent
        }
    }
}

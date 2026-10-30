import SwiftUI
import WebKit

struct AuthRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// 웹 게임의 외부 로그인(구글·디스코드) 팝업. 게임과 같은 쿠키 저장소를 쓰므로
/// 로그인 뒤 게임 사이트로 돌아오면 쿠키가 게임 웹뷰에도 보인다. 그때 시트를 닫고 게임을 새로 고친다.
struct AuthPopupView: View {
    let dish: Dish
    let url: URL
    let onReturn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        NavigationStack {
            AuthWebView(dish: dish, url: url, title: $title) { dismiss(); onReturn() }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title.isEmpty ? "로그인" : title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
    }
}

private struct AuthWebView: UIViewRepresentable {
    let dish: Dish
    let url: URL
    @Binding var title: String
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(host: dish.location.host ?? "", onReturn: onReturn, title: $title) }

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
        let host: String; let onReturn: () -> Void; var title: Binding<String>
        var returned = false
        init(host: String, onReturn: @escaping () -> Void, title: Binding<String>) { self.host = host; self.onReturn = onReturn; self.title = title }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 게임 사이트로 돌아오면 (로그인 완료) 팝업은 할 일을 다 한 것
            if let h = action.request.url?.host, h == host, action.targetFrame?.isMainFrame ?? true, !returned {
                returned = true
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.onReturn() }
                return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            title.wrappedValue = webView.title ?? ""
        }
    }
}

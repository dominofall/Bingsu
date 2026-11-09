import SwiftUI

/// 빙수 애플워치 컨트롤러. iPhone 빙수가 게임 중일 때 버튼을 보낸다 (docs/watch/research.md)
@main
struct BingsuWatchApp: App {
    @StateObject private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            TabView {
                PadView(link: link)
                StatsView(link: link)
            }
            .tabViewStyle(.verticalPage)
            .environmentObject(link)
            .onAppear { link.selfTestIfAsked() }
        }
    }
}

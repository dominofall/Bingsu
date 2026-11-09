import SwiftUI

/// "새로운 점": 업데이트 뒤 처음 켤 때 홈 위에 한 번 띄우는 작은 시트 (2026-11-10 사용자 요청, 빌드 33 부터).
/// 사용자 결정: 자세한 글은 사이트 패치노트(bingsu.domino.kim/notes)가 맡고, 여기는 **빌드마다 핵심 세 줄 이하**만. 전체 화면은 방해가 커서 안 씀.
/// 글은 빌드마다 `notes` 맨 위에 더한다. 심사관·테스터가 보는 글이므로 특정 게임 이름은 쓰지 않는다.
/// 마지막으로 본 빌드(`seenKey`)보다 큰 빌드의 글을 모아 보여 준다. 처음 설치(게임 없음)에는 띄우지 않고 본 것으로 적는다.
enum WhatsNew {
    struct Item: Identifiable {
        let symbol: String
        let text: String
        var id: String { text }
    }
    struct Note: Identifiable {
        let build: Int
        let title: String
        let items: [Item]
        var id: Int { build }
    }

    static let seenKey = "bingsu.whatsNewSeen"
    /// 이 빌드 전의 변화는 보여 주지 않는다
    static let firstBuild = 33
    /// 자세한 글
    static let notesURL = URL(string: "https://bingsu.domino.kim/notes/")!

    /// 새 빌드는 맨 위에. 빌드마다 세 줄 이하
    static let notes: [Note] = [
        Note(build: 35, title: "iPhone 을 iPad 의 컨트롤러로", items: [
            Item(symbol: "gamecontroller", text: "iPhone 홈의 게임패드 단추로 iPad 의 빙수에 연결해요. iPad 설정 › 컨트롤러에서 켜요"),
            Item(symbol: "rectangle.portrait.rotate", text: "배치 다섯 가지, 가로·세로 모두. 십자키는 왼쪽 아무 데나 대면 생겨요"),
            Item(symbol: "iphone.radiowaves.left.and.right", text: "게임 진동은 손에 든 iPhone 에서. 연결되면 iPad 가상 패드는 숨겨져요"),
        ]),
        Note(build: 34, title: "새로운 점 알림", items: [
            Item(symbol: "sparkles", text: "업데이트 뒤 처음 켤 때 바뀐 점을 짧게 알려 드려요. 설정 › 정보에서 다시 볼 수 있어요"),
        ]),
        Note(build: 33, title: "애플워치 컨트롤러 다듬기", items: [
            Item(symbol: "applewatch", text: "원반 십자키가 커지고 A·B·X·Y 가 원반을 감싸는 모양이 됐어요"),
            Item(symbol: "arrow.up.arrow.down", text: "크라운을 올리면 ▲, 내리면 ▼. − 와 + 를 길게 누르면 일시정지"),
            Item(symbol: "hand.tap", text: "버튼마다 진동이 달라요. 워치를 쓰는 동안 iPhone 가상 패드는 숨겨져요"),
        ]),
    ]

    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// 이번에 보여 줄 글 (오래된 것부터 위에). 없으면 빈 배열
    static func pending(_ d: UserDefaults = .standard) -> [Note] {
        let seen = d.object(forKey: seenKey) as? Int ?? (firstBuild - 1)
        return notes.filter { $0.build > seen && $0.build <= currentBuild }.sorted { $0.build < $1.build }
    }

    static func markSeen(_ d: UserDefaults = .standard) { d.set(currentBuild, forKey: seenKey) }
}

/// 업데이트 뒤 한 번 뜨는 작은 시트: 제목, 빌드별 핵심 줄, 사이트 링크, 확인. 내용 높이에 맞춘다 (`sheetHeight`)
struct WhatsNewSheet: View {
    let notes: [WhatsNew.Note]
    @Environment(\.dismiss) private var dismiss

    /// 시트 높이: 머리 + 빌드마다 머리글 + 줄 수
    var sheetHeight: CGFloat {
        let lines = notes.reduce(0) { $0 + $1.items.count }
        return 150 + CGFloat(notes.count) * 34 + CGFloat(lines) * 46 + (notes.count > 1 ? 10 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "snowflake")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("새로운 점").font(.title3.weight(.semibold))
                    Text(notes.count == 1 ? "빌드 \(notes[0].build)" : "빌드 \(notes.first!.build)–\(notes.last!.build)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(notes) { n in
                    if notes.count > 1 {
                        Text("빌드 \(n.build) · \(n.title)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    ForEach(n.items) { it in WhatsNewRow(item: it) }
                }
            }
            Link(destination: WhatsNew.notesURL) {
                Label("자세한 내용 · bingsu.domino.kim", systemImage: "safari").font(.footnote)
            }
            Button { dismiss() } label: { Text("확인").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .tint(Palette.accent)
        .onDisappear { WhatsNew.markSeen() }
    }
}

/// 핵심 한 줄: 아이콘 + 글
struct WhatsNewRow: View {
    let item: WhatsNew.Item
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol).font(.body.weight(.medium)).foregroundStyle(Palette.accent).frame(width: 26, alignment: .center).padding(.top, 1)
            Text(item.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 설정 › 정보 › 새로운 점: 지금까지의 글 전체
struct WhatsNewListView: View {
    var body: some View {
        List {
            ForEach(WhatsNew.notes.filter { $0.build <= WhatsNew.currentBuild }) { n in
                Section("빌드 \(n.build) · \(n.title)") {
                    ForEach(n.items) { it in WhatsNewRow(item: it).padding(.vertical, 2) }
                }
            }
            Section { Link(destination: WhatsNew.notesURL) { Label("자세한 내용 · bingsu.domino.kim", systemImage: "safari") } }
        }
        .navigationTitle("새로운 점")
        .navigationBarTitleDisplayMode(.inline)
    }
}

import SwiftUI

/// "새로운 기능"(화면 표기; 코드명 WhatsNew): 업데이트 뒤 처음 켤 때 홈 위에 한 번 띄우는 작은 시트 (2026-11-10 사용자 요청, 빌드 33 부터).
/// 사용자 결정: 자세한 글은 사이트 패치노트(bingsu.domino.kim/notes)가 맡고, 여기는 **빌드마다 핵심 세 줄 이하**만. 전체 화면은 방해가 커서 안 씀.
/// 글은 빌드마다 `notes` 맨 위에 더한다. 심사관·테스터가 보는 글이므로 특정 게임 이름은 쓰지 않는다.
/// 한 건의 형식은 **제목 · 한 줄(`message`, 사용자가 직접 씀) · 요점 셋 이하 · 행동 링크(`action`)** 로 고정한다.
/// 같은 틀로 설문·Q&A 안내도 띄울 수 있게 (링크만 bingsu.domino.kim 의 설문·Q&A 주소로 바꾼다). 사이트 패치노트도 같은 형식을 따른다.
/// 마지막으로 본 빌드(`seenKey`)보다 큰 빌드의 글을 모아 보여 준다. 처음 설치(게임 없음)에는 띄우지 않고 본 것으로 적는다.
/// "확인"·바깥 터치·쓸어내리기는 닫기만 한다 → 다음에 켤 때 다시 뜬다. "다시 보지 않기"를 눌러야 이 빌드까지를 본 것으로 적어
/// 그 내용은 다시 안 뜬다 (새 빌드가 오면 그 빌드 글만 다시 뜸). 아예 끄는 것은 설정 › 새로운 점의 스위치. 2026-11-10 사용자 결정
enum WhatsNew {
    struct Item: Identifiable {
        let symbol: String
        let text: String
        var id: String { text }
    }
    /// 하단 링크. 시트에는 빌드의 `action`(기본 패치노트, 설문이면 그 주소)과 Q&A 게시판이 늘 나란히 있다 — "불편한 점은 Q&A로" 가 어디인지 바로 보이게
    struct Action {
        let label: String
        let symbol: String
        let url: URL
        static let notes = Action(label: "자세한 내용", symbol: "safari", url: WhatsNew.notesURL)
        static func survey(_ url: URL) -> Action { Action(label: "설문 참여", symbol: "checklist", url: url) }
        static let qna = Action(label: "Q&A 게시판", symbol: "bubble.left.and.bubble.right", url: WhatsNew.qnaURL)
    }
    struct Note: Identifiable {
        let build: Int
        let title: String
        /// 빌드 숫자 옆에 붙는 한 줄. 사용자(개발자)가 그 빌드의 느낌을 직접 쓴다. 비우면 안 보임
        var message: String = ""
        let items: [Item]
        var action: Action = .notes
        var id: Int { build }
    }

    static let seenKey = "bingsu.whatsNewSeen"
    /// 새 빌드마다 띄울지 (기본 켬). 설정 › 새로운 점에서 끈다
    static let enabledKey = "bingsu.whatsNewPopup"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    /// 이 빌드 전의 변화는 보여 주지 않는다
    static let firstBuild = 33
    /// 자세한 글 · 사이트의 Q&A 게시판
    static let notesURL = URL(string: "https://bingsu.domino.kim/notes/")!
    static let qnaURL = URL(string: "https://bingsu.domino.kim/qna/")!

    /// 새 빌드는 맨 위에. 빌드마다 세 줄 이하
    static let notes: [Note] = [
        Note(build: 36, title: "iPhone 을 iPad 의 컨트롤러로", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "gamecontroller", text: "iPhone 홈의 게임패드 단추로 iPad 의 빙수에 연결해요. iPad 설정 › 컨트롤러에서 켜요"),
            Item(symbol: "rectangle.portrait.rotate", text: "배치 다섯 가지, 가로·세로 모두. 십자키는 왼쪽 아무 데나 대면 생겨요"),
            Item(symbol: "iphone.radiowaves.left.and.right", text: "게임 진동은 손에 든 iPhone 에서. 연결되면 iPad 가상 패드는 숨겨져요"),
        ]),
        Note(build: 35, title: "새로운 기능 알림 다듬기", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "bell.slash", text: "\"다시 보지 않기\"를 누를 때까지 켤 때마다 떠요. 다음 빌드가 오면 그 빌드 것만 다시 떠요"),
            Item(symbol: "switch.2", text: "아예 끄려면 설정 › 새로운 기능의 스위치를 끄세요"),
            Item(symbol: "bubble.left.and.bubble.right", text: "Q&A 게시판 링크를 넣었어요. 설정 › 정보에서도 갈 수 있어요"),
        ]),
        Note(build: 34, title: "새로운 기능 알림 개편", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "sparkles", text: "업데이트 뒤 처음 켤 때 바뀐 점을 짧게 알려 드려요. 설정 › 정보에서 다시 볼 수 있어요"),
        ]),
        Note(build: 33, title: "애플워치 컨트롤러 연동 기능 추가", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "applewatch", text: "원반 십자키가 커지고 A·B·X·Y 가 원반을 감싸는 모양이 됐어요"),
            Item(symbol: "arrow.up.arrow.down", text: "크라운을 올리면 ▲, 내리면 ▼. − 와 + 를 길게 누르면 일시정지"),
            Item(symbol: "hand.tap", text: "버튼마다 진동이 달라요. 워치를 쓰는 동안 iPhone 가상 패드는 숨겨져요"),
        ]),
    ]

    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// 이번에 보여 줄 글 (오래된 것부터 위에). 없거나 알림을 껐으면 빈 배열
    static func pending(_ d: UserDefaults = .standard) -> [Note] {
        guard d.object(forKey: enabledKey) as? Bool ?? true else { return [] }
        let seen = d.object(forKey: seenKey) as? Int ?? (firstBuild - 1)
        return notes.filter { $0.build > seen && $0.build <= currentBuild }.sorted { $0.build < $1.build }
    }

    static func markSeen(_ d: UserDefaults = .standard) { d.set(currentBuild, forKey: seenKey) }
}

/// 업데이트 뒤 한 번 뜨는 작은 시트: 제목, 빌드별 핵심 줄, 사이트 링크, 확인 · 다시 보지 않기. 내용 높이에 맞춘다 (`sheetHeight`).
/// 확인·쓸어내리기·바깥 터치는 닫기만 해서 다음에 다시 뜬다. "다시 보지 않기"만 본 것으로 적는다
struct WhatsNewSheet: View {
    let notes: [WhatsNew.Note]
    @Environment(\.dismiss) private var dismiss

    /// 가장 새 빌드의 한 줄과 링크를 쓴다
    private var newest: WhatsNew.Note { notes.last! }
    private var buildText: String { notes.count == 1 ? "빌드 \(notes[0].build)" : "빌드 \(notes.first!.build)–\(notes.last!.build)" }

    /// 시트 높이: 손잡이 + 머리 + 빌드마다 머리글 + 줄 수 + 링크 + 버튼 둘
    var sheetHeight: CGFloat {
        let lines = notes.reduce(0) { $0 + $1.items.count }
        return 206 + CGFloat(notes.count) * 34 + CGFloat(lines) * 46 + (notes.count > 1 ? 10 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 손잡이는 직접 그린다: 시스템 것은 위 여백이 좁다. iPad 폼 시트에는 손잡이 대신 여백만
            if UIDevice.current.userInterfaceIdiom == .pad {
                Color.clear.frame(height: 8)
            } else {
                Capsule().fill(.tertiary).frame(width: 36, height: 5).frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, -2)
            }
            HStack(spacing: 12) {
                Image(systemName: "snowflake")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("새로운 기능").font(.title3.weight(.semibold))
                    Text(newest.message.isEmpty ? buildText : "\(buildText) · \(newest.message)")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            // 여러 빌드를 건너뛰어 글이 길면(작은 iPhone) 가운데만 스크롤. 맞으면 스크롤 안 됨
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(notes) { n in
                        if notes.count > 1 {
                            Text("빌드 \(n.build) · \(n.title)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                        }
                        ForEach(n.items) { it in WhatsNewRow(item: it) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 18) {
                ForEach([newest.action, WhatsNew.Action.qna], id: \.url) { a in
                    Link(destination: a.url) { Label(a.label, systemImage: a.symbol).font(.footnote) }
                }
                Spacer(minLength: 0)
                Text("bingsu.domino.kim").font(.caption2).foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                Button { dismiss() } label: { Text("확인").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("다시 보지 않기") { WhatsNew.markSeen(); dismiss() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
        .tint(Palette.accent)
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

/// 설정 › 정보 › 새로운 점: 알림 스위치 + 지금까지의 글 전체
struct WhatsNewListView: View {
    @AppStorage(WhatsNew.enabledKey) private var popup = true

    var body: some View {
        List {
            Section {
                Toggle("새 빌드마다 알림", isOn: $popup)
            } footer: {
                Text("업데이트 뒤 처음 켤 때 바뀐 점을 짧게 띄워요.")
            }
            ForEach(WhatsNew.notes.filter { $0.build <= WhatsNew.currentBuild }) { n in
                Section {
                    ForEach(n.items) { it in WhatsNewRow(item: it).padding(.vertical, 2) }
                } header: {
                    Text("빌드 \(n.build) · \(n.title)")
                } footer: {
                    if !n.message.isEmpty { Text(n.message) }
                }
            }
            Section {
                Link(destination: WhatsNew.notesURL) { Label("자세한 내용 · bingsu.domino.kim", systemImage: "safari") }
                Link(destination: WhatsNew.qnaURL) { Label("Q&A 게시판 · bingsu.domino.kim", systemImage: "bubble.left.and.bubble.right") }
            }
        }
        .navigationTitle("새로운 기능")
        .navigationBarTitleDisplayMode(.inline)
    }
}

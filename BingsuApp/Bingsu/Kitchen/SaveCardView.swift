import SwiftUI

/// 세이브 카드 한 장 (빌드 49). 상태 저장 목록(`ScoopListView`)과 세이브 파일 화면(`SaveFilesView`)이 같이 쓴다.
/// ┌사진┬ 장소(맵 이름)                       슬롯 1
/// │    │ 캐릭터 그림 · 플레이 1시간 23분      (Essentials: 트레이너 · 배지 N개, 포켓몬 아이콘)
/// └────┴ 어제 오후 3:12
/// 파일 이름은 보이지 않는다 (자세히 메뉴에서만). 정보는 `SaveCard.card` 가 고른다
struct SaveCardView: View {
    let dish: Dish
    let fileName: String
    let date: Date?
    /// 상태 저장 칸에 붙인 이름
    var name: String? = nil
    @State private var card: SaveCard.Card?

    private var label: String? { SaveCard.slotLabel(fileName) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            photo
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 6)
                    if let label, title != label { badge(label) }
                }
                if let name, !name.isEmpty, name != title {
                    Text(name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                }
                if let card, !card.chars.isEmpty || detail != nil {
                    HStack(spacing: 6) {
                        if !card.chars.isEmpty {
                            HStack(spacing: 1) {
                                ForEach(card.chars.indices, id: \.self) { i in sprite(card.chars[i], height: 30) }
                            }
                        }
                        if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                if let card, !card.party.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(card.party.indices, id: \.self) { i in sprite(card.party[i], height: 28) }
                    }
                    .accessibilityLabel("포켓몬 \(card.party.count)마리")
                }
                if let date {
                    Text(SaveCard.when(date)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .task(id: "\(fileName)|\(date?.timeIntervalSince1970 ?? 0)") {
            let d = dish, n = fileName
            card = await Task.detached(priority: .userInitiated) { SaveCard.card(d, n) }.value
        }
    }

    private var title: String {
        if let m = card?.info?.map, !m.isEmpty { return m }
        if let name, !name.isEmpty { return name }
        return label ?? fileName
    }

    private var detail: String? {
        guard let info = card?.info else { return nil }
        var parts: [String] = []
        if let t = info.trainer { parts.append(t) }
        if let b = info.badges, info.trainer != nil || !(info.party ?? []).isEmpty { parts.append("배지 \(b)개") }
        if let p = info.play, p > 0 { parts.append((parts.isEmpty ? "플레이 " : "") + SaveCard.playText(p)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var photo: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let p = card?.photo {
                Image(uiImage: p).resizable().scaledToFill()
            } else if let c = card?.chars.first {
                Image(uiImage: c).resizable().interpolation(.none).scaledToFit().padding(14)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 104, height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private func sprite(_ img: UIImage, height: CGFloat) -> some View {
        let w = img.size.height > 0 ? height * img.size.width / img.size.height : height
        return Image(uiImage: img).resizable().interpolation(.none).frame(width: w, height: height)
    }

    private func badge(_ t: String) -> some View {
        let quick = t == "빠른 저장"
        return Text(t).font(.caption2.weight(.bold))
            .foregroundStyle(quick ? Color.white : Color.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(quick ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
            .fixedSize()
    }
}

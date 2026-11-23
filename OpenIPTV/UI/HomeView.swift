import SwiftUI

/// Home: shelves of what you watch, then every category as a card.
struct HomeView: View {
    @Environment(Library.self) private var library
    @Environment(PlayerModel.self) private var player
    @Binding var selection: SidebarItem?
    let nav: Navigator

    private let cardColumns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 22, alignment: .top)]

    var body: some View {
        let recents = library.channels(for: .recents)
        let favorites = library.channels(for: .favorites)
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if library.channels.isEmpty {
                    VStack(spacing: 10) {
                        if library.isLoading { ProgressView() }
                        Text(library.loadError ?? "Loading channels…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .padding(.horizontal, 36)
                }
                if !recents.isEmpty {
                    shelf("Continue Watching", recents, .recents)
                }
                if !favorites.isEmpty {
                    shelf("Favorites", favorites, .favorites)
                }
                if !library.groups.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Browse").font(.title2.weight(.bold))
                        LazyVGrid(columns: cardColumns, spacing: 22) {
                            ForEach(library.groups) { group in
                                CategoryCard(group: group, channels: library.byGroup[group.id] ?? []) {
                                    selection = .group(group.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 36)
                }
            }
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .onAppear { nav.setItems([], focusFirst: false) }
    }

    private func shelf(_ title: String, _ channels: [Channel], _ target: SidebarItem) -> some View {
        Shelf(title: title, channels: Array(channels.prefix(20)), target: target, selection: $selection)
    }
}

/// A horizontal row of tiles with ‹ › buttons (not everyone knows Shift-scroll).
private struct Shelf: View {
    @Environment(Library.self) private var library
    @Environment(PlayerModel.self) private var player
    let title: String
    let channels: [Channel]
    let target: SidebarItem
    @Binding var selection: SidebarItem?
    @State private var leadingID: String?
    @State private var width: CGFloat = 900

    private let tileWidth: CGFloat = 220
    private let spacing: CGFloat = 22

    private var pageSize: Int { max(1, Int((width - 72 + spacing) / (tileWidth + spacing))) }
    private var leadingIndex: Int { leadingID.flatMap { id in channels.firstIndex { $0.id == id } } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { selection = target } label: {
                    HStack(spacing: 4) {
                        Text(title).font(.title2.weight(.bold))
                        Image(systemName: "chevron.right").font(.title3.weight(.bold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if channels.count > pageSize {
                    HStack(spacing: 8) {
                        pageButton("chevron.left", enabled: leadingIndex > 0) { page(-1) }
                        pageButton("chevron.right", enabled: leadingIndex + pageSize < channels.count) { page(1) }
                    }
                }
            }
            .padding(.horizontal, 36)

            // The shelf spans the whole pane, so cards scroll on under the sidebar glass instead of vanishing.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(channels.prefix(20)) { channel in
                        ShelfTile(channel: channel, isFavorite: library.isFavorite(channel)) {
                            player.play(channel, in: channels)
                        }
                        .frame(width: tileWidth)
                        .id(channel.id)
                        .contextMenu {
                            Button("Play") { player.play(channel, in: channels) }
                            Divider()
                            if target == .recents {
                                Button("Remove from Continue Watching") {
                                    withAnimation(.easeOut(duration: 0.2)) { library.removeRecent(channel) }
                                }
                            }
                            Menu("Add to Playlist") { PlaylistMenuItems(channel: channel) }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 6)
            }
            .contentMargins(.horizontal, 36, for: .scrollContent)
            .scrollPosition(id: $leadingID, anchor: .leading)
            // Hover lift and shadow spill outside the shelf instead of being cut off.
            .scrollClipDisabled()
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }

    private func page(_ direction: Int) {
        let target = min(max(leadingIndex + direction * pageSize, 0), max(0, channels.count - pageSize))
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { leadingID = channels[target].id }
    }

    private func pageButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// A tile that manages its own hover focus (shelves aren't keyboard-navigated).
private struct ShelfTile: View {
    let channel: Channel
    let isFavorite: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ChannelTile(channel: channel, focused: hovering, isFavorite: isFavorite, action: action)
            .onHover { hovering = $0 }
    }
}

/// Category card: a color drawn from the name, the category's best logo, and its name.
struct CategoryCard: View {
    let group: ChannelGroup
    let channels: [Channel]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [color.opacity(0.95), color.opacity(0.55), .black.opacity(0.85)],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                if let sample = channels.first(where: { $0.logo != nil }) {
                    LogoView(channel: sample)
                        .padding(28)
                        .padding(.bottom, 30)
                        .opacity(0.9)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name.titleCased)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(2)
                    Text("\(channels.count) channels")
                        .font(.caption.weight(.medium))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.5 : 0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(hovering ? 0.45 : 0.15), radius: hovering ? 20 : 5, y: hovering ? 12 : 3)
            .scaleEffect(hovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hovering)
    }

    private var color: Color {
        var h: UInt64 = 1469598103934665603
        for b in group.name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Color(hue: Double(h % 360) / 360, saturation: 0.6, brightness: 0.6)
    }
}

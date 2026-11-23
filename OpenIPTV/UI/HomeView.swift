import SwiftUI

/// Home: Continue Watching, recent channels, favorites, the newest movies and series, then every
/// channel category as a card. Movie / series pages open right here (navigation stack).
struct HomeView: View {
    @Environment(Library.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(VODStore.self) private var vod
    @Binding var selection: SidebarItem?
    let nav: Navigator

    private let cardColumns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 22, alignment: .top)]

    var body: some View {
        let recents = library.channels(for: .recents)
        let favorites = library.channels(for: .favorites)
        NavigationStack {
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
                    if !vod.recents.isEmpty {
                        ContinueWatchingRow(selection: $selection)
                    }
                    if !recents.isEmpty {
                        shelf("Recent Channels", recents, .recents)
                    }
                    if !favorites.isEmpty {
                        shelf("Favorites", favorites, .favorites)
                    }
                    let movies = vod.latestMovies()
                    if !movies.isEmpty {
                        PagedRow(title: "Latest Movies", target: .movies, selection: $selection, items: movies, itemWidth: 150) { m in
                            NavigationLink(value: m) {
                                PosterCard(title: m.title, poster: m.poster, caption: m.year ?? "",
                                           badges: vod.quick(m)?.badges ?? [], detail: vod.categoryLabel(movie: m))
                            }
                            .task { vod.enrich(m) }
                            .buttonStyle(.plain)
                        }
                    }
                    let series = vod.latestSeries()
                    if !series.isEmpty {
                        PagedRow(title: "Latest Series", target: .series, selection: $selection, items: series, itemWidth: 150) { s in
                            NavigationLink(value: s) {
                                PosterCard(title: s.title, poster: s.cover, caption: s.year ?? "",
                                           badges: vod.quick(s)?.badges ?? [], detail: vod.categoryLabel(series: s))
                            }
                            .task { vod.enrich(s) }
                            .buttonStyle(.plain)
                        }
                    }
                    if !library.groups.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Browse Channels").font(.title2.weight(.bold))
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
            .navigationDestination(for: Movie.self) { MovieDetailView(movie: $0) }
            .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
        }
        .onAppear { nav.setItems([], focusFirst: false) }
    }

    private func shelf(_ title: String, _ channels: [Channel], _ target: SidebarItem) -> some View {
        Shelf(title: title, channels: Array(channels.prefix(20)), target: target, selection: $selection)
    }
}

/// A titled horizontal row with ‹ › page buttons (not everyone knows Shift-scroll).
/// Pages with its own index + ScrollViewReader (no scroll-position binding, which can loop layout).
struct PagedRow<Item: Identifiable, Cell: View>: View {
    let title: String
    var target: SidebarItem? = nil
    @Binding var selection: SidebarItem?
    let items: [Item]
    let itemWidth: CGFloat
    var spacing: CGFloat = 22
    @ViewBuilder let cell: (Item) -> Cell

    @State private var pageStart = 0
    @State private var pageSize = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { if let target { selection = target } } label: {
                    HStack(spacing: 4) {
                        Text(title).font(.title2.weight(.bold))
                        if target != nil {
                            Image(systemName: "chevron.right").font(.title3.weight(.bold)).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(target == nil)
                Spacer()
                if items.count > pageSize {
                    HStack(spacing: 8) {
                        PageButton(symbol: "chevron.left", enabled: pageStart > 0) { page(-1) }
                        PageButton(symbol: "chevron.right", enabled: pageStart + pageSize < items.count) { page(1) }
                    }
                }
            }
            .padding(.horizontal, 36)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(items) { item in
                            cell(item).frame(width: itemWidth).id(item.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .contentMargins(.horizontal, 36, for: .scrollContent)
                .scrollClipDisabled()
                .onChange(of: pageStart) { _, start in
                    guard items.indices.contains(start) else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { proxy.scrollTo(items[start].id, anchor: .leading) }
                }
            }
        }
        .onGeometryChange(for: Int.self, of: { max(1, Int(($0.size.width - 72 + spacing) / (itemWidth + spacing))) }) { pageSize = $0 }
        .onChange(of: items.count) { pageStart = 0 }
    }

    private func page(_ direction: Int) {
        pageStart = min(max(pageStart + direction * pageSize, 0), max(0, items.count - pageSize))
    }
}

struct PageButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
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

/// Movies and episodes you're partway through: wide cards with a progress bar, click to resume.
struct ContinueWatchingRow: View {
    @Environment(VODStore.self) private var vod
    @Environment(PlayerModel.self) private var player
    @Binding var selection: SidebarItem?

    var body: some View {
        PagedRow(title: "Continue Watching", selection: $selection, items: vod.recents, itemWidth: 280) { r in
            ContinueCard(recent: r) {
                if let item = vod.item(for: r) { player.playVOD(item) }
            }
            .contextMenu {
                Button("Resume") { if let item = vod.item(for: r) { player.playVOD(item) } }
                Button("Remove from Continue Watching", role: .destructive) {
                    withAnimation(.easeOut(duration: 0.2)) { vod.removeRecent(r) }
                }
            }
        }
    }
}

private struct ContinueCard: View {
    let recent: VODRecent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottom) {
                    ArtworkView(url: recent.episode?.image ?? recent.artwork, maxPixels: 640, placeholder: recent.title)
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 6) {
                        Spacer()
                        HStack {
                            Image(systemName: "play.fill").font(.caption)
                            Text(recent.remaining).font(.caption.weight(.semibold))
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        GeometryReader { geo in
                            Capsule().fill(.white.opacity(0.3))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white)
                                        .frame(width: geo.size.width * min(1, recent.position / max(recent.duration, 1)))
                                }
                        }
                        .frame(height: 4)
                    }
                    .padding(12)
                }
                .frame(width: 280, height: 158)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(hovering ? 0.5 : 0.08), lineWidth: hovering ? 1.5 : 1)
                }
                .shadow(color: .black.opacity(hovering ? 0.45 : 0.15), radius: hovering ? 20 : 5, y: hovering ? 12 : 3)
                .scaleEffect(hovering ? 1.04 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recent.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let sub = recent.subtitle {
                        Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: 280, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hovering)
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
    // Paging is driven only by the ‹ › buttons (no scroll-position binding: SwiftUI rewrites those
    // during layout, which can spin into a layout loop and crash).
    @State private var pageStart = 0
    @State private var pageSize = 4

    private let tileWidth: CGFloat = 220
    private let spacing: CGFloat = 22

    private var leadingIndex: Int { min(pageStart, max(0, channels.count - 1)) }

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
            ScrollViewReader { proxy in
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
                .padding(.vertical, 6)
            }
            .contentMargins(.horizontal, 36, for: .scrollContent)
            .onChange(of: pageStart) { _, start in
                guard channels.indices.contains(start) else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { proxy.scrollTo(channels[start].id, anchor: .leading) }
            }
            // Hover lift and shadow spill outside the shelf instead of being cut off.
            .scrollClipDisabled()
            }
        }
        // Only an integer page size is stored, so this fires on real changes, not every layout pass.
        .onGeometryChange(for: Int.self, of: { max(1, Int(($0.size.width - 72 + spacing) / (tileWidth + spacing))) }) { pageSize = $0 }
    }

    private func page(_ direction: Int) {
        pageStart = min(max(leadingIndex + direction * pageSize, 0), max(0, channels.count - pageSize))
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

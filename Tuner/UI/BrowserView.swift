import SwiftUI

struct BrowserView: View {
    @Environment(Library.self) private var library
    @Environment(PlayerModel.self) private var player
    @State private var selection: SidebarItem? = .all
    @State private var query = ""
    @State private var expanded: Set<String> = []

    private var item: SidebarItem { selection ?? .all }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let shown = isSearching ? library.search(query) : library.channels(for: item)
        NavigationSplitView {
            Sidebar(selection: $selection, expanded: $expanded)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            ChannelGrid(
                channels: shown,
                title: isSearching ? "Results" : library.title(for: item),
                emptyMessage: emptyMessage,
                scrollID: isSearching ? "search" : "\(item)"
            )
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search channels")
        .onSubmit(of: .search) {
            if let first = shown.first { player.play(first, in: shown) }
        }
        .toolbar(player.isPresented ? .hidden : .visible, for: .windowToolbar)
        .navigationTitle("")
    }

    private var emptyMessage: String {
        if isSearching { return "No channels match “\(query)”." }
        if library.isLoading && library.channels.isEmpty { return "Loading channels…" }
        if let e = library.loadError, library.channels.isEmpty { return e }
        switch item {
        case .favorites: return "Right-click a channel and choose Add to Favorites."
        case .recents: return "Channels you watch show up here."
        default: return "No channels."
        }
    }
}

struct Sidebar: View {
    @Environment(Library.self) private var library
    @Binding var selection: SidebarItem?
    @Binding var expanded: Set<String>

    var body: some View {
        List(selection: $selection) {
            Section {
                row("All Channels", "square.grid.2x2", .all, library.channels.count)
                row("Favorites", "star", .favorites, library.favorites.count)
                row("Recently Watched", "clock", .recents, nil)
            }
            ForEach(library.sections) { section in
                Section(section.title, isExpanded: binding(section.id)) {
                    ForEach(section.groups, id: \.group.id) { entry in
                        Text(entry.label)
                            .lineLimit(1)
                            .badge(library.byGroup[entry.group.id]?.count ?? 0)
                            .tag(SidebarItem.group(entry.group.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SourceBar() }
    }

    private func row(_ title: String, _ icon: String, _ tag: SidebarItem, _ count: Int?) -> some View {
        Label(title, systemImage: icon)
            .badge(count ?? 0)
            .tag(tag)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } }
        )
    }
}

/// Bottom of the sidebar: which playlist is active, when it was updated, refresh.
struct SourceBar: View {
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 8) {
            if library.sources.count > 1 {
                Menu {
                    ForEach(library.sources) { s in
                        Button(s.name) { Task { await library.activate(s.id) } }
                    }
                } label: {
                    Text(library.active?.name ?? "").lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text(library.active?.name ?? "").lineLimit(1).font(.callout.weight(.medium))
            }
            Spacer(minLength: 4)
            if library.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await library.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(updatedText)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
        .background(.bar)
    }

    private var updatedText: String {
        guard let d = library.fetchedAt, d > .distantPast else { return "Refresh" }
        return "Updated " + d.formatted(.relative(presentation: .named))
    }
}

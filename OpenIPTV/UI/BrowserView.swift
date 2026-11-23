import SwiftUI

enum ViewMode: String, CaseIterable {
    case grid, list
    var icon: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    var label: String { self == .grid ? "Grid" : "List" }
}

struct BrowserView: View {
    @Environment(Library.self) private var library
    @Environment(PlayerModel.self) private var player
    @AppStorage("viewMode") private var viewMode: ViewMode = .grid
    @State private var selection: SidebarItem? = .home
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var nav = Navigator()

    private var item: SidebarItem { selection ?? .home }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let shown = isSearching ? library.search(query) : library.channels(for: item)
        NavigationSplitView {
            Sidebar(selection: $selection, expanded: $expanded)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            if item == .home && !isSearching {
                HomeView(selection: $selection, nav: nav)
            } else {
            ChannelBrowser(
                channels: shown,
                title: isSearching ? "Results" : library.title(for: item).titleCased,
                emptyMessage: emptyMessage,
                scrollID: isSearching ? "search" : "\(item)",
                showGroup: isSearching || !isGroup,
                mode: viewMode,
                nav: nav
            )
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search channels")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if item != .home || isSearching {
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { m in
                        Label(m.label, systemImage: m.icon).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Grid or list (⌘1 / ⌘2)")
                }
            }
        }
        .toolbar(player.isFull ? .hidden : .visible, for: .windowToolbar)
        .navigationTitle("")
        .onAppear {
            nav.isActive = { !player.isFull }
            nav.onPlay = { channel, list in player.play(channel, in: list) }
            nav.query = { query }
            nav.setQuery = { query = $0 }
            nav.install()
        }
        .onChange(of: "\(query)|\(item)|\(library.channels.count)|\(library.favorites.count)", initial: true) {
            nav.setItems(shown, focusFirst: isSearching)
        }
        .onChange(of: player.channel?.id) { _, id in
            // Coming back from the player, focus stays on what you watched.
            if let id, nav.items.contains(where: { $0.id == id }) {
                nav.focusID = id
                nav.scrollTarget = id
            }
        }
        .onChange(of: selection) { query = "" }
        .onChange(of: viewMode) {
            let id = nav.focusID
            nav.scrollTarget = nil
            DispatchQueue.main.async { nav.scrollTarget = id }
        }
    }

    private var isGroup: Bool {
        if case .group = item { return true }
        return false
    }

    private var emptyMessage: String {
        if isSearching { return "No channels match “\(query)”." }
        if library.isLoading && library.channels.isEmpty { return "Loading channels…" }
        if let e = library.loadError, library.channels.isEmpty { return e }
        switch item {
        case .favorites: return "Right-click a channel, or press S while watching, to add it here."
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
                row("Home", "house", .home, nil)
                row("All Channels", "square.grid.2x2", .all, library.channels.count)
            }
            Section("Library") {
                row("Favorites", "star", .favorites, library.favorites.count)
                row("Recently Watched", "clock", .recents, nil)
            }
            if !library.sections.isEmpty {
                Section("Categories") {
                    ForEach(library.sections) { section in
                        DisclosureGroup(isExpanded: binding(section.id)) {
                            ForEach(section.groups, id: \.group.id) { entry in
                                Text(entry.label.titleCased)
                                    .lineLimit(1)
                                    .badge(library.byGroup[entry.group.id]?.count ?? 0)
                                    .tag(SidebarItem.group(entry.group.id))
                            }
                        } label: {
                            Label(section.title.titleCased, systemImage: Self.icon(for: section))
                                .lineLimit(1)
                                .badge(section.groups.reduce(0) { $0 + (library.byGroup[$1.group.id]?.count ?? 0) })
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.2)) { binding(section.id).wrappedValue.toggle() }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .sidebarFooter { SourceBar() }
    }

    private func row(_ title: String, _ icon: String, _ tag: SidebarItem, _ count: Int?) -> some View {
        Label(title, systemImage: icon)
            .badge(count ?? 0)
            .tag(tag)
    }

    /// A fitting symbol from the names inside the section.
    static func icon(for section: GroupSection) -> String {
        if section.id == "_other" { return "square.stack" }
        let names = ([section.title] + section.groups.map(\.group.name)).joined(separator: " ").uppercased()
        if section.groups.allSatisfy({ $0.group.name.uppercased().contains("SPORT") }) || section.title.uppercased() == "BEIN" {
            return "sportscourt"
        }
        if names.contains("KIDS") && section.groups.count <= 2 { return "figure.and.child.holdinghands" }
        if names.contains("MUSIC") && section.groups.count <= 2 { return "music.note" }
        return "globe"
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
        HStack(spacing: 10) {
            Text(initials)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            if library.sources.count > 1 {
                Menu {
                    ForEach(library.sources) { s in
                        Button(s.name) { Task { await library.activate(s.id) } }
                    }
                } label: {
                    Text(library.active?.name ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text(library.active?.name ?? "").font(.callout.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if library.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await library.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(updatedText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var initials: String {
        let words = (library.active?.name ?? "TV").split(separator: " ")
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var updatedText: String {
        guard let d = library.fetchedAt, d > .distantPast else { return "Refresh" }
        return "Updated " + d.formatted(.relative(presentation: .named))
    }
}

extension View {
    /// Pins a footer under a scrolling list. On macOS 26 rows fade out under it (scroll edge effect);
    /// before that it sits on an opaque bar so rows never show through the text.
    @ViewBuilder func sidebarFooter<F: View>(@ViewBuilder _ footer: () -> F) -> some View {
        if #available(macOS 26.0, *) {
            self.safeAreaBar(edge: .bottom, spacing: 0, content: footer)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) {
                footer().background(.bar)
            }
        }
    }
}

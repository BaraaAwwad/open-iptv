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
    @State private var playlistRef: PlaylistRef? = .favorites
    @State private var selecting = SelectionModel()
    @State private var qualityFilter: QualityTier?
    // Movies / series filters (same toolbar filter button).
    @State private var vodQuality: String?
    @AppStorage("vodLanguage") private var vodLanguage = ""
    @Environment(VODStore.self) private var vod

    private var item: SidebarItem { selection ?? .home }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let unfiltered = isSearching ? library.search(query)
            : item == .playlists ? library.channels(in: playlistRef ?? .favorites)
            : library.channels(for: item)
        let shown = qualityFilter.map { f in unfiltered.filter { library.tier($0) == f } } ?? unfiltered
        NavigationSplitView {
            Sidebar(selection: $selection, expanded: $expanded)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            if isSearching {
                // Search covers everything: channels, movies and series.
                SearchResultsView(query: query,
                                  channels: library.search(query).filter { vodQuality == nil || library.tier($0).rawValue == vodQuality },
                                  nav: nav, quality: vodQuality, language: vodLanguage)
            } else if item == .home {
                HomeView(selection: $selection, nav: nav)
            } else if item == .movies || item == .series {
                // Search filters the open category here.
                VODBrowser(kind: item == .movies ? .movies : .series, query: "", language: vodLanguage, quality: vodQuality)
                    .id(item)
            } else if item == .playlists && !isSearching {
                // Playlists on the left, that playlist's channels on the right, in one view.
                HStack(spacing: 0) {
                    PlaylistsPane(selection: $playlistRef)
                    Divider()
                    ChannelBrowser(
                        channels: shown,
                        title: library.name(of: playlistRef ?? .favorites),
                        emptyMessage: "Add channels with the + button in the player, or right-click any channel.",
                        scrollID: "playlist-\(String(describing: playlistRef))",
                        showGroup: true,
                        mode: viewMode,
                        nav: nav,
                        selection: selecting,
                        playlist: playlistRef ?? .favorites
                    )
                }
            } else {
                ChannelBrowser(
                    channels: shown,
                    title: isSearching ? "Results" : library.title(for: item).titleCased,
                    emptyMessage: emptyMessage,
                    scrollID: isSearching ? "search" : "\(item)",
                    showGroup: isSearching || !isGroup,
                    mode: viewMode,
                    nav: nav,
                    selection: selecting
                )
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search channels, movies, series")
        // Toolbar items are always present and only disabled where they don't apply: adding and removing
        // them on every page change made AppKit rebuild the toolbar (and re-lay out the sidebar) each time.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // One filter button: channel quality on channel pages; quality + language on Movies / Series.
                Menu {
                    if isVODPage {
                        // Submenus keep the menu short; the long language list is split once more.
                        Menu("Quality: \(vodQuality ?? "All")") {
                            Picker("Quality", selection: $vodQuality) {
                                Text("All Qualities").tag(String?.none)
                                Divider()
                                ForEach(["4K", "1080p", "720p", "SD"], id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                        let langs = VODBrowser.languages(item == .movies ? vod.movieCategories
                                                         : item == .series ? vod.seriesCategories
                                                         : vod.movieCategories + vod.seriesCategories)
                        Menu("Language: \(vodLanguage.isEmpty ? "All" : VODBrowser.languageName(vodLanguage))") {
                            Picker("Language", selection: $vodLanguage) {
                                Text("All Languages").tag("")
                                Divider()
                                ForEach(langs.prefix(12), id: \.tag) { l in
                                    Text("\(VODBrowser.languageName(l.tag)) (\(l.count))").tag(l.tag)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                            if langs.count > 12 {
                                Divider()
                                Menu("More Languages") {
                                    Picker("More Languages", selection: $vodLanguage) {
                                        ForEach(langs.dropFirst(12), id: \.tag) { l in
                                            Text("\(VODBrowser.languageName(l.tag)) (\(l.count))").tag(l.tag)
                                        }
                                    }
                                    .pickerStyle(.inline)
                                    .labelsHidden()
                                }
                            }
                        }
                        if filterActive {
                            Divider()
                            Button("Clear Filters") { vodQuality = nil; vodLanguage = "" }
                        }
                    } else {
                        Picker("Quality", selection: $qualityFilter) {
                            Text("All Qualities").tag(QualityTier?.none)
                            Divider()
                            ForEach(QualityTier.allCases) { t in Text(t.rawValue).tag(QualityTier?.some(t)) }
                        }
                        .pickerStyle(.inline)
                    }
                } label: {
                    Label(filterLabel, systemImage: filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .disabled(!showsChannelList && !isVODPage)
                .help(isVODPage ? "Filter by measured quality or by language" : "Filter by measured quality (only channels that were played or checked have one)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(selecting.isActive ? "Done" : "Select") {
                    if selecting.isActive { selecting.end() } else { selecting.isActive = true }
                }
                .disabled(!showsChannelList)
                .help("Select several channels to add to or remove from a playlist")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { m in
                        Label(m.label, systemImage: m.icon).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .disabled(!showsChannelList)
                .help("Grid or list (⌘1 / ⌘2)")
            }
        }
        .navigationTitle("")
        .onAppear {
            nav.isActive = { !player.isFull }
            nav.onPlay = { channel, list in
                if selecting.isActive { selecting.toggle(channel) } else { player.play(channel, in: list) }
            }
            nav.query = { query }
            nav.setQuery = { query = $0 }
            nav.install()
        }
        .onChange(of: "\(query)|\(item)|\(library.channels.count)|\(library.favorites.count)|\(String(describing: playlistRef))|\(String(describing: qualityFilter))|\(library.playlists.map(\.channelIDs.count))", initial: true) {
            nav.columns = isSearching ? 1 : nav.columns
            nav.setItems(shown, focusFirst: isSearching)
        }
        .onChange(of: player.channel?.id) { _, id in
            // Coming back from the player, focus stays on what you watched.
            if let id, nav.items.contains(where: { $0.id == id }) {
                nav.focusID = id
                nav.scrollTarget = id
            }
        }
        .onChange(of: selection) { query = ""; selecting.end() }
        .onChange(of: playlistRef) { selecting.clear() }
        .onChange(of: viewMode) {
            let id = nav.focusID
            nav.scrollTarget = nil
            DispatchQueue.main.async { nav.scrollTarget = id }
        }
    }

    /// Movies / Series pages and the search results use the Quality + Language filter.
    private var isVODPage: Bool { isSearching || item == .movies || item == .series }
    private var filterActive: Bool { isVODPage ? (vodQuality != nil || !vodLanguage.isEmpty) : qualityFilter != nil }
    private var filterLabel: String {
        if isVODPage {
            return [vodQuality, vodLanguage.isEmpty ? nil : VODBrowser.languageName(vodLanguage)]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "Filter"
        }
        return qualityFilter?.rawValue ?? "Quality"
    }

    /// Home has no channel list, so the list tools are disabled there (not removed).
    private var showsChannelList: Bool { (item != .home || isSearching) && item != .movies && item != .series }

    private var isGroup: Bool {
        if case .group = item { return true }
        return false
    }

    private var emptyMessage: String {
        if let f = qualityFilter { return "No \(f.rawValue) channels here yet. Use Check Quality to measure them." }
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
                row("My Playlists", "music.note.list", .playlists, library.playlists.count + 1)
            }
            if library.active?.kind == .xtream {
                Section("On Demand") {
                    row("Movies", "film", .movies, nil)
                    row("Series", "tv", .series, nil)
                }
            }
            Section("Library") {
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

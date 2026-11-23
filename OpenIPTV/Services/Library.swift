import Foundation
import Observation

/// Sources, the cached channel catalog of the active source, favorites, recents and search.
@MainActor @Observable
final class Library {
    private(set) var sources: [Source] = []
    private(set) var activeID: UUID?

    private(set) var groups: [ChannelGroup] = []
    private(set) var sections: [GroupSection] = []
    private(set) var channels: [Channel] = []
    private(set) var byGroup: [String: [Channel]] = [:]
    private(set) var fetchedAt: Date?
    private var byID: [String: Channel] = [:]
    @ObservationIgnored private var keys: [String] = []
    @ObservationIgnored private var displayKeys: [String] = []

    private(set) var favorites: [String] = []
    private(set) var recents: [String] = []

    private(set) var isLoading = false
    private(set) var loadError: String?

    var active: Source? { sources.first { $0.id == activeID } }

    // MARK: Storage

    private static let dir: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = support.appendingPathComponent("Open IPTV", isDirectory: true)
        // The app was called Tuner before; carry its data over once.
        let old = support.appendingPathComponent("Tuner", isDirectory: true)
        if !fm.fileExists(atPath: d.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: d)
            if let oldDefaults = UserDefaults(suiteName: "app.tuner.mac") {
                for (k, v) in oldDefaults.dictionaryRepresentation()
                where k == "activeSource" || k == "volume" || k == "viewMode" || k == "pipCorner" || k.hasPrefix("fav-") || k.hasPrefix("recent-") {
                    UserDefaults.standard.set(v, forKey: k)
                }
            }
        }
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static var sourcesFile: URL { dir.appendingPathComponent("sources.json") }
    private static func cacheFile(_ id: UUID) -> URL { dir.appendingPathComponent("catalog-\(id.uuidString).json") }

    init() {
        if let data = try? Data(contentsOf: Self.sourcesFile), let s = try? JSONDecoder().decode([Source].self, from: data) {
            sources = s
        }
        let saved = UserDefaults.standard.string(forKey: "activeSource").flatMap(UUID.init)
        activeID = sources.first { $0.id == saved }?.id ?? sources.first?.id
    }

    private func saveSources() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        // Credentials live here, so keep the file private to this user.
        FileManager.default.createFile(atPath: Self.sourcesFile.path, contents: data, attributes: [.posixPermissions: 0o600])
        UserDefaults.standard.set(activeID?.uuidString, forKey: "activeSource")
    }

    // MARK: Sources

    func add(_ source: Source) async {
        sources.append(source)
        saveSources()
        await activate(source.id)
    }

    func remove(_ id: UUID) async {
        sources.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.cacheFile(id))
        saveSources()
        if activeID == id { await activate(sources.first?.id) } else { saveSources() }
    }

    func activate(_ id: UUID?) async {
        activeID = id
        saveSources()
        apply(Catalog(groups: [], channels: [], fetchedAt: .distantPast), fetched: nil)
        await load()
    }

    /// Cached catalog first (instant), then a network refresh when it's older than 12 hours.
    func load() async {
        guard let source = active else { return }
        favorites = UserDefaults.standard.stringArray(forKey: "fav-\(source.id)") ?? []
        recents = UserDefaults.standard.stringArray(forKey: "recent-\(source.id)") ?? []
        let file = Self.cacheFile(source.id)
        let cached = await Task.detached(priority: .userInitiated) { () -> Catalog? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(Catalog.self, from: data)
        }.value
        if let cached, activeID == source.id { apply(cached, fetched: cached.fetchedAt) }
        if cached == nil || Date().timeIntervalSince(cached!.fetchedAt) > 12 * 3600 {
            await refresh()
        }
    }

    func refresh() async {
        guard let source = active, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let catalog = try await Self.fetch(source)
            guard activeID == source.id else { return }
            apply(catalog, fetched: catalog.fetchedAt)
            let file = Self.cacheFile(source.id)
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(catalog) { try? data.write(to: file, options: .atomic) }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    nonisolated static func fetch(_ source: Source) async throws -> Catalog {
        switch source.kind {
        case .xtream:
            return try await XtreamClient(source: source).fetchCatalog()
        case .m3u:
            guard let url = URL(string: source.url.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SourceError.badURL }
            let data = url.isFileURL ? try Data(contentsOf: url) : try await fetchData(url)
            let text = String(decoding: data, as: UTF8.self)
            return try await Task.detached { try M3UParser.parse(text) }.value
        }
    }

    /// Checks a source before saving it.
    nonisolated static func validate(_ source: Source) async throws {
        switch source.kind {
        case .xtream: try await XtreamClient(source: source).authenticate()
        case .m3u: _ = try await fetch(source)
        }
    }

    private func apply(_ catalog: Catalog, fetched: Date?) {
        var grouped: [String: [Channel]] = [:]
        var ids: [String: Channel] = [:]
        ids.reserveCapacity(catalog.channels.count)
        for c in catalog.channels {
            grouped[c.groupID, default: []].append(c)
            ids[c.id] = c
        }
        keys = catalog.channels.map { Self.fold($0.name) }
        displayKeys = catalog.channels.map { Self.fold($0.displayName) }
        groups = catalog.groups.filter { grouped[$0.id] != nil }
        sections = Self.makeSections(groups)
        byGroup = grouped
        byID = ids
        channels = catalog.channels
        fetchedAt = fetched
    }

    // MARK: Lists

    func channels(for item: SidebarItem) -> [Channel] {
        switch item {
        case .home: []
        case .all: channels
        case .favorites: favorites.compactMap { byID[$0] }
        case .recents: recents.compactMap { byID[$0] }
        case .group(let id): byGroup[id] ?? []
        }
    }

    func title(for item: SidebarItem) -> String {
        switch item {
        case .home: "Home"
        case .all: "All Channels"
        case .favorites: "Favorites"
        case .recents: "Recently Watched"
        case .group(let id): groups.first { $0.id == id }?.name ?? ""
        }
    }

    func groupName(_ id: String) -> String { groups.first { $0.id == id }?.name ?? "" }

    func isFavorite(_ c: Channel) -> Bool { favorites.contains(c.id) }

    func toggleFavorite(_ c: Channel) {
        guard let s = active else { return }
        if let i = favorites.firstIndex(of: c.id) { favorites.remove(at: i) } else { favorites.append(c.id) }
        UserDefaults.standard.set(favorites, forKey: "fav-\(s.id)")
    }

    func isRecent(_ c: Channel) -> Bool { recents.contains(c.id) }

    func removeRecent(_ c: Channel) {
        guard let s = active else { return }
        recents.removeAll { $0 == c.id }
        UserDefaults.standard.set(recents, forKey: "recent-\(s.id)")
    }

    func markWatched(_ c: Channel) {
        guard let s = active else { return }
        recents.removeAll { $0 == c.id }
        recents.insert(c.id, at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
        UserDefaults.standard.set(recents, forKey: "recent-\(s.id)")
    }

    // MARK: Playback helpers

    func streamURL(_ c: Channel) -> URL? {
        if let id = c.streamID, let s = active { return XtreamClient(source: s).streamURL(id) }
        return c.url.flatMap(URL.init(string:))
    }

    func nowNext(_ c: Channel) async -> [Programme] {
        guard let id = c.streamID, let s = active, s.kind == .xtream else { return [] }
        return await XtreamClient(source: s).shortEPG(id)
    }

    // MARK: Search

    /// Every word must appear in the name (case, accent and punctuation insensitive).
    /// Names starting with the query rank first, then word-prefix matches, then the rest.
    func search(_ query: String) -> [Channel] {
        let tokens = Self.fold(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let first = tokens[0]
        var buckets: [[Channel]] = [[], [], []]
        for (i, key) in keys.enumerated() {
            var ok = true
            for t in tokens where !key.contains(t) { ok = false; break }
            guard ok else { continue }
            let rank = displayKeys[i].hasPrefix(first) || key.hasPrefix(first) ? 0
                : (" " + key).contains(" " + first) ? 1 : 2
            buckets[rank].append(channels[i])
        }
        return buckets.flatMap { $0 }
    }

    nonisolated static func fold(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        var lastSpace = true
        for ch in folded {
            if ch.isLetter || ch.isNumber || ch == "+" {
                out.append(ch)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    // MARK: Sidebar sections

    static func makeSections(_ groups: [ChannelGroup]) -> [GroupSection] {
        func split(_ name: String) -> (String, String) {
            let parts = name.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "|" || $0 == ":" })
            guard parts.count == 2 else { return (name, "") }
            let rest = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " |:-"))
            return (String(parts[0]).uppercased(), rest)
        }
        var counts: [String: Int] = [:]
        for g in groups { counts[split(g.name).0, default: 0] += 1 }

        var order: [String] = []
        var buckets: [String: [(ChannelGroup, String)]] = [:]
        var other: [(ChannelGroup, String)] = []
        for g in groups {
            let (prefix, rest) = split(g.name)
            if counts[prefix, default: 0] >= 2 {
                if buckets[prefix] == nil { order.append(prefix) }
                buckets[prefix, default: []].append((g, rest.isEmpty ? g.name : rest))
            } else {
                other.append((g, g.name))
            }
        }
        var result = order.map { GroupSection(id: $0, title: $0, groups: buckets[$0]!.map { (group: $0.0, label: $0.1) }) }
        if !other.isEmpty {
            result.append(GroupSection(id: "_other", title: result.isEmpty ? "Categories" : "More", groups: other.map { (group: $0.0, label: $0.1) }))
        }
        return result
    }
}

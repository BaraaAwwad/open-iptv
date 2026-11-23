import Foundation

/// A playlist the user added: an Xtream Codes account or a plain M3U URL.
struct Source: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case xtream, m3u
        var label: String { self == .xtream ? "Xtream Codes" : "M3U Playlist" }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var url: String
    var username: String = ""
    var password: String = ""

    /// Server base without a trailing slash, e.g. `http://host:8080`.
    var server: String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "http://" + s }
        return s
    }
}

struct ChannelGroup: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct Channel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let logo: String?
    let groupID: String
    /// Xtream stream id (the URL is built at play time so the password never lands in the cache).
    let streamID: Int?
    /// Direct URL for M3U channels.
    let url: String?
    let epgID: String?

    static func == (a: Channel, b: Channel) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Name without the provider's country tag (`|UK| `, `UK | `, `LATIN: `) for display.
    var displayName: String { Self.stripTag(name).titleCased }

    static func stripTag(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let r = trimmed.range(of: #"^(\|[A-Za-z0-9-]{1,8}\|\s*)+"#, options: .regularExpression) {
            let rest = trimmed[r.upperBound...]
            if !rest.isEmpty { return String(rest) }
        }
        if let r = trimmed.range(of: #"^[A-Za-z0-9-]{2,10}\s*[:|]\s+"#, options: .regularExpression) {
            let rest = trimmed[r.upperBound...]
            if !rest.isEmpty { return String(rest) }
        }
        return trimmed
    }

    /// Providers pad lists with fake "channels" like `=====  SPORTS =====`.
    static func isSeparator(_ name: String) -> Bool {
        let head = name.trimmingCharacters(in: .whitespaces).unicodeScalars.prefix(3)
        guard head.count == 3 else { return false }
        return head.allSatisfy { !CharacterSet.alphanumerics.contains($0) && $0 != " " }
    }
}

struct Catalog: Codable {
    var groups: [ChannelGroup]
    var channels: [Channel]
    var fetchedAt: Date
}

struct Programme: Hashable {
    let title: String
    let start: Date
    let end: Date

    var progress: Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(start) / total))
    }
}

enum SidebarItem: Hashable {
    case home, all, movies, series, playlists, favorites, recents
    case group(String)
}

/// Sidebar section: categories sharing a prefix ("ARABIC NEWS", "ARABIC MBC" → "ARABIC").
struct GroupSection: Identifiable {
    let id: String
    let title: String
    let groups: [(group: ChannelGroup, label: String)]
}

extension String {
    /// Providers send names in ALL CAPS. "BEIN SPORTS 1 HD" → "beIN Sports 1 HD", "BBC ONE" → "BBC One".
    /// Short words (MBC, CNN, HD) and quality tags keep their capitals; mixed-case names are left alone.
    var titleCased: String {
        let letters = unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty, uppercased() == self, lowercased() != self else { return self }
        return split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            let core = w.filter(\.isLetter)
            if let special = Self.specialWords[core] { return w.replacingOccurrences(of: core, with: special) }
            if (core.count <= 3 && !Self.commonWords.contains(core)) || Self.keepCaps.contains(core) || w.contains(where: \.isNumber) { return w }
            return w.prefix(1) + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    private static let keepCaps: Set<String> = [
        "HEVC", "UHD", "FHD", "HDR", "ESPN", "DAZN", "CNBC", "DSTV", "EXYU", "MSNBC", "OSN",
        "TVRI", "TRT", "BFM", "RMC", "SSC", "BEINSPORT",
    ]
    private static let commonWords: Set<String> = [
        "ONE", "TWO", "SIX", "TEN", "THE", "NEW", "ALL", "BOX", "MAX", "FUN", "PRO", "TOP", "AND", "FOX",
        "KIDS", "BIG", "OLD", "DAY", "WAR", "SEA", "SUN", "CAR", "LAW", "ZEE", "GEO", "BIO",
    ]
    private static let specialWords: [String: String] = ["BEIN": "beIN", "BEINSPORT": "beINSport", "PLUS": "Plus"]
}

/// A list the user made ("My Playlists"). Favorites is a built-in one that always comes first.
struct UserPlaylist: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var channelIDs: [String] = []
}

enum PlaylistRef: Hashable {
    case favorites
    case custom(UUID)
}

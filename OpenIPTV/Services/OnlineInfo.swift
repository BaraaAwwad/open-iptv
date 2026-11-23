import Foundation

/// Extra details for movies and series from Cinemeta (the public metadata service Stremio uses:
/// IMDb / TMDB data, no account or key). Optional: Settings → "Enhance with online info".
/// Only the title being opened is sent; nothing about the account or provider.
struct OnlineMeta: Codable {
    var imdbID: String
    var name: String?
    var logo: String?
    var background: String?
    var poster: String?
    var description: String?
    var cast: [String]?
    var director: [String]?
    var writer: [String]?
    var genres: [String]?
    var runtime: String?
    var imdbRating: String?
    var awards: String?
    var year: String?
    var trailer: String?
    var episodes: [OnlineEpisode]?

    func episode(_ season: Int, _ number: Int) -> OnlineEpisode? {
        episodes?.first { $0.season == season && $0.episode == number }
    }
}

struct OnlineEpisode: Codable {
    var season: Int
    var episode: Int
    var name: String?
    var thumbnail: String?
    var overview: String?
    var released: String?
}

actor OnlineInfo {
    static let shared = OnlineInfo()
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "onlineInfo") as? Bool ?? true }

    private let base = "https://v3-cinemeta.strem.io"
    private var memory: [String: OnlineMeta] = [:]
    private var inflight: [String: Task<OnlineMeta?, Never>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.httpAdditionalHeaders = ["User-Agent": "OpenIPTV/0.1"]
        return URLSession(configuration: c)
    }()

    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Open IPTV/online", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    // MARK: Public

    func movie(title: String, originalTitle: String?, year: String?, tmdbID: Int?) async -> OnlineMeta? {
        await lookup(key: tmdbID.map { "tmdb-\($0)" } ?? "m-\(Library.fold(title))-\(year ?? "")") {
            await self.match(type: "movie", titles: [originalTitle, title].compactMap { $0 }, year: year, tmdbID: tmdbID)
        }
    }

    func series(title: String, year: String?) async -> OnlineMeta? {
        await lookup(key: "s-\(Library.fold(title))-\(year ?? "")") {
            await self.match(type: "series", titles: [title], year: year, tmdbID: nil)
        }
    }

    // MARK: Cache

    private struct Stored: Codable { var meta: OnlineMeta?; var date: Date }

    /// Memory, then disk (found: 30 days; not found: 7 days), then the network, one request per key.
    private func lookup(key: String, fetch: @escaping () async -> OnlineMeta?) async -> OnlineMeta? {
        guard Self.isEnabled else { return nil }
        if let m = memory[key] { return m }
        let file = dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_").prefix(120) + ".json")
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            let age = Date().timeIntervalSince(s.date)
            if let meta = s.meta, age < 30 * 86400 { memory[key] = meta; return meta }
            if s.meta == nil, age < 7 * 86400 { return nil }
        }
        if let t = inflight[key] { return await t.value }
        let task = Task { await fetch() }
        inflight[key] = task
        let meta = await task.value
        inflight[key] = nil
        if let meta { memory[key] = meta }
        if let data = try? JSONEncoder().encode(Stored(meta: meta, date: Date())) { try? data.write(to: file, options: .atomic) }
        return meta
    }

    // MARK: Matching

    /// Search by title; prefer an exact TMDB id match, then the same title and year.
    private func match(type: String, titles: [String], year: String?, tmdbID: Int?) async -> OnlineMeta? {
        var seen = Set<String>()
        var candidates: [(id: String, name: String, year: String?)] = []
        for t in titles {
            let q = Self.cleanQuery(t)
            guard !q.isEmpty, !seen.contains(q) else { continue }
            seen.insert(q)
            candidates += await search(type: type, query: q)
            if candidates.count >= 6 { break }
        }
        guard !candidates.isEmpty else { return nil }

        let wanted = Set(titles.map { Library.fold(Self.cleanQuery($0)) })
        func score(_ c: (id: String, name: String, year: String?)) -> Int {
            var s = 0
            let n = Library.fold(c.name)
            if wanted.contains(n) { s += 4 } else if wanted.contains(where: { n.contains($0) || $0.contains(n) }) { s += 1 }
            if let y = year, let cy = c.year?.prefix(4), let a = Int(y), let b = Int(cy) {
                s += a == b ? 3 : abs(a - b) == 1 ? 1 : -2
            }
            return s
        }
        let ranked = candidates.sorted { score($0) > score($1) }

        if let tmdbID {
            // Exact: the provider's TMDB id must match the candidate's.
            for c in ranked.prefix(4) {
                if let meta = await meta(type: type, id: c.id), meta.tmdb == tmdbID { return meta.meta }
            }
        }
        guard let best = ranked.first, score(best) >= 4 else { return nil }
        return await meta(type: type, id: best.id)?.meta
    }

    private func search(type: String, query: String) async -> [(id: String, name: String, year: String?)] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: " -'")
        guard let q = query.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "%20"),
              let url = URL(string: "\(base)/catalog/\(type)/top/search=\(q).json"),
              let (data, _) = try? await session.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metas = obj["metas"] as? [[String: Any]] else { return [] }
        return metas.prefix(8).compactMap { m in
            guard let id = m["id"] as? String, id.hasPrefix("tt"), let name = m["name"] as? String else { return nil }
            return (id, name, (m["releaseInfo"] as? String) ?? (m["year"] as? String))
        }
    }

    private func meta(type: String, id: String) async -> (meta: OnlineMeta, tmdb: Int?)? {
        guard let url = URL(string: "\(base)/meta/\(type)/\(id).json"),
              let (data, _) = try? await session.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = obj["meta"] as? [String: Any] else { return nil }
        func strings(_ k: String) -> [String]? {
            let v = (m[k] as? [String])?.filter { !$0.isEmpty }
            return v?.isEmpty == false ? v : nil
        }
        func text(_ k: String) -> String? { (m[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let trailer = (m["trailerStreams"] as? [[String: Any]])?.first?["ytId"] as? String
            ?? (m["trailers"] as? [[String: Any]])?.first?["source"] as? String
        let episodes: [OnlineEpisode]? = (m["videos"] as? [[String: Any]])?.compactMap { v in
            guard let s = XtreamClient.int(v["season"]), let e = XtreamClient.int(v["episode"]), s > 0 else { return nil }
            return OnlineEpisode(season: s, episode: e, name: (v["name"] as? String) ?? (v["title"] as? String),
                                 thumbnail: v["thumbnail"] as? String,
                                 overview: (v["overview"] as? String) ?? (v["description"] as? String),
                                 released: (v["released"] as? String).map { String($0.prefix(10)) })
        }
        let meta = OnlineMeta(imdbID: id, name: text("name"), logo: text("logo"), background: text("background"),
                              poster: text("poster"), description: text("description"), cast: strings("cast"),
                              director: strings("director"), writer: strings("writer"),
                              genres: strings("genres") ?? strings("genre"), runtime: text("runtime"),
                              imdbRating: text("imdbRating"), awards: text("awards"),
                              year: text("releaseInfo") ?? text("year"), trailer: trailer, episodes: episodes)
        return (meta, XtreamClient.int(m["moviedb_id"]))
    }

    /// "Les Intrus (2026) [MULTI] 4K" → "Les Intrus"
    static func cleanQuery(_ s: String) -> String {
        var t = s
        for pattern in [#"\[[^\]]*\]"#, #"\((19|20)\d{2}\)"#, #"\b(4K|UHD|FHD|HD|SD|HEVC|x265|MULTI|VOSTFR|VF|VO)\b"#] {
            t = t.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -:|"))
    }
}

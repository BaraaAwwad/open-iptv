import Foundation
import Observation

// MARK: - Models

struct VODCategory: Identifiable, Hashable {
    let id: String
    let name: String
}

struct Movie: Identifiable, Hashable, Codable {
    let id: Int
    let title: String
    let year: String?
    let poster: String?
    let rating: Double?
    let ext: String
    let categoryID: String
}

struct MovieInfo {
    var originalTitle: String?
    var plot: String?
    var cast: String?
    var director: String?
    var genre: String?
    var released: String?
    var duration: String?
    var durationSecs: Double?
    var country: String?
    var backdrop: String?
    var trailer: String?
    var video: VideoDetails?
    var audio: String?
    var bitrate: String?
}

/// What the file really is, from the provider's own probe: "3840×2160 · HEVC · HDR".
struct VideoDetails: Hashable {
    var width: Int?
    var height: Int?
    var codec: String?
    var fps: Double?
    var hdr: Bool

    var tier: String? {
        guard let h = height, h > 0 else { return nil }
        return QualityTier.from(width: width ?? 0, height: h).rawValue
    }

    var summary: String {
        var parts: [String] = []
        if let w = width, let h = height { parts.append("\(w)×\(h)") }
        if let codec { parts.append(codec.uppercased()) }
        if let fps, fps > 0 { parts.append(String(format: fps.rounded() == fps ? "%.0f fps" : "%.2f fps", fps)) }
        if hdr { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }
}

struct Series: Identifiable, Hashable, Codable {
    let id: Int
    let title: String
    let year: String?
    let cover: String?
    let plot: String?
    let cast: String?
    let director: String?
    let genre: String?
    let rating: Double?
    let backdrop: String?
    let trailer: String?
    let categoryID: String
}

struct Episode: Identifiable, Hashable {
    let id: String
    let season: Int
    let number: Int
    let title: String
    let ext: String
    let plot: String?
    let duration: String?
    let image: String?
    let video: VideoDetails?
}

struct SeriesInfo {
    var seasons: [Int]
    var seasonNames: [Int: String]
    var episodes: [Int: [Episode]]
    var backdrop: String?
}

// MARK: - Provider calls

extension XtreamClient {
    func movieCategories() async throws -> [VODCategory] { try await categories("get_vod_categories") }
    func seriesCategories() async throws -> [VODCategory] { try await categories("get_series_categories") }

    private func categories(_ action: String) async throws -> [VODCategory] {
        let list = (try await json(action) as? [[String: Any]]) ?? []
        return list.compactMap { c in
            guard let id = Self.string(c["category_id"]), let name = c["category_name"] as? String else { return nil }
            return VODCategory(id: id, name: name.trimmingCharacters(in: .whitespaces))
        }
    }

    func movies(in category: String) async throws -> [Movie] {
        let list = (try await json("get_vod_streams", [.init(name: "category_id", value: category)]) as? [[String: Any]]) ?? []
        return list.compactMap { m in
            guard let id = Self.int(m["stream_id"]), let raw = m["name"] as? String, !Channel.isSeparator(raw) else { return nil }
            let (title, year) = VOD.split(raw)
            return Movie(id: id, title: title, year: year, poster: VOD.url(m["stream_icon"]),
                         rating: Self.double(m["rating"]).flatMap { $0 > 0 ? $0 : nil },
                         ext: (m["container_extension"] as? String) ?? "mp4", categoryID: category)
        }
    }

    func movieInfo(_ id: Int) async throws -> MovieInfo {
        let obj = try await json("get_vod_info", [.init(name: "vod_id", value: String(id))])
        let i = ((obj as? [String: Any])?["info"] as? [String: Any]) ?? [:]
        return MovieInfo(
            originalTitle: VOD.text(i["o_name"]),
            plot: VOD.text(i["plot"]) ?? VOD.text(i["description"]),
            cast: VOD.list(i["cast"]) ?? VOD.list(i["actors"]),
            director: VOD.list(i["director"]),
            genre: VOD.list(i["genre"]),
            released: VOD.text(i["releasedate"]),
            duration: VOD.text(i["duration"]),
            durationSecs: Self.double(i["duration_secs"]),
            country: VOD.text(i["country"]),
            backdrop: VOD.url(i["backdrop_path"]),
            trailer: VOD.text(i["youtube_trailer"]),
            video: VOD.video(i["video"]),
            audio: VOD.audio(i["audio"]),
            bitrate: Self.double(i["bitrate"]).map { $0 >= 1000 ? String(format: "%.1f Mbps", $0 / 1000) : String(format: "%.0f kbps", $0) }
        )
    }

    func series(in category: String) async throws -> [Series] {
        let list = (try await json("get_series", [.init(name: "category_id", value: category)]) as? [[String: Any]]) ?? []
        return list.compactMap { s in
            guard let id = Self.int(s["series_id"]), let raw = s["name"] as? String, !Channel.isSeparator(raw) else { return nil }
            let (title, year) = VOD.split(raw)
            return Series(id: id, title: title, year: year ?? VOD.text(s["releaseDate"]).map { String($0.prefix(4)) },
                          cover: VOD.url(s["cover"]), plot: VOD.text(s["plot"]), cast: VOD.list(s["cast"]),
                          director: VOD.list(s["director"]), genre: VOD.list(s["genre"]),
                          rating: Self.double(s["rating"]).flatMap { $0 > 0 ? $0 : nil },
                          backdrop: VOD.url(s["backdrop_path"]), trailer: VOD.text(s["youtube_trailer"]), categoryID: category)
        }
    }

    func seriesInfo(_ id: Int) async throws -> SeriesInfo {
        let obj = (try await json("get_series_info", [.init(name: "series_id", value: String(id))]) as? [String: Any]) ?? [:]
        var episodes: [Int: [Episode]] = [:]
        let raw: [(String, Any)] = (obj["episodes"] as? [String: Any]).map { Array($0) }
            ?? ((obj["episodes"] as? [Any]).map { $0.enumerated().map { ("\($0.offset + 1)", $0.element) } } ?? [])
        for (key, value) in raw {
            let season = Int(key) ?? 1
            for e in (value as? [[String: Any]]) ?? [] {
                guard let eid = Self.string(e["id"]) else { continue }
                let info = e["info"] as? [String: Any] ?? [:]
                episodes[season, default: []].append(Episode(
                    id: eid, season: season, number: Self.int(e["episode_num"]) ?? 0,
                    title: VOD.episodeTitle(e["title"] as? String ?? "", number: Self.int(e["episode_num"]) ?? 0),
                    ext: (e["container_extension"] as? String) ?? "mp4",
                    plot: VOD.text(info["plot"]), duration: VOD.text(info["duration"]),
                    image: VOD.url(info["movie_image"]), video: VOD.video(info["video"])))
            }
        }
        for k in episodes.keys { episodes[k]?.sort { $0.number < $1.number } }
        var names: [Int: String] = [:]
        for s in (obj["seasons"] as? [[String: Any]]) ?? [] {
            if let n = Self.int(s["season_number"]), let name = VOD.text(s["name"]) { names[n] = name }
        }
        let info = obj["info"] as? [String: Any] ?? [:]
        return SeriesInfo(seasons: episodes.keys.sorted(), seasonNames: names, episodes: episodes, backdrop: VOD.url(info["backdrop_path"]))
    }

    private func path(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }

    func movieURL(_ m: Movie) -> URL? {
        URL(string: "\(source.server)/movie/\(path(source.username))/\(path(source.password))/\(m.id).\(m.ext)")
    }

    func episodeURL(_ e: Episode) -> URL? {
        URL(string: "\(source.server)/series/\(path(source.username))/\(path(source.password))/\(e.id).\(e.ext)")
    }
}

/// Parsing helpers: providers are inconsistent (strings vs numbers, arrays vs "['…']" strings).
enum VOD {
    /// "|FR| Les Intrus : Chapitre 3 (2026)" → ("Les Intrus : Chapitre 3", "2026")
    static func split(_ raw: String) -> (String, String?) {
        var title = Channel.stripTag(raw)
        var year: String?
        if let r = title.range(of: #"\s*[\(\[](19|20)\d{2}[\)\]]\s*$"#, options: .regularExpression) {
            year = title[r].filter(\.isNumber)
            title.removeSubrange(r)
        } else if let r = title.range(of: #"\s+-\s+(19|20)\d{2}\s*$"#, options: .regularExpression) {
            year = title[r].filter(\.isNumber)
            title.removeSubrange(r)
        }
        return (title.trimmingCharacters(in: .whitespaces), year)
    }

    static func text(_ v: Any?) -> String? {
        let s = XtreamClient.string(v)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false && s != "0" && s != "null") ? s : nil
    }

    /// "Mindhunter S01 E02" → "Episode 2"; "Mindhunter S01E02 - The Interview" → "The Interview".
    static func episodeTitle(_ raw: String, number: Int) -> String {
        var t = split(raw).0
        if let r = t.range(of: #"^.*?\bS\d{1,2}\s*E\d{1,3}\b\s*[-:.–]?\s*"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Episode \(number)" : t
    }

    /// "Thriller,Action" → "Thriller, Action"
    static func list(_ v: Any?) -> String? {
        text(v).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ") }
    }

    static func url(_ v: Any?) -> String? {
        if let list = v as? [Any] { return list.lazy.compactMap { url($0) }.first }
        guard let s = text(v) else { return nil }
        if s.hasPrefix("http") { return s }
        if let r = s.range(of: #"https?://[^'"\],\s]+"#, options: .regularExpression) { return String(s[r]) }
        return nil
    }

    private static func dict(_ v: Any?) -> [String: Any]? {
        if let d = v as? [String: Any] { return d }
        guard let s = v as? String, s.hasPrefix("{") else { return nil }
        // Python-style repr: {'width': 1920, ...}
        let jsonish = s.replacingOccurrences(of: "'", with: "\"").replacingOccurrences(of: "True", with: "true")
            .replacingOccurrences(of: "False", with: "false").replacingOccurrences(of: "None", with: "null")
        return (try? JSONSerialization.jsonObject(with: Data(jsonish.utf8))) as? [String: Any]
    }

    static func video(_ v: Any?) -> VideoDetails? {
        guard let d = dict(v) else { return nil }
        let rate: Double? = (d["avg_frame_rate"] as? String).flatMap { s in
            let p = s.split(separator: "/").compactMap { Double($0) }
            return p.count == 2 && p[1] > 0 ? (p[0] / p[1] * 100).rounded() / 100 : nil
        }
        let transfer = (d["color_transfer"] as? String) ?? ""
        return VideoDetails(width: XtreamClient.int(d["width"]), height: XtreamClient.int(d["height"]),
                            codec: d["codec_name"] as? String, fps: rate.flatMap { $0 > 0 && $0 < 300 ? $0 : nil },
                            hdr: transfer.contains("2084") || transfer.contains("hlg"))
    }

    static func audio(_ v: Any?) -> String? {
        guard let d = dict(v) else { return nil }
        let codec = (d["codec_name"] as? String)?.uppercased()
        let layout = d["channel_layout"] as? String ?? XtreamClient.int(d["channels"]).map { "\($0) ch" }
        let parts = [codec, layout].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Store

/// Movies and series for the active Xtream source. Everything loads one category at a time
/// (this account has ~150k movies; the full list would be tens of megabytes).
@MainActor @Observable
final class VODStore {
    private(set) var movieCategories: [VODCategory] = []
    private(set) var seriesCategories: [VODCategory] = []
    private(set) var movies: [String: [Movie]] = [:]
    private(set) var series: [String: [Series]] = [:]
    private(set) var loading: Set<String> = []
    private(set) var error: String?

    @ObservationIgnored private var movieInfo: [Int: MovieInfo] = [:]
    @ObservationIgnored private var seriesInfo: [Int: SeriesInfo] = [:]
    @ObservationIgnored private let library: Library
    @ObservationIgnored private var sourceID: UUID?
    /// Seconds watched, by "m<id>" / "e<id>".
    private(set) var progress: [String: Double] = [:]
    /// Last episode watched per series.
    private(set) var lastEpisode: [Int: String] = [:]

    init(library: Library) { self.library = library }

    private var client: XtreamClient? {
        guard let s = library.active, s.kind == .xtream else { return nil }
        return XtreamClient(source: s)
    }

    var isAvailable: Bool { library.active?.kind == .xtream }

    /// Drops everything when the provider changes.
    func syncSource() {
        guard library.activeID != sourceID else { return }
        sourceID = library.activeID
        movieCategories = []; seriesCategories = []; movies = [:]; series = [:]
        movieInfo = [:]; seriesInfo = [:]; error = nil
        let key = sourceID?.uuidString ?? "-"
        progress = UserDefaults.standard.dictionary(forKey: "vod-progress-\(key)") as? [String: Double] ?? [:]
        lastEpisode = (UserDefaults.standard.dictionary(forKey: "vod-last-episode-\(key)") as? [String: String] ?? [:])
            .reduce(into: [:]) { r, kv in if let k = Int(kv.key) { r[k] = kv.value } }
    }

    func loadCategories() async {
        syncSource()
        guard let client, movieCategories.isEmpty || seriesCategories.isEmpty, !loading.contains("cats") else { return }
        loading.insert("cats")
        defer { loading.remove("cats") }
        do {
            async let m = client.movieCategories()
            async let s = client.seriesCategories()
            movieCategories = try await m
            seriesCategories = try await s
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    // Category lists are saved on disk: the provider can take 10+ seconds the first time it builds one,
    // so a revisit (even after a restart) shows the saved list instantly and refreshes it after 12 hours.
    private func cacheURL(_ name: String) -> URL? {
        guard let id = sourceID else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Open IPTV/vod-\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name + ".json")
    }

    private func cached<T: Decodable>(_ name: String, as: T.Type) -> (T, fresh: Bool)? {
        guard let url = cacheURL(name), let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        let age = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
        return (value, age < 12 * 3600)
    }

    private func store<T: Encodable>(_ value: T, _ name: String) {
        guard let url = cacheURL(name) else { return }
        Task.detached { if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) } }
    }

    func loadMovies(_ category: String) async {
        guard let client, movies[category] == nil, !loading.contains("m" + category) else { return }
        if let (saved, fresh) = cached("m-\(category)", as: [Movie].self) {
            movies[category] = saved
            if fresh { return }
        }
        loading.insert("m" + category)
        defer { loading.remove("m" + category) }
        do {
            let list = try await client.movies(in: category)
            movies[category] = list
            store(list, "m-\(category)")
        } catch { if movies[category] == nil { self.error = error.localizedDescription } }
    }

    func loadSeries(_ category: String) async {
        guard let client, series[category] == nil, !loading.contains("s" + category) else { return }
        if let (saved, fresh) = cached("s-\(category)", as: [Series].self) {
            series[category] = saved
            if fresh { return }
        }
        loading.insert("s" + category)
        defer { loading.remove("s" + category) }
        do {
            let list = try await client.series(in: category)
            series[category] = list
            store(list, "s-\(category)")
        } catch { if series[category] == nil { self.error = error.localizedDescription } }
    }

    func info(_ m: Movie) async -> MovieInfo? {
        if let i = movieInfo[m.id] { return i }
        guard let client, let i = try? await client.movieInfo(m.id) else { return nil }
        movieInfo[m.id] = i
        return i
    }

    func info(_ s: Series) async -> SeriesInfo? {
        if let i = seriesInfo[s.id] { return i }
        guard let client, let i = try? await client.seriesInfo(s.id) else { return nil }
        seriesInfo[s.id] = i
        return i
    }

    func url(_ m: Movie) -> URL? { client?.movieURL(m) }
    func url(_ e: Episode) -> URL? { client?.episodeURL(e) }

    // MARK: Resume

    func position(_ key: String) -> Double? { progress[key] }

    func save(_ key: String, position: Double, duration: Double, series: Int? = nil) {
        // Within the last 5% (or 3 minutes) counts as finished.
        if duration > 0, position > duration * 0.95 || duration - position < 180 { progress[key] = nil }
        else if position > 30 { progress[key] = position }
        if let series {
            lastEpisode[series] = key
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: lastEpisode.map { ("\($0.key)", $0.value) }),
                                      forKey: "vod-last-episode-\(sourceID?.uuidString ?? "-")")
        }
        UserDefaults.standard.set(progress, forKey: "vod-progress-\(sourceID?.uuidString ?? "-")")
    }
}

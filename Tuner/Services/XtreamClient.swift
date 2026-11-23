import Foundation

enum SourceError: LocalizedError {
    case badURL, auth(String), http(Int), empty, format

    var errorDescription: String? {
        switch self {
        case .badURL: "That server address doesn't look right."
        case .auth(let m): m.isEmpty ? "Wrong username or password, or the account is inactive." : m
        case .http(let c): "The server answered with HTTP \(c)."
        case .empty: "The playlist has no channels."
        case .format: "The server sent something that isn't a playlist."
        }
    }
}

let sharedSession: URLSession = {
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = 30
    c.timeoutIntervalForResource = 180
    c.httpAdditionalHeaders = ["User-Agent": "Tuner/0.1"]
    return URLSession(configuration: c)
}()

func fetchData(_ url: URL) async throws -> Data {
    let (data, resp) = try await sharedSession.data(from: url)
    if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw SourceError.http(h.statusCode) }
    return data
}

/// Xtream Codes `player_api.php` client.
struct XtreamClient {
    let source: Source

    private func apiURL(_ action: String? = nil, _ extra: [URLQueryItem] = []) throws -> URL {
        guard var c = URLComponents(string: source.server + "/player_api.php") else { throw SourceError.badURL }
        c.queryItems = [.init(name: "username", value: source.username), .init(name: "password", value: source.password)]
            + (action.map { [.init(name: "action", value: $0)] } ?? []) + extra
        guard let url = c.url else { throw SourceError.badURL }
        return url
    }

    private func json(_ action: String? = nil, _ extra: [URLQueryItem] = []) async throws -> Any {
        let data = try await fetchData(try apiURL(action, extra))
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw SourceError.format }
        return obj
    }

    func authenticate() async throws {
        let obj = try await json()
        guard let info = (obj as? [String: Any])?["user_info"] as? [String: Any] else { throw SourceError.auth("") }
        let ok = "\(info["auth"] ?? 0)" == "1"
        let status = info["status"] as? String ?? ""
        if !ok { throw SourceError.auth("") }
        if !status.isEmpty && status != "Active" { throw SourceError.auth("This account is \(status.lowercased()).") }
    }

    func fetchCatalog() async throws -> Catalog {
        async let catsObj = json("get_live_categories")
        async let streamsObj = json("get_live_streams")
        let cats = (try await catsObj as? [[String: Any]]) ?? []
        let streams = (try await streamsObj as? [[String: Any]]) ?? []

        var channels: [Channel] = []
        channels.reserveCapacity(streams.count)
        var used = Set<String>()
        for s in streams {
            guard let name = s["name"] as? String, !Channel.isSeparator(name),
                  let id = Self.int(s["stream_id"]) else { continue }
            let group = Self.string(s["category_id"]) ?? "0"
            used.insert(group)
            let icon = (s["stream_icon"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let epg = (s["epg_channel_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            channels.append(Channel(id: "x\(id)", name: name, logo: icon, groupID: group, streamID: id, url: nil, epgID: epg))
        }
        var groups: [ChannelGroup] = cats.compactMap { c in
            guard let id = Self.string(c["category_id"]), let name = c["category_name"] as? String, used.contains(id) else { return nil }
            return ChannelGroup(id: id, name: name.trimmingCharacters(in: .whitespaces))
        }
        let known = Set(groups.map(\.id))
        if used.contains(where: { !known.contains($0) }) { groups.append(ChannelGroup(id: "0", name: "Uncategorized")) }
        if channels.isEmpty { throw SourceError.empty }
        return Catalog(groups: groups, channels: channels, fetchedAt: Date())
    }

    func streamURL(_ streamID: Int) -> URL? {
        let u = source.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.username
        let p = source.password.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.password
        return URL(string: "\(source.server)/live/\(u)/\(p)/\(streamID).ts")
    }

    /// Now / next for one channel.
    func shortEPG(_ streamID: Int) async -> [Programme] {
        guard let obj = try? await json("get_short_epg", [.init(name: "stream_id", value: String(streamID)), .init(name: "limit", value: "3")]),
              let list = (obj as? [String: Any])?["epg_listings"] as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            guard let t = e["title"] as? String,
                  let start = Self.double(e["start_timestamp"]), let end = Self.double(e["stop_timestamp"]) else { return nil }
            let title = Data(base64Encoded: t).flatMap { String(data: $0, encoding: .utf8) } ?? t
            return Programme(title: title, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
        }
        .filter { $0.end > Date() }
    }

    // Panels mix numbers and strings freely.
    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }
    static func int(_ v: Any?) -> Int? { string(v).flatMap { Int($0) } }
    static func double(_ v: Any?) -> Double? { string(v).flatMap { Double($0) } }
}

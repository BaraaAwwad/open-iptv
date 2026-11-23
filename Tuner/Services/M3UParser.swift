import Foundation

/// Parses `#EXTM3U` playlists (`#EXTINF` with `tvg-*` / `group-title` attributes).
enum M3UParser {
    static func parse(_ text: String) throws -> Catalog {
        var groups: [ChannelGroup] = []
        var groupIndex: [String: Int] = [:]
        var channels: [Channel] = []
        var seen = Set<String>()

        var pendingName: String?
        var pendingAttrs: [String: String] = [:]
        var pendingGroup: String?

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF") {
                let (attrs, name) = parseExtinf(line)
                pendingAttrs = attrs
                pendingName = name
            } else if line.hasPrefix("#EXTGRP:") {
                pendingGroup = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                continue
            } else if let name = pendingName {
                defer { pendingName = nil; pendingAttrs = [:]; pendingGroup = nil }
                guard !Channel.isSeparator(name) else { continue }
                let groupName = pendingAttrs["group-title"].flatMap { $0.isEmpty ? nil : $0 } ?? pendingGroup ?? "Uncategorized"
                if groupIndex[groupName] == nil {
                    groupIndex[groupName] = groups.count
                    groups.append(ChannelGroup(id: groupName, name: groupName))
                }
                var id = "m" + line
                var n = 1
                while seen.contains(id) { n += 1; id = "m\(n)" + line }
                seen.insert(id)
                let logo = pendingAttrs["tvg-logo"].flatMap { $0.isEmpty ? nil : $0 }
                let epg = pendingAttrs["tvg-id"].flatMap { $0.isEmpty ? nil : $0 }
                channels.append(Channel(id: id, name: name, logo: logo, groupID: groupName, streamID: nil, url: line, epgID: epg))
            }
        }
        if channels.isEmpty { throw text.contains("#EXTM3U") || text.contains("#EXTINF") ? SourceError.empty : SourceError.format }
        return Catalog(groups: groups, channels: channels, fetchedAt: Date())
    }

    /// `#EXTINF:-1 tvg-id="a" tvg-logo="b" group-title="c",Channel Name`
    static func parseExtinf(_ line: String) -> ([String: String], String) {
        var attrs: [String: String] = [:]
        var inQuotes = false
        var commaIndex: String.Index?
        for i in line.indices {
            let ch = line[i]
            if ch == "\"" { inQuotes.toggle() } else if ch == "," && !inQuotes { commaIndex = i; break }
        }
        let head = commaIndex.map { line[..<$0] } ?? Substring(line)
        let name = commaIndex.map { String(line[line.index(after: $0)...]) } ?? ""

        // key="value" pairs
        var rest = head[...]
        while let eq = rest.range(of: "=\"") {
            let keyStart = rest[..<eq.lowerBound].lastIndex(where: { $0 == " " }).map { rest.index(after: $0) } ?? rest.startIndex
            let key = rest[keyStart..<eq.lowerBound].lowercased()
            let valueStart = eq.upperBound
            guard let close = rest[valueStart...].firstIndex(of: "\"") else { break }
            attrs[key] = String(rest[valueStart..<close])
            rest = rest[rest.index(after: close)...]
        }
        let title = name.trimmingCharacters(in: .whitespaces)
        return (attrs, title.isEmpty ? (attrs["tvg-name"] ?? "Unnamed") : title)
    }
}

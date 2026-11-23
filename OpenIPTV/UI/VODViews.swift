import AppKit
import SwiftUI

// MARK: - Browse (categories left, posters right, details pushed on the right)

struct VODBrowser: View {
    enum Kind { case movies, series }
    @Environment(VODStore.self) private var vod
    let kind: Kind
    let query: String
    @State private var category: String?
    @State private var path = NavigationPath()
    /// Language filter: narrows the category list to one language's collections. Remembered.
    @AppStorage("vodLanguage") private var language = ""
    /// Quality filter: only titles measured at this quality.
    @State private var quality: String?

    private var allCategories: [VODCategory] { kind == .movies ? vod.movieCategories : vod.seriesCategories }
    private var categories: [VODCategory] {
        language.isEmpty ? allCategories : allCategories.filter { VODBrowser.languageTag($0.name) == language }
    }

    /// Languages present in the category names, most common first.
    private var languages: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for c in allCategories { if let t = VODBrowser.languageTag(c.name) { counts[t, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
            Picker("Language", selection: $language) {
                Text("All Languages").tag("")
                Divider()
                ForEach(languages, id: \.tag) { l in Text("\(l.tag)  (\(l.count))").tag(l.tag) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .help("Show only collections in one language")
            List(selection: $category) {
                ForEach(categories) { c in
                    Text(VODBrowser.label(c.name)).lineLimit(1).tag(c.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            }
            .frame(width: 230)
            .background(Color.primary.opacity(0.03))
            .overlay {
                if allCategories.isEmpty {
                    if let e = vod.error { Text(e).font(.callout).foregroundStyle(.secondary).padding() } else { ProgressView() }
                }
            }
            Divider()
            NavigationStack(path: $path) {
                grid
                    .navigationDestination(for: Movie.self) { MovieDetailView(movie: $0) }
                    .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
            }
        }
        .task {
            await vod.loadCategories()
            if category == nil { category = categories.first?.id }
        }
        .onChange(of: language) {
            if !categories.contains(where: { $0.id == category }) { category = categories.first?.id }
        }
        .onChange(of: category) { _, c in
            path = NavigationPath()
            quality = nil
            vod.stopCheck()
            guard let c else { return }
            Task { kind == .movies ? await vod.loadMovies(c) : await vod.loadSeries(c) }
        }
    }

    @ViewBuilder private var grid: some View {
        let name = categories.first { $0.id == category }.map { VODBrowser.label($0.name) } ?? (kind == .movies ? "Movies" : "Series")
        if let category {
            switch kind {
            case .movies:
                if let items = vod.movies[category] {
                    PosterGrid(title: name, items: byQuality(filter(items, \.title)) { vod.quick($0)?.tier }, key: category,
                               accessory: AnyView(qualityControl(count: items.count) { vod.checkAll(items, title: name) })) { m in
                        NavigationLink(value: m) {
                            PosterCard(title: m.title, poster: m.poster, caption: caption(m.year, m.rating),
                                       badges: vod.quick(m)?.badges ?? [])
                        }
                        .task { vod.enrich(m) }
                    }
                } else { loadingView }
            case .series:
                if let items = vod.series[category] {
                    PosterGrid(title: name, items: byQuality(filter(items, \.title)) { vod.quick($0)?.tier }, key: category,
                               accessory: AnyView(qualityControl(count: items.count) { vod.checkAll(items, title: name) })) { s in
                        NavigationLink(value: s) {
                            PosterCard(title: s.title, poster: s.cover, caption: caption(s.year, s.rating),
                                       badges: vod.quick(s)?.badges ?? [], detail: vod.quick(s)?.counts)
                        }
                        .task { vod.enrich(s) }
                    }
                } else { loadingView }
            }
        } else {
            loadingView
        }
    }

    private func byQuality<T>(_ items: [T], _ tier: (T) -> String?) -> [T] {
        guard let quality else { return items }
        return items.filter { tier($0) == quality }
    }

    /// Quality filter + the background check that measures the category.
    private func qualityControl(count: Int, check: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            if vod.isChecking {
                ProgressView(value: Double(vod.checkDone), total: Double(max(vod.checkTotal, 1)))
                    .frame(width: 80).controlSize(.small)
                Text("Checking \(vod.checkDone) of \(vod.checkTotal)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button("Stop") { vod.stopCheck() }
            }
            Picker("Quality", selection: Binding(get: { quality ?? "" }, set: { value in
                quality = value.isEmpty ? nil : value
                if quality != nil, !vod.isChecking { check() }
            })) {
                Text("All Qualities").tag("")
                Divider()
                ForEach(["4K", "1080p", "720p", "SD"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Show only titles measured at this quality. Choosing one checks the whole category in the background (\(count) titles).")
        }
    }

    private var loadingView: some View {
        let name = categories.first { $0.id == category }.map { VODBrowser.label($0.name) }
        return VStack(spacing: 10) {
            ProgressView()
            Text(name.map { "Loading \($0)…" } ?? "Loading…").foregroundStyle(.secondary)
            Text("The provider can take a few seconds the first time.").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filter<T>(_ items: [T], _ title: KeyPath<T, String>) -> [T] {
        let q = Library.fold(query)
        guard !q.isEmpty else { return items }
        let words = q.split(separator: " ")
        return items.filter { item in
            let t = Library.fold(item[keyPath: title])
            return words.allSatisfy { t.contains($0) }
        }
    }

    private func caption(_ year: String?, _ rating: Double?) -> String {
        [year, rating.map { String(format: "★ %.1f", $0) }].compactMap { $0 }.joined(separator: "  ·  ")
    }

    /// The language tag of a category name: "|VOD-FR| COMEDIE" → "FR", "MULTI · Netflix" → "MULTI".
    static func languageTag(_ raw: String) -> String? {
        let label = VODBrowser.label(raw)
        guard let dot = label.range(of: " · ") else { return nil }
        let tag = String(label[..<dot.lowerBound]).uppercased()
        return tag.count <= 6 && tag.allSatisfy({ $0.isLetter || $0 == "-" }) ? tag : nil
    }

    /// "|VOD-FR| COMEDIE DRAMATIQUE" → "FR · Comedie Dramatique"
    static func label(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let r = trimmed.range(of: #"^\|([^|]+)\|\s*"#, options: .regularExpression) {
            let tag = trimmed[r].trimmingCharacters(in: CharacterSet(charactersIn: "| "))
                .replacingOccurrences(of: "VOD-", with: "").replacingOccurrences(of: "SERIES", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
            let rest = String(trimmed[r.upperBound...]).titleCased
            return tag.isEmpty ? rest : "\(tag) · \(rest)"
        }
        return trimmed.titleCased
    }
}

struct PosterGrid<Item: Identifiable, Cell: View>: View {
    let title: String
    let items: [Item]
    let key: String
    var accessory: AnyView = AnyView(EmptyView())
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(.system(size: 34, weight: .bold)).lineLimit(1)
                    Text("\(items.count)").font(.title3).foregroundStyle(.tertiary)
                    Spacer(minLength: 12)
                    accessory
                }
                if items.isEmpty {
                    Text("Nothing here yet. If a quality filter is on, titles appear as they're checked.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24, alignment: .top)], spacing: 30) {
                    ForEach(items) { cell($0).buttonStyle(.plain) }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
        }
        .id(key)
    }
}

struct PosterCard: View {
    let title: String
    let poster: String?
    let caption: String
    /// Quality / language chips over the poster ("1080p", "HDR", "EN").
    var badges: [String] = []
    /// Second caption line, e.g. the collection: "FR · HBO".
    var detail: String? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: poster, maxPixels: 500, placeholder: title)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(hovering ? 0.5 : 0.08), lineWidth: hovering ? 1.5 : 1)
                }
                .overlay(alignment: .topLeading) {
                    if !badges.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(badges, id: \.self) { b in
                                Text(b)
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }
                        .padding(7)
                        .transition(.opacity)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.45 : 0.15), radius: hovering ? 20 : 5, y: hovering ? 12 : 3)
                .scaleEffect(hovering ? 1.05 : 1)
            Text(title)
                .font(.system(size: 13, weight: hovering ? .semibold : .medium))
                .lineLimit(2)
                .foregroundStyle(hovering ? .primary : .secondary)
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hovering)
        .help(title)
    }
}

/// Poster / backdrop / still from a URL, with a tasteful placeholder.
struct ArtworkView: View {
    let url: String?
    var maxPixels: Int = 500
    var placeholder: String = ""
    var fill = true
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        // The frame comes from the caller (Color.clear takes exactly the space offered); the image fills
        // it and is clipped to it, so a wide picture can never spill over its neighbours.
        Color.clear
            .overlay {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: fill ? .fill : .fit)
                            .transition(.opacity)
                    } else if failed || url == nil {
                        Text(placeholder)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(12)
                    }
                }
            }
            .clipped()
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { return }
            let img = await ImageLoader.shared.image(url, maxPixels: maxPixels)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = img }
            failed = img == nil
        }
    }
}

// MARK: - Detail pages

/// Backdrop hero shared by movie and series pages.
private struct Hero<Content: View>: View {
    let backdrop: String?
    let poster: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkView(url: backdrop ?? poster, maxPixels: 1600)
                .frame(height: 440)
                .frame(maxWidth: .infinity)
                .overlay {
                    LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.7), Color(nsColor: .windowBackgroundColor)],
                                   startPoint: .center, endPoint: .bottom)
                }
                .overlay {
                    LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0.85), .clear],
                                   startPoint: .leading, endPoint: .center)
                }
                .clipped()
            HStack(alignment: .bottom, spacing: 24) {
                ArtworkView(url: poster, maxPixels: 500)
                    .frame(width: 170, height: 255)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                VStack(alignment: .leading, spacing: 10) { content() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 8)
        }
    }
}

private struct Facts: View {
    let items: [(String, String?)]
    var body: some View {
        let shown = items.compactMap { k, v in v.map { (k, $0) } }
        if !shown.isEmpty {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(shown, id: \.0) { k, v in
                    GridRow {
                        Text(k).foregroundStyle(.secondary)
                        Text(v).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        }
    }
}

private func metaLine(_ parts: [String?]) -> String {
    parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
}

private func time(_ s: Double) -> String {
    let t = Int(s)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

struct MovieDetailView: View {
    @Environment(VODStore.self) private var vod
    @Environment(PlayerModel.self) private var player
    let movie: Movie
    @State private var info: MovieInfo?
    @State private var online: OnlineMeta?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Hero(backdrop: online?.background ?? info?.backdrop, poster: movie.poster) {
                    TitleLogo(logo: online?.logo, title: movie.title)
                    if let o = info?.originalTitle, o != movie.title {
                        Text(o).font(.title3).foregroundStyle(.secondary)
                    }
                    Text(metaLine([info?.released.map { String($0.prefix(4)) } ?? movie.year ?? online?.year,
                                   info?.genre ?? online?.genres?.joined(separator: ", "), info?.duration ?? online?.runtime,
                                   online?.imdbRating.map { "IMDb \($0)" } ?? movie.rating.map { String(format: "★ %.1f", $0) }]))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let v = info?.video {
                        HStack(spacing: 6) {
                            if let tier = v.tier { Badge(tier) }
                            if v.hdr { Badge("HDR") }
                            if let codec = v.codec { Badge(codec.uppercased()) }
                        }
                    }
                    actions.padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 22) {
                    if let plot = info?.plot ?? online?.description {
                        Text(plot).font(.body).lineSpacing(3).frame(maxWidth: 760, alignment: .leading).textSelection(.enabled)
                    } else if info == nil {
                        ProgressView().controlSize(.small)
                    }
                    Facts(items: [
                        ("Director", info?.director ?? online?.director?.joined(separator: ", ")),
                        ("Writer", online?.writer?.joined(separator: ", ")),
                        ("Cast", info?.cast ?? online?.cast?.joined(separator: ", ")),
                        ("Genre", info?.genre ?? online?.genres?.joined(separator: ", ")),
                        ("Released", info?.released), ("Country", info?.country), ("Runtime", info?.duration ?? online?.runtime),
                        ("Awards", online?.awards),
                        ("Video", info?.video?.summary.isEmpty == false ? info?.video?.summary : nil),
                        ("Audio", info?.audio), ("Bitrate", info?.bitrate), ("Format", movie.ext.uppercased()),
                    ])
                    .frame(maxWidth: 760, alignment: .leading)
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(movie.title)
        .task(id: movie.id) {
            info = await vod.info(movie)
            online = await OnlineInfo.shared.movie(title: movie.title, originalTitle: info?.originalTitle,
                                                  year: info?.released.map { String($0.prefix(4)) } ?? movie.year,
                                                  tmdbID: info?.tmdbID)
        }
    }

    @ViewBuilder private var actions: some View {
        let resume = vod.position("m\(movie.id)")
        HStack(spacing: 12) {
            if let resume {
                PlayPill(title: "Resume from \(time(resume))", icon: "play.fill", primary: true) { play(from: resume) }
                PlayPill(title: "From Start", icon: "arrow.counterclockwise", primary: false) { play(from: nil) }
            } else {
                PlayPill(title: "Play", icon: "play.fill", primary: true) { play(from: nil) }
            }
            if let t = info?.trailer ?? online?.trailer, let url = URL(string: t.hasPrefix("http") ? t : "https://www.youtube.com/watch?v=\(t)") {
                PlayPill(title: "Trailer", icon: "film", primary: false) { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func play(from start: Double?) {
        guard let url = vod.url(movie) else { return }
        player.playVOD(.init(key: "m\(movie.id)", title: movie.title, subtitle: metaLine([movie.year, info?.genre]),
                             artwork: movie.poster, url: url, start: start, movie: movie))
    }
}

struct SeriesDetailView: View {
    @Environment(VODStore.self) private var vod
    @Environment(PlayerModel.self) private var player
    let series: Series
    @State private var info: SeriesInfo?
    @State private var online: OnlineMeta?
    @State private var season: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Hero(backdrop: online?.background ?? series.backdrop ?? info?.backdrop, poster: series.cover) {
                    TitleLogo(logo: online?.logo, title: series.title)
                    Text(metaLine([series.year ?? online?.year, series.genre ?? online?.genres?.joined(separator: ", "),
                                   info.map { "\($0.seasons.count) season\($0.seasons.count == 1 ? "" : "s")" },
                                   online?.imdbRating.map { "IMDb \($0)" } ?? series.rating.map { String(format: "★ %.1f", $0) }]))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let next = nextUp {
                        PlayPill(title: next.label, icon: "play.fill", primary: true) { play(next.episode, from: next.start) }
                            .padding(.top, 6)
                    }
                }

                VStack(alignment: .leading, spacing: 22) {
                    if let plot = series.plot ?? online?.description {
                        Text(plot).lineSpacing(3).frame(maxWidth: 760, alignment: .leading).textSelection(.enabled)
                    }
                    Facts(items: [("Director", series.director ?? online?.director?.joined(separator: ", ")),
                                  ("Writer", online?.writer?.joined(separator: ", ")),
                                  ("Cast", series.cast ?? online?.cast?.joined(separator: ", ")),
                                  ("Genre", series.genre ?? online?.genres?.joined(separator: ", ")),
                                  ("Awards", online?.awards)])
                        .frame(maxWidth: 760, alignment: .leading)

                    if let info {
                        if info.seasons.count > 1 {
                            Picker("Season", selection: Binding(get: { season ?? info.seasons.first ?? 1 }, set: { season = $0 })) {
                                ForEach(info.seasons, id: \.self) { s in
                                    Text(info.seasonNames[s] ?? "Season \(s)").tag(s)
                                }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        let current = season ?? info.seasons.first ?? 1
                        VStack(spacing: 4) {
                            ForEach(info.episodes[current] ?? []) { e in
                                EpisodeRow(episode: e, online: online?.episode(e.season, e.number), fallback: series.cover,
                                           progress: vod.position("e\(e.id)")) { play(e, from: vod.position("e\(e.id)")) }
                            }
                        }
                        .padding(.horizontal, -12)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(series.title)
        .task(id: series.id) {
            async let o = OnlineInfo.shared.series(title: series.title, year: series.year)
            info = await vod.info(series)
            online = await o
            if season == nil, let last = vod.lastEpisode[series.id], let info,
               let s = info.episodes.first(where: { $0.value.contains { "e\($0.id)" == last } })?.key {
                season = s
            }
        }
    }

    /// Resume the last episode you watched, or start S1 E1.
    private var nextUp: (episode: Episode, label: String, start: Double?)? {
        guard let info else { return nil }
        let all = info.seasons.flatMap { info.episodes[$0] ?? [] }
        if let last = vod.lastEpisode[series.id], let i = all.firstIndex(where: { "e\($0.id)" == last }) {
            if let pos = vod.position(last) {
                return (all[i], "Resume S\(all[i].season) E\(all[i].number)", pos)
            }
            if i + 1 < all.count { return (all[i + 1], "Play S\(all[i + 1].season) E\(all[i + 1].number)", nil) }
        }
        guard let first = all.first else { return nil }
        return (first, "Play S\(first.season) E\(first.number)", nil)
    }

    private func play(_ e: Episode, from start: Double?) {
        guard let url = vod.url(e) else { return }
        player.playVOD(.init(key: "e\(e.id)", title: series.title, subtitle: "S\(e.season) E\(e.number) · \(e.title)",
                             artwork: series.cover, url: url, seriesID: series.id, start: start, episode: e))
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    var online: OnlineEpisode? = nil
    let fallback: String?
    let progress: Double?
    let action: () -> Void
    @State private var hovering = false

    /// The provider's name unless it's just "Episode N", then the real one from online info.
    private var title: String {
        let generic = episode.title.hasPrefix("Episode ")
        if generic, let n = online?.name, !n.isEmpty, !n.hasPrefix("Episode ") { return "\(episode.number). \(n)" }
        return generic ? episode.title : "\(episode.number). \(episode.title)"
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkView(url: episode.image ?? online?.thumbnail ?? fallback, maxPixels: 500, placeholder: "E\(episode.number)")
                        .frame(width: 192, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if hovering {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 192, height: 108)
                            .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if progress != nil {
                        Capsule().fill(.white.opacity(0.9)).frame(width: 60, height: 3).padding(8)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).lineLimit(2)
                    Text(metaLine([online?.released, episode.duration, episode.video?.tier])).font(.caption).foregroundStyle(.secondary)
                    if let plot = episode.plot ?? online?.overview {
                        Text(plot).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PlayPill: View {
    let title: String
    let icon: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .foregroundStyle(primary ? Color.black : Color.primary)
                .background(primary ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}

private struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary, lineWidth: 1))
            .foregroundStyle(.secondary)
    }
}

/// The show's title logo (transparent artwork) when online info has one, otherwise the title in text.
struct TitleLogo: View {
    let logo: String?
    let title: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 380, maxHeight: 120, alignment: .leading)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .accessibilityLabel(title)
                    .help(title)
            } else {
                Text(title).font(.system(size: 36, weight: .bold)).lineLimit(2)
            }
        }
        .task(id: logo) {
            image = nil
            guard let logo else { return }
            let img = await ImageLoader.shared.image(logo, maxPixels: 800)
            withAnimation(.easeOut(duration: 0.25)) { image = img }
        }
    }
}

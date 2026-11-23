import SwiftUI

/// Search everywhere: channels, movies and series in one page.
struct SearchResultsView: View {
    @Environment(Library.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(VODStore.self) private var vod
    let query: String
    let channels: [Channel]
    let nav: Navigator

    @State private var movies: [Movie] = []
    @State private var series: [Series] = []
    @State private var showAllChannels = false

    private let posterColumns = [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 22, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Text("Results for “\(query)”")
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(1)

                    if !channels.isEmpty {
                        section("Channels", count: channels.count) {
                            LazyVStack(spacing: 2) {
                                ForEach(showAllChannels ? channels : Array(channels.prefix(8))) { c in
                                    ChannelRow(channel: c, focused: nav.focusID == c.id, isFavorite: library.isFavorite(c),
                                               group: library.groupName(c.groupID).titleCased, quality: library.quality(c)) {
                                        nav.focusID = c.id
                                        player.play(c, in: channels)
                                    }
                                    .onHover { nav.hover(c.id, $0) }
                                    .contextMenu { Menu("Add to Playlist") { PlaylistMenuItems(channel: c) } }
                                    .id(c.id)
                                }
                            }
                            .padding(.horizontal, -12)
                            if channels.count > 8 {
                                Button(showAllChannels ? "Show fewer" : "Show all \(channels.count) channels") { showAllChannels.toggle() }
                                    .buttonStyle(.link)
                            }
                        }
                    }

                    if !movies.isEmpty {
                        section("Movies", count: movies.count) {
                            LazyVGrid(columns: posterColumns, spacing: 26) {
                                ForEach(movies) { m in
                                    NavigationLink(value: m) {
                                        PosterCard(title: m.title, poster: m.poster, caption: m.year ?? "",
                                                   badges: vod.quick(m)?.badges ?? [], detail: vod.categoryLabel(movie: m))
                                    }
                                    .task { vod.enrich(m) }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if !series.isEmpty {
                        section("Series", count: series.count) {
                            LazyVGrid(columns: posterColumns, spacing: 26) {
                                ForEach(series) { s in
                                    NavigationLink(value: s) {
                                        PosterCard(title: s.title, poster: s.cover,
                                                   caption: [s.year, vod.quick(s)?.counts].compactMap { $0 }.joined(separator: " · "),
                                                   badges: vod.quick(s)?.badges ?? [], detail: vod.categoryLabel(series: s))
                                    }
                                    .task { vod.enrich(s) }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if vod.indexing && vod.allMovies.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Getting the movie and series list ready for search (first time only)…")
                                .foregroundStyle(.secondary)
                        }
                    } else if channels.isEmpty && movies.isEmpty && series.isEmpty {
                        Text("Nothing matches “\(query)”.").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 22)
            }
            .navigationDestination(for: Movie.self) { MovieDetailView(movie: $0) }
            .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
        }
        // Debounced: searching 150k titles on every keystroke would stutter.
        .task(id: "\(query)|\(vod.allMovies.count)|\(vod.allSeries.count)") {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            movies = vod.searchMovies(query, limit: 60)
            series = vod.searchSeries(query, limit: 60)
        }
        .onChange(of: query) { showAllChannels = false }
    }

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title2.weight(.bold))
                Text(count >= 60 && title != "Channels" ? "60+" : "\(count)").foregroundStyle(.tertiary)
            }
            content()
        }
    }
}

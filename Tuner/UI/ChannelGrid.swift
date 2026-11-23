import SwiftUI

/// The detail pane: a big title, then channels as a grid of tiles or a compact list.
struct ChannelBrowser: View {
    @Environment(Library.self) private var library
    @Environment(PlayerModel.self) private var player
    let channels: [Channel]
    let title: String
    let emptyMessage: String
    let scrollID: String
    let showGroup: Bool
    let mode: ViewMode
    let nav: Navigator

    @State private var width: CGFloat = 900

    private let tileMin: CGFloat = 190
    private let spacing: CGFloat = 26
    private let hPad: CGFloat = 36

    private var columnCount: Int {
        mode == .list ? 1 : max(1, Int((width - hPad * 2 + spacing) / (tileMin + spacing)))
    }

    var body: some View {
        Group {
            if channels.isEmpty {
                VStack(spacing: 10) {
                    if library.isLoading && library.channels.isEmpty { ProgressView() }
                    Text(emptyMessage).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: mode == .grid ? 22 : 14) {
                            header
                            if mode == .grid { grid } else { list }
                        }
                        .padding(.horizontal, hPad)
                        .padding(.top, 18)
                        .padding(.bottom, 40)
                    }
                    .id(scrollID + mode.rawValue)
                    .onChange(of: nav.scrollTarget) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .onChange(of: columnCount, initial: true) { nav.columns = columnCount }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .lineLimit(1)
            Text("\(channels.count) channels")
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columnCount),
                  spacing: 30) {
            ForEach(channels) { channel in
                ChannelTile(channel: channel, focused: nav.focusID == channel.id,
                            isFavorite: library.isFavorite(channel)) { play(channel) }
                    .onHover { nav.hover(channel.id, $0) }
                    .contextMenu { menu(channel) }
                    .id(channel.id)
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 2) {
            ForEach(channels) { channel in
                ChannelRow(channel: channel, focused: nav.focusID == channel.id,
                           isFavorite: library.isFavorite(channel),
                           group: showGroup ? library.groupName(channel.groupID).titleCased : nil) { play(channel) }
                    .onHover { nav.hover(channel.id, $0) }
                    .contextMenu { menu(channel) }
                    .id(channel.id)
            }
        }
        .padding(.horizontal, -12)
    }

    private func play(_ channel: Channel) {
        nav.focusID = channel.id
        player.play(channel, in: channels)
    }

    @ViewBuilder private func menu(_ channel: Channel) -> some View {
        Button("Play") { play(channel) }
        Button(library.isFavorite(channel) ? "Remove from Favorites" : "Add to Favorites") {
            library.toggleFavorite(channel)
        }
    }
}

// MARK: - Grid tile

struct ChannelTile: View {
    let channel: Channel
    let focused: Bool
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                ZStack {
                    Tile.background
                    Tile.sheen
                    LogoView(channel: channel)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.yellow)
                            .padding(6)
                            .background(.black.opacity(0.35), in: Circle())
                            .padding(8)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(focused ? 0.55 : 0.07), lineWidth: focused ? 1.5 : 1)
                }
                .shadow(color: .black.opacity(focused ? 0.45 : 0.15), radius: focused ? 22 : 5, y: focused ? 14 : 3)
                .scaleEffect(focused ? 1.06 : 1)
                .zIndex(focused ? 1 : 0)

                Text(channel.displayName)
                    .font(.system(size: 13, weight: focused ? .semibold : .medium))
                    .lineLimit(1)
                    .foregroundStyle(focused ? .primary : .secondary)
                    .padding(.horizontal, 2)
                    .offset(y: focused ? 4 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: focused)
        .help(channel.name)
    }
}

// MARK: - List row

struct ChannelRow: View {
    let channel: Channel
    let focused: Bool
    let isFavorite: Bool
    let group: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Tile.background
                    LogoView(channel: channel, monogramSize: 13)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.displayName)
                        .font(.system(size: 14, weight: focused ? .semibold : .regular))
                        .lineLimit(1)
                    if let group, !group.isEmpty {
                        Text(group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isFavorite {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                }
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(focused ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(focused ? 0.09 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: focused)
        .help(channel.name)
    }
}

enum Tile {
    static let background = LinearGradient(
        colors: [Color(white: 0.24), Color(white: 0.14)],
        startPoint: .top, endPoint: .bottom
    )
    /// Soft top highlight, like light catching glass.
    static let sheen = LinearGradient(
        colors: [.white.opacity(0.07), .clear],
        startPoint: .top, endPoint: .center
    )
}

/// Channel logo, or a monogram when there is none (or it fails to load).
struct LogoView: View {
    let channel: Channel
    var monogramSize: CGFloat = 26
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if failed || channel.logo == nil {
                Text(monogram)
                    .font(.system(size: monogramSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: channel.id) {
            image = nil
            failed = false
            guard let logo = channel.logo else { return }
            let img = await ImageLoader.shared.image(logo)
            if Task.isCancelled { return }
            image = img
            failed = img == nil
        }
    }

    private var monogram: String {
        let words = channel.displayName.split(separator: " ").filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters = words.prefix(3).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "TV" : letters.uppercased()
    }
}

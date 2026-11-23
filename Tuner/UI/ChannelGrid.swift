import SwiftUI

struct ChannelGrid: View {
    @Environment(Library.self) private var library
    @Environment(PlayerModel.self) private var player
    let channels: [Channel]
    let title: String
    let emptyMessage: String
    let scrollID: String

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 24, alignment: .top)]

    var body: some View {
        Group {
            if channels.isEmpty {
                VStack(spacing: 10) {
                    if library.isLoading && library.channels.isEmpty { ProgressView() }
                    Text(emptyMessage).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(title).font(.largeTitle.weight(.bold))
                            Text("\(channels.count)").font(.title3).foregroundStyle(.tertiary)
                        }
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(channels) { channel in
                                ChannelTile(channel: channel, isFavorite: library.isFavorite(channel)) {
                                    player.play(channel, in: channels)
                                }
                                .contextMenu {
                                    Button(library.isFavorite(channel) ? "Remove from Favorites" : "Add to Favorites") {
                                        library.toggleFavorite(channel)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                }
                .id(scrollID)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ChannelTile: View {
    let channel: Channel
    let isFavorite: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Tile.background
                    LogoView(channel: channel)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 20)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(8)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(hovering ? 0.25 : 0.06), lineWidth: 1)
                }
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.12), radius: hovering ? 18 : 4, y: hovering ? 12 : 2)
                .scaleEffect(hovering ? 1.05 : 1)

                Text(channel.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovering)
        .help(channel.name)
    }
}

enum Tile {
    static let background = LinearGradient(
        colors: [Color(white: 0.22), Color(white: 0.13)],
        startPoint: .top, endPoint: .bottom
    )
}

/// Channel logo, or a monogram when there is none (or it fails to load).
struct LogoView: View {
    let channel: Channel
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
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
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

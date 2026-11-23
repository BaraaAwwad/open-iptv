import SwiftUI

/// Menu items for one channel: Favorites first, then your playlists, each a checkmark you can tick or
/// untick, then New Playlist….
struct PlaylistMenuItems: View {
    @Environment(Library.self) private var library
    let channel: Channel

    var body: some View {
        toggle("Favorites", .favorites)
        if !library.playlists.isEmpty {
            Divider()
            ForEach(library.playlists) { p in toggle(p.name, .custom(p.id)) }
        }
        Divider()
        Button("New Playlist…") { library.newPlaylistRequest = .init(channels: [channel]) }
    }

    private func toggle(_ title: String, _ ref: PlaylistRef) -> some View {
        Toggle(title, isOn: Binding(
            get: { library.contains(channel, in: ref) },
            set: { _ in library.toggle(channel, in: ref) }
        ))
    }
}

/// Menu items for several channels at once (select mode): adds them all to the chosen playlist.
struct BulkPlaylistMenuItems: View {
    @Environment(Library.self) private var library
    let channels: [Channel]
    var done: () -> Void = {}

    var body: some View {
        Button("Favorites") { library.add(channels, to: .favorites); done() }
        if !library.playlists.isEmpty {
            Divider()
            ForEach(library.playlists) { p in
                Button(p.name) { library.add(channels, to: .custom(p.id)); done() }
            }
        }
        Divider()
        Button("New Playlist…") { library.newPlaylistRequest = .init(channels: channels); done() }
    }
}

/// The player's "Add to Playlist" button: always a +, the menu shows where the channel already is.
struct AddToPlaylistButton: View {
    let channel: Channel
    var size: CGFloat = 34

    var body: some View {
        Menu {
            PlaylistMenuItems(channel: channel)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassCircle()
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add to Playlist")
    }
}

/// Name sheet for a new playlist (or renaming one).
struct PlaylistNameSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let request: Library.NewPlaylistRequest
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.renaming == nil ? "New Playlist" : "Rename Playlist").font(.headline)
            if request.channels.count == 1, let channel = request.channels.first {
                Text("\(channel.displayName) will be added to it.").font(.callout).foregroundStyle(.secondary)
            } else if request.channels.count > 1 {
                Text("\(request.channels.count) channels will be added to it.").font(.callout).foregroundStyle(.secondary)
            }
            TextField("Name", text: $name, prompt: Text("Match Day"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.renaming == nil ? "Create" : "Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            if let id = request.renaming { name = library.name(of: .custom(id)) }
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let id = request.renaming {
            library.renamePlaylist(id, to: name)
        } else {
            library.createPlaylist(name, with: request.channels)
        }
        dismiss()
    }
}

/// Left column of My Playlists: Favorites, then your playlists. The channels show to the right.
struct PlaylistsPane: View {
    @Environment(Library.self) private var library
    @Binding var selection: PlaylistRef?

    var body: some View {
        List(selection: $selection) {
            row("Favorites", "star.fill", .favorites, tint: .yellow)
            if !library.playlists.isEmpty {
                Section("Your Playlists") {
                    ForEach(library.playlists) { p in
                        row(p.name, "music.note.list", .custom(p.id), tint: .accentColor)
                            .contextMenu {
                                Button("Rename…") { library.newPlaylistRequest = .init(renaming: p.id) }
                                Button("Delete", role: .destructive) {
                                    if selection == .custom(p.id) { selection = .favorites }
                                    library.deletePlaylist(p.id)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                library.newPlaylistRequest = .init()
            } label: {
                Label("New Playlist", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 230)
        .background(Color.primary.opacity(0.03))
    }

    private func row(_ title: String, _ icon: String, _ ref: PlaylistRef, tint: Color) -> some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .badge(library.channels(in: ref).count)
        .tag(ref)
    }
}

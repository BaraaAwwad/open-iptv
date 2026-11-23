import SwiftUI

/// Menu items: Favorites first, then your playlists (checked when the channel is in them), then New Playlist….
struct PlaylistMenuItems: View {
    @Environment(Library.self) private var library
    let channel: Channel

    var body: some View {
        item("Favorites", "star", .favorites)
        if !library.playlists.isEmpty {
            Divider()
            ForEach(library.playlists) { p in
                item(p.name, "music.note.list", .custom(p.id))
            }
        }
        Divider()
        Button {
            library.newPlaylistRequest = .init(channel: channel)
        } label: {
            Label("New Playlist…", systemImage: "plus")
        }
    }

    private func item(_ title: String, _ icon: String, _ ref: PlaylistRef) -> some View {
        Button {
            library.toggle(channel, in: ref)
        } label: {
            if library.contains(channel, in: ref) {
                Label(title, systemImage: "checkmark")
            } else {
                Label(title, systemImage: icon)
            }
        }
    }
}

/// The player's "Add to Playlist" button.
struct AddToPlaylistButton: View {
    @Environment(Library.self) private var library
    let channel: Channel
    var size: CGFloat = 34

    private var inAny: Bool {
        library.contains(channel, in: .favorites) || library.playlists.contains { $0.channelIDs.contains(channel.id) }
    }

    var body: some View {
        Menu {
            PlaylistMenuItems(channel: channel)
        } label: {
            Image(systemName: inAny ? "checkmark" : "plus")
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
            if let channel = request.channel {
                Text("\(channel.displayName) will be added to it.").font(.callout).foregroundStyle(.secondary)
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
            library.createPlaylist(name, with: request.channel)
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

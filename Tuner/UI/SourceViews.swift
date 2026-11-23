import SwiftUI

/// First launch: no playlists yet.
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Welcome to Tuner").font(.largeTitle.weight(.bold))
                Text("Add your IPTV provider to get started.").foregroundStyle(.secondary)
            }
            SourceForm()
                .frame(width: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SourceForm: View {
    @Environment(Library.self) private var library
    var onDone: (() -> Void)?

    @State private var kind: Source.Kind = .xtream
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $kind) {
                ForEach(Source.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                TextField("Name", text: $name, prompt: Text("My IPTV"))
                if kind == .xtream {
                    TextField("Server", text: $url, prompt: Text("http://example.com:8080"))
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                } else {
                    TextField("Playlist URL", text: $url, prompt: Text("http://…/playlist.m3u"))
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: kind == .xtream ? 200 : 120)
            .textContentType(.none)
            .autocorrectionDisabled()

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                if let onDone { Button("Cancel", action: onDone).keyboardShortcut(.cancelAction) }
                Button {
                    Task { await save() }
                } label: {
                    if checking { ProgressView().controlSize(.small).padding(.horizontal, 8) } else { Text("Add Playlist") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || checking)
            }
        }
    }

    private var canSave: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty && (kind == .m3u || (!username.isEmpty && !password.isEmpty))
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let source = Source(
            name: trimmedName.isEmpty ? (URL(string: url)?.host() ?? url) : trimmedName,
            kind: kind,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespaces),
            password: password
        )
        checking = true
        error = nil
        defer { checking = false }
        do {
            try await Library.validate(source)
            await library.add(source)
            onDone?()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Environment(Library.self) private var library
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlists").font(.headline)
            List {
                ForEach(library.sources) { s in
                    HStack {
                        Image(systemName: s.id == library.activeID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(s.id == library.activeID ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text("\(s.kind.label) · \(URL(string: s.server)?.host() ?? s.url)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s.id != library.activeID {
                            Button("Use") { Task { await library.activate(s.id) } }
                        }
                        Button(role: .destructive) { Task { await library.remove(s.id) } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Add Playlist…") { adding = true }
            }
        }
        .padding(20)
        .frame(width: 520, height: 340)
        .sheet(isPresented: $adding) {
            SourceForm(onDone: { adding = false })
                .padding(24)
                .frame(width: 460)
        }
    }
}

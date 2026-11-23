import SwiftUI

@main
struct TunerApp: App {
    @State private var library: Library
    @State private var player: PlayerModel

    init() {
        let library = Library()
        _library = State(initialValue: library)
        _player = State(initialValue: PlayerModel(library: library))
    }

    var body: some Scene {
        // One window: most providers allow a single connection, so one player at a time.
        Window("Tuner", id: "main") {
            RootView()
                .environment(library)
                .environment(player)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Channels") {
                Button("Refresh Channel List") { Task { await library.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(library.active == nil || library.isLoading)
            }
        }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(PlayerModel.self) private var player

    var body: some View {
        ZStack {
            if library.sources.isEmpty {
                WelcomeView()
            } else {
                BrowserView()
                    .opacity(player.isPresented ? 0 : 1)
                    .allowsHitTesting(!player.isPresented)
            }
            if player.isPresented {
                PlayerScreen()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: player.isPresented)
        .task { await library.load() }
    }
}

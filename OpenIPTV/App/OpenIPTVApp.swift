import SwiftUI

@main
struct OpenIPTVApp: App {
    @State private var library: Library
    @State private var player: PlayerModel
    @State private var scanner: QualityScanner

    init() {
        let library = Library()
        let player = PlayerModel(library: library)
        // The scanner only probes while nothing plays, and drops its probe the moment you press play.
        let scanner = QualityScanner(library: library, isPlayerBusy: { player.mode != .hidden })
        player.willOpenStream = { scanner.yieldToPlayer() }
        _library = State(initialValue: library)
        _player = State(initialValue: player)
        _scanner = State(initialValue: scanner)
    }

    var body: some Scene {
        // One window: most providers allow a single connection, so one player at a time.
        Window("Open IPTV", id: "main") {
            RootView()
                .environment(library)
                .environment(player)
                .environment(scanner)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            ViewModeCommands()
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
                    .opacity(player.isFull ? 0 : 1)
                    .allowsHitTesting(!player.isFull)
            }
            if player.mode == .mini {
                MiniPlayer()
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            if player.isFull {
                PlayerScreen()
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: player.mode)
        .sheet(item: Binding(get: { library.newPlaylistRequest }, set: { library.newPlaylistRequest = $0 })) { request in
            PlaylistNameSheet(request: request)
        }
        .task { await library.load() }
    }
}

struct ViewModeCommands: Commands {
    @AppStorage("viewMode") private var viewMode: ViewMode = .grid

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("as Grid") { viewMode = .grid }.keyboardShortcut("1")
            Button("as List") { viewMode = .list }.keyboardShortcut("2")
            Divider()
        }
    }
}

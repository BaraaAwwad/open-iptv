import SwiftUI

@main
struct OpenIPTVApp: App {
    @State private var library: Library
    @State private var player: PlayerModel
    @State private var scanner: QualityScanner
    @State private var vod: VODStore

    init() {
        let library = Library()
        let player = PlayerModel(library: library)
        // The scanner only probes while nothing plays, and drops its probe the moment you press play.
        let scanner = QualityScanner(library: library, isPlayerBusy: { player.mode != .hidden })
        player.willOpenStream = { scanner.yieldToPlayer() }
        // Switching provider: stop the stream and the scan first, so nothing uses the old provider's
        // channels with the new provider's login.
        library.willSwitchSource = {
            scanner.cancel()
            player.close()
        }
        _library = State(initialValue: library)
        _player = State(initialValue: player)
        _scanner = State(initialValue: scanner)
        let vod = VODStore(library: library)
        vod.isPlayerBusy = { player.mode != .hidden || scanner.isRunning }
        player.saveVODProgress = { item, position, duration in
            vod.save(item, position: position, duration: duration)
        }
        _vod = State(initialValue: vod)
    }

    var body: some Scene {
        // One window: most providers allow a single connection, so one player at a time.
        Window("Open IPTV", id: "main") {
            RootView()
                .environment(library)
                .environment(player)
                .environment(scanner)
                .environment(vod)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            SidebarCommands()
            ViewModeCommands()
            CommandMenu("Playback") {
                Button(player.mode == .full ? "Picture in Picture" : "Expand Player") {
                    player.mode = player.mode == .full ? .mini : .full
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(player.mode == .hidden)
                Button("Stop") { player.close() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(player.mode == .hidden)
                Divider()
                Button("Previous Channel") { player.step(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(player.mode == .hidden || player.isVOD)
                Button("Next Channel") { player.step(1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(player.mode == .hidden || player.isVOD)
                Button("Go Live") { player.goLive() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(player.mode == .hidden || player.isVOD || !player.isBehindLive)
            }
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
    @Environment(VODStore.self) private var vod
    @State private var fullScreen = FullScreenController()
    @State private var pip = PiPWindowController { AnyView(EmptyView()) }

    var body: some View {
        ZStack {
            if library.sources.isEmpty {
                WelcomeView()
            } else {
                BrowserView()
                    .opacity(player.isFull ? 0 : 1)
                    .allowsHitTesting(!player.isFull)
            }
            // The player layers animate on their own. The animation used to sit on this whole ZStack, so
            // every PiP / full-screen switch also animated the split view re-laying out its sidebar.
            ZStack {
                if player.isFull {
                    PlayerScreen()
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: player.mode)
        }
        // Full-screen playback hides the window toolbar here, at the window's root, so the split view
        // and its sidebar never see a modifier change (toggling it inside the split view rebuilt them).
        // The big player is real macOS full screen only (see FullScreenController).
        .background(WindowReader { window in
            fullScreen.attach(window, player: player)
            pip.makeContent = { [player, library, vod] in
                AnyView(MiniPlayer().environment(player).environment(library).environment(vod))
            }
            pip.attach(window)
            if player.mode == .mini { pip.show() }
        })
        // In full screen the toolbar stays out of the way and slides in when you hover at the top,
        // so nothing has to hide or show it (which used to resize the window mid-transition).
        .windowToolbarFullScreenVisibility(.onHover)
        .onChange(of: player.mode) {
            fullScreen.sync()
            // PiP is its own small window (native resize / move).
            if player.mode == .mini { pip.show() } else { pip.hide() }
        }
        .sheet(item: Binding(get: { library.newPlaylistRequest }, set: { library.newPlaylistRequest = $0 })) { request in
            PlaylistNameSheet(request: request)
        }
        .task { await library.load() }
        // The movie / series index for search and Home, per provider, in the background.
        .task(id: library.activeID) { await vod.loadIndex() }
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

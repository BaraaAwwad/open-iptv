import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let view: MPVVideoView
    func makeNSView(context: Context) -> MPVVideoView { view }
    func updateNSView(_ nsView: MPVVideoView, context: Context) {}
}

/// Full-window player. Nothing is drawn over the picture unless the mouse moves.
struct PlayerScreen: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Library.self) private var library
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(view: player.videoView)

            centerState

            if controlsVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { player.step(-1); showControls(); return .handled }
        .onKeyPress(.downArrow) { player.step(1); showControls(); return .handled }
        .onKeyPress(.space) { player.togglePause(); showControls(); return .handled }
        .onKeyPress(.leftArrow) { player.volume = max(0, player.volume - 5); showControls(); return .handled }
        .onKeyPress(.rightArrow) { player.volume = min(130, player.volume + 5); showControls(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "mfs")) { press in
            switch press.characters {
            case "m": player.isMuted.toggle()
            case "f": NSApp.keyWindow?.toggleFullScreen(nil)
            case "s": if let c = player.channel { library.toggleFavorite(c) }
            default: break
            }
            showControls()
            return .handled
        }
        .onExitCommand { exit() }
        .onAppear { focused = true; showControls() }
        .onDisappear { hideTask?.cancel(); NSCursor.setHiddenUntilMouseMoves(false) }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
    }

    // MARK: Pieces

    @ViewBuilder private var centerState: some View {
        switch player.status {
        case .loading:
            ProgressView().controlSize(.large).tint(.white)
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "tv.slash").font(.system(size: 40, weight: .light))
                Text(message).font(.title3)
                HStack {
                    Button("Try Again") { player.retry() }
                    Button("Next Channel") { player.step(1) }
                }
                .controlSize(.large)
            }
            .foregroundStyle(.white.opacity(0.85))
        default:
            if player.isBuffering { ProgressView().controlSize(.large).tint(.white) }
        }
    }

    private var topBar: some View {
        HStack {
            Button { exit() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Back (Esc)")
            Spacer()
        }
        .padding(.top, isFullScreen ? 20 : 40)
        .padding(.horizontal, 24)
    }

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 18) {
            if let channel = player.channel {
                LogoView(channel: channel)
                    .frame(width: 92, height: 52)
                    .background(Tile.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(channel.displayName).font(.title3.weight(.semibold))
                        if library.isFavorite(channel) {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                        }
                    }
                    if let now = player.programmes.first {
                        HStack(spacing: 10) {
                            Text(now.title).lineLimit(1)
                            ProgressView(value: now.progress).frame(width: 90).tint(.white)
                            Text(now.end, style: .time).foregroundStyle(.white.opacity(0.6))
                        }
                        .font(.callout)
                        if player.programmes.count > 1 {
                            Text("Next: \(player.programmes[1].title)")
                                .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    } else {
                        Text(library.groupName(channel.groupID))
                            .font(.callout).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            Spacer(minLength: 20)
            HStack(spacing: 6) {
                iconButton("chevron.up", "Previous channel (↑)") { player.step(-1) }
                iconButton("chevron.down", "Next channel (↓)") { player.step(1) }
                iconButton(player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", "Mute (M)") {
                    player.isMuted.toggle()
                }
                Slider(value: Binding(get: { player.volume }, set: { player.volume = $0; player.isMuted = false }), in: 0...130)
                    .frame(width: 90)
                    .controlSize(.small)
                iconButton(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", "Full screen (F)") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 26)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); showControls() }) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Behaviour

    private var isFullScreen: Bool { NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }

    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, player.status == .playing else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func exit() {
        if isFullScreen {
            NSApp.keyWindow?.toggleFullScreen(nil)
        } else {
            player.close()
        }
    }
}

import SwiftUI

/// Hosts the one shared mpv video view. The mini player and the full player each get their own
/// container; the video view moves to whichever container appeared last, so playback never restarts.
struct VideoSurface: NSViewRepresentable {
    let view: MPVVideoView
    /// Only the visible player owns the video (the mini player stays mounted under the full one).
    var active = true

    func makeNSView(context: Context) -> VideoContainer { VideoContainer(video: view) }
    func updateNSView(_ container: VideoContainer, context: Context) {
        container.isActive = active
        if active { container.claim() }
    }
    static func dismantleNSView(_ container: VideoContainer, coordinator: ()) { container.release() }
}

final class VideoContainer: NSView {
    private let video: MPVVideoView
    var isActive = true

    init(video: MPVVideoView) {
        self.video = video
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && isActive { claim() }
    }

    func claim() {
        guard video.superview !== self else { return }
        video.removeFromSuperview()
        video.frame = bounds
        video.autoresizingMask = [.width, .height]
        addSubview(video)
    }

    func release() {
        if video.superview === self { video.removeFromSuperview() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Full-window player. Nothing is drawn over the picture unless the mouse moves.
struct PlayerScreen: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Library.self) private var library
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var overControls = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(view: player.videoView)
            // Double-click to toggle full screen; kept behind the controls so it never delays their clicks.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleFullScreen() }

            if controlsVisible {
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            statusOverlay

            if controlsVisible {
                VStack(spacing: 0) {
                    topBar.onHover { overControls = $0 }
                    Spacer()
                    bottomBar.onHover { overControls = $0 }
                }
                .padding(.horizontal, 22)
                .padding(.top, isFullScreen ? 18 : 40)
                .padding(.bottom, 22)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: showControls()
            case .ended: hideControls(after: 0.3)
            }
        }
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
            case "f": toggleFullScreen()
            case "s": if let c = player.channel { library.toggleFavorite(c) }
            default: break
            }
            showControls()
            return .handled
        }
        .onExitCommand { exit() }
        .onAppear { focused = true; showControls() }
        .onChange(of: player.status) { _, status in
            if status == .playing { hideControls(after: 1.2) } else { controlsVisible = true }
        }
        .onDisappear { hideTask?.cancel(); NSCursor.setHiddenUntilMouseMoves(false) }
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
    }

    // MARK: Center

    @ViewBuilder private var statusOverlay: some View {
        switch player.status {
        case .loading:
            ProgressView().controlSize(.large).tint(.white)
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "tv.slash").font(.system(size: 40, weight: .light))
                Text(message).font(.title3.weight(.medium))
                HStack(spacing: 10) {
                    pill("Try Again", "arrow.clockwise") { player.retry() }
                    pill("Next Channel", "forward.end.fill") { player.step(1) }
                }
            }
            .foregroundStyle(.white.opacity(0.9))
        default:
            if player.isBuffering {
                ProgressView().controlSize(.large).tint(.white)
            } else if controlsVisible {
                transport.onHover { overControls = $0 }
                    .transition(.opacity)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 34) {
            roundButton(player.isPaused ? "play.fill" : "pause.fill", size: 84, icon: 32, help: "Pause (Space)") { player.togglePause() }
                .overlay(alignment: .leading) {
                    roundButton("backward.end.fill", size: 60, icon: 18, help: "Previous channel (↑)") { player.step(-1) }
                        .offset(x: -94)
                }
                .overlay(alignment: .trailing) {
                    roundButton("forward.end.fill", size: 60, icon: 18, help: "Next channel (↓)") { player.step(1) }
                        .offset(x: 94)
                }
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top) {
            HStack(spacing: 2) {
                capsuleButton("xmark", help: "Stop and close") { player.close() }
                capsuleButton("pip.exit", help: "Picture in picture (Esc)") { player.mode = .mini }
                capsuleButton(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              help: "Full screen (F)") { toggleFullScreen() }
            }
            .padding(4)
            .glassCapsule()

            Spacer()

            HStack(spacing: 10) {
                Slider(value: Binding(get: { player.isMuted ? 0 : player.volume },
                                      set: { player.volume = $0; player.isMuted = false }), in: 0...130)
                    .frame(width: 120)
                    .controlSize(.small)
                    .tint(.white)
                capsuleButton(volumeIcon, help: "Mute (M)") { player.isMuted.toggle() }
            }
            .padding(.leading, 16)
            .padding(4)
            .glassCapsule()
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let channel = player.channel {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(library.groupName(channel.groupID).titleCased.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(channel.displayName)
                            .font(.system(size: 26, weight: .bold))
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 2) {
                        capsuleButton(library.isFavorite(channel) ? "star.fill" : "star", help: "Favorite (S)") {
                            library.toggleFavorite(channel)
                        }
                        .foregroundStyle(library.isFavorite(channel) ? .yellow : .white)
                    }
                    .padding(4)
                    .glassCapsule()
                }
                if let now = player.programmes.first {
                    HStack(spacing: 12) {
                        Text(now.start, style: .time).monospacedDigit()
                        VStack(alignment: .leading, spacing: 5) {
                            Text(now.title).font(.callout.weight(.semibold)).lineLimit(1)
                            ProgressView(value: now.progress).tint(.white).controlSize(.small)
                        }
                        Text(now.end, style: .time).monospacedDigit()
                        if player.programmes.count > 1 {
                            Divider().frame(height: 26)
                            Text("Next: \(player.programmes[1].title)")
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(maxWidth: 260, alignment: .leading)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassCapsule()
                }
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: Building blocks

    private var volumeIcon: String {
        if player.isMuted || player.volume == 0 { return "speaker.slash.fill" }
        return player.volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
    }

    private func capsuleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); showControls() }) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
    }

    private func roundButton(_ symbol: String, size: CGFloat, icon: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); showControls() }) {
            Image(systemName: symbol)
                .font(.system(size: icon, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassCircle()
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .help(help)
    }

    private func pill(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassCapsule()
        }
        .buttonStyle(PressScale())
    }

    // MARK: Behaviour

    private var isFullScreen: Bool { NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }

    private func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    private func showControls() {
        controlsVisible = true
        hideControls(after: 1.2)
    }

    private func hideControls(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, player.status == .playing, !overControls else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// Esc leaves window full screen first, then shrinks to picture in picture (playback keeps going).
    private func exit() {
        if isFullScreen { toggleFullScreen() } else { player.mode = .mini }
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension View {
    /// Liquid Glass on macOS 26+, a dark material before that.
    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder func glassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }
}

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
    /// Every live container, so a disappearing owner can hand the picture to the one still on screen.
    private static let all = NSHashTable<VideoContainer>.weakObjects()

    init(video: MPVVideoView) {
        self.video = video
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        Self.all.add(self)
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
        Self.all.remove(self)
        guard video.superview === self else { return }
        video.removeFromSuperview()
        // Never leave the picture orphaned: give it to whichever player view is still showing.
        Self.all.allObjects.last { $0.isActive && $0.window != nil }?.claim()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Full-window player. Nothing is drawn over the picture unless the mouse moves.
struct PlayerScreen: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Library.self) private var library
    @State private var controlsVisible = true
    /// The auto-hide timer lives in a plain object: as view state it re-rendered every control on each
    /// mouse movement, which ate clicks.
    @State private var hider = HideTimer()
    @State private var overControls = false
    @State private var showInfo = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black
            // Owns the picture only while actually in full mode: during its fade-out after Esc it must
            // not grab the video back from the PiP view.
            PlayerVideo(active: player.mode == .full)
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

            if player.airPlay != .off {
                AirPlayCard()
            } else {
                statusOverlay
            }

            if showInfo {
                StreamInfoPanel(isShown: $showInfo)
                    .onHover { overControls = $0 }
                    .padding(.top, 112)
                    .padding(.trailing, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if controlsVisible {
                VStack(spacing: 0) {
                    topBar.onHover { overControls = $0 }
                    Spacer()
                    bottomBar.onHover { overControls = $0 }
                }
                .padding(.horizontal, 22)
                .padding(.top, 60) // below the title bar / full-screen menu bar zone, which swallows clicks
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
        .onKeyPress(.upArrow) {
            if player.isVOD { player.volume = min(130, player.volume + 5) } else { player.step(-1) }
            showControls(); return .handled
        }
        .onKeyPress(.downArrow) {
            if player.isVOD { player.volume = max(0, player.volume - 5) } else { player.step(1) }
            showControls(); return .handled
        }
        .onKeyPress(.space) { player.togglePause(); showControls(); return .handled }
        .onKeyPress(.leftArrow) {
            if player.isVOD { player.skip(-10) } else { player.volume = max(0, player.volume - 5) }
            showControls(); return .handled
        }
        .onKeyPress(.rightArrow) {
            if player.isVOD { player.skip(10) } else { player.volume = min(130, player.volume + 5) }
            showControls(); return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "mfsi")) { press in
            switch press.characters {
            case "i": showInfo.toggle()
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
        .onDisappear { hider.cancel(); NSCursor.setHiddenUntilMouseMoves(false) }
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showInfo)
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
                    pill("Next Channel", "chevron.down") { player.step(1) }
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
                    Group {
                        if player.isVOD {
                            roundButton("gobackward.10", size: 60, icon: 22, help: "Back 10 seconds (←)") { player.skip(-10) }
                        } else {
                            ChannelButton(up: true, size: 60) { player.step(-1); showControls() }
                        }
                    }
                    .offset(x: -94)
                }
                .overlay(alignment: .trailing) {
                    Group {
                        if player.isVOD {
                            roundButton("goforward.10", size: 60, icon: 22, help: "Forward 10 seconds (→)") { player.skip(10) }
                        } else {
                            ChannelButton(up: false, size: 60) { player.step(1); showControls() }
                        }
                    }
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
                capsuleButton("info.circle", help: "Stream info (I)") { showInfo.toggle() }
                    .foregroundStyle(showInfo ? .blue : .white)
                capsuleButton("airplayvideo", help: player.airPlay == .off ? "AirPlay to a TV" : "Stop AirPlay") { player.toggleAirPlay() }
                    .foregroundStyle(player.airPlay == .off ? .white : .blue)
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
                        Text((player.vod?.subtitle ?? library.groupName(channel.groupID).titleCased).uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                        Text(channel.displayName)
                            .font(.system(size: 26, weight: .bold))
                            .lineLimit(1)
                        if let now = player.programmes.first {
                            Text(now.title)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if !player.isVOD {
                        LivePill { player.goLive(); showControls() }
                        AddToPlaylistButton(channel: channel, size: 40)
                    }
                }
                if player.isVOD {
                    Scrubber()
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
        if !controlsVisible { controlsVisible = true }
        if !focused { focused = true } // keep keyboard shortcuts working after clicking a control
        hideControls(after: 1.2)
    }

    private func hideControls(after seconds: Double) {
        hider.schedule(after: seconds) {
            guard player.status == .playing, !overControls else { return }
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

/// Channel up / down: a chevron with a small "CH" under it, so it never reads as skip or seek.
struct ChannelButton: View {
    let up: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: size * 0.02) {
                Image(systemName: up ? "chevron.up" : "chevron.down")
                    .font(.system(size: size * 0.3, weight: .bold))
                Text("CH")
                    .font(.system(size: size * 0.17, weight: .heavy, design: .rounded))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .glassCircle()
            .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .help(up ? "Previous channel (↑)" : "Next channel (↓)")
    }
}

/// Red LIVE badge at the live edge; once paused or stalled it turns into a Go Live button that resyncs.
struct LivePill: View {
    @Environment(PlayerModel.self) private var player
    var compact = false
    let action: () -> Void

    var body: some View {
        let behind = player.isBehindLive
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(behind ? Color.white.opacity(0.5) : .red)
                    .frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
                Text(behind ? "GO LIVE" : "LIVE")
                    .font(.system(size: compact ? 10 : 12, weight: .bold))
                    .tracking(0.6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 9 : 14)
            .padding(.vertical, compact ? 5 : 9)
            .glassCapsule()
        }
        .buttonStyle(PressScale())
        .disabled(!behind)
        .help(behind ? "Jump back to live" : "Watching live")
        .animation(.easeInOut(duration: 0.2), value: behind)
    }
}

/// The picture: mpv normally, AVPlayer while AirPlay is on.
struct PlayerVideo: View {
    @Environment(PlayerModel.self) private var player
    let active: Bool

    var body: some View {
        if player.airPlay == .ready && player.isOnTV {
            // The TV has the picture. Show plain black here (AVKit's own "playing on" screen would
            // stack under our card).
            Color.black
        } else if player.airPlay == .ready {
            AirPlayVideo(player: player.airPlayer)
        } else {
            VideoSurface(view: player.videoView, active: active)
        }
    }
}

/// Center card while AirPlay is on: getting ready, pick a TV, playing on the TV, or what went wrong.
struct AirPlayCard: View {
    @Environment(PlayerModel.self) private var player
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 8 : 14) {
            switch player.airPlay {
            case .off:
                EmptyView()
            case .preparing:
                ProgressView().tint(.white).controlSize(compact ? .small : .regular)
                Text("Getting the stream ready for AirPlay…").font(compact ? .caption : .callout)
            case .ready where player.isOnTV:
                Image(systemName: "airplayvideo").font(.system(size: compact ? 22 : 40, weight: .light))
                Text("Playing on your TV").font(compact ? .caption.weight(.semibold) : .title3.weight(.semibold))
                if !compact { stopButton }
            case .ready:
                RoutePicker(player: player.airPlayer, openOnAppear: true)
                    .frame(width: compact ? 30 : 44, height: compact ? 30 : 44)
                Text("Choose a TV").font(compact ? .caption.weight(.semibold) : .title3.weight(.semibold))
                if !compact { stopButton }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: compact ? 20 : 32, weight: .light))
                Text(message).font(compact ? .caption : .callout).multilineTextAlignment(.center).frame(maxWidth: 360)
                Button("Back to this Mac") { player.stopAirPlay(resumeHere: true) }
                    .buttonStyle(PressScale())
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glassCapsule()
            }
        }
        .foregroundStyle(.white)
        .padding(compact ? 12 : 26)
        .background(.black.opacity(player.isOnTV ? 0 : 0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var stopButton: some View {
        Button { player.stopAirPlay(resumeHere: true) } label: {
            Label("Stop AirPlay", systemImage: "xmark")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .glassCapsule()
        }
        .buttonStyle(PressScale())
    }
}

/// Debounced "hide the controls" timer that doesn't trigger SwiftUI updates when rescheduled.
final class HideTimer {
    private var work: DispatchWorkItem?
    func schedule(after seconds: Double, _ action: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: action)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
    func cancel() { work?.cancel() }
}

/// Movie / episode progress you can drag: elapsed, bar, remaining.
struct Scrubber: View {
    @Environment(PlayerModel.self) private var player
    var compact = false
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let t = player.vodTime()
            let position = dragging ?? t?.position ?? 0
            let duration = t?.duration ?? 0
            if compact {
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(width: duration > 0 ? geo.size.width * position / duration : 0)
                        }
                }
                .frame(height: 3)
            } else {
                HStack(spacing: 12) {
                    Text(Self.format(position)).monospacedDigit()
                    Slider(value: Binding(get: { position }, set: { dragging = $0 }), in: 0...max(duration, 1)) { editing in
                        if !editing, let d = dragging { player.seek(to: d); dragging = nil }
                    }
                    .controlSize(.small)
                    .tint(.white)
                    Text("-" + Self.format(max(0, duration - position))).monospacedDigit()
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassCapsule()
            }
        }
    }

    static func format(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

import AppKit
import Observation

@MainActor @Observable
final class PlayerModel {
    enum Status: Equatable { case idle, loading, playing, failed(String) }

    @ObservationIgnored let mpv = MPV()
    @ObservationIgnored lazy var videoView = MPVVideoView(mpv: mpv)
    @ObservationIgnored private let library: Library
    @ObservationIgnored private var epgTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    /// hidden → nothing playing; mini → picture in picture in a corner; full → fills the window.
    enum Mode { case hidden, mini, full }
    var mode: Mode = .hidden
    var isFull: Bool { mode == .full }
    private(set) var channel: Channel?
    private(set) var list: [Channel] = []
    private(set) var status: Status = .idle
    private(set) var isBuffering = false
    private(set) var isPaused = false
    /// True once a live channel was paused or stalled, so what's on screen is no longer live.
    private(set) var isBehindLive = false
    private(set) var programmes: [Programme] = []

    var volume: Double {
        didSet { mpv.setVolume(volume); UserDefaults.standard.set(volume, forKey: "volume") }
    }
    var isMuted = false {
        didSet { mpv.setMute(isMuted) }
    }

    init(library: Library) {
        self.library = library
        volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 100
        mpv.setVolume(volume)
        mpv.onEvent = { [weak self] e in self?.handle(e) }
    }

    /// Plays `channel`; `list` is what ↑/↓ step through.
    func play(_ channel: Channel, in list: [Channel]) {
        self.list = list.isEmpty ? [channel] : list
        self.channel = channel
        if mode == .hidden { mode = .mini }
        guard let url = library.streamURL(channel) else {
            status = .failed("No stream address for this channel.")
            return
        }
        status = .loading
        isBuffering = false
        isPaused = false
        isBehindLive = false
        programmes = []
        mpv.load(url)
        watchForStall(channel)
        library.markWatched(channel)
        loadEPG(channel)
    }

    /// Channel up / down. Steps through the list you played from; when that list is just this channel
    /// (a one-result search, say) it steps through the channel's category instead.
    func step(_ delta: Int) {
        guard let channel else { return }
        var source = list
        if source.count < 2 || !source.contains(channel) {
            source = library.channels(for: .group(channel.groupID))
        }
        guard source.count > 1, let i = source.firstIndex(of: channel) else { return }
        let next = source[(i + delta + source.count) % source.count]
        play(next, in: source)
    }

    /// Reloads the stream at the live edge (pausing or buffering a live channel leaves it behind).
    func goLive() {
        guard let channel, let url = library.streamURL(channel) else { return }
        isBehindLive = false
        status = .loading
        isPaused = false
        mpv.load(url)
        watchForStall(channel)
    }

    func togglePause() {
        guard status == .playing else { return }
        mpv.setPause(!isPaused)
    }

    func retry() {
        if let channel { play(channel, in: list) }
    }

    func close() {
        mpv.stop()
        epgTask?.cancel()
        timeoutTask?.cancel()
        mode = .hidden
        status = .idle
        channel = nil
    }

    /// Some provider channels accept the connection and never send a frame.
    private func watchForStall(_ channel: Channel) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, self.channel == channel, status == .loading else { return }
            mpv.stop()
            status = .failed("This channel isn't responding.")
        }
    }

    private func loadEPG(_ channel: Channel) {
        epgTask?.cancel()
        epgTask = Task { [weak self] in
            guard let self else { return }
            let list = await library.nowNext(channel)
            guard !Task.isCancelled, self.channel == channel else { return }
            programmes = list
        }
    }

    private func handle(_ e: MPV.Event) {
        switch e {
        case .loading: if status != .loading { status = .loading }
        case .playing: status = .playing; isBuffering = false
        case .buffering(let b):
            isBuffering = b
            if b && status == .playing { isBehindLive = true }
        case .paused(let p):
            isPaused = p
            if p && status == .playing { isBehindLive = true }
        case .failed(let msg):
            status = .failed(msg == "loading failed" ? "This channel isn't available right now." : msg.capitalizedFirst)
        case .ended:
            // Live streams shouldn't end; treat it as a drop and reconnect once.
            if status == .playing { retry() }
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

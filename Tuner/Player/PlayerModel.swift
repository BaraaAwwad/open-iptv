import AppKit
import Observation

@MainActor @Observable
final class PlayerModel {
    enum Status: Equatable { case idle, loading, playing, failed(String) }

    @ObservationIgnored let mpv = MPV()
    @ObservationIgnored lazy var videoView = MPVVideoView(mpv: mpv)
    @ObservationIgnored private let library: Library
    @ObservationIgnored private var epgTask: Task<Void, Never>?

    var isPresented = false
    private(set) var channel: Channel?
    private(set) var list: [Channel] = []
    private(set) var status: Status = .idle
    private(set) var isBuffering = false
    private(set) var isPaused = false
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
        isPresented = true
        guard let url = library.streamURL(channel) else {
            status = .failed("No stream address for this channel.")
            return
        }
        status = .loading
        isBuffering = false
        isPaused = false
        programmes = []
        mpv.load(url)
        library.markWatched(channel)
        loadEPG(channel)
    }

    func step(_ delta: Int) {
        guard let channel, let i = list.firstIndex(of: channel), !list.isEmpty else { return }
        let next = list[(i + delta + list.count) % list.count]
        play(next, in: list)
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
        isPresented = false
        status = .idle
        channel = nil
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
        case .buffering(let b): isBuffering = b
        case .paused(let p): isPaused = p
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

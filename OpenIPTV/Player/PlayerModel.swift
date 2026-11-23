import AppKit
import AVFoundation
import Observation

@MainActor @Observable
final class PlayerModel {
    enum Status: Equatable { case idle, loading, playing, failed(String) }

    @ObservationIgnored let mpv = MPV()
    @ObservationIgnored lazy var videoView = MPVVideoView(mpv: mpv)
    @ObservationIgnored private let library: Library
    @ObservationIgnored private var epgTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    /// Opening a stream waits a beat so flipping through channels doesn't open a connection per key press.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Automatic reconnects for the current channel (capped, so a flaky stream can't loop forever).
    @ObservationIgnored private var autoRetries = 0
    /// Called right before a stream is opened (the quality scanner steps aside).
    @ObservationIgnored var willOpenStream: () -> Void = {}

    // MARK: On-demand (movies / episodes)

    struct VODItem: Equatable {
        let key: String          // "m<id>" / "e<id>", for resume
        let title: String
        let subtitle: String?
        let artwork: String?
        let url: URL
        var seriesID: Int? = nil
        var start: Double? = nil
        /// What it is, so Continue Watching can show and resume it.
        var movie: Movie? = nil
        var episode: Episode? = nil
    }
    /// Set while a movie or episode plays (nil for live channels).
    private(set) var vod: VODItem?
    var isVOD: Bool { vod != nil }
    /// Saves the watch position (wired to VODStore).
    @ObservationIgnored var saveVODProgress: (VODItem, Double, Double) -> Void = { _, _, _ in }
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var measureTask: Task<Void, Never>?

    // AirPlay: the stream is repackaged to HLS and played through AVPlayer so a TV can take it.
    enum AirPlayState: Equatable { case off, preparing, ready, failed(String) }
    private(set) var airPlay: AirPlayState = .off
    /// True while a TV is actually showing the stream.
    private(set) var isOnTV = false
    @ObservationIgnored let airPlayer = AVPlayer()
    @ObservationIgnored private let streamer = AirPlayStreamer()
    @ObservationIgnored private var airPlayTask: Task<Void, Never>?
    @ObservationIgnored private var externalObservation: NSKeyValueObservation?

    /// hidden → nothing playing; mini → picture in picture in a corner; full → fills the window.
    enum Mode { case hidden, mini, full }
    var mode: Mode = .hidden
    /// Where PiP sits. Every new playback starts top-right; dragging moves it for that session.
    var pipCorner = "topTrailing"
    /// PiP width (resizable, remembered).
    var pipWidth: Double = UserDefaults.standard.object(forKey: "pipWidth") as? Double ?? 380 {
        didSet { UserDefaults.standard.set(pipWidth, forKey: "pipWidth") }
    }
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
        didSet {
            mpv.setVolume(volume)
            airPlayer.volume = Float(min(volume, 100) / 100)
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    var isMuted = false {
        didSet { mpv.setMute(isMuted); airPlayer.isMuted = isMuted }
    }

    init(library: Library) {
        self.library = library
        volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 100
        mpv.setVolume(volume)
        mpv.onEvent = { [weak self] e in self?.handle(e) }
        airPlayer.allowsExternalPlayback = true
        externalObservation = airPlayer.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
            let active = p.isExternalPlaybackActive
            DispatchQueue.main.async { self?.isOnTV = active }
        }
    }

    func playVOD(_ item: VODItem) {
        saveCurrentVOD()
        if airPlay != .off { stopAirPlay(resumeHere: false) }
        loadTask?.cancel()
        timeoutTask?.cancel()
        vod = item
        list = []
        channel = Channel(id: "vod:" + item.key, name: item.title, logo: item.artwork, groupID: "", streamID: nil, url: nil, epgID: nil)
        if mode == .hidden { mode = .mini }
        status = .loading
        isBuffering = false
        isPaused = false
        isBehindLive = false
        programmes = []
        autoRetries = 0
        PlayerLog.write("play vod \(item.key)")
        mpv.set("start", item.start.map { String(format: "%.0f", max(0, $0 - 3)) } ?? "none")
        open(item.url)
        watchForStall(channel!, seconds: 25)
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.saveCurrentVOD()
            }
        }
    }

    /// Current position and length of the movie / episode.
    func vodTime() -> (position: Double, duration: Double)? {
        guard isVOD, let d = mpv.double("duration"), d > 0 else { return nil }
        return (mpv.double("time-pos") ?? 0, d)
    }

    func seek(to seconds: Double) { if isVOD { mpv.seek(seconds, absolute: true) } }
    func skip(_ seconds: Double) { if isVOD { mpv.seek(seconds, absolute: false) } }

    private func saveCurrentVOD() {
        guard let vod, status == .playing, let t = vodTime() else { return }
        saveVODProgress(vod, t.position, t.duration)
    }

    /// Plays `channel`; `list` is what ↑/↓ step through.
    func play(_ channel: Channel, in list: [Channel]) {
        if vod != nil { saveCurrentVOD(); vod = nil; progressTask?.cancel(); mpv.set("start", "none") }
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
        autoRetries = 0
        timeoutTask?.cancel()
        loadTask?.cancel()
        PlayerLog.write("play \(channel.id)")
        loadTask = Task { [weak self] in
            // Settle first: holding ↓ through ten channels should open one stream, not ten.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, self.channel == channel else { return }
            library.markWatched(channel)
            loadEPG(channel)
            if airPlay != .off {
                startAirPlay(url) // already on AirPlay: switch the TV to the new channel
                return
            }
            open(url)
            watchForStall(channel)
        }
    }

    /// The stream's server as "host:port" — never the full address, which carries the password.
    func serverHost(_ c: Channel) -> String? {
        guard let u = library.streamURL(c), let host = u.host() else { return nil }
        return u.port.map { "\(host):\($0)" } ?? host
    }

    private func open(_ url: URL) {
        willOpenStream()
        mpv.load(url)
    }

    /// Records what the stream really delivers, a moment after it starts.
    private func measure(_ channel: Channel) {
        measureTask?.cancel()
        measureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.channel == channel, status == .playing, airPlay == .off else { return }
            let w = mpv.string("video-params/w").flatMap(Int.init) ?? 0
            let h = mpv.string("video-params/h").flatMap(Int.init) ?? 0
            let fps = mpv.double("container-fps") ?? mpv.double("estimated-vf-fps")
            library.recordQuality(channel, StreamQuality(width: w, height: h, fps: fps.map { ($0 * 100).rounded() / 100 },
                                                         codec: mpv.string("video-codec-name") ?? mpv.string("audio-codec-name"),
                                                         checked: Date(), ok: true))
        }
    }

    // MARK: AirPlay

    func toggleAirPlay() {
        if airPlay == .off {
            guard let channel, let url = vod?.url ?? library.streamURL(channel) else { return }
            startAirPlay(url)
        } else {
            stopAirPlay(resumeHere: true)
        }
    }

    private func startAirPlay(_ url: URL) {
        // The provider allows one connection, so the Mac's own player lets go first.
        willOpenStream()
        mpv.stop()
        timeoutTask?.cancel()
        airPlay = .preparing
        status = .loading
        airPlayTask?.cancel()
        airPlayTask = Task { [weak self] in
            guard let self else { return }
            do {
                let local = try await streamer.start(url)
                guard !Task.isCancelled else { return }
                airPlayer.replaceCurrentItem(with: AVPlayerItem(url: local))
                airPlayer.isMuted = isMuted
                airPlayer.volume = Float(min(volume, 100) / 100)
                airPlayer.play()
                airPlay = .ready
                status = .playing
            } catch {
                guard !Task.isCancelled else { return }
                airPlay = .failed(error.localizedDescription)
                status = .playing
            }
        }
    }

    func stopAirPlay(resumeHere: Bool) {
        airPlayTask?.cancel()
        airPlayer.pause()
        airPlayer.replaceCurrentItem(with: nil)
        streamer.stop()
        airPlay = .off
        isOnTV = false
        if resumeHere {
            if let vod { playVOD(vod) } else if let channel { play(channel, in: list) }
        }
    }

    /// Channel up / down. Steps through the list you played from; when that list is just this channel
    /// (a one-result search, say) it steps through the channel's category instead.
    func step(_ delta: Int) {
        guard let channel, vod == nil else { return }
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
        guard vod == nil, let channel, let url = library.streamURL(channel) else { return }
        if airPlay != .off { startAirPlay(url); isBehindLive = false; return }
        isBehindLive = false
        status = .loading
        isPaused = false
        open(url)
        watchForStall(channel)
    }

    func togglePause() {
        guard status == .playing else { return }
        if airPlay == .ready {
            if airPlayer.rate == 0 { airPlayer.play(); isPaused = false } else { airPlayer.pause(); isPaused = true; isBehindLive = true }
            return
        }
        mpv.setPause(!isPaused)
    }

    func retry() {
        if let vod {
            var again = vod
            again.start = vodTime()?.position ?? vod.start
            playVOD(again)
        } else if let channel { play(channel, in: list) }
    }

    func close() {
        saveCurrentVOD()
        progressTask?.cancel()
        vod = nil
        mpv.set("start", "none")
        loadTask?.cancel()
        if airPlay != .off { stopAirPlay(resumeHere: false) }
        PlayerLog.write("close")
        mpv.stop()
        epgTask?.cancel()
        timeoutTask?.cancel()
        mode = .hidden
        pipCorner = "topTrailing"
        status = .idle
        channel = nil
    }

    /// Some provider channels accept the connection and never send a frame.
    private func watchForStall(_ channel: Channel, seconds: Double = 12) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.channel == channel, status == .loading else { return }
            PlayerLog.write("no response after 12s, stopping \(channel.id)")
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
        case .playing:
            status = .playing
            isBuffering = false
            if let channel, vod == nil { measure(channel) }
        case .buffering(let b):
            isBuffering = b
            if b && status == .playing { isBehindLive = true }
        case .paused(let p):
            isPaused = p
            if p && status == .playing { isBehindLive = true }
        case .failed(let msg):
            PlayerLog.write("failed: \(msg) \(channel?.id ?? "")")
            // Right after switching, the provider often still counts the previous stream against the
            // one-connection limit and refuses. Give it a moment and try once more before giving up.
            if autoRetries == 0, let vod, airPlay == .off {
                autoRetries = 1
                status = .loading
                loadTask?.cancel()
                loadTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard let self, !Task.isCancelled, self.vod == vod else { return }
                    open(vod.url)
                    watchForStall(self.channel!, seconds: 25)
                }
                return
            }
            if autoRetries == 0, vod == nil, let channel, let url = library.streamURL(channel), airPlay == .off {
                autoRetries = 1
                status = .loading
                loadTask?.cancel()
                loadTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard let self, !Task.isCancelled, self.channel == channel else { return }
                    PlayerLog.write("retry after refusal \(channel.id)")
                    open(url)
                    watchForStall(channel)
                }
                return
            }
            status = .failed(msg == "loading failed" ? "This channel isn't available right now." : msg.capitalizedFirst)
        case .ended where vod != nil:
            // The movie / episode finished: mark it watched and close.
            if let vod, let d = mpv.double("duration") { saveVODProgress(vod, d, d) }
            close()
        case .ended:
            // Live streams shouldn't end. Reconnect, but at most twice: a provider that keeps cutting
            // the stream (e.g. over its connection limit) must not be hammered in a loop.
            guard status == .playing, let channel, let url = library.streamURL(channel) else { return }
            if autoRetries < 2 {
                autoRetries += 1
                PlayerLog.write("stream ended, reconnect \(autoRetries) \(channel.id)")
                status = .loading
                loadTask?.cancel()
                loadTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled, self.channel == channel else { return }
                    open(url)
                    watchForStall(channel)
                }
            } else {
                PlayerLog.write("stream ended again, giving up \(channel.id)")
                mpv.stop()
                status = .failed("This stream keeps dropping.")
            }
        }
    }
}

/// A small diagnostics log (~/Library/Logs/Open IPTV/player.log): channel switches, drops, retries.
/// Channel ids only: never stream addresses, which contain the account password.
enum PlayerLog {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Open IPTV")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("player.log")
    }()
    private static let queue = DispatchQueue(label: "openiptv.log")

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            h.write(Data("\(stamp) \(line)\n".utf8))
            try? h.close()
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

import SwiftUI

/// Everything mpv can tell about the stream that's playing, grouped for display.
struct StreamInfo {
    struct Row: Identifiable { let id = UUID(); let label: String; let value: String }
    struct Section: Identifiable { let id = UUID(); let title: String; let rows: [Row] }
    var sections: [Section]

    @MainActor
    static func read(_ player: PlayerModel) -> StreamInfo {
        let m = player.mpv
        func s(_ n: String) -> String? { m.string(n) }
        func d(_ n: String) -> Double? { m.double(n) }
        func rows(_ pairs: [(String, String?)]) -> [Row] { pairs.compactMap { l, v in v.map { Row(label: l, value: $0) } } }

        if player.airPlay != .off {
            return StreamInfo(sections: [Section(title: "AirPlay", rows: [
                Row(label: "Mode", value: player.isOnTV ? "Playing on TV" : "Waiting for a TV"),
                Row(label: "Path", value: "Repackaged to HLS (video copied, audio AAC)"),
            ])])
        }

        // Video
        let w = s("video-params/w"), h = s("video-params/h")
        let dw = s("video-params/dw"), dh = s("video-params/dh")
        let resolution = (w != nil && h != nil) ? "\(w!) × \(h!) · \(QualityTier.from(width: Int(w!) ?? 0, height: Int(h!) ?? 0).rawValue)" : nil
        // With hardware decoding mpv reports "videotoolbox" as the format; the real one is the hw format.
        let rawFormat = s("video-params/pixelformat"), hwFormat = s("video-params/hw-pixelformat")
        let pixelFormat = rawFormat == "videotoolbox" ? hwFormat : rawFormat
        let display = (dw != nil && dh != nil && (dw != w || dh != h)) ? "\(dw!) × \(dh!)" : nil
        let rendered = (s("osd-dimensions/w")).flatMap { ow in s("osd-dimensions/h").map { "\(ow) × \($0) (window)" } }
        let fpsNominal = d("container-fps").map { String(format: "%.3g fps", $0) }
        let fpsMeasured = d("estimated-vf-fps").map { String(format: "%.2f fps", $0) }
        let primaries = s("video-params/primaries"), gamma = s("video-params/gamma")
        let hdr = gamma.map { ["pq", "hlg"].contains($0) ? "Yes (\($0.uppercased()))" : "No (SDR)" }
        let hw = s("hwdec-current").map { $0 == "no" ? "Off (software)" : "On (\($0))" }

        let video = rows([
            ("Resolution", resolution),
            ("Display size", display),
            ("Shown at", rendered),
            ("Codec", s("video-codec")),
            ("Profile", s("current-tracks/video/codec-profile")),
            ("Frame rate", fpsNominal),
            ("Measured rate", fpsMeasured),
            ("Bitrate", d("video-bitrate").map(Self.bitrate)),
            ("Aspect", d("video-params/aspect").map { String(format: "%.3f", $0) }),
            ("Pixel format", pixelFormat),
            ("Color matrix", s("video-params/colormatrix")),
            ("Color range", s("video-params/colorlevels")),
            ("Primaries", primaries),
            ("Transfer", gamma),
            ("HDR", hdr),
            ("Hardware decoding", hw),
            ("Interlaced", s("video-params/interlaced").map { $0 == "yes" ? "Yes" : "No" }),
            ("Rotation", s("video-params/rotate").flatMap { $0 == "0" ? nil : "\($0)°" }),
        ])

        // Audio
        let channels = s("audio-params/channel-count").map { c -> String in
            let layout = s("audio-params/hr-channels") ?? s("audio-params/channels") ?? ""
            return layout.isEmpty ? "\(c)" : "\(c) (\(layout))"
        }
        let audio = rows([
            ("Codec", s("audio-codec")),
            ("Sample rate", d("audio-params/samplerate").map { String(format: "%.1f kHz", $0 / 1000) }),
            ("Channels", channels),
            ("Sample format", s("audio-params/format")),
            ("Bitrate", d("audio-bitrate").map(Self.bitrate)),
            ("Language", s("current-tracks/audio/lang")),
            ("Audio tracks", s("track-list/count").flatMap { _ in Self.count(m, type: "audio") }),
            ("Output", s("current-ao")),
        ])

        // Stream / network / playback health
        let host = player.channel.flatMap { player.serverHost($0) }
        let cacheAhead = d("demuxer-cache-duration").map { String(format: "%.1f s", $0) }
        let speed = d("cache-speed").map { Self.speed($0) }
        let dropped = [s("frame-drop-count").map { "\($0) output" }, s("decoder-frame-drop-count").map { "\($0) decoder" }]
            .compactMap { $0 }.joined(separator: ", ")
        let stream = rows([
            ("Container", s("file-format")),
            ("Server", host),
            ("Download speed", speed),
            ("Buffered ahead", cacheAhead),
            ("Buffer size", d("demuxer-cache-state/fw-bytes").map { Self.bytes($0) }),
            ("Live", player.isBehindLive ? "Behind live (press Go Live)" : "At live edge"),
            ("Dropped frames", dropped.isEmpty ? nil : dropped),
            ("A/V sync", d("avsync").map { String(format: "%+.0f ms", $0 * 1000) }),
            ("Display refresh", d("display-fps").map { String(format: "%.0f Hz", $0) }),
            ("Video output", s("current-vo")),
            ("Subtitle tracks", Self.count(m, type: "sub")),
            ("Player", s("mpv-version")),
        ])

        return StreamInfo(sections: [
            Section(title: "Video", rows: video),
            Section(title: "Audio", rows: audio),
            Section(title: "Stream", rows: stream),
        ].filter { !$0.rows.isEmpty })
    }

    private static func label(height: Int) -> String {
        switch height {
        case 2000...: " · 4K"
        case 1400..<2000: " · 1440p"
        case 1000..<1400: " · 1080p"
        case 700..<1000: " · 720p"
        case 1..<700: " · SD"
        default: ""
        }
    }

    private static func count(_ m: MPV, type: String) -> String? {
        guard let n = m.string("track-list/count").flatMap(Int.init) else { return nil }
        let c = (0..<n).filter { m.string("track-list/\($0)/type") == type }.count
        return c > 0 ? "\(c)" : nil
    }

    static func bitrate(_ bps: Double) -> String {
        bps >= 1_000_000 ? String(format: "%.2f Mbps", bps / 1_000_000) : String(format: "%.0f kbps", bps / 1000)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        let bits = bytesPerSecond * 8
        return bits >= 1_000_000 ? String(format: "%.1f Mbps", bits / 1_000_000) : String(format: "%.0f kbps", bits / 1000)
    }

    static func bytes(_ b: Double) -> String {
        b >= 1_048_576 ? String(format: "%.1f MB", b / 1_048_576) : String(format: "%.0f KB", b / 1024)
    }
}

/// Glass panel listing the stream details, refreshed every second while open.
struct StreamInfoPanel: View {
    @Environment(PlayerModel.self) private var player
    @Binding var isShown: Bool
    @State private var info = StreamInfo(sections: [])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Stream Info").font(.headline)
                Spacer()
                Button { isShown = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (I)")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(info.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white.opacity(0.5))
                            ForEach(section.rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(row.label)
                                        .foregroundStyle(.white.opacity(0.65))
                                        .frame(width: 118, alignment: .leading)
                                    Text(row.value)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 12))
                                .monospacedDigit()
                            }
                        }
                    }
                    if info.sections.isEmpty {
                        Text("Waiting for the stream…").font(.callout).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 330)
        .frame(maxHeight: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)) }
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
        .task {
            while !Task.isCancelled {
                info = StreamInfo.read(player)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

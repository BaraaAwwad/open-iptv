import Foundation
import Observation

/// What a stream actually delivered, measured by playing it or by a scan. Never guessed from names.
struct StreamQuality: Codable, Hashable {
    var width: Int
    var height: Int
    var fps: Double?
    var codec: String?
    var checked: Date
    /// false = the provider didn't deliver anything (dead / refusing channel).
    var ok: Bool

    var tier: QualityTier {
        guard ok else { return .noSignal }
        guard height > 0 else { return .audio }
        return QualityTier.from(width: width, height: height)
    }

    /// "1920×1080 · 50 fps · h264"
    var summary: String {
        guard ok else { return "No signal" }
        var parts: [String] = []
        if height > 0 { parts.append("\(width)×\(height)") } else { parts.append("Audio only") }
        if let fps, fps > 0 { parts.append(String(format: fps.rounded() == fps ? "%.0f fps" : "%.2f fps", fps)) }
        if let codec { parts.append(codec) }
        return parts.joined(separator: " · ")
    }
}

enum QualityTier: String, CaseIterable, Identifiable {
    /// Width counts too: a wide-screen film is 3840×1608, which is 4K, not "1440p".
    static func from(width: Int, height: Int) -> QualityTier {
        if width >= 3200 || height >= 2000 { return .uhd }
        if width >= 1800 || height >= 1000 { return .fhd }
        if width >= 1200 || height >= 700 { return .hd }
        return .sd
    }

    case uhd = "4K", fhd = "1080p", hd = "720p", sd = "SD", audio = "Audio only", noSignal = "No signal", unchecked = "Not checked"
    var id: String { rawValue }
    /// Short label for tile badges (nil = no badge).
    var badge: String? {
        switch self {
        case .uhd: "4K"
        case .fhd: "1080p"
        case .hd: "720p"
        case .sd: "SD"
        case .audio: "Audio"
        case .noSignal: "No signal"
        case .unchecked: nil
        }
    }
}

/// Checks a list of channels one at a time with ffprobe, slowly, and only while nothing is playing,
/// so it never competes for the provider's single connection or looks like a flood.
@MainActor @Observable
final class QualityScanner {
    private(set) var isRunning = false
    private(set) var title = ""
    private(set) var done = 0
    private(set) var total = 0
    private(set) var waitingForPlayer = false

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let isPlayerBusy: () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var probe: Process?
    @ObservationIgnored private var yielded = false

    init(library: Library, isPlayerBusy: @escaping () -> Bool) {
        self.library = library
        self.isPlayerBusy = isPlayerBusy
    }

    nonisolated static var ffprobe: String? {
        ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first(where: FileManager.default.isExecutableFile)
    }

    /// Channels checked within the last week are skipped.
    func scan(_ channels: [Channel], title: String) {
        cancel()
        let fresh = Date().addingTimeInterval(-7 * 24 * 3600)
        let todo = channels.filter { (library.quality($0)?.checked ?? .distantPast) < fresh }
        guard !todo.isEmpty, Self.ffprobe != nil else { return }
        self.title = title
        total = todo.count
        done = 0
        isRunning = true
        PlayerLog.write("scan start \(todo.count) channels")
        task = Task { [weak self] in
            for channel in todo {
                guard let self, !Task.isCancelled else { return }
                // Never share the connection with the player.
                while isPlayerBusy() && !Task.isCancelled {
                    waitingForPlayer = true
                    try? await Task.sleep(for: .seconds(1))
                }
                waitingForPlayer = false
                guard !Task.isCancelled, let url = library.streamURL(channel) else { continue }
                let result = await measure(url)
                guard !Task.isCancelled else { return }
                // A probe the player interrupted tells us nothing; try that channel again later.
                if let result { library.recordQuality(channel, result) }
                done += 1
                // Pace it: one channel every few seconds at most.
                try? await Task.sleep(for: .seconds(1.5))
            }
            self?.finish()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        probe?.terminate()
        probe = nil
        if isRunning { PlayerLog.write("scan stopped") }
        isRunning = false
        waitingForPlayer = false
    }

    /// The player is about to open a stream: drop the probe so it gets the connection.
    func yieldToPlayer() {
        guard let probe else { return }
        yielded = true
        probe.terminate()
    }

    private func finish() {
        PlayerLog.write("scan finished \(done)/\(total)")
        isRunning = false
        task = nil
    }

    /// Runs ffprobe with hard time limits. nil = interrupted (don't record anything).
    private func measure(_ url: URL) async -> StreamQuality? {
        guard let ffprobe = Self.ffprobe else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = [
            "-v", "error", "-user_agent", "VLC/3.0.21 LibVLC/3.0.21",
            "-rw_timeout", "8000000", "-analyzeduration", "2500000", "-probesize", "3000000",
            "-show_entries", "stream=codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate",
            "-of", "json", url.absoluteString,
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        probe = p
        yielded = false
        let started = Date()
        while p.isRunning {
            if Date().timeIntervalSince(started) > 12 { p.terminate(); break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let interrupted = probe == nil || yielded || Task.isCancelled
        probe = nil
        if interrupted { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let streams = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["streams"] as? [[String: Any]] ?? []
        if streams.isEmpty {
            return StreamQuality(width: 0, height: 0, fps: nil, codec: nil, checked: Date(), ok: false)
        }
        let video = streams.first { $0["codec_type"] as? String == "video" && ($0["height"] as? Int ?? 0) > 0 }
        func rate(_ s: Any?) -> Double? {
            guard let s = s as? String else { return nil }
            let parts = s.split(separator: "/").compactMap { Double($0) }
            guard parts.count == 2, parts[1] > 0 else { return nil }
            let v = parts[0] / parts[1]
            return v > 0 && v < 300 ? (v * 100).rounded() / 100 : nil
        }
        return StreamQuality(
            width: video?["width"] as? Int ?? 0,
            height: video?["height"] as? Int ?? 0,
            fps: rate(video?["avg_frame_rate"]) ?? rate(video?["r_frame_rate"]),
            codec: video?["codec_name"] as? String ?? streams.first?["codec_name"] as? String,
            checked: Date(),
            ok: true
        )
    }
}

/// One-off ffprobe of a stream (8–12 s at most). Used for movies / episodes the provider didn't describe.
enum StreamProbe {
    static func measure(_ url: URL) async -> StreamQuality? {
        guard let ffprobe = QualityScanner.ffprobe else { return nil }
        return await Task.detached { () -> StreamQuality? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffprobe)
            p.arguments = ["-v", "error", "-user_agent", "VLC/3.0.21 LibVLC/3.0.21",
                           "-rw_timeout", "8000000", "-analyzeduration", "2500000", "-probesize", "3000000",
                           "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height,avg_frame_rate",
                           "-of", "json", url.absoluteString]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(12)
            while p.isRunning && Date() < deadline { usleep(200_000) }
            if p.isRunning { p.terminate(); return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard let v = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["streams"] as? [[String: Any]])?.first,
                  let w = v["width"] as? Int, let h = v["height"] as? Int else { return nil }
            return StreamQuality(width: w, height: h, fps: nil, codec: v["codec_name"] as? String, checked: Date(), ok: true)
        }.value
    }
}

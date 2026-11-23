import AVFoundation
import AVKit
import Network
import SwiftUI

/// AirPlay for IPTV streams. Apple TVs can't play raw MPEG-TS, so ffmpeg repackages the stream into HLS
/// (video copied as-is, audio to AAC) and a tiny HTTP server shares it on the local network.
final class AirPlayStreamer {
    enum Failure: LocalizedError {
        case noFFmpeg, noNetwork, timeout
        var errorDescription: String? {
            switch self {
            case .noFFmpeg: "AirPlay needs ffmpeg. Install it with: brew install ffmpeg"
            case .noNetwork: "Connect this Mac to Wi-Fi or Ethernet to use AirPlay."
            case .timeout: "The channel didn't start in time. Try again or pick another channel."
            }
        }
    }

    private var process: Process?
    private var server: FileServer?
    private var dir: URL?

    /// Starts repackaging `source` and returns the HLS address a TV can open.
    func start(_ source: URL) async throws -> URL {
        // One connection at a time: make sure the previous ffmpeg has really exited first.
        let previous = process
        stop()
        if let previous {
            for _ in 0..<20 where previous.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            if previous.isRunning { kill(previous.processIdentifier, SIGKILL) }
        }
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile)
        else { throw Failure.noFFmpeg }
        guard let ip = Self.lanAddress() else { throw Failure.noNetwork }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openiptv-airplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-user_agent", "VLC/3.0.21 LibVLC/3.0.21",
            "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "4",
            "-i", source.absoluteString,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "160k", "-ac", "2",
            "-f", "hls", "-hls_time", "2", "-hls_list_size", "8",
            "-hls_flags", "delete_segments+independent_segments+omit_endlist",
            "-hls_segment_type", "fmp4",
            dir.appendingPathComponent("live.m3u8").path,
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p

        let server = FileServer(root: dir)
        let port = try await server.start()
        self.server = server

        // Wait until a couple of segments exist so the TV starts smoothly.
        let playlist = dir.appendingPathComponent("live.m3u8")
        for _ in 0..<60 {
            if let text = try? String(contentsOf: playlist, encoding: .utf8),
               text.components(separatedBy: "#EXTINF").count > 2 {
                return URL(string: "http://\(ip):\(port)/live.m3u8")!
            }
            if !p.isRunning { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        stop()
        throw Failure.timeout
    }

    func stop() {
        process?.interrupt() // ffmpeg closes its input cleanly on SIGINT
        process = nil
        server?.stop()
        server = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
    }

    /// This Mac's IPv4 address on the local network (Wi-Fi or Ethernet).
    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(String, String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            candidates.append((String(cString: ifa.ifa_name), String(cString: host)))
        }
        return (candidates.first { $0.0 == "en0" } ?? candidates.first { $0.0.hasPrefix("en") } ?? candidates.first)?.1
    }
}

/// Minimal HTTP/1.1 file server for the HLS folder.
final class FileServer {
    private let root: URL
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "openiptv.airplay.http")

    init(root: URL) { self.root = root }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [root] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            // Only plain file names inside the folder.
            let name = (path.split(separator: "?").first.map(String.init) ?? path).split(separator: "/").last.map(String.init) ?? ""
            let file = root.appendingPathComponent(name)
            var head: String
            var body = Data()
            if !name.isEmpty, !name.hasPrefix("."), let d = try? Data(contentsOf: file) {
                body = d
                let type = name.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl"
                    : name.hasSuffix(".m4s") ? "video/iso.segment" : "video/mp4"
                head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(d.count)\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            } else {
                head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

/// The system AirPlay device picker, bound to the AirPlay player.
struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer
    var openOnAppear = false

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.player = player
        v.isRoutePickerButtonBordered = false
        v.setRoutePickerButtonColor(.white, for: .normal)
        v.setRoutePickerButtonColor(.systemBlue, for: .active)
        if openOnAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                (v.subviews.first { $0 is NSButton } as? NSButton)?.performClick(nil)
            }
        }
        return v
    }

    func updateNSView(_ v: AVRoutePickerView, context: Context) { v.player = player }
}

/// AVPlayer video for the AirPlay path (shows the picture locally until a TV takes over).
struct AirPlayVideo: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

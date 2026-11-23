import AppKit
import ImageIO

/// Channel logos: memory + disk cache, downsampled, one request per URL, failures remembered.
actor ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, NSImage>()
    private var failed = Set<String>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tuner/logos")
        c.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 400 << 20, directory: dir)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.timeoutIntervalForRequest = 10
        c.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: c)
    }()

    init() { memory.countLimit = 1500 }

    func image(_ string: String) async -> NSImage? {
        if let img = memory.object(forKey: string as NSString) { return img }
        if failed.contains(string) { return nil }
        if let task = inflight[string] { return await task.value }
        let session = session
        let task = Task<NSImage?, Never> {
            guard let url = URL(string: string), let (data, resp) = try? await session.data(from: url),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            return Self.downsample(data, maxPixels: 320)
        }
        inflight[string] = task
        let img = await task.value
        inflight[string] = nil
        if let img { memory.setObject(img, forKey: string as NSString) } else { failed.insert(string) }
        return img
    }

    private static func downsample(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

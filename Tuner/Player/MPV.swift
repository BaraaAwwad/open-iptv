import AppKit
import OpenGL.GL3

/// Thin wrapper over libmpv. All video goes through `MPVVideoLayer`; mpv itself draws nothing on top.
final class MPV {
    enum Event {
        case loading
        case playing
        case buffering(Bool)
        case paused(Bool)
        case failed(String)
        case ended
    }

    let handle: OpaquePointer
    var onEvent: ((Event) -> Void)?
    private let queue = DispatchQueue(label: "tuner.mpv.events")

    init() {
        handle = mpv_create()
        let options: [(String, String)] = [
            ("vo", "libmpv"),
            ("hwdec", "videotoolbox"),
            ("terminal", "no"),
            ("osd-level", "0"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("ytdl", "no"),
            ("keep-open", "no"),
            ("idle", "yes"),
            ("audio-client-name", "Tuner"),
            // Live TV: start fast, ride out short network hiccups.
            ("cache", "yes"),
            ("cache-pause-initial", "no"),
            ("demuxer-max-bytes", "64MiB"),
            ("demuxer-readahead-secs", "20"),
            ("network-timeout", "15"),
            ("demuxer-lavf-probesize", "1000000"),
            ("demuxer-lavf-analyzeduration", "1.5"),
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=4"),
            ("user-agent", "VLC/3.0.21 LibVLC/3.0.21"),
            ("volume-max", "130"),
        ]
        for (k, v) in options { mpv_set_option_string(handle, k, v) }
        mpv_initialize(handle)

        mpv_observe_property(handle, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(handle, { ctx in
            let me = Unmanaged<MPV>.fromOpaque(ctx!).takeUnretainedValue()
            me.queue.async { me.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Commands

    func load(_ url: URL) { command("loadfile", url.absoluteString, "replace") }
    func stop() { command("stop") }

    func set(_ name: String, _ value: String) { mpv_set_property_string(handle, name, value) }
    func setPause(_ p: Bool) { set("pause", p ? "yes" : "no") }
    func setVolume(_ v: Double) { set("volume", String(Int(v))) }
    func setMute(_ m: Bool) { set("mute", m ? "yes" : "no") }

    private func command(_ args: String...) {
        var cargs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cargs.append(nil)
        mpv_command_async(handle, 0, &cargs)
        for p in cargs { free(UnsafeMutablePointer(mutating: p)) }
    }

    // MARK: Events

    private func drainEvents() {
        while true {
            guard let ev = mpv_wait_event(handle, 0) else { return }
            let e = ev.pointee
            switch e.event_id {
            case MPV_EVENT_NONE:
                return
            case MPV_EVENT_START_FILE:
                emit(.loading)
            case MPV_EVENT_PLAYBACK_RESTART:
                emit(.playing)
            case MPV_EVENT_END_FILE:
                if let data = e.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    if data.reason == MPV_END_FILE_REASON_ERROR {
                        emit(.failed(String(cString: mpv_error_string(data.error))))
                    } else if data.reason == MPV_END_FILE_REASON_EOF {
                        emit(.ended)
                    }
                }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let p = e.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                      p.format == MPV_FORMAT_FLAG, let raw = p.data else { continue }
                let flag = raw.assumingMemoryBound(to: Int32.self).pointee != 0
                switch String(cString: p.name) {
                case "paused-for-cache": emit(.buffering(flag))
                case "pause": emit(.paused(flag))
                default: break
                }
            default:
                break
            }
        }
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }
}

/// OpenGL layer that mpv renders frames into (the libmpv render API).
final class MPVVideoLayer: CAOpenGLLayer {
    private let mpv: MPV
    private var renderContext: OpaquePointer?
    private let renderQueue = DispatchQueue(label: "tuner.mpv.render", qos: .userInteractive)
    private var cglContext: CGLContextObj?

    init(mpv: MPV) {
        self.mpv = mpv
        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
    }

    override init(layer: Any) {
        let other = layer as! MPVVideoLayer
        mpv = other.mpv
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var pix: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attrs, &pix, &count)
        return pix ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        let ctx = super.copyCGLContext(forPixelFormat: pf)
        var swapInterval: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swapInterval)
        cglContext = ctx
        if renderContext == nil { createRenderContext(ctx) }
        return ctx
    }

    private func createRenderContext(_ ctx: CGLContextObj) {
        CGLSetCurrentContext(ctx)
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
                let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                return CFBundleGetFunctionPointerForName(bundle, symbol)
            },
            get_proc_address_ctx: nil)
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }
        withUnsafeMutablePointer(to: &initParams) { initPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initPtr),
                mpv_render_param(),
            ]
            var rc: OpaquePointer?
            if mpv_render_context_create(&rc, mpv.handle, &params) >= 0 { renderContext = rc }
        }
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, { ctx in
            let layer = Unmanaged<MPVVideoLayer>.fromOpaque(ctx!).takeUnretainedValue()
            layer.renderQueue.async { layer.renderFrame() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func renderFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display()
        CATransaction.commit()
        CATransaction.flush()
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool { true }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }
        guard let renderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            return
        }
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        var target = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(viewport[2]), h: Int32(viewport[3]), internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &target) { t in
            withUnsafeMutablePointer(to: &flip) { f in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: t),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: f),
                    mpv_render_param(),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
        glFlush()
    }
}

/// The NSView hosting the video layer. Mouse events pass through to SwiftUI.
final class MPVVideoView: NSView {
    init(mpv: MPV) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = MPVVideoLayer(mpv: mpv)
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

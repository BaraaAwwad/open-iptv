import AppKit
import SwiftUI

/// Picture in picture is a real (child) window: AppKit does the resizing (edges, corners, cursor,
/// 16:9 lock) and moving, like any window. This view is just what's inside it.
struct MiniPlayer: View {
    @Environment(PlayerModel.self) private var player
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black
            PlayerVideo(active: player.mode == .mini)
            // Drag anywhere to move the window (system window drag); double-click to expand.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { player.mode = .full }

            if player.airPlay != .off {
                AirPlayCard(compact: true)
            } else {
                statusOverlay
            }

            if hovering {
                controls.transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            // Thin progress line for movies / episodes.
            if player.isVOD { Scrubber(compact: true).padding(.horizontal, 10).padding(.bottom, 6) }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.18), value: hovering)
    }

    @ViewBuilder private var statusOverlay: some View {
        switch player.status {
        case .loading:
            ProgressView().tint(.white)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "tv.slash").font(.title2.weight(.light))
                Text(message).font(.caption).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    small("Try Again") { player.retry() }
                    small("Next") { player.step(1) }
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding()
        default:
            if player.isBuffering { ProgressView().tint(.white) }
        }
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack {
                HStack {
                    circle("xmark", 28, help: "Stop and close") { player.close() }
                    Spacer()
                    circle("airplayvideo", 28, help: player.airPlay == .off ? "AirPlay to a TV" : "Stop AirPlay") { player.toggleAirPlay() }
                    circle("arrow.up.left.and.arrow.down.right", 28, help: "Expand (double-click)") { player.mode = .full }
                }
                Spacer()
                HStack(alignment: .center) {
                    Text(player.channel?.displayName ?? "")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    if !player.isVOD {
                        LivePill(compact: true) { player.goLive() }
                        if let channel = player.channel { AddToPlaylistButton(channel: channel, size: 28) }
                    }
                    circle(player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", 28, help: "Mute") {
                        player.isMuted.toggle()
                    }
                }
            }
            .padding(10)
            if player.status == .playing {
                HStack(spacing: 16) {
                    if player.isVOD {
                        circle("gobackward.10", 34, help: "Back 10 seconds") { player.skip(-10) }
                    } else {
                        ChannelButton(up: true, size: 34) { player.step(-1) }
                    }
                    circle(player.isPaused ? "play.fill" : "pause.fill", 46, help: "Pause") { player.togglePause() }
                    if player.isVOD {
                        circle("goforward.10", 34, help: "Forward 10 seconds") { player.skip(10) }
                    } else {
                        ChannelButton(up: false, size: 34) { player.step(1) }
                    }
                }
            }
        }
    }

    private func circle(_ symbol: String, _ size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassCircle()
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .help(help)
    }

    private func small(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassCapsule()
        }
        .buttonStyle(PressScale())
    }
}

/// The PiP window: a borderless-looking, resizable child window of the main window.
@MainActor
final class PiPWindowController {
    private var panel: NSPanel?
    private weak var parent: NSWindow?
    private var exitObserver: NSObjectProtocol?
    /// What goes inside (set by RootView, which has the app's shared models).
    var makeContent: () -> AnyView

    init(content: @escaping () -> AnyView) { self.makeContent = content }

    func attach(_ window: NSWindow) {
        guard window !== parent else { return }
        parent = window
        if let o = exitObserver { NotificationCenter.default.removeObserver(o) }
        // Coming out of full screen: show PiP once the window is back.
        exitObserver = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                              object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pendingShow?() }
        }
    }

    private var pendingShow: (() -> Void)?

    func show() {
        guard let parent else { return }
        if parent.styleMask.contains(.fullScreen) {
            pendingShow = { [weak self] in self?.pendingShow = nil; self?.show() }
            return
        }
        let panel = self.panel ?? makePanel()
        // Never bigger than 60% of the app window.
        let lim = limits
        panel.contentMaxSize = NSSize(width: lim.max, height: lim.max * 9 / 16)
        if panel.frame.width > lim.max {
            panel.setFrame(NSRect(x: panel.frame.maxX - lim.max, y: panel.frame.maxY - lim.max * 9 / 16,
                                  width: lim.max, height: lim.max * 9 / 16), display: true)
        }
        if panel.parent == nil {
            if !panel.isVisible { place(panel, in: parent) }
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        pendingShow = nil
        guard let panel else { return }
        UserDefaults.standard.set(Double(panel.frame.width), forKey: "pipWidth")
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        // Remembered size, kept inside the limits.
        let width = min(max(UserDefaults.standard.object(forKey: "pipWidth") as? Double ?? 420, Self.minWidth), Self.maxWidthCap)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: width * 9 / 16),
                            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.contentMinSize = NSSize(width: Self.minWidth, height: Self.minWidth * 9 / 16)
        panel.contentMaxSize = NSSize(width: Self.maxWidthCap, height: Self.maxWidthCap * 9 / 16)
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .black
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        // The SwiftUI content, with plain AppKit corner handles on top (siblings, not inside SwiftUI):
        // the window's own edges resize natively; the corners get the diagonal cursor and resize too.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        let host = NSHostingView(rootView: makeContent())
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        for corner in CornerHandle.Corner.allCases {
            let handle = CornerHandle(corner: corner, limits: { [weak self] in self?.limits ?? (Self.minWidth, Self.maxWidthCap) })
            container.addSubview(handle)
        }
        panel.contentView = container
        host.frame = container.bounds
        self.panel = panel
        return panel
    }

    static let minWidth: CGFloat = 384
    static let maxWidthCap: CGFloat = 960

    /// Min / max width right now (max follows the app window: 60% of it, at most 960).
    var limits: (min: CGFloat, max: CGFloat) {
        let byWindow = (parent?.frame.width ?? 1600) * 0.6
        return (Self.minWidth, max(Self.minWidth, min(Self.maxWidthCap, byWindow)))
    }

    /// First time: top-right of the main window, below the toolbar.
    private func place(_ panel: NSPanel, in parent: NSWindow) {
        let content = parent.contentLayoutRect
        let origin = parent.convertPoint(toScreen: NSPoint(x: content.maxX - panel.frame.width - 20,
                                                           y: content.maxY - panel.frame.height - 12))
        panel.setFrameOrigin(origin)
    }
}

/// A corner of the PiP window: diagonal resize cursor, and dragging resizes from that corner
/// (16:9, opposite corner stays put, within the limits).
final class CornerHandle: NSView {
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    private let corner: Corner
    private let limits: () -> (min: CGFloat, max: CGFloat)
    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero
    private static let size: CGFloat = 14

    init(corner: Corner, limits: @escaping () -> (min: CGFloat, max: CGFloat)) {
        self.corner = corner
        self.limits = limits
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var isLeft: Bool { corner == .topLeft || corner == .bottomLeft }
    private var isTop: Bool { corner == .topLeft || corner == .topRight }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let b = superview?.bounds else { return }
        // AppKit coordinates: y grows upward.
        setFrameOrigin(NSPoint(x: isLeft ? 0 : b.width - Self.size, y: isTop ? b.height - Self.size : 0))
        autoresizingMask = [isLeft ? .maxXMargin : .minXMargin, isTop ? .minYMargin : .maxYMargin]
    }

    override func resetCursorRects() {
        let pos: NSCursor.FrameResizePosition = isTop ? (isLeft ? .topLeft : .topRight) : (isLeft ? .bottomLeft : .bottomRight)
        addCursorRect(bounds, cursor: .frameResize(position: pos, directions: .all))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let dx = (now.x - startMouse.x) * (isLeft ? -1 : 1)
        let dy = (now.y - startMouse.y) * (isTop ? 1 : -1)
        let lim = limits()
        let width = min(max(startFrame.width + max(dx, dy * 16 / 9), lim.min), lim.max)
        let height = width * 9 / 16
        // The opposite corner stays where it was.
        let x = isLeft ? startFrame.maxX - width : startFrame.minX
        let y = isTop ? startFrame.minY : startFrame.maxY - height
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

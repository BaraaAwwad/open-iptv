import SwiftUI

/// Picture in picture: a small floating player in a corner of the window.
/// Drag it to any corner, hover for controls, double-click or ⤢ to expand, ✕ to stop.
struct MiniPlayer: View {
    @Environment(PlayerModel.self) private var player
    @State private var drag: CGSize = .zero
    @State private var hovering = false
    /// Width at the start of a resize drag.
    @State private var resizeStart: Double?
    @State private var available: CGSize = .zero

    private var width: CGFloat { CGFloat(player.pipWidth) }
    private var maxWidth: CGFloat { max(260, min(960, (available.width - 2 * margin) * 0.75)) }
    private let margin: CGFloat = 20
    private let topInset: CGFloat = 60 // clear the toolbar

    enum Corner: String { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private var corner: Corner { Corner(rawValue: player.pipCorner) ?? .topTrailing }

    private var alignment: Alignment {
        switch corner {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    var body: some View {
        GeometryReader { geo in
            card
                .offset(drag)
                .gesture(
                    DragGesture(minimumDistance: 10) // a click with a tiny wobble is not a drag
                        .onChanged { drag = $0.translation }
                        .onEnded { value in snap(value, in: geo.size) }
                )
                .padding(.top, topInset)
                .padding([.horizontal, .bottom], margin)
                .frame(width: geo.size.width, height: geo.size.height, alignment: alignment)
                .onAppear { available = geo.size }
                .onChange(of: geo.size) { _, size in
                    available = size
                    if width > maxWidth { player.pipWidth = Double(maxWidth) }
                }
        }
    }

    // MARK: Resizing, like a window: drag the inner edges or corner with the system resize cursor.

    private var dockedLeading: Bool { corner == .topLeading || corner == .bottomLeading }
    private var dockedTop: Bool { corner == .topLeading || corner == .topTrailing }

    /// Invisible edge strips and a corner square on the sides facing into the window.
    private var resizeZones: some View {
        let edge: CGFloat = 7, cornerSize: CGFloat = 16
        let side: HorizontalEdge = dockedLeading ? .trailing : .leading
        let vertical: VerticalEdge = dockedTop ? .bottom : .top
        return ZStack {
            // Inward vertical edge.
            Color.clear
                .frame(width: edge)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == .leading ? .leading : .trailing)
                .resizeHandle(position: side == .leading ? .leading : .trailing, axis: .horizontal, resize: resize)
            // Inward horizontal edge.
            Color.clear
                .frame(height: edge)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: vertical == .top ? .top : .bottom)
                .resizeHandle(position: vertical == .top ? .top : .bottom, axis: .vertical, resize: resize)
            // Inward corner.
            Color.clear
                .frame(width: cornerSize, height: cornerSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: Alignment(horizontal: side == .leading ? .leading : .trailing,
                                            vertical: vertical == .top ? .top : .bottom))
                .resizeHandle(position: cornerPosition, axis: [.horizontal, .vertical], resize: resize)
        }
    }

    private var cornerPosition: FrameResizePosition {
        switch (dockedTop, dockedLeading) {
        case (true, false): .bottomLeading
        case (true, true): .bottomTrailing
        case (false, false): .topLeading
        case (false, true): .topTrailing
        }
    }

    /// Dragging away from the docked corner grows it; the picture stays 16:9.
    private func resize(_ translation: CGSize, _ axis: Axis.Set, _ ended: Bool) {
        if ended { resizeStart = nil; return }
        let start = resizeStart ?? player.pipWidth
        resizeStart = start
        let dx = dockedLeading ? translation.width : -translation.width
        let dy = (dockedTop ? translation.height : -translation.height) * 16 / 9
        let grow = axis == .horizontal ? dx : axis == .vertical ? dy : max(dx, dy)
        player.pipWidth = Double(min(max(start + grow, 260), Double(maxWidth)))
    }

    private func snap(_ value: DragGesture.Value, in size: CGSize) {
        // Where the card's center ended up decides the corner.
        let h = width * 9 / 16
        let startX = corner == .topLeading || corner == .bottomLeading ? margin + width / 2 : size.width - margin - width / 2
        let startY = corner == .topLeading || corner == .topTrailing ? topInset + h / 2 : size.height - margin - h / 2
        let x = startX + value.predictedEndTranslation.width
        let y = startY + value.predictedEndTranslation.height
        let left = x < size.width / 2, top = y < size.height / 2
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            player.pipCorner = (top ? (left ? Corner.topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing)).rawValue
            drag = .zero
        }
    }

    private var card: some View {
        ZStack {
            Color.black
            PlayerVideo(active: player.mode == .mini)
            Color.clear
                .contentShape(Rectangle())
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
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14))
        }
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .overlay { resizeZones }
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

private extension View {
    /// A native resize edge: the system resize cursor on hover, and a drag that reports its translation.
    func resizeHandle(position: FrameResizePosition, axis: Axis.Set,
                      resize: @escaping (CGSize, Axis.Set, Bool) -> Void) -> some View {
        contentShape(Rectangle())
            .pointerStyle(.frameResize(position: position))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { resize($0.translation, axis, false) }
                    .onEnded { _ in resize(.zero, axis, true) }
            )
    }
}

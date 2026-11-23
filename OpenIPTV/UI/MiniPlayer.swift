import SwiftUI

/// Picture in picture: a small floating player in a corner of the window.
/// Drag it to any corner, hover for controls, double-click or ⤢ to expand, ✕ to stop.
struct MiniPlayer: View {
    @Environment(PlayerModel.self) private var player
    @State private var drag: CGSize = .zero
    @State private var hovering = false
    @State private var overGrip = false
    @State private var unhover = HideTimer()
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

    /// The resize grip sits on the corner facing into the window (opposite the docked corner).
    private var gripAlignment: Alignment {
        switch corner {
        case .topTrailing: .bottomLeading
        case .topLeading: .bottomTrailing
        case .bottomTrailing: .topLeading
        case .bottomLeading: .topTrailing
        }
    }

    private var grip: some View {
        let leading = corner == .topLeading || corner == .bottomLeading
        let top = corner == .topLeading || corner == .topTrailing
        // Arrow pointing out of the card, into the window.
        let symbol = top ? (leading ? "arrow.down.right" : "arrow.down.left") : (leading ? "arrow.up.right" : "arrow.up.left")
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .glassCircle()
            .contentShape(Rectangle().inset(by: -8))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let start = resizeStart ?? player.pipWidth
                        resizeStart = start
                        // Docked right → dragging left grows it; docked left → dragging right grows it.
                        let dx = leading ? v.translation.width : -v.translation.width
                        let dy = top ? v.translation.height : -v.translation.height
                        let grow = max(dx, dy * 16 / 9)
                        player.pipWidth = Double(min(max(start + grow, 260), Double(maxWidth)))
                    }
                    .onEnded { _ in
                        resizeStart = nil
                        if !overGrip { unhover.schedule(after: 0.7) { hovering = false } }
                    }
            )
            .onHover { inside in
                overGrip = inside
                if inside { unhover.cancel() } else if resizeStart == nil {
                    unhover.schedule(after: 0.7) { hovering = false }
                }
            }
            .help("Drag to resize")
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
        // Outside the clip, poking out of the inner corner, so it never covers the controls.
        .overlay(alignment: gripAlignment) {
            if hovering || resizeStart != nil {
                let leading = corner == .topLeading || corner == .bottomLeading
                let top = corner == .topLeading || corner == .topTrailing
                grip.offset(x: leading ? 21 : -21, y: top ? 21 : -21).transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .onHover { inside in
            // Linger a moment after the mouse leaves, so it can reach the resize grip outside the card.
            if inside { unhover.cancel(); hovering = true }
            else { unhover.schedule(after: 0.7) { if !overGrip { hovering = false } } }
        }
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

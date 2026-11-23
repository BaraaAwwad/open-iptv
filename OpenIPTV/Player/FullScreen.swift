import AppKit
import SwiftUI

/// Keeps the big player and macOS full screen in step, on the app's real window:
/// - player goes full  → the window enters full screen
/// - player leaves full → the window exits full screen (only if we put it there)
/// - full screen ends any other way (Esc, green button, Mission Control) → the player drops to PiP
/// Requests made while macOS is still animating are applied when the animation finishes.
@MainActor
final class FullScreenController {
    private weak var window: NSWindow?
    private weak var player: PlayerModel?
    private var observers: [NSObjectProtocol] = []
    private var transitioning = false
    private var enteredForPlayer = false

    func attach(_ window: NSWindow, player: PlayerModel) {
        guard window !== self.window else { return }
        // A frame saved mid-transition can bring the window back at its minimum size; restore a normal one
        // (after SwiftUI has applied its saved frame).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
            guard let window, !window.styleMask.contains(.fullScreen),
                  window.frame.width < 1000 || window.frame.height < 650,
                  let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            let size = NSSize(width: min(1280, screen.width), height: min(800, screen.height))
            window.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                   width: size.width, height: size.height), display: true, animate: false)
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        self.window = window
        self.player = player
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, _ body: @escaping @MainActor () -> Void) {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { body() }
            })
        }
        on(NSWindow.willEnterFullScreenNotification) { [weak self] in self?.begin() }
        on(NSWindow.willExitFullScreenNotification) { [weak self] in self?.begin() }
        on(NSWindow.didEnterFullScreenNotification) { [weak self] in
            self?.safety?.cancel()
            self?.transitioning = false
            self?.sync() // Esc pressed during the animation: go straight back out
        }
        on(NSWindow.didExitFullScreenNotification) { [weak self] in
            guard let self else { return }
            safety?.cancel()
            transitioning = false
            enteredForPlayer = false
            // Left full screen some other way: the big player can't stay without it.
            if player.mode == .full { player.mode = .mini }
        }
    }

    private var safety: DispatchWorkItem?

    /// A transition is running. If macOS never reports the end (a failed transition), give up waiting.
    private func begin() {
        transitioning = true
        safety?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.transitioning = false; self?.sync() }
        safety = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    /// Call whenever the player's mode changes.
    func sync() {
        guard let window, let player, !transitioning else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if player.mode == .full, !isFull {
            enteredForPlayer = true
            window.toggleFullScreen(nil)
        } else if player.mode != .full, isFull, enteredForPlayer {
            enteredForPlayer = false
            window.toggleFullScreen(nil)
        }
    }
}

/// Hands the SwiftUI view's real NSWindow to a callback (no guessing by title or identifier).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = ReaderView()
        v.onWindow = onWindow
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

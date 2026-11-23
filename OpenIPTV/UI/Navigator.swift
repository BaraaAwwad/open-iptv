import AppKit
import Observation

/// Keyboard focus for the channel grid / list: arrows move, Return plays, typing starts a search.
/// One item is "focused" at a time; hovering moves it too, so there is only ever one highlight.
@MainActor @Observable
final class Navigator {
    var focusID: String?
    /// The view scrolls to this id when it changes.
    var scrollTarget: String?
    @ObservationIgnored var items: [Channel] = []
    @ObservationIgnored var columns = 1
    /// After a key press, hover stops moving focus until the mouse really moves
    /// (otherwise tiles scrolling under a resting cursor would steal it).
    @ObservationIgnored var keyboardMode = false

    @ObservationIgnored var isActive: () -> Bool = { true }
    @ObservationIgnored var onPlay: (Channel, [Channel]) -> Void = { _, _ in }
    /// Type-ahead search: edits the query without moving focus into the search field.
    @ObservationIgnored var query: () -> String = { "" }
    @ObservationIgnored var setQuery: (String) -> Void = { _ in }
    @ObservationIgnored private var monitors: [Any] = []

    func install() {
        guard monitors.isEmpty else { return }
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) ?? e }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.keyboardMode = false }
            return e
        }) { monitors.append(m) }
    }

    func hover(_ id: String, _ inside: Bool) {
        guard !keyboardMode else { return }
        if inside { focusID = id } else if focusID == id { focusID = nil }
    }

    /// New list (category switch, new search results): keep focus if the item is still there.
    func setItems(_ new: [Channel], focusFirst: Bool) {
        items = new
        if focusFirst {
            focusID = new.first?.id
            scrollTarget = focusID
        } else if let f = focusID, !new.contains(where: { $0.id == f }) {
            focusID = nil
        }
    }

    private var index: Int? {
        focusID.flatMap { id in items.firstIndex { $0.id == id } }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        keyboardMode = true
        NSCursor.setHiddenUntilMouseMoves(true)
        let next = index.map { min(max($0 + delta, 0), items.count - 1) } ?? 0
        focusID = items[next].id
        scrollTarget = focusID
    }

    private func playFocused() -> Bool {
        guard let i = index ?? (items.isEmpty ? nil : 0) else { return false }
        onPlay(items[i], items)
        return true
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard isActive(), let window = e.window, window.attachedSheet == nil,
              window.identifier?.rawValue.contains("main") == true || window.title == "Open IPTV",
              e.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return e }

        let responder = window.firstResponder
        let inText = responder is NSText
        // While a search is showing, keys drive the results even if the sidebar still has focus.
        let inSidebar = responder is NSTableView && query().isEmpty

        switch e.keyCode {
        case 125: // ↓
            if inSidebar { return e }
            move(columns)
        case 126: // ↑
            if inSidebar { return e }
            if inText && (index ?? 0) < columns { return e }
            move(-columns)
        case 124: // →
            if inText { return e }
            if inSidebar {
                window.makeFirstResponder(nil)
                if index == nil { move(0) } else { keyboardMode = true }
                return nil
            }
            if let i = index, (i + 1) % columns == 0 || columns == 1 { return nil }
            move(1)
        case 123: // ←
            if inText || inSidebar { return e }
            if index == nil || index! % columns == 0 {
                if let outline = Self.find(NSTableView.self, in: window.contentView) {
                    window.makeFirstResponder(outline)
                }
                return nil
            }
            move(-1)
        case 36, 76: // Return
            if inSidebar { window.makeFirstResponder(nil); move(0); return nil }
            return playFocused() ? nil : e
        case 51: // Backspace
            if inText { return e }
            let q = query()
            guard !q.isEmpty else { return e }
            setQuery(String(q.dropLast()))
        case 53: // Esc
            if inText || query().isEmpty { return e }
            setQuery("")
        default:
            // Type anywhere to search.
            guard !inText, let chars = e.characters, chars.count == 1, let scalar = chars.unicodeScalars.first else { return e }
            let isSpace = scalar == " " && !query().isEmpty
            guard isSpace || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar) else { return e }
            setQuery(query() + chars)
            if responder is NSTableView { window.makeFirstResponder(nil) }
        }
        return nil
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }
}

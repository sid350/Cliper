import SwiftUI
import AppKit

/// Content of the status bar popover.
struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore
    /// Single click: copy to the clipboard. Returns false if that failed.
    let onCopy: (ClipboardItem) -> Bool
    /// Double click: copy and paste into the previous app.
    let onPaste: (ClipboardItem) -> Void
    let onClear: () -> Void
    let onQuit: () -> Void

    @State private var query = ""

    private var filteredItems: [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.items }
        return store.items.filter { $0.text?.localizedCaseInsensitiveContains(trimmed) ?? false }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drawn with its own background so it stays visible even while the
            // popover's window is not key (the system may refuse to activate a
            // menu bar app, and a .roundedBorder field then looks empty).
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .padding(10)

            Divider()

            list

            Divider()

            HStack {
                Button("Clear History…", action: onClear)
                    .disabled(store.items.isEmpty)
                Spacer()
                Button("Quit", action: onQuit)
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(10)
        }
        .frame(width: 320, height: 420)
    }

    @ViewBuilder
    private var list: some View {
        if store.items.isEmpty {
            placeholder("No items in clipboard history")
        } else if filteredItems.isEmpty {
            placeholder("Nothing found")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredItems) { item in
                        ClipboardRow(
                            item: item,
                            thumbnail: item.kind == .image ? store.thumbnail(for: item) : nil,
                            onClick: { clickCount in
                                if clickCount >= 2 {
                                    onPaste(item)
                                } else {
                                    _ = onCopy(item)
                                }
                            }
                        )
                        .contextMenu {
                            Button("Copy") { _ = onCopy(item) }
                            Divider()
                            Button("Delete") { store.remove(item) }
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let thumbnail: NSImage?
    /// Called on every click with the click count (1 = single, 2 = double).
    let onClick: (Int) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            // A Button fires on each click; the current event tells whether
            // this is the second click of a double click.
            // (clickCount is only valid for mouse events; keyboard or
            // accessibility presses count as a single click.)
            let event = NSApp.currentEvent
            let isMouseUp = event?.type == .leftMouseUp || event?.type == .leftMouseDown
            onClick(isMouseUp ? (event?.clickCount ?? 1) : 1)
        } label: {
            HStack {
                switch item.kind {
                case .text:
                    Text(item.previewText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image:
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 60)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Image unavailable")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // SwiftUI's onHover doesn't fire reliably in a popover of a menu bar
        // app, so track the mouse with an AppKit tracking area instead.
        .background(HoverTracker(isHovered: $isHovered))
        .help(item.text.map { String($0.prefix(500)) } ?? "Image")
    }
}

/// Reports whether the mouse is over this view, using an NSTrackingArea that is
/// active even when the popover's window is not key. It sits in the background,
/// so it never takes clicks away from the row.
private struct HoverTracker: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = { hovering in
            if isHovered != hovering { isHovered = hovering }
        }
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = { hovering in
            if isHovered != hovering { isHovered = hovering }
        }
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
            // Re-check after scrolling or layout changes moved the row.
            if let window {
                let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                onChange?(bounds.contains(point))
            }
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

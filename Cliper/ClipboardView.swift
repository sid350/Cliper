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
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
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
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(item.text.map { String($0.prefix(500)) } ?? "Image")
    }
}

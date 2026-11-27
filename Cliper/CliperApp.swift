import SwiftUI
import AppKit

@main
struct CliperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar only app: no windows. The Dock icon is hidden via
        // LSUIElement (INFOPLIST_KEY_LSUIElement in Build Settings).
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var store: ClipboardStore!
    private let monitor = PasteboardMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ClipboardStore(maxItems: 50)
        setupStatusItem()
        setupPopover()

        monitor.onContent = { [weak self] content in
            self?.handle(content)
        }
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        store.flush()
    }

    // MARK: - Status item and popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        if let image = NSImage(named: "StatusBarIcon") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "C"
        }
        button.toolTip = "Cliper - Clipboard Manager"
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 420)
        // Created once; the view updates itself from the store.
        popover.contentViewController = NSHostingController(
            rootView: ClipboardView(
                store: store,
                onSelect: { [weak self] item in self?.select(item) },
                onClear: { [weak self] in self?.confirmClear() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // A menu bar app is not active by default; without this the search
            // field and keyboard shortcuts don't receive key events.
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Actions

    private func handle(_ content: PasteboardMonitor.Content) {
        switch content {
        case .text(let text):
            store.addText(text)
        case .image(let data, let type):
            store.addImage(rawData: data, type: type)
        }
    }

    private func select(_ item: ClipboardItem) {
        guard store.write(item) else {
            NSSound.beep()
            return
        }
        monitor.ignoreCurrentContents()
        store.promote(item)
        popover.performClose(nil)
        // Give focus back to the app the user was working in, so Cmd-V works right away.
        NSApp.hide(nil)
    }

    private func confirmClear() {
        let count = store.items.count
        popover.performClose(nil)

        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "All \(count) items will be removed. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
        }
    }
}

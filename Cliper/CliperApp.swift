import SwiftUI
import AppKit
#if !APPSTORE
import ApplicationServices
import Carbon.HIToolbox
#endif

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

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var store: ClipboardStore!
    private let monitor = PasteboardMonitor()
    /// The app that was in front when the popover opened; paste goes there.
    private var previousApp: NSRunningApplication?
    /// Item copied with a single click. It moves to the top only when the
    /// popover closes, so the list doesn't jump under the cursor between the
    /// two clicks of a double click.
    private var pendingPromotion: ClipboardItem?

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
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: 420)
        // Created once; the view updates itself from the store.
        popover.contentViewController = NSHostingController(
            rootView: ClipboardView(
                store: store,
                onCopy: { [weak self] item in self?.copy(item) ?? false },
                onPaste: { [weak self] item in self?.paste(item) },
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
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp = frontmost
            }
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

    func popoverDidClose(_ notification: Notification) {
        if let item = pendingPromotion {
            pendingPromotion = nil
            store.promote(item)
        }
    }

    /// Single click: put the item on the clipboard and keep the popover open.
    @discardableResult
    private func copy(_ item: ClipboardItem) -> Bool {
        guard store.write(item) else {
            NSSound.beep()
            return false
        }
        monitor.ignoreCurrentContents()
        pendingPromotion = item
        return true
    }

    /// Double click: copy, close the popover, return to the previous app and
    /// press Cmd-V there. The App Store build (APPSTORE) is sandboxed and does
    /// not synthesize key presses: it only copies and returns focus, so the
    /// user presses Cmd-V.
    private func paste(_ item: ClipboardItem) {
        guard copy(item) else { return }
        popover.performClose(nil)

        // Give focus back to the app the user was working in.
        let target = previousApp
        NSApp.hide(nil)
        target?.activate()

        #if !APPSTORE
        // Synthesizing key presses needs the Accessibility permission. Ask for it
        // once; until it is granted, double click only copies.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Self.postCommandV()
        }
        #endif
    }

    #if !APPSTORE
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
    #endif

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

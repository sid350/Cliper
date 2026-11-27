import AppKit
import Combine
import ImageIO

/// Owns the clipboard history and its persistence.
///
/// Storage layout (in ~/Library/Application Support/<bundle id>/):
/// - `history.json` — small index with text and image file names
/// - `Images/*.png`  — one file per image item
///
/// All public methods must be called on the main thread. Disk I/O happens on a
/// private serial queue, so copying a large screenshot never blocks the UI.
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    let maxItems: Int

    private let imagesURL: URL
    private let indexURL: URL
    private let ioQueue = DispatchQueue(label: "Cliper.storage", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private let thumbnailCache = NSCache<NSString, NSImage>()

    private static let legacyDefaultsKey = "clipboardHistory"

    init(maxItems: Int = 50) {
        self.maxItems = maxItems

        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let baseURL = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cliper", isDirectory: true)
        imagesURL = baseURL.appendingPathComponent("Images", isDirectory: true)
        indexURL = baseURL.appendingPathComponent("history.json")

        do {
            // History can contain sensitive data: keep it readable by the owner only.
            try fileManager.createDirectory(
                at: imagesURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseURL.path)
        } catch {
            NSLog("Cliper: cannot create storage directory: \(error)")
        }

        load()
        migrateLegacyHistoryIfNeeded()
        removeOrphanedImages()
    }

    // MARK: - Adding items

    func addText(_ text: String) {
        insert(.makeText(text))
    }

    /// Stores image data from the pasteboard. PNG conversion and the disk write
    /// happen off the main thread; the item appears in the list once saved.
    func addImage(rawData: Data, type: NSPasteboard.PasteboardType) {
        let digest = ClipboardItem.digest(of: rawData, prefix: "image")
        if let index = items.firstIndex(where: { $0.digest == digest }) {
            promote(at: index)
            return
        }

        let fileName = UUID().uuidString + ".png"
        let url = imagesURL.appendingPathComponent(fileName)

        ioQueue.async { [weak self] in
            guard let png = Self.pngData(from: rawData, type: type) else { return }
            do {
                try png.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                NSLog("Cliper: cannot save image: \(error)")
                return
            }
            DispatchQueue.main.async {
                guard let self else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.insert(.makeImage(fileName: fileName, digest: digest))
            }
        }
    }

    // MARK: - Editing

    /// Moves an existing item to the top (e.g. after the user picked it).
    func promote(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        promote(at: index)
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        deleteFiles(of: item)
        scheduleSave()
    }

    func clear() {
        let removed = items
        items.removeAll()
        removed.forEach(deleteFiles(of:))
        scheduleSave()
    }

    // MARK: - Pasteboard

    /// Puts the item back on the pasteboard. Returns false if that failed
    /// (for example, the image file is missing).
    @discardableResult
    func write(_ item: ClipboardItem, to pasteboard: NSPasteboard = .general) -> Bool {
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        case .image:
            guard let url = imageURL(for: item), let png = try? Data(contentsOf: url) else { return false }
            pasteboard.clearContents()
            let ok = pasteboard.setData(png, forType: .png)
            // Many older apps only understand TIFF.
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            return ok
        }
    }

    // MARK: - Images

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return imagesURL.appendingPathComponent(name)
    }

    /// Small, cached thumbnail for the list. Decodes only a downscaled image,
    /// not the full-size screenshot.
    func thumbnail(for item: ClipboardItem, maxPixelSize: Int = 200) -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let url = imageURL(for: item),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2)
        )
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Persistence

    /// Writes pending changes and waits for all disk work to finish.
    /// Call from `applicationWillTerminate`.
    func flush() {
        saveNow()
        ioQueue.sync {}
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = items
        let url = indexURL
        ioQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                NSLog("Cliper: cannot save history: \(error)")
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode([ClipboardItem].self, from: data)
            let fileManager = FileManager.default
            // Drop image entries whose file has disappeared.
            items = decoded.filter { item in
                guard item.kind == .image else { return true }
                guard let url = imageURL(for: item) else { return false }
                return fileManager.fileExists(atPath: url.path)
            }
            if items.count > maxItems {
                items = Array(items.prefix(maxItems))
            }
        } catch {
            NSLog("Cliper: cannot read history, starting empty: \(error)")
        }
    }

    /// The first version kept everything (including TIFF images) as one blob in
    /// UserDefaults. Move it to the new storage once and delete the old key.
    private func migrateLegacyHistoryIfNeeded() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.legacyDefaultsKey) else { return }
        defer { defaults.removeObject(forKey: Self.legacyDefaultsKey) }

        guard let legacy = try? JSONDecoder().decode([LegacyClipboardContent].self, from: data) else { return }

        var migrated: [ClipboardItem] = []
        for entry in legacy {
            switch entry {
            case .text(let text):
                migrated.append(.makeText(text))
            case .image(let raw):
                guard let png = Self.pngData(from: raw, type: .tiff) else { continue }
                let fileName = UUID().uuidString + ".png"
                let url = imagesURL.appendingPathComponent(fileName)
                guard (try? png.write(to: url, options: .atomic)) != nil else { continue }
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                migrated.append(.makeImage(fileName: fileName, digest: ClipboardItem.digest(of: raw, prefix: "image")))
            }
        }

        var seen = Set(items.map(\.digest))
        for item in migrated where !seen.contains(item.digest) && items.count < maxItems {
            seen.insert(item.digest)
            items.append(item)
        }
        saveNow()
    }

    /// Deletes image files no longer referenced by the history (e.g. after a crash).
    private func removeOrphanedImages() {
        let referenced = Set(items.compactMap(\.imageFileName))
        let directory = imagesURL
        ioQueue.async {
            let fileManager = FileManager.default
            guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
            for name in files where !referenced.contains(name) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Helpers

    private func insert(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.digest == item.digest }) {
            // Already in history: drop the new copy, move the old one up.
            if let name = item.imageFileName, name != items[index].imageFileName {
                deleteImageFile(named: name)
            }
            promote(at: index)
            return
        }

        items.insert(item, at: 0)
        while items.count > maxItems {
            deleteFiles(of: items.removeLast())
        }
        scheduleSave()
    }

    private func promote(at index: Int) {
        var item = items.remove(at: index)
        item.date = Date()
        items.insert(item, at: 0)
        scheduleSave()
    }

    private func deleteFiles(of item: ClipboardItem) {
        thumbnailCache.removeObject(forKey: item.id.uuidString as NSString)
        if let name = item.imageFileName {
            deleteImageFile(named: name)
        }
    }

    private func deleteImageFile(named name: String) {
        let url = imagesURL.appendingPathComponent(name)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func pngData(from data: Data, type: NSPasteboard.PasteboardType) -> Data? {
        if type == .png { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }
}

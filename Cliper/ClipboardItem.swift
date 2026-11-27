import Foundation
import CryptoKit

/// One entry of the clipboard history.
///
/// Text is stored inline; images are stored as PNG files on disk and only
/// their file name is kept here, so the JSON index stays small.
struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    let id: UUID
    let kind: Kind
    /// Full text for `.text` items.
    let text: String?
    /// File name (inside the images directory) for `.image` items.
    let imageFileName: String?
    /// Stable content hash (SHA-256), used to detect duplicates across launches.
    let digest: String
    var date: Date

    static func makeText(_ text: String) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            kind: .text,
            text: text,
            imageFileName: nil,
            digest: Self.digest(of: Data(text.utf8), prefix: "text"),
            date: Date()
        )
    }

    static func makeImage(fileName: String, digest: String) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            kind: .image,
            text: nil,
            imageFileName: fileName,
            digest: digest,
            date: Date()
        )
    }

    static func digest(of data: Data, prefix: String) -> String {
        let hash = SHA256.hash(data: data)
        return prefix + "-" + hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Single-line preview used in the list.
    var previewText: String {
        guard let text else { return "Image" }
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        if collapsed.isEmpty { return "(whitespace)" }
        return collapsed.count > 80 ? String(collapsed.prefix(80)) + "…" : collapsed
    }
}

/// Format used by the first version of Cliper (stored in UserDefaults).
/// Kept only to migrate old history once.
enum LegacyClipboardContent: Codable {
    case text(String)
    case image(Data)
}

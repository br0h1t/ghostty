import AppKit
import GhosttyKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// A reversible UTI namespace for MIME types that do not have a system `UTType`
    private static let ghosttyMimePrefix = "com.mitchellh.ghostty.mime."

    /// Initialize a pasteboard type from a MIME type string
    init?(mimeType: String) {
        // Explicit mappings for common MIME types
        switch mimeType {
        case "text/plain":
            self = .string
            return
        default:
            break
        }

        // Try to get UTType from MIME type
        guard let utType = UTType(mimeType: mimeType) else {
            // Fallback: use the MIME type directly as identifier
            self.init(mimeType)
            return
        }

        // Use the UTType's identifier
        self.init(utType.identifier)
    }

    /// Initialize a DnD pasteboard type, using a reversible synthetic UTI for
    /// private MIME types that UniformTypeIdentifiers does not recognize.
    init?(dndMimeType mimeType: String) {
        guard !mimeType.isEmpty else { return nil }
        if mimeType == "text/plain" || UTType(mimeType: mimeType) != nil {
            self.init(mimeType: mimeType)
            return
        }

        guard let data = mimeType.data(using: .utf8) else { return nil }
        let encoded = data.map { String(format: "%02x", $0) }.joined()
        self.init(Self.ghosttyMimePrefix + encoded)
    }

    /// The MIME type for a DnD pasteboard type
    var dndMimeType: String? {
        guard rawValue.hasPrefix(Self.ghosttyMimePrefix) else { return mimeType }
        let encoded = rawValue.dropFirst(Self.ghosttyMimePrefix.count)
        guard !encoded.isEmpty, encoded.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(encoded.count / 2)
        var offset = encoded.startIndex
        while offset < encoded.endIndex {
            let end = encoded.index(offset, offsetBy: 2)
            guard let byte = UInt8(encoded[offset..<end], radix: 16) else { return nil }
            bytes.append(byte)
            offset = end
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// The best-effort MIME type for this pasteboard type.
    var mimeType: String? {
        switch self {
        case .string:
            return "text/plain"
        case .fileURL:
            return "text/uri-list"
        default:
            break
        }

        if let mime = UTType(self.rawValue)?.preferredMIMEType {
            return mime
        }

        if let customUTType = UTType(tag: self.rawValue, tagClass: .mimeType, conformingTo: nil) {
            return customUTType.preferredMIMEType
        }

        return nil
    }
}

extension NSPasteboard {
    /// The pasteboard to used for Ghostty selection.
    static var ghosttySelection: NSPasteboard = {
        NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
    }()

    /// Gets the contents of the pasteboard as a string following a specific set of semantics.
    /// Does these things in order:
    /// - Tries to get the absolute filesystem path of the file in the pasteboard if there is one and ensures the file path is properly escaped.
    /// - Tries to get any string from the pasteboard.
    /// If all of the above fail, returns None.
    func getOpinionatedStringContents() -> String? {
        let strings = (pasteboardItems ?? []).compactMap { item in
            if let plist = item.propertyList(forType: .fileURL),
               let fileURL = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               fileURL.isFileURL {
                return Ghostty.Shell.escape(fileURL.path)
            } else {
                return item.string(forType: .string)
            }
        }

        guard !strings.isEmpty else {
            return nil
        }
        return strings.joined(separator: " ")
    }

    /// The pasteboard for the Ghostty enum type.
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return Self.general

        case GHOSTTY_CLIPBOARD_SELECTION:
            return Self.ghosttySelection

        default:
            return nil
        }
    }
}

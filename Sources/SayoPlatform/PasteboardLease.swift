import AppKit
import SayoCore

/// Owns the clipboard only until the target has consumed the paste. A copy made
/// by the user in the meantime always wins over restoration of the old contents.
@MainActor
final class PasteboardLease {
    private let pasteboard: NSPasteboard
    private let savedItems: [NSPasteboardItem]
    private let installedChangeCount: Int

    init(text: String, pasteboard: NSPasteboard = .general) throws {
        self.pasteboard = pasteboard
        let before = pasteboard.changeCount
        savedItems = try (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                guard let data = original.data(forType: type) else { throw SayoError.replacementFailed }
                copy.setData(data, forType: type)
            }
            return copy
        }
        guard pasteboard.changeCount == before else { throw SayoError.staleInput }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Ask clipboard history utilities not to retain this temporary content.
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            pasteboard.writeObjects(savedItems)
            throw SayoError.replacementFailed
        }
        installedChangeCount = pasteboard.changeCount
    }

    func restore() {
        guard pasteboard.changeCount == installedChangeCount else { return }
        pasteboard.clearContents()
        if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
    }
}

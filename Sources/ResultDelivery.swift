import AppKit

struct ResultDelivery {
    var pasteboard: NSPasteboard = .general
    var showInFinder: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    @discardableResult func copy(_ files: [URL]) -> Bool {
        // A failed/cancelled conversion must preserve the user's clipboard.
        guard !files.isEmpty, files.allSatisfy({ $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(files as [NSURL])
    }
    func reveal(_ files: [URL]) {
        let existing = files.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { showInFinder(existing) }
    }
}

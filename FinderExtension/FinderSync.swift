import AppKit
import FinderSync

/// Finder supplies only the current selection. No directory enumeration,
/// file-content access, badges or background indexing are performed here.
@objc(OrbitFinderSync)
final class OrbitFinderSync: FIFinderSync {
    private var menuSelection: [URL] = []
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return nil }
        menuSelection = urls
        let menu = NSMenu(title: "Orbit")
        let item = NSMenuItem(title: "Конвертировать", action: #selector(orbitConvertSelection(_:)), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }
    @IBAction func orbitConvertSelection(_ sender: Any?) {
        // Keep the files belonging to this context menu. Activating another window
        // must never replace the source with its selection or a previous result.
        let urls = menuSelection
        guard let request = SelectionLink.make(urls) else { return }
        // Opening the document from the extension would require sandbox access to
        // its contents. A selection link delegates processing to the containing app.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(request, configuration: configuration) { _, error in
            if let error = error { NSLog("Orbit selection delivery failed: %@", error.localizedDescription) }
        }
    }
}

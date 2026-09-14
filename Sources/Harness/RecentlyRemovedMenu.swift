import AppKit

/// Wallpaper ▸ Recently Removed: Library entries removed by any Idlesse process, newest first.
final class RecentlyRemovedMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Recently Removed")
    private let library: () -> SceneLibraryController?

    init(library: @escaping () -> SceneLibraryController?) {
        self.library = library
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let records = library()?.recentlyRemoved ?? []
        guard !records.isEmpty else {
            menu.addItem(withTitle: "Nothing Removed", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        let when = RelativeDateTimeFormatter()
        for record in records.prefix(25) {
            let item = NSMenuItem(title: SceneLibraryController.displayTitle(record.entry.title), action: #selector(restore(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = record.entry.id
            item.toolTip = "Removed \(when.localizedString(for: record.removedAt, relativeTo: Date())). Choose to put it back."
            menu.addItem(item)
        }
    }

    @objc private func restore(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        library()?.restoreRemoved(id)
    }
}

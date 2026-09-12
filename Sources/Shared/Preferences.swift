import AppKit
import Foundation
import ScreenSaver

enum IdlesseMultiDisplayMode: String, CaseIterable, Codable {
    case same
    case different

    var title: String {
        switch self {
        case .same: return "Same image on every display"
        case .different: return "Different image on each display"
        }
    }
}

enum IdlessePlaybackOrder: String, CaseIterable, Codable {
    case random
    case nameAscending
    case nameDescending
    case createdOldest
    case createdNewest
    case modifiedOldest
    case modifiedNewest

    var title: String {
        switch self {
        case .random: return "Random"
        case .nameAscending: return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        case .createdOldest: return "Date created (oldest first)"
        case .createdNewest: return "Date created (newest first)"
        case .modifiedOldest: return "Date modified (oldest first)"
        case .modifiedNewest: return "Date modified (newest first)"
        }
    }
}

final class IdlessePreferences {
    static let moduleIdentifier = "com.teamleaderleo.idlesse"
    static let settingsChangedNotification = Notification.Name("com.teamleaderleo.idlesse.settingsChanged")
    static let shared = IdlessePreferences()

    private enum Key {
        static let folderBookmark = "folderBookmark"
        static let folderDisplayPath = "folderDisplayPath"
        static let displayDuration = "displayDuration"
        static let transitionDuration = "transitionDuration"
        static let scalingMode = "scalingMode"
        static let backgroundColor = "backgroundColor"
        static let multiDisplayMode = "multiDisplayMode"
        static let playbackOrder = "playbackOrder"
        static let shuffle = "shuffle"
        static let includeSubfolders = "includeSubfolders"
    }

    let defaults: UserDefaults

    init(defaults suppliedDefaults: UserDefaults? = nil) {
        if let suppliedDefaults {
            defaults = suppliedDefaults
        } else if let saverDefaults = ScreenSaverDefaults(forModuleWithName: Self.moduleIdentifier) {
            defaults = saverDefaults
        } else {
            defaults = .standard
        }

        let hadPlaybackOrder = defaults.object(forKey: Key.playbackOrder) != nil
        let legacyShuffle = (defaults.object(forKey: Key.shuffle) as? NSNumber)?.boolValue

        defaults.register(defaults: [
            Key.displayDuration: 300.0,
            Key.transitionDuration: 2.0,
            Key.scalingMode: IdlesseScalingMode.fit.rawValue,
            Key.backgroundColor: [0.0, 0.0, 0.0, 1.0],
            Key.multiDisplayMode: IdlesseMultiDisplayMode.same.rawValue,
            Key.playbackOrder: IdlessePlaybackOrder.random.rawValue,
            Key.includeSubfolders: true,
        ])

        if !hadPlaybackOrder, let legacyShuffle {
            defaults.set(
                legacyShuffle ? IdlessePlaybackOrder.random.rawValue : IdlessePlaybackOrder.nameAscending.rawValue,
                forKey: Key.playbackOrder
            )
        }
    }

    var folderDisplayPath: String? {
        defaults.string(forKey: Key.folderDisplayPath)
    }

    var displayDuration: TimeInterval {
        get { max(1, defaults.double(forKey: Key.displayDuration)) }
        set { defaults.set(max(1, newValue), forKey: Key.displayDuration) }
    }

    var transitionDuration: TimeInterval {
        get { max(0, defaults.double(forKey: Key.transitionDuration)) }
        set { defaults.set(min(30, max(0, newValue)), forKey: Key.transitionDuration) }
    }

    var scalingMode: IdlesseScalingMode {
        get {
            guard let raw = defaults.string(forKey: Key.scalingMode),
                  let mode = IdlesseScalingMode(rawValue: raw) else {
                return .fit
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.scalingMode) }
    }

    var backgroundColor: NSColor {
        get {
            let values = defaults.array(forKey: Key.backgroundColor)?
                .compactMap { ($0 as? NSNumber)?.doubleValue }

            guard let values, values.count >= 4 else { return .black }
            return NSColor(
                srgbRed: CGFloat(values[0]),
                green: CGFloat(values[1]),
                blue: CGFloat(values[2]),
                alpha: CGFloat(values[3])
            )
        }
        set {
            let color = newValue.usingColorSpace(.sRGB) ?? .black
            defaults.set([
                Double(color.redComponent),
                Double(color.greenComponent),
                Double(color.blueComponent),
                Double(color.alphaComponent),
            ], forKey: Key.backgroundColor)
        }
    }

    var multiDisplayMode: IdlesseMultiDisplayMode {
        get {
            guard let raw = defaults.string(forKey: Key.multiDisplayMode),
                  let mode = IdlesseMultiDisplayMode(rawValue: raw) else {
                return .same
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.multiDisplayMode) }
    }

    var playbackOrder: IdlessePlaybackOrder {
        get {
            guard let raw = defaults.string(forKey: Key.playbackOrder),
                  let order = IdlessePlaybackOrder(rawValue: raw) else {
                return .random
            }
            return order
        }
        set { defaults.set(newValue.rawValue, forKey: Key.playbackOrder) }
    }

    var includeSubfolders: Bool {
        get { defaults.bool(forKey: Key.includeSubfolders) }
        set { defaults.set(newValue, forKey: Key.includeSubfolders) }
    }

    func saveFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        defaults.set(bookmark, forKey: Key.folderBookmark)
        defaults.set(url.path, forKey: Key.folderDisplayPath)
    }

    func resolveFolder() throws -> URL? {
        guard let bookmark = defaults.data(forKey: Key.folderBookmark) else {
            return nil
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            try? saveFolder(url)
            save()
        }

        return url
    }

    func reloadFromDisk() {
        defaults.synchronize()
    }

    /// Hand the current ScreenSaverDefaults buffer to cfprefsd, then wake any
    /// other running legacyScreenSaver process so it can re-read the same domain.
    func save() {
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            Self.settingsChangedNotification,
            object: "settings-changed",
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

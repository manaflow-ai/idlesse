import Foundation

enum IdlesseExternalOpenRoute: Equatable {
    case sceneDocument
    case wallpaperMedia
    case deepLink

    static func classify(_ url: URL) -> Self {
        if url.scheme == "idlesse" { return .deepLink }
        if url.isFileURL, url.pathExtension.lowercased() == "idlesse" { return .sceneDocument }
        return .wallpaperMedia
    }
}

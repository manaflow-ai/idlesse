import CoreGraphics
import Foundation

/// Hard bounds for extension-safe scene posters. The renderer has its own
/// intermediate-texture cap; these limits additionally bound readback and PNG
/// memory in Quick Look processes.
enum ScenePreviewPolicy {
    static let defaultPreviewTime: Double = 2
    static let previewPixelSize = CGSize(width: 1280, height: 720)
    static let maxPixelWidth = 1600
    static let maxPixelHeight = 900
    static let maxOutputPixels = maxPixelWidth * maxPixelHeight
    static let maxOutputBytes = maxOutputPixels * 4
    static let minimumPixelDimension = 32
    private static let aspectRatio: CGFloat = 16.0 / 9.0

    static func previewTime(for scene: SceneDescriptor) -> Double {
        scene.metadata?.previewTime ?? defaultPreviewTime
    }

    /// Finder supplies thumbnail sizes in points plus a display scale. Keep the
    /// established 16:9 Idlesse poster aspect while staying inside both the
    /// request and the extension output ceiling.
    static func thumbnailPixelSize(maximumSize: CGSize, scale: CGFloat) -> CGSize? {
        guard maximumSize.width.isFinite, maximumSize.height.isFinite,
              scale.isFinite, maximumSize.width > 0, maximumSize.height > 0, scale > 0 else { return nil }
        let requestedWidth = min(CGFloat(maxPixelWidth), maximumSize.width * scale)
        let requestedHeight = min(CGFloat(maxPixelHeight), maximumSize.height * scale)
        let width = min(requestedWidth, requestedHeight * aspectRatio)
        let height = width / aspectRatio
        guard width >= CGFloat(minimumPixelDimension), height >= CGFloat(minimumPixelDimension) else { return nil }
        return CGSize(width: floor(width), height: floor(height))
    }

    static func validatedPixels(_ size: CGSize) throws -> (width: Int, height: Int) {
        guard size.width.isFinite, size.height.isFinite else {
            throw SceneError.invalid("Preview dimensions must be finite.")
        }
        guard size.width >= CGFloat(minimumPixelDimension), size.height >= CGFloat(minimumPixelDimension),
              size.width <= CGFloat(maxPixelWidth), size.height <= CGFloat(maxPixelHeight),
              size.width * size.height <= CGFloat(maxOutputPixels) else {
            throw SceneError.invalid("Preview dimensions exceed the bounded still-image budget.")
        }
        return (Int(size.width.rounded(.down)), Int(size.height.rounded(.down)))
    }
}

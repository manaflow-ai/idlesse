import CoreGraphics
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maximumSize = request.maximumSize
        let scale = request.scale
        guard let pixelSize = ScenePreviewPolicy.thumbnailPixelSize(maximumSize: maximumSize, scale: scale) else {
            handler(nil, SceneError.invalid("The requested thumbnail is outside Idlesse preview bounds."))
            return
        }

        Task { @MainActor in
            do {
                let frame = try await ScenePreviewRuntime.renderPackage(at: url, pixelSize: pixelSize)
                let contextSize = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
                let reply = QLThumbnailReply(contextSize: contextSize, drawing: { context in
                    context.interpolationQuality = .high
                    context.draw(frame.image, in: CGRect(origin: .zero, size: contextSize))
                    return true
                })
                handler(reply, nil)
            } catch {
                // Returning an error asks Quick Look to use its generic document thumbnail.
                handler(nil, error)
            }
        }
    }
}

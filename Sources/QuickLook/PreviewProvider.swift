import QuickLookUI
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL
        Task { @MainActor in
            do {
                let frame = try await ScenePreviewRuntime.renderPackage(
                    at: url,
                    pixelSize: ScenePreviewPolicy.previewPixelSize
                )
                let data = try frame.pngData()
                let reply = QLPreviewReply(
                    dataOfContentType: .png,
                    contentSize: frame.pixelSize,
                    createDataUsing: { _ in data }
                )
                // QLPreviewReply exposes a display title, but no author/tag metadata fields.
                reply.title = frame.title
                handler(reply, nil)
            } catch {
                // Quick Look supplies the generic package preview when the provider fails.
                handler(nil, error)
            }
        }
    }
}
